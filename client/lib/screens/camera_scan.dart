import 'dart:async';

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../core/scan_dedup.dart';
import '../core/scan_sink.dart';
import '../core/theme.dart';
import '../widgets/qty_edit.dart' show fmtQty;

/// 摄像头扫码只在手机上有意义。
/// `mobile_scanner` 的 Platform Support 是 Android/iOS/macOS/Web —— **没有 Windows**，
/// 桌面端（我们是 Windows）实例化 MobileScanner 会直接抛 UnimplementedError。
/// 所以入口必须按平台判断；页面里再兜一层，双保险。
bool get cameraScanSupported =>
    defaultTargetPlatform == TargetPlatform.android ||
    defaultTargetPlatform == TargetPlatform.iOS;

/// **通用**摄像头连续扫码页（扫码枪与盘点共用）。
///
/// ── 为什么扫到不停下来确认 ──────────────────────────────────────
/// 扫码是一格一格过的连贯动作。每扫一件都弹一次"确认？"会让整件事慢一个量级。
/// 所以这里是**连续扫**：扫到就落库，底部给即时反馈，员工一路扫到扫完。
///
/// ── 🔴 去重策略（本页最容易做错的地方）──────────────────────────
/// **绝对不能用 `DetectionSpeed.noDuplicates`。** 它在 mobile_scanner 里的语义是：
///   "同一个条码只会被扫到一次，**直到扫到另一个条码之前都不会再报**"。
/// 而扫码最常见的动作恰恰是**连扫同一个商品的第 2 件、第 3 件** ——
/// 用 noDuplicates 会把这些件数**静默丢掉**：界面上什么都不发生，
/// 员工只会以为"软件坏了"，最后盘出来的数比实际少，而且不报任何错。
///
/// 这里改用 `DetectionSpeed.normal`（按 detectionTimeoutMs 反复上报），
/// 再由 `kSameCodeCooldownMs` 做"同码冷却"（判据本体在 core/scan_dedup.dart，
/// 是纯函数、有独立单测）：
///   · 换成**另一个**条码 → 立刻计入（不受冷却影响）
///   · **同一个**条码在冷却期内反复上报 → 视为"相机还对着同一件"，不重复计
///   · 冷却过了再对同一个码 → 正常计入（第二件、第三件）
/// 再加一个显式的「再记 1 件」按钮兜底：这是唯一不依赖"手感"的出口，
/// 也顺手覆盖了"这一件条码磨损、相机读不出来"的情况。
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

  String? _lastCode;
  int _lastAcceptAt = 0;

  /// 🔴 落库是异步的。上一笔还没写完又来一笔，会并发写同一个 (单号, 条码) 行
  /// —— 结果是数量算错，而且**不报错**。所以整个写入过程用一个闸门串起来。
  bool _writing = false;

  int _sessionCount = 0;
  Map<String, dynamic>? _lastHit;
  String? _lastMessage;
  bool _lastAccepted = true;
  Map<String, dynamic> _sum = const {};
  String? _error;

  /// 扫码成功时取景框闪一下 —— 现场很吵、手机拿得远，没有这个反馈员工不确定扫上没有。
  /// **只有真的写进去了才闪**（被拒绝的扫码闪绿会训练出错误的直觉）。
  bool _flash = false;
  Timer? _flashTimer;

  @override
  void initState() {
    super.initState();
    unawaited(_loadSum());
  }

  @override
  void dispose() {
    _flashTimer?.cancel();
    unawaited(_cam.dispose());
    super.dispose();
  }

  Future<void> _loadSum() async {
    final s = await widget.sink.summary(widget.sheetNo);
    if (!mounted) return;
    setState(() => _sum = s);
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_writing) return;

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
    await _record(code);
  }

  /// 「再记 1 件」：对刚扫过的那个码再加一件。
  Future<void> _addAgain() async {
    final code = _lastCode;
    if (code == null) return;
    _lastAcceptAt = 0; // 手动加不参与冷却
    await _record(code);
  }

  Future<void> _record(String code) async {
    if (_writing) return;
    _writing = true;
    try {
      final fb = await widget.sink.record(widget.sheetNo, code);
      final s = await widget.sink.summary(widget.sheetNo);
      if (!mounted) return;
      _lastCode = code;
      // ⚠️ 被拒绝的扫码**也要更新冷却锚点**：否则相机对着一个不该收的条码，
      //    每一帧都会重新走一次判定（连续弹同一条提示，界面像卡住了）。
      _lastAcceptAt = DateTime.now().millisecondsSinceEpoch;
      setState(() {
        _error = null;
        _sum = s;
        _sessionCount += 1;
        _lastAccepted = fb.accepted;
        _lastMessage = fb.message;
        _lastHit = fb.hit;
      });
      if (!fb.accepted) return;
      _flashTimer?.cancel();
      setState(() => _flash = true);
      _flashTimer = Timer(const Duration(milliseconds: 260), () {
        if (mounted) setState(() => _flash = false);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '写入失败：$e');
    } finally {
      _writing = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: AppColors.bgElevated,
        foregroundColor: AppColors.text,
        title: Text(widget.title, style: const TextStyle(fontSize: 17)),
        actions: [
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
            icon: const Icon(Icons.cameraswitch_outlined,
                color: AppColors.textSub),
            onPressed: () => _cam.switchCamera(),
          ),
        ],
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
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
          Positioned(left: 0, right: 0, bottom: 0, child: _panel()),
        ],
      ),
    );
  }

  /// 取景框。用半透明遮罩压暗框外区域，让"该把条码放哪"一眼就懂。
  Widget _scanWindow() {
    final frameColor = _flash ? AppColors.brand : Colors.white70;
    return IgnorePointer(
      child: Center(
        child: Container(
          width: 268,
          height: 172,
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
      ),
    );
  }

  Widget _topHint() => Container(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
        color: Colors.black.withValues(alpha: 0.45),
        child: Text(
          _flash
              ? '已记下 ✓'
              : (widget.hint ?? '把条码对准框内，不用按任何键'),
          textAlign: TextAlign.center,
          style: TextStyle(
            color: _flash ? AppColors.brand : Colors.white,
            fontSize: 13,
            fontWeight: _flash ? FontWeight.w600 : FontWeight.normal,
          ),
        ),
      );

  Widget _panel() {
    final hit = _lastHit;
    final name = (hit?['name'] ?? '').toString();
    final unknown = hit != null && name.isEmpty;
    final qty = hit == null ? '0' : fmtQty(hit['qty']);

    // 四种状态，颜色分开：
    //   红 = 没记上（原因最重要，盖过其他一切）
    //   黄 = 记上了但有提醒（未知条码 / 未绑定货架位）
    //   绿 = 正常记上
    final nameLine = unknown
        ? '未知条码 ${hit['barcode']} × $qty（商档里没有）'
        : '$name × $qty';
    final noteColor = !_lastAccepted
        ? AppColors.danger
        : (unknown || _lastMessage != null ? AppColors.warn : AppColors.brand);
    final noteIcon = !_lastAccepted
        ? Icons.block
        : (hit == null
            ? Icons.qr_code_scanner
            : (unknown
                ? Icons.help_outline
                : (_lastMessage != null
                    ? Icons.info_outline
                    : Icons.check_circle_outline)));
    final noteText = !_lastAccepted
        ? (_lastMessage ?? '这一笔没有记上')
        : (hit == null
            ? (_lastMessage ?? '还没扫到东西')
            : (_lastMessage == null
                ? nameLine
                : '$nameLine　·　$_lastMessage'));

    return Container(
      color: AppColors.bgElevated.withValues(alpha: 0.96),
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_error != null) ...[
            Text(_error!,
                style: const TextStyle(color: AppColors.danger, fontSize: 12)),
            const SizedBox(height: 6),
          ],
          Row(
            children: [
              _stat('本次连扫', '$_sessionCount'),
              const SizedBox(width: 14),
              _stat('合计数量', fmtQty(_sum['total_qty'])),
              const SizedBox(width: 14),
              _stat('品种', '${_sum['kinds'] ?? 0}'),
              const Spacer(),
              Text(
                widget.sheetNo,
                style: const TextStyle(color: AppColors.textWeak, fontSize: 11),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: noteColor.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(AppRadii.sm),
            ),
            child: Row(
              children: [
                Icon(noteIcon, size: 16, color: noteColor),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    noteText,
                    style: const TextStyle(color: AppColors.text, fontSize: 13),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                // 「再记 1 件」是唯一不依赖手感的出口：同一个商品连扫第 N 件、
                // 或者条码磨损读不出来时，都靠它。
                SizedBox(
                  height: 32,
                  child: FilledButton.tonal(
                    onPressed: hit == null || !_lastAccepted ? null : _addAgain,
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      backgroundColor: AppColors.brand.withValues(alpha: 0.18),
                      foregroundColor: AppColors.brand,
                    ),
                    child: const Text('再记 1 件', style: TextStyle(fontSize: 12)),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            '同一个条码连续对着不会重复计数；要再记一件点右边按钮。',
            style: TextStyle(color: AppColors.textWeak, fontSize: 11),
          ),
        ],
      ),
    );
  }

  Widget _stat(String label, String value) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label,
              style: const TextStyle(color: AppColors.textWeak, fontSize: 10)),
          const SizedBox(height: 1),
          Text(value,
              style: const TextStyle(
                  color: AppColors.text,
                  fontSize: 16,
                  fontWeight: FontWeight.w600)),
        ],
      );

  /// 相机起不来时的兜底。
  /// 员工看到的必须是一句人话 + 怎么自救，而不是一个异常堆栈。
  Widget _cameraError(MobileScannerException e) => ColoredBox(
        color: AppColors.bg,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.no_photography_outlined,
                    size: 44, color: AppColors.warn),
                const SizedBox(height: 14),
                const Text('摄像头打不开',
                    style: TextStyle(color: AppColors.text, fontSize: 16)),
                const SizedBox(height: 10),
                const Text(
                  '常见原因：\n'
                  '① 相机权限被拒绝 —— 到 手机设置 → 应用 → 小智IM → 权限 → 相机 打开\n'
                  '② 后置摄像头正被别的 App 占用 —— 关掉相机/视频通话类 App 再回来\n'
                  '\n'
                  '也可以先返回，改用扫码枪或手输条码。',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: AppColors.textSub, fontSize: 12, height: 1.6),
                ),
                const SizedBox(height: 14),
                Text(
                  '$e',
                  textAlign: TextAlign.center,
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: AppColors.textWeak, fontSize: 10),
                ),
              ],
            ),
          ),
        ),
      );
}
