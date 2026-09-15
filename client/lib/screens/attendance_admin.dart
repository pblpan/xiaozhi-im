import 'package:flutter/material.dart';

import '../api.dart';
import '../core/theme.dart';
import '../core/time.dart';
import 'attendance.dart' show statusColor;

/// 考勤记录（**管理员专属**）—— 今日/某日的全员出勤看板 + 代员工补卡。
///
/// ─────────────────────────────────────────────────────────────
/// 为什么管理员需要的不是"打卡页"，而是这一页
/// ─────────────────────────────────────────────────────────────
/// 管理员是系统角色，不在员工名册里，不参与考勤（见 server/src/apps.js 的
/// BUILTIN_APPS）。所以他需要的不是"我自己打卡"，而是两件高频的事：
///
///   ① **今天谁还没打**（一眼看出缺谁，而不是去数报表）
///   ② **谁漏打了，我替他补上**（手机当场就能办，不用回办公室开电脑）
///
/// 管理台「考勤管理」里的报表 / 班次 / 考勤组 / 审批是完整能力，手机屏上搬不动
/// 也不需要 —— 这一页只做上面这两件事，其余留在管理台。
///
/// ─────────────────────────────────────────────────────────────
/// 两条纪律（与员工端打卡页一致）
/// ─────────────────────────────────────────────────────────────
/// 1. **判定一律来自服务端**。谁该打几张卡、缺的是"午休下班"还是"下班"、
///    迟到几分钟，都由 /api/admin/attendance/overview 用与报表同一个判定引擎
///    算好下发。客户端只负责摆出来 —— 这里若自己算一次，手机上看板和管理台
///    报表就会给出两个答案，对不上时无从查起。
/// 2. **补卡必须指明"第几次卡"**（slot）。4 次卡的班次里 out1 是"午休下班"、
///    out2 才是"下班"，只给 in/out 会把卡补到错误的段上 —— 看着补了、
///    报表上那天依旧缺卡。所以补卡选项直接**照服务端下发的 punchPlan 渲染**，
///    主管点的是"午休上班"这张卡，而不是自己拼 type+slot。
class AttendanceAdminPage extends StatefulWidget {
  const AttendanceAdminPage({super.key});

  @override
  State<AttendanceAdminPage> createState() => _AttendanceAdminPageState();
}

class _AttendanceAdminPageState extends State<AttendanceAdminPage> {
  bool _loading = true;
  String? _error;
  Map<String, dynamic> _d = const {};
  List<Map<String, dynamic>> _pending = const [];
  Map<String, dynamic> _counts = const {};
  late String _day = _dayOf(DateTime.now());

  static String _dayOf(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  static const _weekNames = ['一', '二', '三', '四', '五', '六', '日'];

  bool get _isToday => _day == _dayOf(DateTime.now());

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final api = ImApi();
      final ov = await api.adminAttOverview(day: _day);
      // 待审批是**附加上下文**：拉不到不该让整页打不开 ——
      // 主管点进来最想看的是"今天谁没打卡"，那个数字在 overview 里。
      var pending = <Map<String, dynamic>>[];
      var counts = <String, dynamic>{};
      try {
        final rq = await api.adminAttRequests();
        pending = ((rq['items'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
        counts = ((rq['counts'] as Map?) ?? const {}).cast<String, dynamic>();
      } catch (_) {
        // 静默：没有审批权限/接口异常都不影响看板本身
      }
      if (!mounted) return;
      setState(() {
        _d = ov;
        _pending = pending;
        _counts = counts;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  /// 切到前一天 / 后一天。**不允许看未来** —— 未来的考勤没有任何判定意义，
  /// 翻过去只会看到一屏"尚未到来"，反倒让人以为出问题了。
  void _shiftDay(int delta) {
    final d = DateTime.parse(_day).add(Duration(days: delta));
    final t = DateTime.now();
    if (d.isAfter(DateTime(t.year, t.month, t.day))) return;
    setState(() => _day = _dayOf(d));
    _load();
  }

  void _toast(String s) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(s), duration: const Duration(seconds: 3)),
    );
  }

  static int _n(dynamic v) => v is num ? v.toInt() : (int.tryParse('$v') ?? 0);

  List<Map<String, dynamic>> get _items => ((_d['items'] as List?) ?? const [])
      .whereType<Map>()
      .map((e) => Map<String, dynamic>.from(e))
      .toList();

  Map<String, dynamic> get _stats =>
      ((_d['stats'] as Map?) ?? const {}).cast<String, dynamic>();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('考勤记录'),
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Column(
        children: [
          _dayBar(),
          Expanded(
            child: RefreshIndicator(onRefresh: _load, child: _body()),
          ),
        ],
      ),
    );
  }

  /// 日期条：看的是**哪一天**必须一直挂在眼前 —— 主管最怕的是"以为在看今天，
  /// 其实看的是昨天"，然后照着昨天的缺卡去给人打电话。
  Widget _dayBar() {
    final sem = AppSemantic.of(context);
    final d = DateTime.parse(_day);
    final label = _isToday ? '今天' : '${d.month}月${d.day}日';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: sem.cardBg,
        border: Border(bottom: BorderSide(color: sem.cardBorder)),
      ),
      child: Row(
        children: [
          IconButton(
            tooltip: '前一天',
            onPressed: () => _shiftDay(-1),
            icon: const Icon(Icons.chevron_left),
          ),
          Expanded(
            child: Column(
              children: [
                Text('$label · 周${_weekNames[d.weekday - 1]}',
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(
                  _d['isWorkday'] == false ? '非工作日' : '工作日',
                  style: TextStyle(
                      fontSize: 11.5,
                      color: _d['isWorkday'] == false ? sem.muted : AppColors.brand),
                ),
              ],
            ),
          ),
          if (!_isToday)
            TextButton(onPressed: () {
              setState(() => _day = _dayOf(DateTime.now()));
              _load();
            }, child: const Text('回今天')),
          IconButton(
            tooltip: '后一天',
            onPressed: _isToday ? null : () => _shiftDay(1),
            icon: const Icon(Icons.chevron_right),
          ),
        ],
      ),
    );
  }

  Widget _body() {
    if (_loading && _d.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return _hint(
        icon: Icons.cloud_off,
        title: '拿不到考勤数据',
        desc: _error!,
        action: TextButton(onPressed: _load, child: const Text('重试')),
      );
    }
    final items = _items;
    if (items.isEmpty) {
      return _hint(
        icon: Icons.groups_outlined,
        title: '还没有员工',
        desc: '这一页列的是组织员工。先去「组织机构」里按工号录入员工，\n'
            '录入后他们的考勤才会出现在这里。',
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 28),
      children: [
        _statsCard(),
        if (_pending.isNotEmpty) ...[const SizedBox(height: 14), _pendingCard()],
        const SizedBox(height: 18),
        _sectionTitle('员工出勤（${items.length} 人）'),
        ...items.map(_personTile),
      ],
    );
  }

  Widget _sectionTitle(String t) {
    final sem = AppSemantic.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10, left: 2),
      child: Text(t,
          style: TextStyle(
              fontSize: 13, fontWeight: FontWeight.w600, color: sem.muted, letterSpacing: 0.5)),
    );
  }

  /// 概览数字。刻意只放"主管会据此打电话"的几个 —— 数字堆太多就没人看了。
  Widget _statsCard() {
    final sem = AppSemantic.of(context);
    final s = _stats;
    final boxes = <Widget>[
      _statBox('应出勤', _n(s['total']), AppColors.text),
      _statBox('已出勤', _n(s['present']), AppColors.brand),
      _statBox('迟到', _n(s['late']), AppColors.warn),
      _statBox('缺卡', _n(s['missing']), AppColors.danger),
      _statBox('缺勤', _n(s['absent']), AppColors.danger),
      _statBox('请假', _n(s['leave']), AppColors.brand2),
    ];
    final done = _n(s['punchesDone']);
    final expect = _n(s['punchesExpected']);
    final missPunch = _n(s['missingPunches']);
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 14, 12, 12),
      decoration: BoxDecoration(
        color: sem.cardBg,
        borderRadius: BorderRadius.circular(AppRadii.md),
        border: Border.all(color: sem.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LayoutBuilder(builder: (ctx, c) {
            final w = (c.maxWidth - 16) / 3;
            return Wrap(
              spacing: 8,
              runSpacing: 8,
              children: boxes.map((b) => SizedBox(width: w, child: b)).toList(),
            );
          }),
          const SizedBox(height: 10),
          Text(
            '打卡张数 $done / $expect'
            '${missPunch > 0 ? '，还缺 $missPunch 张' : '，今日无缺卡'}',
            style: TextStyle(fontSize: 11.5, color: sem.muted),
          ),
          // 4 次卡下"人数"已经不够说明问题：全组都在岗、但一半人没打午休卡，
          // 出勤率看着 100%，实际报表上全是缺卡。所以张数必须单独给一行。
          if (expect > done)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('（4 次卡的班次一天要打 4 张，只看人数会把漏打午休卡的人算成"正常"）',
                  style: TextStyle(fontSize: 11, height: 1.5, color: sem.muted)),
            ),
        ],
      ),
    );
  }

  Widget _statBox(String label, int value, Color color) {
    final sem = AppSemantic.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        color: sem.cardBorder.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(AppRadii.sm),
      ),
      child: Column(
        children: [
          Text('$value',
              style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700, color: color)),
          const SizedBox(height: 2),
          Text(label, style: TextStyle(fontSize: 11.5, color: sem.muted)),
        ],
      ),
    );
  }

  /// 待审批：主管的"待办"。补卡审批通过后服务端会**自动补写打卡记录**，
  /// 所以在这里点一下"通过"，那个人的缺卡立刻消失，不用再去管理台。
  Widget _pendingCard() {
    final sem = AppSemantic.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
      decoration: BoxDecoration(
        color: sem.cardBg,
        borderRadius: BorderRadius.circular(AppRadii.md),
        border: Border.all(color: AppColors.warn.withValues(alpha: 0.45)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.pending_actions, size: 18, color: AppColors.warn),
              const SizedBox(width: 8),
              Text('待审批 ${_pending.length} 条',
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              const Spacer(),
              Text('共审批过 ${_n(_counts['approved'])} 条',
                  style: TextStyle(fontSize: 11, color: sem.muted)),
            ],
          ),
          const SizedBox(height: 6),
          ..._pending.take(6).map(_pendingRow),
          if (_pending.length > 6)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text('还有 ${_pending.length - 6} 条，请到管理台「考勤管理 → 申请审批」处理',
                  style: TextStyle(fontSize: 11.5, color: sem.muted)),
            ),
        ],
      ),
    );
  }

  Widget _pendingRow(Map<String, dynamic> r) {
    final sem = AppSemantic.of(context);
    final who = (r['nickname'] ?? r['username'] ?? '').toString();
    final kind = (r['kindLabel'] ?? '').toString();
    final desc = (r['desc'] ?? '').toString();
    return InkWell(
      borderRadius: BorderRadius.circular(AppRadii.sm),
      onTap: () => _openReview(r),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('$who · $kind',
                      style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text(desc,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11.5, height: 1.5, color: sem.muted)),
                ],
              ),
            ),
            const SizedBox(width: 8),
            TextButton(onPressed: () => _openReview(r), child: const Text('处理')),
          ],
        ),
      ),
    );
  }

  Widget _personTile(Map<String, dynamic> u) {
    final sem = AppSemantic.of(context);
    final status = (u['status'] ?? '').toString();
    final statusLabel = (u['statusLabel'] ?? status).toString();
    final note = (u['note'] ?? '').toString();
    final name = (u['nickname'] ?? u['username'] ?? '').toString();
    final no = (u['employeeNo'] ?? '').toString();
    final dept = (u['deptName'] ?? '').toString();
    final punches = ((u['punches'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
    final worked = TimeFmt.minutesAsHours(_n(u['workedMinutes']));
    final shiftName = (u['shiftName'] ?? '').toString();

    final meta = <String>[
      if (no.isNotEmpty) '工号 $no',
      if (dept.isNotEmpty) dept,
      if (shiftName.isNotEmpty) shiftName,
    ].join(' · ');

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadii.md),
        onTap: () => _openFix(u),
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 11, 12, 10),
          decoration: BoxDecoration(
            color: sem.cardBg,
            borderRadius: BorderRadius.circular(AppRadii.md),
            border: Border.all(color: sem.cardBorder),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 14.5, fontWeight: FontWeight.w600)),
                        if (meta.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(meta,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 11.5, color: sem.muted)),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  _chip(statusLabel, statusColor(status)),
                ],
              ),
              if (punches.isNotEmpty) ...[
                const SizedBox(height: 8),
                Wrap(spacing: 6, runSpacing: 6, children: punches.map(_punchChip).toList()),
              ],
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      note.isEmpty ? '在岗 $worked' : '$note · 在岗 $worked',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11.5, color: sem.muted),
                    ),
                  ),
                  Text('补卡', style: TextStyle(fontSize: 12, color: AppColors.brand)),
                  Icon(Icons.chevron_right, size: 18, color: sem.muted),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 一张卡一个标签：「应打 12:00」+「已打 12:01」/「缺卡」/「免打卡」。
  /// 4 次卡的班次靠它把"缺的是午休下班还是下午上班"说清楚。
  Widget _punchChip(Map<String, dynamic> p) {
    final done = p['done'] == true;
    final exempt = p['exempt'] == true;
    final due = p['due'] == true;
    final status = (p['status'] ?? '').toString();
    final label = (p['label'] ?? '').toString();
    final expect = (p['expectTime'] ?? '').toString();
    final time = (p['time'] ?? '').toString();
    final late = _n(p['lateMinutes']);
    final early = _n(p['earlyMinutes']);

    final color = exempt
        ? AppColors.textSub
        : (done ? statusColor(status) : (due ? AppColors.danger : AppColors.textSub));
    final text = done
        ? '$label $time${late > 0 ? ' 迟到$late分' : (early > 0 ? ' 早退$early分' : '')}'
        : (exempt ? '$label 免打卡' : '$label ${due ? '缺' : '待'}（应打 $expect）');

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(AppRadii.sm),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Text(text, style: TextStyle(fontSize: 11.5, color: color)),
    );
  }

  Widget _chip(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(AppRadii.pill),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(text,
          style: TextStyle(fontSize: 11.5, color: color, fontWeight: FontWeight.w600)),
    );
  }

  Widget _hint({
    required IconData icon,
    required String title,
    required String desc,
    Widget? action,
  }) {
    final sem = AppSemantic.of(context);
    // 用可滚动容器包一层，空状态下也能下拉刷新
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 80, left: 36, right: 36),
          child: Column(
            children: [
              Icon(icon, size: 46, color: sem.muted),
              const SizedBox(height: 14),
              Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              const SizedBox(height: 10),
              Text(desc,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13, height: 1.7, color: sem.muted)),
              if (action != null) ...[const SizedBox(height: 14), action],
            ],
          ),
        ),
      ],
    );
  }

  /* ==================== 代补卡 ==================== */

  Future<void> _openFix(Map<String, dynamic> u) async {
    final punches = ((u['punches'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
    if (punches.isEmpty) {
      _toast('这位员工今天没有需要打的卡（可能是休息日或已请假）');
      return;
    }
    // 默认选中**第一张该打却没打的卡** —— 主管点进来的动机就是补那张。
    // 让他自己去认"我该选 in 还是 out、slot 1 还是 2"，正是补错卡的来源。
    var idx = punches.indexWhere(
        (p) => p['due'] == true && p['done'] != true && p['exempt'] != true);
    if (idx < 0) idx = punches.indexWhere((p) => p['done'] != true);
    if (idx < 0) idx = 0;

    final name = (u['nickname'] ?? u['username'] ?? '').toString();
    var picked = idx;
    final ctrl = TextEditingController(
        text: (punches[picked]['expectTime'] ?? '').toString());

    final okd = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.bgElevated,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadii.lg)),
      ),
      builder: (ctx) => StatefulBuilder(builder: (ctx, setSheet) {
        final sem = AppSemantic.of(ctx);
        return Padding(
          padding: EdgeInsets.only(
            left: 16,
            right: 16,
            top: 16,
            bottom: 16 + MediaQuery.of(ctx).viewInsets.bottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('给 $name 补卡',
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Text('$_day · 补哪一张卡、补几点，记录里都会写明来源是管理员补录',
                  style: TextStyle(fontSize: 11.5, height: 1.5, color: sem.muted)),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (var i = 0; i < punches.length; i++)
                    _pickChip(
                      ctx,
                      text: '${punches[i]['label']}'
                          '${punches[i]['done'] == true ? '（已打 ${punches[i]['time']}）' : '（应打 ${punches[i]['expectTime']}）'}',
                      selected: picked == i,
                      onTap: () {
                        setSheet(() => picked = i);
                        ctrl.text = (punches[i]['expectTime'] ?? '').toString();
                      },
                    ),
                ],
              ),
              const SizedBox(height: 16),
              TextField(
                controller: ctrl,
                keyboardType: TextInputType.datetime,
                decoration: const InputDecoration(
                  labelText: '打卡时刻（HH:MM）',
                  hintText: '例如 08:00',
                ),
              ),
              const SizedBox(height: 8),
              Text('补的是"$_day 这一天"的卡；同一张卡重复补会覆盖上一次，历史流水仍可查。',
                  style: TextStyle(fontSize: 11.5, height: 1.5, color: sem.muted)),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(ctx).pop(false),
                      child: const Text('取消'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton(
                      onPressed: () => Navigator.of(ctx).pop(true),
                      child: const Text('确认补卡'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      }),
    );

    if (okd != true) return;
    final time = ctrl.text.trim();
    if (!RegExp(r'^\d{1,2}:\d{2}$').hasMatch(time)) {
      _toast('时刻格式要对，例如 08:00');
      return;
    }
    final p = punches[picked];
    try {
      await ImApi().adminAttAddRecord(
        userId: _n(u['userId']),
        day: _day,
        type: (p['type'] ?? '').toString(),
        slot: _n(p['slot']) == 2 ? 2 : 1,
        time: time,
      );
      _toast('已为 $name 补上「${p['label']}」$time');
      await _load();
    } catch (e) {
      _toast('补卡失败：$e');
    }
  }

  Widget _pickChip(BuildContext ctx,
      {required String text, required bool selected, required VoidCallback onTap}) {
    final color = selected ? AppColors.brand : AppSemantic.of(ctx).muted;
    return InkWell(
      borderRadius: BorderRadius.circular(AppRadii.sm),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: color.withValues(alpha: selected ? 0.2 : 0.1),
          borderRadius: BorderRadius.circular(AppRadii.sm),
          border: Border.all(
              color: color.withValues(alpha: selected ? 0.7 : 0.25),
              width: selected ? 1.4 : 1),
        ),
        child: Text(text,
            style: TextStyle(
                fontSize: 12, color: selected ? AppColors.brand : null,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400)),
      ),
    );
  }

  /* ==================== 审批 ==================== */

  Future<void> _openReview(Map<String, dynamic> r) async {
    final name = (r['nickname'] ?? r['username'] ?? '').toString();
    final kind = (r['kindLabel'] ?? '').toString();
    final desc = (r['desc'] ?? '').toString();
    final reason = (r['reason'] ?? '').toString();

    final res = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.bgElevated,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadii.lg)),
      ),
      builder: (ctx) {
        final sem = AppSemantic.of(ctx);
        return Padding(
          padding: EdgeInsets.only(
            left: 16,
            right: 16,
            top: 16,
            bottom: 16 + MediaQuery.of(ctx).viewInsets.bottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('$name 的$kind申请',
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              Text(desc, style: const TextStyle(fontSize: 13.5, height: 1.6)),
              if (reason.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text('事由：$reason',
                    style: TextStyle(fontSize: 12.5, height: 1.6, color: sem.muted)),
              ],
              const SizedBox(height: 10),
              Text(
                kind == '补卡'
                    ? '通过后服务端会**自动补写**当天那张打卡记录，那个人立刻从「缺卡」变正常。'
                    : '通过后当天按免考勤计入，不再算缺勤。',
                style: TextStyle(fontSize: 11.5, height: 1.6, color: sem.muted),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(ctx).pop('reject'),
                      child: const Text('驳回'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton(
                      onPressed: () => Navigator.of(ctx).pop('approve'),
                      child: const Text('通过'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
    if (res == null) return;
    try {
      await ImApi().adminAttReview(_n(r['id']), approve: res == 'approve');
      _toast(res == 'approve' ? '已通过' : '已驳回');
      await _load();
    } catch (e) {
      _toast('处理失败：$e');
    }
  }
}
