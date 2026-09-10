import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:xiaozhi_im_client/api.dart';
import 'package:xiaozhi_im_client/core/config.dart';
import 'package:xiaozhi_im_client/core/media.dart';
import 'package:xiaozhi_im_client/core/theme.dart';
import 'package:xiaozhi_im_client/core/time.dart';
import 'package:xiaozhi_im_client/core/voice.dart';
import 'package:xiaozhi_im_client/models.dart';
import 'package:xiaozhi_im_client/socket.dart';
import 'package:xiaozhi_im_client/widgets/avatar.dart';
import 'package:xiaozhi_im_client/widgets/bubble.dart';

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
      setState(() {
        _msgs = list;
        _readMap = {
          for (final m in members)
            (m['user_id'] as int): ((m['last_read_id'] ?? 0) as int),
        };
        _recallWindowMs = (d['recallWindowMs'] as int?) ?? 120000;
        _loading = false;
      });
      _scroll();
      _markRead();
    } catch (e) {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 上报已读（进入会话 / 收到对方新消息时）
  Future<void> _markRead() async {
    try {
      final r = await ImApi().markRead(widget.conv.id);
      final lr = (r['lastReadId'] as int?) ?? 0;
      if (mounted) setState(() => _readMap[widget.myId] = lr);
    } catch (_) {
      // 已读上报失败不打扰用户，下次进会话会重试
    }
  }

  void _onTextChanged() {
    final v = _ctrl.text.trim().isNotEmpty;
    if (v != _hasText && mounted) setState(() => _hasText = v);
    if (!v) return;
    // 输入中状态：2.5 秒节流，避免每个字符都发帧
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastTypingSent > 2500) {
      _lastTypingSent = now;
      SocketService().send({'type': 'typing', 'conversationId': widget.conv.id});
    }
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

    if (type == 'message:edit') {
      if (e['conversationId'] != widget.conv.id) return;
      final id = e['messageId'];
      setState(() {
        final i = _msgs.indexWhere((x) => x.id == id);
        if (i >= 0) {
          _msgs[i] = _msgs[i]
              .copyWith(content: e['content'] as String?, edited: true);
        }
      });
      return;
    }

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
    _ctrl.clear();
    setState(() => _hasText = false);
    try {
      final m = await ImApi().sendMessage(widget.conv.id, 'text', t);
      if (!mounted) return;
      setState(() => _msgs.add(Message.fromJson(m)));
      _scroll();
    } catch (e) {
      if (mounted) _toast('发送失败: ${_msg(e)}');
    }
  }

  void _attach() async {
    final files = await FilePicker.pickFiles();
    if (files.isEmpty) return;
    final picked = files.first;
    final path = picked.path;
    if (path == null) return;
    setState(() => _busy = true);
    try {
      final orig = File(path);
      final origLen = await orig.length();
      final toUpload = await Media.prepareForUpload(orig); // 内网原图 / 外网压缩
      final up = await ImApi().upload(toUpload);

      final name = (up['name'] ?? path).toString();
      final isImg = (up['mime'] ?? '').toString().startsWith('image') ||
          Media.isImagePath(name) ||
          Media.isImagePath(path);
      // 图片消息存 /files/xxx 访问路径，文件消息存原始文件名
      final content = isImg ? (up['url'] ?? name).toString() : name;

      final m = await ImApi()
          .sendMessage(widget.conv.id, isImg ? 'image' : 'file', content, up['id']);
      if (!mounted) return;
      setState(() => _msgs.add(Message.fromJson(m)));
      _scroll();

      if (toUpload.path != orig.path) {
        final newLen = await toUpload.length();
        _toast('已压缩上传（${TimeFmt.size(origLen)} → ${TimeFmt.size(newLen)}）');
      }
    } catch (e) {
      if (mounted) _toast('发送失败: ${_msg(e)}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
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

  bool _canEdit(Message m) =>
      m.senderId == widget.myId && !m.deleted && m.kind == 'text';

  void _showMsgMenu(Message m) {
    final canEdit = _canEdit(m);
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
            if (canEdit)
              _menuItem(Icons.edit_rounded, '编辑', () {
                Navigator.pop(ctx);
                _editMsg(m);
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

  Future<void> _editMsg(Message m) async {
    final ctrl = TextEditingController(text: m.content ?? '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('编辑消息'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          minLines: 1,
          maxLines: 5,
          decoration: const InputDecoration(hintText: '输入新内容'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('保存')),
        ],
      ),
    );
    if (ok != true) return;
    final text = ctrl.text.trim();
    if (text.isEmpty) {
      _toast('内容不能为空');
      return;
    }
    try {
      await ImApi().editMessage(widget.conv.id, m.id, text);
      if (!mounted) return;
      setState(() {
        final i = _msgs.indexWhere((x) => x.id == m.id);
        if (i >= 0) _msgs[i] = _msgs[i].copyWith(content: text, edited: true);
      });
    } catch (e) {
      if (mounted) _toast('编辑失败: ${_msg(e)}');
    }
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

  // ---------- 渲染 ----------

  /// 已读水位：其他成员都读到哪（无其他成员返回 -1 = 不显示标签）
  int get _watermark {
    final others =
        _readMap.entries.where((e) => e.key != widget.myId).toList();
    if (others.isEmpty) return -1;
    if (widget.conv.type == 'group') {
      return others.map((e) => e.value).reduce((a, b) => a < b ? a : b);
    }
    return others.first.value;
  }

  /// 只在「自己发的最后一条未撤回消息」上显示已读/未读
  String? _readLabelFor(int i) {
    final m = _msgs[i];
    if (m.senderId != widget.myId || m.deleted) return null;
    final hasLaterMine = _msgs
        .skip(i + 1)
        .any((x) => x.senderId == widget.myId && !x.deleted);
    if (hasLaterMine) return null;
    final wm = _watermark;
    if (wm < 0) return null;
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

  @override
  Widget build(BuildContext context) {
    final canSend = _hasText && !_busy;
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: !widget.embedded,
        titleSpacing: widget.embedded ? 16 : 0,
        title: Row(
          children: [
            UserAvatar(name: _title, size: 36, radius: 12),
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
                          widget.conv.type == 'group' ? '群聊' : '私信',
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
          IconButton(
            tooltip: '刷新',
            onPressed: _loadMsgs,
            icon: const Icon(Icons.refresh_rounded),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: Stack(
        children: [
          Column(
            children: [
              Expanded(child: _body()),
              _composer(canSend),
            ],
          ),
          if (_recording) _recordOverlay(),
        ],
      ),
    );
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
              senderName: m.senderId == widget.myId ? null : widget.peerName,
              baseUrl: Config.baseUrl,
              showTime: _showTimeAt(i),
              readLabel: _readLabelFor(i),
              onLongPress: () => _showMsgMenu(m),
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
              const SizedBox(width: 8),
              _micButton(),
              const SizedBox(width: 8),
              Expanded(
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
                  ),
                ),
              ),
              const SizedBox(width: 8),
              _sendButton(canSend),
            ],
          ),
        ),
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
