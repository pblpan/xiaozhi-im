import 'dart:io';

import 'package:flutter/material.dart';

import '../core/file_io.dart';
import '../core/inventory_export.dart';
import '../core/inventory_repo.dart';
import '../core/inventory_rules.dart';
import '../core/theme.dart';
import '../widgets/export_flow.dart';
import '../widgets/qty_edit.dart';
import 'inventory_scan.dart';

/// 盘点采集页：**一个点位 × 一个阶段**地扫。
///
/// ── 这一页和「扫码枪」差在哪 ────────────────────────────────────
/// 扫码枪只有一个状态："扫了什么、多少件"。
/// 盘点多两个维度，界面必须让人一眼看见，否则数据就串了：
///   · **阶段**（初盘 / 复盘 / 抽盘）—— 顶部三段，每段底色不同；
///   · **货架位** —— 每件商品"是在哪儿数出来的"。
/// 这两个维度是盘点的全部意义所在。少了阶段，复盘和初盘分不清；
/// 少了货架位，差异出来以后没人知道该去哪个货架找。
///
/// ── 阶段切换为什么要二次确认 ────────────────────────────────────
/// 不是怕误触，是怕**串阶段**：员工以为还在初盘、其实已经切到复盘，
/// 一枪扫下去，这笔就记进了复盘单 —— 而复盘只收差异商品，
/// 于是"扫了没反应"。那种困惑在货架中间是解释不清的。
///
/// ── 离线 ──────────────────────────────────────────────────────
/// 这一页一次网络请求都不发（商档同步是另一个入口）。
/// 服务端只在"上传"那一步介入，M1 还不含上传。
class InventoryCollectPage extends StatefulWidget {
  const InventoryCollectPage({
    super.key,
    required this.zoneCode,
    required this.zoneName,
  });

  final String zoneCode;
  final String zoneName;

  @override
  State<InventoryCollectPage> createState() => _InventoryCollectPageState();
}

class _InventoryCollectPageState extends State<InventoryCollectPage> {
  final InventoryRepo _repo = InventoryRepo();
  final TextEditingController _input = TextEditingController();
  final FocusNode _focus = FocusNode();

  bool _loading = true;
  bool _busy = false;
  bool _exporting = false;

  /// 正在把某个阶段的数据读进界面。
  ///
  /// 🔴 必须与 [_phase] 一起切：`_phase` 一改，界面上的阶段条、提醒语、
  ///    单号都立刻变成新阶段的，但 `_rows` 还是上一次查出来的旧数据 ——
  ///    中间那一帧会**把上一个阶段的商品显示在新的阶段标题下**。
  ///    员工瞥一眼正好看到它，就会以为"复盘里已经有这些了"。
  ///    所以切阶段时先把列表清空、挂个转圈，等数据到了再一起显示。
  bool _phaseLoading = false;

  String? _error;

  /// 当前阶段。默认初盘 —— 盘点总是从全量扫一遍开始。
  int _phase = InvPhase.first;

  /// 当前阶段的单。没扫之前可能为 null（还没开单）。
  Map<String, dynamic>? _sheet;

  List<Map<String, dynamic>> _rows = const [];
  Map<String, dynamic> _sum = const {};
  List<Map<String, dynamic>> _progress = const [];
  List<Map<String, dynamic>> _locs = const [];

  /// 当前选中的货架位。扫到没绑过货架位的商品就记在它名下。
  String? _locCode;

  /// 当前阶段的**上一阶段差异集**（复盘只收这些商品）。
  Set<String> _diffSet = const {};

  bool get _editable =>
      _sheet == null ||
      InvSheetStatus.editable((_sheet!['status'] as num).toInt());

  List<Map<String, dynamic>> get _diffRows =>
      _rows.where(InventoryRules.isDiffRow).toList();

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

  /// 每个阶段的底色。三个阶段必须**一眼可分** ——
  /// 颜色一样的话，员工只能靠读字确认自己在哪个阶段，会读错的。
  static Color phaseColor(int phase) {
    switch (phase) {
      case InvPhase.first:
        return AppColors.brand;
      case InvPhase.second:
        return AppColors.warn;
      default:
        return AppColors.brand2;
    }
  }

  // ============================================================
  // 载入
  // ============================================================

  Future<void> _boot() async {
    try {
      final locs = await _repo.listLocations(widget.zoneCode);
      if (!mounted) return;
      setState(() {
        _locs = locs;
        if (_locCode == null && locs.isNotEmpty) {
          _locCode = locs.first['loc_code'] as String?;
        }
      });
      await _enterPhase(InvPhase.first, firstTime: true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '读取本地数据失败：$e';
      });
    }
  }

  /// 切到某个阶段：开单（已开的直接复用）并载入该阶段的数据。
  ///
  /// [firstTime] 只影响"是否弹继续盘点提示" —— 首次进入自动落到初盘，
  /// 不该给用户弹一个他自己没点的确认框。
  Future<void> _enterPhase(int phase, {bool firstTime = false}) async {
    setState(() => _busy = true);
    try {
      final existBefore = await _repo.openSheetOf(widget.zoneCode, phase);
      final sheet =
          await _repo.openSheet(zoneCode: widget.zoneCode, phase: phase);
      if (!mounted) return;
      setState(() {
        _phase = phase;
        _sheet = sheet;
        _error = null;
        // 先清空 + 转圈，避免"新阶段的标题 + 上一个阶段的行"这种串台画面
        _phaseLoading = true;
        _rows = const [];
        _sum = const {};
        _diffSet = const {};
      });
      await _refreshAll();
      if (!mounted) return;
      // "您在该盘点位有未完成数据，是否继续盘点？"—— 这里不弹框，
      // 因为**默认就是继续**（数据一条没丢，就在下面列表里）。
      // 弹一次反而会让人以为"不点继续就会丢"。
      if (!firstTime && existBefore != null) {
        final n = (_sum['kinds'] as num? ?? 0).toInt();
        if (n > 0) _snack('接着上次的${InvPhase.label(phase)}盘（已有 $n 种）');
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = _msgOf(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _refreshAll() async {
    final no = (_sheet?['sheet_no'] ?? '').toString();
    final sheet = no.isEmpty ? null : await _repo.findSheet(no);
    final rows = no.isEmpty
        ? const <Map<String, dynamic>>[]
        : await _repo.listRows(no);
    final sum =
        no.isEmpty ? const <String, dynamic>{} : await _repo.summary(no);
    final progress = await _repo.phaseProgress(widget.zoneCode);
    final prev = InvPhase.prev(_phase);
    final diff = prev == null
        ? const <String>{}
        : await _repo.diffBarcodes(widget.zoneCode, prev);
    if (!mounted) return;
    setState(() {
      if (sheet != null) _sheet = sheet;
      _rows = rows;
      _sum = sum;
      _progress = progress;
      _diffSet = diff;
      _loading = false;
      _phaseLoading = false;
    });
  }

  // ============================================================
  // 扫码
  // ============================================================

  /// 扫码枪（HID 键盘）敲回车或摄像头回来，都走这里。
  Future<void> _handleCode(String raw) async {
    final code = raw.trim();
    _input.clear();
    if (code.isEmpty) return;

    // 🔴 **正在切换阶段时不能直接把这一枪丢掉。**
    //    现场的动作就是"点完『切到复盘』的确认，马上对着货架扫" ——
    //    此时开单/读库还没跑完。早先的写法在这里 `return`，那一枪就
    //    **静默消失**：界面上什么都不发生，员工以为扫上了，回头对账少一件。
    //    所以这里**等**（最多 2 秒）等它落定；真等不到也要明说没记上，
    //    绝不静默 —— 静默失败比慢两秒贵得多。
    for (var i = 0; i < 40 && _busy; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      if (!mounted) return;
    }
    if (_busy) {
      _snack('正在切换阶段，刚才那一枪**没有**记上，请再扫一次');
      return;
    }

    var sheet = _sheet;
    if (sheet == null) {
      await _enterPhase(_phase);
      sheet = _sheet;
      if (sheet == null) {
        _snack('开单失败，先解决上面那条报错再扫');
        return;
      }
    }
    if (!InvSheetStatus.editable((sheet['status'] as num).toInt())) {
      _snack('本单已提交，如需修改请先点「撤销提交」');
      return;
    }

    try {
      final r = await _repo.scanAuto(
        sheet['sheet_no'] as String,
        code,
        fallbackLocCode: _locCode,
      );
      if (!mounted) return;
      if (!r.accepted) {
        // 判定给的话原样转达，界面不另编一句（同一个错三种说法最让人困惑）。
        _snack(r.message ?? '这一笔没有记上');
        return;
      }
      // accepted 时还有话，只有"未绑定货架位"那一种 —— 要让人看见。
      if (r.message != null) _snack(r.message!);
      await _refreshAll();
    } catch (e) {
      if (!mounted) return;
      _snack('扫码失败：${_msgOf(e)}');
    }
  }

  // ============================================================
  // 阶段 / 提交
  // ============================================================

  Future<void> _switchPhase(int phase) async {
    if (phase == _phase || _busy) return;
    // 有一定数据就确认一下：串阶段是这一页最贵的错。
    if (_rows.isNotEmpty) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppColors.bgElevated,
          title: Text('切到${InvPhase.label(phase)}？',
              style: const TextStyle(color: AppColors.text, fontSize: 16)),
          content: Text(
            '当前是${InvPhase.label(_phase)}，已扫 ${_rows.length} 种。\n\n'
            '切换后扫进来的商品会记到**${InvPhase.label(phase)}**单里。\n'
            '${InvPhase.label(_phase)}的数据不会丢，随时可以切回去看。',
            style: const TextStyle(color: AppColors.textSub, fontSize: 13),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('不切')),
            TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text('切到${InvPhase.label(phase)}',
                    style: TextStyle(
                        color: phaseColor(phase),
                        fontWeight: FontWeight.w600))),
          ],
        ),
      );
      if (ok != true) return;
    }
    await _enterPhase(phase);
  }

  Future<void> _submit() async {
    final sheet = _sheet;
    if (sheet == null) {
      _snack('还没有开始盘点，先扫一件');
      return;
    }
    final no = sheet['sheet_no'] as String;
    final label = InvPhase.label(_phase);
    final nextP = InvPhase.next(_phase);
    final kinds = _rows.length;
    final diff = _diffRows.length;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.bgElevated,
        title: Text('提交$label',
            style: const TextStyle(color: AppColors.text, fontSize: 16)),
        content: Text(
          '本单 $no\n'
          '品种 $kinds 种，其中差异 $diff 种。\n\n'
          '提交后这张单**不能再改**（要改得先「撤销提交」）。\n'
          '${nextP == null ? '' : '差异集同时定格，${InvPhase.label(nextP)}就按它来盘。'}',
          style: const TextStyle(color: AppColors.textSub, fontSize: 13),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('再盘盘')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('提交',
                  style: TextStyle(
                      color: AppColors.brand, fontWeight: FontWeight.w600))),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    try {
      await _repo.submitSheet(no);
      await _refreshAll();
      if (!mounted) return;
      _snack('$label已提交（$kinds 种，差异 $diff 种）');
      if (nextP != null && diff > 0) {
        await _askNextPhase(nextP, diff);
      }
    } catch (e) {
      if (!mounted) return;
      _snack('提交失败：${_msgOf(e)}');
    }
  }

  /// 提交完问一句"现在去下一阶段吗"。
  ///
  /// 这一问是有必要的：盘点的三个阶段是连着做的，
  /// 让员工自己去点那个阶段条，十次里有三次会点错（点到旁边那格）。
  Future<void> _askNextPhase(int next, int diff) async {
    final label = InvPhase.label(next);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.bgElevated,
        title: Text('现在开始$label？',
            style: const TextStyle(color: AppColors.text, fontSize: 16)),
        content: Text(
          '这一轮有 $diff 个差异商品。\n'
          '$label只收这些差异商品 —— 其他商品扫了不会被记上。',
          style: const TextStyle(color: AppColors.textSub, fontSize: 13),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('待会儿')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text('开始$label',
                  style: TextStyle(
                      color: phaseColor(next), fontWeight: FontWeight.w600))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await _enterPhase(next);
  }

  Future<void> _reopen() async {
    final sheet = _sheet;
    if (sheet == null) return;
    final no = sheet['sheet_no'] as String;
    final label = InvPhase.label(_phase);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.bgElevated,
        title: Text('撤销提交$label？',
            style: const TextStyle(color: AppColors.text, fontSize: 16)),
        content: Text(
          '这张单（$no）会回到"可继续扫、可改数量"的状态。\n'
          '已经同步到服务端的数据不会因此撤销。',
          style: const TextStyle(color: AppColors.textSub, fontSize: 13),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('算了')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('撤销提交',
                  style: TextStyle(color: AppColors.danger))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await _repo.reopenSheet(no);
    await _refreshAll();
    if (!mounted) return;
    _snack('$label已回到可编辑');
  }

  // ============================================================
  // 货架位
  // ============================================================

  Future<void> _newLocation() async {
    final ctl = TextEditingController();
    final nameCtl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.bgElevated,
        title: const Text('新建货架位',
            style: TextStyle(color: AppColors.text, fontSize: 16)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              key: const Key('loc-code-input'),
              controller: ctl,
              autofocus: true,
              textCapitalization: TextCapitalization.characters,
              style: const TextStyle(color: AppColors.text, fontSize: 15),
              decoration: const InputDecoration(
                labelText: '货架位码（如 A01）',
                labelStyle:
                    TextStyle(color: AppColors.textWeak, fontSize: 13),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              key: const Key('loc-name-input'),
              controller: nameCtl,
              style: const TextStyle(color: AppColors.text, fontSize: 15),
              decoration: const InputDecoration(
                labelText: '名字（可留空）',
                labelStyle:
                    TextStyle(color: AppColors.textWeak, fontSize: 13),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('建好',
                  style: TextStyle(
                      color: AppColors.brand, fontWeight: FontWeight.w600))),
        ],
      ),
    );
    final code = ctl.text.trim();
    final nm = nameCtl.text.trim();
    ctl.dispose();
    nameCtl.dispose();
    if (ok != true || !mounted) return;
    if (code.isEmpty) {
      _snack('货架位码不能为空');
      return;
    }
    try {
      await _repo.saveLocation(
          locCode: code, zoneCode: widget.zoneCode, name: nm.isEmpty ? code : nm);
      final locs = await _repo.listLocations(widget.zoneCode);
      if (!mounted) return;
      setState(() {
        _locs = locs;
        _locCode = code;
      });
      _snack('已建货架位 $code，之后的商品默认记在它名下');
    } catch (e) {
      _snack('新建失败：${_msgOf(e)}');
    }
  }

  /// 把某行商品绑到当前货架位。
  ///
  /// 这是"货架位档案"的**唯一**建法：员工在货架前扫一遍该货架上的商品，
  /// 顺手绑一次，档案就这样一天天补齐。所以这个动作必须一步可达。
  Future<void> _bindToCurrentLoc(Map<String, dynamic> r) async {
    final lc = _locCode;
    if (lc == null || lc.isEmpty) {
      _snack('先在上面选一个货架位');
      return;
    }
    final bc = r['barcode'].toString();
    try {
      await _repo.bindBarcode(bc, lc);
      await _refreshAll();
      if (!mounted) return;
      _snack('已把 $bc 绑到货架位 $lc');
    } catch (e) {
      _snack('绑定失败：${_msgOf(e)}');
    }
  }

  // ============================================================
  // 行操作
  // ============================================================

  Future<void> _editQty(Map<String, dynamic> r) async {
    if (!_editable) {
      _snack('本单已提交，改数量前先「撤销提交」');
      return;
    }
    final cur = (r['qty'] as num?)?.toDouble() ?? 0;
    final v = await askQty(
      context,
      subtitle: '${InventoryExport.nameOf(r)}　${r['barcode']}',
      current: cur,
      confirmText: '确定把 ${r['barcode']} 这一行删掉？',
      onMessage: _snack,
    );
    if (v == null || !mounted) return;
    final id = r['id'] as int;
    if (v == 0) {
      await _repo.deleteRow(id);
    } else {
      await _repo.setQty(id, v);
    }
    await _refreshAll();
    if (!mounted) return;
    _snack(v == 0 ? '已删掉这一行' : '已改成 ${fmtQty(v)}');
  }

  Future<void> _rowMenu(Map<String, dynamic> r) async {
    final act = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppColors.bgElevated,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                title: Text(
                  '${InventoryExport.nameOf(r)}　${r['barcode']}',
                  style: const TextStyle(color: AppColors.text, fontSize: 13),
                ),
              ),
              if (_editable)
                ListTile(
                  key: const Key('row-menu-bind'),
                  leading: const Icon(Icons.link, color: AppColors.brand),
                  title: Text(
                      _locCode == null
                          ? '绑到货架位（先选一个货架位）'
                          : '绑到货架位 $_locCode',
                      style: const TextStyle(color: AppColors.text)),
                  onTap: () => Navigator.pop(ctx, 'bind'),
                ),
              ListTile(
                key: const Key('row-menu-where'),
                leading: const Icon(Icons.place_outlined,
                    color: AppColors.textSub),
                title: const Text('看它在哪些货架位',
                    style: TextStyle(color: AppColors.text)),
                onTap: () => Navigator.pop(ctx, 'where'),
              ),
              if (_editable)
                ListTile(
                  key: const Key('row-menu-delete'),
                  leading: const Icon(Icons.delete_outline,
                      color: AppColors.danger),
                  title: const Text('删掉这一行',
                      style: TextStyle(color: AppColors.danger)),
                  onTap: () => Navigator.pop(ctx, 'delete'),
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
    if (act == 'bind') {
      await _bindToCurrentLoc(r);
      return;
    }
    if (act == 'where') {
      await _showWhereBound(r['barcode'].toString());
      return;
    }
    if (act == 'delete') {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppColors.bgElevated,
          title: const Text('删掉这一行？',
              style: TextStyle(color: AppColors.text, fontSize: 16)),
          content: Text('${InventoryExport.nameOf(r)}　${r['barcode']}',
              style: const TextStyle(color: AppColors.textSub, fontSize: 13)),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消')),
            TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('删除',
                    style: TextStyle(color: AppColors.danger))),
          ],
        ),
      );
      if (ok != true || !mounted) return;
      await _repo.deleteRow(r['id'] as int);
      await _refreshAll();
      if (!mounted) return;
      _snack('已删掉这一行');
    }
  }

  Future<void> _showWhereBound(String barcode) async {
    final rows = await _repo.locationsOfBarcode(barcode);
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.bgElevated,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('$barcode 绑定的货架位',
                  style: const TextStyle(
                      color: AppColors.text,
                      fontSize: 15,
                      fontWeight: FontWeight.w600)),
              const SizedBox(height: 10),
              if (rows.isEmpty)
                const Text(
                  '一个都没绑。\n\n'
                  '这不影响盘：扫它照样能记，只是"记在哪儿"要靠你上面选的货架位。\n'
                  '在货架前把它绑一次，以后它就知道自己在哪儿了。',
                  style: TextStyle(
                      color: AppColors.textSub, fontSize: 13, height: 1.6),
                )
              else
                for (final r in rows)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(
                      children: [
                        const Icon(Icons.place,
                            size: 16, color: AppColors.brand),
                        const SizedBox(width: 6),
                        Text(
                          '${r['zone_code']} / ${r['loc_code']}'
                          '${(r['zone_name'] ?? '') == '' ? '' : '（${r['zone_name']}）'}',
                          style: const TextStyle(
                              color: AppColors.text, fontSize: 13),
                        ),
                      ],
                    ),
                  ),
            ],
          ),
        ),
      ),
    );
  }

  // ============================================================
  // 差异表 / 导出
  // ============================================================

  Future<void> _showDiffSheet() async {
    final phase = _phase;
    final rows = await _repo.phaseRows(widget.zoneCode, phase);
    final diffs = rows.where(InventoryRules.isDiffRow).toList();
    final mistakes = await _repo.mistakeCount(widget.zoneCode, phase);
    if (!mounted) return;

    var loss = 0.0;
    var gain = 0.0;
    var noAccount = 0;
    for (final r in diffs) {
      if (r['account_qty'] == null) {
        noAccount++;
        continue;
      }
      final a = InventoryExport.amtOf(r);
      if (a == null) continue;
      if (a < 0) {
        loss += -a;
      } else {
        gain += a;
      }
    }

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.bgElevated,
      isScrollControlled: true,
      builder: (ctx) => FractionallySizedBox(
        heightFactor: 0.84,
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
                child: Row(
                  children: [
                    Icon(Icons.rule,
                        size: 18, color: phaseColor(phase)),
                    const SizedBox(width: 8),
                    Text('${InvPhase.label(phase)}差异',
                        style: const TextStyle(
                            color: AppColors.text,
                            fontSize: 16,
                            fontWeight: FontWeight.w600)),
                    const Spacer(),
                    Text('盘点位 ${widget.zoneCode}',
                        style: const TextStyle(
                            color: AppColors.textWeak, fontSize: 11)),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _statChip('差异品种', '${diffs.length}'),
                    _statChip('盘亏', loss.toStringAsFixed(2),
                        color: AppColors.danger),
                    _statChip('盘盈', gain.toStringAsFixed(2),
                        color: AppColors.brand),
                    _statChip('账面缺失', '$noAccount',
                        color: noAccount > 0 ? AppColors.warn : null),
                    _statChip('失误笔数', '$mistakes',
                        color: mistakes > 0 ? AppColors.warn : null),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              const Divider(height: 1),
              Expanded(
                child: diffs.isEmpty
                    ? const Center(
                        child: Padding(
                          padding: EdgeInsets.all(28),
                          child: Text(
                            '这个阶段没有差异。\n\n'
                            '（差异 = 实盘跟账面不一致。一条都没有，说明盘得很准；'
                            '也可能是这一阶段还没扫。）',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                                color: AppColors.textWeak,
                                fontSize: 13,
                                height: 1.7),
                          ),
                        ),
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.only(top: 4, bottom: 12),
                        itemCount: diffs.length,
                        separatorBuilder: (_, __) =>
                            const Divider(height: 1, indent: 16),
                        itemBuilder: (_, i) => _diffTile(diffs[i], i + 1),
                      ),
              ),
              if (diffs.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 6, 16, 14),
                  child: Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          key: const Key('export-diff-csv'),
                          onPressed: () => _exportDiff(phase, asDoc: false),
                          icon: const Icon(Icons.table_chart_outlined,
                              size: 18),
                          label: const Text('导出表格'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: FilledButton.tonalIcon(
                          key: const Key('export-diff-doc'),
                          onPressed: () => _exportDiff(phase, asDoc: true),
                          icon: const Icon(Icons.description_outlined,
                              size: 18),
                          label: const Text('导出文档（发主管）'),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _diffTile(Map<String, dynamic> r, int idx) {
    final acc = r['account_qty'];
    final d = (r['diff_qty'] as num?)?.toDouble();
    final amt = InventoryExport.amtOf(r);
    // 盘亏红、盘盈绿？（这个项目里"涨红跌绿"是中国习惯，
    // 但盘亏≠涨。这里按"亏了要引起注意"给色：亏损用 danger。）
    final c = d == null
        ? AppColors.textWeak
        : (d < 0 ? AppColors.danger : AppColors.brand);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 24,
            child: Text('$idx',
                style: const TextStyle(
                    color: AppColors.textWeak, fontSize: 12)),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(InventoryExport.nameOf(r),
                    style: const TextStyle(
                        color: AppColors.text, fontSize: 14),
                    overflow: TextOverflow.ellipsis),
                const SizedBox(height: 3),
                Text(
                  '${r['barcode']}'
                  '　实盘 ${fmtQty(r['qty'])}'
                  '　账面 ${acc == null ? '（账上没这商品）' : fmtQty(acc)}',
                  style: const TextStyle(
                      color: AppColors.textWeak, fontSize: 11),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(d == null ? '—' : fmtQty(d),
                  style: TextStyle(
                      color: c, fontSize: 15, fontWeight: FontWeight.w600)),
              if (amt != null)
                Text(amt.toStringAsFixed(2),
                    style: TextStyle(color: c, fontSize: 11)),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _exportDiff(int phase, {required bool asDoc}) async {
    try {
      final rows = await _repo.phaseRows(widget.zoneCode, phase);
      final diffs = rows.where(InventoryRules.isDiffRow).toList();
      if (diffs.isEmpty) {
        _snack('${InvPhase.label(phase)}没有差异，不用导出');
        return;
      }
      final mistakes = await _repo.mistakeCount(widget.zoneCode, phase);
      final name = FileIo.safeName(asDoc
          ? InventoryExport.diffDocName(widget.zoneCode, phase)
          : InventoryExport.diffName(widget.zoneCode, phase));
      final text = asDoc
          ? InventoryExport.toDiffDoc(
              diffs,
              zoneName: widget.zoneName,
              phaseLabel: InvPhase.label(phase),
              mistakes: mistakes,
            )
          : InventoryExport.toDiffCsv(diffs);
      final dir = await FileIo.dir();
      final f = File('${dir.path}${Platform.pathSeparator}$name');
      await f.writeAsString(text); // UTF-8；CSV 的 BOM 由导出层负责
      if (!mounted) return;
      await ExportFlow.show(context, f,
          rows: diffs.length, suggestName: name, onMessage: _snack);
    } catch (e) {
      if (!mounted) return;
      _snack('导出失败：${_msgOf(e)}');
    }
  }

  Future<void> _exportRows({required bool asDoc}) async {
    final sheet = _sheet;
    if (sheet == null || _rows.isEmpty) {
      _snack('这个阶段还没有扫码记录，先扫几条再导出');
      return;
    }
    final no = sheet['sheet_no'] as String;
    setState(() => _exporting = true);
    try {
      final name = FileIo.safeName(asDoc
          ? InventoryExport.docName(no)
          : InventoryExport.csvName(no));
      final text = asDoc
          ? InventoryExport.toRowsDoc(_rows,
              sheetNo: no,
              zoneName: widget.zoneName,
              phaseLabel: InvPhase.label(_phase))
          : InventoryExport.toRowsCsv(_rows);
      final dir = await FileIo.dir();
      final f = File('${dir.path}${Platform.pathSeparator}$name');
      await f.writeAsString(text);
      if (!mounted) return;
      setState(() => _exporting = false);
      await ExportFlow.show(context, f,
          rows: _rows.length, suggestName: name, onMessage: _snack);
    } catch (e) {
      if (!mounted) return;
      setState(() => _exporting = false);
      _snack('导出失败：${_msgOf(e)}');
    }
  }

  Future<void> _clearZoneData() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.bgElevated,
        title: const Text('清除本点位盘点数据（不可恢复）',
            style: TextStyle(color: AppColors.text, fontSize: 16)),
        content: Text(
          '会删掉「${widget.zoneName}」下**所有阶段**的盘点单与扫码明细。\n'
          '点位、货架位、商品绑定这些档案会保留。\n\n'
          '（只清本机数据，已经同步到服务端的不会被删。）',
          style: const TextStyle(color: AppColors.textSub, fontSize: 13),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child:
                  const Text('清除', style: TextStyle(color: AppColors.danger))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      final r = await _repo.clearZoneData(widget.zoneCode);
      await _enterPhase(InvPhase.first);
      if (!mounted) return;
      _snack('已清除 ${r['sheet'] ?? 0} 张单、${r['scan_record'] ?? 0} 条明细');
    } catch (e) {
      _snack('清除失败：${_msgOf(e)}');
    }
  }

  Future<void> _openCamera() async {
    var sheet = _sheet;
    if (sheet == null) {
      await _enterPhase(_phase);
      sheet = _sheet;
      if (sheet == null) return;
    }
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => InventoryScanPage(
          sheetNo: sheet!['sheet_no'] as String,
          repo: _repo,
          locCode: _locCode,
          phaseLabel: InvPhase.label(_phase),
        ),
      ),
    );
    if (!mounted) return;
    await _refreshAll();
  }

  // ============================================================
  // 界面
  // ============================================================

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  /// 把异常揉成一句人话。裸 `$e` 会带上 `StateError: ` 这种前缀，
  /// 现场看到的应该是"盘点位已锁定，请先解除锁定"。
  static String _msgOf(Object e) {
    final s = e.toString();
    return s.replaceFirst(RegExp(r'^\w*Exception: '), '').replaceFirst(
        RegExp(r'^Bad state: '), '');
  }

  @override
  Widget build(BuildContext context) {
    final pc = phaseColor(_phase);
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bgElevated,
        title: Text(widget.zoneName,
            style: const TextStyle(color: AppColors.text, fontSize: 17)),
        actions: [
          IconButton(
            key: const Key('inv-diff-btn'),
            tooltip: '${InvPhase.label(_phase)}差异表',
            icon: const Icon(Icons.rule, color: AppColors.textSub),
            onPressed: _loading ? null : _showDiffSheet,
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert, color: AppColors.textSub),
            onSelected: (v) {
              if (v == 'clear') _clearZoneData();
            },
            itemBuilder: (_) => const [
              PopupMenuItem<String>(
                  value: 'clear', child: Text('清除本点位盘点数据')),
            ],
          ),
        ],
      ),
      bottomNavigationBar: _loading ? null : _bottomBar(),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                if (_error != null) _banner(_error!, AppColors.danger),
                _phaseBar(),
                _locBar(),
                _inputBar(),
                _notice(pc),
                _statBar(pc),
                Expanded(
                  child: _phaseLoading
                      ? const Center(child: CircularProgressIndicator())
                      : (_rows.isEmpty
                          ? _empty(pc)
                          : ListView.separated(
                              padding: const EdgeInsets.only(bottom: 10),
                              itemCount: _rows.length,
                              separatorBuilder: (_, __) =>
                                  const Divider(height: 1, indent: 14),
                              itemBuilder: (_, i) => _rowTile(_rows[i], i + 1),
                            )),
                ),
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

  /// 阶段条：三段并排，当前那段用**自己的阶段色**填底。
  Widget _phaseBar() => Container(
        color: AppColors.bgElevated,
        padding: const EdgeInsets.fromLTRB(11, 8, 11, 8),
        child: Row(
          children: [
            for (final p in InvPhase.all) _phaseTab(p),
          ],
        ),
      );

  Widget _phaseTab(int phase) {
    final item = _progress.firstWhere(
      (x) => (x['phase'] as num).toInt() == phase,
      orElse: () => <String, dynamic>{'phase': phase},
    );
    final active = phase == _phase;
    final c = phaseColor(phase);
    final status = (item['status'] as num? ?? -1).toInt();
    final kinds = (item['kinds'] as num? ?? 0).toInt();
    final diff = (item['diff'] as num? ?? 0).toInt();
    final statusText = status == -1 ? '未开始' : InvSheetStatus.label(status);

    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 3),
        child: InkWell(
          key: Key('inv-phase-$phase'),
          borderRadius: BorderRadius.circular(AppRadii.sm),
          onTap: () => _switchPhase(phase),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
            decoration: BoxDecoration(
              color: active
                  ? c.withValues(alpha: 0.16)
                  : AppColors.surface,
              borderRadius: BorderRadius.circular(AppRadii.sm),
              border: Border.all(
                  color: active ? c : AppColors.border,
                  width: active ? 1.4 : 1),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        InvPhase.label(phase),
                        style: TextStyle(
                            color: active ? c : AppColors.textSub,
                            fontSize: 13,
                            fontWeight:
                                active ? FontWeight.w700 : FontWeight.w500),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 4),
                    if (status != -1)
                      Container(
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(
                            color: c,
                            borderRadius: BorderRadius.circular(999)),
                      ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  kinds == 0 ? statusText : '$kinds 种 · 差 $diff',
                  style: const TextStyle(
                      color: AppColors.textWeak, fontSize: 10),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 货架位选择条。现场的做法是"人站在哪个货架前就选哪个"。
  Widget _locBar() => Container(
        color: AppColors.bgElevated,
        padding: const EdgeInsets.fromLTRB(11, 0, 11, 8),
        child: Row(
          children: [
            const Icon(Icons.place_outlined,
                size: 15, color: AppColors.textWeak),
            const SizedBox(width: 5),
            const Text('货架位：',
                style: TextStyle(color: AppColors.textWeak, fontSize: 12)),
            Expanded(
              child: SizedBox(
                height: 30,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: [
                    if (_locs.isEmpty)
                      const Center(
                        child: Text('还没建，扫到没绑过的商品会不记货架位',
                            style: TextStyle(
                                color: AppColors.textWeak, fontSize: 11)),
                      )
                    else
                      for (final l in _locs) _locChip(l),
                  ],
                ),
              ),
            ),
            InkWell(
              key: const Key('inv-new-loc'),
              borderRadius: BorderRadius.circular(999),
              onTap: _newLocation,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.add, size: 14, color: AppColors.brand),
                    Text('新建',
                        style: TextStyle(
                            color: AppColors.brand,
                            fontSize: 12,
                            fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
            ),
          ],
        ),
      );

  Widget _locChip(Map<String, dynamic> l) {
    final code = (l['loc_code'] ?? '').toString();
    final active = code == _locCode;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: InkWell(
        key: Key('inv-loc-$code'),
        borderRadius: BorderRadius.circular(999),
        onTap: () => setState(() => _locCode = code),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: active
                ? AppColors.brand.withValues(alpha: 0.18)
                : AppColors.surface,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
                color: active ? AppColors.brand : AppColors.border, width: 1),
          ),
          child: Text(
            (l['loc_name'] ?? code).toString(),
            style: TextStyle(
                color: active ? AppColors.brand : AppColors.textSub,
                fontSize: 12,
                fontWeight: active ? FontWeight.w600 : FontWeight.normal),
          ),
        ),
      ),
    );
  }

  Widget _inputBar() => Container(
        color: AppColors.bgElevated,
        padding: const EdgeInsets.fromLTRB(11, 0, 11, 10),
        child: Row(
          children: [
            // 手机端把「扫码」放最左、给足面积 —— 现场大多数店没有扫码枪，
            // 摄像头才是主路径，输入框是兜底。
            if (InventoryScanPage.supported) ...[
              Material(
                color: AppColors.brand.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(AppRadii.sm),
                child: InkWell(
                  key: const Key('inv-camera'),
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
                key: const Key('inv-scan-input'),
                controller: _input,
                focusNode: _focus,
                autofocus: true,
                // 🔴 **不能**用 TextInputType.visiblePassword：Android 会把它
                // 当密码框，弹出来的是密码安全键盘，数字全变圆点。
                // 要的是"关掉输入法干预"，那是下面两个开关的活。
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
                onSubmitted: _handleCode,
              ),
            ),
          ],
        ),
      );

  /// 当前阶段最重要的一句提醒。
  Widget _notice(Color pc) {
    String? text;
    Color c = pc;
    if (_phase == InvPhase.second) {
      text = '复盘只盘上一轮的差异商品（${_diffSet.length} 种）。'
          '扫其他商品不会被记上。';
      c = AppColors.warn;
    } else if (_phase == InvPhase.third) {
      text = '抽盘是主管抽查：可以扫任意商品，不受差异集限制。扫完看「差异表」出抽盘差异。';
      c = AppColors.brand2;
    }
    if (text == null) return const SizedBox.shrink();
    return _banner(text, c);
  }

  Widget _statBar(Color pc) => Container(
        color: AppColors.bgElevated,
        padding: const EdgeInsets.fromLTRB(14, 0, 14, 9),
        child: Row(
          children: [
            Expanded(
              child: Text(
                _sheet == null ? '还没开始' : (_sheet!['sheet_no'] ?? '').toString(),
                style: const TextStyle(color: AppColors.textWeak, fontSize: 11),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            _statChip('品种', '${_sum['kinds'] ?? 0}'),
            const SizedBox(width: 6),
            _statChip('合计', fmtQty(_sum['total_qty'])),
            const SizedBox(width: 6),
            _statChip('差异', '${_diffRows.length}',
                color: _diffRows.isEmpty ? null : AppColors.warn),
            if (((_sum['unknown'] as num? ?? 0).toInt()) > 0) ...[
              const SizedBox(width: 6),
              _statChip('未知 ${_sum['unknown']}', '',
                  color: AppColors.warn),
            ],
          ],
        ),
      );

  Widget _statChip(String label, String value, {Color? color}) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: (color ?? AppColors.textSub).withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          value.isEmpty ? label : '$label $value',
          style: TextStyle(color: color ?? AppColors.textSub, fontSize: 11),
        ),
      );

  /// 空状态的外壳：**有空间就居中，没空间就滚动**。
  ///
  /// 🔴 不能直接 `Center(child: Column(...))`：小屏 + 系统大字体下整块会
  ///    **溢出**（实测溢出 5.8px），最下面那个按钮被顶到屏幕外**点不到**。
  ///    空状态里恰恰放着最该点得着的那个按钮（"直接去抽盘"），
  ///    点不到就等于这条路没给。
  Widget _emptyShell(Widget child) => LayoutBuilder(
        builder: (_, cons) => SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: cons.maxHeight),
            child: Center(child: child),
          ),
        ),
      );

  Widget _empty(Color pc) {
    // 复盘阶段 + 上一轮零差异 = 这一遍**没东西可盘**。
    // 必须给一条出路：否则按钮因为"一条都没扫"而灰着，员工卡在这儿
    // 出不去（门店盘得很准时这是常态，不是异常）。
    if (_phase == InvPhase.second && _diffSet.isEmpty) {
      return _emptyShell(
        Padding(
          // 底部留 96：浮动的 SnackBar 就飘在这块区域上方，
          // 不留的话"提示弹出那 4 秒"里按钮被压住**点不动**（实测命中测试失败）。
          padding: const EdgeInsets.fromLTRB(28, 28, 28, 96),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.task_alt, size: 44, color: AppColors.brand),
              const SizedBox(height: 14),
              const Text('上一轮没有差异',
                  style: TextStyle(color: AppColors.text, fontSize: 15)),
              const SizedBox(height: 10),
              const Text(
                '初盘盘得很准，这一遍没什么可盘的了。\n'
                '可以直接去抽盘，让主管抽查一遍。',
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: AppColors.textWeak, fontSize: 13, height: 1.7),
              ),
              const SizedBox(height: 16),
              FilledButton.tonalIcon(
                key: const Key('inv-skip-to-third'),
                onPressed: () => _enterPhase(InvPhase.third),
                icon: const Icon(Icons.skip_next, size: 18),
                label: const Text('直接去抽盘'),
              ),
            ],
          ),
        ),
      );
    }

    return _emptyShell(
      Padding(
        padding: const EdgeInsets.fromLTRB(28, 28, 28, 96),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.qr_code_scanner, size: 44, color: pc),
            const SizedBox(height: 14),
            Text('${InvPhase.label(_phase)}还没扫',
                style: const TextStyle(color: AppColors.text, fontSize: 15)),
            const SizedBox(height: 10),
            Text(
              _phase == InvPhase.second
                  ? '这一遍只盘上一轮的差异商品。\n差异表里那 ${_diffSet.length} 个商品扫一遍就行。'
                  : '对着货架上的条码一路扫。\n'
                      '扫错了或者要改数量，点右边那个数量格。',
              textAlign: TextAlign.center,
              style: const TextStyle(
                  color: AppColors.textWeak, fontSize: 13, height: 1.7),
            ),
          ],
        ),
      ),
    );
  }

  Widget _rowTile(Map<String, dynamic> r, int idx) {
    final bc = r['barcode'].toString();
    final unknown = (r['name'] ?? '').toString().trim().isEmpty;
    final acc = r['account_qty'];
    final d = (r['diff_qty'] as num?)?.toDouble();
    final lc = (r['loc_code'] ?? '').toString();
    final isDiff = InventoryRules.isDiffRow(r);

    return InkWell(
      key: Key('inv-row-$bc'),
      onLongPress: () => _rowMenu(r),
      child: Container(
        color: isDiff ? AppColors.warn.withValues(alpha: 0.045) : null,
        padding: const EdgeInsets.fromLTRB(14, 9, 10, 9),
        child: Row(
          children: [
            SizedBox(
              width: 26,
              child: Text('$idx',
                  style: const TextStyle(
                      color: AppColors.textWeak, fontSize: 12)),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    InventoryExport.nameOf(r),
                    style: TextStyle(
                        color: unknown ? AppColors.warn : AppColors.text,
                        fontSize: 14,
                        fontWeight: FontWeight.w500),
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          bc,
                          style: const TextStyle(
                              color: AppColors.textWeak, fontSize: 11),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (lc.isNotEmpty) ...[
                        const SizedBox(width: 6),
                        Icon(Icons.place,
                            size: 11,
                            color: AppColors.textWeak.withValues(alpha: 0.9)),
                        Text(lc,
                            style: const TextStyle(
                                color: AppColors.textWeak, fontSize: 11)),
                      ],
                      if (acc != null) ...[
                        const SizedBox(width: 6),
                        Text('账面 ${fmtQty(acc)}',
                            style: const TextStyle(
                                color: AppColors.textWeak, fontSize: 11)),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            if (d != null && d != 0)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Text(
                  '${d > 0 ? '+' : ''}${fmtQty(d)}',
                  style: TextStyle(
                      color: d < 0 ? AppColors.danger : AppColors.brand,
                      fontSize: 12,
                      fontWeight: FontWeight.w600),
                ),
              ),
            _qtyPill(r, bc),
          ],
        ),
      ),
    );
  }

  /// 数量格 —— **做成有底色的小胶囊**。
  ///
  /// 一行纯文字里没人看得出"这个数字能点"。所以给它底色、加 tooltip，
  /// 并且 key 固定成 `inv-qty-<条码>`，测试才能精确点到"这一行"。
  Widget _qtyPill(Map<String, dynamic> r, String barcode) {
    final locked = !_editable;
    return Tooltip(
      message: locked ? '本单已提交，先撤销提交' : '点这里改数量',
      child: InkWell(
        key: Key('inv-qty-$barcode'),
        borderRadius: BorderRadius.circular(AppRadii.sm),
        onTap: locked ? null : () => _editQty(r),
        child: Container(
          constraints: const BoxConstraints(minWidth: 56),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(
            color: locked
                ? AppColors.surface
                : AppColors.brand.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(AppRadii.sm),
            border: Border.all(
                color: locked ? AppColors.border : AppColors.brand,
                width: 1),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                fmtQty(r['qty']),
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: locked ? AppColors.textWeak : AppColors.brand,
                    fontSize: 15,
                    fontWeight: FontWeight.w700),
              ),
              if (!locked) ...[
                const SizedBox(width: 4),
                Icon(Icons.edit,
                    size: 11,
                    color: AppColors.brand.withValues(alpha: 0.75)),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _bottomBar() {
    final editable = _editable;
    final hasSheet = _sheet != null;
    // 🔴 **一条都没扫就不给提交。**
    //    提交 = "这一遍我盘完了"。空手点一下就把初盘标记成完成，
    //    差异集随之定格为空 —— 后面的复盘、抽盘全部建立在"没有差异"上，
    //    整条链报废，而且**没有任何报错**，等对账时才发现。
    //    宁可让人先扫一件，也不能让这个动作随手可及。
    final canSubmit = hasSheet && !_phaseLoading && _rows.isNotEmpty;
    return Container(
      color: AppColors.bgElevated,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            Expanded(
              child: editable
                  ? FilledButton.icon(
                      key: const Key('inv-submit'),
                      onPressed: canSubmit ? _submit : null,
                      icon: const Icon(Icons.check, size: 18),
                      label: Text(canSubmit
                          ? '提交${InvPhase.label(_phase)}'
                          : '先扫一件再提交'),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(44),
                      ),
                    )
                  : OutlinedButton.icon(
                      key: const Key('inv-reopen'),
                      onPressed: _reopen,
                      icon: const Icon(Icons.lock_open, size: 18),
                      // ⚠️ InvSheetStatus.label 本身就带"已"（"已提交"/"已上传"），
                      //    这里不要再加一个 —— 会拼出"已已提交"。
                      label: Text(
                          '${InvSheetStatus.label((_sheet!['status'] as num).toInt())}'
                          ' · 撤销提交'),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size.fromHeight(44),
                        foregroundColor: AppColors.warn,
                      ),
                    ),
            ),
            const SizedBox(width: 8),
            IconButton(
              key: const Key('inv-export-csv'),
              tooltip: '导出本阶段明细表格',
              onPressed: _exporting ? null : () => _exportRows(asDoc: false),
              icon: _exporting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.table_chart_outlined,
                      color: AppColors.textSub),
            ),
            IconButton(
              key: const Key('inv-export-doc'),
              tooltip: '导出本阶段明细文档',
              onPressed: _exporting ? null : () => _exportRows(asDoc: true),
              icon: const Icon(Icons.description_outlined,
                  color: AppColors.textSub),
            ),
          ],
        ),
      ),
    );
  }
}
