import 'dart:io';

import 'package:flutter/material.dart';

import '../api.dart';
import '../core/theme.dart';
import '../core/time.dart';
import 'attendance_records.dart';
import 'attendance_request.dart';

/// 考勤打卡（工作模式下随工作模式启用）。
///
/// 界面逻辑刻意"薄"：所有判定（今天算不算迟到、还差几分钟、本月出勤几天）
/// 都由服务端算好下发 —— 客户端只展示结果并触发打卡动作。
/// 一旦前端自己算，桌面端、手机端、管理台就会出现三套口径，对不上时无从查起。
///
/// 打卡时刻**不传**给服务端（服务端用服务器时钟），否则改一下系统时间
/// 就能随便补卡，考勤数据立刻失去意义。
class AttendancePage extends StatefulWidget {
  const AttendancePage({super.key});

  @override
  State<AttendancePage> createState() => _AttendancePageState();
}

class _AttendancePageState extends State<AttendancePage> {
  bool _loading = true;
  bool _busy = false;
  String? _error;
  Map<String, dynamic> _d = const {};

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
      final r = await ImApi().attendanceToday();
      if (!mounted) return;
      setState(() {
        _d = r;
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

  String _deviceName() {
    if (Platform.isWindows) return 'Windows';
    if (Platform.isAndroid) return 'Android';
    if (Platform.isIOS) return 'iOS';
    if (Platform.isMacOS) return 'macOS';
    if (Platform.isLinux) return 'Linux';
    return 'unknown';
  }

  /// 打卡。slot = 第几段（1 = 上班/午休下班，2 = 午休上班/下班）。
  /// 一天 4 次卡的班次里，"午休下班"和"下班"都是 type=out，靠 slot 区分。
  Future<void> _clock(String type, int slot) async {
    setState(() => _busy = true);
    try {
      final r = await ImApi().attendanceClock(type, slot: slot, device: _deviceName());
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text((r['message'] ?? '打卡成功').toString()),
        duration: const Duration(seconds: 2),
      ));
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('打卡失败：$e'),
        duration: const Duration(seconds: 4),
        backgroundColor: AppColors.danger,
      ));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  static String _fmtTs(int? ts) {
    if (ts == null || ts <= 0) return '—';
    final d = DateTime.fromMillisecondsSinceEpoch(ts);
    return '${d.year}-${_p(d.month)}-${_p(d.day)} ${_p(d.hour)}:${_p(d.minute)}';
  }

  static String _p(int n) => n.toString().padLeft(2, '0');

  static const _weekNames = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('考勤打卡'),
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: RefreshIndicator(onRefresh: _load, child: _body()),
    );
  }

  Widget _body() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return _msg(Icons.cloud_off, '拿不到考勤数据', _error!,
          action: TextButton(onPressed: _load, child: const Text('重试')));
    }
    if (_d['available'] != true) {
      // 未启用不是错误：把原因说清楚，员工才知道该找谁
      return _msg(
        Icons.schedule_outlined,
        '考勤未启用',
        (_d['reason'] ?? '当前服务器未启用考勤').toString(),
        extra: '服务器时间：${_fmtTs(_d['serverTime'] as int?)}',
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 30),
      children: [
        _todayCard(),
        const SizedBox(height: 14),
        _clockRow(),
        const SizedBox(height: 18),
        _sectionTitle('本月统计'),
        _monthStats(),
        const SizedBox(height: 18),
        _sectionTitle('更多'),
        _entries(),
        if (_d['group'] != null) ...[
          const SizedBox(height: 16),
          _groupHint(),
        ],
      ],
    );
  }

  Widget _sectionTitle(String t) {
    final sem = AppSemantic.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10, left: 2),
      child: Text(t,
          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: sem.muted)),
    );
  }

  /// 今日概览：日期 / 星期 / 班次 / 状态
  Widget _todayCard() {
    final shift = (_d['shift'] as Map?) ?? const {};
    final today = (_d['today'] as Map?) ?? const {};
    final dow = (_d['dayOfWeek'] as int?) ?? 0;
    final isWorkday = _d['isWorkday'] == true;
    final status = (today['status'] ?? '').toString();
    final statusLabel = (today['statusLabel'] ?? '').toString();
    final note = (today['note'] ?? '').toString();
    final donePunches = (today['donePunches'] as num?)?.toInt() ?? 0;
    final expectedPunches = (today['expectedPunches'] as num?)?.toInt() ?? 0;
    final workedMinutes = (today['workedMinutes'] as num?)?.toInt() ?? 0;
    final expectedWorkMinutes = (today['expectedWorkMinutes'] as num?)?.toInt() ?? 0;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: AppTheme.brandGradient,
        borderRadius: BorderRadius.circular(AppRadii.lg),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('${_d['date'] ?? ''}  ${dow >= 1 && dow <= 7 ? _weekNames[dow - 1] : ''}',
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w700, color: Colors.white)),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(AppRadii.pill),
                ),
                child: Text(isWorkday ? '工作日' : '休息日',
                    style: const TextStyle(fontSize: 11.5, color: Colors.white)),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            '班次 ${shift['name'] ?? '默认班次'} · ${shift['workStart'] ?? ''} - ${shift['workEnd'] ?? ''}'
            '${shift['restStart'] != null ? '（午休 ${shift['restStart']}-${shift['restEnd']}）' : ''}'
            '${shift['crossDay'] == true ? '（跨天）' : ''}',
            style: const TextStyle(fontSize: 13, color: Colors.white70),
          ),
          // 4 次卡的班次光有"状态"不够用：员工真正想知道的是"今天还差几次、
          // 在岗时长够不够"。服务端算好的数直接显示，客户端不重复算。
          if (expectedPunches > 0) ...[
            const SizedBox(height: 10),
            Text(
              '已打 $donePunches/$expectedPunches 次'
              '${workedMinutes > 0 ? ' · 在岗 ${TimeFmt.minutesAsHours(workedMinutes)}' : ''}'
              '${expectedWorkMinutes > 0 ? '（应出勤 ${TimeFmt.minutesAsHours(expectedWorkMinutes)}）' : ''}',
              style: const TextStyle(fontSize: 12.5, color: Colors.white),
            ),
          ],
          if (status.isNotEmpty) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(AppRadii.pill),
                  ),
                  child: Text(statusLabel,
                      style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                          color: statusColor(status))),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(note,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12.5, color: Colors.white)),
                ),
              ],
            ),
          ],
          const SizedBox(height: 10),
          Text(
            '服务器时间 ${_fmtTs(_d['serverTime'] as int?)}',
            style: const TextStyle(fontSize: 11, color: Colors.white70),
          ),
        ],
      ),
    );
  }

  /// 打卡按钮组：**照服务端下发的一日打卡计划渲染**。
  ///
  /// 客户端不判断"今天该打几次卡"—— 2 次卡给两张按钮、4 次卡给四张，
  /// 全由 punchPlan 决定。客户端自己再算一遍"是不是 4 次卡"，迟早会和报表口径打起来
  /// （班次带不带午休窗口、有没有跨天降级，只有服务端说得准）。
  ///
  /// 老服务端不返回 punchPlan 时退回 cards.in / cards.out 两张按钮 —— 向前兼容，
  /// 免得客户端先发了、服务端还没热更，打卡页直接空白。
  Widget _clockRow() {
    final plan = (_d['punchPlan'] as List?) ?? const [];
    if (plan.isEmpty) {
      final cards = (_d['cards'] as Map?) ?? const {};
      return Row(children: [
        Expanded(child: _clockBtn(type: 'in', slot: 1, label: '上班打卡', card: cards['in'] as Map?)),
        const SizedBox(width: 12),
        Expanded(child: _clockBtn(type: 'out', slot: 1, label: '下班打卡', card: cards['out'] as Map?)),
      ]);
    }
    final rows = <Widget>[];
    for (var i = 0; i < plan.length; i += 2) {
      if (i > 0) rows.add(const SizedBox(height: 12));
      rows.add(Row(children: [
        Expanded(child: _clockBtn(type: '', slot: 0, label: '', plan: plan[i] as Map)),
        const SizedBox(width: 12),
        Expanded(
          child: i + 1 < plan.length
              ? _clockBtn(type: '', slot: 0, label: '', plan: plan[i + 1] as Map)
              : const SizedBox.shrink(),
        ),
      ]));
    }
    return Column(children: rows);
  }

  /// 打卡按钮。两种来源共用一套外观：
  ///   · plan 非空 —— 走服务端打卡计划（4 次卡走这里）
  ///   · 只有 card —— 老服务端的 cards.in/out 兜底（2 张按钮）
  Widget _clockBtn({
    required String type,
    required int slot,
    required String label,
    Map? card,
    Map? plan,
  }) {
    final sem = AppSemantic.of(context);
    final p = plan ?? const {};
    final fromPlan = plan != null;
    final done = fromPlan ? p['done'] == true : card != null;
    final exempt = fromPlan && p['exempt'] == true;
    final time = fromPlan ? (p['time'] ?? '').toString() : (card?['time'] ?? '').toString();
    final late = fromPlan ? ((p['lateMinutes'] as num?)?.toInt() ?? 0) : 0;
    final early = fromPlan ? ((p['earlyMinutes'] as num?)?.toInt() ?? 0) : 0;
    final expect = fromPlan ? (p['expectTime'] ?? '').toString() : '';
    final btnLabel = fromPlan ? (p['label'] ?? '打卡').toString() : label;
    final t = fromPlan ? ((p['type'] ?? '') as String) : type;
    final s = fromPlan ? ((p['slot'] as num?)?.toInt() ?? 1) : slot;

    // 副标题按"请假 > 已打 > 迟到/早退 > 应打几点"的优先级给一句话，不堆术语
    String sub;
    if (exempt) {
      sub = '已请假，免打卡';
    } else if (done) {
      final tag = late > 0 ? ' 迟到$late分' : (early > 0 ? ' 早退$early分' : '');
      sub = '$time 已打卡$tag';
    } else {
      sub = _busy ? '处理中…' : (expect.isEmpty ? '点击打卡' : '应打 $expect');
    }
    final warn = late > 0 || early > 0;

    return InkWell(
      borderRadius: BorderRadius.circular(AppRadii.md),
      // 请假豁免的卡不能打（打了服务端也不认），禁用掉比让员工白点一次强
      onTap: (_busy || exempt) ? null : () => _clock(t, s),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 10),
        decoration: BoxDecoration(
          color: (done || exempt) ? sem.cardBg : null,
          gradient: (done || exempt) ? null : AppTheme.brandGradient,
          borderRadius: BorderRadius.circular(AppRadii.md),
          border: Border.all(color: (done || exempt) ? sem.cardBorder : Colors.transparent),
        ),
        child: Column(
          children: [
            Icon(
              exempt
                  ? Icons.event_busy_outlined
                  : (done ? (warn ? Icons.error_outline : Icons.check_circle) : Icons.touch_app_outlined),
              size: 24,
              color: (done || exempt)
                  ? (warn ? AppColors.danger : (exempt ? AppColors.textWeak : AppColors.brand))
                  : Colors.white,
            ),
            const SizedBox(height: 8),
            Text(btnLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w700,
                    color: (done || exempt) ? AppColors.text : Colors.white)),
            const SizedBox(height: 4),
            Text(sub,
                textAlign: TextAlign.center,
                maxLines: 2,
                style: TextStyle(
                    fontSize: 12,
                    color: (done || exempt)
                        ? (warn ? AppColors.danger : AppColors.textSub)
                        : Colors.white70)),
            if (done && !exempt) ...[
              const SizedBox(height: 2),
              const Text('可再次点击更新',
                  style: TextStyle(fontSize: 10.5, color: AppColors.textWeak)),
            ],
          ],
        ),
      ),
    );
  }

  Widget _monthStats() {
    final sum = (_d['monthSummary'] as Map?) ?? const {};
    final items = <List<String>>[
      ['出勤', '${sum['present'] ?? 0}', '天'],
      ['迟到', '${sum['late'] ?? 0}', '次'],
      ['早退', '${sum['early'] ?? 0}', '次'],
      ['缺卡', '${sum['missing'] ?? 0}', '次'],
      ['缺勤', '${sum['absent'] ?? 0}', '天'],
      ['请假', '${sum['leave'] ?? 0}', '天'],
    ];
    final sem = AppSemantic.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
      decoration: BoxDecoration(
        color: sem.cardBg,
        borderRadius: BorderRadius.circular(AppRadii.md),
        border: Border.all(color: sem.cardBorder),
      ),
      child: Row(
        children: items.map((it) {
          final bad = it[0] == '迟到' || it[0] == '早退' || it[0] == '缺卡' || it[0] == '缺勤';
          final v = int.tryParse(it[1]) ?? 0;
          return Expanded(
            child: Column(
              children: [
                Text(it[1],
                    style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: bad && v > 0 ? AppColors.danger : AppColors.brand)),
                const SizedBox(height: 2),
                Text(it[0], style: TextStyle(fontSize: 11.5, color: sem.muted)),
              ],
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _entries() {
    final pending = (_d['pendingRequests'] as int?) ?? 0;
    return Column(
      children: [
        _entryRow(Icons.calendar_month_outlined, '我的考勤记录', '按月查看每天状态与打卡时刻',
            onTap: () => Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => const AttendanceRecordsPage()))),
        const SizedBox(height: 10),
        _entryRow(
          Icons.assignment_outlined,
          '我的申请',
          pending > 0 ? '$pending 条审批中' : '请假 / 补卡 / 外出 / 加班',
          badge: pending > 0 ? '$pending' : null,
          onTap: () => Navigator.of(context)
              .push(MaterialPageRoute(builder: (_) => const AttendanceRequestPage())),
        ),
      ],
    );
  }

  Widget _entryRow(IconData icon, String title, String sub,
      {String? badge, required VoidCallback onTap}) {
    final sem = AppSemantic.of(context);
    return InkWell(
      borderRadius: BorderRadius.circular(AppRadii.md),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: sem.cardBg,
          borderRadius: BorderRadius.circular(AppRadii.md),
          border: Border.all(color: sem.cardBorder),
        ),
        child: Row(
          children: [
            Icon(icon, size: 20, color: AppColors.brand),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text(sub, style: TextStyle(fontSize: 11.5, color: sem.muted)),
                ],
              ),
            ),
            if (badge != null) ...[
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: AppColors.danger,
                  borderRadius: BorderRadius.circular(AppRadii.pill),
                ),
                child: Text(badge,
                    style: const TextStyle(fontSize: 10.5, color: Colors.white)),
              ),
              const SizedBox(width: 8),
            ],
            Icon(Icons.chevron_right, color: sem.muted),
          ],
        ),
      ),
    );
  }

  Widget _groupHint() {
    final sem = AppSemantic.of(context);
    final g = _d['group'] as Map;
    final src = (_d['shiftSource'] ?? '').toString();
    final srcText = src == 'group' ? '考勤组点名' : (src == 'dept' ? '考勤组（部门）' : '组织默认班次');
    return Text(
      '你属于考勤组「${g['name']}」，班次来源：$srcText。'
      '定位要求：${_locLabel(g['locationMode']?.toString())}。',
      style: TextStyle(fontSize: 11.5, height: 1.6, color: sem.muted),
    );
  }

  static String _locLabel(String? m) {
    switch (m) {
      case 'required':
        return '必须提供（桌面端无定位，请用手机打卡）';
      case 'optional':
        return '有就记录';
      default:
        return '不校验';
    }
  }

  Widget _msg(IconData icon, String title, String desc,
      {String? extra, Widget? action}) {
    final sem = AppSemantic.of(context);
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
              if (extra != null) ...[
                const SizedBox(height: 12),
                Text(extra, style: TextStyle(fontSize: 11.5, color: sem.muted)),
              ],
              if (action != null) ...[const SizedBox(height: 14), action],
            ],
          ),
        ),
      ],
    );
  }
}

/// 考勤状态 → 颜色（打卡页与记录页共用，口径只有一处）
Color statusColor(String status) {
  switch (status) {
    case 'normal':
      return AppColors.brand;
    case 'pending':
      return AppColors.brand2;
    case 'late':
    case 'early':
    case 'late_early':
      return AppColors.warn;
    case 'missing':
    case 'absent':
      return AppColors.danger;
    default:
      return AppColors.textSub;
  }
}
