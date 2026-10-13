import 'dart:async';
import 'dart:io';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:xiaozhi_im_client/api.dart';
import 'package:xiaozhi_im_client/core/call_service.dart';
import 'package:xiaozhi_im_client/core/clipboard_image.dart';
import 'package:xiaozhi_im_client/core/config.dart';
import 'package:xiaozhi_im_client/core/file_io.dart';
import 'package:xiaozhi_im_client/core/media.dart';
import 'package:xiaozhi_im_client/core/read_bus.dart';
import 'package:xiaozhi_im_client/core/theme.dart';
import 'package:xiaozhi_im_client/core/time.dart';
import 'package:xiaozhi_im_client/core/voice.dart';
import 'package:xiaozhi_im_client/core/win_screen.dart';
import 'package:xiaozhi_im_client/models.dart';
import 'package:xiaozhi_im_client/screens/forward.dart';
import 'package:xiaozhi_im_client/screens/group_manage.dart';
import 'package:xiaozhi_im_client/screens/group_panel.dart';
import 'package:xiaozhi_im_client/screens/screenshot_editor.dart';
import 'package:xiaozhi_im_client/socket.dart';
import 'package:xiaozhi_im_client/widgets/avatar.dart';
import 'package:xiaozhi_im_client/widgets/bubble.dart';
import 'package:xiaozhi_im_client/widgets/emoji_panel.dart';

class ChatScreen extends StatefulWidget {
  final Conversation conv;
  final int myId;
  final String? peerName;

  /// 宽屏时作为侧栏右侧面板嵌入，此时不显示返回箭头
  final bool embedded;

  const ChatScreen({
    super.key,
    required this.conv,
    required this.myId,
    this.peerName,
    this.embedded = false,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  List<Message> _msgs = [];
  final _ctrl = TextEditingController();
  final _scrollC = ScrollController();
  final _focus = FocusNode();
  bool _busy = false;
  bool _loading = true;
  bool _hasText = false;

  /// 每个成员的已读水位：userId -> 读到的最大 message id
  Map<int, int> _readMap = {};
  int _recallWindowMs = 120000;

  /// 拖着文件悬在聊天窗上时显示投放提示（仅 Windows）
  bool _dragHover = false;

  /// 对方正在输入（非空=显示）
  int? _typingUserId;
  Timer? _typingHide;
  int _lastTypingSent = 0;

  /// 录音中（长按麦克风期间为 true）
  bool _recording = false;

  /// 手指上滑到"取消"区域
  bool _willCancel = false;
  int _recSeconds = 0;
  Timer? _recTimer;

  /// 群成员（用于 @提及 选择器；单聊为空）
  List<GroupMember> _members = [];

  /// 群公告（群聊才有）
  String? _announcement;
  bool _announceCollapsed = true;

  /// 当前置顶消息（null = 无）
  Message? _pinned;

  /// 我在群里的管理权限（群主/管理员）
  bool _canManage = false;

  /// 群主开了全员禁言（普通成员不能发言；豁免口径同服务端：能管群的人能说话）
  bool _mutedAll = false;

  /// 我已收藏的消息 id 集合（长按菜单显示"收藏/取消收藏"）
  final Set<int> _favIds = {};

  /// 记录上一次输入框内容，用于识别"刚输入了 @"
  String _lastText = '';

  /// 表情面板展开中
  bool _showEmoji = false;
  final _emojiPanelKey = GlobalKey<EmojiPanelState>();

  /// 文件下载进度：messageId -> 0~1（下载完移除）
  final Map<int, double> _fileProgress = {};

  @override
  void initState() {
    super.initState();
    _ctrl.addListener(_onTextChanged);
    _loadMsgs();
    SocketService().stream.listen(_onEvent);
  }

  @override
  void dispose() {
    _typingHide?.cancel();
    _recTimer?.cancel();
    // 页面销毁时若还在录音，丢弃半截文件，避免残留
    if (_recording) Voice.cancelRecording();
    Voice.stopPlayback(); // 离开会话停止播放
    _ctrl.dispose();
    _scrollC.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _loadMsgs() async {
    try {
      final d = await ImApi().messages(widget.conv.id);
      if (!mounted) return;
      final list =
          (d['messages'] as List? ?? []).map((e) => Message.fromJson(e)).toList();
      final members = d['members'] as List? ?? [];
      final pinnedRaw = d['pinned'];
      setState(() {
        _msgs = list;
        _readMap = {
          for (final m in members)
            (m['user_id'] as int): ((m['last_read_id'] ?? 0) as int),
        };
        _recallWindowMs = (d['recallWindowMs'] as int?) ?? 120000;
        _pinned = pinnedRaw is Map
            ? Message.fromJson(Map<String, dynamic>.from(pinnedRaw))
            : null;
        _loading = false;
      });
      _scroll();
      _markRead();
      _loadGroup();
      _loadFavs();
    } catch (e) {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 群聊：拉成员（@选择器用）、公告、我的管理权限、全员禁言状态
  Future<void> _loadGroup() async {
    final gid = widget.conv.groupId;
    if (gid == null) return;
    try {
      final d = await ImApi().groupDetail(gid);
      if (!mounted) return;
      final g = GroupDetail.fromJson(d);
      setState(() {
        _members = g.members;
        _canManage = g.canManage;
        _announcement = g.announcement;
        _mutedAll = g.mutedAll;
      });
    } catch (_) {
      // 群信息拉取失败不影响聊天
    }
  }

  /// 我现在被全员禁言拦着吗（普通成员 + 群开了全员禁言）。
  /// _canManage 与服务端 isAdmin 同口径（群内管理员/群主/系统管理员），
  /// 直接拿它当豁免判据，不会出现"服务端能发、界面却锁死"的两张皮。
  bool get _mutedHere =>
      widget.conv.type == 'group' && _mutedAll && !_canManage;

  /// 我收藏过的消息 id（长按菜单据此显示"收藏 / 取消收藏"）
  Future<void> _loadFavs() async {
    try {
      final d = await ImApi().favorites(limit: 200);
      if (!mounted) return;
      setState(() {
        _favIds
          ..clear()
          ..addAll(((d['items'] as List?) ?? []).map((e) => (e['id'] as int)));
      });
    } catch (_) {
      // 收藏状态拉取失败不打扰用户
    }
  }

  /// 上报已读（进入会话 / 收到对方新消息时）
  Future<void> _markRead() async {
    try {
      final r = await ImApi().markRead(widget.conv.id);
      final lr = (r['lastReadId'] as int?) ?? 0;
      if (mounted) setState(() => _readMap[widget.myId] = lr);
      // 上报成功即广播：会话列表本地立刻把红点清零（宽屏同屏时观感就是
      // "读了马上消"），不用等 WS 的 message:read 帧绕回来。
      // 只 fire 不清真值 —— 校准由订阅方的 _load() 拉服务端完成。
      ReadBus.instance.fire(widget.conv.id);
    } catch (_) {
      // 已读上报失败不打扰用户，下次进会话会重试
    }
  }

  void _onTextChanged() {
    final text = _ctrl.text;
    final v = text.trim().isNotEmpty;
    if (v != _hasText && mounted) setState(() => _hasText = v);

    // 刚敲下 @ → 弹出成员选择（仅群聊；插入的 "@昵称 " 以空格结尾，不会递归触发）
    if (widget.conv.type == 'group' &&
        text.length == _lastText.length + 1 &&
        text.endsWith('@')) {
      _pickMention();
    }
    _lastText = text;

    if (!v) return;
    // 输入中状态：2.5 秒节流，避免每个字符都发帧
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastTypingSent > 2500) {
      _lastTypingSent = now;
      SocketService().send({'type': 'typing', 'conversationId': widget.conv.id});
    }
  }

  /// 输入 @ 后弹出成员选择（含"所有人"），选中则把 "@昵称 " 插入光标处
  Future<void> _pickMention() async {
    if (_members.isEmpty) await _loadGroup();
    if (!mounted) return;
    final picked = await showModalBottomSheet<_MentionPick>(
      context: context,
      backgroundColor: AppColors.bgElevated,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 12),
            const Text('选择要提醒的人',
                style: TextStyle(fontSize: 13.5, color: AppColors.textSub)),
            const SizedBox(height: 8),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  ListTile(
                    leading: const Icon(Icons.campaign_rounded,
                        size: 21, color: Color(0xFFFFB74D)),
                    title: const Text('所有人',
                        style: TextStyle(
                            fontSize: 14.5, fontWeight: FontWeight.w600)),
                    onTap: () =>
                        Navigator.pop(ctx, const _MentionPick('所有人', -1)),
                  ),
                  ..._members
                      .where((m) => m.id != widget.myId)
                      .map((m) => ListTile(
                            leading: UserAvatar(name: m.display, size: 34, radius: 9),
                            title: Text(m.display,
                                style: const TextStyle(fontSize: 14.5)),
                            onTap: () =>
                                Navigator.pop(ctx, _MentionPick(m.display, m.id)),
                          )),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;

    // 去掉刚输入的 @，替换为 "@昵称 "
    final text = _ctrl.text;
    final base = text.endsWith('@') ? text.substring(0, text.length - 1) : text;
    final next = '$base@${picked.name} ';
    _ctrl.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: next.length),
    );
    _lastText = next;
    _focus.requestFocus();
  }

  /// 从文本里反查 @提及 的成员 id（避免用户删掉 @ 文本后仍误发提醒）
  List<int> _mentionsInText(String text) {
    final out = <int>[];
    for (final m in _members) {
      if (m.id != widget.myId && text.contains('@${m.display}')) out.add(m.id);
    }
    if (text.contains('@所有人') || text.toLowerCase().contains('@all')) {
      out.add(-1);
    }
    return out;
  }

  void _clearTyping() {
    _typingHide?.cancel();
    if (_typingUserId != null) setState(() => _typingUserId = null);
  }

  void _onEvent(dynamic e) {
    if (e is! Map) return;
    final type = e['type'];

    if (type == 'message:new') {
      final m = Message.fromJson(e['message']);
      if (m.conversationId != widget.conv.id) return;
      // 按 id 幂等去重。两种来源会送来同一条：
      //   ①「文件助手」是自己↔自己的会话，服务端广播不排除发送者，
      //      手机端刚发的那条会自己再收一次（不然电脑端收不到）；
      //   ② 断线重连的补推。
      // 不判重就是同一条消息在屏幕上出现两遍。
      if (_msgs.any((x) => x.id == m.id)) return;
      setState(() => _msgs.add(m));
      _scroll();
      _clearTyping();
      if (m.senderId != widget.myId) _markRead(); // 正在看这个会话，即时回执
      return;
    }

    if (type == 'message:recall') {
      if (e['conversationId'] != widget.conv.id) return;
      final id = e['messageId'];
      setState(() {
        final i = _msgs.indexWhere((x) => x.id == id);
        if (i >= 0) _msgs[i] = _msgs[i].copyWith(content: null, deleted: true);
      });
      return;
    }

    // 不再处理 message:edit —— 服务端已下线编辑能力。
    // 旧服务端可能还在广播它，收到就忽略，不做任何界面改动。

    if (type == 'message:read') {
      if (e['conversationId'] != widget.conv.id) return;
      final uid = e['userId'] as int?;
      if (uid == null || uid == widget.myId) return;
      final lr = (e['lastReadId'] as int?) ?? 0;
      setState(() {
        final old = _readMap[uid] ?? 0;
        if (lr > old) _readMap[uid] = lr;
      });
      return;
    }

    if (type == 'typing') {
      if (e['conversationId'] != widget.conv.id) return;
      if (e['userId'] == widget.myId) return;
      setState(() => _typingUserId = e['userId'] as int?);
      _typingHide?.cancel();
      _typingHide = Timer(const Duration(seconds: 3), () {
        if (mounted) setState(() => _typingUserId = null);
      });
      return;
    }

    // 有人置顶 / 取消置顶
    if (type == 'conversation:pin') {
      if (e['conversationId'] != widget.conv.id) return;
      final pid = e['pinnedMessageId'] as int?;
      if (pid == null) {
        setState(() => _pinned = null);
        return;
      }
      Message? found;
      for (final m in _msgs) {
        if (m.id == pid) { found = m; break; }
      }
      if (found == null) {
        _loadMsgs(); // 置顶的消息不在当前窗口内，重新拉一次
      } else {
        setState(() => _pinned = found);
      }
      return;
    }

    // 群资料 / 成员变更
    if (type == 'group:updated') {
      if (e['conversationId'] != widget.conv.id) return;
      _loadGroup();
      return;
    }

    // 被移出群聊 → 关掉会话页
    if (type == 'group:kicked') {
      if (e['conversationId'] != widget.conv.id) return;
      if (mounted) {
        _toast('你已被移出该群聊');
        Navigator.of(context).maybePop();
      }
    }
  }

  void _scroll() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollC.hasClients) {
        _scrollC.jumpTo(_scrollC.position.maxScrollExtent);
      }
    });
  }

  void _send() async {
    final t = _ctrl.text.trim();
    if (t.isEmpty) return;
    // 群聊：从文本里反查 @了谁（用户删掉 @文本就不会误提醒）
    final mentions =
        widget.conv.type == 'group' ? _mentionsInText(t) : const <int>[];
    _ctrl.clear();
    _lastText = '';
    setState(() => _hasText = false);
    try {
      final m =
          await ImApi().sendMessage(widget.conv.id, 'text', t, null, mentions);
      if (!mounted) return;
      setState(() => _msgs.add(Message.fromJson(m)));
      _scroll();
    } catch (e) {
      if (mounted) _toast('发送失败: ${_msg(e)}');
    }
  }

  // ---------- 表情 ----------

  /// 在光标处插入表情（光标无效时追加到末尾）
  void _insertEmoji(String e) {
    final text = _ctrl.text;
    var sel = _ctrl.selection;
    if (!sel.isValid) sel = TextSelection.collapsed(offset: text.length);
    final start = sel.start.clamp(0, text.length).toInt();
    final end = sel.end.clamp(0, text.length).toInt();
    final next = text.replaceRange(start, end, e);
    _ctrl.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: start + e.length),
    );
  }

  /// 退格：按「字素」删。emoji 常由多个码位组成（如 ❤️ = U+2764 + U+FE0F），
  /// 直接删一个 code unit 会留下半个字符渲染成方框。
  void _backspaceEmoji() {
    final text = _ctrl.text;
    if (text.isEmpty) return;
    var sel = _ctrl.selection;
    if (!sel.isValid) sel = TextSelection.collapsed(offset: text.length);
    var start = sel.start.clamp(0, text.length).toInt();
    final end = sel.end.clamp(0, text.length).toInt();
    if (start == end) {
      if (start == 0) return;
      final before = text.substring(0, start).characters;
      if (before.isEmpty) return;
      start = start - before.last.length;
    }
    final next = text.replaceRange(start, end, '');
    _ctrl.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: start),
    );
  }

  // ---------- 文件消息：打开 / 另存为 ----------

  String? _fileUrlOf(Message m) {
    final p = m.filePath;
    if (p == null || p.isEmpty) return null;
    return p.startsWith('http') ? p : '${Config.baseUrl}$p';
  }

  /// 下载到本地（已存在就直接复用），过程中把进度写进 _fileProgress 供气泡显示
  Future<File?> _fetchFile(Message m) async {
    final url = _fileUrlOf(m);
    if (url == null) {
      _toast('这条消息没有可下载的文件地址');
      return null;
    }
    setState(() => _fileProgress[m.id] = 0);
    try {
      return await FileIo.ensure(
        url: url,
        fileId: m.fileId ?? m.id,
        name: m.displayFileName,
        onProgress: (p) {
          if (!mounted) return;
          setState(() => _fileProgress[m.id] = p);
        },
      );
    } finally {
      if (mounted) setState(() => _fileProgress.remove(m.id));
    }
  }

  Future<void> _openFileMsg(Message m) async {
    try {
      final f = await _fetchFile(m);
      if (f == null) return;
      final err = await FileIo.open(f);
      if (err.isNotEmpty) _toast(err);
    } catch (e) {
      _toast('打开失败: ${_msg(e)}');
    }
  }

  Future<void> _saveFileAs(Message m) async {
    try {
      final f = await _fetchFile(m);
      if (f == null) return;
      final out = await FileIo.saveAs(f, m.displayFileName);
      if (out == null) return; // 用户取消
      _toast('已另存为 $out');
    } catch (e) {
      _toast('另存为失败: ${_msg(e)}');
    }
  }

  /// 上传一个文件并以 image / file 消息发出去。
  /// 返回是否压缩过（原图直传为 false），供上层汇总提示。
  /// [toastDone] 批量发送（拖拽/多选）时上层自己汇总，这里就不逐个弹提示。
  Future<bool> _sendFile(File orig, {bool toastDone = true}) async {
    final toUpload = await Media.prepareForUpload(orig); // 内网原图 / 外网压缩
    final up = await ImApi().upload(toUpload);

    final path = orig.path;
    final name = (up['name'] ?? path).toString();
    final isImg = (up['mime'] ?? '').toString().startsWith('image') ||
        Media.isImagePath(name) ||
        Media.isImagePath(path);
    // 图片消息存 /files/xxx 访问路径，文件消息存原始文件名
    final content = isImg ? (up['url'] ?? name).toString() : name;

    final m = await ImApi()
        .sendMessage(widget.conv.id, isImg ? 'image' : 'file', content, up['id']);
    if (!mounted) return false;
    setState(() => _msgs.add(Message.fromJson(m)));
    _scroll();
    final compressed = toUpload.path != orig.path;
    if (toastDone && compressed) {
      final newLen = await toUpload.length();
      _toast('已压缩上传（${TimeFmt.size(await orig.length())} → ${TimeFmt.size(newLen)}）');
    }
    return compressed;
  }

  // ── 截图 / 粘贴图片 / 拖拽收文件（Windows；龙哥 2026-10-10 需求④）──

  bool get _isWin => Platform.isWindows;

  /// 把 PNG 字节落临时文件再走通用发送（Ctrl+V 贴图用）
  Future<void> _sendPngBytes(Uint8List bytes) async {
    try {
      final dir = await getTemporaryDirectory();
      final f = File(p.join(dir.path, 'paste_${DateTime.now().millisecondsSinceEpoch}.png'));
      await f.writeAsBytes(bytes);
      await _sendFile(f, toastDone: false);
    } catch (e) {
      if (mounted) _toast('发送失败: $e');
    }
  }

  /// 拖拽进来的文件（可一次拖多个），逐个独立发送
  Future<void> _sendDropped(DropDoneDetails d) async {
    if (d.files.isEmpty) return;
    setState(() => _dragHover = false);
    var ok = 0;
    final failed = <String>[];
    setState(() => _busy = true);
    try {
      for (final f in d.files) {
        try {
          await _sendFile(File(f.path), toastDone: false);
          ok++;
        } catch (_) {
          failed.add(f.name);
        }
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted) return;
    if (ok == 0) {
      _toast('发送失败：${failed.join('、')}');
    } else if (failed.isNotEmpty) {
      _toast('已发送 $ok 个，${failed.length} 个失败');
    }
  }

  /// Windows 才包 DropTarget：拖文件进聊天窗直接发送
  Widget _dropWrap(Widget child) {
    if (!_isWin) return child;
    return DropTarget(
      onDragEntered: (_) => setState(() => _dragHover = true),
      onDragExited: (_) => setState(() => _dragHover = false),
      onDragDone: _sendDropped,
      child: Stack(
        children: [
          child,
          if (_dragHover)
            Positioned.fill(
              child: IgnorePointer(
                child: Container(
                  color: AppColors.brand.withValues(alpha: 0.08),
                  alignment: Alignment.center,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
                    decoration: BoxDecoration(
                      color: AppColors.bgElevated,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppColors.brand, width: 1.5),
                    ),
                    child: const Text('松开发送文件',
                        style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// Ctrl+V：剪贴板里是图片就直接发图（有图优先于文本粘贴）。
  /// 挂在输入框上游的 Focus 上 —— 按键从焦点节点冒泡上来，这里先拿到，
  /// 认下（handled）系统就不会再走默认的文本粘贴。
  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent e) {
    if (!_isWin) return KeyEventResult.ignored;
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    if (e.logicalKey != LogicalKeyboardKey.keyV) return KeyEventResult.ignored;
    if (!HardwareKeyboard.instance.isControlPressed) return KeyEventResult.ignored;
    final png = readClipboardImage();
    if (png == null) return KeyEventResult.ignored; // 没图 → 放行，正常粘贴文本
    _sendPngBytes(png);
    return KeyEventResult.handled;
  }

  /// 打开截图编辑器（框选 → 可标注 → 发送）
  Future<void> _startScreenshot() async {
    setState(() => _busy = true);
    String? shot;
    try {
      shot = await WinScreen.captureScreen();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted) return;
    if (shot == null) {
      _toast('截图失败（需要 Windows 10 及以上）');
      return;
    }
    final f = await Navigator.push<File>(
      context,
      MaterialPageRoute(builder: (_) => ScreenshotEditorPage(imagePath: shot!)),
    );
    if (f == null || !mounted) return;
    setState(() => _busy = true);
    try {
      await _sendFile(f, toastDone: false);
    } catch (e) {
      _toast('发送失败: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 选文件发送（file_picker 默认允许多选，一次可以挑一堆）。
  ///
  /// 逐个独立上传、逐个记账：第 3 个失败不影响前 2 个已经发出去的。
  /// 传 10 个文件因为其中一个坏了就全部回滚，比失败本身更让人恼火。
  void _attach() async {
    final files = await FilePicker.pickFiles();
    if (files.isEmpty) return;
    setState(() => _busy = true);
    var ok = 0;
    var compressed = 0;
    final failed = <String>[];
    try {
      for (final picked in files) {
        final path = picked.path;
        if (path == null) continue;
        try {
          if (await _sendFile(File(path))) compressed++;
          ok++;
        } catch (_) {
          failed.add(picked.name);
        }
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted) return;
    if (ok == 0) {
      _toast('发送失败：${failed.join('、')}');
      return;
    }
    final tail = failed.isEmpty ? '' : '（${failed.length} 个失败：${failed.join('、')}）';
    _toast(ok > 1 ? '已发送 $ok 个文件$tail' : '已发送$tail');
    if (compressed > 0) _toast('其中 $compressed 个走外网已压缩上传');
  }

  String _msg(Object e) => e.toString().replaceFirst('Exception: ', '');

  void _toast(String s) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(s), duration: const Duration(seconds: 2)));

  // ---------- 语音消息（长按录音 / 松开发送 / 上滑取消）----------

  Future<void> _startRecord() async {
    if (_busy || _recording) return;
    if (!await Voice.hasPermission()) {
      _toast('需要麦克风权限，请在系统设置里开启');
      return;
    }
    if (!await Voice.start()) {
      _toast('无法开始录音');
      return;
    }
    setState(() {
      _recording = true;
      _willCancel = false;
      _recSeconds = 0;
    });
    _recTimer?.cancel();
    _recTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (!mounted || !_recording) return;
      final s = Voice.elapsedSeconds;
      setState(() => _recSeconds = s);
      if (s >= Voice.maxSeconds) _finishRecord(); // 满 60 秒自动发送
    });
  }

  /// 长按拖动：手指移到屏幕上方 140px 内即"松手取消"
  void _updateRecordDrag(Offset globalPos) {
    if (!_recording) return;
    final cancel = globalPos.dy < 140;
    if (cancel != _willCancel) setState(() => _willCancel = cancel);
  }

  Future<void> _finishRecord() async {
    if (!_recording) return;
    _recTimer?.cancel();
    _recTimer = null;
    final cancel = _willCancel;
    setState(() {
      _recording = false;
      _willCancel = false;
      _recSeconds = 0;
    });
    if (cancel) {
      await Voice.cancelRecording();
      return;
    }
    final clip = await Voice.stopRecording();
    if (clip == null) {
      _toast('说话时间太短');
      return;
    }
    await _sendVoice(clip);
  }

  Future<void> _sendVoice(VoiceClip clip) async {
    setState(() => _busy = true);
    try {
      // 录音文件在临时目录里没有规范扩展名，显式指定 voice.m4a 让服务端按音频存
      final up = await ImApi().upload(clip.file, filename: 'voice.m4a');
      final m = await ImApi()
          .sendMessage(widget.conv.id, 'audio', '${clip.seconds}', up['id']);
      if (!mounted) return;
      setState(() => _msgs.add(Message.fromJson(m)));
      _scroll();
    } catch (e) {
      if (mounted) _toast('语音发送失败: ${_msg(e)}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ---------- 消息操作（长按菜单）----------

  bool _canRecall(Message m) =>
      m.senderId == widget.myId &&
      !m.deleted &&
      DateTime.now().millisecondsSinceEpoch - m.createdAt <= _recallWindowMs;

  // 已发送的消息不支持编辑（产品决策：只能撤回）。
  // 服务端对应接口已返回 410，这里也不再给入口。

  /// 能否置顶：单聊任意成员；群聊需群主或管理员
  bool get _canPinHere => widget.conv.type != 'group' || _canManage;

  void _showMsgMenu(Message m) {
    final canRecall = _canRecall(m);
    final expired = m.senderId == widget.myId &&
        !m.deleted &&
        !canRecall &&
        m.kind != 'image' &&
        m.kind != 'file';

    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.bgElevated,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 6),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.border,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 6),
            if (m.kind == 'text' && !m.deleted)
              _menuItem(Icons.copy_rounded, '复制', () {
                Navigator.pop(ctx);
                _copyText(m);
              }),
            // 文件消息：打开 / 另存为（卡片上点一下也能打开，这里给长按的补充入口）
            if (m.kind == 'file' && !m.deleted) ...[
              _menuItem(Icons.open_in_new_rounded, '打开', () {
                Navigator.pop(ctx);
                _openFileMsg(m);
              }),
              _menuItem(Icons.save_alt_rounded, '另存为…', () {
                Navigator.pop(ctx);
                _saveFileAs(m);
              }),
            ],
            // 已发送的消息只能撤回，不给「编辑」入口
            if (!m.deleted)
              _menuItem(Icons.forward_rounded, '转发', () {
                Navigator.pop(ctx);
                _forward(m);
              }),
            if (!m.deleted)
              _menuItem(
                _favIds.contains(m.id)
                    ? Icons.star_rounded
                    : Icons.star_border_rounded,
                _favIds.contains(m.id) ? '取消收藏' : '收藏',
                () {
                  Navigator.pop(ctx);
                  _toggleFav(m);
                },
              ),
            // 已读回执：只有「自己发的、未撤回」消息才给入口（看别人消息谁读了是越权）
            if (!m.deleted && m.senderId == widget.myId)
              _menuItem(Icons.visibility_outlined, '查看已读', () {
                _showReadReceipt(m);
              }),
            if (!m.deleted && _canPinHere)
              _menuItem(Icons.push_pin_rounded,
                  _pinned?.id == m.id ? '取消置顶' : '置顶', () {
                Navigator.pop(ctx);
                _togglePin(m);
              }),
            if (canRecall)
              _menuItem(Icons.undo_rounded, '撤回', () {
                Navigator.pop(ctx);
                _recallMsg(m);
              }, danger: true),
            if (expired)
              _menuItem(Icons.timer_off_outlined, '超过 2 分钟，无法撤回', null,
                  disabled: true),
            const SizedBox(height: 6),
          ],
        ),
      ),
    );
  }

  Widget _menuItem(IconData icon, String label, VoidCallback? onTap,
          {bool danger = false, bool disabled = false}) =>
      ListTile(
        enabled: !disabled,
        leading: Icon(icon,
            size: 21,
            color: disabled
                ? AppColors.textWeak
                : (danger ? AppColors.danger : AppColors.text)),
        title: Text(
          label,
          style: TextStyle(
            fontSize: 14.5,
            color: disabled
                ? AppColors.textWeak
                : (danger ? AppColors.danger : AppColors.text),
          ),
        ),
        onTap: onTap,
      );

  void _copyText(Message m) {
    final t = m.content;
    if (t == null || t.isEmpty) return;
    Clipboard.setData(ClipboardData(text: t));
    _toast('已复制');
  }

  Future<void> _recallMsg(Message m) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('撤回消息'),
        content: const Text('撤回后对方将看到「撤回了一条消息」，确定撤回吗？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('撤回')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ImApi().recallMessage(widget.conv.id, m.id);
      if (!mounted) return;
      setState(() {
        final i = _msgs.indexWhere((x) => x.id == m.id);
        if (i >= 0) _msgs[i] = _msgs[i].copyWith(content: null, deleted: true);
      });
    } catch (e) {
      if (mounted) _toast('撤回失败: ${_msg(e)}');
    }
  }

  /// 转发：弹出会话多选页
  Future<void> _forward(Message m) async {
    final done = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => ForwardScreen(messageId: m.id)),
    );
    if (done == true && mounted) _scroll();
  }

  /// 收藏 / 取消收藏
  Future<void> _toggleFav(Message m) async {
    final has = _favIds.contains(m.id);
    try {
      if (has) {
        await ImApi().removeFavorite(m.id);
        if (mounted) setState(() => _favIds.remove(m.id));
        _toast('已取消收藏');
      } else {
        await ImApi().addFavorite(m.id);
        if (mounted) setState(() => _favIds.add(m.id));
        _toast('已收藏，可在「我的收藏」查看');
      }
    } catch (e) {
      if (mounted) _toast('操作失败: ${_msg(e)}');
    }
  }

  /// 置顶 / 取消置顶
  Future<void> _togglePin(Message m) async {
    try {
      final r = await ImApi().pinMessage(widget.conv.id, m.id);
      final pid = r['pinnedMessageId'] as int?;
      if (!mounted) return;
      setState(() => _pinned = pid == null ? null : m);
      _toast(pid == null ? '已取消置顶' : '已置顶');
    } catch (e) {
      if (mounted) _toast('操作失败: ${_msg(e)}');
    }
  }

  /// 已读回执：长按自己发的消息 → 弹出"谁读了 / 谁没读"面板
  void _showReadReceipt(Message m) {
    Navigator.pop(context); // 先关长按菜单
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.bgElevated,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (_) => _ReadReceiptSheet(convId: widget.conv.id, msgId: m.id),
    );
  }

  // ---------- 渲染 ----------

  /// 只在「自己发的最后一条未撤回消息」上常驻显示已读回执。
  /// 单聊：对方读到哪 → 已读 / 未读；
  /// 群聊：其他成员里多少人读到了这条 → 「已读 N/共 M」（N=已读人数，M=其他成员总数）。
  String? _readLabelFor(int i) {
    final m = _msgs[i];
    if (m.senderId != widget.myId || m.deleted) return null;
    final hasLaterMine = _msgs
        .skip(i + 1)
        .any((x) => x.senderId == widget.myId && !x.deleted);
    if (hasLaterMine) return null;
    final others = _readMap.entries.where((e) => e.key != widget.myId).toList();
    if (others.isEmpty) return null;
    if (widget.conv.type == 'group') {
      final read = others.where((e) => e.value >= m.id).length;
      final total = others.length;
      // 没有任何其他成员时（理论上不会，但兜底）不显示
      if (total == 0) return null;
      return '已读 $read/$total';
    }
    final wm = others.first.value;
    return wm >= m.id ? '已读' : '未读';
  }

  bool _showTimeAt(int i) {
    if (i == 0) return true;
    return _msgs[i].createdAt - _msgs[i - 1].createdAt > 5 * 60 * 1000;
  }

  bool _showDayAt(int i) {
    if (i == 0) return true;
    return !TimeFmt.sameDay(_msgs[i].createdAt, _msgs[i - 1].createdAt);
  }

  String get _title => widget.conv.title ?? widget.peerName ?? '会话';

  /// 单聊对方信息（群聊为 null）。服务端 /conversations 已把 peer 展开，
  /// 这里只用它取 id / 头像 / 是否机器人。
  Map<String, dynamic>? get _peer => widget.conv.peer;

  int? get _peerId => (_peer?['id'] as num?)?.toInt();

  bool get _peerIsBot => _peer?['is_bot'] == true || _peer?['is_bot'] == 1;

  /// 发起通话（video=false 为语音）。失败原因直接弹提示，不静默。
  Future<void> _startCall(bool video) async {
    final pid = _peerId;
    if (pid == null) {
      _toast('无法识别通话对象，请下拉刷新会话列表');
      return;
    }
    final err = await CallService().startCall(
      conversationId: widget.conv.id,
      peerId: pid,
      peerName: _title,
      peerAvatar: _peer?['avatar'] as String?,
      video: video,
    );
    if (err != null && mounted) _toast(err);
  }

  /// 发起群通话（video=false 为群语音房）。
  ///
  /// 服务端不传 calleeIds 时默认邀请群内所有其他成员，所以这里只发起、不挑人。
  /// 上限由服务端兜底（默认 6 人），这里做一次前置提示，免得用户点了才发现
  /// 一大半人进不来。
  Future<void> _startGroupCall(bool video) async {
    const limit = 6;
    if (_members.length > limit) {
      _toast('群成员 ${_members.length} 人，单次通话最多 $limit 人，先到的先进');
    }
    final err = await CallService().startGroupCall(
      conversationId: widget.conv.id,
      video: video,
      group: true,
      groupName: _title,
    );
    if (err != null && mounted) _toast(err);
  }

  /// 每条消息的发送者名字。
  /// 群聊里成员名单是拉到的，优先用它——这样机器人、其他成员的名字都能显示对，
  /// 而不是一律显示会话名（旧实现只有单聊能显示对）。
  String? _senderName(Message m) {
    if (m.senderId == widget.myId) return null;
    for (final mem in _members) {
      if (mem.id == m.senderId) return mem.display;
    }
    return widget.peerName;
  }

  /// 发送者在群里的角色（owner / admin / member），用于气泡上的身份标签。
  String? _senderRole(Message m) {
    if (widget.conv.type != 'group') return null;
    for (final mem in _members) {
      if (mem.id == m.senderId) return mem.role;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final canSend = _hasText && !_busy;
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: !widget.embedded,
        titleSpacing: widget.embedded ? 16 : 0,
        title: Row(
          children: [
            widget.conv.type == 'group'
                // 群聊顶栏也用拼出来的群头像，跟列表里看到的保持一致，
                // 否则点进去发现"换了个图标"会以为是另一个群
                ? GroupAvatar(
                    members: widget.conv.memberAvatars, size: 36, radius: 12)
                : widget.conv.isFileHelper
                    ? const FileHelperAvatar(size: 36, radius: 12)
                    : UserAvatar(
                        name: _title, size: 36, radius: 12,
                        imageUrl: widget.conv.avatar),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(_title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 1),
                  _typingUserId != null
                      ? const Text(
                          '正在输入…',
                          style: TextStyle(
                              fontSize: 11.5,
                              color: AppColors.brand,
                              fontWeight: FontWeight.w600),
                        )
                      : Text(
                          widget.conv.isFileHelper
                              ? '手机 ↔ 电脑互传文件'
                              : widget.conv.type == 'group'
                                  // 带上人数：群聊和单聊的第二行也就彻底不一样了
                                  ? (widget.conv.memberCount > 0
                                      ? '群聊 · ${widget.conv.memberCount} 人'
                                      : '群聊')
                                  : '私信',
                          style: const TextStyle(
                              fontSize: 11.5,
                              color: AppColors.textWeak,
                              fontWeight: FontWeight.w400),
                        ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          // 单聊才有通话入口，直接给两个按钮；机器人不会接，直接不给
          if (widget.conv.type == 'dm' && !_peerIsBot) ...[
            IconButton(
              tooltip: '语音通话',
              onPressed: () => _startCall(false),
              icon: const Icon(Icons.call_rounded),
            ),
            IconButton(
              tooltip: '视频通话',
              onPressed: () => _startCall(true),
              icon: const Icon(Icons.videocam_rounded),
            ),
          ],
          // 群聊：通话 + 群管理收进一个菜单，否则顶栏放不下 4 个图标
          if (widget.conv.type == 'group') ...[
            PopupMenuButton<String>(
              tooltip: '群通话',
              icon: const Icon(Icons.call_rounded),
              onSelected: (v) {
                switch (v) {
                  case 'audio':
                    _startGroupCall(false);
                    break;
                  case 'video':
                    _startGroupCall(true);
                    break;
                  case 'poll':
                    _createPoll();
                    break;
                  case 'manage':
                    _openGroupManage();
                    break;
                  case 'panel':
                    _openGroupPanel();
                    break;
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(
                  value: 'audio',
                  child: ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.phone_rounded, size: 20),
                    title: Text('群语音通话'),
                  ),
                ),
                PopupMenuItem(
                  value: 'video',
                  child: ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.videocam_rounded, size: 20),
                    title: Text('群视频通话'),
                  ),
                ),
                PopupMenuDivider(),
                PopupMenuItem(
                  value: 'poll',
                  child: ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.how_to_vote_outlined, size: 20),
                    title: Text('发起投票'),
                  ),
                ),
                PopupMenuItem(
                  value: 'panel',
                  child: ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.apps_rounded, size: 20),
                    title: Text('群文件 · 相册 · 课堂'),
                  ),
                ),
                PopupMenuItem(
                  value: 'manage',
                  child: ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.groups_rounded, size: 20),
                    title: Text('群管理'),
                  ),
                ),
              ],
            ),
          ],
          IconButton(
            tooltip: '刷新',
            onPressed: _loadMsgs,
            icon: const Icon(Icons.refresh_rounded),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: _dropWrap(Stack(
        children: [
          Column(
            children: [
              _topBars(),
              Expanded(child: _body()),
              // 全员禁言：普通成员看到"全体成员已被禁言"提示条替代输入区。
              // 只换界面不换逻辑——就算绕过界面，服务端也会拦（两条腿都要有）。
              if (_mutedHere)
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.fromLTRB(12, 4, 12, 10),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppColors.border),
                  ),
                  child: Row(
                    children: const [
                      Icon(Icons.volume_off_rounded,
                          size: 17, color: AppColors.textWeak),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text('群主已开启全员禁言，暂时无法发言',
                            style: TextStyle(
                                fontSize: 13, color: AppColors.textWeak)),
                      ),
                    ],
                  ),
                )
              else
                _composer(canSend),
              if (_showEmoji)
                EmojiPanel(
                  key: _emojiPanelKey,
                  onPick: _insertEmoji,
                  onBackspace: _backspaceEmoji,
                ),
            ],
          ),
          if (_recording) _recordOverlay(),
        ],
      )),
    );
  }

  /// 会话顶部信息条：置顶消息 + 群公告（都没有则占 0 高度）
  Widget _topBars() {
    final bars = <Widget>[];
    if (_pinned != null) bars.add(_pinnedBar(_pinned!));
    if (widget.conv.type == 'group' &&
        _announcement != null &&
        _announcement!.isNotEmpty) {
      bars.add(_announceBar(_announcement!));
    }
    if (bars.isEmpty) return const SizedBox.shrink();
    return Column(children: bars);
  }

  Widget _pinnedBar(Message m) => Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        color: AppColors.brand.withValues(alpha: 0.10),
        child: Row(
          children: [
            const Icon(Icons.push_pin_rounded, size: 15, color: AppColors.brand),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _previewOf(m),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12.5, color: AppColors.text),
              ),
            ),
            if (_canPinHere)
              GestureDetector(
                onTap: () => _togglePin(m),
                child: const Padding(
                  padding: EdgeInsets.only(left: 8),
                  child: Icon(Icons.close_rounded,
                      size: 15, color: AppColors.textWeak),
                ),
              ),
          ],
        ),
      );

  Widget _announceBar(String text) => GestureDetector(
        onTap: () => setState(() => _announceCollapsed = !_announceCollapsed),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: const BoxDecoration(
            color: AppColors.surfaceHi,
            border: Border(bottom: BorderSide(color: AppColors.divider)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.only(top: 1),
                child: Icon(Icons.campaign_rounded,
                    size: 15, color: Color(0xFFFFB74D)),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '群公告：$text',
                  maxLines: _announceCollapsed ? 1 : 6,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 12.5, color: AppColors.textSub, height: 1.4),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(left: 6, top: 1),
                child: Icon(
                  _announceCollapsed
                      ? Icons.expand_more_rounded
                      : Icons.expand_less_rounded,
                  size: 16,
                  color: AppColors.textWeak,
                ),
              ),
            ],
          ),
        ),
      );

  /// 单行预览（置顶条 / 转发提示用）
  String _previewOf(Message m) {
    switch (m.kind) {
      case 'text':
        return m.content ?? '';
      case 'image':
        return '[图片]';
      case 'audio':
        return '[语音] ${m.audioSeconds ?? 1}"';
      case 'file':
        return '[文件] ${m.fileName ?? ''}';
      case 'emoji':
        return '[表情] ${m.content ?? ''}';
      case 'card':
        return '[卡片] ${m.card?.title ?? ''}';
      case 'poll':
        // content 是 {"pollId":N}，直接展示会露出一串 JSON
        return '[投票]';
      case 'call':
        return m.call?.label ?? '[通话]';
      default:
        return m.content ?? '';
    }
  }

  Future<void> _openGroupManage() async {
    final gid = widget.conv.groupId;
    if (gid == null) return;
    final changed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => GroupManageScreen(groupId: gid, myId: widget.myId),
      ),
    );
    if (changed == true && mounted) {
      _loadGroup();
      _loadMsgs();
    }
  }

  /// 群功能面板（群文件 / 相册 / 视频 / 课堂）
  void _openGroupPanel() {
    final gid = widget.conv.groupId;
    if (gid == null) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => GroupPanelScreen(
          groupId: gid,
          groupName: widget.conv.title ?? '群聊',
        ),
      ),
    );
  }

  /// 发起投票（QQ 群投票口径）：标题 + 2~10 个选项 + 多选/匿名开关。
  /// 成功后服务端会往群里发一条 poll 卡片消息，这里刷新列表就能看到。
  Future<void> _createPoll() async {
    final gid = widget.conv.groupId;
    if (gid == null) return;
    final created = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.bgElevated,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (ctx) => _PollCreateSheet(groupId: gid),
    );
    if (created == true && mounted) _loadMsgs();
  }

  Widget _body() {
    if (_loading) {
      return const Center(
          child: SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2)));
    }
    if (_msgs.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.waving_hand_rounded,
                size: 46, color: AppColors.textWeak.withValues(alpha: 0.5)),
            const SizedBox(height: 12),
            const Text('还没有消息，打个招呼吧',
                style: TextStyle(color: AppColors.textSub, fontSize: 14)),
          ],
        ),
      );
    }
    // 会话里所有可看的图片（绝对路径）—— 点开大图后要能左右滑着看下一张，
    // 这是微信/企微都有的手势。只收图片消息，且撤回的（imagePath 为 null）不算。
    final gallery = <String>[];
    final galleryIdx = <int, int>{}; // 消息下标 -> 它在画廊里的下标
    for (var i = 0; i < _msgs.length; i++) {
      final p = _msgs[i].imagePath;
      if (p == null) continue;
      galleryIdx[i] = gallery.length;
      gallery.add('${Config.baseUrl}$p');
    }
    return ListView.builder(
      controller: _scrollC,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      itemCount: _msgs.length,
      itemBuilder: (c, i) {
        final m = _msgs[i];
        return Column(
          children: [
            if (_showDayAt(i)) DayDivider(ts: m.createdAt),
            MessageBubble(
              msg: m,
              mine: m.senderId == widget.myId,
              senderName: _senderName(m),
              senderRole: _senderRole(m),
              baseUrl: Config.baseUrl,
              showTime: _showTimeAt(i),
              readLabel: _readLabelFor(i),
              mentionHighlight:
                  m.senderId != widget.myId && m.mentionsMe(widget.myId),
              onLongPress: () => _showMsgMenu(m),
              onFileOpen: m.kind == 'file' ? () => _openFileMsg(m) : null,
              onFileSaveAs: m.kind == 'file' ? () => _saveFileAs(m) : null,
              fileProgress: _fileProgress[m.id],
              imageUrls: gallery,
              imageIndex: galleryIdx[i] ?? 0,
              pollGroupId: widget.conv.groupId,
              pollCanManage: _canManage,
              onPollChanged: _loadMsgs,
            ),
          ],
        );
      },
    );
  }

  /// 录音浮层：显示计时与"上滑取消"状态
  Widget _recordOverlay() {
    final left = (Voice.maxSeconds - _recSeconds).clamp(0, Voice.maxSeconds);
    return Positioned.fill(
      child: IgnorePointer(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 26, vertical: 20),
                decoration: BoxDecoration(
                  color: _willCancel
                      ? AppColors.danger.withValues(alpha: 0.93)
                      : Colors.black.withValues(alpha: 0.84),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _willCancel
                          ? Icons.delete_outline_rounded
                          : Icons.mic_rounded,
                      color: Colors.white,
                      size: 34,
                    ),
                    const SizedBox(height: 10),
                    Text(
                      '$_recSeconds"',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _willCancel ? '松开取消' : '松开发送 · 上滑取消',
                      style:
                          const TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Text('还可录 $left 秒',
                  style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 11.5,
                      shadows: [Shadow(blurRadius: 6, color: Colors.black54)])),
            ],
          ),
        ),
      ),
    );
  }

  Widget _composer(bool canSend) => Container(
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
        decoration: const BoxDecoration(
          color: AppColors.bgElevated,
          border: Border(top: BorderSide(color: AppColors.divider)),
        ),
        child: SafeArea(
          top: false,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              _roundButton(
                icon: _busy
                    ? Icons.hourglass_top_rounded
                    : Icons.attach_file_rounded,
                onTap: _busy ? null : _attach,
              ),
              // 截图（框选 → 可标注/OCR → 发送）。只有 Windows 有；
              // Android 上不显示，输入区不挤
              if (_isWin)
                _roundButton(
                  icon: Icons.crop_rounded,
                  onTap: _busy ? null : _startScreenshot,
                ),
              const SizedBox(width: 8),
              _micButton(),
              const SizedBox(width: 8),
              Expanded(
                child: Focus(
                  // Windows：Ctrl+V 时剪贴板里有图就发图（见 _onKeyEvent）。
                  // canRequestFocus=false / skipTraversal：这个节点只当"按键
                  // 冒泡的中转站"，不参与焦点切换，输入框的焦点行为不受影响。
                  onKeyEvent: _isWin ? _onKeyEvent : null,
                  canRequestFocus: false,
                  skipTraversal: true,
                  child: Container(
                    constraints: const BoxConstraints(maxHeight: 120),
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      borderRadius: BorderRadius.circular(22),
                      border: Border.all(color: AppColors.border),
                    ),
                    child: TextField(
                    controller: _ctrl,
                    focusNode: _focus,
                    minLines: 1,
                    maxLines: 5,
                    textInputAction: TextInputAction.newline,
                    style: const TextStyle(fontSize: 15, height: 1.35),
                    decoration: const InputDecoration(
                      hintText: '输入消息…',
                      filled: false,
                      isDense: true,
                      contentPadding:
                          EdgeInsets.symmetric(horizontal: 16, vertical: 11),
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                    ),
                    onSubmitted: (_) => _send(),
                    onTap: () {
                      // 桌面端点输入框顺手收起表情面板，避免两块内容抢高度
                      if (_showEmoji) setState(() => _showEmoji = false);
                    },
                  ),
                ),
                ),
              ),
              const SizedBox(width: 6),
              _emojiButton(),
              const SizedBox(width: 6),
              _sendButton(canSend),
            ],
          ),
        ),
      );

  /// 表情按钮：展开/收起面板；展开时先把焦点让出去，
  /// 否则手机端系统键盘会和面板叠在一起把输入区顶得很高。
  Widget _emojiButton() => _roundButton(
        icon: _showEmoji
            ? Icons.keyboard_alt_outlined
            : Icons.emoji_emotions_outlined,
        color: _showEmoji ? AppColors.brand : null,
        onTap: () {
          setState(() => _showEmoji = !_showEmoji);
          if (_showEmoji) _focus.unfocus();
        },
      );

  /// 麦克风按钮：按下即录（用 Listener 而非长按手势，响应更跟手）
  Widget _micButton() => Listener(
        onPointerDown: (_) => _startRecord(),
        onPointerMove: (e) => _updateRecordDrag(e.position),
        onPointerUp: (_) => _finishRecord(),
        onPointerCancel: (_) => _finishRecord(),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: _recording ? AppColors.danger : AppColors.surface,
            boxShadow: _recording
                ? [
                    BoxShadow(
                      color: AppColors.danger.withValues(alpha: 0.45),
                      blurRadius: 14,
                      offset: const Offset(0, 2),
                    ),
                  ]
                : null,
          ),
          child: Icon(
            Icons.mic_rounded,
            size: 21,
            color: _recording ? Colors.white : AppColors.textSub,
          ),
        ),
      );

  Widget _roundButton(
          {required IconData icon, VoidCallback? onTap, Color? color}) =>
      Material(
        color: AppColors.surface,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox(
            width: 42,
            height: 42,
            child: Icon(icon, size: 21, color: color ?? AppColors.textSub),
          ),
        ),
      );

  Widget _sendButton(bool canSend) => GestureDetector(
        onTap: canSend ? _send : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: canSend ? AppTheme.brandGradient : null,
            color: canSend ? null : AppColors.surfaceHi,
            boxShadow: canSend
                ? [
                    BoxShadow(
                      color: AppColors.brand2.withValues(alpha: 0.35),
                      blurRadius: 12,
                      offset: const Offset(0, 3),
                    ),
                  ]
                : null,
          ),
          child: Icon(
            Icons.send_rounded,
            size: 19,
            color: canSend ? Colors.white : AppColors.textWeak,
          ),
        ),
      );
}

/// @提及选择结果：name 用于插入文本，id 用于服务端校验（-1 = 所有人）
class _MentionPick {
  final String name;
  final int id;

  const _MentionPick(this.name, this.id);
}

/// 已读回执面板：列出一条消息的已读 / 未读成员（含头像、名字）。
/// 服务端按"除发送者外的会话成员，last_read_id >= 消息 id"判定已读。
/// 只对"自己发的消息"开放入口（隐私：不能看别人消息谁读了）。
class _ReadReceiptSheet extends StatefulWidget {
  final int convId;
  final int msgId;
  const _ReadReceiptSheet({ required this.convId, required this.msgId });

  @override
  State<_ReadReceiptSheet> createState() => _ReadReceiptSheetState();
}

class _ReadReceiptSheetState extends State<_ReadReceiptSheet> {
  bool _loading = true;
  String? _err;
  Map<String, dynamic>? _data;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d = await ImApi().messageReaders(widget.convId, widget.msgId);
      if (!mounted) return;
      setState(() {
        _data = d;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _err = e.toString().replaceFirst('Exception: ', '');
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).padding.bottom;
    final content = _loading
        ? const Center(
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: 40),
              child: CircularProgressIndicator(strokeWidth: 2.5),
            ),
          )
        : _err != null
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 24),
                  child:
                      Text(_err!, style: const TextStyle(color: AppColors.textWeak)),
                ),
              )
            : _body();

    return SafeArea(
      child: Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.78,
        ),
        padding: EdgeInsets.fromLTRB(16, 12, 16, 12 + bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.border,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 12),
            _header(),
            const SizedBox(height: 14),
            Flexible(child: SingleChildScrollView(child: content)),
          ],
        ),
      ),
    );
  }

  Widget _header() {
    final sender = _data?['sender'] as Map<String, dynamic>?;
    final readCount = _data?['readCount'] as int? ?? 0;
    final total = _data?['total'] as int? ?? 0;
    final isGroup = _data?['conversationType'] == 'group';
    final kind = _data?['kind'] as String? ?? '';
    final content = _data?['content'] as String? ?? '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Expanded(
              child: Text('已读回执',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
              decoration: BoxDecoration(
                color: AppColors.brand.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text('已读 $readCount/$total',
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.brand)),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          '${isGroup ? "群聊" : "单聊"} · ${sender?['name'] ?? "某人"} 发送',
          style: const TextStyle(fontSize: 12.5, color: AppColors.textWeak),
        ),
        if (kind == 'text' && content.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(content,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13, color: AppColors.textSub)),
          ),
      ],
    );
  }

  Widget _body() {
    final rawRead = _data?['read'];
    final rawUnread = _data?['unread'];
    final read = rawRead is List ? rawRead.cast<Map<String, dynamic>>() : <Map<String, dynamic>>[];
    final unread = rawUnread is List ? rawUnread.cast<Map<String, dynamic>>() : <Map<String, dynamic>>[];
    final sections = <_ReceiptSection>[
      _ReceiptSection('已读 ${read.length}', read, true),
      _ReceiptSection('未读 ${unread.length}', unread, false),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final s in sections) ...[
          Padding(
            padding: const EdgeInsets.only(top: 12, bottom: 8),
            child: Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: s.read ? AppColors.brand : AppColors.textWeak,
                  ),
                ),
                const SizedBox(width: 8),
                Text(s.title,
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.text)),
              ],
            ),
          ),
          if (s.members.isEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 16, bottom: 4),
              child: Text(s.read ? '暂无人已读' : '全部已读',
                  style: const TextStyle(fontSize: 12.5, color: AppColors.textWeak)),
            )
          else
            for (final u in s.members)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Row(
                  children: [
                    UserAvatar(
                      name: (u['name'] as String?) ?? '?',
                      size: 34,
                      radius: 12,
                      imageUrl: u['avatar'] as String?,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text((u['name'] as String?) ?? '?',
                          style: const TextStyle(fontSize: 14, color: AppColors.text)),
                    ),
                    if (u['isBot'] == true)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                        decoration: BoxDecoration(
                          color: AppColors.brand.withValues(alpha: 0.16),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Text('机器人',
                            style: TextStyle(
                                fontSize: 9.5, fontWeight: FontWeight.w700, color: AppColors.brand)),
                      ),
                  ],
                ),
              ),
        ],
      ],
    );
  }
}

class _ReceiptSection {
  final String title;
  final List<Map<String, dynamic>> members;
  final bool read;
  const _ReceiptSection(this.title, this.members, this.read);
}

/// 发起投票的底部弹窗：标题 + 动态增删的选项 + 多选/匿名开关。
/// 校验与服务端同口径：标题 ≤60 字、2~10 个选项、每项 ≤30 字 ——
/// 前端先拦一遍省得点了发送才报错。
class _PollCreateSheet extends StatefulWidget {
  final int groupId;
  const _PollCreateSheet({required this.groupId});

  @override
  State<_PollCreateSheet> createState() => _PollCreateSheetState();
}

class _PollCreateSheetState extends State<_PollCreateSheet> {
  final _titleC = TextEditingController();
  final _opts = <TextEditingController>[
    TextEditingController(), TextEditingController(),
  ];
  bool _multi = false;
  bool _anonymous = false;
  bool _busy = false;

  @override
  void dispose() {
    _titleC.dispose();
    for (final c in _opts) {
      c.dispose();
    }
    super.dispose();
  }

  String _msg(Object e) => e.toString().replaceFirst('Exception: ', '');

  void _toast(String s) => ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(s), duration: const Duration(seconds: 2)));

  Future<void> _submit() async {
    final title = _titleC.text.trim();
    if (title.isEmpty) {
      _toast('标题不能为空');
      return;
    }
    if (title.length > 60) {
      _toast('标题最长 60 个字');
      return;
    }
    final options = _opts.map((c) => c.text.trim()).where((s) => s.isNotEmpty).toList();
    if (options.length < 2) {
      _toast('至少填 2 个选项');
      return;
    }
    if (options.any((o) => o.length > 30)) {
      _toast('每个选项最长 30 个字');
      return;
    }
    setState(() => _busy = true);
    try {
      await ImApi().createPoll(widget.groupId,
          title: title, options: options, multi: _multi, anonymous: _anonymous);
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (e) {
      _toast(_msg(e));
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
            18, 16, 18, 16 + MediaQuery.of(context).viewInsets.bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('发起投票',
                style: TextStyle(fontSize: 16.5, fontWeight: FontWeight.w600)),
            const SizedBox(height: 12),
            TextField(
              controller: _titleC,
              autofocus: true,
              maxLength: 60,
              decoration: const InputDecoration(
                hintText: '投票标题（如：团建吃什么）',
                counterText: '',
              ),
            ),
            const SizedBox(height: 6),
            for (var i = 0; i < _opts.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _opts[i],
                        maxLength: 30,
                        decoration: InputDecoration(
                          hintText: '选项 ${i + 1}',
                          counterText: '',
                          isDense: true,
                        ),
                      ),
                    ),
                    // 前两项是骨架，不给出入口；至少留 2 个选项
                    if (_opts.length > 2)
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.remove_circle_outline_rounded,
                            size: 19, color: AppColors.textWeak),
                        onPressed: () => setState(() {
                          _opts[i].dispose();
                          _opts.removeAt(i);
                        }),
                      ),
                  ],
                ),
              ),
            if (_opts.length < 10)
              TextButton.icon(
                onPressed: () => setState(
                    () => _opts.add(TextEditingController())),
                icon: const Icon(Icons.add_rounded, size: 17),
                label: const Text('添加选项', style: TextStyle(fontSize: 13)),
              ),
            const SizedBox(height: 4),
            SwitchListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text('可多选', style: TextStyle(fontSize: 14)),
              value: _multi,
              onChanged: (v) => setState(() => _multi = v),
            ),
            SwitchListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text('匿名投票', style: TextStyle(fontSize: 14)),
              subtitle: const Text('只显示票数，不显示谁投的',
                  style: TextStyle(fontSize: 12, color: AppColors.textSub)),
              value: _anonymous,
              onChanged: (v) => setState(() => _anonymous = v),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _busy ? null : _submit,
                child: Text(_busy ? '发送中…' : '发到群里'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
