import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../core/file_io.dart';
import '../core/scan_feedback.dart';
import '../core/stock_master_repo.dart';
import '../core/stocktake_export.dart';
import '../core/stocktake_repo.dart';
import '../core/theme.dart';
import '../widgets/export_flow.dart';
import '../widgets/qty_edit.dart';
import 'stocktake_result.dart';
import 'stocktake_scan.dart';

/// 扫码枪：采集页。
///
/// ── 这一页为什么不叫「盘点」 ──────────────────────────────────
/// 它的本职是**把条码快速扫成一笔账**：扫码 + 明细列表 + 导出 + 盈亏表。
/// 它是"采集工具"，不是"盘点制度"。
/// 真正的盘点（盘点位 / 库位货架位 / 初盘-复盘-抽盘三遍制 / 抽盘授权）是
/// 另一个模块，名字已经留给它。所以这里**用词一律是"扫码"，不再出现"盘点"** ——
/// 否则两个模块会在界面上、在导出文件名上互相打架，员工也分不清哪个是哪个。
///
/// ── 这一页为什么完全不发网络请求 ──────────────────────────────
/// 扫码是在货架之间做的，那里的网络不归我们管。所以"扫一个码 → 记一笔"
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
  String _sheetName = '';
  List<Map<String, dynamic>> _rows = const [];
  Map<String, dynamic> _summary = const {};
  int _masterCount = 0;

  bool _loading = true;
  bool _syncing = false;
  bool _exporting = false;
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
      // 有没盘完的单就接着盘，别一进来就开新单（上次的数据会"消失"）。
      // 只认扫码枪自己的单（PD 开头）—— 盘点单（INV-）共用同一张流水表，
      // 不筛的话这里会把盘点单当成"上次没扫完的扫码单"接着扫。
      final sheets = await _repo.listSheets(prefix: StocktakeRepo.sheetPrefix);
      final no = sheets.isEmpty ? StocktakeRepo.newSheetNo() : sheets.first['sheet_no'] as String;
      // 🔴 数全表：服务端同步下来的商档 source 是 server，countLocal 默认只数 tiger
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
        _error = '打开扫码枪失败：$e';
        _loading = false;
      });
    }
  }

  /// [refocus] 刷完要不要把焦点抢回输入框。
  /// 扫码枪需要（焦点丢了枪就打偏），但从摄像头页返回时不要 ——
  /// 用户刚从相机回来，再给他弹一次软键盘是纯打扰。
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
      // 🔴 声音**先于界面**：扫码枪是连贯动作，员工靠这一声确认"记上了"
      // 才敢扫下一件。等列表刷完再响就慢半拍了。
      // 这一页没有"拒绝"这回事（扫码枪扫什么都入账），所以只有成功音；
      // 异常走 catch 给失败音 —— 写库失败必须听得出来，不能静默吞掉。
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
    if (!StocktakeScanPage.supported) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => StocktakeScanPage(sheetNo: _sheetNo, repo: _repo),
      ),
    );
    if (!mounted) return;
    // 从相机回来不抢焦点（见 _reload 的 refocus 说明）
    await _reload(refocus: false);
  }

  /// 同步商档。
  ///
  /// 🔴 现在从**自家服务端**拉（/api/master），不再走泰格上游钩子：
  ///    那台机器一关机、IP 一漂就是 fetch failed，接着商档同步永远失败，
  ///    扫码枪扫什么都是"未知条码"。商档是门店自己的底表，放自家服务端
  ///    才靠得住 —— 管理台导入一次，所有手机拉同一份。
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
    final no = StocktakeRepo.newSheetNo();
    // 🔴 先弹窗起名（好又多版同款，龙哥 2026-10-06 要求继承过来）：
    // 单据一多，光看 PD+时间戳分不清哪张单盘的是什么。名字可空 —— 空着用单号。
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
    _snack(name.isEmpty ? '已新建扫码单 $no' : '已新建扫码单「$name」');
  }

  Future<void> _pickSheet() async {
    final sheets = await _repo.listSheets(prefix: StocktakeRepo.sheetPrefix);
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
              title:  Text('新建一张扫码单',
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
  /// 新建和改名共用（与好又多版一致，同一种动作一种界面）。
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
            hintText: hint ?? '例如：日配 9 月底盘点',
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
        title:  Text('清空本张扫码单？',
            style: TextStyle(color: AppColors.text)),
        content: Text('将删除 $_sheetNo 的全部扫码记录，不可恢复。',
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
  /// 员工把某个码扫多了，最直觉的操作就是行尾那个删除按钮，
  /// 而不是"减到 0"——一行点 N 次减号在货架边上是不可接受的。
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

  /// 点数量就能改。
  ///
  /// 现场要修正的其实是两件事，都得支持：
  ///   · "这一箱是 12 个，不是 1 个" → 要能改**大**（只给加减号的话要点 11 次）
  ///   · "刚才多扫了一下" → 要能改**小**
  /// 所以给一个可编辑的数字框，而不是行内加减号。
  ///
  /// 改到 0 = 删除该行（`StocktakeRepo.setQty` 的既有语义），但**要二次确认**：
  /// 手滑多按一个 0 就静默删行，是员工第二天才发现的那种错。
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

  /// 出数：打开盈亏表。扫完顺手看一眼才敢收工，所以入口就放在采集页顶上。
  Future<void> _openResult() async {
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
          builder: (_) => StocktakeResultPage(sheetNo: _sheetNo)),
    );
    if (!mounted) return;
    await _reload();
  }

  /// 底部导出：[asDoc] = 文本文档（.txt），否则表格（.csv）。
  /// 两份都是"扫码明细"这一份原始账，口径与界面列表完全一致。
  Future<void> _exportScanList({required bool asDoc}) async {
    final rows = _rows;
    if (rows.isEmpty) {
      _snack('还没有扫码记录，先扫几条再导出');
      return;
    }
    setState(() => _exporting = true);
    try {
      // 🔴 文件名优先用单据名（龙哥 2026-10-06）：转发出去要让同事看得出
      // 这是哪张单，而不是一串 PD+时间戳。没起名才兜底单号。
      final name = FileIo.safeName(asDoc
          ? StocktakeExport.scanDocName(_sheetNo, _sheetName)
          : StocktakeExport.scanCsvName(_sheetNo, _sheetName));
      final text = asDoc
          ? StocktakeExport.toScanDoc(rows, sheetNo: _sheetNo)
          : StocktakeExport.toScanCsv(rows);
      final dir = await FileIo.dir();
      final f = File('${dir.path}${Platform.pathSeparator}$name');
      await f.writeAsString(text); // UTF-8；CSV 的 BOM 由 toScanCsv 负责
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
  ///
  /// 弹层本体已抽到 `widgets/export_flow.dart`，与盈亏表页、盘点采集页共用一份。
  /// 各写一份的代价是：下次修"某个平台少了微信"只改一处，
  /// 另一处就变成"看起来有、点了没反应"的坑。
  Future<void> _afterExport(File f, int rows) async {
    await ExportFlow.show(
      context,
      f,
      rows: rows,
      // 转发建议名同样优先单据名（与实际文件名一致，别两边对不上）。
      suggestName: ExportFlow.asDocName(f)
          ? StocktakeExport.scanDocName(_sheetNo, _sheetName)
          : StocktakeExport.scanCsvName(_sheetNo, _sheetName),
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
        title:  Text('扫码枪',
            style: TextStyle(color: AppColors.text, fontSize: 17)),
        actions: [
          IconButton(
            tooltip: '盈亏表',
            icon: Icon(Icons.assessment_outlined, color: AppColors.brand),
            onPressed: _openResult,
          ),
          IconButton(
            tooltip: '切换/新建扫码单',
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
                // 表头**常显**：空列表时也要让人看见这个列表有哪几列。
                // 之前是 _rows.isNotEmpty 才画，结果没扫之前整页看不出有列表，
                // 现场被当成"这功能没做"。列表结构本身也是要给人看的。
                _listHeader(),
                Expanded(child: _list()),
              ],
            ),
      // 导出栏同样常显（空单时点它会给"先扫几条再导出"的提示），理由同上：
      // 底部的能力要一眼可见，不能"扫完才长出来"。
      bottomNavigationBar: _loading ? null : _exportBar(),
    );
  }

  /// 底部导出栏：文档（.txt，微信里直接能看）+ 表格（.csv，Excel/WPS 可开）。
  /// 挂在 bottomNavigationBar 上，列表再长也始终可见、不用滚到底找。
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
            // 有名字显示「名字（单号）」，空则只显示单号 —— 与好又多版一致。
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
            // 手机端把「扫码」放最左、给足面积 —— 现场大多数店没有扫码枪，
            // 摄像头才是主路径，输入框是兜底。
            if (StocktakeScanPage.supported) ...[
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
                // 🔴 这里**不能**用 TextInputType.visiblePassword。
                // 之前用它本意是"压掉输入法联想/纠错"（扫码枪会敲出一串数字+回车），
                // 但 Android 把它当成密码框处理 → 弹出来的是**密码安全键盘**，
                // 数字全被打成圆点、布局也和普通键盘不一样，员工当场就懵了。
                // 真正要做的是"关掉输入法干预"，那是下面两个开关的活，
                // 跟键盘类型无关：普通键盘 + 关联想 + 关纠错就够了。
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
            StocktakeScanPage.supported
                ? '还没有扫码记录\n点左边「扫码」用摄像头扫，\n或用扫码枪对着上面的输入框扫'
                : '还没有扫码记录\n把光标放在上面的输入框，用扫码枪扫即可',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.textWeak, fontSize: 13),
          ),
        ),
      );
    }
    // 表格式列表：序号 | 条码 | 数量 | 商品名称 | 删除。
    // 列宽常量集中在 [_listHeader] 和 [_row] 两处共用，改一处必须同步另一处。
    return ListView.separated(
      padding: const EdgeInsets.only(bottom: 12),
      itemCount: _rows.length,
      separatorBuilder: (_, __) =>
          Divider(height: 1, color: AppColors.divider),
      itemBuilder: (_, i) => _row(i, _rows[i]),
    );
  }

  /// 表头。列宽与 [_row] 严格共用同一组常量，保证表头和内容对齐。
  static const double _kIdxW = 36; // 序号
  static const double _kQtyW = 56; // 数量
  static const double _kDelW = 44; // 删除按钮
  static const double _kCodeFlex = 5; // 条码
  static const double _kNameFlex = 6; // 商品名称

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
            // 数量列的内容是居中的胶囊，表头跟着居中才对得齐
            textAlign: text == '数量' ? TextAlign.center : TextAlign.left,
            style: TextStyle(color: AppColors.textWeak, fontSize: 11)),
      );

  Widget _row(int index, Map<String, dynamic> r) {
    final name = (r['name'] ?? '').toString();
    final qty = (r['qty'] as num?)?.toDouble() ?? 0;
    final unknown = name.trim().isEmpty;

    return Container(
      // 行级 key：让测试能精确指到"这一行"的数量/删除按钮，
      // 而不是靠 findsWidgets 猜（"2"既可能是序号也可能是数量，猜不准）。
      key: ValueKey<String>('scan-row-${r['barcode']}'),
      color: AppColors.bg,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: Row(
        children: [
          // ① 序号
          SizedBox(
            width: _kIdxW,
            child: Text('${index + 1}',
                style:
                    TextStyle(color: AppColors.textWeak, fontSize: 13)),
          ),
          const SizedBox(width: 8),
          // ② 条码
          Expanded(
            flex: _kCodeFlex.toInt(),
            child: Text(r['barcode'].toString(),
                style: TextStyle(color: AppColors.text, fontSize: 12),
                overflow: TextOverflow.ellipsis),
          ),
          const SizedBox(width: 8),
          // ③ 数量：点一下就改（重复扫同一个码，这里也是直接 +1）
          //    做成有底色的小胶囊，是让"这里能点"看得见 ——
          //    纯文字数字谁都不会去点它。
          SizedBox(
            key: ValueKey<String>('scan-qty-${r['barcode']}'),
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
          // ④ 商品名称（商档里没有的用预留值「未知条码」）
          Expanded(
            flex: _kNameFlex.toInt(),
            child: Text(
              StocktakeExport.scanNameOf(r),
              style: TextStyle(
                  color: unknown ? AppColors.warn : AppColors.text,
                  fontSize: 13),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          // ⑤ 行尾固定删除按钮
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
