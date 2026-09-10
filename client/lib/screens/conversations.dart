import 'package:flutter/material.dart';
import 'package:xiaozhi_im_client/api.dart';
import 'package:xiaozhi_im_client/core/media.dart';
import 'package:xiaozhi_im_client/core/storage.dart';
import 'package:xiaozhi_im_client/core/theme.dart';
import 'package:xiaozhi_im_client/core/time.dart';
import 'package:xiaozhi_im_client/models.dart';
import 'package:xiaozhi_im_client/socket.dart';
import 'package:xiaozhi_im_client/screens/chat.dart';
import 'package:xiaozhi_im_client/screens/favorites.dart';
import 'package:xiaozhi_im_client/screens/login.dart';
import 'package:xiaozhi_im_client/screens/search.dart';
import 'package:xiaozhi_im_client/widgets/avatar.dart';
import 'package:xiaozhi_im_client/widgets/server_settings.dart';

class ConversationsScreen extends StatefulWidget {
  const ConversationsScreen({super.key});
  @override
  State<ConversationsScreen> createState() => _ConversationsScreenState();
}

class _ConversationsScreenState extends State<ConversationsScreen> {
  List<Conversation> _all = [];
  Conversation? _sel;
  int _myId = 0;
  bool _loading = true;
  String? _error;
  String _q = '';
  final _qCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _qCtrl.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final me = await ImApi().me();
      _myId = me['user']['id'];
      await SocketService().connect();
      await _load();
      SocketService().stream.listen(_onEvent);
    } catch (e) {
      if (mounted) setState(() => _error = _msg(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _load() async {
    final list = await ImApi().conversations();
    if (!mounted) return;
    setState(() {
      _all = list.map((e) => Conversation.fromJson(e)).toList();
      // 按最后活跃时间倒序
      _all.sort((a, b) => (b.lastAt ?? b.id).compareTo(a.lastAt ?? a.id));
    });
  }

  void _onEvent(dynamic e) {
    if (e is! Map) return;
    const refreshOn = {
      'message:new', // 新消息：刷新未读与预览
      'message:recall', // 撤回后刷新预览
      'message:read', // 已读推进：未读数变化
      'conversation:pin', // 置顶变更
      'group:updated', // 群名 / 公告 / 成员变更
      'group:kicked', // 自己被移出群
      'group:invited', // 被拉进新群
    };
    if (refreshOn.contains(e['type'])) _load();
  }

  List<Conversation> get _visible {
    if (_q.trim().isEmpty) return _all;
    final k = _q.trim().toLowerCase();
    return _all
        .where((c) =>
            (c.title ?? '').toLowerCase().contains(k) ||
            (c.lastContent ?? '').toLowerCase().contains(k))
        .toList();
  }

  String _msg(Object e) =>
      e.toString().replaceFirst('Exception: ', '');

  void _logout() async {
    await Storage.clear();
    ImApi().clearToken();
    SocketService().disconnect();
    if (mounted) {
      Navigator.pushReplacement(
          context, MaterialPageRoute(builder: (_) => const LoginScreen()));
    }
  }

  /// 修改服务器地址：换地址后旧 token 失效，回到登录页
  Future<void> _openServer() async {
    final changed = await showServerSettings(context);
    if (changed != true) return;
    await Storage.clear();
    ImApi().clearToken();
    SocketService().disconnect();
    if (mounted) {
      Navigator.pushReplacement(
          context, MaterialPageRoute(builder: (_) => const LoginScreen()));
    }
  }

  Future<void> _openChat(Conversation cv) async {
    if (MediaQuery.of(context).size.width > 720) {
      setState(() => _sel = cv);
      return;
    }
    await Navigator.push(
      context,
      MaterialPageRoute(
          builder: (_) => ChatScreen(conv: cv, myId: _myId, peerName: cv.title)),
    );
    _load(); // 返回后刷新最后消息
  }

  // ---------------- 消息搜索 ----------------
  Future<void> _openFavorites() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => FavoritesScreen(myId: _myId)),
    );
    if (mounted) _load();
  }

  Future<void> _openSearch() async {
    final cid = await Navigator.push<int>(
      context,
      MaterialPageRoute(builder: (_) => const SearchScreen()),
    );
    if (cid == null || !mounted) return;

    Conversation? cv;
    for (final c in _all) {
      if (c.id == cid) {
        cv = c;
        break;
      }
    }
    // 会话可能还没加载进来（刚建的会话），拉一次列表再找
    if (cv == null) {
      await _load();
      if (!mounted) return;
      for (final c in _all) {
        if (c.id == cid) {
          cv = c;
          break;
        }
      }
    }
    if (cv != null) await _openChat(cv);
  }

  // ---------------- 添加好友 / 发起聊天 ----------------
  void _openAdd() {
    final q = TextEditingController();
    List<dynamic> results = [];
    bool searching = false;

    showDialog(
      context: context,
      builder: (d) => StatefulBuilder(
        builder: (c, set) => AlertDialog(
          titlePadding: const EdgeInsets.fromLTRB(20, 20, 20, 6),
          contentPadding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
          title: const Text('添加好友 / 发起聊天'),
          content: SizedBox(
            width: 380,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: q,
                  autofocus: true,
                  decoration: InputDecoration(
                    hintText: '搜索账号或昵称',
                    prefixIcon: const Icon(Icons.search_rounded,
                        size: 20, color: AppColors.textWeak),
                    suffixIcon: q.text.isEmpty
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.close_rounded, size: 18),
                            onPressed: () {
                              q.clear();
                              set(() {
                                results = [];
                                searching = false;
                              });
                            },
                          ),
                  ),
                  onChanged: (v) async {
                    if (v.trim().isEmpty) {
                      set(() {
                        results = [];
                        searching = false;
                      });
                      return;
                    }
                    set(() => searching = true);
                    try {
                      final r = await ImApi().search(v.trim());
                      set(() {
                        results = r;
                        searching = false;
                      });
                    } catch (_) {
                      set(() => searching = false);
                    }
                  },
                ),
                const SizedBox(height: 8),
                if (searching)
                  const Padding(
                    padding: EdgeInsets.all(18),
                    child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2)),
                  )
                else if (results.isEmpty && q.text.isNotEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 22),
                    child: Text('没有找到匹配的用户',
                        style: TextStyle(color: AppColors.textWeak)),
                  )
                else
                  Flexible(
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: results.map((u) {
                          final name = u['nickname'] ?? u['username'] ?? '用户';
                          return Container(
                            margin: const EdgeInsets.only(bottom: 6),
                            decoration: BoxDecoration(
                              color: AppColors.surface,
                              borderRadius:
                                  BorderRadius.circular(AppRadii.md),
                            ),
                            child: ListTile(
                              contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 2),
                              leading: UserAvatar(name: name, size: 42),
                              title: Text(name,
                                  style: const TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w600)),
                              subtitle: Text('@${u['username']}',
                                  style: const TextStyle(fontSize: 12.5)),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  TextButton(
                                    onPressed: () async {
                                      try {
                                        await ImApi().friendRequest(u['id']);
                                        if (mounted) {
                                          _toast('已发送好友请求');
                                        }
                                      } catch (e) {
                                        if (mounted) _toast(_msg(e));
                                      }
                                    },
                                    child: const Text('加好友'),
                                  ),
                                  const SizedBox(width: 4),
                                  FilledButton(
                                    onPressed: () async {
                                      try {
                                        final r = await ImApi().dm(u['id']);
                                        final conv = Conversation(
                                            id: r['conversationId'],
                                            type: 'dm',
                                            title: name);
                                        if (!context.mounted) return;
                                        Navigator.pop(d);
                                        await _load();
                                        await _openChat(conv);
                                      } catch (e) {
                                        if (mounted) _toast(_msg(e));
                                      }
                                    },
                                    style: FilledButton.styleFrom(
                                      backgroundColor: AppColors.brand,
                                      foregroundColor: Colors.white,
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 14),
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(
                                            AppRadii.sm),
                                      ),
                                    ),
                                    child: const Text('发消息'),
                                  ),
                                ],
                              ),
                            ),
                          );
                        }).toList(),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(d), child: const Text('关闭')),
          ],
        ),
      ),
    );
  }

  void _toast(String s) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));

  // ---------------- 侧边栏 ----------------
  String _preview(Conversation cv) {
    final c = cv.lastContent ?? '';
    if (c.isEmpty) return '还没有消息';
    if (c.startsWith('/files/')) {
      return Media.isImagePath(c) ? '[图片]' : '[文件]';
    }
    return c;
  }

  Widget _searchBox() => Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
        child: TextField(
          controller: _qCtrl,
          onChanged: (v) => setState(() => _q = v),
          style: const TextStyle(fontSize: 14),
          decoration: InputDecoration(
            hintText: '搜索会话',
            isDense: true,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            prefixIcon: const Icon(Icons.search_rounded,
                size: 19, color: AppColors.textWeak),
            suffixIcon: _q.isEmpty
                ? null
                : IconButton(
                    icon: const Icon(Icons.close_rounded, size: 17),
                    onPressed: () {
                      _qCtrl.clear();
                      setState(() => _q = '');
                    },
                  ),
          ),
        ),
      );

  Widget _tile(Conversation cv) {
    final name = cv.title ?? (cv.type == 'group' ? '群聊' : '会话');
    final selected = _sel?.id == cv.id;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Material(
        color: selected ? AppColors.surfaceHi : Colors.transparent,
        borderRadius: BorderRadius.circular(AppRadii.md),
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadii.md),
          onTap: () => _openChat(cv),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 10, 12, 10),
            child: Row(
              children: [
                UserAvatar(name: name, size: 46, radius: 15),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                                color: AppColors.text,
                              ),
                            ),
                          ),
                          if (cv.hasMention && cv.unread > 0)
                            Container(
                              margin: const EdgeInsets.only(left: 6),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 5, vertical: 1.5),
                              decoration: BoxDecoration(
                                color: const Color(0xFFF4685E)
                                    .withValues(alpha: 0.18),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: const Text(
                                '有人@我',
                                style: TextStyle(
                                    fontSize: 10.5,
                                    color: Color(0xFFF4685E),
                                    fontWeight: FontWeight.w600),
                              ),
                            ),
                          if (cv.unread > 0)
                            Container(
                              margin: const EdgeInsets.only(left: 6),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 2),
                              constraints: const BoxConstraints(minWidth: 19),
                              decoration: BoxDecoration(
                                color: AppColors.danger,
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Text(
                                cv.unread > 99 ? '99+' : '${cv.unread}',
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 10.5,
                                    height: 1.25,
                                    fontWeight: FontWeight.w600),
                              ),
                            ),
                          if (cv.lastAt != null)
                            Padding(
                              padding: const EdgeInsets.only(left: 6),
                              child: Text(
                                TimeFmt.listStamp(cv.lastAt!),
                                style: const TextStyle(
                                    fontSize: 11.5, color: AppColors.textWeak),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _preview(cv),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 13, color: AppColors.textSub),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _empty() => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const BrandLogo(size: 62),
            const SizedBox(height: 18),
            const Text('还没有会话',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            const Text('搜索好友，发起第一次聊天',
                style: TextStyle(color: AppColors.textSub, fontSize: 13)),
            const SizedBox(height: 20),
            SizedBox(
              width: 160,
              child: FilledButton.icon(
                onPressed: _openAdd,
                icon: const Icon(Icons.person_add_alt_rounded, size: 19),
                label: const Text('发起聊天'),
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.brand,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 13),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppRadii.md)),
                ),
              ),
            ),
          ],
        ),
      );

  Widget _listPane() {
    if (_loading) {
      return const Center(
          child: SizedBox(
              width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)));
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off_rounded,
                  size: 42, color: AppColors.textWeak),
              const SizedBox(height: 12),
              Text(_error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: AppColors.textSub, fontSize: 13)),
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: _init,
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: const Text('重试'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.brand,
                  side: const BorderSide(color: AppColors.brand),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppRadii.md)),
                ),
              ),
            ],
          ),
        ),
      );
    }

    final items = _visible;
    return RefreshIndicator(
      color: AppColors.brand,
      backgroundColor: AppColors.surfaceHi,
      onRefresh: _load,
      child: Column(
        children: [
          _searchBox(),
          const Divider(height: 1),
          Expanded(
            child: items.isEmpty
                ? (_q.isEmpty
                    ? _empty()
                    : const Center(
                        child: Text('没有匹配的会话',
                            style:
                                TextStyle(color: AppColors.textWeak, fontSize: 13))))
                : ListView.builder(
                    padding: const EdgeInsets.only(top: 6, bottom: 12),
                    itemCount: items.length,
                    itemBuilder: (c, i) => _tile(items[i]),
                  ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          titleSpacing: 16,
          title: const Row(
            children: [
              BrandLogo(size: 28),
              SizedBox(width: 10),
              Text('小智 IM',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            ],
          ),
          actions: [
            ValueListenableBuilder<ConnState>(
              valueListenable: SocketService().state,
              builder: (_, s, __) {
                final (color, tip) = switch (s) {
                  ConnState.online => (AppColors.online, '实时连接正常（点击重连）'),
                  ConnState.connecting => (AppColors.brand, '正在连接…'),
                  ConnState.offline => (AppColors.danger, '连接已断开（点击重连）'),
                  _ => (AppColors.textWeak, '未连接'),
                };
                return IconButton(
                  tooltip: tip,
                  onPressed: () => SocketService().reconnect(),
                  icon: Icon(Icons.circle, size: 11, color: color),
                );
              },
            ),
            IconButton(
              tooltip: '搜索聊天记录',
              onPressed: _openSearch,
              icon: const Icon(Icons.search_rounded),
            ),
            IconButton(
              tooltip: '发起聊天',
              onPressed: _openAdd,
              icon: const Icon(Icons.person_add_alt_rounded),
            ),
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert_rounded),
              onSelected: (v) {
                if (v == 'refresh') _load();
                if (v == 'fav') _openFavorites();
                if (v == 'server') _openServer();
                if (v == 'logout') _logout();
              },
              itemBuilder: (_) => const [
                PopupMenuItem(
                    value: 'refresh',
                    child: Row(children: [
                      Icon(Icons.refresh_rounded, size: 19),
                      SizedBox(width: 10),
                      Text('刷新列表')
                    ])),
                PopupMenuItem(
                    value: 'fav',
                    child: Row(children: [
                      Icon(Icons.star_border_rounded, size: 19),
                      SizedBox(width: 10),
                      Text('我的收藏')
                    ])),
                PopupMenuItem(
                    value: 'server',
                    child: Row(children: [
                      Icon(Icons.dns_rounded, size: 19),
                      SizedBox(width: 10),
                      Text('服务器设置')
                    ])),
                PopupMenuItem(
                    value: 'logout',
                    child: Row(children: [
                      Icon(Icons.logout_rounded, size: 19, color: AppColors.danger),
                      SizedBox(width: 10),
                      Text('退出登录', style: TextStyle(color: AppColors.danger))
                    ])),
              ],
            ),
            const SizedBox(width: 6),
          ],
        ),
        body: LayoutBuilder(
          builder: (c, box) {
            final wide = box.maxWidth > 720;
            if (!wide) return _listPane();
            return Row(
              children: [
                SizedBox(width: 320, child: _listPane()),
                const VerticalDivider(width: 1),
                Expanded(
                  child: _sel == null
                      ? Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.forum_rounded,
                                  size: 56,
                                  color: AppColors.textWeak
                                      .withValues(alpha: 0.5)),
                              const SizedBox(height: 14),
                              const Text('选择一个会话开始聊天',
                                  style: TextStyle(
                                      color: AppColors.textSub, fontSize: 14)),
                            ],
                          ),
                        )
                      : ChatScreen(
                          key: ValueKey(_sel!.id),
                          conv: _sel!,
                          myId: _myId,
                          peerName: _sel!.title,
                          embedded: true,
                        ),
                ),
              ],
            );
          },
        ),
      );
}
