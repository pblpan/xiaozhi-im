import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:xiaozhi_im_client/api.dart';
import 'package:xiaozhi_im_client/core/config.dart';
import 'package:xiaozhi_im_client/core/media.dart';
import 'package:xiaozhi_im_client/core/theme.dart';
import 'package:xiaozhi_im_client/core/time.dart';
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

  @override
  void initState() {
    super.initState();
    _ctrl.addListener(() {
      final v = _ctrl.text.trim().isNotEmpty;
      if (v != _hasText && mounted) setState(() => _hasText = v);
    });
    _loadMsgs();
    SocketService().stream.listen(_onEvent);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _scrollC.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _loadMsgs() async {
    try {
      final list = await ImApi().messages(widget.conv.id);
      if (!mounted) return;
      setState(() {
        _msgs = list.map((e) => Message.fromJson(e)).toList();
        _loading = false;
      });
      _scroll();
    } catch (e) {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _onEvent(dynamic e) {
    if (e is Map && e['type'] == 'message:new') {
      final m = Message.fromJson(e['message']);
      if (m.conversationId == widget.conv.id) {
        setState(() => _msgs.add(m));
        _scroll();
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
                  Text(
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
      body: Column(
        children: [
          Expanded(child: _body()),
          _composer(canSend),
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
            ),
          ],
        );
      },
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
