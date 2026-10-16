import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../core/file_io.dart';
import '../core/scan_feedback.dart';
import '../core/stock_master_repo.dart';
import '../core/stocktake_export.dart';
import '../core/picking_repo.dart';
import '../core/picking_sink.dart';
import '../core/theme.dart';
import '../widgets/export_flow.dart';
import '../widgets/qty_edit.dart';
import 'camera_scan.dart';

/// 自由拣货单页面。
///
/// ── 它是什么 ───────────────────────────────────────────────────
/// 拣货 = 把货从货架拣出来去配单。是典型的"干活型"扫码作业：
/// 开一张拣货单 → 一趟趟扫 → 带商档信息 → 可改数量 → 导出一张拣货明细单。
/// 和盘点（数账面）语义不同，但底层共用同一张 `scan_record` 流水表
/// （见 core/picking_repo.dart）。
///
/// ── 入口在哪 ───────────────────────────────────────────────────
/// **不挂工作台图标**（龙哥 2026-10-03 要"放在盘点里面，不独立"）：
/// 从「盘点」页右上角的「自由拣货单」按钮 push 进来
/// （见 screens/inventory.dart 的 open-picking）。所以它不在 `kBuiltinAppIds` 里。
///
/// ── 为什么扫码走相机页而不是自己画 ─────────────────────────────
/// 铁律：所有带扫码/输入数字的地方都走扫码枪那套相机界面（带扫码窗口、
/// 带确认制数量输入）。这里复用通用 [CameraScanPage] + [PickingSink]，
/// 不另写一套相机逻辑 —— 那套确认制/写入闸门最容易做错，抄第二份就是给
/// "连扫同款件数被静默丢掉"这类不报错的 bug 留复活路。
class PickingPage extends StatefulWidget {
  const PickingPage({super.key});

  @override
  State<PickingPage> createState() => _PickingPageState();
}

class _PickingPageState extends State<PickingPage> {
  final PickingRepo _repo = PickingRepo.instance;
  final TextEditingController _input = TextEditingController();
  final FocusNode _focus = FocusNode();

  String _sheetNo = '';
  String _sheetName = '';
  List<Map<String, dynamic>> _rows = const [];
  Map<String, dynamic> _summary = const {};
  int _masterCount = 0;

  bool _loading = true;
  bool _syncing = false;
  bool _exporting = false;
  String? _error;

  /// 最近一次扫码的反馈（品名/数量/规格/单位），null = 还没扫过。
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
      // 有没拣完的单就接着拣，别一进来就开新单（上次的数据会"消失"）。
      // 只认拣货自己的单（JK 开头）—— 盘点/减货/简易盘点共用同一张流水表，
      // 不筛的话这里会把别的单当成"上次没拣完的拣货单"接着拣。
      final sheets = await _repo.listSheets();
      final no = sheets.isEmpty ? PickingRepo.newSheetNo() : sheets.first['sheet_no'] as String;
      final masterCount = await StockMasterRepo().countAll();
      final name = sheets.isEmpty ? '' : await _repo.sheetName(no);
      if (!mounted) return;
      _sheetNo = no;
      _sheetName = name;
      _masterCount = masterCount;
      await _reload();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '打开拣货单失败：$e';
        _loading = false;
      });
    }
  }

  /// [refocus] 刷完要不要把焦点抢回输入框（同 StocktakePage 的说明）。
  Future<void> _reload({bool refocus = true}) async {
    final rows = await _repo.listWithMaster(_sheetNo);
    final sum = await _repo.summary(_sheetNo);
    if (!mounted) return;
    setState(() {
      _rows = rows;
      _summary = sum;
      _loading = false;
    });
    if (refocus) _refocus();
  }

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
      unawaited(ScanFeedbackService.I.forResult(accepted: true));
      final rows = await _repo.listWithMaster(_sheetNo);
      final hit = rows.cast<Map<String, dynamic>?>().firstWhere(
            (r) => r != null && r['barcode'] == code,
            orElse: () => null,
          );
      if (!mounted) return;
      setState(() => _lastHit = hit);
      await _reload();
    } catch (e) {
      unawaited(ScanFeedbackService.I.forResult(accepted: false));
      if (!mounted) return;
      setState(() => _error = '写入失败：$e');
    }
  }

  /// 打开摄像头扫码页。扫到的码由那一页直接落库，这里只负责回来刷新。
  Future<void> _openCamera() async {
    if (!cameraScanSupported) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => CameraScanPage(
          title: '拣货扫码',
          sheetNo: _sheetNo,
          hint: '扫商品条码拣货（带商档，可改数量）',
          sink: PickingSink(_repo),
        ),
      ),
    );
    if (!mounted) return;
    await _reload(refocus: false);
  }

  /// 同步商档（拣货也要带商档信息，没商档扫出来是"未知条码"）。
  Future<void> _syncMaster() async {
    setState(() => _syncing = true);
    try {
      final n = await StockMasterRepo.syncFromServer();
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
    final no = PickingRepo.newSheetNo();
    // 🔴 先弹窗起名（龙哥 2026-10-04 长期规则，好又多版同款）：
    // 单据一多，光看 JK+时间戳分不清哪张单拣的是什么。名字可空 —— 空着用单号。
    final name = await _askSheetName(hint: no);
    if (name == null) return; // 取消 = 不开新单，保持当前单不动
    if (name.isNotEmpty) await _repo.setSheetName(no, name);
    if (!mounted) return;
    setState(() {
      _sheetNo = no;
      _sheetName = name;
      _lastHit = null;
      _rows = const [];
      _summary = const {};
    });
    await _reload();
    _snack(name.isEmpty ? '已新建拣货单 $no' : '已新建拣货单「$name」');
  }

  /// 切换 / 新建拣货单。只列 JK 前缀的单。
  Future<void> _pickSheet() async {
    final sheets = await _repo.listSheets();
    if (!mounted) return;

    // 长按改名：关弹层 → 改名窗 → 改完重开弹层，立刻看到新名字。
    String? renameTarget;
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppColors.bgElevated,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(Icons.add, color: AppColors.brand),
              title:  Text('新建一张拣货单',
                  style: TextStyle(color: AppColors.text)),
              onTap: () => Navigator.pop(ctx, '__new__'),
            ),
            Divider(height: 1, color: AppColors.divider),
             Padding(
              padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('长按单据可改名',
                    style:
                        TextStyle(color: AppColors.textWeak, fontSize: 11)),
              ),
            ),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: sheets.length,
                itemBuilder: (ctx, i) {
                  final s = sheets[i];
                  final no = s['sheet_no'].toString();
                  final name = (s['name'] ?? '').toString().trim();
                  return ListTile(
                    leading:  Icon(Icons.receipt_long,
                        color: AppColors.textWeak),
                    // 有名字显示名字，副标题兜底单号（好又多版同款）。
                    title: Text(name.isEmpty ? no : name,
                        style: TextStyle(color: AppColors.text)),
                    subtitle: Text(
                        name.isEmpty
                            ? '${s['kinds']} 个品种'
                            : '$no · ${s['kinds']} 个品种',
                        style: TextStyle(color: AppColors.textWeak)),
                    onTap: () => Navigator.pop(ctx, no),
                    onLongPress: () {
                      renameTarget = no;
                      Navigator.pop(ctx);
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
    if (picked == '__new__') return _newSheet();
    if (renameTarget != null) {
      await _renameSheet(renameTarget!);
      if (!mounted) return;
      return _pickSheet(); // 重开列表，改完马上能看到
    }
    if (picked == null) return;
    setState(() {
      _sheetNo = picked;
      _lastHit = null;
    });
    _sheetName = await _repo.sheetName(picked);
    if (!mounted) return;
    setState(() {});
    await _reload();
  }

  /// 弹窗收一个单据名字。返回 null = 取消；空串 = 不起名（用单号）。
  /// 新建和改名共用（与扫码枪好又多版一致，同一种动作一种界面）。
  Future<String?> _askSheetName({String? initial, String? hint}) {
    final ctl = TextEditingController(text: initial ?? '');
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.bgElevated,
        title: Text('单据名称', style: TextStyle(color: AppColors.text)),
        content: TextField(
          controller: ctl,
          autofocus: true,
          maxLength: 30,
          style: TextStyle(color: AppColors.text),
          decoration: InputDecoration(
            hintText: hint ?? '例如：周五生鲜补货',
            counterText: '',
          ),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, ctl.text.trim()),
              child: const Text('确定')),
        ],
      ),
    );
  }

  /// 长按已有单改名。清空名字 = 回退用单号。
  Future<void> _renameSheet(String no) async {
    final cur = await _repo.sheetName(no);
    if (!mounted) return;
    final name = await _askSheetName(initial: cur, hint: no);
    if (name == null) return;
    await _repo.setSheetName(no, name);
    if (!mounted) return;
    setState(() {
      if (no == _sheetNo) _sheetName = name;
    });
    _snack(name.isEmpty ? '已清除 $no 的名称' : '已改名「$name」');
  }

  Future<void> _clearSheet() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.bgElevated,
        title:  Text('清空本张拣货单？',
            style: TextStyle(color: AppColors.text)),
        content: Text('将删除 $_sheetNo 的全部拣货记录，不可恢复。',
            style: TextStyle(color: AppColors.textSub)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child:  Text('清空',
                  style: TextStyle(color: AppColors.danger))),
        ],
      ),
    );
    if (ok != true) return;
    await _repo.deleteSheet(_sheetNo);
    setState(() => _lastHit = null);
    await _reload();
  }

  /// 删除一整行（该条码本单的累计全部清掉）。
  Future<void> _deleteRow(Map<String, dynamic> r) async {
    try {
      await _repo.deleteScan(r['id'] as int);
      setState(() => _lastHit = null);
      await _reload();
      if (!mounted) return;
      _snack('已删除 ${r['barcode']}');
    } catch (e) {
      if (!mounted) return;
      _snack('删除失败：$e');
    }
  }

  /// 点数量就能改（重复扫同一个码，这里也是直接 +1；要改大/改小都走这个）。
  /// 改到 0 = 删除该行（`PickingRepo.setQty` 的既有语义），但**要二次确认**。
  Future<void> _editQty(Map<String, dynamic> r) async {
    final id = r['id'] as int;
    final cur = (r['qty'] as num?)?.toDouble() ?? 0;

    final n = await askQty(
      context,
      subtitle: '${StocktakeExport.scanNameOf(r)}　${r['barcode']}',
      current: cur,
      confirmText: '确定删除 ${r['barcode']} 这一行？',
      onMessage: _snack,
    );
    if (n == null || !mounted) return;

    try {
      await _repo.setQty(id, n);
      setState(() => _lastHit = null);
      await _reload();
      if (!mounted) return;
      _snack(n == 0 ? '已删除 ${r['barcode']}' : '${r['barcode']} 已改为 ${StocktakeExport.fmtNum(n)}');
    } catch (e) {
      if (!mounted) return;
      _snack('改数量失败：$e');
    }
  }

  /// 导出拣货明细：文档（.txt，微信里直接能看）+ 表格（.csv，Excel/WPS 可开）。
  /// 内容就是"这件拣了多少"（条码/数量/名称），与扫码枪明细同口径，
  /// 只是文件名前缀错开成「拣货明细」，免得两份文件在微信里发串。
  Future<void> _exportScanList({required bool asDoc}) async {
    final rows = _rows;
    if (rows.isEmpty) {
      _snack('还没有拣货记录，先扫几条再导出');
      return;
    }
    setState(() => _exporting = true);
    try {
      // 🔴 文件名用单据名（龙哥 2026-10-06）：起了名的单，导出/转发就叫名字，
      // 别再退回单号 —— 好又多版就是栽在"转发的文件名还是单号"上。
      // 没起名才兜底用单号。
      final label = _sheetName.trim().isEmpty ? _sheetNo : _sheetName.trim();
      final base = asDoc
          ? '拣货明细_$label.txt'
          : '拣货明细_$label.csv';
      final name = FileIo.safeName(base);
      final text = asDoc
          ? StocktakeExport.toScanDoc(rows, sheetNo: _sheetNo)
          : StocktakeExport.toScanCsv(rows);
      final dir = await FileIo.dir();
      final f = File('${dir.path}${Platform.pathSeparator}$name');
      await f.writeAsString(text); // UTF-8；CSV 的 BOM 由 toScanCsv 负责
      if (!mounted) return;
      setState(() => _exporting = false);
      await _afterExport(f, rows.length, label);
    } catch (e) {
      if (!mounted) return;
      setState(() => _exporting = false);
      _snack('导出失败：$e');
    }
  }

  Future<void> _afterExport(File f, int rows, String label) async {
    await ExportFlow.show(
      context,
      f,
      rows: rows,
      suggestName: '拣货明细_$label',
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
        title:  Text('自由拣货单',
            style: TextStyle(color: AppColors.text, fontSize: 17)),
        actions: [
          IconButton(
            tooltip: '切换/新建拣货单',
            icon: Icon(Icons.receipt_long, color: AppColors.textSub),
            onPressed: _pickSheet,
          ),
          IconButton(
            tooltip: '清空本单',
            icon: Icon(Icons.delete_outline, color: AppColors.textSub),
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
                Divider(height: 1, color: AppColors.divider),
                _listHeader(),
                Expanded(child: _list()),
              ],
            ),
      bottomNavigationBar: _loading ? null : _exportBar(),
    );
  }

  Widget _exportBar() => Container(
        decoration:  BoxDecoration(
          color: AppColors.bgElevated,
          border: Border(top: BorderSide(color: AppColors.divider)),
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed:
                        _exporting ? null : () => _exportScanList(asDoc: true),
                    icon: const Icon(Icons.description_outlined, size: 18),
                    label: const Text('导出文档',
                        style: TextStyle(fontSize: 14)),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton.icon(
                    onPressed:
                        _exporting ? null : () => _exportScanList(asDoc: false),
                    icon: const Icon(Icons.table_view_outlined, size: 18),
                    label: const Text('导出表格',
                        style: TextStyle(fontSize: 14)),
                  ),
                ),
                if (_exporting) ...[
                  const SizedBox(width: 10),
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ],
              ],
            ),
          ),
        ),
      );

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
            Icon(Icons.numbers, size: 16, color: AppColors.textWeak),
            const SizedBox(width: 6),
            // 有名字显示「名字（单号）」，空则只显示单号 —— 与扫码枪一致。
            Expanded(
              child: Text(
                _sheetName.isEmpty
                    ? _sheetNo
                    : '$_sheetName（$_sheetNo）',
                style: TextStyle(color: AppColors.text, fontSize: 13),
                overflow: TextOverflow.ellipsis,
              ),
            ),
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

  Widget _chip(String text, {Color? color}) {
    // 默认色不能写成参数默认值：AppColors 是运行时值（换肤要重写），
    // 而默认参数值必须编译期常量。改可空 + 内部回落。
    final c = color ?? AppColors.textSub;
    return Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: c.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(text, style: TextStyle(color: c, fontSize: 12)),
      );
  }

  Widget _inputBar() => Container(
        color: AppColors.bgElevated,
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
        child: Row(
          children: [
            // 手机端把「扫码」放最左、给足面积（铁律：带扫码的地方走扫码枪界面）。
            if (cameraScanSupported) ...[
              Material(
                color: AppColors.brand.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(AppRadii.sm),
                child: InkWell(
                  borderRadius: BorderRadius.circular(AppRadii.sm),
                  onTap: _openCamera,
                  child:  Padding(
                    padding: EdgeInsets.symmetric(horizontal: 12, vertical: 11),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.qr_code_scanner,
                            color: AppColors.brand, size: 20),
                        SizedBox(width: 6),
                        Text('扫码',
                            style: TextStyle(
                                color: AppColors.brand,
                                fontSize: 13,
                                fontWeight: FontWeight.w600)),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
            ],
            Expanded(
              child: TextField(
                controller: _input,
                focusNode: _focus,
                autofocus: true,
                keyboardType: TextInputType.text,
                enableSuggestions: false,
                autocorrect: false,
                textInputAction: TextInputAction.done,
                style: TextStyle(color: AppColors.text, fontSize: 15),
                decoration: InputDecoration(
                  hintText: '扫码枪直接打，或手输条码回车',
                  hintStyle:
                      TextStyle(color: AppColors.textWeak, fontSize: 13),
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
                    icon: Icon(Icons.sync, color: AppColors.brand),
                    onPressed: _syncMaster,
                  ),
          ],
        ),
      );

  /// 扫完的即时反馈（带商档：品名 + 规格 + 单位 + 数量）。
  Widget _hitBanner() {
    final h = _lastHit!;
    final name = (h['name'] ?? '').toString();
    final spec = (h['spec'] ?? '').toString();
    final unit = (h['unit'] ?? '').toString();
    final qty = StocktakeExport.fmtNum(h['qty']);
    final unknown = name.isEmpty;
    final tail = <String>[];
    if (spec.isNotEmpty) tail.add(spec);
    if (unit.isNotEmpty) tail.add(unit);
    final detail = tail.isEmpty ? '' : '（${tail.join(' / ')}）';
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
              unknown
                  ? '未知条码 ${h['barcode']} × $qty（商档里没有）'
                  : '$name$detail × $qty',
              style: TextStyle(color: AppColors.text, fontSize: 13),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _list() {
    if (_rows.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            cameraScanSupported
                ? '还没有拣货记录\n点左边「扫码」用摄像头扫，\n或用扫码枪对着上面的输入框扫'
                : '还没有拣货记录\n把光标放在上面的输入框，用扫码枪扫即可',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.textWeak, fontSize: 13),
          ),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.only(bottom: 12),
      itemCount: _rows.length,
      separatorBuilder: (_, __) =>
          Divider(height: 1, color: AppColors.divider),
      itemBuilder: (_, i) => _row(i, _rows[i]),
    );
  }

  static const double _kIdxW = 36;
  static const double _kQtyW = 56;
  static const double _kDelW = 44;
  static const double _kCodeFlex = 5;
  static const double _kNameFlex = 6;

  Widget _listHeader() => Container(
        color: AppColors.bgElevated,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        child: Row(
          children: [
            _hCell('序号', _kIdxW),
            const SizedBox(width: 8),
             Expanded(
              flex: 5,
              child: Text('条码',
                  style: TextStyle(color: AppColors.textWeak, fontSize: 11)),
            ),
            const SizedBox(width: 8),
            _hCell('数量', _kQtyW),
            const SizedBox(width: 8),
             Expanded(
              flex: 6,
              child: Text('商品名称',
                  style: TextStyle(color: AppColors.textWeak, fontSize: 11)),
            ),
            const SizedBox(width: _kDelW),
          ],
        ),
      );

  Widget _hCell(String text, double w) => SizedBox(
        width: w,
        child: Text(text,
            textAlign: text == '数量' ? TextAlign.center : TextAlign.left,
            style: TextStyle(color: AppColors.textWeak, fontSize: 11)),
      );

  Widget _row(int index, Map<String, dynamic> r) {
    final name = (r['name'] ?? '').toString();
    final spec = (r['spec'] ?? '').toString();
    final unit = (r['unit'] ?? '').toString();
    final qty = (r['qty'] as num?)?.toDouble() ?? 0;
    final unknown = name.trim().isEmpty;

    final label = unknown
        ? '未知条码'
        : (spec.isNotEmpty ? '$name（$spec' + (unit.isNotEmpty ? ' / $unit' : '') + '）' : name);

    return Container(
      key: ValueKey<String>('pick-row-${r['barcode']}'),
      color: AppColors.bg,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: Row(
        children: [
          SizedBox(
            width: _kIdxW,
            child: Text('${index + 1}',
                style: TextStyle(color: AppColors.textWeak, fontSize: 13)),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: _kCodeFlex.toInt(),
            child: Text(r['barcode'].toString(),
                style: TextStyle(color: AppColors.text, fontSize: 12),
                overflow: TextOverflow.ellipsis),
          ),
          const SizedBox(width: 8),
          SizedBox(
            key: ValueKey<String>('pick-qty-${r['barcode']}'),
            width: _kQtyW,
            child: Tooltip(
              message: '点这里改数量',
              child: Material(
                color: AppColors.brand.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(7),
                child: InkWell(
                  borderRadius: BorderRadius.circular(7),
                  onTap: () => _editQty(r),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 5),
                    child: Text(
                      StocktakeExport.fmtNum(qty),
                      textAlign: TextAlign.center,
                      style:  TextStyle(
                          color: AppColors.brand,
                          fontSize: 15,
                          fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: _kNameFlex.toInt(),
            child: Text(
              label,
              style: TextStyle(
                  color: unknown ? AppColors.warn : AppColors.text,
                  fontSize: 13),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          SizedBox(
            width: _kDelW,
            height: 36,
            child: IconButton(
              tooltip: '删除本行',
              icon:  Icon(Icons.delete_outline,
                  color: AppColors.danger, size: 20),
              onPressed: () => _deleteRow(r),
            ),
          ),
        ],
      ),
    );
  }
}
