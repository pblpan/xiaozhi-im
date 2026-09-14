import 'package:flutter/material.dart';

import '../api.dart';
import '../core/theme.dart';

/// 我的申请（请假 / 补卡 / 外出 / 加班）。
///
/// 为什么把四类申请放在一个页面：它们的**表单差别不大、审批链路完全一样**，
/// 拆成四个页面只会让"我要请假"变成"我该点哪个入口"。这里用类型切换 + 动态表单。
///
/// 审批通过之后的业务后果（补卡写入记录、请假豁免缺勤）全部由服务端处理，
/// 客户端不做任何"我是不是算请假了"的判断 —— 那属于判定口径，只能在服务端一处。
class AttendanceRequestPage extends StatefulWidget {
  const AttendanceRequestPage({super.key});

  @override
  State<AttendanceRequestPage> createState() => _AttendanceRequestPageState();
}

class _AttendanceRequestPageState extends State<AttendanceRequestPage> {
  bool _loading = true;
  bool _busy = false;
  String? _error;
  List<Map<String, dynamic>> _items = const [];

  String _kind = 'leave';
  // 请假
  DateTime _leaveStart = DateTime.now();
  DateTime _leaveEnd = DateTime.now();
  int _half = 0;
  String _leaveType = 'personal';
  // 补卡
  DateTime _makeupDay = DateTime.now();
  String _clockType = 'in';
  TimeOfDay _makeupTime = const TimeOfDay(hour: 8, minute: 50);
  // 外出 / 加班（同日内的起止时刻）
  DateTime _rangeDay = DateTime.now();
  TimeOfDay _rangeStart = const TimeOfDay(hour: 9, minute: 0);
  TimeOfDay _rangeEnd = const TimeOfDay(hour: 18, minute: 0);
  // 共同
  final _reasonCtrl = TextEditingController();

  static const _leaveTypes = [
    ['personal', '事假'],
    ['sick', '病假'],
    ['annual', '年假'],
    ['comp', '调休'],
  ];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _reasonCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await ImApi().attendanceRequests();
      if (!mounted) return;
      final raw = (r['items'] as List?) ?? const [];
      setState(() {
        _items = raw.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
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

  static String _dstr(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  static int _ts(DateTime day, TimeOfDay t) =>
      DateTime(day.year, day.month, day.day, t.hour, t.minute).millisecondsSinceEpoch;

  Future<void> _submit() async {
    final reason = _reasonCtrl.text.trim();
    Map<String, dynamic> body;
    switch (_kind) {
      case 'leave':
        body = {
          'kind': 'leave',
          'startDay': _dstr(_leaveStart),
          'endDay': _dstr(_leaveEnd),
          // 半天只对单日有意义（多日请假按整天计，服务端也会拦）
          'half': _dstr(_leaveStart) == _dstr(_leaveEnd) ? _half : 0,
          'leaveType': _leaveType,
          'reason': reason,
        };
        break;
      case 'makeup':
        body = {
          'kind': 'makeup',
          'day': _dstr(_makeupDay),
          'clockType': _clockType,
          'at': _ts(_makeupDay, _makeupTime),
          'reason': reason,
        };
        break;
      default:
        body = {
          'kind': _kind,
          'startAt': _ts(_rangeDay, _rangeStart),
          'endAt': _ts(_rangeDay, _rangeEnd),
          'reason': reason,
        };
    }
    setState(() => _busy = true);
    try {
      await ImApi().createAttendanceRequest(body);
      if (!mounted) return;
      _reasonCtrl.clear();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已提交，等待管理员审批'), duration: Duration(seconds: 2)),
      );
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('提交失败：$e'),
        duration: const Duration(seconds: 4),
        backgroundColor: AppColors.danger,
      ));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _cancel(Map<String, dynamic> item) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('撤销申请'),
        content: Text('确认撤销这条${item['kindLabel']}申请？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('撤销')),
        ],
      ),
    );
    if (yes != true) return;
    try {
      await ImApi().cancelAttendanceRequest(item['id'] as int);
      if (!mounted) return;
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('撤销失败：$e')));
    }
  }

  Future<void> _pickDate(DateTime cur, void Function(DateTime) apply) async {
    final now = DateTime.now();
    final d = await showDatePicker(
      context: context,
      initialDate: cur,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year, now.month, now.day), // 不允许未来（服务端也会拦）
    );
    if (d != null) setState(() => apply(d));
  }

  Future<void> _pickTime(TimeOfDay cur, void Function(TimeOfDay) apply) async {
    final t = await showTimePicker(context: context, initialTime: cur);
    if (t != null) setState(() => apply(t));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('我的申请'),
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 30),
          children: [
            _formCard(),
            const SizedBox(height: 20),
            _sectionTitle('申请记录'),
            if (_loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 40),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_error != null)
              Text('加载失败：$_error', style: const TextStyle(color: AppColors.danger))
            else if (_items.isEmpty)
              _emptyHint()
            else
              ..._items.map(_itemRow),
          ],
        ),
      ),
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

  Widget _emptyHint() {
    final sem = AppSemantic.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Center(
        child: Text('还没有提交过申请', style: TextStyle(fontSize: 13, color: sem.muted)),
      ),
    );
  }

  Widget _formCard() {
    final sem = AppSemantic.of(context);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: sem.cardBg,
        borderRadius: BorderRadius.circular(AppRadii.md),
        border: Border.all(color: sem.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _kindChip('leave', '请假'),
                const SizedBox(width: 8),
                _kindChip('makeup', '补卡'),
                const SizedBox(width: 8),
                _kindChip('outing', '外出'),
                const SizedBox(width: 8),
                _kindChip('overtime', '加班'),
              ],
            ),
          ),
          const SizedBox(height: 14),
          if (_kind == 'leave') ..._leaveFields(),
          if (_kind == 'makeup') ..._makeupFields(),
          if (_kind == 'outing' || _kind == 'overtime') ..._rangeFields(),
          const SizedBox(height: 12),
          TextField(
            controller: _reasonCtrl,
            maxLines: 2,
            maxLength: 200,
            decoration: InputDecoration(
              labelText: _kind == 'leave' ? '请假事由' : '事由 / 说明',
              hintText: _kind == 'makeup' ? '如：忘打卡' : '选填',
              isDense: true,
              border: const OutlineInputBorder(),
              counterText: '',
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _busy ? null : _submit,
              child: Text(_busy ? '提交中…' : '提交申请'),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            _submitHint(),
            style: TextStyle(fontSize: 11.5, height: 1.5, color: sem.muted),
          ),
        ],
      ),
    );
  }

  String _submitHint() {
    switch (_kind) {
      case 'leave':
        return '请假按天计：单日可选上午/下午半天（按 0.5 天），多日按整天。单次最多 30 天。通过后当天不再判缺勤。';
      case 'makeup':
        return '补卡时刻必须落在所选日期当天，且不能给未来日期补卡。管理员通过后立即写入考勤记录。';
      case 'outing':
        return '外出的起止时刻覆盖到哪张卡，哪张卡就不再判缺勤（例如 08:00-19:00 覆盖上下班）。';
      default:
        return '加班时长会计入统计（单次不超过 24 小时）。';
    }
  }

  Widget _kindChip(String k, String label) {
    final on = _kind == k;
    return InkWell(
      borderRadius: BorderRadius.circular(AppRadii.pill),
      onTap: () => setState(() => _kind = k),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          gradient: on ? AppTheme.brandGradient : null,
          color: on ? null : AppColors.surfaceHi,
          borderRadius: BorderRadius.circular(AppRadii.pill),
        ),
        child: Text(label,
            style: TextStyle(
                fontSize: 13.5,
                fontWeight: on ? FontWeight.w700 : FontWeight.w500,
                color: on ? Colors.white : AppColors.textSub)),
      ),
    );
  }

  List<Widget> _leaveFields() => [
        _row('开始日期', _dateBtn(_leaveStart, (d) => _leaveStart = d),
            trailing: _dateBtn(_leaveEnd, (d) => _leaveEnd = d)),
        const SizedBox(height: 10),
        _row('请假类型', Wrap(
          spacing: 8,
          children: _leaveTypes
              .map((t) => ChoiceChip(
                    label: Text(t[1]),
                    selected: _leaveType == t[0],
                    onSelected: (_) => setState(() => _leaveType = t[0]),
                  ))
              .toList(),
        )),
        if (_dstr(_leaveStart) == _dstr(_leaveEnd)) ...[
          const SizedBox(height: 10),
          _row('时段', Wrap(
            spacing: 8,
            children: [
              ChoiceChip(
                  label: const Text('全天'),
                  selected: _half == 0,
                  onSelected: (_) => setState(() => _half = 0)),
              ChoiceChip(
                  label: const Text('上午半天'),
                  selected: _half == 1,
                  onSelected: (_) => setState(() => _half = 1)),
              ChoiceChip(
                  label: const Text('下午半天'),
                  selected: _half == 2,
                  onSelected: (_) => setState(() => _half = 2)),
            ],
          )),
        ],
      ];

  List<Widget> _makeupFields() => [
        _row('补卡日期', _dateBtn(_makeupDay, (d) => _makeupDay = d)),
        const SizedBox(height: 10),
        _row('补哪张卡', Wrap(
          spacing: 8,
          children: [
            ChoiceChip(
                label: const Text('上班卡'),
                selected: _clockType == 'in',
                onSelected: (_) => setState(() => _clockType = 'in')),
            ChoiceChip(
                label: const Text('下班卡'),
                selected: _clockType == 'out',
                onSelected: (_) => setState(() => _clockType = 'out')),
          ],
        )),
        const SizedBox(height: 10),
        _row('补卡时间', _timeBtn(_makeupTime, (t) => _makeupTime = t)),
      ];

  List<Widget> _rangeFields() => [
        _row('日期', _dateBtn(_rangeDay, (d) => _rangeDay = d)),
        const SizedBox(height: 10),
        _row('开始', _timeBtn(_rangeStart, (t) => _rangeStart = t),
            trailing: _timeBtn(_rangeEnd, (t) => _rangeEnd = t)),
      ];

  Widget _row(String label, Widget child, {Widget? trailing}) {
    final sem = AppSemantic.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SizedBox(
          width: 74,
          child: Text(label, style: TextStyle(fontSize: 13, color: sem.muted)),
        ),
        Expanded(child: child),
        if (trailing != null) ...[const SizedBox(width: 8), trailing],
      ],
    );
  }

  Widget _dateBtn(DateTime d, void Function(DateTime) apply) => OutlinedButton(
        onPressed: () => _pickDate(d, apply),
        child: Text(_dstr(d), style: const TextStyle(fontSize: 13)),
      );

  Widget _timeBtn(TimeOfDay t, void Function(TimeOfDay) apply) => OutlinedButton(
        onPressed: () => _pickTime(t, apply),
        child: Text(
          '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}',
          style: const TextStyle(fontSize: 13),
        ),
      );

  Widget _itemRow(Map<String, dynamic> it) {
    final sem = AppSemantic.of(context);
    final status = (it['status'] ?? '').toString();
    final pending = status == 'pending';
    final color = status == 'approved'
        ? AppColors.brand
        : (status == 'rejected' ? AppColors.danger : AppColors.warn);
    return Container(
      margin: const EdgeInsets.only(bottom: 9),
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
      decoration: BoxDecoration(
        color: sem.cardBg,
        borderRadius: BorderRadius.circular(AppRadii.sm),
        border: Border.all(color: sem.cardBorder),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: AppColors.brand.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(AppRadii.pill),
            ),
            child: Text((it['kindLabel'] ?? '').toString(),
                style: const TextStyle(
                    fontSize: 11.5, fontWeight: FontWeight.w600, color: AppColors.brand)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text((it['desc'] ?? '').toString(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
                if ((it['reason'] ?? '').toString().isNotEmpty ||
                    (it['reviewNote'] ?? '').toString().isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      [
                        if ((it['reason'] ?? '').toString().isNotEmpty) it['reason'].toString(),
                        if ((it['reviewNote'] ?? '').toString().isNotEmpty)
                          '审批：${it['reviewNote']}',
                      ].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11.5, color: sem.muted),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text((it['statusLabel'] ?? '').toString(),
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: color)),
          if (pending) ...[
            const SizedBox(width: 4),
            TextButton(
              onPressed: () => _cancel(it),
              style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  minimumSize: const Size(0, 30)),
              child: const Text('撤销', style: TextStyle(fontSize: 12)),
            ),
          ],
        ],
      ),
    );
  }
}
