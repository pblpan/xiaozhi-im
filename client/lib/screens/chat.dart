import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:xiaozhi_im_client/api.dart';
import 'package:xiaozhi_im_client/core/config.dart';
import 'package:xiaozhi_im_client/models.dart';
import 'package:xiaozhi_im_client/socket.dart';
import 'package:xiaozhi_im_client/widgets/bubble.dart';

class ChatScreen extends StatefulWidget {
  final Conversation conv;
  final int myId;
  final String? peerName;
  const ChatScreen({super.key, required this.conv, required this.myId, this.peerName});
  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  List<Message> _msgs = [];
  final _ctrl = TextEditingController();
  final _scrollC = ScrollController();
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _loadMsgs();
    SocketService().stream.listen(_onEvent);
  }

  Future<void> _loadMsgs() async {
    final list = await ImApi().messages(widget.conv.id);
    setState(() => _msgs = list.map((e) => Message.fromJson(e)).toList());
    _scroll();
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
    try {
      final m = await ImApi().sendMessage(widget.conv.id, 'text', t);
      setState(() => _msgs.add(Message.fromJson(m)));
      _scroll();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('发送失败: $e')));
    }
  }

  void _attach() async {
    final files = await FilePicker.pickFiles();
    if (files.isEmpty) return;
    final picked = files.first;
    if (picked.path == null) return;
    setState(() => _busy = true);
    try {
      final f = File(picked.path!);
      final up = await ImApi().upload(f);
      final kind = (up['mime'] ?? '').startsWith('image') ? 'image' : 'file';
      final m = await ImApi().sendMessage(widget.conv.id, kind, up['name'], up['id']);
      setState(() => _msgs.add(Message.fromJson(m)));
      _scroll();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('发送失败: $e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(widget.conv.title ?? widget.peerName ?? '会话')),
        body: Column(
          children: [
            Expanded(
              child: ListView.builder(
                controller: _scrollC,
                padding: const EdgeInsets.all(12),
                itemCount: _msgs.length,
                itemBuilder: (c, i) {
                  final m = _msgs[i];
                  return MessageBubble(
                    msg: m,
                    mine: m.senderId == widget.myId,
                    senderName: m.senderId == widget.myId ? null : widget.peerName,
                    baseUrl: Config.baseUrl,
                  );
                },
              ),
            ),
            SafeArea(
              child: Row(
                children: [
                  IconButton(onPressed: _busy ? null : _attach, icon: const Icon(Icons.attach_file)),
                  Expanded(
                    child: TextField(
                      controller: _ctrl,
                      decoration: const InputDecoration(hintText: '输入消息', border: OutlineInputBorder()),
                      onSubmitted: (_) => _send(),
                    ),
                  ),
                  IconButton(onPressed: _send, icon: const Icon(Icons.send)),
                ],
              ),
            ),
          ],
        ),
      );
}
