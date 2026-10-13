import 'package:flutter/material.dart';
import 'package:xiaozhi_im_client/api.dart';
import 'package:xiaozhi_im_client/core/group_candidates.dart';
import 'package:xiaozhi_im_client/core/theme.dart';
import 'package:xiaozhi_im_client/models.dart';
import 'package:xiaozhi_im_client/screens/join_requests.dart';
import 'package:xiaozhi_im_client/widgets/avatar.dart';

/// 群管理：改群名/公告、设管理员、禁言、踢人、转让群主、退群，
/// 以及 2026-10-13 新增的全员禁言 / 加群验证 / 入群审批 / 群名片。
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
  /// 待审批的入群申请数（只拉一次做角标，进审批页会重算）
  int _pendingJoins = 0;
  /// 开关操作进行中（防止连点把开关打回去）
  bool _switching = false;

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
      // 待审批数拉失败不打扰（只是个角标）
      if (_d?.canManage == true) {
        try {
          final n = (await ImApi().joinRequests(widget.groupId)).length;
          if (mounted) setState(() => _pendingJoins = n);
        } catch (_) {}
      }
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

  /// 添加成员：从候选里挑还没进群的人。
  ///
  /// 候选口径见 group_candidates.dart：普通模式=好友，工作模式=组织全员
  /// （含管理员）。以前只列好友，管理员不在好友关系表里，谁都拉不进来 ——
  /// 2026-10-13 龙哥报的 bug「管理员不能被加入群聊」。
  ///
  /// 服务端允许**任何群成员**拉人（不只是群主/管理员），这里就跟服务端一致，
  /// 不额外设门槛 —— 界面比服务端严会让"别人能拉、我却点不了"，反而更难解释。
  Future<void> _addMembers(GroupDetail d) async {
    List<User> friends;
    try {
      friends = await loadGroupCandidates();
    } catch (e) {
      _toast('拉取成员失败: ${_msg(e)}');
      return;
    }
    final inGroup = d.members.map((m) => m.id).toSet();
    final candidates = friends.where((u) => !inGroup.contains(u.id)).toList();
    if (!mounted) return;
    if (candidates.isEmpty) {
      _toast('好友都已经在这个群里了');
      return;
    }

    final picked = <int>{};
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('添加成员'),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: candidates.length,
              itemBuilder: (c, i) {
                final u = candidates[i];
                return CheckboxListTile(
                  dense: true,
                  value: picked.contains(u.id),
                  onChanged: (v) => setLocal(() {
                    if (v == true) {
                      picked.add(u.id);
                    } else {
                      picked.remove(u.id);
                    }
                  }),
                  secondary: UserAvatar(
                      name: u.remark ?? u.nickname ?? u.username,
                      size: 32,
                      radius: 10,
                      imageUrl: u.avatar),
                  title: Text(u.remark ?? u.nickname ?? u.username,
                      style: const TextStyle(fontSize: 14)),
                );
              },
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
            FilledButton(
              onPressed: picked.isEmpty ? null : () => Navigator.pop(ctx, true),
              child: Text(picked.isEmpty ? '添加' : '添加（${picked.length}）'),
            ),
          ],
        ),
      ),
    );
    if (go != true || picked.isEmpty) return;

    var okN = 0;
    for (final uid in picked) {
      try {
        await ImApi().addMember(widget.groupId, uid);
        okN++;
      } catch (_) {
        /* 个别失败不阻断，最后统一汇报 */
      }
    }
    if (!mounted) return;
    _toast(okN == picked.length ? '已添加 $okN 人' : '添加完成，成功 $okN / ${picked.length} 人');
    await _load();
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

  /// 全员禁言 / 加群验证开关（服务端 PATCH /groups/:id，失败弹提示并回弹）
  Future<void> _toggleSwitch(String kind, bool value) async {
    if (_switching) return;
    setState(() => _switching = true);
    try {
      if (kind == 'mutedAll') {
        await ImApi().updateGroup(widget.groupId, mutedAll: value);
      } else {
        await ImApi().updateGroup(widget.groupId, joinMode: value ? 'approval' : 'free');
      }
      await _load();
    } catch (e) {
      if (mounted) _toast(_msg(e));
    } finally {
      if (mounted) setState(() => _switching = false);
    }
  }

  /// 设置我自己的群名片（空 = 清除）
  Future<void> _editMyNickname() async {
    final d = _d!;
    final me = d.members.firstWhere((m) => m.id == widget.myId);
    final ctrl = TextEditingController(text: me.groupNickname ?? '');
    final v = await _inputDialog('我的群名片', ctrl, hint: '群内显示的名字（留空用真实昵称）');
    if (v == null) return;
    await _act(() => ImApi().setMyGroupNickname(widget.groupId, v));
  }

  /// 群主/管理员改他人群名片
  Future<void> _editMemberNickname(GroupMember m) async {
    final ctrl = TextEditingController(text: m.groupNickname ?? '');
    final v = await _inputDialog('修改「${m.display}」的群名片', ctrl,
        hint: '留空恢复真实昵称');
    if (v == null) return;
    await _act(() => ImApi().setMemberNickname(widget.groupId, m.id, v));
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
            if (d.canManage)
              _item(Icons.drive_file_rename_outline_rounded, '修改群名片',
                  () async {
                Navigator.pop(ctx);
                await _editMemberNickname(m);
              }),
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

                // ---- 群管理开关（群主/管理员）----
                if (d.canManage) ...[
                  _sectionTitle('群管理'),
                  SwitchListTile(
                    secondary: const Icon(Icons.volume_off_rounded, size: 21),
                    title: const Text('全员禁言', style: TextStyle(fontSize: 14.5)),
                    subtitle: const Text('开启后只有群主和管理员能发言',
                        style: TextStyle(fontSize: 12.5, color: AppColors.textSub)),
                    value: d.mutedAll,
                    onChanged: _switching ? null : (v) => _toggleSwitch('mutedAll', v),
                  ),
                  SwitchListTile(
                    secondary: const Icon(Icons.verified_user_outlined, size: 21),
                    title: const Text('加群验证', style: TextStyle(fontSize: 14.5)),
                    subtitle: const Text('成员拉人需要群主或管理员同意',
                        style: TextStyle(fontSize: 12.5, color: AppColors.textSub)),
                    value: d.needApproval,
                    onChanged: _switching ? null : (v) => _toggleSwitch('join', v),
                  ),
                  ListTile(
                    leading: const Icon(Icons.how_to_reg_outlined, size: 21),
                    title: const Text('入群申请', style: TextStyle(fontSize: 14.5)),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (_pendingJoins > 0)
                          Container(
                            margin: const EdgeInsets.only(right: 4),
                            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                            decoration: BoxDecoration(
                              color: AppColors.danger,
                              borderRadius: BorderRadius.circular(9),
                            ),
                            child: Text('$_pendingJoins',
                                style: const TextStyle(
                                    fontSize: 11, color: Colors.white)),
                          ),
                        const Icon(Icons.chevron_right_rounded,
                            size: 20, color: AppColors.textWeak),
                      ],
                    ),
                    onTap: () async {
                      await Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => JoinRequestsScreen(
                              groupId: widget.groupId, groupName: d.name),
                        ),
                      );
                      if (mounted) _load();
                    },
                  ),
                ],

                // ---- 我的群名片 ----
                _sectionTitle('我的群名片'),
                ListTile(
                  leading: const Icon(Icons.drive_file_rename_outline_rounded, size: 21),
                  title: Builder(builder: (c) {
                    final me = d.members.where((m) => m.id == widget.myId).toList();
                    final nick = me.isNotEmpty ? me.first.groupNickname : null;
                    return Text(
                      (nick == null || nick.isEmpty) ? '未设置（显示真实昵称）' : nick,
                      style: const TextStyle(fontSize: 14.5),
                    );
                  }),
                  subtitle: const Text('只在本群显示，别人看到的名字',
                      style: TextStyle(fontSize: 12.5, color: AppColors.textSub)),
                  trailing: const Icon(Icons.chevron_right_rounded,
                      size: 20, color: AppColors.textWeak),
                  onTap: _editMyNickname,
                ),

                // ---- 成员 ----
                _sectionTitle('群成员（${d.members.length}）'),
                // 龙哥 2026-10-10：客户端此前**没有添加成员的入口** ——
                // addMember 接口一直都在，就是没人调。服务端允许普通成员拉人，
                // 所以这里不给 canManage 门槛。
                ListTile(
                  leading: const Icon(Icons.person_add_alt_1_rounded, size: 21),
                  title: const Text('添加成员', style: TextStyle(fontSize: 14.5)),
                  trailing: const Icon(Icons.chevron_right_rounded,
                      size: 20, color: AppColors.textWeak),
                  onTap: () => _addMembers(d),
                ),
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
