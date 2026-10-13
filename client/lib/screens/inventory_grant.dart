import 'package:flutter/material.dart';

import '../api.dart';
import '../core/theme.dart';
import '../core/time.dart';

/// 抽盘授权（M2/P2）—— **管理干部在这里决定"谁能开抽盘单"**。
///
/// ── 为什么抽盘要单独发一道权 ────────────────────────────────────
/// 初盘、复盘是"数"，抽盘是"定案"：抽盘的数量一旦上传，那批差异就按它结账。
/// 谁都能抽盘的话，等于谁都能把自己盘错的数改成对 —— 三遍互盘就白做了。
/// 所以抽盘不是"藏个按钮"，是**服务端在上传时拒掉无权账号**
/// （见 server/src/routes/inventory.js 的 requireGrant）。
/// 这一页只是那道门的管理端，不是那道门本身。
///
/// ── 三条不能省的规矩（都在服务端落实，这里只是照实呈现）─────────
/// 1. **管理员天然持权**。否则新点位建出来当天没人开得了第一个抽盘单
///    （连给自己授权都需要先有权 —— 死锁）。所以管理员不在这张名单里，也不需要有。
/// 2. **解除 ≠ 删除**。解除是给那行记录盖一个 `revoked_at` 时间戳，
///    名单里仍能翻到"某人某时被授过、某时被收回"。事后追责靠的就是这行。
///    这一页把"已解除"整段摆出来，就是为了让人知道它没消失。
/// 3. **谁有权，只有一个判据**（`revoked_at IS NULL`）。界面上的"生效中/已解除"
///    一律照服务端下发的 `live_user_ids` 渲染，绝不本地另算一套 ——
///    两套判据必然在某个边界（刚授权、刚解除）给出不同答案，
///    表现出来就是"界面说有权、一上传被拒"，那是最难查的一种。
///
/// ── 一个刻意的取舍 ──────────────────────────────────────────────
/// 候选名单**只取本组织员工名册**（/orgs/my），不做"随便输个账号就授权"。
/// 抽盘是定案动作，授权对象必须是个名册上的人；输错一个字符就授给不存在的人，
/// 现场只会得到一句 404，还不如直接告诉他"先去管理台把员工加进来"。
class InventoryGrantScreen extends StatefulWidget {
  const InventoryGrantScreen({
    super.key,
    required this.zoneCode,
    required this.zoneName,
  });

  final String zoneCode;
  final String zoneName;

  @override
  State<InventoryGrantScreen> createState() => _InventoryGrantScreenState();
}

class _InventoryGrantScreenState extends State<InventoryGrantScreen> {
  final _api = ImApi();
  final _qCtrl = TextEditingController();

  bool _loading = true;
  String? _err;
  bool _isAdmin = false;
  bool _canManage = false;

  /// `GET /stocktake/zone/:z/grant` 的原样响应（头部徽标要用 mine / is_admin）。
  Map<String, dynamic> _grantData = const {};

  /// 服务端原样的授权行：user_id / username / nickname / granted_by / granted_at / revoked_at
  List<Map<String, dynamic>> _grants = const [];
  /// 生效中的 user_id（**以服务端 live_user_ids 为准**）
  Set<int> _liveIds = const {};

  /// 本组织员工名册（/orgs/my 的 members）
  List<Map<String, dynamic>> _members = const [];
  bool _rosterLoaded = false;

  /// 正在请求中的 user_id（防连点同一个人）
  final Set<int> _busy = <int>{};
  String _q = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _qCtrl.dispose();
    super.dispose();
  }

  // ---- 数据 ----

  Future<void> _load({bool silent = false}) async {
    if (!silent && mounted) setState(() => _loading = true);
    try {
      // 授权现状是这一页的主内容，它拿不到就整页失败（下面 _err 分支给重试）。
      final g = await _api.stocktakeGrant(widget.zoneCode);

      // 员工名册是"要授权给谁"的候选，**拿不到不该拖垮整页** ——
      // 名单照样能看、能解除，只是暂时不能新授权。所以单独 try 一次。
      List<Map<String, dynamic>> members = const [];
      var rosterOk = true;
      try {
        final org = await _api.myOrg();
        // 只收**有工号的在册员工**：服务端 /orgs/my 从 2026-10-13 起也会把
        // org_id=NULL 的管理员账号列进组织通讯录（修"通讯录里看不到管理员"），
        // 但抽盘授权是发给"被授权干活的人"的 —— 管理员本来就能进所有页面，
        // 授不授权一个样。名册里混进管理员只会让人以为"还得给管理员授权"。
        members = _maps(org['members'])
            .where((m) => (m['employee_no'] as String?)?.isNotEmpty == true)
            .toList(growable: false);
      } catch (_) {
        rosterOk = false;
      }
      if (!mounted) return;

      final grants = _maps(g['grants']);
      final liveRaw = g['live_user_ids'];

      // 生效中的 user_id。**优先信服务端下发的 live_user_ids**；
      // 万一没有，才按 `revoked_at == null` 兜底 —— 同一份响应里的同一批行，
      // 不存在两个答案。界面绝不自己另立一套判据。
      Set<int> liveIds;
      if (liveRaw is List) {
        liveIds = liveRaw.whereType<num>().map((e) => e.toInt()).toSet();
      } else {
        liveIds = grants
            .where((r) => r['revoked_at'] == null)
            .map((r) => (r['user_id'] as num?)?.toInt() ?? 0)
            .where((e) => e > 0)
            .toSet();
      }

      setState(() {
        _grantData = g;
        _grants = grants;
        _liveIds = liveIds;
        _isAdmin = g['is_admin'] == true;
        _canManage = g['can_manage'] == true;
        _members = members;
        _rosterLoaded = rosterOk;
        _err = null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _err = _errText(e);
        _loading = false;
      });
    }
  }

  // ---- 动作 ----

  Future<void> _grant(int userId, String label) async {
    if (_busy.contains(userId)) return;
    setState(() => _busy.add(userId));
    try {
      final r = await _api.grantStocktake(widget.zoneCode, userId);
      if (!mounted) return;
      // already=true 是"本来就生效中"：说清楚是幂等命中，不是又授了一次
      // （服务端刻意不刷新原 granted_at，反复点不会把授权时间改掉）。
      _snack(r['already'] == true
          ? '$label 本来就有抽盘授权，授权时间没被改'
          : '已授权 $label 抽盘');
      await _load(silent: true);
    } catch (e) {
      if (mounted) _snack(_errText(e));
    } finally {
      if (mounted) setState(() => _busy.remove(userId));
    }
  }

  Future<void> _revoke(int userId, String label) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.bgElevated,
        title: Text('解除 $label 的抽盘授权？',
            style: const TextStyle(color: AppColors.text, fontSize: 16)),
        content: const Text(
          '解除后 ta 进不了抽盘，上传的抽盘单也会被服务端拒绝。\n\n'
          '这条授权记录不会删掉，会留一条"什么时候被解除"的痕迹，'
          '以后还能查。真要让 ta 重新抽盘，再授一次即可（会重新计时）。',
          style: TextStyle(color: AppColors.textSub, fontSize: 13),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('不解除')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('解除',
                  style: TextStyle(
                      color: AppColors.danger, fontWeight: FontWeight.w600))),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    setState(() => _busy.add(userId));
    try {
      await _api.revokeStocktake(widget.zoneCode, userId);
      if (!mounted) return;
      _snack('已解除 $label 的抽盘授权（记录留痕）');
      await _load(silent: true);
    } catch (e) {
      if (mounted) _snack(_errText(e));
    } finally {
      if (mounted) setState(() => _busy.remove(userId));
    }
  }

  // ---- 小工具 ----

  static List<Map<String, dynamic>> _maps(Object? v) {
    if (v is! List) return const [];
    return v
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList(growable: false);
  }

  /// 员工显示名：昵称优先，没有就用账号（账号=工号）。
  static String _name(Map<String, dynamic> m) {
    final n = (m['nickname'] as String?)?.trim();
    if (n != null && n.isNotEmpty) return n;
    return (m['username'] as String?)?.trim() ?? '（未知）';
  }

  /// user_id → 显示名（授权人那一列要显示"谁授的"，服务端只给 id）。
  String _nameOfId(int id) {
    for (final m in _members) {
      if ((m['id'] as num?)?.toInt() == id) return _name(m);
    }
    for (final g in _grants) {
      if ((g['user_id'] as num?)?.toInt() == id) {
        return (g['nickname'] as String?)?.trim().isNotEmpty == true
            ? g['nickname'] as String
            : (g['username'] as String? ?? 'id:$id');
      }
    }
    return 'id:$id';
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  /// 把异常揉成一句人话（与盘点采集页同一套处理）。
  static String _errText(Object e) {
    if (e is ApiException) return e.message;
    return e
        .toString()
        .replaceFirst(RegExp(r'^\w*Exception: '), '')
        .replaceFirst(RegExp(r'^Bad state: '), '');
  }

  /// 名册按搜索词过滤：账号 / 昵称 / 工号 三处都命中。
  List<Map<String, dynamic>> get _candidates {
    final q = _q.trim().toLowerCase();
    if (q.isEmpty) return _members;
    return _members.where((m) {
      final u = (m['username'] as String? ?? '').toLowerCase();
      final n = (m['nickname'] as String? ?? '').toLowerCase();
      final e = (m['employee_no'] as String? ?? '').toLowerCase();
      return u.contains(q) || n.contains(q) || e.contains(q);
    }).toList(growable: false);
  }

  // ---- 界面 ----

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bgElevated,
        title: const Text('抽盘授权',
            style: TextStyle(color: AppColors.text, fontSize: 17)),
        actions: [
          IconButton(
            tooltip: '刷新',
            icon: const Icon(Icons.refresh, color: AppColors.textSub),
            onPressed: _loading ? null : () => _load(),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _err != null
              ? _errorView(_err!)
              : RefreshIndicator(
                  onRefresh: () => _load(silent: true),
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 28),
                    children: [
                      _headCard(),
                      if (!_canManage) _readOnlyBanner(),
                      _liveSection(),
                      _addSection(),
                      _historySection(),
                    ],
                  ),
                ),
    );
  }

  Widget _errorView(String msg) => Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off, color: AppColors.danger, size: 40),
              const SizedBox(height: 12),
              Text(msg,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: AppColors.textSub, fontSize: 13)),
              const SizedBox(height: 6),
              const Text('抽盘授权只有连上服务器才能看和改。',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: AppColors.textWeak, fontSize: 12)),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () => _load(),
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      );

  Widget _headCard() {
    final mine = _grantData['mine'] == true;
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.fact_check_outlined,
                  color: AppColors.brand, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${widget.zoneName}（${widget.zoneCode}）',
                  style: const TextStyle(
                      color: AppColors.text,
                      fontSize: 15,
                      fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            '初盘、复盘是"数"，抽盘是"定案"。被授权的人才能开抽盘单、'
            '才能把抽盘数据传上来。',
            style: TextStyle(color: AppColors.textSub, fontSize: 12, height: 1.5),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              _chip(
                mine ? '我有抽盘权' : '我没有抽盘权',
                mine ? AppColors.brand : AppColors.textWeak,
              ),
              _chip(
                _canManage ? '可授权/解除' : '只能查看',
                _canManage ? AppColors.brand2 : AppColors.textWeak,
              ),
              if (_isAdmin) _chip('管理员天然持权', AppColors.brand2),
            ],
          ),
          if (_isAdmin) ...[
            const SizedBox(height: 10),
            const Text(
              '管理员不需要出现在下面的名单里 —— 系统默认管理员可抽盘，'
              '否则新点位建出来当天没人开得了第一张抽盘单。',
              style: TextStyle(
                  color: AppColors.textWeak, fontSize: 11, height: 1.5),
            ),
          ],
        ],
      ),
    );
  }

  /// 无权管理时**明说**，并把名单照常摆出来（看得到谁有权是有用的信息），
  /// 只是不显示按钮 —— 而不是显示一个点了会 403 的按钮。
  Widget _readOnlyBanner() => Container(
        margin: const EdgeInsets.only(bottom: 14),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.warn.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.warn.withValues(alpha: 0.35)),
        ),
        child: const Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.lock_outline, color: AppColors.warn, size: 16),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                '您没有该点位的抽盘授权权限，只能查看名单。\n'
                '需要开通或收回抽盘权，请找已持权的管理干部或管理员。',
                style: TextStyle(
                    color: AppColors.warn, fontSize: 12, height: 1.5),
              ),
            ),
          ],
        ),
      );

  /// 生效中的名单。**空的也要有话说** —— 空名单最容易被误读成"页面坏了"。
  Widget _liveSection() {
    final live = _grants
        .where((g) => (g['user_id'] as num?)?.toInt() != null)
        .where((g) => _liveIds.contains((g['user_id'] as num).toInt()))
        .toList()
      ..sort((a, b) =>
          ((b['granted_at'] as num?)?.toInt() ?? 0)
              .compareTo((a['granted_at'] as num?)?.toInt() ?? 0));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle('生效中', live.length),
        if (live.isEmpty)
          _emptyCard(
            _isAdmin
                ? '目前只有管理员能抽盘（管理员默认持权，不列在这里）。\n'
                    '要把抽盘交给店长/主管，从下面名册里选人授权。'
                : '目前没有人被单独授权。管理员默认可抽盘。',
          )
        else
          ...live.map((g) {
            final uid = (g['user_id'] as num).toInt();
            return _personTile(
              title: _name(g),
              subtitle: _subOf(g),
              trailing: _canManage
                  ? _busy.contains(uid)
                      ? const _MiniSpin()
                      : TextButton(
                          onPressed: () => _revoke(uid, _name(g)),
                          child: const Text('解除',
                              style: TextStyle(
                                  color: AppColors.danger, fontSize: 13)),
                        )
                  : _chip('生效中', AppColors.brand),
            );
          }),
      ],
    );
  }

  /// 从名册选人授权。已在生效中的显示"已授权"且不给点（避免点了个没反应）。
  Widget _addSection() {
    final cands = _candidates;
    final shown = cands.take(50).toList(growable: false);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 18),
        _sectionTitle('授权给人', _members.length),
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: TextField(
            key: const Key('grant-search'),
            controller: _qCtrl,
            onChanged: (v) => setState(() => _q = v),
            style: const TextStyle(color: AppColors.text, fontSize: 14),
            decoration: InputDecoration(
              isDense: true,
              hintText: '搜昵称 / 账号（工号）',
              hintStyle: const TextStyle(color: AppColors.textWeak, fontSize: 13),
              prefixIcon:
                  const Icon(Icons.search, color: AppColors.textWeak, size: 18),
              filled: true,
              fillColor: AppColors.surface,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: AppColors.border),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: AppColors.border),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: AppColors.brand, width: 1.4),
              ),
            ),
          ),
        ),
        if (!_rosterLoaded)
          _emptyCard('没取到员工名册，下拉刷新试试。')
        else if (_members.isEmpty)
          _emptyCard('这台服务器还没有员工名册，先去「管理台 → 组织」把员工加进来，'
              '再回来授权。')
        else if (cands.isEmpty)
          _emptyCard('名册里没有匹配"$_q"的人。抽盘只能授给名册上的员工，'
              '请确认工号，或先去管理台把人加进来。')
        else ...[
          ...shown.map((m) {
            final uid = (m['id'] as num?)?.toInt() ?? 0;
            if (uid <= 0) return const SizedBox.shrink();
            final isLive = _liveIds.contains(uid);
            return _personTile(
              title: _name(m),
              subtitle: _memberSub(m),
              trailing: isLive
                  ? _chip('已授权', AppColors.brand)
                  : !_canManage
                      ? _chip('无权限操作', AppColors.textWeak)
                      : _busy.contains(uid)
                          ? const _MiniSpin()
                          : TextButton(
                              onPressed: () => _grant(uid, _name(m)),
                              child: const Text('授权',
                                  style: TextStyle(
                                      color: AppColors.brand,
                                      fontWeight: FontWeight.w600,
                                      fontSize: 13)),
                            ),
            );
          }),
          if (cands.length > shown.length)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                '还有 ${cands.length - shown.length} 人没显示，用上面的搜索框缩小范围。',
                style: const TextStyle(color: AppColors.textWeak, fontSize: 11),
              ),
            ),
        ],
      ],
    );
  }

  /// 已解除的历史。**这是留痕，不是垃圾桶** —— 特意单独一段摆出来。
  Widget _historySection() {
    final dead = _grants
        .where((g) => (g['user_id'] as num?) != null)
        .where((g) => !_liveIds.contains((g['user_id'] as num).toInt()))
        .toList()
      ..sort((a, b) =>
          ((b['revoked_at'] as num?)?.toInt() ?? 0)
              .compareTo((a['revoked_at'] as num?)?.toInt() ?? 0));
    if (dead.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 18),
        _sectionTitle('已解除（留痕）', dead.length),
        const Padding(
          padding: EdgeInsets.only(bottom: 8),
          child: Text(
            '这些记录不会删除：谁、什么时候被授过、什么时候被解除，都留着。',
            style: TextStyle(color: AppColors.textWeak, fontSize: 11, height: 1.5),
          ),
        ),
        ...dead.map((g) {
          final uid = (g['user_id'] as num).toInt();
          return _personTile(
            dim: true,
            title: _name(g),
            subtitle: _subOf(g, revoked: true),
            trailing: _canManage
                ? _busy.contains(uid)
                    ? const _MiniSpin()
                    : TextButton(
                        onPressed: () => _grant(uid, _name(g)),
                        child: const Text('重新授权',
                            style: TextStyle(
                                color: AppColors.brand, fontSize: 13)),
                      )
                : _chip('已解除', AppColors.textWeak),
          );
        }),
      ],
    );
  }

  // ---- 小部件 ----

  Widget _sectionTitle(String text, int count) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          children: [
            Text(text,
                style: const TextStyle(
                    color: AppColors.text,
                    fontSize: 14,
                    fontWeight: FontWeight.w600)),
            const SizedBox(width: 6),
            Text('$count',
                style: const TextStyle(color: AppColors.textWeak, fontSize: 12)),
          ],
        ),
      );

  Widget _emptyCard(String text) => Container(
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: 4),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.border),
        ),
        child: Text(text,
            style: const TextStyle(
                color: AppColors.textSub, fontSize: 12, height: 1.5)),
      );

  Widget _personTile({
    required String title,
    required String subtitle,
    required Widget trailing,
    bool dim = false,
  }) =>
      Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          children: [
            CircleAvatar(
              radius: 16,
              backgroundColor: AppColors.surfaceHi,
              child: Text(
                title.isEmpty ? '?' : title.substring(0, 1),
                style: TextStyle(
                    color: dim ? AppColors.textWeak : AppColors.text,
                    fontSize: 13),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: dim ? AppColors.textSub : AppColors.text,
                          fontSize: 14,
                          fontWeight: FontWeight.w500)),
                  const SizedBox(height: 2),
                  Text(subtitle,
                      maxLines: 2,
                      style: const TextStyle(
                          color: AppColors.textWeak, fontSize: 11, height: 1.4)),
                ],
              ),
            ),
            const SizedBox(width: 6),
            trailing,
          ],
        ),
      );

  /// 生效中那一行的第二行：谁授的、什么时候授的。
  String _subOf(Map<String, dynamic> g, {bool revoked = false}) {
    final parts = <String>[];
    final u = (g['username'] as String?)?.trim();
    if (u != null && u.isNotEmpty) parts.add('账号 $u');
    final at = (g['granted_at'] as num?)?.toInt();
    if (at != null && at > 0) parts.add('${TimeFmt.dayLabel(at)} ${TimeFmt.hhmm(at)} 授权');
    final by = (g['granted_by'] as num?)?.toInt();
    if (by != null && by > 0) parts.add('授权人 ${_nameOfId(by)}');
    if (revoked) {
      final rt = (g['revoked_at'] as num?)?.toInt();
      if (rt != null && rt > 0) {
        parts.add('${TimeFmt.dayLabel(rt)} ${TimeFmt.hhmm(rt)} 解除');
      }
    }
    return parts.isEmpty ? '—' : parts.join(' · ');
  }

  /// 名册那一行的第二行：部门 / 岗位（名册里带下来的，空的不占位）。
  String _memberSub(Map<String, dynamic> m) {
    final parts = <String>[];
    final u = (m['username'] as String?)?.trim();
    if (u != null && u.isNotEmpty) parts.add('账号 $u');
    final d = (m['dept_name'] as String?)?.trim();
    if (d != null && d.isNotEmpty) parts.add(d);
    final p = (m['position_name'] as String?)?.trim();
    if (p != null && p.isNotEmpty) parts.add(p);
    return parts.isEmpty ? '—' : parts.join(' · ');
  }

  Widget _chip(String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.16),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(text,
            style: TextStyle(color: color, fontSize: 11, height: 1.2)),
      );
}

/// 行内小转圈：只占一个人的位置，不整页 loading（整页会让人以为页面重载了）。
class _MiniSpin extends StatelessWidget {
  const _MiniSpin();

  @override
  Widget build(BuildContext context) => const SizedBox(
        width: 18,
        height: 18,
        child: Padding(
          padding: EdgeInsets.all(2),
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
}
