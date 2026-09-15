import 'package:flutter/material.dart';

import '../api.dart';
import '../core/theme.dart';
import '../core/time.dart';
import 'attendance.dart' show statusColor;

/// 我的考勤记录（按月）。
///
/// 数据同样全部来自服务端 `/api/attendance/my`：哪一天正常、哪一天迟到几分钟，
/// 都是服务端按班次与申请单算好的。客户端只负责摆出来 —— 这里若自己算，
/// 员工看到的数字和管理台看到的就会不一样，然后没人说得清哪个对。
class AttendanceRecordsPage extends StatefulWidget {
  const AttendanceRecordsPage({super.key});

  @override
  State<AttendanceRecordsPage> createState() => _AttendanceRecordsPageState();
}

class _AttendanceRecordsPageState extends State<AttendanceRecordsPage> {
  bool _loading = true;
  String? _error;
  Map<String, dynamic> _d = const {};
  late String _month = _monthOf(DateTime.now());

  static String _monthOf(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}';

  static const _weekNames = ['一', '二', '三', '四', '五', '六', '日'];

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
      final r = await ImApi().attendanceMy(month: _month);
      if (!mounted) return;
      setState(() {
        _d = r;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  void _shiftMonth(int delta) {
    final parts = _month.split('-');
    final d = DateTime(int.parse(parts[0]), int.parse(parts[1]) + delta, 1);
    setState(() => _month = _monthOf(d));
    _load();
  }

  Future<void> _showDetail(String day) async {
    try {
      final r = await ImApi().attendanceRecords(day: day);
      final items = (r['items'] as List?) ?? const [];
      if (!mounted) return;
      await showModalBottomSheet<void>(
        context: context,
        backgroundColor: AppColors.bgElevated,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadii.lg)),
        ),
        builder: (ctx) {
          final sem = AppSemantic.of(ctx);
          return Padding(
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 26),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('$day 打卡流水',
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                const SizedBox(height: 6),
                Text('同一天同一张卡可以有多条（更新打卡会保留历史），统计只取到点的那一次。'
                    '一天 4 次卡的班次：上班 → 下班 → 上班 → 下班，靠打卡时刻区分是哪一段。',
                    style: TextStyle(fontSize: 11.5, height: 1.5, color: sem.muted)),
                const SizedBox(height: 12),
                if (items.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 18),
                    child: Text('这天没有打卡记录', style: TextStyle(color: sem.muted)),
                  )
                else
                  for (final it in items)
                    if (it is Map)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                              decoration: BoxDecoration(
                                color: (it['type'] == 'in' ? AppColors.brand : AppColors.brand2)
                                    .withValues(alpha: 0.16),
                                borderRadius: BorderRadius.circular(AppRadii.pill),
                              ),
                              // 标签一律用服务端下发的 punchLabel（客户端不按 type 猜），
                              // 并且**这一行必须把时刻也显示出来**：4 次卡的班次里
                              // 卡名统一是"上班/下班"，光看名字分不出是哪一段
                              // （第 1 段的 out 和收工都叫"下班"）。
                              child: Text(
                                  (it['punchLabel'] ?? (it['type'] == 'in' ? '上班' : '下班')).toString(),
                                  style: TextStyle(
                                      fontSize: 11.5,
                                      fontWeight: FontWeight.w600,
                                      color: it['type'] == 'in' ? AppColors.brand : AppColors.brand2)),
                            ),
                            const SizedBox(width: 10),
                            Text((it['time'] ?? '').toString(),
                                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                _sourceLabel(it['source']?.toString()) +
                                    ((it['address'] ?? '').toString().isNotEmpty
                                        ? ' · ${it['address']}'
                                        : ''),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(fontSize: 11.5, color: sem.muted),
                              ),
                            ),
                          ],
                        ),
                      ),
              ],
            ),
          );
        },
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('加载流水失败：$e')));
    }
  }

  static String _sourceLabel(String? s) {
    switch (s) {
      case 'admin':
        return '管理员补录';
      case 'makeup':
        return '补卡审批';
      default:
        return '客户端打卡';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('我的考勤')),
      body: Column(
        children: [
          _monthBar(),
          Expanded(child: RefreshIndicator(onRefresh: _load, child: _body())),
        ],
      ),
    );
  }

  Widget _monthBar() {
    final sem = AppSemantic.of(context);
    final shift = (_d['shift'] as Map?) ?? const {};
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: sem.cardBg,
        border: Border(bottom: BorderSide(color: sem.cardBorder)),
      ),
      child: Column(
        children: [
          Row(
            children: [
              IconButton(
                onPressed: () => _shiftMonth(-1),
                icon: const Icon(Icons.chevron_left),
                tooltip: '上一月',
              ),
              Expanded(
                child: Center(
                  child: Text(_month,
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                ),
              ),
              IconButton(
                onPressed: () => _shiftMonth(1),
                icon: const Icon(Icons.chevron_right),
                tooltip: '下一月',
              ),
            ],
          ),
          if (shift.isNotEmpty)
            Text('班次 ${shift['name'] ?? ''} · ${shift['workStart'] ?? ''} - ${shift['workEnd'] ?? ''}',
                style: TextStyle(fontSize: 11.5, color: sem.muted)),
        ],
      ),
    );
  }

  Widget _body() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 70),
            child: Column(
              children: [
                const Icon(Icons.cloud_off, size: 40),
                const SizedBox(height: 12),
                Text('加载失败：$_error', textAlign: TextAlign.center),
                TextButton(onPressed: _load, child: const Text('重试')),
              ],
            ),
          ),
        ],
      );
    }
    if (_d['available'] == false) {
      final sem = AppSemantic.of(context);
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 80, left: 36, right: 36),
            child: Text('当前未启用考勤',
                textAlign: TextAlign.center, style: TextStyle(color: sem.muted)),
          ),
        ],
      );
    }

    final days = (_d['days'] as List?) ?? const [];
    final sum = (_d['summary'] as Map?) ?? const {};
    // 倒序显示：员工最关心的是最近几天
    final ordered = days.reversed.toList();

    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 26),
      children: [
        _summary(sum),
        const SizedBox(height: 14),
        for (final d in ordered)
          if (d is Map) _dayRow(Map<String, dynamic>.from(d)),
      ],
    );
  }

  Widget _summary(Map sum) {
    final sem = AppSemantic.of(context);
    final items = <List<String>>[
      ['出勤', '${sum['present'] ?? 0}'],
      ['迟到', '${sum['late'] ?? 0}'],
      ['早退', '${sum['early'] ?? 0}'],
      ['缺卡', '${sum['missing'] ?? 0}'],
      ['缺勤', '${sum['absent'] ?? 0}'],
      ['请假', '${sum['leave'] ?? 0}'],
    ];
    final worked = (sum['workedMinutes'] as num?)?.toInt() ?? 0;
    final expectWork = (sum['expectedWorkMinutes'] as num?)?.toInt() ?? 0;
    final fullDays = (sum['fullDays'] as num?)?.toInt() ?? 0;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
      decoration: BoxDecoration(
        color: sem.cardBg,
        borderRadius: BorderRadius.circular(AppRadii.md),
        border: Border.all(color: sem.cardBorder),
      ),
      child: Column(
        children: [
          Row(
            children: items.map((it) {
              final bad = it[0] != '出勤';
              final v = num.tryParse(it[1]) ?? 0;
              return Expanded(
                child: Column(
                  children: [
                    Text(it[1],
                        style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                            color: bad && v > 0 ? AppColors.danger : AppColors.brand)),
                    const SizedBox(height: 2),
                    Text(it[0], style: TextStyle(fontSize: 11, color: sem.muted)),
                  ],
                ),
              );
            }).toList(),
          ),
          // 4 次卡的班次，"缺卡"这个计数会明显变大（一天最多缺 4 张），
          // 所以额外把"在岗多少小时 / 应出勤多少小时"摆出来：
          // 员工真正想知道的是"我够不够工时"，不是"我少打了几次指纹"
          if (expectWork > 0) ...[
            const Divider(height: 18),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text('本月在岗 ${TimeFmt.minutesAsHours(worked)}',
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                Text(' / 应出勤 ${TimeFmt.minutesAsHours(expectWork)}',
                    style: TextStyle(fontSize: 12, color: sem.muted)),
                if (fullDays > 0) ...[
                  Text(' · 全勤 $fullDays 天',
                      style: TextStyle(fontSize: 12, color: sem.muted)),
                ],
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _dayRow(Map<String, dynamic> d) {
    final sem = AppSemantic.of(context);
    final day = (d['day'] ?? '').toString();
    final wd = (d['weekday'] as int?) ?? 0; // 0=周日
    final status = (d['status'] ?? '').toString();
    final label = (d['statusLabel'] ?? '').toString();
    final note = (d['note'] ?? '').toString();
    final isRest = status == 'rest';
    final wdText = wd == 0 ? '日' : _weekNames[wd - 1];

    return Opacity(
      opacity: isRest ? 0.65 : 1,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadii.sm),
        onTap: () => _showDetail(day),
        child: Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: sem.cardBg,
            borderRadius: BorderRadius.circular(AppRadii.sm),
            border: Border.all(color: sem.cardBorder),
          ),
          child: Row(
            children: [
              SizedBox(
                width: 66,
                child: Text(day.substring(5),
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              ),
              SizedBox(
                width: 30,
                child: Text('周$wdText', style: TextStyle(fontSize: 11.5, color: sem.muted)),
              ),
              SizedBox(
                width: 78,
                child: Text(
                  (d['firstInTime'] ?? '—').toString(),
                  style: const TextStyle(fontSize: 12.5),
                ),
              ),
              SizedBox(
                width: 78,
                child: Text(
                  (d['lastOutTime'] ?? '—').toString(),
                  style: const TextStyle(fontSize: 12.5),
                ),
              ),
              // 4 次卡的班次光看"上班最早/下班最晚"看不出中间两次打没打
              // （中午那两张缺了也照样有 08:00 和 17:00），所以补一个打卡计数
              if (((d['expectedPunches'] as num?)?.toInt() ?? 0) >= 4) ...[
                SizedBox(
                  width: 44,
                  child: Text(
                    '${(d['donePunches'] as num?)?.toInt() ?? 0}/${(d['expectedPunches'] as num?)?.toInt() ?? 0}次',
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: ((d['missingPunches'] as List?) ?? const []).isEmpty
                          ? AppColors.brand
                          : AppColors.danger,
                    ),
                  ),
                ),
              ],
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: statusColor(status).withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(AppRadii.pill),
                ),
                child: Text(label,
                    style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        color: statusColor(status))),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(note,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11.5, color: sem.muted)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
