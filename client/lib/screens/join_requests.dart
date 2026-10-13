import 'package:flutter/material.dart';
import 'package:xiaozhi_im_client/api.dart';
import 'package:xiaozhi_im_client/core/theme.dart';
import 'package:xiaozhi_im_client/widgets/avatar.dart';

/// 入群审批（群主/管理员）：审批模式下普通成员拉的人先挂这里等点头。
/// 数据形状见服务端 GET /groups/:id/joinRequests —— user_* 是申请人，
/// inviter_* 是拉他进来的人（可能为空，比如以后开放自主申请）。
class JoinRequestsScreen extends StatefulWidget {
  final int groupId;
  final String groupName;
  const JoinRequestsScreen(
      {super.key, required this.groupId, required this.groupName});

  @override
  State<JoinRequestsScreen> createState() => _JoinRequestsScreenState();
}

class _JoinRequestsScreenState extends State<JoinRequestsScreen> {
  List<Map<String, dynamic>> _items = [];
  bool _loading = true;
  final Set<int> _busy = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final items = await ImApi().joinRequests(widget.groupId);
      if (!mounted) return;
      setState(() {
        _items = items.cast<Map<String, dynamic>>();
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _toast(e.toString().replaceFirst('Exception: ', ''));
    }
  }

  void _toast(String s) => ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(s), duration: const Duration(seconds: 2)));

  Future<void> _handle(Map<String, dynamic> r, bool approve) async {
    final id = r['id'] as int;
    final name = ((r['user_nickname'] as String?)?.isNotEmpty == true
            ? r['user_nickname']
            : (r['user_username'] ?? '对方')) as String;
    setState(() => _busy.add(id));
    try {
      if (approve) {
        await ImApi().approveJoinRequest(widget.groupId, id);
        _toast('已通过，$name 已加入群聊');
      } else {
        await ImApi().rejectJoinRequest(widget.groupId, id);
        _toast('已拒绝');
      }
      await _load();
    } catch (e) {
      _toast(e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _busy.remove(id));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        title: Text('入群申请 · ${widget.groupName}',
            style: const TextStyle(fontSize: 17)),
        backgroundColor: AppColors.bgElevated,
      ),
      body: _loading
          ? const Center(
              child: SizedBox(
                  width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)))
          : _items.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: const [
                      Icon(Icons.how_to_reg_outlined,
                          size: 44, color: AppColors.textWeak),
                      SizedBox(height: 10),
                      Text('没有待审批的申请',
                          style:
                              TextStyle(fontSize: 14, color: AppColors.textWeak)),
                    ],
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.separated(
                    itemCount: _items.length,
                    separatorBuilder: (_, __) => const Divider(
                        height: 1, indent: 66, color: AppColors.divider),
                    itemBuilder: (c, i) {
                      final r = _items[i];
                      final name = ((r['user_nickname'] as String?)?.isNotEmpty == true
                              ? r['user_nickname']
                              : (r['user_username'] ?? '未知用户'))
                          as String;
                      final inviter = r['inviter_nickname'] ??
                          r['inviter_username'] ??
                          null;
                      final busy = _busy.contains(r['id']);
                      return ListTile(
                        leading: UserAvatar(name: name, size: 40, radius: 11),
                        title: Text(name,
                            style: const TextStyle(fontSize: 14.5)),
                        subtitle: Text(
                          inviter == null ? '申请加入群聊' : '由「$inviter」邀请加入',
                          style: const TextStyle(
                              fontSize: 12.5, color: AppColors.textSub),
                        ),
                        trailing: busy
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2))
                            : Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  TextButton(
                                    onPressed: () => _handle(r, false),
                                    child: const Text('拒绝'),
                                  ),
                                  const SizedBox(width: 4),
                                  FilledButton(
                                    onPressed: () => _handle(r, true),
                                    child: const Text('通过'),
                                  ),
                                ],
                              ),
                      );
                    },
                  ),
                ),
    );
  }
}
