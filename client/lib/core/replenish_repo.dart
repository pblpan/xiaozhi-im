// 补货单的仓库层（本地 SQLite）。
//
// ── 和「库房减货」什么关系 ─────────────────────────────────
// 结构是同一套（共用 stocktake_sheet + scan_record，靠 sheet_type 区分），
// 业务方向相反：减货是**出库**（从库房减掉），补货是**上架**（补到货架）。
// 两边都是"扫一个码、给一个数量"，所以复用同样的表是最省事也最不容易漂移的做法。
//
// ── 场景（生鲜 / 杂百）存在哪 ──────────────────────────────
// 借 `stocktake_sheet.zone_code` 存场景值（'fresh' / 'dry'）。
// 🔴 减货那边的 zone_code 是 **null**（它不挂点位、也不分场景），
//    简易盘点那边借它存**任务号** —— 同一列被三种单据各借各的，
//    看着脏但比给每种单据加一列强：加列要动迁移，而这一列对这些单据
//    本来就没有"盘点位"的含义，空着也是空着。
//
// ── 单位（龙哥 2026-09-25 定，只有两套）─────────────────────
//   生鲜 = 公斤；杂百 = 最小单位。不做第三套。
//   判据在 `replenish_rules.dart`，这里只负责存取。

import 'inventory_rules.dart';
import 'local_db.dart';
import 'replenish_rules.dart';

class ReplenishRepo {
  ReplenishRepo({this.maxRows = ReplenishRules.maxRowsPerSheet});

  final int maxRows;

  /// 单号前缀。盘点 `INV-` / 减货 `JH-` / 补货 `BH-`，扫一眼就知道是哪类单。
  static const String sheetPrefix = 'BH-';

  /// 补货流水落在 scan_record 里的 phase 值（中性值，不是"初盘"）。
  static const int neutralPhase = 1;

  static String newSheetNo([DateTime? now]) {
    final d = now ?? DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '$sheetPrefix${d.year}${two(d.month)}${two(d.day)}'
        '${two(d.hour)}${two(d.minute)}${two(d.second)}';
  }

  static String _req(String v, String field) {
    final t = v.trim();
    if (t.isEmpty) throw ArgumentError.value(v, field, '$field 不能为空');
    return t;
  }

  // ---------------- 单据 ----------------

  /// 当前还开着的某一场景的补货单。
  ///
  /// 🔴 两个场景各允许一张进行中的单：生鲜和杂百是两拨人、两个区，
  ///    合成一张单的结果是生鲜的人往里扫公斤、杂百的人往里扫件数，
  ///    一张单里两种单位混着，谁也算不出合计。
  Future<Map<String, dynamic>?> openSheet(String scene) async {
    final db = await LocalDb.I.db();
    final rows = await db.query('stocktake_sheet',
        where: "sheet_type = ? and zone_code = ? and status = ?",
        whereArgs: <Object?>[
          InvSheetType.replenish,
          ReplenishScene.normalize(scene),
          InvSheetStatus.open,
        ],
        orderBy: 'started_at desc',
        limit: 1);
    return rows.isEmpty ? null : rows.first;
  }

  Future<Map<String, dynamic>> openOrCreate({
    required String scene,
    String? operator,
    bool forceNew = false,
  }) async {
    final sc = ReplenishScene.normalize(scene);
    if (!forceNew) {
      final exist = await openSheet(sc);
      if (exist != null) return exist;
    }

    final db = await LocalDb.I.db();
    final base = newSheetNo();
    var no = base;
    var guard = 0;
    while (true) {
      final rows = await db.query('stocktake_sheet',
          where: 'sheet_no = ?', whereArgs: <Object?>[no], limit: 1);
      if (rows.isEmpty) break;
      guard++;
      no = '${base}x$guard';
      if (guard > 50) throw StateError('单号连续撞车 50 次，检查系统时间是否异常');
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    await db.insert('stocktake_sheet', <String, Object?>{
      'sheet_no': no,
      'zone_code': sc, // 🔴 借来存场景，不是点位码（见文件头）
      'phase': neutralPhase,
      'status': InvSheetStatus.open,
      'operator': operator,
      'started_at': now,
      'sheet_type': InvSheetType.replenish,
    });
    return (await findSheet(no))!;
  }

  Future<Map<String, dynamic>?> findSheet(String sheetNo) async {
    final db = await LocalDb.I.db();
    final rows = await db.query('stocktake_sheet',
        where: 'sheet_no = ? and sheet_type = ?',
        whereArgs: <Object?>[sheetNo, InvSheetType.replenish],
        limit: 1);
    return rows.isEmpty ? null : rows.first;
  }

  Future<List<Map<String, dynamic>>> listSheets({int limit = 50}) async {
    final db = await LocalDb.I.db();
    return db.query('stocktake_sheet',
        where: 'sheet_type = ?',
        whereArgs: <Object?>[InvSheetType.replenish],
        orderBy: 'started_at desc',
        limit: limit);
  }

  /// 历史单（带条数与合计），喂给"切换单据"那个面板。用 SQL 聚合，不逐单查。
  Future<List<Map<String, dynamic>>> sheetBriefs({int limit = 50}) async {
    final db = await LocalDb.I.db();
    return db.rawQuery('''
      SELECT s.sheet_no, s.status, s.started_at, s.submitted_at, s.operator,
             s.zone_code AS scene,
             COUNT(r.id) AS rows,
             COALESCE(SUM(r.qty), 0) AS total_qty
      FROM stocktake_sheet s
      LEFT JOIN scan_record r ON r.sheet_no = s.sheet_no
      WHERE s.sheet_type = ?
      GROUP BY s.sheet_no
      ORDER BY s.started_at DESC
      LIMIT ?
    ''', <Object?>[InvSheetType.replenish, limit]);
  }

  // ---------------- 明细 ----------------

  /// 🔴 必须 LEFT JOIN 商档：账上没有的商品（新品、错码）恰恰要留在单子上，
  ///    INNER JOIN 会让它整行消失，而"少了一行"在明细里看不出来。
  Future<List<Map<String, dynamic>>> listRows(String sheetNo) async {
    final db = await LocalDb.I.db();
    return db.rawQuery('''
      SELECT r.id, r.sheet_no, r.barcode, r.qty, r.scanned_at, r.uploaded,
             m.name AS name, m.spec AS spec, m.unit AS unit
      FROM scan_record r
      LEFT JOIN stock_master m ON m.barcode = r.barcode
      WHERE r.sheet_no = ?
      ORDER BY r.id ASC
    ''', <Object?>[sheetNo]);
  }

  Future<Set<String>> existingBarcodes(String sheetNo) async {
    final db = await LocalDb.I.db();
    final rows = await db.query('scan_record',
        columns: <String>['barcode'],
        where: 'sheet_no = ?',
        whereArgs: <Object?>[sheetNo]);
    return rows.map((r) => (r['barcode'] ?? '').toString()).toSet();
  }

  /// 加一行。被拒时**不写库**并把理由回给界面。
  Future<ReplenishDecision> addRow({
    required String sheetNo,
    required String barcode,
    required String qtyRaw,
  }) async {
    final sheet = await findSheet(_req(sheetNo, 'sheetNo'));
    if (sheet == null) throw StateError('补货单 $sheetNo 不存在');

    final exists = await existingBarcodes(sheetNo);
    final rows = await listRows(sheetNo);
    final d = ReplenishRules.decide(
      sheetEditable: InvSheetStatus.editable(
          (sheet['status'] as num? ?? 0).toInt()),
      alreadyInSheet: exists.contains(barcode.trim()),
      rowCount: rows.length,
      maxRows: maxRows,
    );
    if (!d.accepted) return d;

    final qtyErr = ReplenishRules.qtyError(qtyRaw);
    if (qtyErr != null) {
      return ReplenishDecision(ReplenishVerdict.badQty, message: qtyErr);
    }

    final db = await LocalDb.I.db();
    await db.insert('scan_record', <String, Object?>{
      'sheet_no': sheetNo,
      'barcode': barcode.trim(),
      'qty': ReplenishRules.parseQty(qtyRaw)!,
      'scanned_at': DateTime.now().millisecondsSinceEpoch,
      'note': null,
      'uploaded': 0,
      'phase': neutralPhase,
      'loc_code': null,
    });
    return ReplenishDecision.ok;
  }

  Future<void> setQty(int id, double qty) async {
    final err = ReplenishRules.qtyError(qty.toString());
    if (err != null) throw ArgumentError.value(qty, 'qty', err);
    final db = await LocalDb.I.db();
    await db.update('scan_record', <String, Object?>{'qty': qty},
        where: 'id = ?', whereArgs: <Object?>[id]);
  }

  Future<int> deleteRow(int id) async {
    final db = await LocalDb.I.db();
    return db.delete('scan_record', where: 'id = ?', whereArgs: <Object?>[id]);
  }

  /// 汇总（品种数 / 主单位合计 / 折算公斤合计）。
  ///
  /// 场景决定主单位，所以必须传进来 —— 拿错了场景，公斤合计会整个不对，
  /// 而数字看着还是正常的（这是那种最难发现的错）。
  Future<ReplenishTally> summary(String sheetNo, String scene) async {
    final rows = await listRows(sheetNo);
    return ReplenishRules.tally(
      rows.map((r) => ReplenishRow(
            barcode: (r['barcode'] ?? '').toString(),
            qty: (r['qty'] as num? ?? 0).toDouble(),
            unitWeightKg: ReplenishRules.specWeightKg(
                (r['spec'] ?? '').toString()),
          )),
      scene: scene,
    );
  }

  // ---------------- 状态流转 ----------------

  Future<int> submitSheet(String sheetNo) async {
    final db = await LocalDb.I.db();
    return db.update(
        'stocktake_sheet',
        <String, Object?>{
          'status': InvSheetStatus.submitted,
          'submitted_at': DateTime.now().millisecondsSinceEpoch,
        },
        where: 'sheet_no = ? and sheet_type = ?',
        whereArgs: <Object?>[sheetNo, InvSheetType.replenish]);
  }

  Future<int> reopenSheet(String sheetNo) async {
    final db = await LocalDb.I.db();
    return db.update(
        'stocktake_sheet',
        <String, Object?>{'status': InvSheetStatus.open, 'submitted_at': null},
        where: 'sheet_no = ? and sheet_type = ?',
        whereArgs: <Object?>[sheetNo, InvSheetType.replenish]);
  }

  Future<void> deleteSheet(String sheetNo) async {
    final sheet = await findSheet(sheetNo);
    if (sheet == null) return;
    if ((sheet['status'] as num? ?? 0).toInt() != InvSheetStatus.open) {
      throw StateError('已提交的补货单不能删除，请先撤销提交');
    }
    final db = await LocalDb.I.db();
    await db.transaction((txn) async {
      await txn.delete('scan_record',
          where: 'sheet_no = ?', whereArgs: <Object?>[sheetNo]);
      await txn.delete('stocktake_sheet',
          where: 'sheet_no = ? and sheet_type = ?',
          whereArgs: <Object?>[sheetNo, InvSheetType.replenish]);
    });
  }

  /// 清空本地补货数据。返回删掉的【单 / 明细】条数。
  Future<Map<String, int>> clearAll() async {
    final db = await LocalDb.I.db();
    var sheets = 0;
    var rows = 0;
    await db.transaction((txn) async {
      final nos = (await txn.query('stocktake_sheet',
              columns: <String>['sheet_no'],
              where: 'sheet_type = ?',
              whereArgs: <Object?>[InvSheetType.replenish]))
          .map((r) => (r['sheet_no'] ?? '').toString())
          .toList();
      sheets = nos.length;
      for (final no in nos) {
        rows += await txn.delete('scan_record',
            where: 'sheet_no = ?', whereArgs: <Object?>[no]);
      }
      await txn.delete('stocktake_sheet',
          where: 'sheet_type = ?', whereArgs: <Object?>[InvSheetType.replenish]);
    });
    return <String, int>{'sheets': sheets, 'rows': rows};
  }
}
