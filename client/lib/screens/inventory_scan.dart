import 'package:flutter/material.dart';

import '../core/inventory_repo.dart';
import '../core/scan_sink.dart';
import 'camera_scan.dart';

/// 盘点：手机摄像头扫码页。
///
/// 相机机制全在 [CameraScanPage]（与扫码枪同一套）。这里只负责把
/// "扫到的码"接到盘点的**阶段化**入账上，并把判定结果翻成员工看得懂的话。
///
/// ── 盘点与扫码枪在扫码这件事上的关键差异 ─────────────────────────
/// 扫码枪扫什么都是入账（它没有点位和阶段，没什么可判的）；
/// 盘点**会拒绝**：复盘扫了不在差异集里的商品、抽盘扫了别的点位的商品，
/// 都不该记进去。拒绝必须让员工当场看见原因 ——
/// 否则他会以为"扫上了"，回头对账才发现那一件根本没盘。
class InventoryScanPage extends StatefulWidget {
  const InventoryScanPage({
    super.key,
    required this.sheetNo,
    required this.repo,
    this.locCode,
    this.phaseLabel,
  });

  final String sheetNo;
  final InventoryRepo repo;

  /// 当前货架位。扫进来的商品都会记上它 —— 这是盘点区别于扫条码的关键：
  /// "这个商品是在**哪儿**数出来的"。
  final String? locCode;

  /// 阶段名（初盘/复盘/抽盘），显示在标题上，防止员工串阶段。
  final String? phaseLabel;

  /// 摄像头扫码只在手机上有意义（桌面端 mobile_scanner 没有实现）。
  static bool get supported => cameraScanSupported;

  @override
  State<InventoryScanPage> createState() => _InventoryScanPageState();
}

class _InventoryScanPageState extends State<InventoryScanPage> {
  late final _InventorySink _sink = _InventorySink(
    widget.repo,
    locCode: widget.locCode,
  );

  @override
  Widget build(BuildContext context) => CameraScanPage(
        title: widget.phaseLabel == null
            ? '盘点扫码'
            : '盘点扫码 · ${widget.phaseLabel}',
        sheetNo: widget.sheetNo,
        sink: _sink,
        hint: widget.locCode == null || widget.locCode!.isEmpty
            ? '把条码对准框内，不用按任何键'
            : '货架位 ${widget.locCode}　把条码对准框内',
      );
}

/// 盘点的入账适配：一次扫码 = 一次 [InventoryRepo.scan]。
class _InventorySink implements ScanSink {
  _InventorySink(this.repo, {this.locCode});

  final InventoryRepo repo;
  final String? locCode;

  @override
  Future<ScanFeedback> record(String sheetNo, String code) async {
    final r = await repo.scan(sheetNo, code, locCode: locCode);

    // 被拒绝：把判定给的原因原样交出去（"本阶段只盘上一轮的差异商品"这种话
    // 必须一字不差地到员工眼前，界面不要自己另编一句）。
    if (!r.accepted) {
      return ScanFeedback(accepted: false, message: r.message);
    }

    final rows = await repo.listRows(sheetNo);
    final hit = rows.cast<Map<String, dynamic>?>().firstWhere(
          (x) => x != null && x['barcode'] == code,
          orElse: () => null,
        );

    return ScanFeedback(
      accepted: true,
      // accepted 时 message 只有一种情况非空：未绑定货架位的提醒。
      // 那是"记下了、但这件商品还没建货架位档案"，要给员工看见。
      message: r.message,
      hit: hit,
    );
  }

  @override
  Future<Map<String, dynamic>> summary(String sheetNo) =>
      repo.summary(sheetNo);

  @override
  Future<List<Map<String, dynamic>>> recent(String sheetNo,
      {int limit = 40}) async {
    final rows = await repo.listRows(sheetNo);
    return rows.take(limit).toList();
  }
}
