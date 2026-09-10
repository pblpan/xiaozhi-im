import 'package:flutter/material.dart';
import 'package:xiaozhi_im_client/api.dart';
import 'package:xiaozhi_im_client/core/theme.dart';
import 'package:xiaozhi_im_client/models.dart';
import 'package:xiaozhi_im_client/widgets/avatar.dart';

/// 群管理：改群名/公告、设管理员、禁言、踢人、转让群主、退群。
/// 权限由服务端裁决，这里只做界面上的可用性收敛。
class GroupManageScreen extends StatefulWidget {
  final int groupId;
  final int myId;

  const GroupManageScreen({super.key, required this.groupId, required this.myId});

  @override
  State<GroupManageScreen> createState() => _GroupManageScreenState();
}

class _GroupManageScreenState extends State<GroupManageScreen> {
  GroupDetail? _d;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d = await ImApi().groupDetail(widget.groupId);
      if (!mounted) return;
      setState(() {
        _d = GroupDetail.fromJson(d);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _toast('加载失败: ${_msg(e)}');
    }
  }

  String _msg(Object e) => e.toString().replaceFirst('Exception: ', '');

  void _toast(String s) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(s), duration: const Duration(seconds: 2)));

  /// 统一处理带确认弹窗 + 错误提示的操作
  Future<void> _act(Future<void> Function() run, {String? confirm, String? title}) async {
    if (confirm != null) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(title ?? '确认操作'),
          content: Text(confirm),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('确定')),
          ],
        ),
      );
      if (ok != true) return;
    }
    try {
      await run();
      await _load();
    } catch (e) {
      if (mounted) _toast(_msg(e));
    }
  }

  Future<void> _editName() async {
    final ctrl = TextEditingController(text: _d?.name ?? '');
    final v = await _inputDialog('修改群名', ctrl, hint: '输入新的群名称');
    if (v == null) return;
    await _act(() => ImApi().updateGroup(widget.groupId, name: v));
  }

  Future<void> _editAnnouncement() async {
    final ctrl = TextEditingController(text: _d?.announcement ?? '');
    final v = await _inputDialog('编辑群公告', ctrl,
        hint: '输入群公告（留空即清除）', maxLines: 6);
    if (v == null) return;
    await _act(() => ImApi().updateGroup(widget.groupId, announcement: v));
  }

  Future<String?> _inputDialog(String title, TextEditingController ctrl,
      {String? hint, int maxLines = 1}) async {
    final v = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          minLines: 1,
          maxLines: maxLines,
          decoration: InputDecoration(hintText: hint),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: const Text('保存')),
        ],
      ),
    );
    if (v != null && v.isEmpty && title.contains('群名')) {
      _toast('群名不能为空');
      return null;
    }
    return v;
  }

  void _memberSheet(GroupMember m) {
    final d = _d!;
    if (m.id == widget.myId) return; // 不对自己操作
    final isOwnerTarget = m.id == (d.group['owner_id'] as int?);
    if (isOwnerTarget) {
      _toast('不能对群主操作');
      return;
    }
    final canMute = d.canManage && (d.isOwner || m.role != 'admin');
    final canKick = d.canManage && (d.isOwner || m.role != 'admin');

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
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18),
              child: Row(
                children: [
                  UserAvatar(name: m.display, size: 38, radius: 10),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(m.display,
                        style: const TextStyle(
                            fontSize: 15.5, fontWeight: FontWeight.w600)),
                  ),
                  Text(m.roleLabel,
                      style: const TextStyle(fontSize: 12, color: AppColors.textWeak)),
                ],
              ),
            ),
            const SizedBox(height: 8),
            const Divider(height: 1, color: AppColors.divider),
            if (d.isOwner)
              _item(
                m.role == 'admin' ? Icons.remove_moderator_outlined : Icons.shield_outlined,
                m.role == 'admin' ? '撤销管理员' : '设为管理员',
                () async {
                  Navigator.pop(ctx);
                  await _act(
                    () => ImApi().setMemberRole(
                        widget.groupId, m.id, m.role == 'admin' ? 'member' : 'admin'),
                  );
                },
              ),
            if (canMute) ...[
              _item(Icons.volume_off_rounded, '禁言 10 分钟',
                  () => _muteFlow(ctx, m, 10)),
              _item(Icons.volume_off_rounded, '禁言 1 小时',
                  () => _muteFlow(ctx, m, 60)),
              _item(Icons.volume_off_rounded, '禁言 1 天',
                  () => _muteFlow(ctx, m, 1440)),
              if (m.isMuted)
                _item(Icons.volume_up_rounded, '解除禁言', () => _muteFlow(ctx, m, 0)),
            ],
            if (d.isOwner)
              _item(Icons.swap_horiz_rounded, '转让群主', () async {
                Navigator.pop(ctx);
                await _act(
                  () => ImApi().transferOwner(widget.groupId, m.id),
                  title: '转让群主',
                  confirm: '把群主转让给「${m.display}」？转让后你将成为普通成员，此操作不可撤销。',
                );
              }),
            if (canKick)
              _item(Icons.person_remove_alt_1_rounded, '移出群聊', () async {
                Navigator.pop(ctx);
                await _act(
                  () => ImApi().kickMember(widget.groupId, m.id),
                  title: '移出群聊',
                  confirm: '把「${m.display}」移出群聊？',
                );
              }, danger: true),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _muteFlow(BuildContext sheetCtx, GroupMember m, int mins) async {
    Navigator.pop(sheetCtx);
    await _act(
      () => ImApi().muteMember(widget.groupId, m.id, mins),
      confirm: mins == 0 ? '解除「${m.display}」的禁言？' : '禁言「${m.display}」$mins 分钟？',
    );
  }

  Widget _item(IconData icon, String label, VoidCallback onTap, {bool danger = false}) =>
      ListTile(
        leading: Icon(icon, size: 21, color: danger ? AppColors.danger : AppColors.text),
        title: Text(label,
            style: TextStyle(
                fontSize: 14.5, color: danger ? AppColors.danger : AppColors.text)),
        onTap: onTap,
      );

  Future<void> _leave() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('退出群聊'),
        content: const Text('退出后将不再接收该群消息，确定退出吗？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('退出'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ImApi().leaveGroup(widget.groupId);
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (e) {
      if (mounted) _toast(_msg(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = _d;
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        title: const Text('群管理'),
        backgroundColor: AppColors.bgElevated,
      ),
      body: _loading || d == null
          ? const Center(
              child: SizedBox(
                  width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)))
          : ListView(
              children: [
                // ---- 群资料 ----
                if (d.canManage) ...[
                  _sectionTitle('群资料'),
                  ListTile(
                    leading: const Icon(Icons.badge_outlined, size: 21),
                    title: const Text('群名称', style: TextStyle(fontSize: 14.5)),
                    subtitle: Text(d.name,
                        style: const TextStyle(fontSize: 13, color: AppColors.textSub)),
                    trailing: const Icon(Icons.chevron_right_rounded,
                        size: 20, color: AppColors.textWeak),
                    onTap: _editName,
                  ),
                  ListTile(
                    leading: const Icon(Icons.campaign_outlined, size: 21),
                    title: const Text('群公告', style: TextStyle(fontSize: 14.5)),
                    subtitle: Text(
                      (d.announcement == null || d.announcement!.isEmpty)
                          ? '未设置'
                          : d.announcement!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13, color: AppColors.textSub),
                    ),
                    trailing: const Icon(Icons.chevron_right_rounded,
                        size: 20, color: AppColors.textWeak),
                    onTap: _editAnnouncement,
                  ),
                ] else ...[
                  _sectionTitle('群资料'),
                  ListTile(
                    leading: const Icon(Icons.badge_outlined, size: 21),
                    title: const Text('群名称', style: TextStyle(fontSize: 14.5)),
                    subtitle: Text(d.name,
                        style: const TextStyle(fontSize: 13, color: AppColors.textSub)),
                  ),
                  ListTile(
                    leading: const Icon(Icons.campaign_outlined, size: 21),
                    title: const Text('群公告', style: TextStyle(fontSize: 14.5)),
                    subtitle: Text(
                      (d.announcement == null || d.announcement!.isEmpty)
                          ? '未设置'
                          : d.announcement!,
                      style: const TextStyle(fontSize: 13, color: AppColors.textSub),
                    ),
                  ),
                ],

                // ---- 成员 ----
                _sectionTitle('群成员（${d.members.length}）'),
                ...d.members.map((m) {
                  final isMe = m.id == widget.myId;
                  return ListTile(
                    leading: UserAvatar(
                      name: m.display,
                      size: 40,
                      radius: 11,
                      showOnlineDot: false,
                    ),
                    title: Row(
                      children: [
                        Flexible(
                          child: Text(
                            isMe ? '${m.display}（我）' : m.display,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 14.5),
                          ),
                        ),
                        if (m.role == 'owner')
                          _tag('群主', const Color(0xFFF5B942))
                        else if (m.role == 'admin')
                          _tag('管理员', AppColors.brand)
                        else if (m.isMuted)
                          _tag('已禁言', AppColors.danger),
                      ],
                    ),
                    subtitle: Text('@${m.username}',
                        style: const TextStyle(fontSize: 12, color: AppColors.textWeak)),
                    trailing: isMe
                        ? null
                        : const Icon(Icons.more_horiz_rounded,
                            size: 20, color: AppColors.textWeak),
                    onTap: isMe ? null : () => _memberSheet(m),
                  );
                }),

                const SizedBox(height: 8),
                if (!d.isOwner)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 6, 16, 20),
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.danger,
                        side: const BorderSide(color: AppColors.danger),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                      onPressed: _leave,
                      icon: const Icon(Icons.logout_rounded, size: 18),
                      label: const Text('退出群聊'),
                    ),
                  ),
                if (d.isOwner)
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 4, 16, 20),
                    child: Text(
                      '你是群主，需先转让群主才能退出群聊。',
                      style: TextStyle(fontSize: 12.5, color: AppColors.textWeak),
                    ),
                  ),
              ],
            ),
    );
  }

  Widget _tag(String text, Color color) => Container(
        margin: const EdgeInsets.only(left: 6),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.16),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: color.withValues(alpha: 0.5), width: 0.8),
        ),
        child: Text(text, style: TextStyle(fontSize: 10.5, color: color)),
      );

  Widget _sectionTitle(String s) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 6),
        child: Text(s,
            style: const TextStyle(
                fontSize: 12.5,
                color: AppColors.textWeak,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.4)),
      );
}
