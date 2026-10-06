import 'local_db.dart';

/// 扫码枪采集的本地仓库：扫码流水（`scan_record`）的读写。
///
/// ── 为什么整页都只在本地打转 ──────────────────────────────────
/// 扫码发生在货架之间：手机可能没信号、Wi-Fi 可能连的是个假热点。
/// 所以"扫一个码 → 记一笔"这条路径**一次网络请求都不发**，全部落在本地
/// SQLite（见 core/local_db.dart 的 scan_record）。联网是后面的事（回传、
/// 出盈亏表），采集这一段必须离线可用 —— 否则员工扫到一半发现存不进去，
/// 这一轮扫码就白干了。
///
/// ── 一条最重要的业务语义 ──────────────────────────────────────
/// **同一个条码在同一张单里只占一行，重复扫是数量累加，不是插新行。**
/// 员工扫第二遍的意思是"这还有一个"，不是"又来一条记录"。
/// 插成多行的话，后面按单号汇总就会把同一个品种数两遍，
/// 而且界面上会出现两行一模一样的商品，看起来像 bug。
///
/// 这条靠 `addScan` 内部的"先查再增"实现，并且包在事务里 ——
/// 扫码枪连发时两次写入可能挨得很近，不加事务会竞态丢一次。
class StocktakeRepo {
  /// 扫码单号前缀。单号要能一眼看出"这是哪天哪次扫"，
  /// 所以带日期时间，不单独维护流水表（手机上不值得）。
  static const String sheetPrefix = 'PD';

  /// 生成扫码单号：[prefix] + yyyyMMdd + HHmmss。
  /// 同一秒开两张单的概率可以接受；真撞了就以库里已存在的为准（见 listSheets）。
  /// [prefix] 默认用本类的 [sheetPrefix]；拣货单等"共用一张流水表"的兄弟模块
  /// 传自己的前缀（如 'JK'），保证各自单号段不串。
  static String newSheetNo([DateTime? now, String? prefix]) {
    final p = prefix ?? sheetPrefix;
    final d = now ?? DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '$p${d.year}${two(d.month)}${two(d.day)}'
        '${two(d.hour)}${two(d.minute)}${two(d.second)}';
  }

  /// 记一笔扫码。同条码累加数量，返回该行 id。
  ///
  /// [qty] 默认 1（扫一次算一个）。称重商品可以由界面传小数。
  /// [note] 货位/备注，可空。
  Future<int> addScan(
    String sheetNo,
    String barcode, {
    double qty = 1,
    String? note,
  }) async {
    final code = barcode.trim();
    if (code.isEmpty) {
      throw ArgumentError.value(barcode, 'barcode', '空条码不能入账');
    }
    if (qty == 0) {
      throw ArgumentError.value(qty, 'qty', '数量为 0 没有意义（要删就调 deleteScan）');
    }

    final db = await LocalDb.I.db();
    final now = DateTime.now().millisecondsSinceEpoch;

    return db.transaction((txn) async {
      final exist = await txn.query(
        'scan_record',
        where: 'sheet_no = ? AND barcode = ?',
        whereArgs: [sheetNo, code],
        limit: 1,
      );

      if (exist.isEmpty) {
        return txn.insert('scan_record', <String, Object?>{
          'sheet_no': sheetNo,
          'barcode': code,
          'qty': qty,
          'scanned_at': now,
          'note': note,
          'uploaded': 0,
        });
      }

      final id = exist.first['id'] as int;
      final oldQty = (exist.first['qty'] as num).toDouble();
      final newQty = oldQty + qty;
      if (newQty <= 0) {
        // 减到 0 就删掉这行：留一行数量 0 的记录，汇总时会多算一个品种
        await txn.delete('scan_record', where: 'id = ?', whereArgs: [id]);
        return id;
      }
      await txn.update(
        'scan_record',
        <String, Object?>{
          'qty': newQty,
          'scanned_at': now,
          // 改过数量就打回未上传：已回传的数据对不上了
          'uploaded': 0,
          if (note != null) 'note': note,
        },
        where: 'id = ?',
        whereArgs: [id],
      );
      return id;
    });
  }

  /// 直接把某笔改成指定数量（手输修正用）。
  /// 传 0 或负数 = 删除该笔。
  Future<void> setQty(int id, double qty) async {
    final db = await LocalDb.I.db();
    if (qty <= 0) {
      await db.delete('scan_record', where: 'id = ?', whereArgs: [id]);
      return;
    }
    await db.update(
      'scan_record',
      <String, Object?>{'qty': qty, 'uploaded': 0},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<int> deleteScan(int id) async {
    final db = await LocalDb.I.db();
    return db.delete('scan_record', where: 'id = ?', whereArgs: [id]);
  }

  /// 某张单的扫码流水，最近的排最前。
  Future<List<Map<String, dynamic>>> listScans(String sheetNo) async {
    final db = await LocalDb.I.db();
    return db.query(
      'scan_record',
      where: 'sheet_no = ?',
      whereArgs: [sheetNo],
      orderBy: 'scanned_at DESC, id DESC',
    );
  }

  /// 扫码流水 **左连** 商品档案，界面直接拿去显示。
  ///
  /// 用 LEFT JOIN 而不是 INNER JOIN：商档里没有的条码（新品、错码、一品多码
  /// 的副码）**照样要显示出来**，只是品名空着。用 INNER JOIN 会把它们吃掉 ——
  /// 员工明明扫了，界面却没有，他会以为没扫进去，于是再扫一遍，数量就翻倍了。
  ///
  /// [diffQty] = 实盘 - 账面，账面缺失时为 null（"不知道差多少"，不是"差 0"）。
  Future<List<Map<String, dynamic>>> listWithMaster(String sheetNo) async {
    final db = await LocalDb.I.db();
    return db.rawQuery(
      '''
      select (select meta.name from sheet_meta meta
               where meta.sheet_no = s.sheet_no) as sheet_name,
             s.id            as id,
             s.barcode       as barcode,
             s.qty           as qty,
             s.scanned_at    as scanned_at,
             s.note          as note,
             s.uploaded      as uploaded,
             m.name          as name,
             m.spec          as spec,
             m.unit          as unit,
             m.unit_price    as unit_price,
             m.account_qty   as account_qty,
             (s.qty - m.account_qty) as diff_qty
        from scan_record s
        left join stock_master m on m.barcode = s.barcode
       where s.sheet_no = ?
       order by s.scanned_at DESC, s.id DESC
      ''',
      [sheetNo],
    );
  }

  /// 某张单的汇总：品种数、总数量、未知条码数、未回传条数。
  Future<Map<String, dynamic>> summary(String sheetNo) async {
    final db = await LocalDb.I.db();
    final rows = await db.rawQuery(
      '''
      select count(*)                                        as kinds,
             coalesce(sum(s.qty), 0)                          as total_qty,
             sum(case when m.barcode is null then 1 else 0 end) as unknown,
             sum(case when s.uploaded = 0 then 1 else 0 end)   as pending
        from scan_record s
        left join stock_master m on m.barcode = s.barcode
       where s.sheet_no = ?
      ''',
      [sheetNo],
    );
    final r = rows.first;
    int asInt(Object? v) => v is int ? v : int.parse((v ?? 0).toString());
    double asDouble(Object? v) =>
        v is num ? v.toDouble() : double.tryParse((v ?? 0).toString()) ?? 0;
    return <String, dynamic>{
      'kinds': asInt(r['kinds']),
      'total_qty': asDouble(r['total_qty']),
      'unknown': asInt(r['unknown']),
      'pending': asInt(r['pending']),
    };
  }

  /// 给单起名/改名（好又多版同款机制，2026-10-06 继承过来）。
  /// 名字存在 sheet_meta 表（建表见 local_db.dart v6 迁移）。
  /// INSERT OR REPLACE：改名就是整体替换，单号是主键不会漂。
  Future<void> setSheetName(String sheetNo, String name) async {
    final db = await LocalDb.I.db();
    final n = name.trim();
    await db.rawInsert(
      'INSERT OR REPLACE INTO sheet_meta (sheet_no, name, created_at) '
      'VALUES (?, ?, ?)',
      [sheetNo, n.isEmpty ? null : n, DateTime.now().millisecondsSinceEpoch],
    );
  }

  /// 查某张单的名字；没起过名返回空串（界面兜底显示单号）。
  Future<String> sheetName(String sheetNo) async {
    final db = await LocalDb.I.db();
    final rows = await db.query('sheet_meta',
        where: 'sheet_no = ?', whereArgs: [sheetNo], limit: 1);
    if (rows.isEmpty) return '';
    return (rows.first['name'] as String?) ?? '';
  }

  /// 本机已有的扫码单（最近在前），用于"继续上次没扫完的单"。
  ///
  /// [prefix] 只取以它开头的单号。**扫码枪必须传 `sheetPrefix`（'PD'）**：
  /// 盘点（inventory 模块）的单号是 `INV-...`，两者共用 `scan_record` 这张表，
  /// 不筛的话盘点单会出现在扫码枪的"继续上次没扫完的单"里，
  /// 员工点进去发现是一堆盘点数据（表头都是扫码的列），只会以为是坏了。
  Future<List<Map<String, dynamic>>> listSheets({String? prefix}) async {
    final db = await LocalDb.I.db();
    final where = prefix == null || prefix.isEmpty
        ? ''
        : 'where r.sheet_no like ?';
    // LEFT JOIN sheet_meta：没起过名的单 name 为 null，界面兜底显示单号。
    // 不能 INNER JOIN —— sheet_meta 是后加的表，历史单在 meta 里根本没有行。
    return db.rawQuery(
      '''
      select r.sheet_no                 as sheet_no,
             meta.name                  as name,
             count(*)                   as kinds,
             coalesce(sum(r.qty), 0)    as total_qty,
             max(r.scanned_at)          as last_at
        from scan_record r
        left join sheet_meta meta on meta.sheet_no = r.sheet_no
       $where
       group by r.sheet_no
       order by last_at DESC
      ''',
      prefix == null || prefix.isEmpty ? null : <Object?>['$prefix%'],
    );
  }

  /// 整单删除（盘错了重来）。事务连带删 sheet_meta，
  /// 否则删单后 meta 里会留一行孤儿名字 —— 重用同号概率虽低，但"列表里
  /// 出现一张没有流水的单"这种事不值得赌。返回删除条数。
  Future<int> deleteSheet(String sheetNo) async {
    final db = await LocalDb.I.db();
    return db.transaction((txn) async {
      final n = await txn.delete(
        'scan_record',
        where: 'sheet_no = ?',
        whereArgs: [sheetNo],
      );
      await txn.delete('sheet_meta',
          where: 'sheet_no = ?', whereArgs: [sheetNo]);
      return n;
    });
  }
}
