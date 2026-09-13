import 'package:flutter/material.dart';
import 'package:xiaozhi_im_client/api.dart';
import 'package:xiaozhi_im_client/core/theme.dart';
import 'package:xiaozhi_im_client/models.dart';
import 'package:xiaozhi_im_client/widgets/avatar.dart';

/// 组织机构页（工作模式）。
///
/// 数据完全由服务端驱动，客户端不判断好友模式：
/// - 我没组织 & 我是 admin → 显示「创建组织」；
///   若服务端还在普通模式，会返回 400「请先切换到工作模式」，toast 原样展示。
/// - 我没组织 & 我是员工 → 「尚未加入组织」。
/// - 有组织 → 成员列表；点成员返回该 [User]，语义是「打开跟 TA 的聊天」
///   （与 NewFriendsScreen 相同，调用方据此直接建会话）。
/// - admin 额外可用：添加员工（工号=账号、初始密码=工号）、移除员工。
class OrgScreen extends StatefulWidget {
  const OrgScreen({super.key});

  @override
  State<OrgScreen> createState() => _OrgScreenState();
}

class _OrgScreenState extends State<OrgScreen> {
  Map<String, dynamic>? _org;
  List<User> _members = [];
  // uid → 部门/岗位名（服务端 my 接口附带；空 = 未分配）
  Map<int, Map<String, String>> _extras = const {};
  // 部门展示顺序（服务端按 sort 排好）
  List<String> _deptOrder = const [];
  bool _isAdmin = false;
  int _myId = 0;
  bool _loading = true;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  String _errText(Object e) =>
      e is ApiException ? e.message : e.toString().replaceFirst('Exception: ', '');

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
      final results = await Future.wait([ImApi().me(), ImApi().myOrg()]);
      final me = results[0];
      final org = results[1];
      _myId = ((me['user'] ?? const {})['id'] ?? 0) as int;
      final role = ((me['user'] ?? const {})['role'] ?? 'user').toString();
      final o = org['org'];
      final rawMembers = (org['members'] as List? ?? const []).whereType<Map>();
      final list = rawMembers
          .map((m) => User.fromJson(m.cast<String, dynamic>()))
          .toList();
      // 部门/岗位名挂在原始 map 上（User 模型不带），uid → {dept, position}
      final extras = <int, Map<String, String>>{
        for (final m in rawMembers)
          ((m['id'] ?? 0) as int): {
            'dept': (m['dept_name'] ?? '').toString(),
            'position': (m['position_name'] ?? '').toString(),
          },
      };
      // 服务端 depts 全集（含没人部门），按 sort 排好 → 分组顺序以它为准
      final deptOrder = (org['depts'] as List? ?? const [])
          .whereType<Map>()
          .map((d) => (d['name'] ?? '').toString())
          .toList();
      if (!mounted) return;
      setState(() {
        _isAdmin = role == 'admin';
        _org = o is Map ? Map<String, dynamic>.from(o) : null;
        _members = list;
        _extras = extras;
        _deptOrder = deptOrder;
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

  Future<void> _createOrg() async {
    final ctrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('创建组织'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLength: 30,
          decoration: const InputDecoration(
              hintText: '组织名称（2-30 个字）', counterText: ''),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () {
              final v = ctrl.text.trim();
              if (v.length < 2) {
                _toast('组织名至少 2 个字');
                return;
              }
              Navigator.pop(ctx, v);
            },
            child: const Text('创建'),
          ),
        ],
      ),
    );
    if (name == null) return;
    setState(() => _busy = true);
    try {
      await ImApi().createOrg(name);
      _toast('组织已创建');
      await _load();
    } catch (e) {
      _toast(_errText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _addMember() async {
    final no = TextEditingController();
    final nick = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('添加员工'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: no,
              autofocus: true,
              maxLength: 20,
              decoration: const InputDecoration(
                hintText: '工号（3-20 位字母/数字/下划线）',
                counterText: '',
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: nick,
              maxLength: 24,
              decoration: const InputDecoration(
                hintText: '姓名（选填，默认用工号）',
                counterText: '',
              ),
            ),
            const SizedBox(height: 4),
            const Align(
              alignment: Alignment.centerLeft,
              child: Text('工号即登录账号，初始密码与工号相同；录入后自动与同事互为好友。',
                  style: TextStyle(fontSize: 11.5, color: AppColors.textWeak, height: 1.5)),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(
            onPressed: () {
              final v = no.text.trim();
              if (!RegExp(r'^[A-Za-z0-9_]{3,20}$').hasMatch(v)) {
                _toast('工号 3-20 位，仅限字母、数字、下划线');
                return;
              }
              Navigator.pop(ctx, true);
            },
            child: const Text('添加'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final orgId = _org?['id'];
    if (orgId is! int) return;
    setState(() => _busy = true);
    try {
      await ImApi().addOrgMember(orgId, no.text.trim(), nick.text.trim());
      _toast('员工已添加，初始密码为工号');
      await _load();
    } catch (e) {
      _toast(_errText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _removeMember(User u) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('移除员工'),
        content: Text('确定移除 ${u.display}（${u.username}）吗？\n移除后 TA 将退出组织并解除同事好友关系。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('移除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final orgId = _org?['id'];
    if (orgId is! int) return;
    setState(() => _busy = true);
    try {
      await ImApi().removeOrgMember(orgId, u.id);
      _toast('已移除');
      await _load();
    } catch (e) {
      _toast(_errText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ---------------- 界面 ----------------

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: Text(_org?['name']?.toString() ?? '组织机构'),
          actions: [
            if (_org != null && _isAdmin)
              IconButton(
                tooltip: '添加员工',
                onPressed: _busy ? null : _addMember,
                icon: const Icon(Icons.person_add_alt_rounded),
              ),
          ],
        ),
        body: _loading
            ? const Center(
                child: SizedBox(
                    width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)))
            : _error != null
                ? _errorView()
                : _body(),
      );

  Widget _errorView() => Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 40),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline_rounded, size: 44, color: AppColors.textWeak),
              const SizedBox(height: 12),
              Text(_error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 13.5, color: AppColors.textSub)),
              const SizedBox(height: 10),
              FilledButton(onPressed: _load, child: const Text('重试')),
            ],
          ),
        ),
      );

  Widget _body() {
    if (_org == null) return _emptyOrg();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
          child: Row(
            children: [
              const Icon(Icons.corporate_fare_rounded,
                  size: 18, color: AppColors.textWeak),
              const SizedBox(width: 6),
              Text('${_org!['name']} · ${_members.length} 人',
                  style: const TextStyle(
                      fontSize: 12.5, color: AppColors.textWeak)),
            ],
          ),
        ),
        Expanded(
          child: _members.isEmpty
              ? const Center(
                  child: Text('还没有成员，点右上角添加',
                      style: TextStyle(color: AppColors.textWeak)))
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                  itemCount: _flatRows.length,
                  itemBuilder: (c, i) {
                    final row = _flatRows[i];
                    return row.header != null
                        ? _deptHeader(row.header!)
                        : _memberRow(row.user!);
                  },
                ),
        ),
      ],
    );
  }

  // 分组行：header 非 null = 部门小标题，否则是成员
  // （按服务端 depts 的 sort 顺序分组；未分配部门排最后）
  List<({String? header, User? user})> get _flatRows {
    final byDept = <String, List<User>>{};
    for (final u in _members) {
      final dept = _extras[u.id]?['dept'] ?? '';
      (byDept[dept] ??= []).add(u);
    }
    final rows = <({String? header, User? user})>[];
    for (final d in _deptOrder) {
      final list = byDept.remove(d);
      if (list == null) continue; // 没人的部门不占屏
      rows.add((header: d, user: null));
      rows.addAll(list.map((u) => (header: null, user: u)));
    }
    // 剩下的 = 未分配（'' 为 key）+ 数据里出现但不在 depts 全集的（防御）
    for (final e in byDept.entries) {
      rows.add((header: e.key.isEmpty ? '未分配部门' : e.key, user: null));
      rows.addAll(e.value.map((u) => (header: null, user: u)));
    }
    return rows;
  }

  Widget _deptHeader(String name) => Padding(
        padding: const EdgeInsets.only(top: 10, bottom: 6),
        child: Row(
          children: [
            const Icon(Icons.folder_outlined,
                size: 14, color: AppColors.textWeak),
            const SizedBox(width: 5),
            Text(name,
                style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textWeak)),
          ],
        ),
      );

  Widget _emptyOrg() => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.corporate_fare_rounded,
                size: 56, color: AppColors.textWeak),
            const SizedBox(height: 14),
            Text(
              _isAdmin ? '还没有创建组织' : '尚未加入组织',
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            Text(
              _isAdmin
                  ? '创建后即可按工号录入员工：\n工号即登录账号，初始密码与工号相同。'
                  : '请管理员在工作模式下按工号录入，\n录入后同事自动互为好友。',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12.5, color: AppColors.textWeak, height: 1.6),
            ),
            const SizedBox(height: 16),
            if (_isAdmin)
              FilledButton.icon(
                onPressed: _busy ? null : _createOrg,
                icon: const Icon(Icons.add_business_rounded, size: 18),
                label: const Text('创建组织'),
              ),
          ],
        ),
      );

  // 副标题：工号 + 部门/岗位（有才显示）
  String _memberSub(User u) {
    final ex = _extras[u.id] ?? const {};
    final dept = ex['dept'] ?? '';
    final pos = ex['position'] ?? '';
    final org = [
      if (dept.isNotEmpty) dept,
      if (pos.isNotEmpty) pos,
    ].join(' · ');
    final no = u.username; // 工号=账号
    return org.isEmpty ? '@$no' : '@$no · $org';
  }

  Widget _memberRow(User u) {
    final mine = u.id == _myId;
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadii.md),
        border: Border.all(color: AppColors.divider),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
        leading: UserAvatar(name: u.display, size: 42, imageUrl: u.avatar),
        title: Text(
          mine ? '${u.display}（我）' : u.display,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          _memberSub(u),
          style: const TextStyle(fontSize: 12.5),
        ),
        // 员工没有备注语义：组织内一律显示昵称/工号
        onTap: mine ? null : () => Navigator.pop(context, u),
        trailing: _isAdmin && !mine
            ? IconButton(
                tooltip: '移除员工',
                icon: const Icon(Icons.person_remove_outlined,
                    size: 19, color: AppColors.textWeak),
                onPressed: _busy ? null : () => _removeMember(u),
              )
            : (mine
                ? null
                : const Icon(Icons.chevron_right_rounded,
                    size: 19, color: AppColors.textWeak)),
      ),
    );
  }
}
