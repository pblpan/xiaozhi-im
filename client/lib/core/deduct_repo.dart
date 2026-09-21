// 库房减货单的仓库层（本地 SQLite）。
//
// ── 为什么不塞进 InventoryRepo ─────────────────────────────
// InventoryRepo 是"盘点"的仓库：点位、阶段、差异集、失误笔数。减货**一条都不用**。
// 塞进去的结果是两个业务的判据混在一个文件里，改减货时要在盘点的 1200 行里找位置，
// 而且很容易顺手复用到不该复用的方法（比如拿 phaseRows 去算减货汇总，永远算不对）。
//
// ── 和盘点共用什么 ─────────────────────────────────────────
// 共用**两张表**：stocktake_sheet（靠 sheet_type='deduct' 区分）与 scan_record。
// 这是刻意的（见 local_db.dart v3 迁移的注释）：单据/流水/提交/导出这四条链路
// 两边一模一样，各抄一套必然漂移。判别只在 sheet_no 上做，互不干扰。
//
// 🔴 减货**不看 phase**：它没有初盘/复盘的概念。写进 scan_record 时 phase 固定 1，
//    那是"这条列是 NOT NULL DEFAULT 1"的中性值，不是"初盘"。
//    以后谁写查询都别拿 phase 去分减货的行。

import 'deduct_rules.dart';
import 'inventory_rules.dart';
import 'local_db.dart';

class DeductRepo {
  /// [maxRows] 单张单的条数上限。生产用默认值（500）；**测试可以调小**
  /// （调到 2 就能验上限拦截，不用真灌 500 条）。
  /// 将来要按门店配置就从这里进来，不要在 SQL 或判定里写死数字。
  DeductRepo({this.maxRows = DeductRules.maxRowsPerSheet});

  final int maxRows;

  /// 单号前缀。盘点用 `INV-`，减货用 `JH-`，扫一眼就知道是哪类单。
  static const String sheetPrefix = 'JH-';

  /// 减货流水落在 scan_record 里的 phase 值（中性值，不是"初盘"）。
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

  /// 当前还开着的减货单（status=0）。
  ///
  /// 减货**同一时间只允许有一张进行中的单**：库房减货是一趟活，
  /// 同时开两张的结果是员工扫了一半换了个页面，货减了两遍而两张单看都正常。
  Future<Map<String, dynamic>?> openSheet() async {
    final db = await LocalDb.I.db();
    final rows = await db.query('stocktake_sheet',
        where: "sheet_type = ? and status = ?",
        whereArgs: <Object?>[InvSheetType.deduct, InvSheetStatus.open],
        orderBy: 'started_at desc',
        limit: 1);
    return rows.isEmpty ? null : rows.first;
  }

  /// 开单。**默认复用未完成的那张**（和盘点同一个道理：
  /// 一进来就开新单会让上次扫的数据"凭空消失"，员工以为丢了）。
  Future<Map<String, dynamic>> openOrCreate({
    String? operator,
    bool forceNew = false,
  }) async {
    if (!forceNew) {
      final exist = await openSheet();
      if (exist != null) return exist;
    }

    final db = await LocalDb.I.db();
    final base = newSheetNo();
    var no = base;
    var guard = 0;
    // 同一秒重开会撞号 → 挂序号，绝不让撞车变成"覆盖掉别人那张单"
    while (true) {
      final rows = await db.query('stocktake_sheet',
          where: 'sheet_no = ?', whereArgs: <Object?>[no], limit: 1);
      if (rows.isEmpty) break;
      guard++;
      no = '${base}x$guard';
      if (guard > 50) throw StateError('单号连续撞车 50 次，检查系统时间是否异常');
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    await db.insert('stocktake_sheet', {
      'sheet_no': no,
      'zone_code': null, // 减货不挂盘点位
      'phase': neutralPhase,
      'status': InvSheetStatus.open,
      'operator': operator,
      'started_at': now,
      'sheet_type': InvSheetType.deduct,
    });
    return (await findSheet(no))!;
  }

  Future<Map<String, dynamic>?> findSheet(String sheetNo) async {
    final db = await LocalDb.I.db();
    final rows = await db.query('stocktake_sheet',
        where: 'sheet_no = ? and sheet_type = ?',
        whereArgs: <Object?>[sheetNo, InvSheetType.deduct],
        limit: 1);
    return rows.isEmpty ? null : rows.first;
  }

  /// 减货单列表（最近的在前）。界面上要能翻历史单。
  Future<List<Map<String, dynamic>>> listSheets({int limit = 50}) async {
    final db = await LocalDb.I.db();
    return db.query('stocktake_sheet',
        where: 'sheet_type = ?',
        whereArgs: <Object?>[InvSheetType.deduct],
        orderBy: 'started_at desc',
        limit: limit);
  }

  /// 历史单（带条数与合计），喂给"切换单据"那个面板。
  ///
  /// 合计用 SQL 聚合，**不逐单去调 summary()** —— 那是 N+1 次查询，
  /// 单子攒到几十张以后打开面板会明显一顿一顿的（而且每次都全表扫 scan_record）。
  ///
  /// 条数用 `r.id` 数：`COUNT(*)` 在 LEFT JOIN 下会把"没有明细的单"算成 1 行。
  Future<List<Map<String, dynamic>>> sheetBriefs({int limit = 50}) async {
    final db = await LocalDb.I.db();
    return db.rawQuery('''
      SELECT s.sheet_no, s.status, s.started_at, s.submitted_at, s.operator,
             COUNT(r.id) AS rows,
             COALESCE(SUM(r.qty), 0) AS total_qty
      FROM stocktake_sheet s
      LEFT JOIN scan_record r ON r.sheet_no = s.sheet_no
      WHERE s.sheet_type = ?
      GROUP BY s.sheet_no
      ORDER BY s.started_at DESC
      LIMIT ?
    ''', <Object?>[InvSheetType.deduct, limit]);
  }

  // ---------------- 明细 ----------------

  Future<List<Map<String, dynamic>>> listRows(String sheetNo) async {
    final db = await LocalDb.I.db();
    // LEFT JOIN 商品档案：界面要显示商品名、导出要带规格与单位。
    //
    // 🔴 必须是 LEFT JOIN，不能 INNER：**账上没有这个商品**（新品、错码、
    //    别家货串进来）恰恰是最需要留在减货记录里的那种行 ——
    //    INNER JOIN 会让它整行消失，而"少了一行"在明细里根本看不出来。
    //    这和盘点侧"account_qty 为 NULL 是有效状态"是同一个道理。
    return db.rawQuery('''
      SELECT r.id, r.sheet_no, r.barcode, r.qty, r.scanned_at, r.uploaded,
             r.phase, r.loc_code,
             m.name AS name, m.spec AS spec, m.unit AS unit
      FROM scan_record r
      LEFT JOIN stock_master m ON m.barcode = r.barcode
      WHERE r.sheet_no = ?
      ORDER BY r.id ASC
    ''', <Object?>[sheetNo]);
  }

  /// 本单已有的条码（喂给 [DeductRules.decide] 用）。
  Future<Set<String>> existingBarcodes(String sheetNo) async {
    final db = await LocalDb.I.db();
    final rows = await db.query('scan_record',
        columns: <String>['barcode'],
        where: 'sheet_no = ?',
        whereArgs: <Object?>[sheetNo]);
    return rows.map((r) => (r['barcode'] ?? '').toString()).toSet();
  }

  /// 加一行。判定走 [DeductRules.decide]，被拒时**不写库**并把理由回给界面。
  Future<DeductDecision> addRow({
    required String sheetNo,
    required String barcode,
    required String qtyRaw,
  }) async {
    final sheet = await findSheet(_req(sheetNo, 'sheetNo'));
    if (sheet == null) throw StateError('减货单 $sheetNo 不存在');

    final exists = await existingBarcodes(sheetNo);
    final rows = await listRows(sheetNo);
    final d = DeductRules.decide(
      barcode: barcode,
      existingBarcodes: exists,
      sheetStatus: (sheet['status'] as num? ?? 0).toInt(),
      rowCount: rows.length,
      maxRows: maxRows,
    );
    if (!d.accepted) return d;

    // 数量校验放在准入之后：条码本身有问题（重复/读不到）时，
    // 先说条码的事 —— 同时甩两条错误，员工不知道该先改哪个。
    final qtyErr = DeductRules.qtyError(qtyRaw);
    if (qtyErr != null) {
      return DeductDecision(DeductVerdict.duplicate, message: qtyErr);
    }

    final db = await LocalDb.I.db();
    await db.insert('scan_record', {
      'sheet_no': sheetNo,
      'barcode': barcode.trim(),
      'qty': double.parse(qtyRaw.trim()),
      'scanned_at': DateTime.now().millisecondsSinceEpoch,
      'note': null,
      'uploaded': 0,
      'phase': neutralPhase,
      'loc_code': null,
    });
    return const DeductDecision(DeductVerdict.ok);
  }

  /// 改数量（列表里手改）。
  Future<void> setQty(int id, double qty) async {
    final err = DeductRules.qtyError(qty.toString());
    if (err != null) throw ArgumentError.value(qty, 'qty', err);
    final db = await LocalDb.I.db();
    await db.update('scan_record', {'qty': qty},
        where: 'id = ?', whereArgs: <Object?>[id]);
  }

  /// 删一行。**删除是重复条码唯一的解法** ——
  /// PG 那句"减货列表已存在，请处理后重新扫码"里的"处理"就是这个动作。
  Future<int> deleteRow(int id) async {
    final db = await LocalDb.I.db();
    return db.delete('scan_record', where: 'id = ?', whereArgs: <Object?>[id]);
  }

  /// 汇总（品种数 / 合计数量）。
  Future<DeductTally> summary(String sheetNo) async {
    final rows = await listRows(sheetNo);
    return DeductRules.tally(rows.map((r) => DeductRow(
          barcode: (r['barcode'] ?? '').toString(),
          qty: (r['qty'] as num? ?? 0).toDouble(),
        )));
  }

  // ---------------- 状态流转 ----------------

  Future<int> submitSheet(String sheetNo) async {
    final db = await LocalDb.I.db();
    return db.update(
        'stocktake_sheet',
        {
          'status': InvSheetStatus.submitted,
          'submitted_at': DateTime.now().millisecondsSinceEpoch,
        },
        where: 'sheet_no = ? and sheet_type = ?',
        whereArgs: <Object?>[sheetNo, InvSheetType.deduct]);
  }

  /// 撤销提交（库里那条 status 退回进行中）。
  /// 和盘点一样必须留着：交错了要能改回来，否则员工只能重扫一遍。
  Future<int> reopenSheet(String sheetNo) async {
    final db = await LocalDb.I.db();
    return db.update(
        'stocktake_sheet',
        {'status': InvSheetStatus.open, 'submitted_at': null},
        where: 'sheet_no = ? and sheet_type = ?',
        whereArgs: <Object?>[sheetNo, InvSheetType.deduct]);
  }

  /// 删单（连同明细）。只允许删**未提交**的 ——
  /// 已提交的单是"货已经减了"的凭据，删掉就没法回答"这批货谁减的"。
  Future<void> deleteSheet(String sheetNo) async {
    final sheet = await findSheet(sheetNo);
    if (sheet == null) return;
    if ((sheet['status'] as num? ?? 0).toInt() != InvSheetStatus.open) {
      throw StateError('已提交的减货单不能删除，请先撤销提交');
    }
    final db = await LocalDb.I.db();
    await db.transaction((txn) async {
      await txn.delete('scan_record',
          where: 'sheet_no = ?', whereArgs: <Object?>[sheetNo]);
      await txn.delete('stocktake_sheet',
          where: 'sheet_no = ? and sheet_type = ?',
          whereArgs: <Object?>[sheetNo, InvSheetType.deduct]);
    });
  }

  /// 清空本地减货数据（界面走在二次确认路径上）。
  /// 返回删掉的【单 / 明细】条数，界面要显示"清了几张单、几行"。
  Future<Map<String, int>> clearAll() async {
    final db = await LocalDb.I.db();
    var sheets = 0;
    var rows = 0;
    await db.transaction((txn) async {
      final nos = (await txn.query('stocktake_sheet',
              columns: <String>['sheet_no'],
              where: 'sheet_type = ?',
              whereArgs: <Object?>[InvSheetType.deduct]))
          .map((r) => (r['sheet_no'] ?? '').toString())
          .toList();
      sheets = nos.length;
      for (final no in nos) {
        rows += await txn.delete('scan_record',
            where: 'sheet_no = ?', whereArgs: <Object?>[no]);
      }
      await txn.delete('stocktake_sheet',
          where: 'sheet_type = ?', whereArgs: <Object?>[InvSheetType.deduct]);
    });
    return <String, int>{'sheets': sheets, 'rows': rows};
  }
}
