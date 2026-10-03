import 'stocktake_repo.dart';

/// 自由拣货单的本地仓库。
///
/// ── 为什么不复用 PD 单、而是单开前缀 ──────────────────────────────
/// 拣货和盘点（PD）都是"扫码 → 记一笔"的干活型作业，底层**共用同一张**
/// `scan_record` 流水表（见 StocktakeRepo 顶部说明）。区别只在**语义**：
///   · 盘点 = 数货（实盘 vs 账面）
///   · 拣货 = 把货从货架拣出来去配单
/// 两者单号段不能串：否则"继续上次没扫完的单"会把拣货单当成盘点单接着数，
/// 员工进去看到一堆拣货数据会以为坏了。所以这里只换前缀（'JK'），存储全复用。
///
/// ── 入口在哪 ─────────────────────────────────────────────────────
/// 拣货**不挂工作台图标**（龙哥 2026-10-03 明确要求"放在盘点里面，不独立"），
/// 入口是从「盘点」页右上角按钮 push 进来的（见 screens/inventory.dart 的
/// open-picking）。所以它**不在** `kBuiltinAppIds` 里——少一个内置应用就少四处登记。
class PickingRepo {
  /// 拣货单号前缀（拣 = jian，取 J；与减货/盘点都不撞）。
  static const String sheetPrefix = 'JK';

  static final PickingRepo instance = PickingRepo();

  final StocktakeRepo _repo = StocktakeRepo();

  /// 生成拣货单号：JK + yyyyMMdd + HHmmss。
  static String newSheetNo([DateTime? now]) =>
      StocktakeRepo.newSheetNo(now, sheetPrefix);

  /// 记一笔（同条码累加）。[qty] 来自扫码确认卡上填的数量。
  Future<int> addScan(String sheetNo, String barcode,
          {double qty = 1, String? note}) =>
      _repo.addScan(sheetNo, barcode, qty: qty, note: note);

  /// 直接改某笔数量（手输修正；传 0/负 = 删除该笔）。
  Future<void> setQty(int id, double qty) => _repo.setQty(id, qty);

  /// 删掉某笔。
  Future<int> deleteScan(int id) => _repo.deleteScan(id);

  /// 某张单的流水（最近在前）。
  Future<List<Map<String, dynamic>>> listScans(String sheetNo) =>
      _repo.listScans(sheetNo);

  /// 流水 **左连** 商品档案（名称/规格/单位/单价/账面），界面直接拿。
  Future<List<Map<String, dynamic>>> listWithMaster(String sheetNo) =>
      _repo.listWithMaster(sheetNo);

  /// 小结：品种数、总数量、未知条码数、未回传条数。
  Future<Map<String, dynamic>> summary(String sheetNo) =>
      _repo.summary(sheetNo);

  /// 本机已有的拣货单（最近在前），只认 JK 前缀。
  Future<List<Map<String, dynamic>>> listSheets() =>
      _repo.listSheets(prefix: sheetPrefix);

  /// 整单删除（拣错了重来）。
  Future<int> deleteSheet(String sheetNo) => _repo.deleteSheet(sheetNo);
}
