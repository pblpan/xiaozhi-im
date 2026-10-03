import 'dart:io';

import 'package:flutter/material.dart';

import '../core/app_params.dart';
import '../core/file_io.dart';
import '../core/inventory_rules.dart';
import '../core/scale_code.dart';
import '../core/replenish_export.dart';
import '../core/replenish_repo.dart';
import '../core/replenish_rules.dart';
import '../core/theme.dart';
import '../screens/camera_scan.dart';
import '../core/scan_sink.dart';
import '../widgets/export_flow.dart';

/// 补货：把货补到货架上的作业单（生鲜 / 杂百分开）。
///
/// ── 和「库房减货」的区别 ──────────────────────────────────
/// 减货是**出库**（从库房减掉），补货是**上架**（补到货架）。方向相反，
/// 所以是两张单、两个 sheet_type —— 合在一起对账时符号会打架。
///
/// ── 单位（龙哥 2026-09-25 定，只有两套，不做第三套）─────────
///   生鲜（称重）→ **公斤**；杂百（非称重）→ **最小单位**（件 / 个 / 瓶）。
///   另外给一列「转换公斤」：把最小单位折成公斤，供对账/物流口径用。
///   折算率从商档的**规格**里解析（`500g` / `1.25kg` / `2斤`），
///   解析不出就留空 —— 绝不猜一个 1 出来（猜了会让公斤合计变得毫无意义，
///   而且完全看不出来）。
class ReplenishPage extends StatefulWidget {
  const ReplenishPage({super.key, this.repo});

  /// 测试注入点。
  final ReplenishRepo? repo;

  @override
  State<ReplenishPage> createState() => _ReplenishPageState();
}

class _ReplenishPageState extends State<ReplenishPage> {
  late ReplenishRepo _repo;

  final TextEditingController _scanCtl = TextEditingController();
  final TextEditingController _qtyCtl = TextEditingController(text: '1');
  final FocusNode _scanFocus = FocusNode();

  Map<String, dynamic>? _sheet;
  List<Map<String, dynamic>> _rows = const <Map<String, dynamic>>[];
  ReplenishTally _tally = const ReplenishTally(
      kinds: 0, totalQty: 0, totalKg: 0, unknownWeight: 0);
  bool _loading = true;
  bool _busy = false;
  String? _error;

  String _scene = ReplenishScene.dry;

  /// 🔴 认住当前那张单的单号（与减货同一个坑：提交后会开新单，
  ///    每次刷新去"取进行中的那张"会让刚提交的单凭空消失）。
  String? _curNo;

  @override
  void initState() {
    super.initState();
    _repo = widget.repo ?? ReplenishRepo();
    // 拉一次管理台配的参数（电子秤码的商品码位数）。不等它：
    // 弱网时等它会让进页面卡住，而拿不到只是回到默认 5 位。
    AppParams.I.refresh();
    _reload();
  }

  @override
  void dispose() {
    _scanCtl.dispose();
    _qtyCtl.dispose();
    _scanFocus.dispose();
    super.dispose();
  }

  static int _intOf(Object? v) {
    if (v == null) return 0;
    if (v is num) return v.toInt();
    return int.tryParse(v.toString()) ?? 0;
  }

  bool get _editable =>
      _sheet != null &&
      InvSheetStatus.editable(_intOf(_sheet!['status']));

  String get _sheetNo => _curNo ?? '';

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _reload({bool forceNew = false, String? loadNo}) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      Map<String, dynamic>? s;
      if (loadNo != null) s = await _repo.findSheet(loadNo);
      s ??= await _repo.openSheet(_scene);
      s ??= await _repo.openOrCreate(scene: _scene, forceNew: forceNew);

      final no = (s['sheet_no'] ?? '').toString();
      final rows = await _repo.listRows(no);
      final t = await _repo.summary(no, _scene);
      if (!mounted) return;
      setState(() {
        _sheet = s;
        _curNo = no;
        _rows = rows;
        _tally = t;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '打开补货单失败：$e';
        _loading = false;
      });
    }
  }

  Future<void> _switchScene(String scene) async {
    if (scene == _scene) return;
    setState(() => _scene = scene);
    await _reload();
    if (!mounted) return;
    _snack('切到「${ReplenishScene.label(scene)}」，数量按'
        '${ReplenishUnit.label(ReplenishUnit.ofScene(scene))}记');
  }

  Future<void> _addRow() async {
    final input = _scanCtl.text.trim();
    if (input.isEmpty) {
      _snack('先扫一个条码');
      return;
    }

    // 电子秤码（生鲜称重码）：条码里**编着重量**，不必再手输数量。
    // 只在生鲜场景解 —— 杂百区扫到的 13 位数字是普通商品码，
    // 拿秤码的规则去解它会解出一个不存在的商品，还不报错。
    var barcode = input;
    double? scaleKg;
    if (_scene == ReplenishScene.fresh) {
      final info =
          ScaleCode.parse(input, codeLen: AppParams.I.scaleCodeLen);
      if (info != null) {
        barcode = info.plu; // 商档里存的是 PLU（秤上的商品号），不是整串秤码
        scaleKg = info.kg;
      }
    }

    setState(() => _busy = true);
    try {
      final d = await _repo.addRow(
        sheetNo: _sheetNo,
        barcode: barcode,
        qtyRaw: scaleKg != null ? scaleKg.toString() : _qtyCtl.text,
      );
      if (!mounted) return;
      if (!d.accepted) {
        _snack(d.message ?? '这一笔没能记上');
        return;
      }
      _scanCtl.clear();
      _qtyCtl.text = '1';
      await _reload();
      if (!mounted) return;
      // 秤码要**明说**解出了什么：默默用秤上的重量顶掉手输数量，
      // 员工会以为是数量填错了（而这个数其实比手填的准）。
      if (scaleKg != null) {
        _snack('秤码 $input → 商品码 $barcode，${scaleKg.toStringAsFixed(3)} 公斤');
      }
      _focusScan();
    } catch (e) {
      if (!mounted) return;
      _snack('录入失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _focusScan() {
    FocusScope.of(context).requestFocus(_scanFocus);
  }

  /// 打开扫码枪那套相机界面（龙哥 2026-10-03 要的"带扫码窗口"）。
  ///
  /// 扫到的码由 [ReplenishSink] 直接落进当前补货单 —— 生鲜扫秤码自动取重量，
  /// 普通商品在确认卡上填数量。从相机回来刷新列表。
  Future<void> _openCamera() async {
    if (!cameraScanSupported) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => CameraScanPage(
          title: '补货扫码',
          sheetNo: _sheetNo,
          hint: '扫商品条码补货（生鲜扫秤码自动取重量）',
          sink: ReplenishSink(_repo, _scene),
        ),
      ),
    );
    if (!mounted) return;
    await _reload();
  }

  Future<void> _deleteRow(Map<String, dynamic> r) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.bgElevated,
        title: const Text('删掉这一行？',
            style: TextStyle(color: AppColors.text, fontSize: 16)),
        content: Text('${r['barcode']}\n删掉后可以重新扫这个条码。',
            style: const TextStyle(color: AppColors.textSub, fontSize: 14)),
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
      await _repo.deleteRow(_intOf(r['id']));
      await _reload();
    } catch (e) {
      _snack('删除失败：$e');
    }
  }

  Future<void> _editQty(Map<String, dynamic> r) async {
    final ctl = TextEditingController(
        text: ReplenishExport.fmtQty(r['qty']));
    final unit = ReplenishUnit.label(ReplenishUnit.ofScene(_scene));
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.bgElevated,
        title: const Text('改数量',
            style: TextStyle(color: AppColors.text, fontSize: 16)),
        content: TextField(
          controller: ctl,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          style: const TextStyle(color: AppColors.text, fontSize: 15),
          decoration: InputDecoration(
            labelText: '数量（$unit）',
            labelStyle:
                const TextStyle(color: AppColors.textWeak, fontSize: 13),
          ),
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
    if (ok != true) return;
    final err = ReplenishRules.qtyError(ctl.text);
    if (err != null) {
      _snack(err);
      return;
    }
    try {
      await _repo.setQty(_intOf(r['id']), ReplenishRules.parseQty(ctl.text)!);
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
    setState(() => _busy = true);
    try {
      await _repo.submitSheet(_sheetNo);
      await _reload(loadNo: _sheetNo);
      if (!mounted) return;
      _snack('已提交：$_sheetNo');
    } catch (e) {
      if (!mounted) return;
      _snack('提交失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reopen() async {
    setState(() => _busy = true);
    try {
      await _repo.reopenSheet(_sheetNo);
      await _reload(loadNo: _sheetNo);
      if (!mounted) return;
      _snack('已撤销提交，可以继续改');
    } catch (e) {
      if (!mounted) return;
      _snack('撤销失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _newSheet() async {
    setState(() => _busy = true);
    try {
      final s = await _repo.openOrCreate(scene: _scene, forceNew: true);
      await _reload(loadNo: (s['sheet_no'] ?? '').toString());
      if (!mounted) return;
      _snack('已开新单：${s['sheet_no']}');
    } catch (e) {
      if (!mounted) return;
      _snack('开新单失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _clearAll() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.bgElevated,
        title: const Text('清除本机全部补货数据？',
            style: TextStyle(color: AppColors.text, fontSize: 16)),
        content: const Text(
          '会删掉本机**所有**补货单和明细（生鲜 + 杂百）。\n'
          '盘点单、减货单、简易盘点**一个字节都不会动**。',
          style: TextStyle(color: AppColors.textSub, fontSize: 14),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('清除',
                  style: TextStyle(
                      color: AppColors.danger, fontWeight: FontWeight.w600))),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      final r = await _repo.clearAll();
      await _reload(forceNew: true);
      if (!mounted) return;
      _snack('已清除 ${r['sheets']} 张单、${r['rows']} 行明细');
    } catch (e) {
      if (!mounted) return;
      _snack('清除失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickSheet() async {
    final briefs = await _repo.sheetBriefs();
    if (!mounted) return;
    final no = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppColors.bgElevated,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: briefs.isEmpty
              ? [
                  const Padding(
                    padding: EdgeInsets.all(20),
                    child: Text('还没有历史补货单',
                        style: TextStyle(color: AppColors.textWeak)),
                  )
                ]
              : briefs
                  .map((s) => ListTile(
                        title: Text((s['sheet_no'] ?? '').toString(),
                            style: const TextStyle(
                                color: AppColors.text, fontSize: 13)),
                        subtitle: Text(
                          '${ReplenishScene.label((s['scene'] ?? '').toString())}'
                          ' · ${s['rows']} 行 · 合计 ${s['total_qty']}',
                          style: const TextStyle(
                              color: AppColors.textSub, fontSize: 12),
                        ),
                        onTap: () =>
                            Navigator.pop(ctx, (s['sheet_no'] ?? '').toString()),
                      ))
                  .toList(),
        ),
      ),
    );
    if (no == null || !mounted) return;
    await _reload(loadNo: no);
  }

  Future<void> _export() async {
    if (_rows.isEmpty) {
      _snack('这一单还没有明细，先扫几条再导出');
      return;
    }
    setState(() => _busy = true);
    try {
      final name = FileIo.safeName(ReplenishExport.csvName(_sheetNo));
      final dir = await FileIo.dir();
      final f = File('${dir.path}${Platform.pathSeparator}$name');
      await f.writeAsString(
          ReplenishExport.toCsv(_rows, scene: _scene));
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
    final status = _intOf(_sheet?['status']);
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bgElevated,
        title: const Text('补货',
            style: TextStyle(color: AppColors.text, fontSize: 17)),
        actions: [
          IconButton(
            key: const Key('replenish-history'),
            tooltip: '历史补货单',
            icon: const Icon(Icons.history, color: AppColors.textSub),
            onPressed: _busy ? null : _pickSheet,
          ),
          IconButton(
            key: const Key('replenish-export'),
            tooltip: '导出 CSV',
            icon: const Icon(Icons.ios_share, color: AppColors.textSub),
            onPressed: _busy ? null : _export,
          ),
          PopupMenuButton<String>(
            key: const Key('replenish-menu'),
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
                child: Text('清除本机全部补货数据'),
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
                _sceneBar(),
                _header(status),
                _inputBar(),
                const Divider(height: 1, color: AppColors.divider),
                _listHeader(),
                Expanded(
                  child: _rows.isEmpty
                      ? const Center(
                          child: Text('还没有补货记录，扫一个条码开始',
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

  /// 场景切换（生鲜 / 杂百）。放在最上面而不是菜单里：
  /// 单位口径由它决定，藏起来的话员工根本不知道自己这一笔是按公斤还是按件记的。
  Widget _sceneBar() {
    return Container(
      width: double.infinity,
      color: AppColors.bgElevated,
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
      child: Row(
        children: [
          const Text('场景',
              style: TextStyle(color: AppColors.textWeak, fontSize: 12)),
          const SizedBox(width: 10),
          Expanded(
            child: SegmentedButton<String>(
              key: const Key('replenish-scene'),
              segments: const <ButtonSegment<String>>[
                ButtonSegment<String>(
                    value: ReplenishScene.dry, label: Text('杂百（按件/个）')),
                ButtonSegment<String>(
                    value: ReplenishScene.fresh, label: Text('生鲜（按公斤）')),
              ],
              selected: <String>{_scene},
              onSelectionChanged: _busy
                  ? null
                  : (s) {
                      if (s.isNotEmpty) _switchScene(s.first);
                    },
              style: SegmentedButton.styleFrom(
                foregroundColor: AppColors.text,
                selectedForegroundColor: AppColors.bg,
                selectedBackgroundColor: AppColors.brand,
                textStyle: const TextStyle(fontSize: 12),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _header(int status) {
    return Container(
      width: double.infinity,
      color: AppColors.bgElevated,
      padding: const EdgeInsets.fromLTRB(14, 4, 14, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(_sheetNo,
                    key: const Key('replenish-sheet-no'),
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
                  key: const Key('replenish-sheet-status'),
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
          Text(ReplenishExport.summaryText(_tally, _scene),
              key: const Key('replenish-summary'),
              style: const TextStyle(color: AppColors.textSub, fontSize: 13)),
          // 「每分钟补货」是 PG 那版有的效率列。不到 1 分钟不给数 ——
          // 拿 20 秒去除会得到虚高的数，而它会被当成"这人补得真快"看。
          if (_rows.isNotEmpty && _sheet != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(_speedText(),
                  key: const Key('replenish-speed'),
                  style: const TextStyle(
                      color: AppColors.textWeak, fontSize: 12)),
            ),
          if (!_editable && !_loading)
            const Padding(
              padding: EdgeInsets.only(top: 2),
              child: Text('这一单已提交，不能再改（右上角菜单可撤销提交或开新单）',
                  key: Key('replenish-locked-hint'),
                  style: TextStyle(color: AppColors.textWeak, fontSize: 12)),
            ),
        ],
      ),
    );
  }

  String _speedText() {
    final started = _intOf(_sheet?['started_at']);
    if (started <= 0) return '';
    final elapsed = DateTime.now().millisecondsSinceEpoch - started;
    final perMin = _tally.perMinute(elapsed);
    final unit = ReplenishUnit.label(ReplenishUnit.ofScene(_scene));
    if (perMin == null) return '每分钟补货：还不到 1 分钟，先不给数';
    return '每分钟补货 ${perMin.toStringAsFixed(1)} $unit';
  }

  Widget _inputBar() {
    final unit = ReplenishUnit.label(ReplenishUnit.ofScene(_scene));
    return Container(
      color: AppColors.bgElevated,
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      child: Row(
        children: [
          // 手机端把「扫码」放最左、给足面积 —— 龙哥 2026-10-03 明确要
          // 补货也走扫码枪那套相机界面（带扫码窗口、带确认制数量输入），
          // 不再只靠手输条码。桌面端（摄像头不支持）自动隐藏，退回手输兜底。
          if (cameraScanSupported) ...[
            Material(
              color: AppColors.brand.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(AppRadii.sm),
              child: InkWell(
                borderRadius: BorderRadius.circular(AppRadii.sm),
                onTap: (_editable && !_busy) ? _openCamera : null,
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
            flex: 3,
            child: TextField(
              key: const Key('replenish-barcode-input'),
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
            width: 84,
            child: TextField(
              key: const Key('replenish-qty-field'),
              controller: _qtyCtl,
              enabled: _editable,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              style: const TextStyle(color: AppColors.text, fontSize: 15),
              decoration: InputDecoration(
                labelText: '数量($unit)',
                isDense: true,
                labelStyle:
                    const TextStyle(color: AppColors.textWeak, fontSize: 12),
              ),
              onSubmitted: (_) => _addRow(),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton(
            key: const Key('replenish-add'),
            onPressed: (_editable && !_busy) ? _addRow : null,
            style: FilledButton.styleFrom(backgroundColor: AppColors.brand),
            child: const Text('确定补货'),
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
          Expanded(
              flex: 4,
              child: Text('条码',
                  key: Key('replenish-col-barcode'), style: style)),
          Expanded(
              flex: 3,
              child: Text('商品',
                  key: Key('replenish-col-name'), style: style)),
          SizedBox(
              width: 66,
              child: Text('数量', key: Key('replenish-col-qty'), style: style)),
          SizedBox(
              width: 62,
              child: Text('公斤', key: Key('replenish-col-kg'), style: style)),
          SizedBox(
              width: 48,
              child: Text('操作', key: Key('replenish-col-op'), style: style)),
        ],
      ),
    );
  }

  Widget _rowTile(Map<String, dynamic> r) {
    final qty = (r['qty'] as num? ?? 0).toDouble();
    final isKg = ReplenishUnit.ofScene(_scene) == ReplenishUnit.kg;
    final kg = isKg
        ? qty
        : (ReplenishRules.specWeightKg((r['spec'] ?? '').toString()) == null
            ? null
            : qty * ReplenishRules.specWeightKg((r['spec'] ?? '').toString())!);
    return Container(
      key: Key('replenish-row-${r['id']}'),
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
            width: 66,
            child: InkWell(
              onTap: _editable ? () => _editQty(r) : null,
              child: Text(
                ReplenishExport.fmtQty(qty),
                style: TextStyle(
                    color: _editable ? AppColors.brand : AppColors.text,
                    fontSize: 14,
                    fontWeight: FontWeight.w600),
              ),
            ),
          ),
          // 折不出公斤的**留空**而不是填 0：填 0 会让人以为"这件货没有重量"。
          SizedBox(
            width: 62,
            child: Text(kg == null ? '—' : kg.toStringAsFixed(3),
                key: Key('replenish-row-kg-${r['id']}'),
                style: const TextStyle(color: AppColors.textSub, fontSize: 12)),
          ),
          SizedBox(
            width: 48,
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

/// 补货的扫码适配：把相机页扫到的码接到 [ReplenishRepo]。
///
/// 与扫码枪 / 盘点共用同一套相机机制（确认制、写入闸门、闪绿反馈，见
/// [CameraScanPage]）。这一层只负责"码 → 补货行"：
///   · 生鲜场景的**秤码**里编着重量，解出重量当数量（不用卡上的数量）；
///   · 普通商品用确认卡上填的数量落库。
class ReplenishSink implements ScanSink {
  ReplenishSink(this.repo, this.scene);

  final ReplenishRepo repo;

  /// 补货场景（生鲜 / 杂百），决定单位口径与是否解秤码。
  final String scene;

  @override
  Future<ScanFeedback> record(String sheetNo, String code, {double qty = 1}) async {
    // 秤码（生鲜称重）：条码里编着重量，不必用卡上的数量。
    var barcode = code;
    double? scaleKg;
    if (scene == ReplenishScene.fresh) {
      final info = ScaleCode.parse(code, codeLen: AppParams.I.scaleCodeLen);
      if (info != null) {
        // 商档里存的是 PLU（秤上的商品号），不是整串秤码。
        barcode = info.plu;
        scaleKg = info.kg;
      }
    }
    final d = await repo.addRow(
      sheetNo: sheetNo,
      barcode: barcode,
      qtyRaw: scaleKg != null ? scaleKg.toString() : qty.toString(),
    );
    if (!d.accepted) {
      return ScanFeedback(accepted: false, message: d.message);
    }
    final rows = await repo.listRows(sheetNo);
    final hit = rows.cast<Map<String, dynamic>?>().firstWhere(
          (r) => r != null && r['barcode'] == barcode,
          orElse: () => null,
        );
    return ScanFeedback(
      accepted: true,
      // 秤码要**明说**解出了多少公斤，免得员工以为是数量填错了。
      message: scaleKg != null ? '秤码 → ${scaleKg.toStringAsFixed(3)} 公斤' : null,
      hit: hit ?? <String, dynamic>{'barcode': barcode, 'qty': qty},
    );
  }

  @override
  Future<Map<String, dynamic>> summary(String sheetNo) async {
    final t = await repo.summary(sheetNo, scene);
    return <String, dynamic>{'total_qty': t.totalQty, 'kinds': t.kinds};
  }

  @override
  Future<List<Map<String, dynamic>>> recent(String sheetNo, {int limit = 40}) async {
    final rows = await repo.listRows(sheetNo);
    return rows.take(limit).toList();
  }
}
