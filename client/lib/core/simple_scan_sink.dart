/// 「简易盘点」的摄像头扫码适配（`ScanSink` 的第三家实现）。
///
/// ── 为什么必须走这一层 ──────────────────────────────────────────
/// 扫码枪（stocktake）和盘点（inventory）共用同一套相机机制
/// （`CameraScanPage`：去重判据、写入闸门、闪绿反馈、报错兜底）。
/// 简易盘点要的正是同一件事 —— **别再抄一份相机代码**：那几百行里
/// 最容易做错的全是"不报错的判定"，抄一份就是给
/// 「连扫同款件数被静默丢掉」「相机的码反复上报把数算虚高」
/// 各留一条复活的路。
///
/// ── 落库走谁 ────────────────────────────────────────────────────
/// 走 `SimpleRepo.scan`，和页面上手输条码**完全同一个入口**：
/// 同码累加、清单外放行、差异复盘只收差异集、行数上限 —— 这些判定
/// 全在仓库层的事务里。这里不许自己再判一遍：两处判定必然漂移，
/// 漂移的表现就是"手输能进、扫码进不去"（或反过来），现场没法解释。
///
/// 数量固定 1：摄像头一帧认一件，同码冷却挡"还对着同一件"，
/// 多件靠相机页自带的「再记 1 件」按钮 —— 与扫码枪/盘点同一口径。
import 'scan_sink.dart';
import 'simple_repo.dart';

class SimpleScanSink implements ScanSink {
  SimpleScanSink(this.repo, {this.allowedBarcodes});

  final SimpleRepo repo;

  /// 只有**差异复盘**那一趟才传（和页面手输同一规则：第三趟只收差异集）。
  /// 传 `null` = 本趟全量可扫（初盘/复盘）。
  final Set<String>? allowedBarcodes;

  @override
  Future<ScanFeedback> record(String sheetNo, String code, {double qty = 1}) async {
    final r = await repo.scan(sheetNo, code, qty: qty, allowedBarcodes: allowedBarcodes);
    return ScanFeedback(
      accepted: r.accepted,
      message: r.decision.message,
      // 相机页底部回显：accepted 才给 hit（拒绝的不能闪绿、不能显示数量）。
      hit: r.accepted
          ? <String, dynamic>{'barcode': code, 'qty': r.newQty ?? 1}
          : null,
    );
  }

  @override
  Future<Map<String, dynamic>> summary(String sheetNo) async {
    final t = await repo.nodeTally(sheetNo);
    return <String, dynamic>{'total_qty': t.totalQty, 'kinds': t.rows};
  }

  @override
  Future<List<Map<String, dynamic>>> recent(String sheetNo,
      {int limit = 40}) async {
    // listNodeRows 按 id 降序（刚扫的在最上面，与扫码枪/盘点同口径）。
    final rows = await repo.listNodeRows(sheetNo);
    return rows.take(limit).toList();
  }
}
