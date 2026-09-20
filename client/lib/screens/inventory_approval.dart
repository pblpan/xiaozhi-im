import 'package:flutter/material.dart';

import '../api.dart';
import '../core/theme.dart';
import '../core/time.dart';

/// 审批中心（M2/P2）—— **单据审批 + 驳回**。
///
/// ── 为什么是"通用"审批，而不是"盘点审批" ──────────────────────────
/// 现在只有盘点单要审，但下一次要审的（退货、调价、盘盈盘亏）一定是同类动作：
/// "某张单据动了数、要人点头"。所以服务端是一张通用 `approvals` 表，
/// 单据类型走 `kind`。这一页也照着通用来做 —— 以后多一种 `kind`，
/// 这一页只多一行中文名，不用再写一个页面。
///
/// ── 三条不写成"看起来对"的规矩 ──────────────────────────────────
/// 1. **驳回理由必填**。驳回不带理由，就是把人拉黑还不告诉他为什么 ——
///    现场只能瞎猜着重扫一遍。所以这里在按钮上就拦住空理由，服务端也会拦。
/// 2. **只能看、不能批的账号不显示按钮**。服务端明确回 `can_approve`，
///    界面据此**不显示**按钮，而不是显示一个点下去 403 的按钮。
///    （这和抽盘授权是同一个原则：不要让用户去撞一堵本来就能预知的墙。）
/// 3. **批完立刻重新拉取**。审批是最怕"看着成功了其实没落库"的动作 ——
///    所以不做本地乐观更新，一律以服务端回来的列表为准。
///
/// ── 一个刻意的取舍 ────────────────────────────────────────────────
/// 「我提交的」只有**撤回**，没有"自己改一下再提交"。改单据是单据那边的事
/// （盘点单在采集页改数量），审批中心只负责"提交/撤回/批/驳"这一条线。
/// 让审批页能改单据内容，两条修改路径迟早会打架。
class InventoryApprovalScreen extends StatefulWidget {
  const InventoryApprovalScreen({super.key, this.initialTab = 0});

  /// 0 = 待我审批，1 = 我提交的。
  final int initialTab;

  @override
  State<InventoryApprovalScreen> createState() =>
      _InventoryApprovalScreenState();
}

class _InventoryApprovalScreenState extends State<InventoryApprovalScreen> {
  final _api = ImApi();

  bool _loading = true;
  String? _err;
  bool _canApprove = false;
  List<Map<String, dynamic>> _pending = const [];
  List<Map<String, dynamic>> _mine = const [];

  /// 正在提交动作的审批 id（防连点：连点两下"驳回"会开出两个理由框）。
  final Set<int> _busy = <int>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent && mounted) setState(() => _loading = true);
    try {
      final results = await Future.wait<dynamic>([
        _api.pendingApprovals(),
        _api.myApprovals(),
      ]);
      if (!mounted) return;
      final p = results[0] as Map<String, dynamic>;
      setState(() {
        _canApprove = p['can_approve'] == true;
        _pending = _maps(p['items']);
        _mine = _maps(results[1] is Map
            ? (results[1] as Map)['items']
            : results[1]);
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

  Future<void> _approve(Map<String, dynamic> a) async {
    final id = _idOf(a);
    if (id == null || _busy.contains(id)) return;
    final ok = await _confirm(
      '通过这张单？',
      '通过后单据状态变为已审批，审批结果会同步写回单据上'
      '（不是只挂在这里）。',
      danger: false,
      yes: '通过',
    );
    if (ok != true || !mounted) return;

    setState(() => _busy.add(id));
    try {
      await _api.approveApproval(id);
      _snack('已通过 ${_labelOf(a)}');
      await _load(silent: true);
    } catch (e) {
      if (mounted) _snack(_errText(e));
    } finally {
      if (mounted) setState(() => _busy.remove(id));
    }
  }

  Future<void> _reject(Map<String, dynamic> a) async {
    final id = _idOf(a);
    if (id == null || _busy.contains(id)) return;

    final ctl = TextEditingController();
    final reason = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          backgroundColor: AppColors.bgElevated,
          title: const Text('驳回理由',
              style: TextStyle(color: AppColors.text, fontSize: 16)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '驳回必须写明理由 —— 提交人全靠这句话知道该回去改什么。',
                style: TextStyle(
                    color: AppColors.textSub, fontSize: 12, height: 1.5),
              ),
              const SizedBox(height: 10),
              TextField(
                key: const Key('reject-reason'),
                controller: ctl,
                autofocus: true,
                maxLines: 3,
                maxLength: 200,
                // 🔴 必须 onChanged 触发重建：下面的「驳回」按钮是按
                //    `ctl.text` 现算可用性的，不重建的话它会**永远停在禁用**上
                //    —— 现象是"输了理由还是点不动"，看着像坏了。
                onChanged: (_) => setD(() {}),
                style: const TextStyle(color: AppColors.text, fontSize: 14),
                decoration: const InputDecoration(
                  hintText: '例如：抽盘数量与货架实物不符，请复称后重扫',
                  hintStyle: TextStyle(color: AppColors.textWeak, fontSize: 12),
                  counterStyle: TextStyle(color: AppColors.textWeak, fontSize: 11),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
            TextButton(
              onPressed: ctl.text.trim().isEmpty
                  ? null
                  : () => Navigator.pop(ctx, ctl.text.trim()),
              child: Text('驳回',
                  style: TextStyle(
                      color: ctl.text.trim().isEmpty
                          ? AppColors.textWeak
                          : AppColors.danger,
                      fontWeight: FontWeight.w600)),
            ),
          ],
        ),
      ),
    );
    // ⚠️ **不 dispose 这个 controller**：弹窗退场的那几帧里视图还会重建一次，
    //    这时候 dispose 会抛 "A TextEditingController was used after being
    //    disposed"。一个字数上限 200 的短命对象，交给 GC 就好。
    if (reason == null || reason.isEmpty || !mounted) return;

    setState(() => _busy.add(id));
    try {
      await _api.rejectApproval(id, reason);
      _snack('已驳回 ${_labelOf(a)}');
      await _load(silent: true);
    } catch (e) {
      if (mounted) _snack(_errText(e));
    } finally {
      if (mounted) setState(() => _busy.remove(id));
    }
  }

  Future<void> _withdraw(Map<String, dynamic> a) async {
    final id = _idOf(a);
    if (id == null || _busy.contains(id)) return;
    final ok = await _confirm(
      '撤回这条审批？',
      '撤回后这条回到"没提过"的状态，单据上的审批状态也会跟着清掉。'
      '已经审完的撤不回来。',
      danger: true,
      yes: '撤回',
    );
    if (ok != true || !mounted) return;

    setState(() => _busy.add(id));
    try {
      await _api.withdrawApproval(id);
      _snack('已撤回 ${_labelOf(a)}');
      await _load(silent: true);
    } catch (e) {
      if (mounted) _snack(_errText(e));
    } finally {
      if (mounted) setState(() => _busy.remove(id));
    }
  }

  // ---- 零件 ----

  static List<Map<String, dynamic>> _maps(Object? v) {
    if (v is! List) return const [];
    return v
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList(growable: false);
  }

  static int? _idOf(Map<String, dynamic> a) => (a['id'] as num?)?.toInt();

  /// 一句话说清"是哪张单"：有标题用标题，没有就用盘点单号。
  static String _labelOf(Map<String, dynamic> a) {
    final t = (a['title'] as String?)?.trim();
    if (t != null && t.isNotEmpty) return t;
    final ref = (a['ref'] as String?)?.trim();
    if (ref != null && ref.isNotEmpty) return ref;
    return '这条审批';
  }

  static String _kindLabel(String? kind) {
    switch (kind) {
      case 'stocktake':
        return '盘点单';
      default:
        return kind == null || kind.isEmpty ? '单据' : kind;
    }
  }

  static String _statusLabel(String? s) {
    switch (s) {
      case 'pending':
        return '待审批';
      case 'approved':
        return '已通过';
      case 'rejected':
        return '已驳回';
      default:
        return s ?? '';
    }
  }

  static Color _statusColor(String? s) {
    switch (s) {
      case 'pending':
        return AppColors.warn;
      case 'approved':
        return AppColors.brand;
      case 'rejected':
        return AppColors.danger;
      default:
        return AppColors.textWeak;
    }
  }

  Future<bool?> _confirm(String title, String body,
          {required bool danger, required String yes}) =>
      showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppColors.bgElevated,
          title:
              Text(title, style: const TextStyle(color: AppColors.text, fontSize: 16)),
          content: Text(body,
              style: const TextStyle(
                  color: AppColors.textSub, fontSize: 13, height: 1.5)),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('再想想')),
            TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(yes,
                    style: TextStyle(
                        color: danger ? AppColors.danger : AppColors.brand,
                        fontWeight: FontWeight.w600))),
          ],
        ),
      );

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  static String _errText(Object e) {
    if (e is ApiException) return e.message;
    return e
        .toString()
        .replaceFirst(RegExp(r'^\w*Exception: '), '')
        .replaceFirst(RegExp(r'^Bad state: '), '');
  }

  // ---- 界面 ----

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      initialIndex: widget.initialTab.clamp(0, 1),
      child: Scaffold(
          backgroundColor: AppColors.bg,
          appBar: AppBar(
            backgroundColor: AppColors.bgElevated,
            title: const Text('审批中心',
                style: TextStyle(color: AppColors.text, fontSize: 17)),
            actions: [
              IconButton(
                tooltip: '刷新',
                icon: const Icon(Icons.refresh, color: AppColors.textSub),
                onPressed: _loading ? null : () => _load(),
              ),
            ],
            bottom: TabBar(
              labelColor: AppColors.brand,
              unselectedLabelColor: AppColors.textSub,
              indicatorColor: AppColors.brand,
              tabs: [
                Tab(text: _pending.isEmpty ? '待我审批' : '待我审批 ${_pending.length}'),
                const Tab(text: '我提交的'),
              ],
            ),
          ),
          body: _loading
              ? const Center(child: CircularProgressIndicator())
              : _err != null
                  ? _errorView()
                  : TabBarView(
                      children: [_pendingTab(), _mineTab()],
                    ),
      ),
    );
  }

  Widget _errorView() => Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off, color: AppColors.danger, size: 40),
              const SizedBox(height: 12),
              Text(_err!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: AppColors.textSub, fontSize: 13)),
              const SizedBox(height: 6),
              const Text('审批要连服务器才做得成（批完了得写回单据上）。',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: AppColors.textWeak, fontSize: 12)),
              const SizedBox(height: 16),
              FilledButton(onPressed: () => _load(), child: const Text('重试')),
            ],
          ),
        ),
      );

  Widget _pendingTab() {
    if (_pending.isEmpty) {
      return _list([_emptyCard('没有待审批的单子。')]);
    }
    return RefreshIndicator(
      onRefresh: () => _load(silent: true),
      child: _list([
        if (!_canApprove)
          Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.warn.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.warn.withValues(alpha: 0.35)),
            ),
            child: const Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.visibility_outlined, color: AppColors.warn, size: 16),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '您不是管理员，这里的单子只能看、不能批。\n'
                    '要审单请让管理员账号操作（服务端也会按管理员权限拦一次）。',
                    style: TextStyle(
                        color: AppColors.warn, fontSize: 12, height: 1.5),
                  ),
                ),
              ],
            ),
          ),
        ..._pending.map((e) => _card(e, inMineTab: false)),
      ]),
    );
  }

  Widget _mineTab() {
    if (_mine.isEmpty) {
      return _list([_emptyCard('您还没提交过审批。')]);
    }
    return RefreshIndicator(
      onRefresh: () => _load(silent: true),
      child: _list(_mine.map((e) => _card(e, inMineTab: true)).toList()),
    );
  }

  Widget _list(List<Widget> children) => ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 28),
        children: children,
      );

  /// 一条审批。**同一个卡片渲染三个地方**（待审、我提交的、已结束的），
  /// 所以按钮区由"状态 + 我在哪一栏 + 有没有权限"现算，不做三套版式 ——
  /// 三套版式迟早会在某个状态上给出不同结论。
  Widget _card(Map<String, dynamic> a, {required bool inMineTab}) {
    final id = _idOf(a) ?? 0;
    final st = a['status'] as String?;
    final busy = _busy.contains(id);
    final canDecide = _canApprove && st == 'pending';

    final submitter = (a['submitter_name'] as String?)?.trim();
    final decidedBy = (a['decided_by_name'] as String?)?.trim();
    final created = (a['created_at'] as num?)?.toInt();
    final decidedAt = (a['decided_at'] as num?)?.toInt();
    final reason = (a['reject_reason'] as String?)?.trim();

    return Container(
      key: ValueKey<String>('approval-$id'),
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
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
              Expanded(
                child: Text(_labelOf(a),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: AppColors.text,
                        fontSize: 15,
                        fontWeight: FontWeight.w600)),
              ),
              const SizedBox(width: 8),
              _chip(_statusLabel(st), _statusColor(st)),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              _chip(_kindLabel(a['kind'] as String?), AppColors.brand2),
              const SizedBox(width: 6),
              if ((a['ref'] as String?)?.isNotEmpty == true)
                Expanded(
                  child: Text('单号 ${a['ref']}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: AppColors.textWeak, fontSize: 11)),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            [
              if (submitter != null && submitter.isNotEmpty) '提交人 $submitter',
              if (created != null && created > 0)
                '${TimeFmt.dayLabel(created)} ${TimeFmt.hhmm(created)}',
            ].join(' · '),
            style: const TextStyle(color: AppColors.textSub, fontSize: 12),
          ),
          if (decidedAt != null && decidedAt > 0)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '${_statusLabel(st)}'
                '${decidedBy != null && decidedBy.isNotEmpty ? ' · $decidedBy' : ''}'
                ' · ${TimeFmt.dayLabel(decidedAt)} ${TimeFmt.hhmm(decidedAt)}',
                style: TextStyle(
                    color: _statusColor(st), fontSize: 12, height: 1.4),
              ),
            ),
          // 驳回理由必须**显眼**：这是提交人唯一能看到的整改依据。
          if (st == 'rejected' && reason != null && reason.isNotEmpty)
            Container(
              margin: const EdgeInsets.only(top: 8),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppColors.danger.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(10),
                border:
                    Border.all(color: AppColors.danger.withValues(alpha: 0.35)),
              ),
              child: Text('驳回理由：$reason',
                  style: const TextStyle(
                      color: AppColors.danger, fontSize: 12, height: 1.5)),
            ),
          ..._payloadLines(a['payload']),
          if (busy)
            const Padding(
              padding: EdgeInsets.only(top: 10),
              child: Align(
                alignment: Alignment.centerRight,
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            )
          else if (canDecide || (st == 'pending' && inMineTab))
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (st == 'pending' && inMineTab)
                    TextButton(
                      onPressed: () => _withdraw(a),
                      child: const Text('撤回',
                          style: TextStyle(
                              color: AppColors.textSub, fontSize: 13)),
                    ),
                  if (canDecide) ...[
                    TextButton(
                      onPressed: () => _reject(a),
                      child: const Text('驳回',
                          style: TextStyle(
                              color: AppColors.danger, fontSize: 13)),
                    ),
                    const SizedBox(width: 4),
                    FilledButton(
                      onPressed: () => _approve(a),
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.brand,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 6),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: const Text('通过',
                          style: TextStyle(
                              fontSize: 13, fontWeight: FontWeight.w600)),
                    ),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// 单据快照。**只挑几个看得懂的键摆出来**，不整块 JSON 倒给用户 ——
  /// 现场没人读 JSON，但"点位/差异数"是他能不能判断该不该批的关键。
  static const _payloadNames = <String, String>{
    'sheet_no': '单号',
    'zone_code': '点位',
    'zone_name': '点位',
    'phase': '阶段',
    'total': '品项',
    'diff': '差异',
    'pending_review': '待复核',
    'note': '说明',
    'remark': '说明',
  };

  List<Widget> _payloadLines(Object? payload) {
    if (payload is! Map) return const [];
    final parts = <String>[];
    for (final e in payload.entries) {
      if (parts.length >= 4) break;
      final k = _payloadNames[e.key.toString()];
      if (k == null) continue;
      final v = e.value;
      if (v == null || v.toString().trim().isEmpty) continue;
      parts.add('$k ${v.toString().trim()}');
    }
    if (parts.isEmpty) return const [];
    return [
      Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Text(parts.join(' · '),
            style: const TextStyle(
                color: AppColors.textSub, fontSize: 12, height: 1.4)),
      ),
    ];
  }

  Widget _emptyCard(String text) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.border),
        ),
        child: Text(text,
            style: const TextStyle(
                color: AppColors.textSub, fontSize: 13, height: 1.5)),
      );

  Widget _chip(String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.16),
          borderRadius: BorderRadius.circular(999),
        ),
        child:
            Text(text, style: TextStyle(color: color, fontSize: 11, height: 1.2)),
      );
}
