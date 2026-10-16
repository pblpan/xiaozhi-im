import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/scan_dedup.dart';
import '../core/scan_feedback.dart';
import '../core/scan_sink.dart';
import '../core/stock_master_repo.dart';
import '../core/theme.dart';
import '../widgets/qty_edit.dart' show fmtQty;

/// 摄像头扫码只在手机上有意义。
/// `mobile_scanner` 的 Platform Support 是 Android/iOS/macOS/Web —— **没有 Windows**，
/// 桌面端（我们是 Windows）实例化 MobileScanner 会直接抛 UnimplementedError。
/// 所以入口必须按平台判断；页面里再兜一层，双保险。
bool get cameraScanSupported =>
    defaultTargetPlatform == TargetPlatform.android ||
    defaultTargetPlatform == TargetPlatform.iOS;

/// **通用**摄像头扫码页（扫码枪与盘点共用）。
///
/// ── 🔴 扫到之后必须停下等确认（确认制）─────────────────────────
/// 原来的行为是"连续扫"：扫到就落库、相机继续识别。现场用起来是这样的 ——
/// 员工扫完一件**没把商品移开**，相机对着同一个条码每秒上报十几帧，
/// 靠"同码冷却"压着；冷却一过就又记一件。表现是"我没动，件数自己往上涨"。
/// 这不是员工的问题，是交互的问题：**相机不知道你扫完了没有**。
///
/// 所以改成确认制：扫到一件 → 立刻屏蔽后续帧 → 弹确认卡 →
/// 必须点「继续扫」才恢复识别。件数只能由人按出来，不会自己涨。
///
/// ── 🔴 为什么不用 `DetectionSpeed.noDuplicates` ────────────────
/// 它在 mobile_scanner 里的语义是："同一个条码只会被扫到一次，
/// **直到扫到另一个条码之前都不会再报**"。
/// 而扫码最常见的动作恰恰是**连扫同一个商品的第 2 件、第 3 件** ——
/// 用 noDuplicates 会把这些件数**静默丢掉**：界面上什么都不发生，
/// 员工只会以为"软件坏了"，最后盘出来的数比实际少，而且不报任何错。
///
/// 所以仍然用 `DetectionSpeed.normal`（按 detectionTimeoutMs 反复上报），
/// 由 `kSameCodeCooldownMs` 做"同码冷却"（判据本体在 core/scan_dedup.dart，
/// 是纯函数、有独立单测）：
///   · 换成**另一个**条码 → 立刻计入（不受冷却影响）
///   · **同一个**条码在冷却期内反复上报 → 视为"相机还对着同一件"，不重复计
/// 「再记 1 件」按钮是唯一不依赖"手感"的出口，也覆盖"条码磨损读不出来"的情况。
class CameraScanPage extends StatefulWidget {
  const CameraScanPage({
    super.key,
    required this.title,
    required this.sheetNo,
    required this.sink,
    this.hint,
  });

  final String title;
  final String sheetNo;
  final ScanSink sink;

  /// 顶部提示语。不传用默认那句。
  final String? hint;

  @override
  State<CameraScanPage> createState() => _CameraScanPageState();
}

class _CameraScanPageState extends State<CameraScanPage> {
  late final MobileScannerController _cam = MobileScannerController(
    detectionSpeed: DetectionSpeed.normal,
    torchEnabled: false,
  );

  /// 同一个码在这个窗口内重复上报 = 相机还对着同一件，不重复计数。
  static const int _sameCodeCooldownMs = kSameCodeCooldownMs;

  static const _kConfirm = 'xz_scan_confirm_mode';
  static const _kCamRatio = 'xz_scan_cam_ratio';

  String? _lastCode;
  int _lastAcceptAt = 0;

  /// 🔴 落库是异步的。上一笔还没写完又来一笔，会并发写同一个 (单号, 条码) 行
  /// —— 结果是数量算错，而且**不报错**。所以整个写入过程用一个闸门串起来。
  bool _writing = false;

  /// 🔴 确认制闸门（判据本体在 core/scan_dedup.dart，纯类、有独立单测）。
  /// **这一个闸门就是"件数不会自己涨"的全部保证**：关上之后所有识别帧
  /// 一律丢弃 —— 相机照常出画面，但不会再入账。
  final ScanConfirmGate _gate = ScanConfirmGate();

  /// 相机区占页面高度的比例。默认偏小，把地方让给下面"扫了什么"的清单。
  double _camRatio = 0.36;

  int _sessionCount = 0;
  String? _lastMessage;
  Map<String, dynamic> _sum = const {};
  List<Map<String, dynamic>> _recent = const <Map<String, dynamic>>[];
  String? _error;

  /// 待确认的那一笔：确认制开着时，扫到先挂到这里等用户填数量，不立刻落库。
  final TextEditingController _qtyCtl = TextEditingController(text: '1');
  String? _pendingCode;
  double _pendingQty = 1;
  Map<String, dynamic>? _pendingMaster;
  /// 这一笔被业务拒绝（如不属于本盘点位）：保持确认卡显示拒绝原因。
  bool _pendingRejected = false;

  /// 扫码成功时取景框闪一下 —— 现场很吵、手机拿得远，没有这个反馈员工不确定扫上没有。
  /// **只有真的写进去了才闪**（被拒绝的扫码闪绿会训练出错误的直觉）。
  bool _flash = false;
  Timer? _flashTimer;

  @override
  void initState() {
    super.initState();
    unawaited(_loadPrefs());
    unawaited(_loadSum());
  }

  @override
  void dispose() {
    _flashTimer?.cancel();
    _qtyCtl.dispose();
    unawaited(_cam.dispose());
    super.dispose();
  }

  Future<void> _loadPrefs() async {
    try {
      final p = await SharedPreferences.getInstance();
      if (!mounted) return;
      setState(() {
        _gate.confirmMode = p.getBool(_kConfirm) ?? true;
        _camRatio = (p.getDouble(_kCamRatio) ?? 0.36).clamp(0.20, 0.70);
      });
    } catch (_) {}
  }

  Future<void> _setConfirmMode(bool v) async {
    // 关掉确认制时闸门会**同时开门**（见 ScanConfirmGate.setConfirmMode）：
    // 否则已经弹着确认卡、开关一关卡片就消失，"继续扫"再也点不到，
    // 页面直接卡死在这一笔上。
    setState(() => _gate.setConfirmMode(v));
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool(_kConfirm, v);
    } catch (_) {}
  }

  Future<void> _saveCamRatio() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setDouble(_kCamRatio, _camRatio);
    } catch (_) {}
  }

  Future<void> _loadSum() async {
    final s = await widget.sink.summary(widget.sheetNo);
    final r = await widget.sink.recent(widget.sheetNo);
    if (!mounted) return;
    setState(() {
      _sum = s;
      _recent = r;
    });
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    // 🔴 写入闸门 + 确认闸门。等确认期间一律不收：
    //    相机还在出画面，但不会再入账。
    if (!_gate.accept(writing: _writing)) return;

    // 一帧里可能同时识别出多个码；取第一个能用的。
    String? code;
    for (final b in capture.barcodes) {
      final v = b.rawValue?.trim();
      if (v != null && v.isNotEmpty) {
        code = v;
        break;
      }
    }
    if (code == null) return;

    final now = DateTime.now().millisecondsSinceEpoch;
    if (!shouldAcceptScan(
      code: code,
      lastCode: _lastCode,
      lastAcceptAt: _lastAcceptAt,
      now: now,
      cooldownMs: _sameCodeCooldownMs,
    )) {
      return; // 相机还对着同一件
    }
    await _onScan(code);
  }

  /// 扫到码后的统一入口。
  ///
  /// 确认制开着 → **先停、后确认**：不直接落库，把码先挂到确认卡上，
  /// 让用户当场填数量（直接输 9，不用点 9 下、更不用点了再减）。
  /// 确认制关着 → 直接落库 1 件（快速连扫模式，没有数量卡）。
  Future<void> _onScan(String code) async {
    if (_gate.confirmMode) {
      // 🔴 扫到这一刻就响（龙哥 2026-10-06）：声音/震动是"这一枪扫上没有"的
      //    确认信号，员工听到了才敢把商品移开去拿下一件。原来响在「确认录入」
      //    落库之后 —— 中间隔着看卡、改数量、点按钮，员工一直不确定扫没扫上，
      //    只好把同一件再扫一遍（件数就这么虚高了）。
      unawaited(ScanFeedbackService.I.ok());
      // 同步关门：防止这一帧到商档查询完成之间又进来一帧（同码被当两件）。
      final now = DateTime.now().millisecondsSinceEpoch;
      setState(() {
        _gate.onRecorded();
        _pendingCode = code;
        _pendingQty = 1;
        _qtyCtl.text = '1';
        _pendingMaster = null;
        _pendingRejected = false;
        _lastAcceptAt = now;
      });
      final master = await StockMasterRepo.instance.lookupLocal(code);
      if (!mounted) return;
      setState(() => _pendingMaster = master);
    } else {
      await _record(code, qty: 1);
    }
  }

  /// 「确认录入」：把确认卡上用户填好的数量真正落库。
  ///
  /// 被业务拒绝（如不属于本盘点位）时**不**放行：保持确认卡、显示拒绝原因，
  /// 等用户点「知道了」再继续 —— 否则他会以为记上了。
  Future<void> _commit() async {
    final code = _pendingCode;
    if (code == null) return;
    final fb = await _record(code, qty: _pendingQty);
    if (!mounted) return;
    if (fb.accepted) {
      _resume();
    } else {
      setState(() => _pendingRejected = true);
    }
  }

  /// 「继续扫」：放行下一帧。
  ///
  /// ⚠️ 冷却锚点必须在这里刷新：否则物品还没移开的话，
  /// "继续"的那一瞬间相机就又上报同一个码，等于刚点完就又弹一次确认卡。
  void _resume() {
    setState(() {
      _gate.resume();
      _pendingRejected = false;
    });
    _lastAcceptAt = DateTime.now().millisecondsSinceEpoch;
  }

  Future<ScanFeedback> _record(String code, {double qty = 1}) async {
    if (_writing) {
      return ScanFeedback(accepted: false, message: '正在写入上一笔');
    }
    _writing = true;
    try {
      final fb = await widget.sink.record(widget.sheetNo, code, qty: qty);
      if (!mounted) return fb;

      // 音反馈**先于界面**：声音是这条链路里延迟最低的一环，
      // 等 setState 把列表刷完再响，手感就"慢半拍"了。
      //
      // 🔴 确认制下"扫到"已经在 _onScan 响过一声了（龙哥 2026-10-06），
      //    这里只剩两种情况要响：
      //    · 落库被拒 → fail（员工得知道这笔没进去，不能让"嘀"了却没记上）
      //    · 确认制关（连扫）→ 成功 ok / 失败 fail：此时这一声就是"扫到了"本身
      //    确认制的成功笔**不再响** —— 再响一遍就是双响，员工会以为扫了两件。
      if (!fb.accepted) {
        unawaited(ScanFeedbackService.I.fail());
      } else if (!_gate.confirmMode) {
        unawaited(ScanFeedbackService.I.ok());
      }

      final s = await widget.sink.summary(widget.sheetNo);
      final recent = await widget.sink.recent(widget.sheetNo);
      if (!mounted) return fb;
      _lastCode = code;
      // ⚠️ 被拒绝的扫码**也要更新冷却锚点**：否则相机对着一个不该收的条码，
      //    每一帧都会重新走一次判定（连续弹同一条提示，界面像卡住了）。
      _lastAcceptAt = DateTime.now().millisecondsSinceEpoch;
      setState(() {
        _error = null;
        _sum = s;
        _recent = recent;
        _sessionCount += 1;
        _lastMessage = fb.message;
        // 🔴 确认制：这一笔记完关门（确认制关着时等于没关），等人工放行。
        _gate.onRecorded();
      });
      if (!fb.accepted) return fb;
      _flashTimer?.cancel();
      setState(() => _flash = true);
      _flashTimer = Timer(const Duration(milliseconds: 260), () {
        if (mounted) setState(() => _flash = false);
      });
      return fb;
    } catch (e) {
      if (!mounted) {
        return ScanFeedback(accepted: false, message: '写入失败：$e');
      }
      setState(() => _error = '写入失败：$e');
      return ScanFeedback(accepted: false, message: '写入失败：$e');
    } finally {
      _writing = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bgElevated,
        foregroundColor: AppColors.text,
        title: Text(widget.title, style: const TextStyle(fontSize: 17)),
        actions: [
          _soundToggle(),
          // 手电筒：货架背面、冷柜里光线很差，没有这个基本没法用。
          ValueListenableBuilder<MobileScannerState>(
            valueListenable: _cam,
            builder: (_, st, __) {
              final on = st.torchState == TorchState.on;
              return IconButton(
                tooltip: on ? '关手电' : '开手电',
                icon: Icon(
                  on ? Icons.flashlight_on : Icons.flashlight_off,
                  color: on ? AppColors.warn : AppColors.textSub,
                ),
                onPressed: () => _cam.toggleTorch(),
              );
            },
          ),
          IconButton(
            tooltip: '切换前后摄像头',
            icon:  Icon(Icons.cameraswitch_outlined,
                color: AppColors.textSub),
            onPressed: () => _cam.switchCamera(),
          ),
        ],
      ),
      body: SafeArea(
        // 上下分栏：上面相机（可拖小），下面"扫了什么"的清单（占大头）。
        //
        // ── 为什么不再是"相机铺满 + 底部浮一层" ──────────────────
        // 铺满的用法里，员工真正需要核对的东西（刚才扫了哪几件、各多少）
        // 被挤在屏幕最底下两行，得弯腰凑近看。而相机画面其实**不需要那么大** ——
        // 条码只要进框就行。把 2/3 的高度让给清单，扫错了当场就能发现。
        child: LayoutBuilder(
          builder: (ctx, c) {
            final total = c.maxHeight;
            final maxCam = (total - 140).clamp(80.0, total);
            final minCam = math.min(80.0, maxCam);
            final camH = (total * _camRatio).clamp(minCam, maxCam);
            return Column(
              children: <Widget>[
                SizedBox(height: camH, child: _cameraArea()),
                _divider(total),
                Expanded(child: _panel()),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _soundToggle() {
    final on = ScanFeedbackService.I.sound;
    return IconButton(
      key: const Key('cam-sound-toggle'),
      tooltip: on ? '关掉扫码提示音' : '打开扫码提示音',
      icon: Icon(
        on ? Icons.volume_up : Icons.volume_off,
        color: on ? AppColors.brand : AppColors.textWeak,
      ),
      onPressed: () async {
        await ScanFeedbackService.I.setSound(!on);
        if (mounted) setState(() {});
      },
    );
  }

  /// 相机区（含取景框与顶部提示）。
  Widget _cameraArea() => ColoredBox(
        color: Colors.black,
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            MobileScanner(
              controller: _cam,
              fit: BoxFit.cover,
              onDetect: _onDetect,
              errorBuilder: (_, e) => _cameraError(e),
              placeholderBuilder: (_) => const ColoredBox(
                color: Colors.black,
                child: Center(child: CircularProgressIndicator()),
              ),
            ),
            _scanWindow(),
            Positioned(top: 0, left: 0, right: 0, child: _topHint()),
          ],
        ),
      );

  /// 可上下拖动的分隔条：相机区想大就大、想小就小，位置会被记住。
  Widget _divider(double totalH) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onVerticalDragUpdate: (d) {
          if (totalH <= 0) return;
          setState(() {
            _camRatio = (_camRatio + d.delta.dy / totalH).clamp(0.20, 0.70);
          });
        },
        onVerticalDragEnd: (_) => unawaited(_saveCamRatio()),
        child: SizedBox(
          key: const Key('cam-divider'),
          height: 24,
          child: Center(
            child: Container(
              width: 56,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.textWeak,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        ),
      );

  /// 取景框。用半透明遮罩压暗框外区域，让"该把条码放哪"一眼就懂。
  ///
  /// 尺寸按相机区**比例**算：相机区被拖小时框跟着小，
  /// 写死 268×172 的话在矮相机区里框会顶出去，看着像坏了。
  Widget _scanWindow() {
    final frameColor = _flash ? AppColors.brand : Colors.white70;
    return IgnorePointer(
      child: Center(
        child: LayoutBuilder(
          builder: (_, c) {
            final w = (c.maxWidth * 0.78).clamp(120.0, 300.0);
            final h = (c.maxHeight * 0.58).clamp(76.0, 190.0);
            return SizedBox(
              width: w,
              height: h,
              child: Container(
                decoration: BoxDecoration(
                  border: Border.all(color: frameColor, width: _flash ? 4 : 2.5),
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: _flash
                      ? [
                          BoxShadow(
                            color: AppColors.brand.withValues(alpha: 0.55),
                            blurRadius: 22,
                            spreadRadius: 4,
                          ),
                        ]
                      : null,
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _topHint() => Container(
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
        color: Colors.black.withValues(alpha: 0.45),
        child: Text(
          _gate.awaiting
              ? '等确认 —— 移开商品，看下面的结果'
              : (_flash
                  ? '已记下 ✓'
                  : (widget.hint ?? '把条码对准框内，不用按任何键')),
          textAlign: TextAlign.center,
          style: TextStyle(
            color: _flash ? AppColors.brand : Colors.white,
            fontSize: 13,
            fontWeight: _flash ? FontWeight.w600 : FontWeight.normal,
          ),
        ),
      );

  Widget _panel() => DecoratedBox(
        decoration: BoxDecoration(color: AppColors.bg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _statBar(),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 6, 14, 0),
                child: Text(_error!,
                    style:
                        TextStyle(color: AppColors.danger, fontSize: 12)),
              ),
            if (_gate.awaiting) _confirmCard(),
            const SizedBox(height: 6),
            Expanded(child: _recentList()),
          ],
        ),
      );

  Widget _statBar() => Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
        child: Row(
          children: <Widget>[
            _stat('本次连扫', '$_sessionCount'),
            const SizedBox(width: 16),
            _stat('合计数量', fmtQty(_sum['total_qty'])),
            const SizedBox(width: 16),
            _stat('品种', '${_sum['kinds'] ?? 0}'),
            const Spacer(),
            // 确认制开关放在这里而不是设置页：这是**每一枪都要经过的判据**，
            // 员工得随时看得见它现在是开着还是关着。
            _chip(
              key: const Key('cam-confirm-toggle'),
              label: '确认制',
              icon: _gate.confirmMode
                  ? Icons.pan_tool_outlined
                  : Icons.all_inclusive,
              on: _gate.confirmMode,
              onTap: () => _setConfirmMode(!_gate.confirmMode),
            ),
            const SizedBox(width: 8),
            Text(
              widget.sheetNo,
              style: TextStyle(color: AppColors.textWeak, fontSize: 11),
            ),
          ],
        ),
      );

  Widget _chip({
    Key? key,
    required String label,
    required IconData icon,
    required bool on,
    required VoidCallback onTap,
  }) =>
      InkWell(
        key: key,
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: (on ? AppColors.brand : AppColors.textWeak)
                .withValues(alpha: on ? 0.16 : 0.08),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: (on ? AppColors.brand : AppColors.textWeak)
                  .withValues(alpha: 0.5),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(icon, size: 13, color: on ? AppColors.brand : AppColors.textWeak),
              const SizedBox(width: 4),
              Text(label,
                  style: TextStyle(
                      color: on ? AppColors.brand : AppColors.textWeak,
                      fontSize: 11)),
            ],
          ),
        ),
      );

  /// 确认卡：扫到一件之后就停在这里。
  ///
  /// ── 为什么必须有一个"停下来"的东西 ──────────────────────────
  /// 相机每秒上报十几帧，它自己不知道你扫完了没有。确认卡就是那个人为的
  /// "这件完了"信号（龙哥 2026-09-19 现场反馈）。
  ///
  /// ── 这一版改了什么（龙哥 2026-10-03）──────────────────────
  /// 原来只有「再记 1 件」按钮（连点 +1），要录 9 件得点 9 下、且点了不能减。
  /// 改成**直接输数量**：确认卡上给出一个数量步进器（可输入 / 可加减），
  /// 填好点「确认录入」一次落库，不用连点、也不用"点了再减"。
  Widget _confirmCard() {
    if (_pendingRejected) return _rejectedCard();
    return _pendingCard();
  }

  /// 待确认：显示商品 + 数量步进器，让用户直接填数量。
  Widget _pendingCard() {
    final code = _pendingCode ?? '';
    final master = _pendingMaster;
    final name = (master?['name'] ?? '').toString();
    final unknown = name.trim().isEmpty;
    final spec = (master?['spec'] ?? '').toString();
    final unit = (master?['unit'] ?? '').toString();
    // 供应商 / 价格三项（龙哥 2026-10-12：与扫码枪好又多版同款）。
    // 老商档这些列为 NULL，按"—"显示，不会崩。
    final supplier = (master?['supplier']?.toString() ?? '').trim();
    final purchaseRaw = master?['purchase_price'];
    final unitRaw = master?['unit_price'];
    final specialRaw = master?['special_price'];
    final title = unknown ? '未知条码' : name;
    final sub = unknown
        ? '$code　（商档里没有，仍可按未知条码录入）'
        : (spec.isNotEmpty ? '$code　$spec　$unit' : code);

    final accent = unknown ? AppColors.warn : AppColors.brand;
    return Container(
      key: const Key('cam-confirm-card'),
      margin: const EdgeInsets.fromLTRB(14, 0, 14, 8),
      padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(AppRadii.sm),
        border: Border.all(color: accent.withValues(alpha: 0.55)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(unknown ? Icons.help_outline : Icons.check_circle_outline,
                  size: 18, color: accent),
              const SizedBox(width: 8),
              Expanded(
                child: Text(title,
                    style:  TextStyle(
                        color: AppColors.text,
                        fontSize: 15,
                        fontWeight: FontWeight.w600),
                    overflow: TextOverflow.ellipsis),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(sub,
              style: TextStyle(color: AppColors.textSub, fontSize: 12),
              overflow: TextOverflow.ellipsis),
          // 供应商行（龙哥特意要的，红框区上面）+ 进价/售价/特价三项。
          if (!unknown && supplier.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                children: <Widget>[
                   Icon(Icons.store_outlined,
                      size: 14, color: AppColors.textSub),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text('供应商：$supplier',
                        style:  TextStyle(
                            color: AppColors.textSub, fontSize: 12),
                        overflow: TextOverflow.ellipsis),
                  ),
                ],
              ),
            ),
          if (!unknown)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: _masterPriceRow(purchaseRaw, unitRaw, specialRaw),
            ),
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
               Text('数量',
                  style: TextStyle(color: AppColors.text, fontSize: 14)),
              const Spacer(),
              _qtyStepper(),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              Expanded(
                child: SizedBox(
                  height: 38,
                  child: FilledButton(
                    key: const Key('cam-commit'),
                    onPressed: _commit,
                    child: const Text('确认录入', style: TextStyle(fontSize: 14)),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                height: 38,
                child: FilledButton.tonal(
                  key: const Key('cam-resume'),
                  onPressed: _resume,
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    backgroundColor: AppColors.surfaceHi,
                    foregroundColor: AppColors.textSub,
                  ),
                  child: const Text('重新扫', style: TextStyle(fontSize: 13)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 商档价格行：固定显示**进价 / 售价 / 特价**三项（龙哥 2026-10-12，
  /// 与扫码枪好又多版同款）。
  ///
  /// 特价为 0 / 没这列都显示「特价 —」（¥0.00 扎眼又不真实 —— 特价是
  /// "现在有活动"，不是"卖 0 元"）；进价/售价 0 极罕见，照实显示数字。
  Widget _masterPriceRow(dynamic purchase, dynamic unit, dynamic special) {
    double? toDouble(dynamic v) {
      if (v == null) return null;
      if (v is num) return v.toDouble();
      return double.tryParse(v.toString());
    }

    final pur = toDouble(purchase);
    final uni = toDouble(unit);
    final spe = toDouble(special);
    final speOff = spe == null || spe <= 0; // 没设特价
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      children: <Widget>[
        _priceChip('进价', pur),
        _priceChip('售价', uni),
        _priceChip('特价', speOff ? null : spe),
      ],
    );
  }

  Widget _priceChip(String label, double? v) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: AppColors.surfaceHi,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
            v == null ? '$label —' : '$label ¥${v.toStringAsFixed(2)}',
            style: TextStyle(color: AppColors.textSub, fontSize: 11)),
      );

  /// 数量步进器：可输入、可加减（龙哥 2026-10-03 要的"直接输数量"）。
  ///
  /// ±1 调整、可手输小数；最小值保护（不能为 0，要删用列表里的删除按钮）。
  Widget _qtyStepper() => Container(
        decoration: BoxDecoration(
          color: AppColors.surface,
          border: Border.all(color: AppColors.border),
          borderRadius: BorderRadius.circular(AppRadii.sm),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            IconButton(
              key: const Key('cam-qty-dec'),
              onPressed: _decQty,
              icon: const Icon(Icons.remove, size: 18),
              color: AppColors.textSub,
              constraints: const BoxConstraints(minWidth: 38, minHeight: 38),
              padding: EdgeInsets.zero,
            ),
            SizedBox(
              width: 48,
              child: TextField(
                key: const Key('cam-qty-input'),
                controller: _qtyCtl,
                textAlign: TextAlign.center,
                keyboardType: const TextInputType.numberWithOptions(
                    decimal: true, signed: false),
                style:  TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: AppColors.text),
                decoration: const InputDecoration(
                  border: InputBorder.none,
                  isCollapsed: true,
                  contentPadding: EdgeInsets.zero,
                ),
                onChanged: (v) {
                  final d = double.tryParse(v.trim());
                  if (d != null && d > 0) _pendingQty = d;
                },
              ),
            ),
            IconButton(
              key: const Key('cam-qty-inc'),
              onPressed: _incQty,
              icon: const Icon(Icons.add, size: 18),
              color: AppColors.textSub,
              constraints: const BoxConstraints(minWidth: 38, minHeight: 38),
              padding: EdgeInsets.zero,
            ),
          ],
        ),
      );

  void _decQty() => _setQty((_pendingQty - 1).clamp(0.01, double.infinity));
  void _incQty() => _setQty(_pendingQty + 1);

  void _setQty(double v) {
    _pendingQty = v;
    _qtyCtl.text = fmtQty(v);
    _qtyCtl.selection = TextSelection.fromPosition(
        TextPosition(offset: _qtyCtl.text.length));
    setState(() {});
  }

  /// 被业务拒绝时显示：说清原因，只给「知道了」放行。
  Widget _rejectedCard() {
    final message = _lastMessage ?? '这一笔没记上，请确认后再扫下一件';
    return Container(
      key: const Key('cam-confirm-card'),
      margin: const EdgeInsets.fromLTRB(14, 0, 14, 8),
      padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
      decoration: BoxDecoration(
        color: AppColors.danger.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(AppRadii.sm),
        border: Border.all(color: AppColors.danger.withValues(alpha: 0.55)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
           Row(
            children: <Widget>[
              Icon(Icons.block, size: 18, color: AppColors.danger),
              SizedBox(width: 8),
              Expanded(
                child: Text('这一笔没记上',
                    style: TextStyle(
                        color: AppColors.text,
                        fontSize: 15,
                        fontWeight: FontWeight.w600)),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(message,
              style: TextStyle(color: AppColors.textSub, fontSize: 12),
              overflow: TextOverflow.ellipsis),
          const SizedBox(height: 12),
          SizedBox(
            height: 38,
            child: FilledButton(
              key: const Key('cam-resume'),
              onPressed: _resume,
              child: const Text('知道了，重新扫',
                  style: TextStyle(fontSize: 14)),
            ),
          ),
        ],
      ),
    );
  }

  /// 最近扫到的清单。占信息区的绝大部分 —— 这是这一页**真正要看的东西**：
  /// 扫重了、扫错了、数量不对，都得在这里当场看出来。
  Widget _recentList() {
    if (_recent.isEmpty) {
      return  Center(
        child: Padding(
          padding: EdgeInsets.all(20),
          child: Text('还没扫到东西。\n把条码对准上面的框里。',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.textWeak, fontSize: 13)),
        ),
      );
    }
    return ListView.separated(
      key: const Key('cam-recent-list'),
      padding: const EdgeInsets.fromLTRB(6, 0, 6, 10),
      itemCount: _recent.length,
      separatorBuilder: (_, __) => const Divider(height: 1, indent: 14),
      itemBuilder: (_, i) => _recentTile(_recent[i], i + 1),
    );
  }

  Widget _recentTile(Map<String, dynamic> r, int no) {
    final name = (r['name'] ?? '').toString();
    final code = (r['barcode'] ?? '').toString();
    final qty = fmtQty(r['qty']);
    final t = _fmtTime(r['scanned_at']);
    final unknown = name.trim().isEmpty;
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      leading: CircleAvatar(
        radius: 14,
        backgroundColor: AppColors.brand.withValues(alpha: 0.14),
        child: Text('$no',
            style: TextStyle(fontSize: 11, color: AppColors.brand)),
      ),
      title: Text(unknown ? '未知条码' : name,
          style: TextStyle(
            color: unknown ? AppColors.warn : AppColors.text,
            fontSize: 14,
            fontWeight: FontWeight.w500,
          ),
          overflow: TextOverflow.ellipsis),
      subtitle: Text(t.isEmpty ? code : '$code　$t',
          style: TextStyle(color: AppColors.textWeak, fontSize: 11)),
      trailing: Text('×$qty',
          style:  TextStyle(
              color: AppColors.text, fontSize: 15, fontWeight: FontWeight.w600)),
    );
  }

  Widget _stat(String label, String value) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(label,
              style: TextStyle(color: AppColors.textWeak, fontSize: 10)),
          const SizedBox(height: 1),
          Text(value,
              style:  TextStyle(
                  color: AppColors.text,
                  fontSize: 16,
                  fontWeight: FontWeight.w600)),
        ],
      );

  static String _fmtTime(Object? v) {
    final ms = v is int ? v : int.tryParse('${v ?? ''}');
    if (ms == null || ms <= 0) return '';
    final t = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int x) => x.toString().padLeft(2, '0');
    return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  /// 相机起不来时的兜底。
  /// 员工看到的必须是一句人话 + 怎么自救，而不是一个异常堆栈。
  Widget _cameraError(MobileScannerException e) => ColoredBox(
        color: AppColors.bg,
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                 Icon(Icons.no_photography_outlined,
                    size: 40, color: AppColors.warn),
                const SizedBox(height: 12),
                 Text('摄像头打不开',
                    style: TextStyle(color: AppColors.text, fontSize: 15)),
                const SizedBox(height: 8),
                 Text(
                  '常见原因：\n'
                  '① 相机权限被拒绝 —— 到 手机设置 → 应用 → 小智IM → 权限 → 相机 打开\n'
                  '② 后置摄像头正被别的 App 占用 —— 关掉相机/视频通话类 App 再回来\n'
                  '\n'
                  '也可以先返回，改用扫码枪或手输条码。',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: AppColors.textSub, fontSize: 12, height: 1.6),
                ),
                const SizedBox(height: 10),
                Text(
                  '$e',
                  textAlign: TextAlign.center,
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: AppColors.textWeak, fontSize: 10),
                ),
              ],
            ),
          ),
        ),
      );
}
