import 'dart:io';

import 'package:flutter/material.dart';

import '../core/file_io.dart';
import '../core/stocktake_export.dart';
import '../core/stocktake_repo.dart';
import '../core/theme.dart';
import '../widgets/export_flow.dart';

/// 扫码枪出数：一张扫码单的盈亏表 + 导出。
///
/// ── 这一页回答的是"盘完了，然后呢" ────────────────────────────
/// 采集页只管把码扫进来。老板要的是三句话：**盘盈多少、盘亏多少、
/// 差在哪几个品种上**。所以这一页只做两件事：算清楚、拿得走。
///
/// ── 为什么默认导出"通用 CSV"而不是某家的导入模板 ──────────────
/// 现场扫的不止泰格一家（超盘、别的进销存都能用这套扫码），
/// 各家导入格式不同且会变。把导出焊死在某家模板上，换系统就要改代码。
/// 这里只出一份干净的 CSV（条码/品名/实盘/账面/差异/差异金额），
/// 谁都能打开、谁都能另存成自己要的模板。
///
/// ── 一个容易写错的口径 ────────────────────────────────────────
/// **账面缺失的行不计入盈亏**。它只表示"商档里没这个码"，
/// 不是"账面为 0"。按 0 算的话，商档没同步好会表现成"大面积盘盈"，
/// 这是一个看起来很像业务结果、实际是数据没准备好的假结论。
class StocktakeResultPage extends StatefulWidget {
  const StocktakeResultPage({super.key, required this.sheetNo});

  final String sheetNo;

  @override
  State<StocktakeResultPage> createState() => _StocktakeResultPageState();
}

class _StocktakeResultPageState extends State<StocktakeResultPage> {
  static const List<String> kFilters = <String>[
    '全部',
    '有差异',
    '盘亏',
    '盘盈',
    '无账面',
  ];

  final StocktakeRepo _repo = StocktakeRepo();

  List<Map<String, dynamic>> _all = const [];
  Map<String, dynamic> _sum = const {};
  String _sheetName = '';
  int _filter = 0;
  bool _loading = true;
  bool _exporting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    try {
      // 🔴 单名随行一起带回来（listWithMaster 的标量子查询 sheet_name），
      //    **不要**在这里再 await 一次 repo.sheetName —— 两次 isolate 往返
      //    会把 widget 测试 runAsync 的等待窗口挤爆（client 端 CI 上
      //    4 条全挂，表现为"找不到任何文字"）。空单没有行 → 兜底空串。
      final rows = await _repo.listWithMaster(widget.sheetNo);
      final name = rows.isEmpty
          ? ''
          : ((rows.first['sheet_name'] as String?) ?? '');
      if (!mounted) return;
      setState(() {
        _all = rows;
        _sum = StocktakeExport.summarize(rows);
        _sheetName = name;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '读扫码数据失败：$e';
        _loading = false;
      });
    }
  }

  /// 当前筛选下要显示（和要导出）的行。筛选与排序都在
  /// `StocktakeExport.filter` 里，界面只负责拿来用。
  List<Map<String, dynamic>> _visible() =>
      StocktakeExport.filter(_all, _filter);

  Future<void> _export() async {
    final rows = _visible();
    if (rows.isEmpty) {
      _snack('当前筛选下没有可导出的行');
      return;
    }
    setState(() => _exporting = true);
    try {
      final csv = StocktakeExport.toCsv(rows);
      // 🔴 文件名优先单据名（龙哥 2026-10-06），没起名兜底单号。
      final name =
          FileIo.safeName(StocktakeExport.fileName(widget.sheetNo, _sheetName));
      final dir = await FileIo.dir();
      final f = File('${dir.path}${Platform.pathSeparator}$name');
      // writeAsString 默认就是 UTF-8，BOM 由 toCsv 负责加在内容里
      await f.writeAsString(csv);
      if (!mounted) return;
      setState(() => _exporting = false);
      await _afterExport(f, rows.length);
    } catch (e) {
      if (!mounted) return;
      setState(() => _exporting = false);
      _snack('导出失败：$e');
    }
  }

  /// 导出后给几条路（打开 / 发给同事 / 另存为）。
  /// 弹层本体在 `widgets/export_flow.dart`，与采集页、盘点采集页共用一份。
  Future<void> _afterExport(File f, int rows) async {
    await ExportFlow.show(
      context,
      f,
      rows: rows,
      // 转发建议名与实际文件名同规则：单据名优先。
      suggestName: StocktakeExport.fileName(widget.sheetNo, _sheetName),
      onMessage: _snack,
    );
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bgElevated,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('扫码盈亏',
                style: TextStyle(color: AppColors.text, fontSize: 17)),
            Text(
                _sheetName.isEmpty
                    ? widget.sheetNo
                    : '$_sheetName（${widget.sheetNo}）',
                style:
                    const TextStyle(color: AppColors.textWeak, fontSize: 11)),
          ],
        ),
        actions: [
          _exporting
              ? const Padding(
                  padding: EdgeInsets.all(14),
                  child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2)),
                )
              : IconButton(
                  tooltip: '导出 CSV',
                  icon: const Icon(Icons.ios_share, color: AppColors.brand),
                  onPressed: _export,
                ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _all.isEmpty
              ? _empty()
              : Column(
                  children: [
                    if (_error != null) _banner(_error!, AppColors.danger),
                    _summaryCard(),
                    _filterBar(),
                    const Divider(height: 1, color: AppColors.divider),
                    Expanded(child: _list()),
                  ],
                ),
    );
  }

  Widget _empty() => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.inbox_outlined,
                  size: 48, color: AppColors.textWeak),
              const SizedBox(height: 12),
              const Text('这张扫码单还没有扫码记录',
                  style: TextStyle(color: AppColors.textSub, fontSize: 14)),
              const SizedBox(height: 16),
              OutlinedButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('回去扫码'),
              ),
            ],
          ),
        ),
      );

  Widget _banner(String text, Color color) => Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        color: color.withValues(alpha: 0.14),
        child: Text(text, style: TextStyle(color: color, fontSize: 13)),
      );

  /// 老板要看的那几个数。
  ///
  /// 盘盈/盘亏金额一律显示**正数**（"盈了多少 / 亏了多少"），
  /// 净额才带符号。混着用符号的话，"亏 300" 写成 "-300"，
  /// 和"盈 300"并排看时极易看反 —— 这是盈亏报表最典型的误读。
  Widget _summaryCard() {
    final gainAmt = (_sum['gain_amt'] as num?)?.toDouble() ?? 0;
    final lossAmt = (_sum['loss_amt'] as num?)?.toDouble() ?? 0;
    final net = (_sum['net_amt'] as num?)?.toDouble() ?? 0;
    final noAccount = _sum['no_account'] ?? 0;
    final unknown = _sum['unknown'] ?? 0;

    return Container(
      color: AppColors.surface,
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
      child: Column(
        children: [
          Row(
            children: [
              _tile('实盘品种', '${_sum['kinds'] ?? 0}', AppColors.text),
              _tile('实盘总数', StocktakeExport.fmtNum(_sum['total_qty']),
                  AppColors.text),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              _tile('盘盈 ${_sum['gain_kinds'] ?? 0} 种', _money(gainAmt),
                  AppColors.brand),
              _tile('盘亏 ${_sum['loss_kinds'] ?? 0} 种', _money(lossAmt),
                  AppColors.danger),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: Text(
                  '净差异 ${net >= 0 ? '+' : '-'}${_money(net.abs())}',
                  style: TextStyle(
                    color: net == 0
                        ? AppColors.textSub
                        : (net > 0 ? AppColors.brand : AppColors.danger),
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (noAccount > 0) _chip('$noAccount 个无账面', AppColors.warn),
              if (unknown > 0) ...[
                const SizedBox(width: 6),
                _chip('$unknown 个未知码', AppColors.warn),
              ],
            ],
          ),
          if (noAccount > 0)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                '有 $noAccount 个条码在商品档案里找不到，'
                '不知道账面数，因此不计入盈亏。先同步一次商档再盘更准。',
                style: const TextStyle(color: AppColors.warn, fontSize: 12),
              ),
            ),
        ],
      ),
    );
  }

  Widget _tile(String label, String value, Color color) => Expanded(
        child: Container(
          margin: const EdgeInsets.only(right: 8),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: AppColors.bgElevated,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  style:
                      const TextStyle(color: AppColors.textWeak, fontSize: 12)),
              const SizedBox(height: 4),
              Text(value,
                  style: TextStyle(
                      color: color,
                      fontSize: 18,
                      fontWeight: FontWeight.w600)),
            ],
          ),
        ),
      );

  Widget _chip(String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(text, style: TextStyle(color: color, fontSize: 12)),
      );

  Widget _filterBar() => Container(
        color: AppColors.bgElevated,
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 10),
        child: Row(
          children: [
            for (var i = 0; i < kFilters.length; i++) ...[
              _filterChip(i, kFilters[i]),
              const SizedBox(width: 6),
            ],
            const Spacer(),
            Text('${_visible().length} 行',
                style:
                    const TextStyle(color: AppColors.textWeak, fontSize: 12)),
          ],
        ),
      );

  Widget _filterChip(int i, String text) {
    final on = _filter == i;
    return GestureDetector(
      // 固定 key：这几个字（"盘亏"/"无账面"）在明细行里也会出现，
      // 靠文字找控件会撞车；也给以后的自动化/无障碍留个稳定把手。
      key: Key('stocktake_filter_$i'),
      onTap: () => setState(() => _filter = i),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: on ? AppColors.brand.withValues(alpha: 0.18) : AppColors.surface,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
              color: on ? AppColors.brand : AppColors.border, width: 1),
        ),
        child: Text(text,
            style: TextStyle(
                color: on ? AppColors.brand : AppColors.textSub, fontSize: 12)),
      ),
    );
  }

  Widget _list() {
    final rows = _visible();
    if (rows.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('这个筛选下没有记录',
              style: TextStyle(color: AppColors.textWeak, fontSize: 13)),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.only(bottom: 24),
      itemCount: rows.length,
      separatorBuilder: (_, __) =>
          const Divider(height: 1, color: AppColors.divider),
      itemBuilder: (_, i) => _row(rows[i]),
    );
  }

  Widget _row(Map<String, dynamic> r) {
    final name = (r['name'] ?? '').toString();
    final qty = (r['qty'] as num?)?.toDouble() ?? 0;
    final account = r['account_qty'];
    final diff = StocktakeExport.diffOf(r);
    final amt = StocktakeExport.amtOf(r);
    final unit = (r['unit'] ?? '').toString();

    final color = diff == null
        ? AppColors.textWeak
        : (diff == 0
            ? AppColors.textWeak
            : (diff > 0 ? AppColors.brand : AppColors.danger));

    return ListTile(
      tileColor: AppColors.bg,
      title: Text(name.isEmpty ? '未知条码 ${r['barcode']}' : name,
          style: TextStyle(
            color: name.isEmpty ? AppColors.warn : AppColors.text,
            fontSize: 15,
          )),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 3),
          Text(r['barcode'].toString(),
              style: const TextStyle(color: AppColors.textWeak, fontSize: 12)),
          const SizedBox(height: 2),
          Text(
            '实盘 ${StocktakeExport.fmtNum(qty)}$unit'
            '　账面 ${account == null ? '—' : StocktakeExport.fmtNum(account)}$unit',
            style: const TextStyle(color: AppColors.textSub, fontSize: 12),
          ),
        ],
      ),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            diff == null
                ? '无账面'
                : (diff == 0
                    ? '持平'
                    : '${diff > 0 ? '+' : '-'}${StocktakeExport.fmtNum(diff.abs())}'),
            style: TextStyle(color: color, fontSize: 15),
          ),
          if (amt != null && diff != null && diff != 0)
            Text(
              '${amt >= 0 ? '+' : '-'}${_money(amt.abs())}',
              style: TextStyle(color: color, fontSize: 12),
            ),
        ],
      ),
    );
  }

  String _money(double d) => '¥${d.toStringAsFixed(2)}';
}
