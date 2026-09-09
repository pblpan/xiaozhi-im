import 'package:flutter/material.dart';
import 'package:xiaozhi_im_client/api.dart';
import 'package:xiaozhi_im_client/core/storage.dart';
import 'package:xiaozhi_im_client/models.dart';
import 'package:xiaozhi_im_client/socket.dart';
import 'package:xiaozhi_im_client/screens/chat.dart';
import 'package:xiaozhi_im_client/screens/login.dart';

class ConversationsScreen extends StatefulWidget {
  const ConversationsScreen({super.key});
  @override
  State<ConversationsScreen> createState() => _ConversationsScreenState();
}

class _ConversationsScreenState extends State<ConversationsScreen> {
  List<Conversation> _conv = [];
  Conversation? _sel;
  int _myId = 0;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      final me = await ImApi().me();
      _myId = me['user']['id'];
      await SocketService().connect();
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('加载失败: $e')));
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
    SocketService().stream.listen(_onEvent);
  }

  Future<void> _load() async {
    final list = await ImApi().conversations();
    setState(() => _conv = list.map((e) => Conversation.fromJson(e)).toList());
  }

  void _onEvent(dynamic e) {
    if (e is Map && e['type'] == 'message:new') _load();
  }

  void _logout() async {
    await Storage.clear();
    SocketService().disconnect();
    if (mounted) {
      Navigator.pushReplacement(
          context, MaterialPageRoute(builder: (_) => const LoginScreen()));
    }
  }

  void _openAdd() {
    final q = TextEditingController();
    List<dynamic> results = [];
    showDialog(
      context: context,
      builder: (d) => StatefulBuilder(
        builder: (c, set) => AlertDialog(
          title: const Text('添加好友 / 发起聊天'),
          content: SizedBox(
            width: 360,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: q,
                  decoration: const InputDecoration(labelText: '搜索账号或昵称'),
                  onChanged: (v) async {
                    if (v.trim().length < 1) return;
                    try {
                      final r = await ImApi().search(v.trim());
                      set(() => results = r);
                    } catch (_) {}
                  },
                ),
                const SizedBox(height: 10),
                ...results.map((u) => ListTile(
                      title: Text(u['nickname'] ?? u['username']),
                      subtitle: Text('@${u['username']}'),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          TextButton(
                            onPressed: () async {
                              await ImApi().friendRequest(u['id']);
                              if (mounted) {
                                ScaffoldMessenger.of(context)
                                    .showSnackBar(const SnackBar(content: Text('已发送好友请求')));
                              }
                            },
                            child: const Text('加好友'),
                          ),
                          TextButton(
                            onPressed: () async {
                              final r = await ImApi().dm(u['id']);
                              final conv = Conversation(
                                  id: r['conversationId'], type: 'dm', title: u['nickname']);
                              Navigator.pop(d);
                              if (!mounted) return;
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => ChatScreen(
                                    conv: conv,
                                    myId: _myId,
                                    peerName: u['nickname'],
                                  ),
                                ),
                              );
                            },
                            child: const Text('发消息'),
                          ),
                        ],
                      ),
                    )),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(d), child: const Text('关闭')),
          ],
        ),
      ),
    );
  }

  Widget _listPane(BuildContext context) => Column(
        children: [
          ListTile(
            leading: const Icon(Icons.person_add),
            title: const Text('添加好友 / 发起聊天'),
            onTap: _openAdd,
          ),
          const Divider(height: 1),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : ListView.builder(
                    itemCount: _conv.length,
                    itemBuilder: (c, i) {
                      final cv = _conv[i];
                      return ListTile(
                        leading: CircleAvatar(
                          backgroundColor: const Color(0xFF5865F2),
                          child: Text((cv.title ?? '?').substring(0, 1)),
                        ),
                        title: Text(cv.title ?? (cv.type == 'group' ? '群聊' : '会话')),
                        subtitle: Text(cv.lastContent ?? ''),
                        selected: _sel?.id == cv.id,
                        onTap: () {
                          if (MediaQuery.of(context).size.width > 720) {
                            setState(() => _sel = cv);
                          } else {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => ChatScreen(
                                  conv: cv,
                                  myId: _myId,
                                  peerName: cv.title,
                                ),
                              ),
                            );
                          }
                        },
                      );
                    },
                  ),
          ),
        ],
      );

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: const Text('小智 IM'),
          actions: [IconButton(onPressed: _logout, icon: const Icon(Icons.logout))],
        ),
        body: LayoutBuilder(
          builder: (c, box) {
            final wide = box.maxWidth > 720;
            if (!wide) return _listPane(context);
            return Row(
              children: [
                SizedBox(width: 320, child: _listPane(context)),
                const VerticalDivider(width: 1),
                Expanded(
                  child: _sel == null
                      ? const Center(
                          child: Text('选择一个会话开始聊天',
                              style: TextStyle(color: Colors.grey)))
                      : ChatScreen(
                          conv: _sel!,
                          myId: _myId,
                          peerName: _sel!.title,
                        ),
                ),
              ],
            );
          },
        ),
      );
}
