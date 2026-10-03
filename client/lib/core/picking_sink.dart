import 'picking_repo.dart';
import 'scan_sink.dart';

/// 拣货的扫码适配：把相机页扫到的码接到 [PickingRepo]。
///
/// 与扫码枪 / 盘点共用同一套相机机制（确认制、写入闸门、闪绿反馈，见
/// [CameraScanPage]）。这一层只负责"码 → 拣货行"：普通商品按确认卡上填的数量
/// 落库（生鲜秤码不在拣货场景里解，拣货是件/箱，不称）。
class PickingSink implements ScanSink {
  PickingSink(this.repo);

  final PickingRepo repo;

  @override
  Future<ScanFeedback> record(String sheetNo, String code,
      {double qty = 1}) async {
    await repo.addScan(sheetNo, code, qty: qty);
    final rows = await repo.listWithMaster(sheetNo);
    final hit = rows.cast<Map<String, dynamic>?>().firstWhere(
          (r) => r != null && r['barcode'] == code,
          orElse: () => null,
        );
    // 拣货没有"拒绝"概念（扫什么拣什么），永远 accepted；
    // 商档里没有的条码照样入账，只是品名空着（和扫码枪一个口径）。
    return ScanFeedback(
      accepted: true,
      message: null,
      hit: hit ?? <String, dynamic>{'barcode': code, 'qty': qty},
    );
  }

  @override
  Future<Map<String, dynamic>> summary(String sheetNo) =>
      repo.summary(sheetNo);

  @override
  Future<List<Map<String, dynamic>>> recent(String sheetNo,
      {int limit = 40}) async {
    final rows = await repo.listScans(sheetNo);
    return rows.take(limit).toList();
  }
}
