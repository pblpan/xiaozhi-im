import 'package:flutter/material.dart';

import '../core/scan_sink.dart';
import '../core/stocktake_repo.dart';
import 'camera_scan.dart';

/// 扫码枪：手机摄像头扫码页。
///
/// ── 这一页现在只是个"壳" ────────────────────────────────────────
/// 相机那套机制（去重判据、写入闸门、闪绿反馈、相机报错兜底）已经搬到
/// [CameraScanPage]，因为盘点（inventory）要用**一模一样**的一套 ——
/// 那几百行里最容易做错的正是这些不报错的判定，抄第二份等于给它留了
/// 第二条复活的路。
///
/// 这里剩下的是扫码枪**特有**的一点：把"扫到的码"接到 [StocktakeRepo] 上。
/// 构造签名与 `supported` 保持不变，调用方（采集页）不用动。
class StocktakeScanPage extends StatefulWidget {
  const StocktakeScanPage({
    super.key,
    required this.sheetNo,
    required this.repo,
  });

  final String sheetNo;
  final StocktakeRepo repo;

  /// 摄像头扫码只在手机上有意义（桌面端 mobile_scanner 没有实现）。
  static bool get supported => cameraScanSupported;

  @override
  State<StocktakeScanPage> createState() => _StocktakeScanPageState();
}

class _StocktakeScanPageState extends State<StocktakeScanPage> {
  late final _StocktakeSink _sink = _StocktakeSink(widget.repo);

  @override
  Widget build(BuildContext context) => CameraScanPage(
        title: '扫码枪',
        sheetNo: widget.sheetNo,
        sink: _sink,
      );
}

/// 把扫码枪的仓库适配成相机页认识的 [ScanSink]。
///
/// ── 一个刻意的差异 ──────────────────────────────────────────────
/// 扫码枪**不做任何准入判定**（它是"把条码扫成一笔账"的工具，
/// 没有点位、没有阶段，没什么可判的）。所以这里永远返回 accepted
/// —— 和它对盘点说的"该商品不属于本盘点位"完全是两回事。
class _StocktakeSink implements ScanSink {
  _StocktakeSink(this.repo);

  final StocktakeRepo repo;

  @override
  Future<ScanFeedback> record(String sheetNo, String code, {double qty = 1}) async {
    await repo.addScan(sheetNo, code, qty: qty);
    final rows = await repo.listWithMaster(sheetNo);
    return ScanFeedback(
      accepted: true,
      hit: rows.cast<Map<String, dynamic>?>().firstWhere(
            (r) => r != null && r['barcode'] == code,
            orElse: () => null,
          ),
    );
  }

  @override
  Future<Map<String, dynamic>> summary(String sheetNo) =>
      repo.summary(sheetNo);

  @override
  Future<List<Map<String, dynamic>>> recent(String sheetNo,
      {int limit = 40}) async {
    final rows = await repo.listWithMaster(sheetNo);
    return rows.take(limit).toList();
  }
}
