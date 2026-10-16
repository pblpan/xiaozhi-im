import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

/// 一次性扫码：扫到一个码就带着它返回（`Navigator.pop(code)`）。
///
/// ── 和 [CameraScanPage] 的分工 ──────────────────────────────────
/// 那边是"扫一个记一行"的流式作业页（盘点/减货，要连续扫几十件）；
/// 这边是"补一个码就走"的单点查询页（价签打印选商品、查商档）。
/// 硬把流式页改成单点会动到确认制/冷却/落库闸门，风险远大于新开一页。
///
/// 用 `DetectionSpeed.noDuplicates`：同一个码只上报一次，
/// 不用担心相机还对着同一件时回调风暴。
class QuickScanPage extends StatefulWidget {
  const QuickScanPage({super.key, required this.title, this.hint});

  final String title;

  /// 副标题提示。不传用默认那句。
  final String? hint;

  @override
  State<QuickScanPage> createState() => _QuickScanPageState();
}

class _QuickScanPageState extends State<QuickScanPage> {
  late final MobileScannerController _cam = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
    torchEnabled: false,
    facing: CameraFacing.back,
  );

  /// 扫到之后锁上，防同一帧重复 pop。
  bool _done = false;

  @override
  void dispose() {
    unawaited(_cam.dispose());
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_done) return;
    for (final b in capture.barcodes) {
      final v = b.rawValue?.trim();
      if (v != null && v.isNotEmpty) {
        _done = true;
        Navigator.pop(context, v);
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          ValueListenableBuilder(
            valueListenable: _cam,
            builder: (c, state, _) => IconButton(
              tooltip: state.torchState == TorchState.on ? '关手电筒' : '开手电筒',
              icon: Icon(state.torchState == TorchState.on
                  ? Icons.flash_on
                  : Icons.flash_off),
              onPressed: () => _cam.toggleTorch(),
            ),
          ),
        ],
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(
            controller: _cam,
            onDetect: _onDetect,
            errorBuilder: (c, e) => _ScanError(error: e),
          ),
          // 取景框：只框中间一条，别让整块屏幕都是"可识别区"——
          // 价签条码窄，全屏识别会把背景里的码也吃进来
          IgnorePointer(
            child: Center(
              child: Container(
                width: 260,
                height: 140,
                decoration: BoxDecoration(
                  border: Border.all(color: const Color(0xFF00E676), width: 2),
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            top: 24,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  widget.hint ?? '把条码放进框里就行',
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ScanError extends StatelessWidget {
  const _ScanError({required this.error});

  final MobileScannerException error;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.no_photography_outlined, size: 44),
            const SizedBox(height: 10),
            Text(
              '相机起不来：${error.errorCode.message}',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 6),
            Text(
              '到「设置 → 应用 → 权限」里给相机权限，再回来扫。',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
