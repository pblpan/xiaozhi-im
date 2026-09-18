import 'package:flutter/material.dart';

import '../core/stock_master_repo.dart';
import '../core/stocktake_export.dart';
import '../core/stocktake_repo.dart';
import '../core/theme.dart';
import 'stocktake_result.dart';

/// 门店盘点：采集页。
///
/// ── 这一页为什么完全不发网络请求 ──────────────────────────────
/// 盘点在货架之间做，那里的网络不归我们管。所以"扫一个码 → 记一笔"
/// 整条路径只写本地 SQLite（core/stocktake_repo.dart），断网照盘。
/// 联网只用在两个地方：① 同步商档（把商品底表拉到手机）② 以后回传。
///
/// ── 输入框为什么要一直攥着焦点 ────────────────────────────────
/// 蓝牙/无线扫码枪在 Android 上就是**一个 HID 键盘**：它把条码敲进"当前
/// 有焦点的输入框"，再补一个回车。焦点丢了，枪扫出来的字就落到别处去了 ——
/// 界面上表现为"扫了没反应"，员工只会怪软件坏。
/// 所以每次提交、每次改数量之后都要把焦点抢回来。
///
/// ── 为什么扫完必须立刻给反馈 ──────────────────────────────────
/// 枪扫得快，员工不会盯屏幕。不给他"刚扫进去的是啥、现在几个了"的即时反馈，
/// 他要么重复扫（数量翻倍），要么以为坏了。这块提示条不是装饰。
class StocktakePage extends StatefulWidget {
  const StocktakePage({super.key});

  @override
  State<StocktakePage> createState() => _StocktakePageState();
}

class _StocktakePageState extends State<StocktakePage> {
  final StocktakeRepo _repo = StocktakeRepo();
  final TextEditingController _input = TextEditingController();
  final FocusNode _focus = FocusNode();

  String _sheetNo = '';
  List<Map<String, dynamic>> _rows = const [];
  Map<String, dynamic> _summary = const {};
  int _masterCount = 0;

  bool _loading = true;
  bool _syncing = false;
  String? _error;

  /// 最近一次扫码的反馈（品名/数量/账面），null = 还没扫过
  Map<String, dynamic>? _lastHit;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  @override
  void dispose() {
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _boot() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      // 有没盘完的单就接着盘，别一进来就开新单（上次的数据会"消失"）
      final sheets = await _repo.listSheets();
      final no = sheets.isEmpty ? StocktakeRepo.newSheetNo() : sheets.first['sheet_no'] as String;
      final masterCount = await StockMasterRepo().countLocal();
      if (!mounted) return;
      _sheetNo = no;
      _masterCount = masterCount;
      await _reload();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '打开盘点失败：$e';
        _loading = false;
      });
    }
  }

  Future<void> _reload() async {
    final rows = await _repo.listWithMaster(_sheetNo);
    final sum = await _repo.summary(_sheetNo);
    if (!mounted) return;
    setState(() {
      _rows = rows;
      _summary = sum;
      _loading = false;
    });
    _refocus();
  }

  /// 把焦点还给输入框。延迟一帧是因为刚 setState 完，焦点请求可能被重建打断。
  void _refocus() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      FocusScope.of(context).requestFocus(_focus);
    });
  }

  Future<void> _submit(String raw) async {
    final code = raw.trim();
    if (code.isEmpty) return;
    _input.clear();
    try {
      await _repo.addScan(_sheetNo, code);
      final rows = await _repo.listWithMaster(_sheetNo);
      final hit = rows.cast<Map<String, dynamic>?>().firstWhere(
            (r) => r != null && r['barcode'] == code,
            orElse: () => null,
          );
      if (!mounted) return;
      setState(() => _lastHit = hit);
      await _reload();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '写入失败：$e');
    }
  }

  Future<void> _syncMaster() async {
    setState(() => _syncing = true);
    try {
      final n = await StockMasterRepo().sync();
      if (!mounted) return;
      setState(() {
        _masterCount = n;
        _syncing = false;
        _error = null;
      });
      _snack('商档已同步：$n 个商品');
      await _reload();
    } catch (e) {
      if (!mounted) return;
      setState(() => _syncing = false);
      _snack('同步商档失败：$e');
    }
  }

  Future<void> _newSheet() async {
    setState(() {
      _sheetNo = StocktakeRepo.newSheetNo();
      _lastHit = null;
      _rows = const [];
      _summary = const {};
    });
    await _reload();
    _snack('已新建盘点单 $_sheetNo');
  }

  Future<void> _pickSheet() async {
    final sheets = await _repo.listSheets();
    if (!mounted) return;
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppColors.bgElevated,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              leading: const Icon(Icons.add, color: AppColors.brand),
              title: const Text('新建一张盘点单',
                  style: TextStyle(color: AppColors.text)),
              onTap: () => Navigator.pop(ctx, '__new__'),
            ),
            ...sheets.map((s) => ListTile(
                  leading: const Icon(Icons.receipt_long,
                      color: AppColors.textWeak),
                  title: Text(s['sheet_no'].toString(),
                      style: const TextStyle(color: AppColors.text)),
                  subtitle: Text('${s['kinds']} 个品种',
                      style: const TextStyle(color: AppColors.textWeak)),
                  onTap: () => Navigator.pop(ctx, s['sheet_no'].toString()),
                )),
          ],
        ),
      ),
    );
    if (picked == null) return;
    if (picked == '__new__') return _newSheet();
    setState(() {
      _sheetNo = picked;
      _lastHit = null;
    });
    await _reload();
  }

  Future<void> _clearSheet() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.bgElevated,
        title: const Text('清空本张盘点单？',
            style: TextStyle(color: AppColors.text)),
        content: Text('将删除 $_sheetNo 的全部扫码记录，不可恢复。',
            style: const TextStyle(color: AppColors.textSub)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('清空',
                  style: TextStyle(color: AppColors.danger))),
        ],
      ),
    );
    if (ok != true) return;
    await _repo.deleteSheet(_sheetNo);
    setState(() => _lastHit = null);
    await _reload();
  }

  /// 出数：打开盈亏表。盘完顺手看一眼才敢收工，所以入口就放在采集页顶上。
  Future<void> _openResult() async {
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
          builder: (_) => StocktakeResultPage(sheetNo: _sheetNo)),
    );
    if (!mounted) return;
    await _reload();
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
        title: const Text('门店盘点',
            style: TextStyle(color: AppColors.text, fontSize: 17)),
        actions: [
          IconButton(
            tooltip: '盈亏表 / 导出',
            icon: const Icon(Icons.assessment_outlined, color: AppColors.brand),
            onPressed: _openResult,
          ),
          IconButton(
            tooltip: '切换/新建盘点单',
            icon: const Icon(Icons.receipt_long, color: AppColors.textSub),
            onPressed: _pickSheet,
          ),
          IconButton(
            tooltip: '清空本单',
            icon: const Icon(Icons.delete_outline, color: AppColors.textSub),
            onPressed: _rows.isEmpty ? null : _clearSheet,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                if (_error != null) _banner(_error!, AppColors.danger),
                if (_masterCount == 0)
                  _banner(
                    '手机上还没有商品档案，扫出来会是"未知条码"。'
                    '请先在有网的地方同步一次商档。',
                    AppColors.warn,
                  ),
                _sheetBar(),
                _inputBar(),
                if (_lastHit != null) _hitBanner(),
                const Divider(height: 1, color: AppColors.divider),
                Expanded(child: _list()),
              ],
            ),
    );
  }

  Widget _banner(String text, Color color) => Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        color: color.withValues(alpha: 0.14),
        child: Text(text, style: TextStyle(color: color, fontSize: 13)),
      );

  Widget _sheetBar() => Container(
        color: AppColors.surface,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          children: [
            const Icon(Icons.numbers, size: 16, color: AppColors.textWeak),
            const SizedBox(width: 6),
            Text(_sheetNo,
                style: const TextStyle(color: AppColors.text, fontSize: 13)),
            const Spacer(),
            _chip('${_summary['kinds'] ?? 0} 品种'),
            const SizedBox(width: 6),
            _chip('合计 ${StocktakeExport.fmtNum(_summary['total_qty'])}'),
            if ((_summary['unknown'] ?? 0) > 0) ...[
              const SizedBox(width: 6),
              _chip('未知 ${_summary['unknown']}', color: AppColors.warn),
            ],
          ],
        ),
      );

  Widget _chip(String text, {Color color = AppColors.textSub}) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(text, style: TextStyle(color: color, fontSize: 12)),
      );

  Widget _inputBar() => Container(
        color: AppColors.bgElevated,
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _input,
                focusNode: _focus,
                autofocus: true,
                // 扫码枪可能扫出带字母的码，但不能让输入法去联想/纠错
                keyboardType: TextInputType.visiblePassword,
                enableSuggestions: false,
                autocorrect: false,
                textInputAction: TextInputAction.done,
                style: const TextStyle(color: AppColors.text, fontSize: 15),
                decoration: InputDecoration(
                  hintText: '扫码枪直接扫，或手输条码后回车',
                  hintStyle:
                      const TextStyle(color: AppColors.textWeak, fontSize: 13),
                  filled: true,
                  fillColor: AppColors.surface,
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 12),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide.none,
                  ),
                ),
                onSubmitted: _submit,
              ),
            ),
            const SizedBox(width: 10),
            _syncing
                ? const SizedBox(
                    width: 36,
                    height: 36,
                    child: Padding(
                      padding: EdgeInsets.all(8),
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : IconButton(
                    tooltip: '同步商档',
                    icon: const Icon(Icons.sync, color: AppColors.brand),
                    onPressed: _syncMaster,
                  ),
          ],
        ),
      );

  /// 扫完的即时反馈。没有它，员工连发几枪后根本不知道扫进去没。
  Widget _hitBanner() {
    final h = _lastHit!;
    final name = (h['name'] ?? '').toString();
    final qty = StocktakeExport.fmtNum(h['qty']);
    final unknown = name.isEmpty;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      color: (unknown ? AppColors.warn : AppColors.brand).withValues(alpha: 0.12),
      child: Row(
        children: [
          Icon(unknown ? Icons.help_outline : Icons.check_circle_outline,
              size: 16, color: unknown ? AppColors.warn : AppColors.brand),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              unknown ? '未知条码 ${h['barcode']} × $qty（商档里没有）' : '$name × $qty',
              style: const TextStyle(color: AppColors.text, fontSize: 13),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _list() {
    if (_rows.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            '还没有扫码记录\n把光标放在上面的输入框，用扫码枪扫即可',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.textWeak, fontSize: 13),
          ),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.only(bottom: 24),
      itemCount: _rows.length,
      separatorBuilder: (_, __) =>
          const Divider(height: 1, color: AppColors.divider),
      itemBuilder: (_, i) => _row(_rows[i]),
    );
  }

  Widget _row(Map<String, dynamic> r) {
    final name = (r['name'] ?? '').toString();
    final qty = (r['qty'] as num?)?.toDouble() ?? 0;
    final account = (r['account_qty'] as num?)?.toDouble();
    final diff = (r['diff_qty'] as num?)?.toDouble();
    final unit = (r['unit'] ?? '').toString();

    return ListTile(
      tileColor: AppColors.bg,
      title: Text(
        name.isEmpty ? '未知条码' : name,
        style: TextStyle(
          color: name.isEmpty ? AppColors.warn : AppColors.text,
          fontSize: 15,
        ),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 3),
          Text(r['barcode'].toString(),
              style: const TextStyle(color: AppColors.textWeak, fontSize: 12)),
          const SizedBox(height: 2),
          Text(
            account == null
                ? '账面：—'
                : '账面 ${StocktakeExport.fmtNum(account)}$unit'
                    '${diff == null ? '' : '　${_diffText(diff)}'}',
            style: TextStyle(
              color: diff == null
                  ? AppColors.textWeak
                  : (diff == 0
                      ? AppColors.textWeak
                      : (diff > 0 ? AppColors.brand : AppColors.danger)),
              fontSize: 12,
            ),
          ),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.remove_circle_outline,
                color: AppColors.textSub, size: 20),
            onPressed: () async {
              await _repo.addScan(_sheetNo, r['barcode'].toString(), qty: -1);
              await _reload();
            },
          ),
          Text(StocktakeExport.fmtNum(qty),
              style: const TextStyle(color: AppColors.text, fontSize: 15)),
          IconButton(
            icon: const Icon(Icons.add_circle_outline,
                color: AppColors.brand, size: 20),
            onPressed: () async {
              await _repo.addScan(_sheetNo, r['barcode'].toString());
              await _reload();
            },
          ),
        ],
      ),
      onLongPress: () async {
        await _repo.deleteScan(r['id'] as int);
        setState(() => _lastHit = null);
        await _reload();
      },
    );
  }

  String _diffText(double d) {
    if (d == 0) return '持平';
    return d > 0 ? '盘盈 +${StocktakeExport.fmtNum(d)}' : '盘亏 ${StocktakeExport.fmtNum(d)}';
  }

}
