import 'package:flutter/material.dart';

import '../core/module_schema.dart';
import '../core/theme.dart';

/// 动作回调。data 仅在表单提交时非空。
typedef ModuleActionHandler = void Function(ModuleAction action, Map<String, dynamic>? data);

/// 语义色 → 实际色值。所有动态组件的颜色都必须经过这里，
/// 组件内部**不允许**出现 Colors.xxx 之类的硬编码（除透明/白色文字）。
Color resolveSemantic(BuildContext context, SemanticColor s) {
  final cs = Theme.of(context).colorScheme;
  final sem = AppSemantic.of(context);
  switch (s) {
    case SemanticColor.primary:
      return cs.primary;
    case SemanticColor.muted:
      return sem.muted;
    case SemanticColor.danger:
      return cs.error;
    case SemanticColor.success:
      return sem.success;
    case SemanticColor.warning:
      return sem.warning;
    case SemanticColor.defaultColor:
      return cs.onSurface;
  }
}

/// 图标名 → IconData。服务端有白名单，这里再兜一层：
/// 不认识的名字给个默认图标，绝不让 `Icon(null)` 之类的东西崩掉页面。
const Map<String, IconData> kModuleIcons = {
  'inventory': Icons.inventory_2_outlined,
  'build': Icons.build_outlined,
  'list': Icons.list_alt_outlined,
  'table_chart': Icons.table_chart_outlined,
  'assessment': Icons.assessment_outlined,
  'note': Icons.sticky_note_2_outlined,
  'report': Icons.summarize_outlined,
  'people': Icons.people_outline,
  'schedule': Icons.schedule_outlined,
  'store': Icons.storefront_outlined,
  'factory': Icons.factory_outlined,
  'restaurant': Icons.restaurant_outlined,
  'local_shipping': Icons.local_shipping_outlined,
  'attach_money': Icons.attach_money_outlined,
  'shopping_cart': Icons.shopping_cart_outlined,
  'warning': Icons.warning_amber_outlined,
  'info': Icons.info_outline,
  'settings': Icons.settings_outlined,
  'dashboard': Icons.dashboard_outlined,
  'campaign': Icons.campaign_outlined,
  'task': Icons.task_alt_outlined,
  'engineering': Icons.engineering_outlined,
  'handyman': Icons.handyman_outlined,
  'receipt_long': Icons.receipt_long_outlined,
};

IconData moduleIcon(String name) => kModuleIcons[name] ?? Icons.dashboard_outlined;

/// 动态模块渲染器：把服务端下发的 JSON 描述渲染成界面。
///
/// 只负责"画"，不负责"取数"和"执行动作" —— 这两件事交给页面（module_page.dart），
/// 这样渲染器可以单独做 widget 测试，塞一份假数据就能跑。
class ModuleRenderer extends StatelessWidget {
  final List<ModuleComponent> body;
  final Map<String, dynamic> data;
  final ModuleActionHandler onAction;

  const ModuleRenderer({
    super.key,
    required this.body,
    required this.data,
    required this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    if (body.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 40),
        child: Center(
          child: Text('这个模块还没有内容',
              style: TextStyle(
                  fontSize: 14, color: resolveSemantic(context, SemanticColor.muted))),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < body.length; i++)
          Padding(
            padding: EdgeInsets.only(top: i == 0 ? 0 : 12),
            child: _buildComponent(context, body[i]),
          ),
      ],
    );
  }

  Widget _buildComponent(BuildContext context, ModuleComponent c) {
    switch (c.type) {
      case ModuleComponentType.text:
        return _TextBlock(c: c);
      case ModuleComponentType.divider:
        return const Divider(height: 20);
      case ModuleComponentType.card:
        return _CardBlock(c: c, data: data, onAction: onAction);
      case ModuleComponentType.list:
        return _ListBlock(c: c, data: data);
      case ModuleComponentType.table:
        return _TableBlock(c: c, data: data);
      case ModuleComponentType.form:
        return ModuleFormBlock(
          key: ValueKey('form-${c.fields.length}-${c.fields.first.key}'),
          c: c,
          onSubmit: (d) {
            final a = c.submit;
            onAction(
              a ?? const ModuleAction(type: 'submit'),
              d,
            );
          },
        );
      case ModuleComponentType.action:
        return _ActionBlock(c: c, onAction: onAction);
      case ModuleComponentType.chart:
        return _ChartBlock(c: c, data: data);
      case ModuleComponentType.unknown:
        return _UnsupportedBlock(rawType: c.rawType);
    }
  }
}

// ---------------------------------------------------------------- text

class _TextBlock extends StatelessWidget {
  final ModuleComponent c;
  const _TextBlock({required this.c});

  @override
  Widget build(BuildContext context) {
    final align = c.align == 'center'
        ? TextAlign.center
        : (c.align == 'right' ? TextAlign.right : TextAlign.left);
    return Text(
      c.text,
      textAlign: align,
      style: TextStyle(
        fontSize: c.size ?? 15,
        color: resolveSemantic(context, c.color),
        height: 1.45,
      ),
    );
  }
}

// ---------------------------------------------------------------- card

class _CardBlock extends StatelessWidget {
  final ModuleComponent c;
  final Map<String, dynamic> data;
  final ModuleActionHandler onAction;

  const _CardBlock({required this.c, required this.data, required this.onAction});

  @override
  Widget build(BuildContext context) {
    final sem = AppSemantic.of(context);
    final accent = resolveSemantic(context, c.accent);
    final hasHead = c.title.isNotEmpty || c.subtitle.isNotEmpty;
    return Container(
      decoration: BoxDecoration(
        color: sem.cardBg,
        borderRadius: BorderRadius.circular(AppRadii.md),
        border: Border.all(color: sem.cardBorder),
      ),
      clipBehavior: Clip.antiAlias,
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 左侧 accent 竖条：靠颜色区分卡片语义，不靠色值硬编码
            Container(width: 3, color: accent),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (hasHead) ...[
                      if (c.title.isNotEmpty)
                        Text(c.title,
                            style: const TextStyle(
                                fontSize: 15, fontWeight: FontWeight.w600)),
                      if (c.subtitle.isNotEmpty) ...[
                        const SizedBox(height: 3),
                        Text(c.subtitle,
                            style: TextStyle(
                                fontSize: 12.5,
                                color: resolveSemantic(context, SemanticColor.muted))),
                      ],
                      if (c.children.isNotEmpty) const SizedBox(height: 10),
                    ],
                    for (var i = 0; i < c.children.length; i++)
                      Padding(
                        padding: EdgeInsets.only(top: i == 0 ? 0 : 10),
                        child: ModuleRenderer(
                          body: [c.children[i]],
                          data: data,
                          onAction: onAction,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- list

class _ListBlock extends StatelessWidget {
  final ModuleComponent c;
  final Map<String, dynamic> data;

  const _ListBlock({required this.c, required this.data});

  @override
  Widget build(BuildContext context) {
    final items = ModuleData.listOf(data, c.dataPath);
    if (items.isEmpty) return const _EmptyHint('暂无数据');
    final sem = AppSemantic.of(context);
    return Container(
      decoration: BoxDecoration(
        color: sem.cardBg,
        borderRadius: BorderRadius.circular(AppRadii.md),
        border: Border.all(color: sem.cardBorder),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          for (var i = 0; i < items.length; i++) ...[
            if (i > 0) const Divider(height: 1),
            _listTile(context, items[i]),
          ],
        ],
      ),
    );
  }

  Widget _listTile(BuildContext context, dynamic item) {
    final m = item is Map ? item.map((k, v) => MapEntry(k.toString(), v)) : <String, dynamic>{};
    final title = renderTemplate(c.itemTemplate.title, m);
    final subtitle = renderTemplate(c.itemTemplate.subtitle, m);
    final trailing = renderTemplate(c.itemTemplate.trailing, m);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title.isEmpty ? '—' : title,
                    style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w500),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis),
                if (subtitle.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(subtitle,
                      style: TextStyle(
                          fontSize: 12.5,
                          color: resolveSemantic(context, SemanticColor.muted)),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis),
                ],
              ],
            ),
          ),
          if (trailing.isNotEmpty) ...[
            const SizedBox(width: 10),
            Text(trailing,
                style: TextStyle(
                    fontSize: 13.5,
                    color: resolveSemantic(context, SemanticColor.primary))),
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- table

class _TableBlock extends StatelessWidget {
  final ModuleComponent c;
  final Map<String, dynamic> data;

  const _TableBlock({required this.c, required this.data});

  @override
  Widget build(BuildContext context) {
    final rows = ModuleData.listOf(data, c.dataPath);
    if (rows.isEmpty) return const _EmptyHint('暂无数据');
    final sem = AppSemantic.of(context);
    final head = TextStyle(
      fontSize: 12.5,
      fontWeight: FontWeight.w600,
      color: resolveSemantic(context, SemanticColor.muted),
    );
    const cell = TextStyle(fontSize: 13.5, height: 1.3);
    return Container(
      decoration: BoxDecoration(
        color: sem.cardBg,
        borderRadius: BorderRadius.circular(AppRadii.md),
        border: Border.all(color: sem.cardBorder),
      ),
      clipBehavior: Clip.antiAlias,
      // 列多时横向滚动，绝不挤压换行（换行后的表格没法看）
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: DataTable(
          headingRowHeight: 40,
          dataRowMinHeight: 40,
          dataRowMaxHeight: 56,
          horizontalMargin: 14,
          columnSpacing: 22,
          headingTextStyle: head,
          dataTextStyle: cell,
          columns: [
            for (final col in c.columns)
              DataColumn(
                label: SizedBox(
                  width: col.width,
                  child: Text(col.label, overflow: TextOverflow.ellipsis),
                ),
              ),
          ],
          rows: [
            for (final r in rows)
              DataRow(cells: [
                for (final col in c.columns)
                  DataCell(_cellText(
                      _stringOf(r, col.key),
                      width: col.width)),
              ]),
          ],
        ),
      ),
    );
  }

  static String _stringOf(dynamic row, String key) {
    if (row is! Map) return '';
    final v = row[key];
    if (v == null) return '';
    if (v is num && v == v.roundToDouble()) return v.toInt().toString();
    return v.toString();
  }

  static Widget _cellText(String s, {double? width}) {
    final t = Text(s, overflow: TextOverflow.ellipsis, maxLines: 2);
    return width == null ? t : SizedBox(width: width, child: t);
  }
}

class _EmptyHint extends StatelessWidget {
  final String text;
  const _EmptyHint(this.text);

  @override
  Widget build(BuildContext context) {
    final sem = AppSemantic.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 22),
      decoration: BoxDecoration(
        color: sem.cardBg,
        borderRadius: BorderRadius.circular(AppRadii.md),
        border: Border.all(color: sem.cardBorder),
      ),
      child: Center(
        child: Text(text,
            style: TextStyle(fontSize: 13, color: sem.muted)),
      ),
    );
  }
}

// ---------------------------------------------------------------- action

class _ActionBlock extends StatelessWidget {
  final ModuleComponent c;
  final ModuleActionHandler onAction;

  const _ActionBlock({required this.c, required this.onAction});

  @override
  Widget build(BuildContext context) {
    final color = resolveSemantic(context, c.color);
    final tap = c.onTap;
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton(
        onPressed: tap == null ? null : () => onAction(tap, null),
        style: OutlinedButton.styleFrom(
          foregroundColor: color,
          side: BorderSide(color: color.withValues(alpha: 0.5)),
          padding: const EdgeInsets.symmetric(vertical: 13),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadii.md),
          ),
        ),
        child: Text(c.label, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
      ),
    );
  }
}

class _UnsupportedBlock extends StatelessWidget {
  final String? rawType;
  const _UnsupportedBlock({this.rawType});

  @override
  Widget build(BuildContext context) {
    final sem = AppSemantic.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadii.sm),
        border: Border.all(color: sem.cardBorder, style: BorderStyle.solid),
      ),
      child: Row(
        children: [
          Icon(Icons.help_outline, size: 18, color: sem.muted),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              rawType == null || rawType!.isEmpty
                  ? '暂不支持的组件（请升级客户端）'
                  : '暂不支持的组件：$rawType（请升级客户端）',
              style: TextStyle(fontSize: 13, color: sem.muted),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- chart

class _ChartBlock extends StatelessWidget {
  final ModuleComponent c;
  final Map<String, dynamic> data;

  const _ChartBlock({required this.c, required this.data});

  @override
  Widget build(BuildContext context) {
    final rows = ModuleData.listOf(data, c.dataPath);
    if (rows.isEmpty) return const _EmptyHint('暂无数据');
    final points = <_ChartPoint>[];
    for (final r in rows) {
      if (r is! Map) continue;
      final y = r[c.yKey];
      final v = y is num ? y.toDouble() : double.tryParse('${y ?? ''}');
      if (v == null) continue;
      points.add(_ChartPoint('${r[c.xKey] ?? ''}', v));
    }
    if (points.isEmpty) return const _EmptyHint('图表数据格式不对');

    final sem = AppSemantic.of(context);
    final bar = resolveSemantic(context, SemanticColor.primary);
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
      decoration: BoxDecoration(
        color: sem.cardBg,
        borderRadius: BorderRadius.circular(AppRadii.md),
        border: Border.all(color: sem.cardBorder),
      ),
      child: c.chartKind == 'line'
          ? _LineChart(points: points, color: bar)
          : _BarChart(points: points, color: bar, muted: sem.muted),
    );
  }
}

class _ChartPoint {
  final String label;
  final double value;
  const _ChartPoint(this.label, this.value);
}

class _BarChart extends StatelessWidget {
  final List<_ChartPoint> points;
  final Color color;
  final Color muted;

  const _BarChart({required this.points, required this.color, required this.muted});

  @override
  Widget build(BuildContext context) {
    final maxV = points.map((p) => p.value).reduce((a, b) => a > b ? a : b);
    final safeMax = maxV <= 0 ? 1.0 : maxV;
    return SizedBox(
      height: 160,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (final p in points)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 3),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Text(_fmt(p.value),
                        style: TextStyle(fontSize: 10.5, color: muted),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 3),
                    Container(
                      height: (110 * (p.value / safeMax)).clamp(2.0, 110.0),
                      decoration: BoxDecoration(
                        color: color,
                        borderRadius: const BorderRadius.vertical(
                            top: Radius.circular(4)),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(p.label,
                        style: TextStyle(fontSize: 10.5, color: muted),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  static String _fmt(double v) =>
      v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);
}

class _LineChart extends StatelessWidget {
  final List<_ChartPoint> points;
  final Color color;

  const _LineChart({required this.points, required this.color});

  @override
  Widget build(BuildContext context) {
    final muted = AppSemantic.of(context).muted;
    return SizedBox(
      height: 160,
      child: CustomPaint(
        painter: _LinePainter(points: points, color: color),
        child: Align(
          alignment: Alignment.bottomCenter,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              for (final p in points.take(6))
                Text(p.label,
                    style: TextStyle(fontSize: 10, color: muted),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
            ],
          ),
        ),
      ),
    );
  }
}

class _LinePainter extends CustomPainter {
  final List<_ChartPoint> points;
  final Color color;

  _LinePainter({required this.points, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    if (points.length < 2) return;
    final maxV = points.map((p) => p.value).reduce((a, b) => a > b ? a : b);
    final safeMax = maxV <= 0 ? 1.0 : maxV;
    const bottomPad = 18.0;
    final h = size.height - bottomPad;
    final dx = size.width / (points.length - 1);
    final path = Path();
    for (var i = 0; i < points.length; i++) {
      final x = dx * i;
      final y = h - (h - 12) * (points[i].value / safeMax);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeJoin = StrokeJoin.round,
    );
    for (var i = 0; i < points.length; i++) {
      canvas.drawCircle(
        Offset(dx * i, h - (h - 12) * (points[i].value / safeMax)),
        2.6,
        Paint()..color = color,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _LinePainter old) =>
      old.points != points || old.color != color;
}

// ---------------------------------------------------------------- form

/// 动态表单。
///
/// 有状态：每个字段一个 TextEditingController，switch 单独用 bool。
/// 提交前**客户端也校验必填**（体验：不用等一个来回）；服务端仍然会再校验一次
/// （安全：客户端的校验永远不算数）。
class ModuleFormBlock extends StatefulWidget {
  final ModuleComponent c;
  final void Function(Map<String, dynamic> data) onSubmit;

  const ModuleFormBlock({super.key, required this.c, required this.onSubmit});

  @override
  State<ModuleFormBlock> createState() => _ModuleFormBlockState();
}

class _ModuleFormBlockState extends State<ModuleFormBlock> {
  final _ctrl = <String, TextEditingController>{};
  final _bool = <String, bool>{};
  final _date = <String, DateTime>{};
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    for (final f in widget.c.fields) {
      if (f.isSwitch) {
        _bool[f.key] = false;
      } else {
        _ctrl[f.key] = TextEditingController();
      }
    }
  }

  @override
  void dispose() {
    for (final c in _ctrl.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    final data = <String, dynamic>{};
    final missing = <String>[];
    for (final f in widget.c.fields) {
      if (f.isSwitch) {
        data[f.key] = _bool[f.key] ?? false;
        continue;
      }
      if (f.isDate) {
        final d = _date[f.key];
        if (d == null) {
          if (f.required) missing.add(f.label);
          continue;
        }
        data[f.key] =
            '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
        continue;
      }
      final v = _ctrl[f.key]?.text.trim() ?? '';
      if (v.isEmpty) {
        if (f.required) missing.add(f.label);
        continue;
      }
      if (f.isNumber) {
        final n = num.tryParse(v);
        if (n == null) {
          _toast('「${f.label}」需要填数字');
          return;
        }
        data[f.key] = n;
        continue;
      }
      data[f.key] = v;
    }
    if (missing.isNotEmpty) {
      _toast('请填写：${missing.join('、')}');
      return;
    }
    setState(() => _submitting = true);
    try {
      widget.onSubmit(data);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final sem = AppSemantic.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
      decoration: BoxDecoration(
        color: sem.cardBg,
        borderRadius: BorderRadius.circular(AppRadii.md),
        border: Border.all(color: sem.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < widget.c.fields.length; i++)
            Padding(
              padding: EdgeInsets.only(top: i == 0 ? 0 : 12),
              child: _field(context, widget.c.fields[i]),
            ),
          const SizedBox(height: 16),
          SizedBox(
            height: 44,
            child: ElevatedButton(
              onPressed: _submitting ? null : _submit,
              style: ElevatedButton.styleFrom(
                backgroundColor: sem.cardBorder == Colors.transparent
                    ? null
                    : Theme.of(context).colorScheme.primary,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppRadii.md)),
              ),
              child: _submitting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white),
                    )
                  : const Text('提交',
                      style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _field(BuildContext context, ModuleField f) {
    final sem = AppSemantic.of(context);
    final labelStyle = TextStyle(
      fontSize: 13,
      color: resolveSemantic(context, SemanticColor.muted),
    );

    Widget input;
    if (f.isSwitch) {
      input = Switch(
        value: _bool[f.key] ?? false,
        onChanged: (v) => setState(() => _bool[f.key] = v),
      );
    } else if (f.isSelect) {
      input = DropdownButtonFormField<String>(
        initialValue: _ctrl[f.key]!.text.isEmpty ? null : _ctrl[f.key]!.text,
        isExpanded: true,
        hint: Text(f.placeholder ?? '请选择',
            style: TextStyle(fontSize: 14.5, color: sem.muted)),
        items: [
          for (final o in f.options)
            DropdownMenuItem(value: o.value, child: Text(o.label)),
        ],
        onChanged: (v) => setState(() => _ctrl[f.key]!.text = v ?? ''),
      );
    } else if (f.isDate) {
      final d = _date[f.key];
      input = InkWell(
        onTap: () async {
          final now = DateTime.now();
          final picked = await showDatePicker(
            context: context,
            initialDate: d ?? now,
            firstDate: DateTime(now.year - 5),
            lastDate: DateTime(now.year + 5),
          );
          if (picked != null) setState(() => _date[f.key] = picked);
        },
        child: InputDecorator(
          decoration: InputDecoration(
            hintText: f.placeholder ?? '请选择日期',
          ),
          child: Text(
            d == null
                ? (f.placeholder ?? '请选择日期')
                : '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}',
            style: TextStyle(fontSize: 14.5, color: d == null ? sem.muted : null),
          ),
        ),
      );
    } else {
      input = TextField(
        controller: _ctrl[f.key],
        keyboardType: f.isNumber
            ? const TextInputType.numberWithOptions(decimal: true)
            : TextInputType.text,
        maxLines: f.isTextarea ? 4 : 1,
        style: const TextStyle(fontSize: 14.5),
        decoration: InputDecoration(hintText: f.placeholder ?? '请输入${f.label}'),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(f.label, style: labelStyle),
            if (f.required)
              Text(' *',
                  style: TextStyle(
                      fontSize: 13,
                      color: resolveSemantic(context, SemanticColor.danger))),
          ],
        ),
        const SizedBox(height: 6),
        input,
      ],
    );
  }
}
