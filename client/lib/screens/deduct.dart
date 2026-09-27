import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api.dart';
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

  // ---------------- 参照数（上一轮盘点，见 _loadRef）----------------

  /// 当前显示的参照数，以及它是**为哪个条码**查的。
  ///
  /// 🔴 `_refBarcode` 一定要留着：请求是异步的，扫完一个码就立刻去查，
  ///    员工手快接着扫下一个码时，上一趟的请求可能后到 ——
  ///    没有这个判据的话，参照卡会显示成"扫的是 A、显示的是 B 的数"，
  ///    这种错最要命：看起来对，实际把人往沟里带。
  Map<String, dynamic>? _ref;
  String _refBarcode = '';
  bool _refLoading = false;
  Timer? _refTimer;

  @override
  void initState() {
    super.initState();
    _repo = widget.repo ?? DeductRepo();
    _reload();
  }

  @override
  void dispose() {
    _refTimer?.cancel();
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
    // 换单了（开新单 / 翻历史），上一个码的参照数就不成立了。
    _clearRef();
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

  /// 查这个条码的参照数（上一轮盘了多少 / 之前已经减了多少 / 还剩多少）。
  ///
  /// ── 为什么这是"减货"这一页唯一联网的动作 ──────────────────────
  /// 龙哥 2026-09-26 那句"库房减货不是盘点的一个流程吗"，把业务链讲清楚了：
  ///   **盘点 → 盘点完再拿货销售 → 账实对不上 → 用减货把已盘点的数往下减**
  /// 也就是说减货的判断依据**来自上一次盘点**。没有参照，现场就只剩一个
  /// 空白输入框，减多少凭印象 —— 减错了当场没人知道，等对账时才发现。
  ///
  /// ── 🔴 失败**不许拦人** ──────────────────────────────────────
  /// 库房常常在最里头，信号是有的没的。查不到参照只是少一条提示，
  /// 绝不能变成"先去盘一点才能减"——临时减货（破损/赠品出库）本来就不盘。
  /// 所以这里只静默留空，由界面自己决定 hide 参照卡。
  Future<void> _loadRef(String rawCode, {bool immediate = false}) async {
    final bc = rawCode.trim();
    // 空条码 / 非编辑态都不查：锁死之后查也没用，还会白白多几个请求。
    if (bc.isEmpty || !_editable) { _clearRef(); return; }

    _refTimer?.cancel();
    if (!immediate) {
      // 手输条码会一个字一个字地触发，每个字打一次接口是浪费（而且容易
      // 拿到慢回来的旧结果）。停手 500ms 再查。扫码枪是一次性的，不受影响。
      _refTimer = Timer(const Duration(milliseconds: 500), () => _loadRef(bc, immediate: true));
      return;
    }
    if (_refLoading) return;

    setState(() { _refLoading = true; _refBarcode = bc; });
    try {
      final api = ImApi();
      final d = await api.deductReference(bc);
      if (!mounted || _refBarcode != bc) return;   // 已经扫到下一个码了，丢掉
      setState(() => _ref = Map<String, dynamic>.from(d as Map));
    } catch (_) {
      // 没网 / 服务端没这套数据 —— 都当"没有参照"，界面 hide 卡片。
      if (!mounted || _refBarcode != bc) return;
      if (mounted) setState(() => _ref = null);
    } finally {
      if (mounted) setState(() => _refLoading = false);
    }
  }

  void _clearRef() {
    _refTimer?.cancel();
    if (_ref == null && _refBarcode.isEmpty) return;
    if (!mounted) return;
    setState(() { _ref = null; _refBarcode = ''; _refLoading = false; });
  }

  /// 是否"真的有参照数可显示"。
  ///
  /// 🔴 服务端 [`hasRef`] 为 false（且没带出商档账面数兜底）时，**不算有参照** ——
  /// 否则"没盘过、没减过"的码也会摊一张全是"—"的卡片，现场会被误读成
  /// "系统说这货有据可查"。判据：以服务端 `hasRef` 为主；当服务端**明确**
  /// `hasRef:false` 且连商档账面数 (`accountQty`) 都没有，才算"真没有"。
  bool get _hasRef {
    final ref = _ref;
    if (ref == null) return false;
    if (ref['hasRef'] == false && ref['accountQty'] == null) return false;
    return true;
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
      // 🔴 参照数是**扫完之后**带出来的：员工刚扫的这个码，上一轮盘了多少、
      //    之前已经减了多少、还剩多少 —— 下一个数该填多少，这里就是依据。
      await _loadRef(barcode, immediate: true);
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

  /// 上传这一单到管理台（对账用）。
  ///
  /// 🔴 两个"必须说出来"的地方，别省：
  ///   ① 409 `already_uploaded` 按成功归档本地，但**要说"没有覆盖服务端"** ——
  ///      静默当成功的话，万一本地这份和服务端那份不一样，用户永远不知道；
  ///   ② 服务端拒收的条数要说 —— 不然"传了 50 条、服务端只收 48 条"
  ///      在手机上看不出来，对账时才发现少了两个品。
  Future<void> _upload() async {
    final no = _sheetNo;
    if (no.isEmpty) {
      _snack('还没有减货单，先开一单');
      return;
    }
    setState(() => _busy = true);
    try {
      final payload = await _repo.uploadPayload(no);
      final rows = (payload['rows'] as List).cast<Map<String, dynamic>>();
      if (rows.isEmpty) {
        _snack('这一单一条减货记录都没有，没有可上传的数据');
        return;
      }
      // ImApi 是单例工厂（`factory ImApi() => _i`），随用随建，不用存字段
      final api = ImApi();
      final res = await api.uploadDeductSheet(
        sheetNo: no,
        rows: rows,
        startedAt: payload['started_at'] as int?,
      );
      // 🔴 只有服务端真的收下了才标本地已上传。
      //    标早了（比如放在 try 开头）会导致"手机显示已上传、服务端其实没有"。
      await _repo.markUploaded(no);
      await _reload(loadNo: no);
      if (!mounted) return;

      final rejected = (res['rejected'] as List?) ?? const <dynamic>[];
      final accepted = (res['accepted'] as num?)?.toInt() ?? rows.length;
      final buf = StringBuffer('已上传管理台，服务端收下 $accepted 条');
      if (rejected.isNotEmpty) buf.write('，拒收 ${rejected.length} 条');
      _snack(buf.toString());
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.code == 'already_uploaded') {
        await _repo.markUploaded(no);
        await _reload(loadNo: no);
        if (!mounted) return;
        _snack('服务端已有这张单，本次没有覆盖它；本地已记为已上传');
      } else if (e.isUnauthorized) {
        _snack('登录已失效，请重新登录后再上传');
      } else {
        _snack('上传失败：${e.message}');
      }
    } on StateError catch (e) {
      if (!mounted) return;
      // uploadPayload 抛的（"不存在" / "请先提交再上传"）—— 是人能改的事，直说。
      _snack(e.message.toString());
    } catch (e) {
      if (!mounted) return;
      _snack('上传失败：$e');
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
          // 上传是这一页**唯一会写服务端**的动作，放在 AppBar 上而不是塞进
          // 菜单里：龙哥踩过"功能藏在菜单里 = 找不到"，而对账全靠这一步。
          IconButton(
            key: const Key('deduct-upload'),
            tooltip: '上传管理台',
            icon: const Icon(Icons.cloud_upload_outlined, color: AppColors.textSub),
            onPressed: _busy ? null : _upload,
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
                case 'upload':
                  _upload();
                  break;
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
                value: 'upload',
                // 未提交的单**不给传**（理由见 DeductRepo.uploadPayload 的注释：
                // 传了半成品就再也传不上修改后的版本了）。
                enabled: !_editable,
                child: const Text('上传管理台'),
              ),
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
                _refCard(),
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
          // 龙哥 2026-09-26 的原话："库房减货不是盘点的一个流程吗？怎么独立成一个
          // 单独的功能了？" —— 它确实是分开的功能，但**依据来自盘点**。这里把那层
          // 关系写死在页面上（只在没有参照数时占一行），免得每次都得解释一遍。
          if (!_hasRef && !_loading)
            const Padding(
              padding: EdgeInsets.only(top: 2),
              child: Text(
                '减货不是盘点的下一步：盘点是数实际有多少，减货是拿货/损耗之后把账往下调',
                key: Key('deduct-flow-hint'),
                style: TextStyle(color: AppColors.textWeak, fontSize: 11),
              ),
            ),
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

  /// 参照卡：扫完一个码，把"上一轮盘点 / 之前已减 / 还剩多少"摊在眼前。
  ///
  /// 🔴 没查到（`_ref == null`）时必须**整块消失**，而不是留个"暂无数据"：
  ///    库房里没网是常态，留一块灰字会让人以为"这页坏了"。
  Widget _refCard() {
    final ref = _ref;
    if (ref == null || !_hasRef) {
      // 返回一个空盒子但**保住 key**：测试靠它断言"查不到时确实没画卡片"。
      // 🔴 `ref == null || !_hasRef`：① 请求失败（_ref=null）② 服务端
      //    `hasRef:false`（没盘过、没减过，但请求成功、_ref 不为 null 的"假有"）
      //    这两种都整块消失 —— 只判 null 会漏掉第二种，把全是"—"的卡片摊给现场看。
      return const SizedBox(width: double.infinity, height: 0, key: Key('deduct-ref-slot'));
    }

    final counted = ref['countedQty'] as num?;
    final deducted = (ref['deductedQty'] as num? ?? 0).toDouble();
    final remaining = ref['remaining'] as num?;
    final sheets = (ref['deductedSheets'] as num? ?? 0).toInt();
    final name = (ref['name'] ?? '').toString().trim();
    final spec = (ref['spec'] ?? '').toString().trim();
    final unit = (ref['unit'] ?? '').toString().trim();
    final code = ref['barcode']?.toString() ?? _refBarcode;

    // 账面数：**商品档案（商档）是底表**，没盘过也能带出来。
    //   盘过就用那一趟的快照（账面数会变，事后再拿新账面数比等于拿
    //   今天的尺子量上个月的布），所以这里要把**来源**说清楚 ——
    //   两个来源的数不一样时，员工得知道该信哪个。
    final account = ref['accountQty'] as num?;
    final fromCounted = (ref['accountFrom'] ?? '').toString() == 'counted';

    // 这次减多少 → 减完还剩多少。填了就现算，员工能对着实货核。
    final q = double.tryParse(_qtyCtl.text.trim());
    final left = (remaining != null && q != null) ? remaining.toDouble() - q : null;

    return Container(
      key: const Key('deduct-ref-card'),
      width: double.infinity,
      color: AppColors.bgElevated,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.history_edu, size: 14, color: AppColors.textSub),
              const SizedBox(width: 5),
              Text('参照',
                  style: const TextStyle(
                      color: AppColors.textSub, fontSize: 12, fontWeight: FontWeight.w600)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  () {
                    final parts = <String>[];
                    if (name.isNotEmpty) parts.add(name);
                    if (spec.isNotEmpty) parts.add(spec);
                    if (parts.isEmpty) parts.add(code);
                    return parts.join(' ');
                  }(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: AppColors.textWeak, fontSize: 12),
                ),
              ),
            ],
          ),
          // 账面数（商品档案共用）：没盘过的货也有，能立刻看出扫没扫错码
          if (account != null) ...[
            const SizedBox(height: 3),
            Text(
              '账面 ${DeductExport.fmtQty(account)}${unit.isNotEmpty ? ' $unit' : ''}'
              ' · ${fromCounted ? '上轮盘点时' : '商品档案'}',
              key: const Key('deduct-ref-account'),
              style: const TextStyle(color: AppColors.textSub, fontSize: 11),
            ),
          ],
          const SizedBox(height: 6),
          Row(
            children: [
              _refCell('deduct-ref-counted', '上一轮盘点',
                  counted != null ? DeductExport.fmtQty(counted) : '—',
                  counted != null),
              _refCell('deduct-ref-deducted', '这次之前已减',
                  deducted > 0 ? DeductExport.fmtQty(deducted) : '—',
                  deducted > 0,
                  sub: sheets > 1 ? '$sheets 张单' : null),
              _refCell('deduct-ref-left', '减完剩',
                  left != null
                      ? DeductExport.fmtQty(left)
                      : (remaining != null
                          ? DeductExport.fmtQty(remaining)
                          : '—'),
                  true,
                  strong: left != null),
            ],
          ),
          const SizedBox(height: 5),
          Text(
            remaining == null
                ? (account != null
                    ? '这个码还没盘过，账面数是商品档案里的；减货照样能做'
                    : '这个码没有盘过点参照（临时减货照样能减）；已减的是最近 ${(ref['windowDays'] ?? 30).toString()} 天')
                : '参照来自上一次盘点（减货是拿货/损耗之后把账往下调，不是盘点这一步）',
            style: const TextStyle(color: AppColors.textWeak, fontSize: 11),
          ),
        ],
      ),
    );
  }

  Widget _refCell(String key, String label, String value, bool has,
      {String? sub, bool strong = false}) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              key: Key(key + '-label'),
              style: const TextStyle(color: AppColors.textWeak, fontSize: 11)),
          const SizedBox(height: 1),
          Text(
            value,
            key: Key(key),
            style: TextStyle(
              color: !has
                  ? AppColors.textWeak
                  : strong
                      ? AppColors.brand
                      : AppColors.text,
              fontSize: 15,
              fontWeight: strong ? FontWeight.w700 : FontWeight.w600,
            ),
          ),
          if (sub != null)
            Text(sub, style: const TextStyle(color: AppColors.textWeak, fontSize: 10)),
        ],
      ),
    );
  }

  Widget _inputBar() {
    return Container(
      color: AppColors.bgElevated,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      child: Column(
        children: [
          Row(
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
                  // 手输的条码：停手 500ms 再查参照（见 _loadRef 的防抖）。
                  onChanged: (_) => _loadRef(_scanCtl.text),
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
                  onChanged: (_) {
                    // 改数量时即时刷新"减完剩"，不用等下一次扫码。
                    if (_ref != null && mounted) setState(() {});
                  },
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
