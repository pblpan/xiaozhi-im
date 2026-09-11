import 'package:flutter/material.dart';
import 'package:xiaozhi_im_client/api.dart';
import 'package:xiaozhi_im_client/core/theme.dart';
import 'package:xiaozhi_im_client/core/time.dart';
import 'package:xiaozhi_im_client/models.dart';
import 'package:xiaozhi_im_client/screens/friend_templates.dart';
import 'package:xiaozhi_im_client/widgets/avatar.dart';

/// 「新的朋友」：待处理的好友申请（带认证附言）+ 我的好友。
///
/// 点击某个好友时 `Navigator.pop(context, user)`，由会话列表页负责
/// 打开对应的单聊（它持有会话列表与自己的 id）。
class NewFriendsScreen extends StatefulWidget {
  const NewFriendsScreen({super.key});

  @override
  State<NewFriendsScreen> createState() => _NewFriendsScreenState();
}

class _NewFriendsScreenState extends State<NewFriendsScreen> {
  List<FriendRequest> _pending = [];
  List<User> _friends = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  String _errText(Object e) => e is ApiException
      ? e.message
      : e.toString().replaceFirst('Exception: ', '');

  void _toast(String s) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(s), duration: const Duration(seconds: 2)));
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final d = await ImApi().friends();
      if (!mounted) return;
      setState(() {
        _pending = ((d['pending'] as List?) ?? const [])
            .map((e) => FriendRequest.fromJson(e as Map<String, dynamic>))
            .toList();
        _friends = ((d['friends'] as List?) ?? const [])
            .map((e) => User.fromJson(e as Map<String, dynamic>))
            .toList();
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = _errText(e);
      });
    }
  }

  Future<void> _accept(FriendRequest r) async {
    try {
      await ImApi().acceptFriend(r.userId);
      _toast('已添加 ${r.display}');
      await _load();
    } catch (e) {
      _toast(_errText(e));
    }
  }

  Future<void> _reject(FriendRequest r) async {
    try {
      await ImApi().rejectFriend(r.userId);
      _toast('已拒绝');
      await _load();
    } catch (e) {
      _toast(_errText(e));
    }
  }

  Future<void> _openTemplates() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const FriendTemplatesScreen()),
    );
  }

  @override
  Widget build(BuildContext context) => DefaultTabController(
        length: 2,
        child: Scaffold(
          appBar: AppBar(
            title: const Text('新的朋友'),
            actions: [
              IconButton(
                tooltip: '认证消息模板',
                onPressed: _openTemplates,
                icon: const Icon(Icons.article_outlined),
              ),
            ],
            // 用 DefaultTabController 托管切换：TabBar 的 currentIndex 参数
            // 只在配合 TabController 时才存在，自己维护 index 会编译不过
            bottom: TabBar(
              tabs: [
                Tab(text: _pending.isEmpty ? '待处理' : '待处理 ${_pending.length}'),
                Tab(text: _friends.isEmpty ? '我的好友' : '我的好友 ${_friends.length}'),
              ],
            ),
          ),
          body: _loading
              ? const Center(
                  child: SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2)))
              : _error != null
                  ? _errorView()
                  : TabBarView(children: [_pendingList(), _friendList()]),
        ),
      );

  Widget _errorView() => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline_rounded, size: 44, color: AppColors.textWeak),
            const SizedBox(height: 12),
            Text(_error!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppColors.textSub, fontSize: 13.5)),
            const SizedBox(height: 10),
            FilledButton(onPressed: _load, child: const Text('重试')),
          ],
        ),
      );

  Widget _empty(String title, String sub) => Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 40),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.person_add_alt_1_rounded,
                  size: 46, color: AppColors.textWeak.withValues(alpha: 0.5)),
              const SizedBox(height: 12),
              Text(title,
                  style: const TextStyle(
                      fontSize: 14.5, fontWeight: FontWeight.w600, color: AppColors.textSub)),
              const SizedBox(height: 6),
              Text(sub,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 12.5, color: AppColors.textWeak)),
            ],
          ),
        ),
      );

  Widget _pendingList() {
    if (_pending.isEmpty) {
      return _empty('暂无好友申请', '别人向你发起申请时会出现在这里');
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(vertical: 6),
        itemCount: _pending.length,
        separatorBuilder: (_, __) => const Divider(
            height: 1, indent: 74, endIndent: 14, color: AppColors.divider),
        itemBuilder: (_, i) {
          final r = _pending[i];
          return Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                UserAvatar(name: r.display, size: 46, imageUrl: r.avatar),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(r.display,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontSize: 15, fontWeight: FontWeight.w600)),
                          ),
                          const SizedBox(width: 8),
                          if (r.createdAt > 0)
                            Text(TimeFmt.listStamp(r.createdAt),
                                style: const TextStyle(
                                    fontSize: 11, color: AppColors.textWeak)),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        r.message.isEmpty ? '对方没有填写验证信息' : r.message,
                        style: TextStyle(
                          fontSize: 13,
                          height: 1.35,
                          color: r.message.isEmpty
                              ? AppColors.textWeak
                              : AppColors.textSub,
                          fontStyle:
                              r.message.isEmpty ? FontStyle.italic : FontStyle.normal,
                        ),
                      ),
                      if ((r.signature ?? '').isNotEmpty) ...[
                        const SizedBox(height: 3),
                        Text(r.signature!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 11.5, color: AppColors.textWeak)),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Column(
                  children: [
                    FilledButton(
                      onPressed: () => _accept(r),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(64, 32),
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                        textStyle: const TextStyle(fontSize: 13),
                      ),
                      child: const Text('接受'),
                    ),
                    const SizedBox(height: 4),
                    TextButton(
                      onPressed: () => _reject(r),
                      style: TextButton.styleFrom(
                        minimumSize: const Size(64, 30),
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        textStyle: const TextStyle(fontSize: 12.5),
                      ),
                      child: const Text('拒绝',
                          style: TextStyle(color: AppColors.textWeak)),
                    ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _friendList() {
    if (_friends.isEmpty) {
      return _empty('还没有好友', '通过搜索账号或昵称，向对方发送好友申请');
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(vertical: 6),
        itemCount: _friends.length,
        separatorBuilder: (_, __) => const Divider(
            height: 1, indent: 74, endIndent: 14, color: AppColors.divider),
        itemBuilder: (_, i) {
          final u = _friends[i];
          return ListTile(
            leading: UserAvatar(name: u.display, size: 46, imageUrl: u.avatar),
            title: Text(u.display,
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
            subtitle: Text(
              (u.signature ?? '').isNotEmpty ? u.signature! : '@${u.username}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12.5, color: AppColors.textWeak),
            ),
            trailing: const Icon(Icons.chat_bubble_outline_rounded,
                size: 19, color: AppColors.textSub),
            onTap: () => Navigator.pop(context, u),
          );
        },
      ),
    );
  }
}
