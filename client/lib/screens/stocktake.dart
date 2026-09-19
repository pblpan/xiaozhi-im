import 'dart:io';

import 'package:flutter/material.dart';

import '../core/file_io.dart';
import '../core/file_share.dart';
import '../core/stock_master_repo.dart';
import '../core/stocktake_export.dart';
import '../core/stocktake_repo.dart';
import '../core/theme.dart';
import '../core/win_shell.dart';
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
    _snack('已新建扫码单 $_sheetNo');
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
              title: const Text('新建一张扫码单',
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
        title: const Text('清空本张扫码单？',
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

    final v = await showDialog<String>(
      context: context,
      builder: (ctx) => _QtyDialog(
        subtitle: '${StocktakeExport.scanNameOf(r)}　${r['barcode']}',
        initial: StocktakeExport.fmtNum(cur),
      ),
    );
    if (v == null || !mounted) return;

    final n = double.tryParse(v.trim());
    if (n == null) {
      _snack('「${v.trim()}」不是数字，没改');
      return;
    }
    if (n < 0) {
      _snack('数量不能是负数');
      return;
    }
    if (n == 0) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppColors.bgElevated,
          title: const Text('改成 0 = 删掉这一行',
              style: TextStyle(color: AppColors.text, fontSize: 16)),
          content: Text('确定删除 ${r['barcode']} 这一行？',
              style: const TextStyle(color: AppColors.textSub)),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消')),
            TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child:
                    const Text('删除', style: TextStyle(color: AppColors.danger))),
          ],
        ),
      );
      if (ok != true) return;
    }

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
      final name = FileIo.safeName(asDoc
          ? StocktakeExport.scanDocName(_sheetNo)
          : StocktakeExport.scanCsvName(_sheetNo));
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

  /// 导出后给几条路。**第一优先是"直接发给同事"** ——
  /// 导出的目的就是发出去，先落盘再让用户自己去文件管理器找回来发，
  /// 中间那两步纯属白干（这也是龙哥 2026-09-19 提的原话）。
  ///
  /// 平台差异见 [FileShare.canShareToOthers]：手机端是真分享面板，
  /// 桌面端没有这玩意，就换成"打开所在文件夹"让他拖进微信 ——
  /// 不做假按钮（点了没反应比没这个按钮更糟）。
  Future<void> _afterExport(File f, int rows) async {
    final channel = FileShare.channel;
    final act = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppColors.bgElevated,
      builder: (ctx) => SafeArea(
        // 弹层里现在最多 5 条，小屏 + 系统大字体下会超出底部弹层的最大高度，
        // 最后一条（"先不用"）会落在屏幕外**点不到**。给个滚动兜底。
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.check_circle_outline,
                    color: AppColors.brand),
                title: Text(
                    '已生成 $rows 行：${fileNameOf(f)}',
                    style: const TextStyle(color: AppColors.text, fontSize: 13)),
              ),
              // 只给这台设备真能走的那一条 —— 见 FileShare.channelFor 的说明：
              // 在桌面上摆一个"发给同事"就是假按钮（点了没反应）。
              if (channel == ShareChannel.systemShare)
                ListTile(
                  key: const Key('share-to-others'),
                  leading: const Icon(Icons.send, color: AppColors.brand),
                  title: const Text('发给同事（微信 / 企微 / 钉钉…）',
                      style: TextStyle(
                          color: AppColors.text, fontWeight: FontWeight.w600)),
                  onTap: () => Navigator.pop(ctx, 'share'),
                )
              else if (channel == ShareChannel.openFolder)
                ListTile(
                  key: const Key('share-to-others'),
                  leading: const Icon(Icons.folder_open, color: AppColors.brand),
                  title: const Text('打开所在文件夹（拖进微信发送）',
                      style: TextStyle(
                          color: AppColors.text, fontWeight: FontWeight.w600)),
                  onTap: () => Navigator.pop(ctx, 'folder'),
                ),
              ListTile(
                leading: const Icon(Icons.open_in_new, color: AppColors.textSub),
                title: const Text('打开（用 WPS / Excel / 记事本看）',
                    style: TextStyle(color: AppColors.text)),
                onTap: () => Navigator.pop(ctx, 'open'),
              ),
              ListTile(
                leading: const Icon(Icons.save_alt, color: AppColors.textSub),
                title: const Text('另存为 / 发到别处',
                    style: TextStyle(color: AppColors.text)),
                onTap: () => Navigator.pop(ctx, 'save'),
              ),
              ListTile(
                leading: const Icon(Icons.close, color: AppColors.textWeak),
                title: const Text('先不用',
                    style: TextStyle(color: AppColors.textSub)),
                onTap: () => Navigator.pop(ctx),
              ),
            ],
          ),
        ),
      ),
    );
    if (act == null || !mounted) return;

    if (act == 'share') {
      // 分享面板是系统的，拉起来就完事 —— 用户选谁发是他自己的事，
      // 我们拿不到"发没发成功"的回执（Android 不给），所以这里只说"已打开"。
      //
      // 标题取**实际文件名**，不是拿单号现拼一个：导出文档(.txt) 与
      // 导出表格(.csv) 是两个文件，标题写错会让接收方以为拿到的不是这份。
      final err = await FileShare.toOthers(f, subject: fileNameOf(f));
      if (!mounted) return;
      _snack(err.isEmpty ? '已打开分享面板，选同事发送即可' : err);
      return;
    }
    if (act == 'folder') {
      final ok = WinShell.revealInExplorer(f.path);
      if (!mounted) return;
      _snack(ok ? '已在资源管理器中定位到该文件' : '打开文件夹失败：${f.path}');
      return;
    }
    if (act == 'open') {
      final err = await FileIo.open(f);
      if (!mounted) return;
      _snack(err.isEmpty ? '已交给系统打开' : err);
      return;
    }
    final where = await FileIo.saveAs(f, asDocName(f)
        ? StocktakeExport.scanDocName(_sheetNo)
        : StocktakeExport.scanCsvName(_sheetNo));
    if (!mounted) return;
    _snack(where == null ? '已取消' : '已保存：$where');
  }

  static bool asDocName(File f) => f.path.toLowerCase().endsWith('.txt');

  /// 文件的实际名字（含扩展名）。分享标题、提示文案都用它，
  /// 不去拿单号现拼 —— 拼出来的名字和真实文件可能不是一份。
  static String fileNameOf(File f) => f.path.split(Platform.pathSeparator).last;

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
        title: const Text('扫码枪',
            style: TextStyle(color: AppColors.text, fontSize: 17)),
        actions: [
          IconButton(
            tooltip: '盈亏表',
            icon: const Icon(Icons.assessment_outlined, color: AppColors.brand),
            onPressed: _openResult,
          ),
          IconButton(
            tooltip: '切换/新建扫码单',
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
        decoration: const BoxDecoration(
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
            // 手机端把「扫码」放最左、给足面积 —— 现场大多数店没有扫码枪，
            // 摄像头才是主路径，输入框是兜底。
            if (StocktakeScanPage.supported) ...[
              Material(
                color: AppColors.brand.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(AppRadii.sm),
                child: InkWell(
                  borderRadius: BorderRadius.circular(AppRadii.sm),
                  onTap: _openCamera,
                  child: const Padding(
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
                style: const TextStyle(color: AppColors.text, fontSize: 15),
                decoration: InputDecoration(
                  hintText: '扫码枪直接打，或手输条码回车',
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
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            StocktakeScanPage.supported
                ? '还没有扫码记录\n点左边「扫码」用摄像头扫，\n或用扫码枪对着上面的输入框扫'
                : '还没有扫码记录\n把光标放在上面的输入框，用扫码枪扫即可',
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppColors.textWeak, fontSize: 13),
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
          const Divider(height: 1, color: AppColors.divider),
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
            const Expanded(
              flex: 5,
              child: Text('条码',
                  style: TextStyle(color: AppColors.textWeak, fontSize: 11)),
            ),
            const SizedBox(width: 8),
            _hCell('数量', _kQtyW),
            const SizedBox(width: 8),
            const Expanded(
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
            style: const TextStyle(color: AppColors.textWeak, fontSize: 11)),
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
                    const TextStyle(color: AppColors.textWeak, fontSize: 13)),
          ),
          const SizedBox(width: 8),
          // ② 条码
          Expanded(
            flex: _kCodeFlex.toInt(),
            child: Text(r['barcode'].toString(),
                style: const TextStyle(color: AppColors.text, fontSize: 12),
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
                      style: const TextStyle(
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
              icon: const Icon(Icons.delete_outline,
                  color: AppColors.danger, size: 20),
              onPressed: () => _deleteRow(r),
            ),
          ),
        ],
      ),
    );
  }
}

/// 「改数量」对话框。
///
/// 🔴 **为什么必须是独立的 StatefulWidget，而不是在 `_editQty` 里 new 一个
///    TextEditingController、`await showDialog(...)` 回来就 `dispose()`：**
///
/// `await showDialog(...)` 在 `Navigator.pop` 那一刻就返回了，可这时对话框
/// **还在播退场动画**，`TextField` 这 200ms 里还在重建、还在向控制器注册监听。
/// 提前 dispose 会直接抛 `A TextEditingController was used after being disposed`，
/// 并连带把焦点树和布局搞乱 —— 实测报 `RenderFlex overflowed by 99634 pixels`，
/// 报错指向的是"布局溢出"，跟真凶（控制器生命周期）看着毫无关系，极难倒查。
///
/// 交给对话框自己持有 → 它的 `State.dispose()` 在**路由真正被移除时**才跑，
/// 时序天然正确；而且"用户点对话框外面关掉"那条路径也自动覆盖到了
/// （在 `_editQty` 里手动 dispose 的话，很容易只处理 保存/取消 两条路）。
class _QtyDialog extends StatefulWidget {
  const _QtyDialog({required this.subtitle, required this.initial});

  /// 副标题：商品名 + 条码，让人确认改的是哪一行
  final String subtitle;
  final String initial;

  @override
  State<_QtyDialog> createState() => _QtyDialogState();
}

class _QtyDialogState extends State<_QtyDialog> {
  late final TextEditingController _ctrl =
      TextEditingController(text: widget.initial);

  @override
  void initState() {
    super.initState();
    // 全选：员工要的是"直接覆盖"，不是先删掉原来那串再输
    _ctrl.selection =
        TextSelection(baseOffset: 0, extentOffset: _ctrl.text.length);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.bgElevated,
      title: const Text('改数量',
          style: TextStyle(color: AppColors.text, fontSize: 16)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.subtitle,
            style: const TextStyle(color: AppColors.textWeak, fontSize: 12),
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _ctrl,
            autofocus: true,
            // 数量可能是小数（称重商品按公斤），所以允许小数点
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            style: const TextStyle(color: AppColors.text, fontSize: 16),
            textInputAction: TextInputAction.done,
            onSubmitted: (s) => Navigator.pop(context, s),
            decoration: InputDecoration(
              hintText: '数量',
              hintStyle: const TextStyle(color: AppColors.textWeak),
              filled: true,
              fillColor: AppColors.surface,
              isDense: true,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide.none,
              ),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context), child: const Text('取消')),
        TextButton(
          onPressed: () => Navigator.pop(context, _ctrl.text),
          child: const Text('保存',
              style:
                  TextStyle(color: AppColors.brand, fontWeight: FontWeight.w600)),
        ),
      ],
    );
  }
}
