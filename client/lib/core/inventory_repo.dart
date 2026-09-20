// 需要 ConflictAlgorithm（幂等绑定）和 Transaction（事务里复用清理逻辑）。
// sqflite 是**直接依赖**（见 pubspec 的离线地基那段），不是蹭进来的传递依赖。
import 'package:sqflite/sqflite.dart' show ConflictAlgorithm, Database, Transaction;

import 'inventory_rules.dart';
import 'local_db.dart';

/// 一笔扫码的结果：判定 + 落库后的行号与数量。
class InvScanResult {
  const InvScanResult(this.decision, {this.rowId, this.newQty});

  final ScanDecision decision;
  final int? rowId;
  final double? newQty;

  bool get accepted => decision.accepted;
  String? get message => decision.message;
  ScanVerdict get verdict => decision.verdict;
}

/// 盘点（inventory 模块）的本地仓库。
///
/// ── 和「扫码枪」（stocktake 模块）什么关系 ──────────────────────
/// **共用同一张 `scan_record` 流水表**（盘点只是多用了 phase / loc_code 两列），
/// 但单号前缀不同：扫码枪是 `PD...`，盘点是 `INV-...`。
/// 单号是天然的分区键 —— 两边都按前缀取自己的单，互不干扰。
/// ⚠️ 以后写任何"查所有单"的语句，**必须带前缀过滤**，否则两个模块的数据会串。
///
/// ── 离线 ────────────────────────────────────────────────────
/// 整个采集路径一次网络请求都不发（和扫码枪同样的理由：货架之间没信号）。
/// 服务端只在"上传"那一步介入。
class InventoryRepo {
  /// [maxRows] 单阶段条数上限。生产用默认值（500）；**测试可以调小**
  /// （调到 3 就能验上限拦截，不用真灌 500 条）；
  /// 将来如果要按门店配置，就从这里进来，不要在 SQL 里写死数字。
  InventoryRepo({this.maxRows = InventoryRules.maxRowsPerPhase});

  final int maxRows;

  /// 盘点单号前缀。**不要改成 'PD'** —— 那会和扫码枪撞在一起。
  static const String sheetPrefix = 'INV-';

  // ============================================================
  // 盘点位
  // ============================================================

  /// 新建或更新盘点位。[code] 是机器码（扫点位条码得到），[name] 是人看的名字。
  Future<void> saveZone({
    required String code,
    required String name,
    String? storeCode,
  }) async {
    final c = _req(code, 'zone_code');
    final n = name.trim().isEmpty ? c : name.trim();
    final db = await LocalDb.I.db();
    await db.insert(
      'stocktake_zone',
      <String, Object?>{
        'zone_code': c,
        'zone_name': n,
        'store_code': storeCode,
        // ⚠️ locked / created_at **不覆盖**：重复保存同一盘点位时
        //    把锁定状态清掉，等于"点一次保存就把锁解了"。
        'created_at': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
    // 名字可能改了，单独更新（ignore 分支不会更新已存在的行）。
    await db.update(
      'stocktake_zone',
      <String, Object?>{'zone_name': n, if (storeCode != null) 'store_code': storeCode},
      where: 'zone_code = ?',
      whereArgs: <Object?>[c],
    );
  }

  /// 全部盘点位，锁定的排后面（界面默认让你选还能用的）。
  Future<List<Map<String, dynamic>>> listZones() async {
    final db = await LocalDb.I.db();
    return db.rawQuery('''
      select z.zone_code, z.zone_name, z.store_code, z.locked, z.created_at,
             (select count(*) from location l where l.zone_code = z.zone_code) as loc_count,
             (select count(*) from stocktake_sheet s
               where s.zone_code = z.zone_code and s.status = 0)        as open_sheets
        from stocktake_zone z
       order by z.locked asc, z.zone_code asc
    ''');
  }

  Future<Map<String, dynamic>?> findZone(String code) async {
    final db = await LocalDb.I.db();
    final rows = await db.query('stocktake_zone',
        where: 'zone_code = ?', whereArgs: <Object?>[code.trim()], limit: 1);
    return rows.isEmpty ? null : rows.first;
  }

  /// 锁定 / 解锁。锁上以后 [openSheet] 会拒绝开单。
  ///
  /// 🔴 这是**人工**动作，不在"提交"里自动做。
  ///    方案文档把「盘点位锁定 / 解除锁定」列为独立交互项，说明它是一把
  ///    专门用来"封场"的锁（主管说这个区不要再盘了）；如果提交就自动锁，
  ///    初盘提交后连复盘都开不出来，只能反复解锁，那就没人会用它。
  Future<int> setZoneLocked(String code, bool locked) async {
    final db = await LocalDb.I.db();
    return db.update(
      'stocktake_zone',
      <String, Object?>{'locked': locked ? 1 : 0},
      where: 'zone_code = ?',
      whereArgs: <Object?>[code.trim()],
    );
  }

  /// 删除盘点位，**连同它的库位与商品绑定一起删**。
  ///
  /// 单独删点位会留下孤儿库位（界面上再也看不到、却还在影响
  /// "该商品属于哪个点位"的判定），所以这里在事务里一起清。
  /// 界面必须先二次确认（这一步不可逆）。
  Future<Map<String, int>> deleteZone(String code) async {
    final c = code.trim();
    final db = await LocalDb.I.db();
    return db.transaction((txn) async {
      final locs = await txn.query('location',
          columns: <String>['loc_code'], where: 'zone_code = ?', whereArgs: <Object?>[c]);
      final locCodes = locs.map((r) => r['loc_code'].toString()).toList();
      var bound = 0;
      if (locCodes.isNotEmpty) {
        final marks = List<String>.filled(locCodes.length, '?').join(',');
        bound = await txn.delete('barcode_location',
            where: 'loc_code in ($marks)', whereArgs: locCodes);
      }
      final loc = await txn.delete('location', where: 'zone_code = ?', whereArgs: <Object?>[c]);
      final purged = await _purgeSheetsOfZone(txn, c);
      final zone = await txn.delete('stocktake_zone', where: 'zone_code = ?', whereArgs: <Object?>[c]);
      return <String, int>{
        'zone': zone,
        'location': loc,
        'barcode_location': bound,
        'sheet': purged['sheet'] ?? 0,
        'scan_record': purged['scan_record'] ?? 0,
      };
    });
  }

  // ============================================================
  // 库位 / 货架位
  // ============================================================

  Future<void> saveLocation({
    required String locCode,
    required String zoneCode,
    String? name,
    int? sortNo,
  }) async {
    final lc = _req(locCode, 'loc_code');
    final zc = _req(zoneCode, 'zone_code');
    final db = await LocalDb.I.db();
    await db.insert(
      'location',
      <String, Object?>{
        'loc_code': lc,
        'loc_name': (name ?? '').trim().isEmpty ? lc : name!.trim(),
        'zone_code': zc,
        'sort_no': sortNo ?? 0,
        'created_at': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
    await db.update(
      'location',
      <String, Object?>{
        if (name != null && name.trim().isNotEmpty) 'loc_name': name.trim(),
        if (sortNo != null) 'sort_no': sortNo,
        'zone_code': zc,
      },
      where: 'loc_code = ?',
      whereArgs: <Object?>[lc],
    );
  }

  Future<List<Map<String, dynamic>>> listLocations(String zoneCode) async {
    final db = await LocalDb.I.db();
    return db.query('location',
        where: 'zone_code = ?',
        whereArgs: <Object?>[zoneCode.trim()],
        orderBy: 'sort_no asc, loc_code asc');
  }

  Future<Map<String, dynamic>?> findLocation(String locCode) async {
    final db = await LocalDb.I.db();
    final rows = await db.query('location',
        where: 'loc_code = ?', whereArgs: <Object?>[locCode.trim()], limit: 1);
    return rows.isEmpty ? null : rows.first;
  }

  /// 删除库位并解绑它的商品（不删商品档案，只断关系）。
  Future<Map<String, int>> deleteLocation(String locCode) async {
    final lc = locCode.trim();
    final db = await LocalDb.I.db();
    return db.transaction((txn) async {
      final bound = await txn.delete('barcode_location',
          where: 'loc_code = ?', whereArgs: <Object?>[lc]);
      final loc =
          await txn.delete('location', where: 'loc_code = ?', whereArgs: <Object?>[lc]);
      return <String, int>{'location': loc, 'barcode_location': bound};
    });
  }

  /// 该条码绑定的所有库位（带盘点位与名字，界面直接用）。
  Future<List<Map<String, dynamic>>> locationsOfBarcode(String barcode) async {
    final db = await LocalDb.I.db();
    return db.rawQuery('''
      select b.barcode, b.loc_code, b.bound_at,
             l.loc_name, l.zone_code, z.zone_name
        from barcode_location b
        left join location l on l.loc_code = b.loc_code
        left join stocktake_zone z on z.zone_code = l.zone_code
       where b.barcode = ?
       order by l.zone_code asc, l.sort_no asc, l.loc_code asc
    ''', <Object?>[barcode.trim()]);
  }

  /// 该条码所属的**盘点位**集合（没有绑定 = 空集合）。
  ///
  /// ⚠️ 空集合代表"这商品的货架位档案还没建"，不是"它不属于任何点位"。
  ///    判定逻辑里这两者必须区别对待（见 InventoryRules.decide）。
  Future<Set<String>> zonesOfBarcode(String barcode) async {
    final db = await LocalDb.I.db();
    final rows = await db.rawQuery('''
      select distinct l.zone_code as zone_code
        from barcode_location b
        join location l on l.loc_code = b.loc_code
       where b.barcode = ?
    ''', <Object?>[barcode.trim()]);
    return rows
        .map((r) => (r['zone_code'] ?? '').toString())
        .where((s) => s.isNotEmpty)
        .toSet();
  }

  /// 绑定 商品 ↔ 货架位。返回 1=新绑成功，0=本来就绑着（幂等）。
  ///
  /// 用 `ignore` 而不是让它抛：扫码绑定这条路上重复绑是**常态**
  /// （同一个货架位上的商品，员工每天都会扫一遍），抛异常就得在调用处
  /// 到处 try/catch，反而容易把真异常一起吞掉。
  Future<int> bindBarcode(String barcode, String locCode) async {
    final bc = _req(barcode, 'barcode');
    final lc = _req(locCode, 'loc_code');
    final db = await LocalDb.I.db();
    return db.insert(
      'barcode_location',
      <String, Object?>{
        'barcode': bc,
        'loc_code': lc,
        'bound_at': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  Future<int> unbindBarcode(String barcode, String locCode) async {
    final db = await LocalDb.I.db();
    return db.delete('barcode_location',
        where: 'barcode = ? and loc_code = ?',
        whereArgs: <Object?>[barcode.trim(), locCode.trim()]);
  }

  // ============================================================
  // 盘点单
  // ============================================================

  /// 单号：`INV-<点位>-<阶段>-<yyyyMMddHHmmss>`。
  ///
  /// 点位码可能带中文/斜杠（"生鲜区/3"），会直接把 CSV 文件名搞坏，
  /// 所以拼进单号前先洗成 `[A-Z0-9_]`。**单号只给人看** ——
  /// 程序要的 zone/phase 都从 `stocktake_sheet` 表里读，不靠反解单号。
  static String newSheetNo(String zoneCode, int phase, [DateTime? now]) {
    final d = now ?? DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final z = _sanitizeZone(zoneCode);
    return '$sheetPrefix$z-$phase-${d.year}${two(d.month)}${two(d.day)}'
        '${two(d.hour)}${two(d.minute)}${two(d.second)}';
  }

  static String _sanitizeZone(String zoneCode) {
    final s = zoneCode.trim().toUpperCase().replaceAll(RegExp(r'[^A-Z0-9_]'), '_');
    return s.isEmpty ? 'Z' : s;
  }

  /// 该点位该阶段**还开着的**单（用于"您在该盘点位有未完成数据，是否继续盘点？"）。
  Future<Map<String, dynamic>?> openSheetOf(String zoneCode, int phase) async {
    final db = await LocalDb.I.db();
    final rows = await db.query('stocktake_sheet',
        where: 'zone_code = ? and phase = ? and status = 0',
        whereArgs: <Object?>[zoneCode.trim(), phase],
        orderBy: 'started_at desc',
        limit: 1);
    return rows.isEmpty ? null : rows.first;
  }

  /// 开单。**默认复用未完成的那张**（不新建）——
  /// 一进来就开新单会让上次扫的数据"凭空消失"，员工会以为丢了。
  /// 真的要重开，传 [forceNew]（界面走在"清除缓存"那条二次确认路径上）。
  Future<Map<String, dynamic>> openSheet({
    required String zoneCode,
    required int phase,
    String? operator,
    bool forceNew = false,
  }) async {
    final zc = _req(zoneCode, 'zone_code');
    if (!InvPhase.isValid(phase)) {
      throw ArgumentError.value(phase, 'phase', '阶段只能是 1初盘/2复盘/3抽盘');
    }

    final zone = await findZone(zc);
    if (zone == null) {
      throw StateError('盘点位 $zc 不存在，请先建盘点位');
    }
    if ((zone['locked'] as num? ?? 0).toInt() != 0) {
      throw StateError('盘点位「${zone['zone_name'] ?? zc}」已锁定，请先解除锁定');
    }

    if (!forceNew) {
      final exist = await openSheetOf(zc, phase);
      if (exist != null) return exist;
    }

    final db = await LocalDb.I.db();
    // 基准单号只算一次：循环里再算会取到新时间，撞车判据就漂了。
    final base = newSheetNo(zc, phase);
    var no = base;
    // 撞车（不同点位洗出同一个串、同一秒又开一张）就在后面挂序号，
    // 绝不让"撞车"变成"覆盖掉别人那张单"。
    //
    // 🔴 这里**只负责找空号，不做复用判断** —— "要不要复用未完成单"上面
    //    `openSheetOf` 已经判过了。如果这里再顺手复用一次，会连带把
    //    **已提交**的单也复用掉（同一秒里重开，候选单号一模一样），
    //    界面上表现为"点了重开，还是那张锁着的单"。
    var guard = 0;
    while (true) {
      final rows = await db.query('stocktake_sheet',
          where: 'sheet_no = ?', whereArgs: <Object?>[no], limit: 1);
      if (rows.isEmpty) break;
      guard++;
      no = '${base}x$guard';
      if (guard > 50) {
        throw StateError('单号连续冲突，请稍后重试');
      }
    }

    await db.insert('stocktake_sheet', <String, Object?>{
      'sheet_no': no,
      'zone_code': zc,
      'phase': phase,
      'status': InvSheetStatus.open,
      'operator': operator,
      'started_at': DateTime.now().millisecondsSinceEpoch,
    });
    return (await findSheet(no))!;
  }

  Future<Map<String, dynamic>?> findSheet(String sheetNo) async {
    final db = await LocalDb.I.db();
    final rows = await db.query('stocktake_sheet',
        where: 'sheet_no = ?', whereArgs: <Object?>[sheetNo.trim()], limit: 1);
    return rows.isEmpty ? null : rows.first;
  }

  /// 某点位的全部单据（阶段升序、时间降序）。
  Future<List<Map<String, dynamic>>> listSheetsOfZone(String zoneCode) async {
    final db = await LocalDb.I.db();
    return db.rawQuery('''
      select s.*,
             (select count(*) from scan_record r where r.sheet_no = s.sheet_no) as rows_count,
             (select coalesce(sum(r.qty), 0) from scan_record r where r.sheet_no = s.sheet_no) as total_qty
        from stocktake_sheet s
       where s.zone_code = ?
       order by s.phase asc, s.started_at desc
    ''', <Object?>[zoneCode.trim()]);
  }

  /// 提交：锁死这张单（不再接受写入），差异集此刻定格。
  Future<int> submitSheet(String sheetNo) async {
    final db = await LocalDb.I.db();
    return db.update(
      'stocktake_sheet',
      <String, Object?>{
        'status': InvSheetStatus.submitted,
        'submitted_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'sheet_no = ? and status = 0',
      whereArgs: <Object?>[sheetNo.trim()],
    );
  }

  /// 撤销提交（主管改口了要重扫）。数据不动，只把单放回可编辑。
  Future<int> reopenSheet(String sheetNo) async {
    final db = await LocalDb.I.db();
    return db.update(
      'stocktake_sheet',
      <String, Object?>{'status': InvSheetStatus.open, 'submitted_at': null},
      where: 'sheet_no = ? and status = ?',
      whereArgs: <Object?>[sheetNo.trim(), InvSheetStatus.submitted],
    );
  }

  Future<int> markUploaded(String sheetNo) async {
    final db = await LocalDb.I.db();
    return db.transaction((txn) async {
      final n = await txn.update(
        'stocktake_sheet',
        <String, Object?>{
          'status': InvSheetStatus.uploaded,
          'uploaded_at': DateTime.now().millisecondsSinceEpoch,
        },
        where: 'sheet_no = ?',
        whereArgs: <Object?>[sheetNo.trim()],
      );
      await txn.update('scan_record', <String, Object?>{'uploaded': 1},
          where: 'sheet_no = ?', whereArgs: <Object?>[sheetNo.trim()]);
      return n;
    });
  }

  Future<int> deleteSheet(String sheetNo) async {
    final no = sheetNo.trim();
    final db = await LocalDb.I.db();
    return db.transaction((txn) async {
      await txn.delete('scan_record', where: 'sheet_no = ?', whereArgs: <Object?>[no]);
      return txn.delete('stocktake_sheet', where: 'sheet_no = ?', whereArgs: <Object?>[no]);
    });
  }

  // ============================================================
  // 采集
  // ============================================================

  /// 扫一笔。**判定 + 落库在同一个事务里**：判定用的行数/差异集，
  /// 必须在写的那一刻是准的，否则扫码枪连发时会算错上限、放错商品进来。
  Future<InvScanResult> scan(
    String sheetNo,
    String barcode, {
    double qty = 1,
    String? locCode,
  }) async {
    final no = _req(sheetNo, 'sheet_no');
    final code = _req(barcode, 'barcode');
    if (!qty.isFinite || qty == 0) {
      throw ArgumentError.value(qty, 'qty', '数量为 0 没有意义（要删就调 deleteRow）');
    }

    final db = await LocalDb.I.db();
    return db.transaction((txn) async {
      final sheetRows = await txn.query('stocktake_sheet',
          where: 'sheet_no = ?', whereArgs: <Object?>[no], limit: 1);
      if (sheetRows.isEmpty) {
        throw StateError('盘点单 $no 不存在（可能已被清除缓存删掉）');
      }
      final sheet = sheetRows.first;
      final zone = (sheet['zone_code'] ?? '').toString();
      final phase = (sheet['phase'] as num).toInt();
      final status = (sheet['status'] as num).toInt();

      final exist = await txn.query('scan_record',
          where: 'sheet_no = ? and barcode = ?',
          whereArgs: <Object?>[no, code],
          limit: 1);

      final cnt = await txn.rawQuery(
          'select count(*) as c from scan_record where sheet_no = ?',
          <Object?>[no]);
      final currentRows = (cnt.first['c'] as num).toInt();

      final boundZones = await _zonesOfBarcodeTxn(txn, code);
      final prevPhase = InvPhase.prev(phase);
      final diff = prevPhase == null
          ? const <String>{}
          : await _diffBarcodesTxn(txn, zone, prevPhase);

      final decision = InventoryRules.decide(
        phase: phase,
        barcode: code,
        zoneCode: zone,
        sheetEditable: InvSheetStatus.editable(status),
        alreadyInSheet: exist.isNotEmpty,
        currentRows: currentRows,
        boundZones: boundZones,
        diffBarcodes: diff,
        maxRows: maxRows,
      );

      if (!decision.accepted) {
        return InvScanResult(decision, rowId: exist.isEmpty ? null : exist.first['id'] as int);
      }

      final now = DateTime.now().millisecondsSinceEpoch;
      if (exist.isEmpty) {
        final id = await txn.insert('scan_record', <String, Object?>{
          'sheet_no': no,
          'barcode': code,
          'qty': qty,
          'scanned_at': now,
          'note': null,
          'phase': phase,
          'loc_code': (locCode ?? '').trim().isEmpty ? null : locCode!.trim(),
          'uploaded': 0,
        });
        return InvScanResult(decision, rowId: id, newQty: qty);
      }

      final id = exist.first['id'] as int;
      final oldQty = (exist.first['qty'] as num).toDouble();
      final newQty = oldQty + qty;
      if (newQty <= 0) {
        // 减到 0 = 删掉这行：留一行数量 0 的记录，汇总时会多算一个品种。
        await txn.delete('scan_record', where: 'id = ?', whereArgs: <Object?>[id]);
        return InvScanResult(decision, rowId: id, newQty: 0);
      }
      await txn.update(
        'scan_record',
        <String, Object?>{
          'qty': newQty,
          'scanned_at': now,
          'uploaded': 0,
          if (locCode != null && locCode.trim().isNotEmpty) 'loc_code': locCode.trim(),
        },
        where: 'id = ?',
        whereArgs: <Object?>[id],
      );
      return InvScanResult(decision, rowId: id, newQty: newQty);
    });
  }

  /// 该条码**在本点位**记到哪个货架位。
  ///
  /// 优先用它在本点位已绑定的货架位（商品档案说它在哪儿）；
  /// 在本点位没绑过就退回 [fallback]（＝界面上当前选中的货架位）。
  ///
  /// 🔴 这里**不判**"绑在别的点位就拒绝" —— 那是**准入判定**，归
  ///    `InventoryRules.decide` 管（它会统一拒绝并给出"当前盘点位不包含该商品"）。
  ///    把"记到哪儿"和"准不准记"混在一起，拒绝路径就会分两处，
  ///    总有一条没人测到，然后在现场以"某些商品扫了没反应"的形式冒出来。
  Future<String?> resolveLocCode(
    String barcode, {
    required String zoneCode,
    String? fallback,
  }) async {
    final zc = zoneCode.trim();
    for (final r in await locationsOfBarcode(barcode)) {
      if ((r['zone_code'] ?? '').toString() != zc) continue;
      final lc = (r['loc_code'] ?? '').toString().trim();
      if (lc.isNotEmpty) return lc;
    }
    final fb = (fallback ?? '').trim();
    return fb.isEmpty ? null : fb;
  }

  /// 扫一笔，**自动决定记到哪个货架位**。
  ///
  /// 采集页那行输入框与摄像头扫码页都走这一个入口 ——
  /// "这一件记到哪儿"只实现一次，两个页面不会各自判出不一样的结果
  /// （同一个动作在两个入口落进不同货架位，是最难查的一类脏数据）。
  Future<InvScanResult> scanAuto(
    String sheetNo,
    String barcode, {
    String? fallbackLocCode,
  }) async {
    final sheet = await findSheet(sheetNo);
    if (sheet == null) {
      throw StateError('盘点单 $sheetNo 不存在（可能已被清除缓存删掉）');
    }
    final loc = await resolveLocCode(
      barcode,
      zoneCode: (sheet['zone_code'] ?? '').toString(),
      fallback: fallbackLocCode,
    );
    return scan(sheetNo, barcode, locCode: loc);
  }

  /// 直接改成指定数量（手输修正）。<= 0 视为删除该行。
  Future<void> setQty(int id, double qty) async {
    final db = await LocalDb.I.db();
    if (qty <= 0) {
      await db.delete('scan_record', where: 'id = ?', whereArgs: <Object?>[id]);
      return;
    }
    await db.update('scan_record', <String, Object?>{'qty': qty, 'uploaded': 0},
        where: 'id = ?', whereArgs: <Object?>[id]);
  }

  Future<int> deleteRow(int id) async {
    final db = await LocalDb.I.db();
    return db.delete('scan_record', where: 'id = ?', whereArgs: <Object?>[id]);
  }

  /// 某张单的明细，左连商品档案（**必须 LEFT JOIN**：商档里没有的条码
  /// 也要显示出来，否则员工看不到自己扫过的东西会再扫一遍）。
  ///
  /// 🔴 明细里带 `prev_qty` / `diff_qty`（**比上一阶段**，不是比账面）：
  ///    界面要当场告诉员工"上一遍这里盘的是多少"，不然复盘就是闷头重扫，
  ///    盘完还是不知道自己改了什么。账面数 `account_qty` 仍然带出来，
  ///    只当参考列显示，不参与差异判定。
  Future<List<Map<String, dynamic>>> listRows(String sheetNo) async {
    final db = await LocalDb.I.db();
    final no = sheetNo.trim();

    final rows = await db.rawQuery('''
      select s.id            as id,
             s.barcode       as barcode,
             s.qty           as qty,
             s.scanned_at    as scanned_at,
             s.phase         as phase,
             s.loc_code      as loc_code,
             s.uploaded      as uploaded,
             m.name          as name,
             m.spec          as spec,
             m.unit          as unit,
             m.unit_price    as unit_price,
             m.account_qty   as account_qty
        from scan_record s
        left join stock_master m on m.barcode = s.barcode
       where s.sheet_no = ?
       order by s.scanned_at desc, s.id desc
    ''', <Object?>[no]);

    final phaseRow = await db.rawQuery(
        'select phase, zone_code from stocktake_sheet where sheet_no = ?',
        <Object?>[no]);
    if (phaseRow.isEmpty) return rows;
    final phase = InventoryRules.asNum(phaseRow.first['phase'])?.toInt();
    final zone = (phaseRow.first['zone_code'] ?? '').toString().trim();
    final prev = InvPhase.prev(phase ?? 0);
    if (prev == null || zone.isEmpty) return rows;

    final prevMap = await _prevSummary(db, zone, prev);
    final cur = <String, double>{};
    for (final r in rows) {
      final c = (r['barcode'] ?? '').toString().trim();
      final q = InventoryRules.asNum(r['qty']);
      if (c.isNotEmpty && q != null) cur[c] = (cur[c] ?? 0) + q;
    }
    // 同一张单里同一条码可能扫多次，先在本单内汇总，再和上一阶段比
    return InventoryRules.attachPrevDiff(rows, <String, double>{
      for (final e in cur.entries) e.key: prevMap[e.key] ?? 0,
    });
  }

  /// 某张单的小结：品种数 / 总数量 / 未知条码数 / 未回传条数。
  Future<Map<String, dynamic>> summary(String sheetNo) async {
    final db = await LocalDb.I.db();
    final rows = await db.rawQuery('''
      select count(*)                                          as kinds,
             coalesce(sum(s.qty), 0)                            as total_qty,
             sum(case when m.barcode is null then 1 else 0 end)  as unknown,
             sum(case when s.uploaded = 0 then 1 else 0 end)     as pending
        from scan_record s
        left join stock_master m on m.barcode = s.barcode
       where s.sheet_no = ?
    ''', <Object?>[sheetNo.trim()]);
    final r = rows.first;
    return <String, dynamic>{
      'kinds': _intOf(r['kinds']),
      'total_qty': _dblOf(r['total_qty']),
      'unknown': _intOf(r['unknown']),
      'pending': _intOf(r['pending']),
    };
  }

  // ============================================================
  // 阶段汇总 / 差异集 / 失误笔数
  // ============================================================

  /// 某点位某阶段**按条码汇总**的行（跨该阶段的所有单）。
  ///
  /// 汇总而不是逐笔，是因为差异要按商品看：同一商品可能在初盘扫了两次
  /// （两张单），比的是合计数量。
  ///
  /// 🔴 `diff_qty` 是**和上一阶段比的**（`qty - 上一阶段 qty`），不是比账面：
  ///    门店的系统里根本没有可用的库存账面（泰格库里所有库存表都是空的），
  ///    拿"账面"当基准会得到一个恒等于全部商品的差异集，三遍制退化成"扫三遍"。
  ///    比优特 PG 的真实口径就是三遍平行数量互比，这里照它来。
  ///    账面数（account_qty）仍然带出来，只是**参考列**，不参与差异判定。
  Future<List<Map<String, dynamic>>> phaseRows(String zoneCode, int phase) async {
    final db = await LocalDb.I.db();
    final zc = zoneCode.trim();
    final rows = await db.rawQuery('''
      select s.barcode       as barcode,
             sum(s.qty)      as qty,
             max(s.scanned_at) as scanned_at,
             m.name          as name,
             m.spec          as spec,
             m.unit          as unit,
             m.unit_price    as unit_price,
             m.account_qty   as account_qty
        from scan_record s
        join stocktake_sheet sh on sh.sheet_no = s.sheet_no
        left join stock_master m on m.barcode = s.barcode
       where sh.zone_code = ? and s.phase = ?
       group by s.barcode
       order by s.barcode asc
    ''', <Object?>[zc, phase]);

    return InventoryRules.attachPrevDiff(
        rows, await _prevSummary(db, zc, InvPhase.prev(phase)));
  }

  /// 上一阶段每个条码的合计数量（初盘没有上一阶段 → 空表）。
  Future<Map<String, double>> _prevSummary(
      Database db, String zoneCode, int? prevPhase) async {
    if (prevPhase == null) return const <String, double>{};
    final rows = await db.rawQuery('''
      select s.barcode as barcode, sum(s.qty) as qty
        from scan_record s
        join stocktake_sheet sh on sh.sheet_no = s.sheet_no
       where sh.zone_code = ? and s.phase = ?
       group by s.barcode
    ''', <Object?>[zoneCode, prevPhase]);
    final out = <String, double>{};
    for (final r in rows) {
      final c = (r['barcode'] ?? '').toString().trim();
      final q = InventoryRules.asNum(r['qty']);
      if (c.isNotEmpty && q != null) out[c] = q;
    }
    return out;
  }

  /// 差异集条码：**和上一阶段数量对不上**的，外加**上一轮盘过这一轮没扫到的（漏盘）**。
  Future<Set<String>> diffBarcodes(String zoneCode, int phase) async {
    final rows = await phaseRows(zoneCode, phase);
    final prev = InvPhase.prev(phase);
    if (prev == null) return const <String>{};
    return InventoryRules.diffBarcodesOf(rows,
        prevRows: await phaseRows(zoneCode, prev));
  }

  /// 某点位某阶段的**差异行**：数量对不上的 + **上一轮盘过这一轮没扫到的（漏盘）**。
  ///
  /// 🔴 漏盘必须**补成一行**（`qty: 0`、`diff_qty: -上一轮`、`missing: true`）：
  ///    它在本阶段压根没有扫码记录，[phaseRows] 里根本没有这一行，
  ///    拿 `rows.where(isDiffRow)` 是永远挑不出来的 —— 差异表、导出、
  ///    抽盘的复核清单会一起漏掉最严重的一类（数量错了至少还显眼，
  ///    "少一行"在明细里看不出来）。服务端 `diffRowsOf` 是同一口径。
  Future<List<Map<String, dynamic>>> diffRows(String zoneCode, int phase) async {
    final zc = zoneCode.trim();
    final prev = InvPhase.prev(phase);
    if (prev == null) return const <Map<String, dynamic>>[]; // 初盘没有参照

    final db = await LocalDb.I.db();
    final rows = await phaseRows(zc, phase);
    final out = <Map<String, dynamic>>[
      for (final r in rows)
        if (InventoryRules.isDiffRow(r)) r,
    ];

    final cur = <String>{};
    for (final r in rows) {
      final c = (r['barcode'] ?? '').toString().trim();
      if (c.isNotEmpty) cur.add(c);
    }
    final prevMap = await _prevSummary(db, zc, prev);
    final missed = <String>[
      for (final c in prevMap.keys)
        if (!cur.contains(c)) c,
    ]..sort();
    if (missed.isEmpty) return out;

    // 补出来的行也要有商品名 —— 差异表上只有一串条码，主管没法认。
    final info = await _masterInfo(db, missed);
    for (final c in missed) {
      final m = info[c] ?? const <String, Object?>{};
      final p = prevMap[c];
      out.add(<String, dynamic>{
        'barcode': c,
        'qty': 0.0,
        'scanned_at': null,
        'name': m['name'],
        'spec': m['spec'],
        'unit': m['unit'],
        'unit_price': m['unit_price'],
        'account_qty': m['account_qty'],
        'prev_qty': p,
        'diff_qty': p == null ? null : -p,
        'missing': true,
      });
    }
    return out;
  }

  /// 一次查若干条码的商品档案（给补出来的漏盘行配名字）。
  ///
  /// **分批**查：SQLite 的绑定变量个数有上限（默认 999），一个货架的漏盘
  /// 一次性 `in (...)` 塞进去会报 "too many SQL variables"，
  /// 现场表现成"差异表打不开"。
  Future<Map<String, Map<String, Object?>>> _masterInfo(
      Database db, List<String> codes) async {
    final out = <String, Map<String, Object?>>{};
    const chunk = 500;
    for (var i = 0; i < codes.length; i += chunk) {
      final end = i + chunk < codes.length ? i + chunk : codes.length;
      final part = codes.sublist(i, end);
      final ph = List.filled(part.length, '?').join(',');
      final rows = await db.rawQuery(
          'select barcode, name, spec, unit, unit_price, account_qty '
          'from stock_master where barcode in ($ph)',
          part);
      for (final r in rows) {
        out[(r['barcode'] ?? '').toString()] = r;
      }
    }
    return out;
  }

  /// 上一阶段 → 本阶段的失误笔数。没有上一阶段返回 0。
  Future<int> mistakeCount(String zoneCode, int phase) async {
    final prev = InvPhase.prev(phase);
    if (prev == null) return 0;
    final a = await phaseRows(zoneCode, prev);
    final b = await phaseRows(zoneCode, phase);
    return InventoryRules.mistakeCount(a, b);
  }

  /// 该点位各阶段的进度小结（界面顶部的阶段条直接用）。
  Future<List<Map<String, dynamic>>> phaseProgress(String zoneCode) async {
    final zc = zoneCode.trim();
    final out = <Map<String, dynamic>>[];
    for (final p in InvPhase.all) {
      final rows = await phaseRows(zc, p);
      final prev = InvPhase.prev(p);
      final diff = InventoryRules.diffBarcodesOf(rows,
          prevRows:
              prev == null ? const <Map<String, dynamic>>[] : await phaseRows(zc, prev));
      final sheet = await _latestSheetOf(zc, p);
      out.add(<String, dynamic>{
        'phase': p,
        'label': InvPhase.label(p),
        'kinds': rows.length,
        'diff': diff.length,
        'mistakes': await mistakeCount(zc, p),
        'status': sheet == null ? -1 : (sheet['status'] as num).toInt(),
        'sheet_no': sheet?['sheet_no'],
      });
    }
    return out;
  }

  Future<Map<String, dynamic>?> _latestSheetOf(String zoneCode, int phase) async {
    final db = await LocalDb.I.db();
    final rows = await db.query('stocktake_sheet',
        where: 'zone_code = ? and phase = ?',
        whereArgs: <Object?>[zoneCode, phase],
        orderBy: 'started_at desc',
        limit: 1);
    return rows.isEmpty ? null : rows.first;
  }

  // ============================================================
  // 缓存清理
  // ============================================================

  /// 清该点位的**盘点数据**（单据 + 流水），保留点位与库位档案。
  ///
  /// 界面必须二次确认，并且把两项分开说清楚：
  /// 「清点位」= 删点位与库位档案；「清数据」= 只删盘点单与扫码流水。
  /// 把两件事合成一个按钮，员工迟早会点错那一次。
  Future<Map<String, int>> clearZoneData(String zoneCode) async {
    final zc = zoneCode.trim();
    final db = await LocalDb.I.db();
    return db.transaction((txn) async {
      final r = await _purgeSheetsOfZone(txn, zc);
      return r;
    });
  }

  /// 清**全部**盘点数据（所有点位）。点位/库位档案不动。
  Future<Map<String, int>> clearAllData() async {
    final db = await LocalDb.I.db();
    return db.transaction((txn) async {
      final sheets = await txn.delete('stocktake_sheet');
      final rows = await txn.delete('scan_record',
          where: 'sheet_no like ?', whereArgs: <Object?>['$sheetPrefix%']);
      return <String, int>{'sheet': sheets, 'scan_record': rows};
    });
  }

  /// 删掉某点位的所有单据 + 它们的流水（事务内用，给 deleteZone/clearZoneData 复用）。
  Future<Map<String, int>> _purgeSheetsOfZone(Transaction txn, String zoneCode) async {
    final sheets = await txn.query('stocktake_sheet',
        columns: <String>['sheet_no'],
        where: 'zone_code = ?',
        whereArgs: <Object?>[zoneCode]);
    final nos = sheets.map((r) => r['sheet_no'].toString()).toList();
    var rows = 0;
    if (nos.isNotEmpty) {
      final marks = List<String>.filled(nos.length, '?').join(',');
      rows = await txn.delete('scan_record',
          where: 'sheet_no in ($marks)', whereArgs: nos);
    }
    final n = await txn.delete('stocktake_sheet',
        where: 'zone_code = ?', whereArgs: <Object?>[zoneCode]);
    return <String, int>{'sheet': n, 'scan_record': rows};
  }

  // ============================================================
  // 小工具
  // ============================================================

  Future<Set<String>> _zonesOfBarcodeTxn(Transaction txn, String barcode) async {
    final rows = await txn.rawQuery('''
      select distinct l.zone_code as zone_code
        from barcode_location b
        join location l on l.loc_code = b.loc_code
       where b.barcode = ?
    ''', <Object?>[barcode]);
    return rows
        .map((r) => (r['zone_code'] ?? '').toString())
        .where((s) => s.isNotEmpty)
        .toSet();
  }

  /// 扫码入库那一刻用的差异集（决定"这一笔让不让扫"）。
  ///
  /// 🔴 和 [phaseRows] 走同一套口径（**比上一阶段**，不是比账面），
  ///    校准不对齐的话会出现"明细页显示有差异、但扫第二遍时被拒"这种鬼故事。
  Future<Set<String>> _diffBarcodesTxn(
      Transaction txn, String zoneCode, int phase) async {
    final prevPhase = InvPhase.prev(phase);
    if (prevPhase == null) return const <String>{};
    Future<List<Map<String, Object?>>> q(int p) => txn.rawQuery('''
      select s.barcode as barcode, sum(s.qty) as qty
        from scan_record s
        join stocktake_sheet sh on sh.sheet_no = s.sheet_no
       where sh.zone_code = ? and s.phase = ?
       group by s.barcode
    ''', <Object?>[zoneCode, p]);

    final rows = await q(phase);
    final prevRows = await q(prevPhase);
    final prev = <String, double>{};
    for (final r in prevRows) {
      final c = (r['barcode'] ?? '').toString().trim();
      final v = InventoryRules.asNum(r['qty']);
      if (c.isNotEmpty && v != null) prev[c] = v;
    }
    // prevRows 一并传进去，漏盘（上一轮有、这一轮没扫）才算得进差异集
    return InventoryRules.diffBarcodesOf(
        InventoryRules.attachPrevDiff(rows, prev),
        prevRows: prevRows);
  }

  static String _req(String v, String field) {
    final s = v.trim();
    if (s.isEmpty) throw ArgumentError.value(v, field, '$field 不能为空');
    return s;
  }

  static int _intOf(Object? v) =>
      v is int ? v : int.tryParse((v ?? 0).toString()) ?? 0;

  static double _dblOf(Object? v) =>
      v is num ? v.toDouble() : double.tryParse((v ?? 0).toString()) ?? 0;
}
