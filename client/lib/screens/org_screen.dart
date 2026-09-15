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
  const OrgScreen({super.key, this.onPick});

  /// 嵌入模式：把它作为「通讯录」标签页的内容时，点成员**不能**走 Navigator.pop
  /// —— 那种场景下本页不是被 push 进来的，pop 会把整个首页弹掉（退到登录页那种）。
  /// 传了这个回调就改为回调出去，由外壳负责切到消息页并打开会话。
  final ValueChanged<User>? onPick;

  @override
  State<OrgScreen> createState() => _OrgScreenState();
}

class _OrgScreenState extends State<OrgScreen> {
  Map<String, dynamic>? _org;
  List<User> _members = [];
  // uid → 部门/岗位名（服务端 my 接口附带；空 = 未分配）
  Map<int, Map<String, String>> _extras = const {};
  // uid → 部门 id（建树用；服务端 my 接口已附带 dept_id，但 User 模型不含，单独留一份）
  Map<int, int?> _deptIds = const {};
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

  /// 选中一个成员。嵌入模式（通讯录标签）走回调，独立打开时才是 pop 返回值 ——
  /// 见 [OrgScreen.onPick] 的说明：嵌入时 pop 会把整个首页弹掉。
  void _pick(User u) {
    final cb = widget.onPick;
    if (cb != null) {
      cb(u);
      return;
    }
    Navigator.pop(context, u);
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
      // 每个成员的部门 id（建树：成员挂到对应部门节点下）
      final deptIds = <int, int?>{};
      for (final m in rawMembers) {
        final id = (m['id'] ?? 0) as int;
        deptIds[id] = (m['dept_id'] is int) ? m['dept_id'] as int? : null;
      }
      if (!mounted) return;
      setState(() {
        _isAdmin = role == 'admin';
        _org = o is Map ? Map<String, dynamic>.from(o) : null;
        _members = list;
        _extras = extras;
        _deptIds = deptIds;
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
              : ListView(
                  padding: const EdgeInsets.fromLTRB(8, 4, 8, 24),
                  children: _tree(),
                ),
        ),
      ],
    );
  }

  /// 把「部门（parent_id 层级）+ 成员」渲染成可展开 / 收起的树。
  ///
  /// 以前是"部门小标题 + 成员"的平铺列表；组织稍大就一长条、找不到人。
  /// 现在部门是可折叠节点，点开才展开子部门与成员；多级部门能嵌套。
  /// 没人任何部门的成员收进「未分配部门」叶子节点。
  List<Widget> _tree() {
    final depts = (() {
      final raw = (_org?['depts'] as List? ?? const []).whereType<Map>();
      final map = <int, Map<String, dynamic>>{};
      for (final d in raw) {
        final id = d['id'];
        if (id is int) map[id] = Map<String, dynamic>.from(d);
      }
      return map;
    })();

    // 成员按 dept_id 分组（null / 不在 depts 里 = 未分配）
    final byDept = <int?, List<User>>{};
    for (final u in _members) {
      final did = _deptIds[u.id];
      (byDept[deptIdsContains(depts, did) ? did : null] ??= []).add(u);
    }
    for (final list in byDept.values) {
      list.sort((a, b) => a.display.compareTo(b.display));
    }

    bool hasDepts = depts.isNotEmpty;
    final roots = depts.values
        .where((d) => (d['parent_id'] is int ? d['parent_id'] as int : 0) == 0)
        .toList()
      ..sort(_deptCmp);

    final children = <Widget>[];
    for (final d in roots) {
      children.add(_deptNode(d, depts, byDept, 0));
    }
    // 没有部门数据：退化为"全部成员"一组
    if (!hasDepts) {
      children.add(_leafGroup('成员', byDept[null] ?? _members, 0, keyId: 'all'));
    } else if ((byDept[null] ?? []).isNotEmpty) {
      children.add(_leafGroup('未分配部门', byDept[null]!, 0, keyId: 'unassigned'));
    }
    return children;
  }

  /// 该 dept_id 是否在部门表里（防御：数据里出现但表里没有的部门 id）
  bool deptIdsContains(Map<int, Map<String, dynamic>> depts, int? did) =>
      did != null && depts.containsKey(did);

  int _deptCmp(Map<String, dynamic> a, Map<String, dynamic> b) {
    final sa = (a['sort'] is int ? a['sort'] as int : 0);
    final sb = (b['sort'] is int ? b['sort'] as int : 0);
    if (sa != sb) return sa.compareTo(sb);
    return (a['id'] as int).compareTo(b['id'] as int);
  }

  /// 部门节点（可折叠）：展开后显示子部门 + 本部门成员。
  Widget _deptNode(Map<String, dynamic> dept,
      Map<int, Map<String, dynamic>> depts, Map<int?, List<User>> byDept, int depth) {
    final id = dept['id'] as int;
    final name = (dept['name'] ?? '').toString();
    final subDepts = depts.values
        .where((d) =>
            (d['parent_id'] is int ? d['parent_id'] as int : 0) == id)
        .toList()
      ..sort(_deptCmp);
    final mems = byDept[id] ?? const <User>[];
    final kids = <Widget>[];
    for (final s in subDepts) {
      kids.add(_deptNode(s, depts, byDept, depth + 1));
    }
    // 纯容器部门（只有子部门、没有直接成员）就不挂空的"本部门成员"
    if (mems.isNotEmpty) {
      kids.add(_leafGroup('本部门成员', mems, depth + 1, keyId: 'mem_$id'));
    }
    return _treeTile(name, mems.length, kids, depth, keyId: id);
  }

  /// 叶子分组（未分配部门 / 本部门成员）：只列成员，不可再展开子部门。
  Widget _leafGroup(String title, List<User> mems, int depth, {Object? keyId}) {
    if (mems.isEmpty) {
      return _treeTile(title, 0, const [], depth, empty: true, keyId: keyId);
    }
    final kids = mems.map(_memberRow).toList();
    return _treeTile(title, mems.length, kids, depth, keyId: keyId);
  }

  /// 树的通用节点外观：文件夹图标 + 名称 + 人数，可展开 / 收起。
  Widget _treeTile(String title, int count, List<Widget> children, int depth,
      {bool empty = false, Object? keyId}) {
    final leading = Icon(
      children.isEmpty ? Icons.folder_open_outlined : Icons.folder_outlined,
      size: 18,
      color: empty ? AppColors.textWeak : AppColors.brand,
    );
    final tile = ExpansionTile(
      key: PageStorageKey('org_${keyId ?? title}_$depth'),
      leading: leading,
      title: Row(
        children: [
          Expanded(
            child: Text(title,
                style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600)),
          ),
          if (count > 0)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
              decoration: BoxDecoration(
                color: AppColors.brand.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(AppRadii.pill),
              ),
              child: Text('$count',
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: AppColors.brand)),
            ),
        ],
      ),
      initiallyExpanded: depth == 0,
      children: empty
          ? const [
              Padding(
                padding: EdgeInsets.only(left: 16, bottom: 8),
                child: Text('（暂无成员）',
                    style: TextStyle(fontSize: 12, color: AppColors.textWeak)),
              )
            ]
          : children,
    );
    // 按层级缩进，做出"树"的视觉
    return Padding(
      padding: EdgeInsets.only(left: depth * 14.0),
      child: tile,
    );
  }

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
        onTap: mine ? null : () => _pick(u),
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
