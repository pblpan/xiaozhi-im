import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/deduct_export.dart';
import '../core/deduct_repo.dart';
import '../core/deduct_rules.dart';
import '../core/file_io.dart';
import '../core/inventory_rules.dart';
import '../core/theme.dart';
import '../widgets/export_flow.dart';

/// 库房减货：扫码 → 减货数量 → 确定减货。
///
/// ── 和「盘点」「扫码枪」什么关系 ──────────────────────────────
///   · 扫码枪：把条码扫成一笔账（工具，不分位置/阶段/规则）；
///   · 盘点：点位 × 初盘/复盘/抽盘三遍制；
///   · 减货（本页）：**减库存**的作业单 —— 没有点位、没有阶段，
///     唯一的硬规则是"同一条码一张单里只能有一行"。
///
/// 单子和明细与盘点**共用两张表**（靠 sheet_type 区分），
/// 所以提交/导出/清本地这些链路的语义和盘点是同一套，员工不用学第二遍。
///
/// ── 为什么这一页不需要选点位 ─────────────────────────────────
/// PG App 里它叫「库房减货」——是库房那一趟活，不挂在盘点位上。
/// 真要做分区（比如多个库房各一张单），加"扫库房码"就是一步的事，
/// 但不能现在假装支持：界面上多一个不知道填什么的框，比没有更糟。
class DeductPage extends StatefulWidget {
  const DeductPage({super.key, this.repo});

  /// 测试注入点（可以给一个 maxRows 调小的仓库）。
  final DeductRepo? repo;

  @override
  State<DeductPage> createState() => _DeductPageState();
}

class _DeductPageState extends State<DeductPage> {
  late DeductRepo _repo;

  final TextEditingController _scanCtl = TextEditingController();
  final TextEditingController _qtyCtl = TextEditingController(text: '1');
  final FocusNode _scanFocus = FocusNode();

  Map<String, dynamic>? _sheet;
  List<Map<String, dynamic>> _rows = const [];
  DeductTally _tally = const DeductTally(kinds: 0, totalQty: 0);
  bool _loading = true;
  bool _busy = false;
  String? _error;

  /// 当前打开的**那一张**单的单号。
  ///
  /// 🔴 必须记住它，不能每次刷新都去 `openOrCreate()`：提交之后那张单
  /// 已经不是"进行中"了，`openOrCreate` 找不到进行中的单就会**再开一张空的**，
  /// 现场看到的是"刚提交的单凭空消失、状态又变回进行中、明细全没了"，
  /// 而「撤销提交」还会改到那张新单上 —— 老单永远退不回来。
  String? _curNo;

  @override
  void initState() {
    super.initState();
    _repo = widget.repo ?? DeductRepo();
    _reload();
  }

  @override
  void dispose() {
    _scanCtl.dispose();
    _qtyCtl.dispose();
    _scanFocus.dispose();
    super.dispose();
  }

  bool get _editable =>
      _sheet != null &&
      InvSheetStatus.editable((_sheet!['status'] as num? ?? 0).toInt());

  String get _sheetNo => _curNo ?? '';

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  /// [forceNew] = 明确要开一张新单（菜单里的「开新单」）。
  /// [loadNo]   = 明确要翻到历史里的某一单（历史面板里点的）。
  Future<void> _reload({bool forceNew = false, String? loadNo}) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      Map<String, dynamic>? s;
      final cur = loadNo ?? _curNo;
      if (!forceNew && cur != null) s = await _repo.findSheet(cur);
      s ??= await _repo.openOrCreate(forceNew: forceNew);
      final no = s['sheet_no'] as String;
      final rows = await _repo.listRows(no);
      final t = await _repo.summary(no);
      if (!mounted) return;
      setState(() {
        _curNo = no;
        _sheet = s;
        _rows = rows;
        _tally = t;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '打开减货单失败：$e';
        _loading = false;
      });
    }
  }

  /// 翻历史单。
  ///
  /// 🔴 没有这条路的话，交完单再点「开新单」，上一张就**永远够不着了**：
  ///    页面上只有"当前这一张"，而减货单是"货已经减了"的凭据，导不出来等于没留痕。
  Future<void> _pickSheet() async {
    List<Map<String, dynamic>> briefs;
    try {
      briefs = await _repo.sheetBriefs();
    } catch (e) {
      _snack('读历史单据失败：$e');
      return;
    }
    if (!mounted) return;
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppColors.bgElevated,
      builder: (ctx) => SafeArea(
        child: Column(
          key: const Key('deduct-history-sheet'),
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 14, 16, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('历史减货单',
                    style: TextStyle(
                        color: AppColors.text,
                        fontSize: 15,
                        fontWeight: FontWeight.w600)),
              ),
            ),
            const Divider(height: 1, color: AppColors.divider),
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: briefs.length,
                separatorBuilder: (_, __) =>
                    const Divider(height: 1, color: AppColors.divider),
                itemBuilder: (_, i) {
                  final b = briefs[i];
                  final no = (b['sheet_no'] ?? '').toString();
                  final st = (b['status'] as num? ?? 0).toInt();
                  final isCur = no == _curNo;
                  return ListTile(
                    key: Key('deduct-hs-$no'),
                    dense: true,
                    title: Text(
                      isCur ? '$no（当前）' : no,
                      style: TextStyle(
                          color: isCur ? AppColors.brand : AppColors.text,
                          fontSize: 14),
                    ),
                    subtitle: Text(
                      '${InvSheetStatus.label(st)} · '
                      '${(b['rows'] as num? ?? 0).toInt()} 条 · '
                      '合计 ${DeductExport.fmtQty(b['total_qty'])}',
                      style: const TextStyle(
                          color: AppColors.textSub, fontSize: 12),
                    ),
                    onTap: () => Navigator.pop(ctx, no),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
    if (picked == null || picked == _curNo) return;
    await _reload(loadNo: picked);
  }

  /// 开一张全新的单。
  ///
  /// 只在**当前这张已锁死**时开放（见菜单的 enabled 判据）：单子都还没交就
  /// 另起一张，上一张会变成没人认领的"孤儿进行中单"，谁也翻不到它。
  Future<void> _newSheet() async {
    try {
      await _reload(forceNew: true);
      if (!mounted) return;
      _snack('已开新单：$_sheetNo');
    } catch (e) {
      _snack('开新单失败：$e');
    }
  }

  Future<void> _addRow() async {
    final barcode = _scanCtl.text.trim();
    if (barcode.isEmpty) {
      _snack('先扫一个条码');
      _scanFocus.requestFocus();
      return;
    }
    final qtyRaw = _qtyCtl.text.trim();
    setState(() => _busy = true);
    try {
      final d = await _repo.addRow(
        sheetNo: _sheetNo,
        barcode: barcode,
        qtyRaw: qtyRaw,
      );
      if (!mounted) return;
      if (!d.accepted) {
        // 被拒时**保留输入**：员工要改的是那个数字，清掉等于让他重扫一遍。
        // 重复条码这条尤其重要 —— 他要看到自己扫的是哪个码才能去列表里找它。
        _snack(d.message ?? '这一笔没能入账');
        // 提示音是现场唯一来得及的反馈（屏幕不一定在看）
        SystemSound.play(SystemSoundType.alert);
        return;
      }
      _scanCtl.clear();
      _qtyCtl.text = '1';
      SystemSound.play(SystemSoundType.click);
      await _reload();
      if (!mounted) return;
      _scanFocus.requestFocus();
    } catch (e) {
      if (!mounted) return;
      _snack('录入失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _deleteRow(Map<String, dynamic> r) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.bgElevated,
        title: const Text('删掉这一行？',
            style: TextStyle(color: AppColors.text, fontSize: 16)),
        content: Text(
          '${r['barcode']}\n删除后可以重新扫这个条码。',
          style: const TextStyle(color: AppColors.textSub, fontSize: 14),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('删除',
                  style: TextStyle(
                      color: AppColors.danger, fontWeight: FontWeight.w600))),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _repo.deleteRow(r['id'] as int);
      await _reload();
    } catch (e) {
      _snack('删除失败：$e');
    }
  }

  Future<void> _editQty(Map<String, dynamic> r) async {
    final ctl =
        TextEditingController(text: DeductExport.fmtQty(r['qty']));
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.bgElevated,
        title: const Text('改减货数量',
            style: TextStyle(color: AppColors.text, fontSize: 16)),
        content: TextField(
          key: const Key('deduct-qty-input'),
          controller: ctl,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          style: const TextStyle(color: AppColors.text, fontSize: 15),
          decoration: const InputDecoration(labelText: '减货数量'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('保存',
                  style: TextStyle(
                      color: AppColors.brand, fontWeight: FontWeight.w600))),
        ],
      ),
    );
    final v = ctl.text.trim();
    ctl.dispose();
    if (ok != true) return;
    final err = DeductRules.qtyError(v);
    if (err != null) {
      _snack(err);
      return;
    }
    try {
      await _repo.setQty(r['id'] as int, double.parse(v));
      await _reload();
    } catch (e) {
      _snack('保存失败：$e');
    }
  }

  Future<void> _submit() async {
    if (_rows.isEmpty) {
      _snack('这一单还没有明细，先扫几条再提交');
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.bgElevated,
        title: const Text('提交这一单？',
            style: TextStyle(color: AppColors.text, fontSize: 16)),
        content: Text(
          '${DeductExport.summaryText(_tally)}\n'
          '提交后本地就锁死，不能再改（可撤销提交）。',
          style: const TextStyle(color: AppColors.textSub, fontSize: 14),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('再核对一下')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('提交',
                  style: TextStyle(
                      color: AppColors.brand, fontWeight: FontWeight.w600))),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _repo.submitSheet(_sheetNo);
      await _reload();
      _snack('已提交：$_sheetNo');
    } catch (e) {
      _snack('提交失败：$e');
    }
  }

  Future<void> _reopen() async {
    try {
      await _repo.reopenSheet(_sheetNo);
      await _reload();
      _snack('已撤销提交，可以继续改');
    } catch (e) {
      _snack('撤销失败：$e');
    }
  }

  Future<void> _clearAll() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.bgElevated,
        title: const Text('清除本机全部减货数据（不可恢复）',
            style: TextStyle(color: AppColors.text, fontSize: 16)),
        content: const Text(
          '会删掉本机**所有**减货单和明细。\n'
          '「盘点」的数据不受影响。没提交过的单删了就找不回来了。',
          style: TextStyle(color: AppColors.textSub, fontSize: 14),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('确认清除',
                  style: TextStyle(
                      color: AppColors.danger, fontWeight: FontWeight.w600))),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final r = await _repo.clearAll();
      // 单子已经全被删了，认住的那个单号也就不存在了 —— 清掉让刷新重开一张。
      _curNo = null;
      await _reload();
      _snack('已清除 ${r['sheets']} 张单、${r['rows']} 行明细');
    } catch (e) {
      _snack('清除失败：$e');
    }
  }

  Future<void> _export() async {
    if (_rows.isEmpty) {
      _snack('这一单还没有明细，先扫几条再导出');
      return;
    }
    setState(() => _busy = true);
    try {
      final name = FileIo.safeName(DeductExport.csvName(_sheetNo));
      final dir = await FileIo.dir();
      final f = File('${dir.path}${Platform.pathSeparator}$name');
      // UTF-8；CSV 的 BOM 由导出层负责（见 DeductExport.toCsv）
      await f.writeAsString(DeductExport.toCsv(_rows));
      if (!mounted) return;
      await ExportFlow.show(context, f,
          rows: _rows.length, suggestName: name, onMessage: _snack);
    } catch (e) {
      if (!mounted) return;
      _snack('导出失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ---------------- UI ----------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bgElevated,
        title: const Text('库房减货',
            style: TextStyle(color: AppColors.text, fontSize: 17)),
        actions: [
          IconButton(
            key: const Key('deduct-history'),
            tooltip: '历史减货单',
            icon: const Icon(Icons.history, color: AppColors.textSub),
            onPressed: _busy ? null : _pickSheet,
          ),
          IconButton(
            key: const Key('deduct-export'),
            tooltip: '导出 CSV',
            icon: const Icon(Icons.ios_share, color: AppColors.textSub),
            onPressed: _busy ? null : _export,
          ),
          PopupMenuButton<String>(
            key: const Key('deduct-menu'),
            icon: const Icon(Icons.more_vert, color: AppColors.textSub),
            onSelected: (v) {
              switch (v) {
                case 'submit':
                  _submit();
                  break;
                case 'new':
                  _newSheet();
                  break;
                case 'reopen':
                  _reopen();
                  break;
                case 'clear':
                  _clearAll();
                  break;
              }
            },
            itemBuilder: (_) => <PopupMenuEntry<String>>[
              PopupMenuItem<String>(
                value: 'submit',
                enabled: _editable,
                child: const Text('提交这一单'),
              ),
              // 「开新单」只在锁死后才给点：还没交就另起一张，上一张会变成
              // 谁也翻不到的"孤儿进行中单"，而库里同时还留着两张进行中的单。
              PopupMenuItem<String>(
                value: 'new',
                enabled: !_editable,
                child: const Text('开新单'),
              ),
              PopupMenuItem<String>(
                value: 'reopen',
                enabled: !_editable,
                child: const Text('撤销提交'),
              ),
              const PopupMenuItem<String>(
                value: 'clear',
                child: Text('清除本机全部减货数据'),
              ),
            ],
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                if (_error != null)
                  Container(
                    width: double.infinity,
                    color: AppColors.danger.withValues(alpha: 0.15),
                    padding: const EdgeInsets.all(12),
                    child: Text(_error!,
                        style: const TextStyle(
                            color: AppColors.danger, fontSize: 13)),
                  ),
                _header(),
                _inputBar(),
                const Divider(height: 1, color: AppColors.divider),
                // 🔴 表头**空列表也要画**：不画的话没扫过码的人整页看不到列名，
                //    现场只会得出"这页没有这个功能"的结论。
                //    （这条在扫码枪上真的踩过，见方案文档 §3.0.1。）
                _listHeader(),
                Expanded(
                  child: _rows.isEmpty
                      ? const Center(
                          child: Text('还没有减货记录，扫一个条码开始',
                              style: TextStyle(
                                  color: AppColors.textWeak, fontSize: 14)),
                        )
                      : ListView.separated(
                          itemCount: _rows.length,
                          separatorBuilder: (_, __) =>
                              const Divider(height: 1, color: AppColors.divider),
                          itemBuilder: (_, i) => _rowTile(_rows[i]),
                        ),
                ),
              ],
            ),
    );
  }

  Widget _header() {
    final status = (_sheet?['status'] as num? ?? 0).toInt();
    return Container(
      width: double.infinity,
      color: AppColors.bgElevated,
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(_sheetNo,
                    key: const Key('deduct-sheet-no'),
                    style: const TextStyle(
                        color: AppColors.text,
                        fontSize: 14,
                        fontWeight: FontWeight.w600)),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: (status == InvSheetStatus.open
                          ? AppColors.brand
                          : AppColors.textSub)
                      .withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  InvSheetStatus.label(status),
                  key: const Key('deduct-sheet-status'),
                  style: TextStyle(
                      fontSize: 12,
                      color: status == InvSheetStatus.open
                          ? AppColors.brand
                          : AppColors.textSub),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(DeductExport.summaryText(_tally),
              key: const Key('deduct-summary'),
              style: const TextStyle(color: AppColors.textSub, fontSize: 13)),
          // 锁死之后输入框是灰的，但不写一句话员工只会以为"手机卡了"。
          if (!_editable && !_loading)
            const Padding(
              padding: EdgeInsets.only(top: 2),
              child: Text('这一单已提交，不能再改（右上角菜单可撤销提交或开新单）',
                  key: Key('deduct-locked-hint'),
                  style: TextStyle(color: AppColors.textWeak, fontSize: 12)),
            ),
        ],
      ),
    );
  }

  Widget _inputBar() {
    return Container(
      color: AppColors.bgElevated,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: TextField(
              key: const Key('deduct-barcode-input'),
              controller: _scanCtl,
              focusNode: _scanFocus,
              enabled: _editable,
              autofocus: true,
              textInputAction: TextInputAction.next,
              style: const TextStyle(color: AppColors.text, fontSize: 15),
              decoration: const InputDecoration(
                labelText: '条码',
                isDense: true,
                labelStyle: TextStyle(color: AppColors.textWeak, fontSize: 13),
              ),
              onSubmitted: (_) => _addRow(),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 76,
            child: TextField(
              key: const Key('deduct-qty-field'),
              controller: _qtyCtl,
              enabled: _editable,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              style: const TextStyle(color: AppColors.text, fontSize: 15),
              decoration: const InputDecoration(
                labelText: '数量',
                isDense: true,
                labelStyle: TextStyle(color: AppColors.textWeak, fontSize: 13),
              ),
              onSubmitted: (_) => _addRow(),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton(
            key: const Key('deduct-add'),
            onPressed: (_editable && !_busy) ? _addRow : null,
            style: FilledButton.styleFrom(backgroundColor: AppColors.brand),
            child: const Text('确定减货'),
          ),
        ],
      ),
    );
  }

  Widget _listHeader() {
    const style = TextStyle(color: AppColors.textWeak, fontSize: 12);
    return Container(
      color: AppColors.bgElevated,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      child: const Row(
        children: [
          // 每列带 key：列名和输入框的 label 会重名（"条码"两处都有），
          // 测试用文字找会一次命中两个，"到底画没画列头"就说不清了。
          Expanded(
              flex: 4,
              child: Text('条码',
                  key: Key('deduct-col-barcode'), style: style)),
          Expanded(
              flex: 3,
              child: Text('商品',
                  key: Key('deduct-col-name'), style: style)),
          SizedBox(
              width: 72,
              child: Text('数量', key: Key('deduct-col-qty'), style: style)),
          SizedBox(
              width: 56,
              child: Text('操作', key: Key('deduct-col-op'), style: style)),
        ],
      ),
    );
  }

  Widget _rowTile(Map<String, dynamic> r) {
    return Container(
      // 行 key：测试要按**行数**断言（"被拒的扫码一行都没多写"）。
      // 靠条码文字找不准 —— 输入框里也可能有同一个条码。
      key: Key('deduct-row-${r['id']}'),
      color: AppColors.bg,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        children: [
          Expanded(
            flex: 4,
            child: Text((r['barcode'] ?? '').toString(),
                style: const TextStyle(color: AppColors.text, fontSize: 13)),
          ),
          Expanded(
            flex: 3,
            child: Text(
              ((r['name'] ?? '').toString().trim().isEmpty
                  ? '未知条码'
                  : r['name'].toString()),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: AppColors.textSub, fontSize: 13),
            ),
          ),
          SizedBox(
            width: 72,
            child: InkWell(
              onTap: _editable ? () => _editQty(r) : null,
              child: Text(
                DeductExport.fmtQty(r['qty']),
                style: TextStyle(
                    color: _editable ? AppColors.brand : AppColors.text,
                    fontSize: 14,
                    fontWeight: FontWeight.w600),
              ),
            ),
          ),
          SizedBox(
            width: 56,
            child: IconButton(
              tooltip: '删除这一行',
              iconSize: 18,
              icon: const Icon(Icons.close, color: AppColors.danger),
              onPressed: _editable ? () => _deleteRow(r) : null,
            ),
          ),
        ],
      ),
    );
  }
}
