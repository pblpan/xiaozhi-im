// 「简易盘点」页面（`simple_stocktake`）—— 导入清单 → 一趟趟盘 → 导出全量。
//
// ── 和「盘点」「扫码枪」「库房减货」什么关系 ──────────────────
//   · 扫码枪 stocktake：把条码扫成一笔账（工具，不分位置/阶段/规则）；
//   · 盘点   inventory：**制度型** —— 盘点位 × 货架位 × 初盘复盘抽盘三遍互比；
//   · 减货   warehouse_deduct：库房减库存的作业单；
//   · 简易盘点（本页）：**干活型** —— 导入"这一轮要盘什么"的清单，
//     一趟一趟扫（同码累加），最后导出一张**全量**盘点数据单
//     （没盘到的也出，数量 0）。
//
// 为什么它必须**单独一个工作台入口**：库房减货当初是塞在盘点页右上角的
// 小图标里，真机验收时龙哥说"**我没找到你说的功能在哪里**"。一个每天要干的活，
// 藏在别人页面的图标里就是没有入口。
//
// ── 这一版（S1）做到哪 ───────────────────────────────────────
// 导入清单 + 任务（含场景）+ **单节点（初盘）扫码** + 导出三段。
// 复盘 / 差异复盘 / 差异集是 S2 —— 所以本页的底部栏**不摆**那些按钮：
// 摆一个点了没用的"下一趟"，比没有更糟。
//
// 方案：`docs/简易盘点通道方案-v1.md`
// 口径（龙哥定的，别自己改）：
//   · 一趟内同码多次扫 = **累加**；
//   · 扫到清单外的 = **不拦**，入账，导出作第三段；
//   · 没盘到的也要出，数量 **0**；
//   · 一个 CSV 三段，每段三列（商品条码 / 商品盘点数量 / 商品名称）。

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/file_io.dart';
import '../core/inventory_rules.dart';
import '../core/simple_export.dart';
import '../core/simple_repo.dart';
import '../core/simple_rules.dart';
import '../core/simple_scan_sink.dart';
import '../core/stock_master_repo.dart';
import '../core/theme.dart';
import '../widgets/export_flow.dart';
import 'camera_scan.dart';
import 'master_lookup.dart';

/// 导入时选定的场景与轮次名。
class _RoundPick {
  const _RoundPick(this.scene, this.name);
  final String scene;
  final String name;
}

class SimpleStocktakePage extends StatefulWidget {
  const SimpleStocktakePage({super.key, this.repo});

  /// 测试注入点（可以给一个 maxRows 调小的仓库）。
  final SimpleRepo? repo;

  @override
  State<SimpleStocktakePage> createState() => _SimpleStocktakePageState();
}

class _SimpleStocktakePageState extends State<SimpleStocktakePage> {
  late SimpleRepo _repo;

  final TextEditingController _scanCtl = TextEditingController();
  final TextEditingController _qtyCtl = TextEditingController(text: '1');
  final FocusNode _scanFocus = FocusNode();

  Map<String, dynamic>? _task;
  Map<String, dynamic>? _node;
  List<Map<String, dynamic>> _items = const <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _rows = const <Map<String, dynamic>>[];
  SimpleTaskTally _taskTally = const SimpleTaskTally(
      totalItems: 0, scannedInList: 0, scannedOffList: 0);
  SimpleNodeTally _nodeTally =
      const SimpleNodeTally(rows: 0, totalQty: 0, offList: 0);

  bool _loading = true;
  bool _busy = false;
  String? _error;

  /// 🔴 认住**当前那一轮 / 那一趟**的单号，不能每次刷新都去"取最新的"：
  ///    换过清单之后，上一轮会被归档，这时候若按"进行中的那一轮"去取，
  ///    现场看到的是"我刚盘的那一轮不见了"。（这个坑在减货单上真踩过。）
  String? _curTaskNo;
  String? _curNodeNo;

  /// 当前趟次（1初盘 / 2复盘 / 3差异复盘）。
  int get _phase => _intOf(_node?['phase']);

  /// 差异集（前两趟对不上的条码）。差异复盘那一趟**只许扫这批**。
  ///
  /// 每次刷新算一次存着，不每次扫码都算 —— 扫码是逐笔的连续动作，
  /// 每扫一次就全表聚合一遍会让枪在长列表上明显发涩。
  Set<String> _diffSet = const <String>{};

  /// 差异复盘那一趟做完了吗（决定导出时"对不上的"是定稿还是待复核）。
  bool _thirdDone = false;

  /// 明细区当前显示哪个视图：true = 「还没盘」（按清单顺序引导扫），
  /// false = 「本趟已录」（按扫描先后核对）。
  ///
  /// 默认"还没盘"：20 个品的清单，员工要的是**下一个扫什么**，
  /// 不是自己已经扫过什么 —— 那个他心里有数。
  bool _showPending = true;

  @override
  void initState() {
    super.initState();
    _repo = widget.repo ?? SimpleRepo();
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

  bool get _hasTask => _task != null;

  String get _scene =>
      SimpleScene.normalize((_task?['scene'] ?? '').toString());

  bool get _editable =>
      _node != null &&
      InvSheetStatus.editable(_intOf(_node!['status']));

  String get _taskNo => _curTaskNo ?? '';
  String get _nodeNo => _curNodeNo ?? '';

  String get _taskTitle {
    final n = (_task?['task_name'] ?? '').toString().trim();
    return n.isEmpty ? '（未命名）' : n;
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  // ============================================================
  // 加载
  // ============================================================

  Future<void> _reload({
    String? loadTaskNo,
    String? loadNodeNo,
    bool forceNewNode = false,
  }) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      // 先落到本地变量：`_curTaskNo` 是**字段**，字段不做类型提升，
      // 直接 `findTask(_curTaskNo)` 会被判成 `String?` 传给 `String`。
      final curTaskNo = _curTaskNo;
      Map<String, dynamic>? t;
      if (loadTaskNo != null) {
        t = await _repo.findTask(loadTaskNo);
      } else if (curTaskNo != null) {
        t = await _repo.findTask(curTaskNo);
      }
      t ??= await _repo.latestTask();

      if (t == null) {
        // 一次都没导过：整页走空状态（**不能是一片空白**，见 §5）。
        if (!mounted) return;
        setState(() {
          _task = null;
          _node = null;
          _items = const <Map<String, dynamic>>[];
          _rows = const <Map<String, dynamic>>[];
          _taskTally = const SimpleTaskTally(
              totalItems: 0, scannedInList: 0, scannedOffList: 0);
          _nodeTally = const SimpleNodeTally(rows: 0, totalQty: 0, offList: 0);
          _curTaskNo = null;
          _curNodeNo = null;
          _loading = false;
        });
        return;
      }

      final taskNo = (t['task_no'] ?? '').toString();
      final archived = _intOf(t['status']) != SimpleRepo.taskOpen;

      final curNodeNo = _curNodeNo;
      Map<String, dynamic>? n;
      if (loadNodeNo != null) n = await _repo.findNode(loadNodeNo);
      if (n == null && curNodeNo != null && _curTaskNo == taskNo) {
        n = await _repo.findNode(curNodeNo);
      }
      n ??= await _repo.openNodeOf(taskNo, SimplePhase.first);
      // 归档的那一轮**不再开新趟**（它已经盘完了），只把已有趟次读出来看。
      if (n == null && !archived) {
        // 🔴 不能写死开初盘：初盘交完之后 `openNodeOf(初盘)` 是 null，
        //    写死就会**再开一张空的初盘**，刚刚盘完的数据看着像凭空消失了。
        //    问仓库"下一趟该开哪一趟"，三趟都开过且都交了 → 不开新的。
        final next = await _repo.nextOpenPhase(taskNo);
        if (next != null) {
          n = await _repo.openOrCreateNode(taskNo, next,
              forceNew: forceNewNode);
        }
      }

      final nodeNo = n == null ? null : (n['sheet_no'] ?? '').toString();
      final items = await _repo.listItems(taskNo);
      final rows = nodeNo == null
          ? const <Map<String, dynamic>>[]
          : await _repo.listNodeRows(nodeNo);
      final tt = await _repo.taskTally(taskNo);
      final nt = nodeNo == null
          ? const SimpleNodeTally(rows: 0, totalQty: 0, offList: 0)
          : await _repo.nodeTally(nodeNo);
      // 差异集与"第三趟做完了吗"：差异复盘只扫差异集，
      // 导出时要知道"对不上的那些是定稿了还是还待复核"。
      final diff = await _repo.diffSet(taskNo);
      final third = await _repo.nodeOf(taskNo, SimplePhase.third);
      final thirdDone =
          third != null && _intOf(third['status']) >= InvSheetStatus.submitted;

      if (!mounted) return;
      setState(() {
        _task = t;
        _node = n;
        _diffSet = diff;
        _thirdDone = thirdDone;
        _curTaskNo = taskNo;
        _curNodeNo = nodeNo;
        _items = items;
        _rows = rows;
        _taskTally = tt;
        _nodeTally = nt;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '打开简易盘点失败：$e';
        _loading = false;
      });
    }
  }

  // ============================================================
  // 导入清单
  // ============================================================

  /// 问场景 + 本轮名称。返回 null 表示用户取消。
  Future<_RoundPick?> _askRound() async {
    var scene = _hasTask ? _scene : SimpleScene.store;
    final nameCtl = TextEditingController();
    final r = await showDialog<_RoundPick>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) => AlertDialog(
          backgroundColor: AppColors.bgElevated,
          title: const Text('导入这一轮要盘的商品清单',
              style: TextStyle(color: AppColors.text, fontSize: 16)),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('这一轮盘的是哪儿？',
                    style: TextStyle(color: AppColors.textSub, fontSize: 13)),
                const SizedBox(height: 6),
                Row(
                  children: SimpleScene.all.map((s) {
                    final on = scene == s;
                    return Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        key: Key('simple-scene-$s'),
                        label: Text(SimpleScene.label(s)),
                        selected: on,
                        onSelected: (_) => setDlg(() => scene = s),
                      ),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 10),
                const Text('给这一轮起个名字（可以不填）',
                    style: TextStyle(color: AppColors.textSub, fontSize: 13)),
                TextField(
                  key: const Key('simple-round-name'),
                  controller: nameCtl,
                  style: const TextStyle(color: AppColors.text, fontSize: 15),
                  decoration: const InputDecoration(
                    hintText: '例：9月生鲜大盘',
                    isDense: true,
                  ),
                ),
                if (_hasTask) ...[
                  const SizedBox(height: 12),
                  Text(
                    '会把当前这一轮（$_taskNo）归档，换上新的一份清单。\n'
                    '上一轮的数据**不会删**，随时能在「历史趟次」里翻回来导出。',
                    style: const TextStyle(color: AppColors.warn, fontSize: 12),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('取消')),
            TextButton(
              key: const Key('simple-pick-file'),
              onPressed: () =>
                  Navigator.pop(ctx, _RoundPick(scene, nameCtl.text.trim())),
              child: const Text('选择 CSV 文件',
                  style: TextStyle(
                      color: AppColors.brand, fontWeight: FontWeight.w600)),
            ),
          ],
        ),
      ),
    );
    nameCtl.dispose();
    return r;
  }

  /// 导入链路：问场景 → 选文件 → **先解码（编码不对就停）** → 解析 →
  /// 把"读到多少 / 导入多少 / 跳过多少"给用户看 → 确认后才真正建新一轮。
  ///
  /// 🔴 顺序是刻意的：**先报数、再落库**。落完库再报数的话，导错了（比如
  ///    选错了文件）也已经把清单换掉了，员工只能再导一次碰运气。
  Future<void> _importFlow() async {
    final pick = await _askRound();
    if (pick == null) return;

    List<PlatformFile> files;
    try {
      // ⚠️ 用 `FileType.any` 而不是 `custom + allowedExtensions`：
      //    Android 的 SAF 是按 MIME 过滤的，而 .csv 经常被标成
      //    application/octet-stream —— 用扩展名筛的后果是**文件在选择器里
      //    根本看不见**，那种失败比"选错文件"难查得多。
      //    所以不筛，靠内容判定（解析不出东西会明确报"读不到数据行"）。
      files = await FilePicker.pickFiles(dialogTitle: '选择这一轮的商品清单（CSV）');
    } catch (e) {
      _snack('打开文件选择器失败：$e');
      return;
    }
    if (files.isEmpty) return;

    final f = files.first;
    final low = f.name.toLowerCase();
    if (low.endsWith('.xlsx') || low.endsWith('.xls')) {
      _snack('这是 Excel 工作簿（${f.name}），不是 CSV —— '
          '请在 Excel 里「另存为 → CSV UTF-8(逗号分隔)」再导');
      return;
    }

    setState(() => _busy = true);
    try {
      // 🔴 走 `readAsBytes()` 而不是 `File(path)`：Android 走 SAF 时
      //    `path` 是 null（`content://`），只有字节流是两端都拿得到的。
      final bytes = await f.readAsBytes();
      final dec = SimpleRules.decodeCsvBytes(bytes);
      if (!dec.ok) {
        // 编码不对**必须停**：硬读下去会得到"条码全对、商品名全是乱码"，
        // 那是最不容易当场发现的一种坏。
        if (!mounted) return;
        await _alert('这个清单打不开', dec.error ?? '读不出内容');
        return;
      }

      final parsed = SimpleRules.parseCsv(dec.text ?? '');
      if (parsed.isEmpty) {
        if (!mounted) return;
        await _alert('这个清单里没有商品', parsed.emptyReason ?? '读不到数据行');
        return;
      }

      if (!mounted) return;
      final go = await _confirmImport(parsed, pick, f.name);
      if (go != true) return;

      final t = await _repo.startNewRound(
        scene: pick.scene,
        rows: parsed.rows,
        taskName: pick.name.isEmpty ? _stripExt(f.name) : pick.name,
      );
      _curTaskNo = (t['task_no'] ?? '').toString();
      _curNodeNo = null; // 新一轮从第 1 趟重新开始
      await _reload();
      _snack('${SimpleScene.label(pick.scene)}新一轮已建：$_curTaskNo\n'
          '${parsed.report}');
    } catch (e) {
      _snack('导入失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool?> _confirmImport(
      SimpleImportResult parsed, _RoundPick pick, String fileName) async {
    // 报数 + **报文件名**：一次选错文件（比如拿了上一轮的清单）时，
    // 行数往往也"看着差不多"，只有文件名能一眼认出来。
    final sb = StringBuffer()
      ..writeln(fileName)
      ..writeln('${SimpleScene.label(pick.scene)}'
          '${pick.name.isEmpty ? '' : '　·　${pick.name}'}')
      ..writeln(parsed.report);
    if (parsed.dupSkipped > 0) {
      sb.writeln('（重复条码只留第一条）');
    }
    if (parsed.noBarcodeSkipped > 0) {
      sb.writeln('（没有条码的行没导进来）');
    }
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.bgElevated,
        title: const Text('确认导入',
            style: TextStyle(color: AppColors.text, fontSize: 16)),
        content: Text(sb.toString(),
            style: const TextStyle(color: AppColors.textSub, fontSize: 14)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('再看看')),
          TextButton(
              key: const Key('simple-import-ok'),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('开始盘点',
                  style: TextStyle(
                      color: AppColors.brand, fontWeight: FontWeight.w600))),
        ],
      ),
    );
  }

  Future<void> _alert(String title, String body) => showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppColors.bgElevated,
          title: Text(title,
              style: const TextStyle(color: AppColors.text, fontSize: 16)),
          content: Text(body,
              style: const TextStyle(color: AppColors.textSub, fontSize: 14)),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('知道了')),
          ],
        ),
      );

  static String _stripExt(String name) {
    final i = name.lastIndexOf('.');
    return i > 0 ? name.substring(0, i) : name;
  }

  /// 给一份**能直接用的**模板。
  ///
  /// 现场最常见的失败不是"不会填"，而是"在 Excel 里随手另存成 GBK 的 CSV"。
  /// 给一份带 BOM 的 UTF-8 模板，他另存时大概率沿用对的编码。
  Future<void> _downloadTemplate() async {
    setState(() => _busy = true);
    try {
      final dir = await FileIo.dir();
      final name = FileIo.safeName('简易盘点清单模板.csv');
      final f = File('${dir.path}${Platform.pathSeparator}$name');
      final b = StringBuffer('\uFEFF')
        ..writeln('商品条码,商品名称,规格')
        ..writeln('6901234567890,农夫山泉 550ml,550ml')
        ..writeln('6901234567891,可口可乐 330ml,330ml')
        ..writeln('6901234567892,散装白糖,1kg');
      // UTF-8；BOM 由上面那行负责（不带 BOM 的话 Excel 双击会按 GBK 读）
      await f.writeAsString(b.toString());
      if (!mounted) return;
      await ExportFlow.show(context, f,
          rows: 3, suggestName: name, onMessage: _snack);
    } catch (e) {
      if (!mounted) return;
      _snack('生成模板失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ============================================================
  // 扫码
  // ============================================================

  Future<void> _addScan() async {
    final barcode = _scanCtl.text.trim();
    if (barcode.isEmpty) {
      _snack('先扫一个条码');
      _scanFocus.requestFocus();
      return;
    }
    final qtyRaw = _qtyCtl.text.trim();
    final err = SimpleRules.qtyError(qtyRaw);
    if (err != null) {
      _snack(err);
      return;
    }
    setState(() => _busy = true);
    try {
      // 差异复盘那一趟**只许扫差异集**：把集合传进去，由规则层判
      // （规则层还会再确认一次 phase 真是第三趟，不靠这里自觉）。
      final r = await _repo.scan(_nodeNo, barcode,
          qty: SimpleRules.parseQty(qtyRaw) ?? 1,
          allowedBarcodes:
              SimplePhase.onlyDiffSet(_phase) ? _diffSet : null);
      if (!mounted) return;
      if (!r.accepted) {
        // 被拒时**保留输入**：他要看到自己扫的是哪个码才知道下一步做什么。
        _snack(r.decision.message ?? '这一笔没能记上');
        SystemSound.play(SystemSoundType.alert);
        return;
      }
      _scanCtl.clear();
      _qtyCtl.text = '1';
      SystemSound.play(SystemSoundType.click);
      await _reload();
      if (!mounted) return;
      // 清单外的：黄条 + 一句话，别让员工以为扫错了。
      if (r.decision.warned) {
        _snack(r.decision.message ?? '不在导入的清单里，已记入');
      }
      _scanFocus.requestFocus();
    } catch (e) {
      if (!mounted) return;
      _snack('录入失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 摄像头扫码：复用扫码枪/盘点同一套相机页（去重、冷却、闪绿都在那层）。
  Future<void> _openCameraScan() async {
    if (_node == null || !_editable || _nodeNo.isEmpty) return;
    final onlyDiff = SimplePhase.onlyDiffSet(_phase);
    final sink = SimpleScanSink(_repo,
        allowedBarcodes: onlyDiff ? _diffSet : null);
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => CameraScanPage(
        title: '简易盘点 · ${SimplePhase.label(_phase)}',
        sheetNo: _nodeNo,
        sink: sink,
        hint: onlyDiff ? '这一趟只盘前两趟对不上的 ${_diffSet.length} 个品' : null,
      ),
    ));
    if (!mounted) return;
    await _reload(loadNodeNo: _nodeNo);
  }

  /// 本趟**还没盘**的，按清单顺序（seq）排 —— 这就是"下一个扫什么"的引导。
  ///
  /// 差异复盘那一趟只许扫差异集 → 「还没盘」就只列差异集里剩下的
  /// （照清单顺序排，清单外的差异码排最后），其余清单品列出来只会误导员工去扫一个必然被拒的码。
  List<Map<String, dynamic>> get _pendingRows {
    final done =
        _rows.map((r) => (r['barcode'] ?? '').toString()).toSet();
    if (SimplePhase.onlyDiffSet(_phase)) {
      final inList = <Map<String, dynamic>>[];
      final offList = <Map<String, dynamic>>[];
      for (final b in _diffSet) {
        if (done.contains(b)) continue;
        Map<String, dynamic>? it;
        for (final i in _items) {
          if ((i['barcode'] ?? '').toString() == b) {
            it = i;
            break;
          }
        }
        (it == null ? offList : inList)
            .add(it ?? <String, dynamic>{'barcode': b, 'name': '', 'spec': ''});
      }
      return <Map<String, dynamic>>[...inList, ...offList];
    }
    return _items
        .where((i) => !done.contains((i['barcode'] ?? '').toString()))
        .toList();
  }

  Future<void> _editQty(Map<String, dynamic> r) async {
    final ctl = TextEditingController(text: _fmtQty(r['qty']));
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.bgElevated,
        title: const Text('改这一趟的数量',
            style: TextStyle(color: AppColors.text, fontSize: 16)),
        content: TextField(
          key: const Key('simple-qty-input'),
          controller: ctl,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          style: const TextStyle(color: AppColors.text, fontSize: 15),
          decoration: const InputDecoration(labelText: '数量'),
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
    final err = SimpleRules.qtyError(v);
    if (err != null) {
      _snack(err);
      return;
    }
    try {
      await _repo.setQty(_intOf(r['id']), SimpleRules.parseQty(v)!);
      await _reload();
    } catch (e) {
      _snack('保存失败：$e');
    }
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

  // ============================================================
  // 完成本趟 / 撤销
  // ============================================================

  Future<void> _submitNode() async {
    if (_rows.isEmpty) {
      _snack('这一趟还没有记到东西，先扫几条再完成');
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.bgElevated,
        title: const Text('完成本趟？',
            style: TextStyle(color: AppColors.text, fontSize: 16)),
        content: Text(
          '${SimplePhase.tripLabel(SimplePhase.first)}：'
          '记了 ${_nodeTally.rows} 个品。\n'
          '完成后本趟就锁死，不能再改（可以撤销）。',
          style: const TextStyle(color: AppColors.textSub, fontSize: 14),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('再扫一会儿')),
          TextButton(
              key: const Key('simple-submit-ok'),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('完成本趟',
                  style: TextStyle(
                      color: AppColors.brand, fontWeight: FontWeight.w600))),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _repo.submitNode(_nodeNo);
      await _reload();
      _snack('已完成本趟：$_nodeNo');
    } catch (e) {
      _snack('完成失败：$e');
    }
  }

  Future<void> _reopenNode() async {
    try {
      await _repo.reopenNode(_nodeNo);
      await _reload();
      _snack('已撤销，可以继续扫');
    } catch (e) {
      _snack('撤销失败：$e');
    }
  }

  // ============================================================
  // 导出
  // ============================================================

  Future<void> _export() async {
    if (_task == null) {
      _snack('还没有盘点任务，先导入一份清单');
      return;
    }
    if (_node == null) {
      _snack('这一轮没有可导出的趟次');
      return;
    }
    setState(() => _busy = true);
    try {
      // 🔴 数量取哪一趟的，是这一版最要紧的一处口径：
      //   · 差异复盘做完（或正在做第三趟）→ 取**合并后的最终数**
      //     （初盘 → 复盘覆盖 → 差异复盘只覆盖差异项，方案 §0「以差异复盘为准」）；
      //   · 否则取当前趟的数（就是员工眼前这一趟）。
      //   拿错了的表现很难发现：数字看着都正常，只是对不上的那几行用了旧数。
      final qty = (_thirdDone || SimplePhase.onlyDiffSet(_phase))
          ? await _repo.finalQtyMap(_taskNo)
          : await _repo.nodeQtyMap(_nodeNo);
      // 前两趟对不上、差异复盘又还没交 → 那批**不下结论**，
      // 进第 4 段「差异待复核」（数量留空）。放进段 1 等于拿一个没定的数当结论，
      // 放进段 2 写 0 更是错（它明明盘到了）。
      final pending = (_diffSet.isNotEmpty && !_thirdDone)
          ? _diffSet
          : const <String>{};

      // 段 3（清单外）尽量带上商档名字（龙哥 2026-10-06）：界面上这一行
      // 已经显示成商品名了，导出来却写"未知条码"没法对账。通常只有几条，
      // 逐个查本地表开销可忽略；查不到的仍然落"未知条码"占位。
      final inListCodes = _items
          .map((e) => (e['barcode'] ?? '').toString().trim())
          .where((c) => c.isNotEmpty)
          .toSet();
      final extraNames = <String, String>{};
      for (final code in qty.keys) {
        final c = code.trim();
        if (c.isEmpty || inListCodes.contains(c)) continue;
        try {
          final m = await StockMasterRepo.instance.lookupLocal(c);
          final n = (m?['name'] ?? '').toString().trim();
          if (n.isNotEmpty) extraNames[c] = n;
        } catch (_) {}
      }

      final segs = SimpleExport.build(
          items: _items, qty: qty, pending: pending, extraNames: extraNames);

      // 🔴 硬判据：清单里的每一条都必须落在"已确定"/"没盘到"/"待复核"里。
      //    不成立就说明有商品被悄悄丢掉了 —— 宁可挡住不让导，
      //    也不能发出一份"看着正常、其实少了几行"的对账单。
      if (!segs.accounted) {
        _snack('导出的行数对不上清单（清单 ${segs.importedCount} 条，'
            '已落位 ${segs.data.length + segs.missing.length + segs.pending.length} 条），'
            '先别导，找开发看');
        return;
      }

      final name = FileIo.safeName(
          SimpleExport.csvName(SimpleScene.label(_scene), _taskNo));
      final dir = await FileIo.dir();
      final f = File('${dir.path}${Platform.pathSeparator}$name');
      // UTF-8；BOM 由导出层负责（见 SimpleExport.toCsv）
      await f.writeAsString(SimpleExport.toCsv(segs));
      if (!mounted) return;
      await ExportFlow.show(context, f,
          rows: segs.totalRows, suggestName: name, onMessage: _snack);
    } catch (e) {
      if (!mounted) return;
      _snack('导出失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ============================================================
  // 历史趟次 / 历史轮次
  // ============================================================

  Future<void> _pickHistory() async {
    List<Map<String, dynamic>> nodes = const <Map<String, dynamic>>[];
    List<Map<String, dynamic>> tasks = const <Map<String, dynamic>>[];
    try {
      if (_taskNo.isNotEmpty) nodes = await _repo.listNodes(_taskNo);
      tasks = await _repo.listTasks();
    } catch (e) {
      _snack('读历史失败：$e');
      return;
    }
    if (!mounted) return;

    final picked = await showModalBottomSheet<Map<String, String>>(
      context: context,
      backgroundColor: AppColors.bgElevated,
      builder: (ctx) => SafeArea(
        child: Column(
          key: const Key('simple-history'),
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 14, 16, 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('本轮的趟次',
                    style: TextStyle(
                        color: AppColors.text,
                        fontSize: 15,
                        fontWeight: FontWeight.w600)),
              ),
            ),
            if (nodes.isEmpty)
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 0, 16, 10),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text('还没有任何一趟',
                      style: TextStyle(color: AppColors.textWeak, fontSize: 13)),
                ),
              ),
            for (final n in nodes)
              ListTile(
                key: Key('simple-node-${n['sheet_no']}'),
                dense: true,
                title: Text(
                  '${SimplePhase.tripLabel(_intOf(n['phase']))}'
                  '${(n['sheet_no'] ?? '').toString() == _curNodeNo ? '（当前）' : ''}',
                  style: TextStyle(
                      color: (n['sheet_no'] ?? '').toString() == _curNodeNo
                          ? AppColors.brand
                          : AppColors.text,
                      fontSize: 14),
                ),
                subtitle: Text(
                  InvSheetStatus.label(_intOf(n['status'])),
                  style: const TextStyle(
                      color: AppColors.textSub, fontSize: 12),
                ),
                onTap: () => Navigator.pop(ctx, <String, String>{
                  'node': (n['sheet_no'] ?? '').toString(),
                }),
              ),
            const Divider(height: 1, color: AppColors.divider),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 12, 16, 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('历史轮次（换过清单的旧轮次都在这）',
                    style: TextStyle(
                        color: AppColors.text,
                        fontSize: 15,
                        fontWeight: FontWeight.w600)),
              ),
            ),
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: tasks.length,
                separatorBuilder: (_, __) =>
                    const Divider(height: 1, color: AppColors.divider),
                itemBuilder: (_, i) {
                  final t = tasks[i];
                  final no = (t['task_no'] ?? '').toString();
                  final isCur = no == _curTaskNo;
                  final st = _intOf(t['status']);
                  return ListTile(
                    key: Key('simple-task-$no'),
                    dense: true,
                    title: Text(isCur ? '$no（当前）' : no,
                        style: TextStyle(
                            color: isCur ? AppColors.brand : AppColors.text,
                            fontSize: 13)),
                    subtitle: Text(
                      '${SimpleScene.label((t['scene'] ?? '').toString())} · '
                      '${st == SimpleRepo.taskOpen ? '进行中' : '已归档'} · '
                      '已盘 ${_intOf(t['scanned'])} / ${_intOf(t['items'])}',
                      style: const TextStyle(
                          color: AppColors.textSub, fontSize: 12),
                    ),
                    onTap: () => Navigator.pop(ctx, <String, String>{
                      'task': no,
                    }),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
    if (picked == null) return;
    if (picked['task'] != null) {
      await _reload(loadTaskNo: picked['task']);
    } else if (picked['node'] != null) {
      await _reload(loadNodeNo: picked['node']);
    }
  }

  Future<void> _clearAll() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.bgElevated,
        title: const Text('清除本机全部简易盘点数据（不可恢复）',
            style: TextStyle(color: AppColors.text, fontSize: 16)),
        content: const Text(
          '会删掉本机**所有**轮的清单、趟次和扫码明细。\n'
          '「盘点」和「库房减货」的数据不受影响。\n'
          '没导出的明细删了就找不回来了。',
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
      _curTaskNo = null;
      _curNodeNo = null;
      await _reload();
      _snack('已清除 ${r['tasks']} 轮、${r['nodes']} 趟、${r['rows']} 行明细');
    } catch (e) {
      _snack('清除失败：$e');
    }
  }

  // ============================================================
  // UI
  // ============================================================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bgElevated,
        title: const Text('简易盘点',
            style: TextStyle(color: AppColors.text, fontSize: 17)),
        actions: [
          IconButton(
            key: const Key('simple-history-btn'),
            tooltip: '历史趟次',
            icon: const Icon(Icons.history, color: AppColors.textSub),
            onPressed: _busy ? null : _pickHistory,
          ),
          // 商档查询：扫一下商品，跳出商档里该商品的所有信息（龙哥 2026-10-03）。
          IconButton(
            key: const Key('open-master-lookup'),
            tooltip: '商档查询',
            icon: const Icon(Icons.qr_code_2_outlined,
                color: AppColors.textSub),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute<void>(
                  builder: (_) => const MasterLookupPage()),
            ),
          ),
          PopupMenuButton<String>(
            key: const Key('simple-menu'),
            icon: const Icon(Icons.more_vert, color: AppColors.textSub),
            onSelected: (v) {
              switch (v) {
                case 'reopen':
                  _reopenNode();
                  break;
                case 'template':
                  _downloadTemplate();
                  break;
                case 'clear':
                  _clearAll();
                  break;
              }
            },
            itemBuilder: (_) => <PopupMenuEntry<String>>[
              PopupMenuItem<String>(
                value: 'reopen',
                enabled: _node != null && !_editable,
                child: const Text('撤销本趟完成'),
              ),
              const PopupMenuItem<String>(
                value: 'template',
                child: Text('下载清单模板'),
              ),
              const PopupMenuItem<String>(
                value: 'clear',
                child: Text('清除本机简易盘点数据'),
              ),
            ],
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : !_hasTask
              ? _emptyState()
              : Column(
                  children: [
                    if (_error != null) _errorBar(_error!),
                    _header(),
                    _nodeBar(),
                    _inputBar(),
                    const Divider(height: 1, color: AppColors.divider),
                    _viewSwitch(),
                    // 🔴 表头**空列表也要画**：不画的话第一次进来的人整页
                    //    看不到列名，只会得出"这页没有这个功能"的结论。
                    if (_showPending) _pendingHeader() else _listHeader(),
                    Expanded(
                      child: _showPending ? _pendingList() : _recordedList(),
                    ),
                    _bottomBar(),
                  ],
                ),
    );
  }

  Widget _emptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.playlist_add, size: 46, color: AppColors.textWeak),
            const SizedBox(height: 12),
            const Text('请先导入这一轮要盘的商品清单（CSV）',
                key: Key('simple-empty-hint'),
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.text, fontSize: 15)),
            const SizedBox(height: 6),
            const Text('清单里要有商品条码（商品名称可以没有）。\n'
                '导进来以后一趟趟扫，最后导出一张全量盘点单。',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.textSub, fontSize: 13)),
            const SizedBox(height: 18),
            FilledButton(
              key: const Key('simple-import-empty'),
              onPressed: _busy ? null : _importFlow,
              style: FilledButton.styleFrom(backgroundColor: AppColors.brand),
              child: const Text('导入清单'),
            ),
            const SizedBox(height: 8),
            TextButton(
              key: const Key('simple-template-empty'),
              onPressed: _busy ? null : _downloadTemplate,
              child: const Text('先下载一份模板',
                  style: TextStyle(color: AppColors.textSub)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _errorBar(String msg) => Container(
        width: double.infinity,
        color: AppColors.danger.withValues(alpha: 0.15),
        padding: const EdgeInsets.all(12),
        child:
            Text(msg, style: const TextStyle(color: AppColors.danger, fontSize: 13)),
      );

  Widget _header() {
    final st = _intOf(_task?['status']);
    return Container(
      width: double.infinity,
      color: AppColors.bgElevated,
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(_taskNo,
                    key: const Key('simple-task-no'),
                    style: const TextStyle(
                        color: AppColors.text,
                        fontSize: 14,
                        fontWeight: FontWeight.w600)),
              ),
              // 场景标：仓库和卖场两个任务会**同时存在**，不标出来员工
              // 根本不知道自己现在盘的是哪个（两边的货和数都不一样）。
              Container(
                key: const Key('simple-scene-chip'),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: (_scene == SimpleScene.warehouse
                          ? AppColors.brand2
                          : AppColors.brand)
                      .withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  SimpleScene.label(_scene),
                  style: TextStyle(
                      fontSize: 12,
                      color: _scene == SimpleScene.warehouse
                          ? AppColors.brand2
                          : AppColors.brand),
                ),
              ),
            ],
          ),
          const SizedBox(height: 3),
          Text(
            '$_taskTitle　·　${st == SimpleRepo.taskOpen ? '进行中' : '已归档'}'
            '${_taskTally.scannedOffList > 0 ? '　·　清单外 ${_taskTally.scannedOffList} 个' : ''}',
            key: const Key('simple-task-name'),
            style: const TextStyle(color: AppColors.textSub, fontSize: 12),
          ),
          const SizedBox(height: 3),
          Text(_taskTally.progressText,
              key: const Key('simple-progress'),
              style: const TextStyle(
                  color: AppColors.text, fontSize: 14, fontWeight: FontWeight.w600)),
          if (st != SimpleRepo.taskOpen)
            const Padding(
              padding: EdgeInsets.only(top: 3),
              child: Text('这是已归档的一轮（只读）。要盘新的一轮请点下面「换一份清单」。',
                  style: TextStyle(color: AppColors.textWeak, fontSize: 12)),
            ),
        ],
      ),
    );
  }

  Widget _nodeBar() {
    final hasNode = _node != null;
    return Container(
      width: double.infinity,
      color: AppColors.bgElevated,
      padding: const EdgeInsets.fromLTRB(14, 0, 10, 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              hasNode
                  ? '${SimplePhase.tripLabel(_intOf(_node!['phase']))}'
                      '　记了 ${_nodeTally.rows} 个品'
                  : '这一轮还没有趟次',
              key: const Key('simple-node-label'),
              style: const TextStyle(color: AppColors.textSub, fontSize: 13),
            ),
          ),
          if (hasNode)
            _editable
                ? FilledButton(
                    key: const Key('simple-submit'),
                    onPressed: _busy ? null : _submitNode,
                    style: FilledButton.styleFrom(
                        backgroundColor: AppColors.brand,
                        visualDensity: VisualDensity.compact),
                    child: const Text('完成本趟'),
                  )
                : Container(
                    key: const Key('simple-submitted-chip'),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: AppColors.warn.withValues(alpha: 0.16),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '${InvSheetStatus.label(_intOf(_node!['status']))}（右上角可撤销）',
                      style: const TextStyle(color: AppColors.warn, fontSize: 12),
                    ),
                  ),
          // 本趟交完之后才给"开下一趟"。放在这一行而不是塞进菜单：
          // 三趟是这套流程的主线，藏起来等于让员工以为"盘完一趟就完了"。
          if (hasNode && !_editable && SimplePhase.next(_phase) != null)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: FilledButton(
                key: const Key('simple-next-trip'),
                onPressed: _busy ? null : _openNextTrip,
                style: FilledButton.styleFrom(
                    backgroundColor: AppColors.brand,
                    visualDensity: VisualDensity.compact),
                child: Text('开${SimplePhase.label(SimplePhase.next(_phase)!)}'),
              ),
            ),
        ],
      ),
    );
  }

  /// 开下一趟（初盘 → 复盘 → 差异复盘）。
  Future<void> _openNextTrip() async {
    final next = SimplePhase.next(_phase);
    if (next == null || _taskNo.isEmpty) return;
    setState(() => _busy = true);
    try {
      final n = await _repo.openOrCreateNode(_taskNo, next);
      final nodeNo = (n['sheet_no'] ?? '').toString();
      await _reload(loadNodeNo: nodeNo);
      if (!mounted) return;
      // 差异复盘要**明说**只扫哪几个：不说的话员工会对着"扫什么都被拒"发懵。
      final extra = SimplePhase.onlyDiffSet(next)
          ? '（只盘前两趟对不上的 ${_diffSet.length} 个品）'
          : '';
      _snack('已开「${SimplePhase.label(next)}」$extra');
    } on StateError catch (e) {
      // 仓库挡回来的（"前两趟完全一致，不用开差异复盘"这类）—— 是结论，不是故障
      if (!mounted) return;
      _snack(e.message.toString());
    } catch (e) {
      if (!mounted) return;
      _snack('开新的一趟失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _inputBar() {
    return Container(
      color: AppColors.bgElevated,
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: TextField(
              key: const Key('simple-barcode-input'),
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
              onSubmitted: (_) => _addScan(),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 74,
            child: TextField(
              key: const Key('simple-qty-field'),
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
              onSubmitted: (_) => _addScan(),
            ),
          ),
          const SizedBox(width: 8),
          // 摄像头扫码：手机端的另一条路 —— 没带扫码枪、也不该让员工
          // 在软键盘上手打 13 位条码。桌面端没有相机，直接不画。
          if (cameraScanSupported)
            IconButton(
              key: const Key('simple-camera'),
              tooltip: '摄像头扫码',
              icon: const Icon(Icons.qr_code_scanner, color: AppColors.brand),
              onPressed: (_editable && !_busy) ? _openCameraScan : null,
            ),
          const SizedBox(width: 8),
          FilledButton(
            key: const Key('simple-add'),
            onPressed: (_editable && !_busy) ? _addScan : null,
            style: FilledButton.styleFrom(backgroundColor: AppColors.brand),
            child: const Text('记一笔'),
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
                  key: Key('simple-col-barcode'), style: style)),
          Expanded(
              flex: 3, child: Text('商品', key: Key('simple-col-name'), style: style)),
          SizedBox(
              width: 66,
              child: Text('本趟数量', key: Key('simple-col-qty'), style: style)),
          SizedBox(
              width: 48,
              child: Text('操作', key: Key('simple-col-op'), style: style)),
        ],
      ),
    );
  }

  /// 「还没盘 / 本趟已录」切换。两个数字都常显 —— 盘到一半想回头核对
  /// 已录的，不该靠"再扫一遍"去翻。
  Widget _viewSwitch() {
    final pending = _pendingRows.length;
    final onlyDiff = SimplePhase.onlyDiffSet(_phase);
    return Container(
      color: AppColors.bgElevated,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Row(
        children: [
          ChoiceChip(
            key: const Key('simple-view-pending'),
            label: Text(onlyDiff ? '差异待盘 $pending' : '还没盘 $pending'),
            selected: _showPending,
            onSelected: (_) => setState(() => _showPending = true),
          ),
          const SizedBox(width: 8),
          ChoiceChip(
            key: const Key('simple-view-recorded'),
            label: Text('本趟已录 ${_nodeTally.rows}'),
            selected: !_showPending,
            onSelected: (_) => setState(() => _showPending = false),
          ),
        ],
      ),
    );
  }

  /// 未盘视图的列头（没有数量列 —— 还没盘的东西没有数）。
  Widget _pendingHeader() {
    const style = TextStyle(color: AppColors.textWeak, fontSize: 12);
    return Container(
      color: AppColors.bgElevated,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      child: const Row(
        children: [
          Expanded(
              flex: 4,
              child: Text('条码', key: Key('simple-col-barcode'), style: style)),
          Expanded(
              flex: 3,
              child: Text('商品', key: Key('simple-col-name'), style: style)),
          Expanded(
              child: Text('规格', key: Key('simple-col-spec'), style: style)),
        ],
      ),
    );
  }

  Widget _pendingList() {
    final rows = _pendingRows;
    if (rows.isEmpty) {
      final onlyDiff = SimplePhase.onlyDiffSet(_phase);
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            onlyDiff ? '对不上的都复核完了\n可以导出盘点数据单了' : '这一趟要盘的都盘到了\n可以点右上「完成本趟」',
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppColors.textWeak, fontSize: 14),
          ),
        ),
      );
    }
    return ListView.separated(
      itemCount: rows.length,
      separatorBuilder: (_, __) =>
          const Divider(height: 1, color: AppColors.divider),
      itemBuilder: (_, i) {
        final r = rows[i];
        final name = (r['name'] ?? '').toString().trim();
        final offList = name.isEmpty;
        return Container(
          key: Key('simple-pending-${r['barcode']}'),
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
                child: Text(offList ? '未录入计划' : name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color:
                            offList ? AppColors.warn : AppColors.textSub,
                        fontSize: 13)),
              ),
              Expanded(
                child: Text((r['spec'] ?? '').toString(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: AppColors.textWeak, fontSize: 12)),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _recordedList() {
    if (_rows.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            '这一趟还没记到东西\n扫一个条码开始',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.textWeak, fontSize: 14),
          ),
        ),
      );
    }
    return ListView.separated(
      itemCount: _rows.length,
      separatorBuilder: (_, __) =>
          const Divider(height: 1, color: AppColors.divider),
      itemBuilder: (_, i) => _rowTile(_rows[i]),
    );
  }

  Widget _rowTile(Map<String, dynamic> r) {
    final name = (r['name'] ?? '').toString().trim();
    final offList = name.isEmpty;
    return Container(
      // 行 key：测试要按**行数**断言（"被拒的扫码一行都没多写"）。
      key: Key('simple-row-${r['id']}'),
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
              // 清单外的（导入清单里查不到名字）直接说出来 ——
              // 这正是"它会被导进第三段"的那一类，员工当场就该看见。
              offList ? '未录入计划' : name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  color: offList ? AppColors.warn : AppColors.textSub,
                  fontSize: 13),
            ),
          ),
          SizedBox(
            width: 66,
            child: InkWell(
              onTap: _editable ? () => _editQty(r) : null,
              child: Text(
                _fmtQty(r['qty']),
                style: TextStyle(
                    color: _editable ? AppColors.brand : AppColors.text,
                    fontSize: 14,
                    fontWeight: FontWeight.w600),
              ),
            ),
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

  Widget _bottomBar() {
    return Container(
      color: AppColors.bgElevated,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            // 🔴 三个按钮**常显**：整页不能因为"没导入"就变成一个死页面。
            Expanded(
              child: TextButton(
                key: const Key('simple-history-bottom'),
                onPressed: _busy ? null : _pickHistory,
                child: const Text('历史趟次',
                    style: TextStyle(color: AppColors.textSub, fontSize: 13)),
              ),
            ),
            Expanded(
              child: TextButton(
                key: const Key('simple-export-bottom'),
                onPressed: _busy ? null : _export,
                child: const Text('导出盘点数据单',
                    style: TextStyle(color: AppColors.brand, fontSize: 13)),
              ),
            ),
            Expanded(
              child: TextButton(
                key: const Key('simple-change-list'),
                onPressed: _busy ? null : _importFlow,
                child: Text(
                    _taskTally.totalItems > 0 ? '换一份清单' : '导入清单',
                    style: const TextStyle(
                        color: AppColors.textSub, fontSize: 13)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 数量显示：整数不拖小数点（与导出、与「减货」同一口径）。
  static String _fmtQty(Object? v) {
    if (v == null) return '';
    final d = v is num ? v.toDouble() : double.tryParse(v.toString());
    if (d == null) return v.toString();
    return d == d.roundToDouble() ? d.toInt().toString() : d.toString();
  }
}
