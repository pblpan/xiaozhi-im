import 'package:flutter/material.dart';
import 'package:xiaozhi_im_client/api.dart';
import 'package:xiaozhi_im_client/core/group_candidates.dart';
import 'package:xiaozhi_im_client/core/theme.dart';
import 'package:xiaozhi_im_client/models.dart';
import 'package:xiaozhi_im_client/widgets/avatar.dart';

/// 发起群聊：起个名 + 勾好友 → 建群并把人拉进来。
///
/// 为什么要有这个页面：服务端早就有 createGroup / addMember 两个接口，
/// 但客户端**一个调用点都没有** —— 结果就是"想建群只能让管理员在后台建"，
/// 而这恰恰是龙哥说的"群聊现在没有群主，在客户端没有添加成员"。
class CreateGroupScreen extends StatefulWidget {
  const CreateGroupScreen({super.key});

  @override
  State<CreateGroupScreen> createState() => _CreateGroupScreenState();
}

class _CreateGroupScreenState extends State<CreateGroupScreen> {
  final _nameCtl = TextEditingController();
  List<User> _friends = const [];
  final Set<int> _picked = {};
  bool _loading = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _nameCtl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      // 候选口径见 group_candidates.dart：普通模式=好友，工作模式=组织全员。
      // 以前这里只拉好友，工作模式下管理员（不占编制、不在好友关系表里）
      // 在任何人的建群列表里都消失 —— 2026-10-13 龙哥报的 bug。
      final list = await loadGroupCandidates();
      if (!mounted) return;
      setState(() {
        _friends = list;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = _msg(e);
        _loading = false;
      });
    }
  }

  String _msg(Object e) => e.toString().replaceFirst('Exception: ', '');

  /// 没起名时给个默认名：用前两个人的名字拼，别让群里出现"未命名群"这种
  /// 谁也分不清是谁的群的东西
  String get _effectiveName {
    final typed = _nameCtl.text.trim();
    if (typed.isNotEmpty) return typed;
    final names = _picked
        .map((id) => _friends.firstWhere((u) => u.id == id,
            orElse: () => User(id: id, username: '$id')))
        .map((u) => u.remark ?? u.nickname ?? u.username)
        .toList();
    if (names.isEmpty) return '新的群聊';
    if (names.length <= 2) return names.join('、');
    return '${names.take(2).join('、')} 等 ${names.length} 人';
  }

  Future<void> _create() async {
    if (_picked.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('至少选一个好友')));
      return;
    }
    setState(() => _busy = true);
    try {
      final r = await ImApi().createGroup(_effectiveName);
      final gid = (r['groupId'] ?? 0) as int;
      if (gid == 0) throw Exception('建群没返回群 id');
      // 一个一个拉人：服务端 addMember 一次只收一个人，
      // 中途失败也不回滚 —— 已经进群的人就在群里，提示用户重试剩下的
      final failed = <int>[];
      for (final uid in _picked) {
        try {
          await ImApi().addMember(gid, uid);
        } catch (_) {
          failed.add(uid);
        }
      }
      if (!mounted) return;
      setState(() => _busy = false);
      if (failed.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('群建好了，但有 ${failed.length} 人没拉进来，可在群管理里重试')),
        );
      }
      Navigator.pop(context, {'groupId': gid, 'conversationId': r['conversationId']});
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = _msg(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('发起群聊'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 10),
            child: Center(
              child: FilledButton(
                onPressed: (_busy || _picked.isEmpty) ? null : _create,
                child: _busy
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : Text('创建${_picked.isEmpty ? '' : '（${_picked.length}）'}'),
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
            child: TextField(
              controller: _nameCtl,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: '群名称（可留空）',
                hintText: _effectiveName,
                hintStyle: TextStyle(color: AppColors.textWeak),
                isDense: true,
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(AppRadii.md)),
              ),
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              child: Text(_error!,
                  style: TextStyle(color: AppColors.danger, fontSize: 12.5)),
            ),
          const Divider(height: 1),
          Expanded(child: _body()),
        ],
      ),
    );
  }

  Widget _body() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_friends.isEmpty) {
      return  Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text('还没有好友，先去通讯录加几个人再来建群',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.textWeak, fontSize: 13)),
        ),
      );
    }
    return ListView.separated(
      itemCount: _friends.length,
      separatorBuilder: (_, __) => const Divider(height: 1, indent: 66),
      itemBuilder: (ctx, i) {
        final u = _friends[i];
        final name = u.remark ?? u.nickname ?? u.username;
        final on = _picked.contains(u.id);
        return CheckboxListTile(
          value: on,
          onChanged: (v) => setState(() {
            if (v == true) {
              _picked.add(u.id);
            } else {
              _picked.remove(u.id);
            }
          }),
          secondary: UserAvatar(name: name, size: 38, radius: 12, imageUrl: u.avatar),
          title: Text(name,
              style:
                  const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600)),
          subtitle: u.remark != null && u.remark!.isNotEmpty
              ? Text(u.nickname ?? u.username,
                  style: TextStyle(fontSize: 11.5, color: AppColors.textWeak))
              : null,
        );
      },
    );
  }
}
