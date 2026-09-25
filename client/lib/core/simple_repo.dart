// 简易盘点（`simple_stocktake`）的仓库层（本地 SQLite）。
//
// ── 为什么不塞进 InventoryRepo / DeductRepo ───────────────────
// 三个通道共用**两张表**，但业务判据完全不重叠：
//   · 盘点：点位 × 阶段、货架位归属、差异集、失误笔数；
//   · 减货：不看点位不看阶段，同码一单只许一行；
//   · 简易盘点：不看点位、不看商档，**一份导入的清单** + 节点式一趟趟扫、
//     同码累加、最后导三段。
// 塞进同一个文件的结果是改一个通道要在另外两个的判据里找位置，
// 而且很容易顺手复用到不该复用的方法（拿 `phaseRows` 去算简易盘点的汇总，
// 它会按点位分组 —— 而简易通道根本没有点位）。
//
// ── 共用哪两张表 ─────────────────────────────────────────────
// `stocktake_sheet`（`sheet_type='simple'`）+ `scan_record`。
// 一个**节点**（＝一趟）就是一张 sheet：`zone_code` 借来存**任务号**、
// `phase` = 1初盘/2复盘/3差异复盘、`sheet_no` = 节点号（`SMP-…-01`）。
// 一笔扫码就是一条 scan_record（`sheet_no` = 节点号）。
//
// 🔴 借 `zone_code` 存任务号：简易通道**本来就不看点位**，这一列在这条通道里
//    没有别的含义。比新增一列（要动所有读表的地方）划算。见方案 §3。
//
// 🔴 **绝不读** `stocktake_zone` / `location` / `barcode_location` / `stock_master`
//    里的任何一个。商品名称只从 `simple_item`（导入的清单）来。
//    一旦读了商档，"盘点那边改了设置、简易盘点跟着变"就会冒出来且极难查。
//
// ── 本文件（S1）的范围 ───────────────────────────────────────
// S1 只做**一个节点（初盘）**：导入清单 → 建任务 → 一趟盘完 → 导出三段。
// 复盘 / 差异复盘 / 差异集是 S2。见下方 [openOrCreateNode] 的阶段闸门 ——
// **故意**在这里挡住，而不是让它"看起来支持"却算不出差异集。

// 需要 ConflictAlgorithm（清单整份替换时按主键覆盖）。
// sqflite 是**直接依赖**（见 pubspec 的离线地基那段），不是蹭进来的传递依赖。
import 'package:sqflite/sqflite.dart' show ConflictAlgorithm;

import 'inventory_rules.dart';
import 'local_db.dart';
import 'simple_rules.dart';

/// 一次扫码的结果。
class SimpleScanResult {
  const SimpleScanResult(this.decision, {this.rowId, this.newQty});

  final SimpleScanDecision decision;

  /// 落在哪一行（被拒时可能为 null）。
  final int? rowId;

  /// 累加之后这个条码在本趟的总数（界面显示"已记 2"用）。
  final double? newQty;

  bool get accepted => decision.accepted;
}

class SimpleRepo {
  /// [maxRows] 单节点（一趟）的条数上限。生产用默认值；**测试可以调小**
  /// （调到 2 就能验上限拦截，不用真灌 500 条）。
  SimpleRepo({this.maxRows = SimpleRules.maxRowsPerNode});

  final int maxRows;

  /// 任务号前缀。盘点 `INV-`、减货 `JH-`、简易盘点 `SMP-` —— 扫一眼就知道是哪类。
  static const String taskPrefix = 'SMP-';

  /// 任务状态：进行中 / 已归档。
  ///
  /// 🔴 归档**不删数据**：一轮盘完之后清单和每一趟的数都要能翻出来导出。
  ///    归档只是"它不再是我现在正在盘的那一轮"。
  static const int taskOpen = 0;
  static const int taskArchived = 1;

  static String newTaskNo([DateTime? now]) {
    final d = now ?? DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '$taskPrefix${d.year}${two(d.month)}${two(d.day)}'
        '-${two(d.hour)}${two(d.minute)}${two(d.second)}';
  }

  /// 节点号 = `任务号-<两位阶段号>`。
  ///
  /// ⚠️ 节点的编号**就是阶段号**（01 初盘 / 02 复盘 / 03 差异复盘）。
  ///    方案 §1 提过"可开 3、4、5 趟"，但第四趟是什么口径龙哥还没定，
  ///    **所以现在不假装支持**（编一个"第 4 趟"出来，导出会不知道算哪一遍）。
  static String nodeNo(String taskNo, int phase) =>
      '${taskNo.trim()}-${phase.toString().padLeft(2, '0')}';

  static String _req(String v, String field) {
    final t = v.trim();
    if (t.isEmpty) throw ArgumentError.value(v, field, '$field 不能为空');
    return t;
  }

  static double _dbl(Object? v) {
    if (v == null) return 0;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString()) ?? 0;
  }

  static int _int(Object? v) {
    if (v == null) return 0;
    if (v is num) return v.toInt();
    return int.tryParse(v.toString()) ?? 0;
  }

  /// 取一个**确实存在**的任务号（规范化后的），不存在就抛错。
  ///
  /// 🔴 为什么"拿这一轮内容"的方法必须报错，而不是给空集合：
  ///    任务号对不上时返回空，界面上和"确实还没导入清单 / 真的一件都没盘"
  ///    **长得一模一样** —— 员工会照着空清单盘一整趟，导出来还是 0 行，
  ///    那时才发现白干了。返回空是"静默"，这里要的是"吵起来"。
  ///    "它到底在不在"用 [findTask]（那个就该返回 null）。
  ///
  /// ⚠️ 空串仍然抛 `ArgumentError`（参数本身不合法），与"目标不存在"
  ///    用的 `StateError` 分开：这两种错排查方向完全不同，
  ///    合成一个类型会让排查的人先往错的方向走。
  ///
  /// 注意它是**实例方法**（要调 [findTask]），别顺手改成 static。
  Future<String> _requireTask(String taskNo) async {
    final no = _req(taskNo, 'taskNo');
    if (await findTask(no) == null) {
      throw StateError('盘点任务 $no 不存在');
    }
    return no;
  }

  // ============================================================
  // 任务
  // ============================================================

  /// 某个场景**进行中**的那一轮（没有返回 null）。
  ///
  /// 🔴 同一场景同时只允许一个进行中的任务（方案 §2 规矩 3）：
  ///    同时开两个任务，员工根本不知道自己在盘哪一次。
  ///    仓库和卖场是**两个场景**，所以可以各有一个。
  Future<Map<String, dynamic>?> openTaskOf(String scene) async {
    final db = await LocalDb.I.db();
    final rows = await db.query('simple_task',
        where: 'scene = ? and status = ?',
        whereArgs: <Object?>[SimpleScene.normalize(scene), taskOpen],
        orderBy: 'created_at desc',
        limit: 1);
    return rows.isEmpty ? null : rows.first;
  }

  Future<Map<String, dynamic>?> findTask(String taskNo) async {
    final db = await LocalDb.I.db();
    final rows = await db.query('simple_task',
        where: 'task_no = ?', whereArgs: <Object?>[_req(taskNo, 'taskNo')], limit: 1);
    return rows.isEmpty ? null : rows.first;
  }

  /// 进页面时先看哪一轮：**优先进行中的**，其次时间最近的。
  ///
  /// 排序写 `status asc, created_at desc`（status 0=进行中）：一条 SQL 表达
  /// "有正在盘的就看它，没有就看最近归档的那一轮"。不这么写的话，员工
  /// 换过一份清单再进来，看到的是刚归档的那一轮 —— 会以为导入失败了。
  Future<Map<String, dynamic>?> latestTask() async {
    final db = await LocalDb.I.db();
    final rows = await db.query('simple_task',
        orderBy: 'status asc, created_at desc', limit: 1);
    return rows.isEmpty ? null : rows.first;
  }

  /// 任务列表（最近的在前），带"盘了多少 / 一共多少"，喂给切换任务那个面板。
  ///
  /// 统计用一条 SQL 聚合，**不逐单去调 count** —— 那是 N+1 次查询。
  /// 条数用 `COUNT(DISTINCT r.barcode)`：同一趟里同码累加只算一个品种，
  /// 直接 `COUNT(*)` 会把扫了两次的商品算成两个品（"已盘 51 / 1000" 就虚了）。
  Future<List<Map<String, dynamic>>> listTasks({
    String? scene,
    int limit = 50,
  }) async {
    final db = await LocalDb.I.db();
    final args = <Object?>[];
    var where = '';
    if (scene != null && scene.trim().isNotEmpty) {
      where = 'where t.scene = ?';
      args.add(SimpleScene.normalize(scene));
    }
    args.add(limit);
    return db.rawQuery('''
      select t.task_no, t.task_name, t.scene, t.total_items, t.status,
             t.created_at, t.closed_at,
             (select count(*) from simple_item i where i.task_no = t.task_no)
               as items,
             (select count(distinct r.barcode)
                from scan_record r
                join stocktake_sheet s on s.sheet_no = r.sheet_no
               where s.zone_code = t.task_no and s.sheet_type = ?)
               as scanned
        from simple_task t
        $where
       order by t.created_at desc
       limit ?
    ''', <Object?>[InvSheetType.simple, ...args]);
  }

  /// 生成一个没被占用的任务号。
  ///
  /// 同一秒重开会撞号 → 挂个序号（`SMP-…-120000x1`）。**绝不能让撞车变成
  /// "覆盖掉别人那一轮"**：那会让上一轮的数据莫名其妙地挂到这一轮名下。
  Future<String> _freshTaskNo() async {
    final db = await LocalDb.I.db();
    final base = newTaskNo();
    var no = base;
    var guard = 0;
    while (true) {
      final rows = await db.query('simple_task',
          where: 'task_no = ?', whereArgs: <Object?>[no], limit: 1);
      if (rows.isEmpty) return no;
      guard++;
      no = '${base}x$guard';
      if (guard > 50) throw StateError('任务号连续撞车 50 次，检查系统时间是否异常');
    }
  }

  /// 归档一轮（不再是我正在盘的那一轮）。**数据一行都不动。**
  Future<int> archiveTask(String taskNo) async {
    final db = await LocalDb.I.db();
    return db.update(
        'simple_task',
        <String, Object?>{
          'status': taskArchived,
          'closed_at': DateTime.now().millisecondsSinceEpoch,
        },
        where: 'task_no = ?',
        whereArgs: <Object?>[_req(taskNo, 'taskNo')]);
  }

  /// 「换一份清单」走的这条路：**归档上一轮 + 开新一轮 + 写新清单**。
  ///
  /// 🔴 三件事必须在**同一个事务**里。分开做的话，中途失败（比如清单写一半
  ///    报错）会留下"上一轮已归档、新一轮是空的"这种谁也盘不了的中间状态：
  ///    上一轮的入口被归档了、这一轮又没有清单，员工只会以为数据全丢了。
  ///
  /// 🔴 归档**不删**上一轮：方案 §7 第 8 条要求"换一份清单后上一轮的数还在、
  ///    导出上一轮仍对"，所以旧任务是留着、能翻出来导的（只是不再是"当前这一轮"）。
  ///
  /// 🔴 「同一场景同时只允许一个进行中的任务」这条规矩，靠的正是这里的
  ///    "先把该场景所有进行中的归档、再插新的" —— **结构上不可能出现两张**，
  ///    不需要另外再写一道 if 去拦（那种拦法还会漏掉并发的情况）。
  ///
  /// 返回新任务（已经带上清单条数）。
  Future<Map<String, dynamic>> startNewRound({
    required String scene,
    required List<SimpleImportRow> rows,
    String? taskName,
  }) async {
    final sc = SimpleScene.normalize(scene);
    // 撞号 guard 在事务外做：查表要在同一条连接上，放事务里会让事务变长
    // （SQLite 是库级锁，界面别的操作都在等它）。
    final no = await _freshTaskNo();
    final db = await LocalDb.I.db();
    final name = (taskName ?? '').trim();
    final now = DateTime.now().millisecondsSinceEpoch;

    await db.transaction((txn) async {
      // 1) 同场景进行中的那一轮 → 归档（数据不动）
      await txn.update(
          'simple_task',
          <String, Object?>{'status': taskArchived, 'closed_at': now},
          where: 'scene = ? and status = ?',
          whereArgs: <Object?>[sc, taskOpen]);

      // 2) 开新一轮
      await txn.insert('simple_task', <String, Object?>{
        'task_no': no,
        'task_name': name.isEmpty ? null : name,
        'scene': sc,
        'total_items': 0,
        'status': taskOpen,
        'created_at': now,
        'closed_at': null,
      });

      // 3) 写清单
      for (final r in rows) {
        await txn.insert('simple_item', r.toDb(no),
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await txn.update('simple_task',
          <String, Object?>{'total_items': rows.length},
          where: 'task_no = ?', whereArgs: <Object?>[no]);
    });

    return (await findTask(no))!;
  }

  // ============================================================
  // 待盘清单
  // ============================================================

  /// 导入**这一轮**的待盘清单。
  ///
  /// [rows] 是 [SimpleRules.parseCsv] 的产物（已去重、已剔空条码）。
  ///
  /// 🔴 事务里**先清后插**：同一个任务重新导清单时必须整份替换，
  ///    不能"新清单 + 旧清单的残留"混在一起 —— 那种脏数据在导出的对账
  ///    里表现为"多出几个谁也没数过的商品"，而没有人会怀疑是导入逻辑。
  ///
  /// ⚠️ 它**只动清单，不动任何扫码数据**。界面上「换一份清单」走的是
  ///    [startNewRound]（新任务），所以不会出现"清单换了、上一轮扫的数还挂着"
  ///    这种自相矛盾的状态。真要给同一个任务换清单，先把节点删掉。
  Future<int> importItems(String taskNo, List<SimpleImportRow> rows) async {
    final no = await _requireTask(taskNo);

    final db = await LocalDb.I.db();
    await db.transaction((txn) async {
      await txn.delete('simple_item',
          where: 'task_no = ?', whereArgs: <Object?>[no]);
      for (final r in rows) {
        await txn.insert('simple_item', r.toDb(no),
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await txn.update('simple_task', <String, Object?>{'total_items': rows.length},
          where: 'task_no = ?', whereArgs: <Object?>[no]);
    });
    return rows.length;
  }

  /// 某轮的待盘清单，**按导入顺序**（导出照这个排，员工好对数）。
  Future<List<Map<String, dynamic>>> listItems(String taskNo) async {
    final no = await _requireTask(taskNo);
    final db = await LocalDb.I.db();
    return db.query('simple_item',
        where: 'task_no = ?',
        whereArgs: <Object?>[no],
        orderBy: 'seq asc, barcode asc');
  }

  /// 这个条码在不在导入的清单里（扫码准入判定要用）。
  Future<bool> inImportedList(String taskNo, String barcode) async {
    final db = await LocalDb.I.db();
    final rows = await db.query('simple_item',
        columns: <String>['barcode'],
        where: 'task_no = ? and barcode = ?',
        whereArgs: <Object?>[_req(taskNo, 'taskNo'), barcode.trim()],
        limit: 1);
    return rows.isNotEmpty;
  }

  /// 一轮账：清单条数 / 已盘到的品种数 / 清单外的品种数。
  ///
  /// 「已盘 N / M」里的 N **只数清单内的**：N 比 M 还大会让人以为出错了，
  /// 而清单外扫到的那些（口径允许，导出作第三段）单独给一个数。
  Future<SimpleTaskTally> taskTally(String taskNo) async {
    final no = await _requireTask(taskNo);
    final db = await LocalDb.I.db();
    final t = await db.rawQuery(
        'select total_items from simple_task where task_no = ?', <Object?>[no]);
    final rows = await db.rawQuery('''
      select
        count(distinct case when i.barcode is not null then r.barcode end) as in_list,
        count(distinct case when i.barcode is null then r.barcode end)     as off_list
        from scan_record r
        join stocktake_sheet s on s.sheet_no = r.sheet_no
        left join simple_item i
               on i.task_no = s.zone_code and i.barcode = r.barcode
       where s.zone_code = ? and s.sheet_type = ?
    ''', <Object?>[no, InvSheetType.simple]);
    final r = rows.isEmpty ? const <String, Object?>{} : rows.first;
    return SimpleTaskTally(
      totalItems: t.isEmpty ? 0 : _int(t.first['total_items']),
      scannedInList: _int(r['in_list']),
      scannedOffList: _int(r['off_list']),
    );
  }

  // ============================================================
  // 节点（一趟）
  // ============================================================

  /// 某轮的全部节点（按趟次升序）。
  ///
  /// 与 [listItems] 同一个口径：任务号对不上就报错，不给"空列表"
  /// （历史趟次面板显示空的，和"这一趟都还没开"分不清）。
  Future<List<Map<String, dynamic>>> listNodes(String taskNo) async {
    final no = await _requireTask(taskNo);
    final db = await LocalDb.I.db();
    return db.query('stocktake_sheet',
        where: 'zone_code = ? and sheet_type = ?',
        whereArgs: <Object?>[no, InvSheetType.simple],
        orderBy: 'phase asc, started_at asc');
  }

  Future<Map<String, dynamic>?> findNode(String nodeNo) async {
    final db = await LocalDb.I.db();
    final rows = await db.query('stocktake_sheet',
        where: 'sheet_no = ? and sheet_type = ?',
        whereArgs: <Object?>[_req(nodeNo, 'nodeNo'), InvSheetType.simple],
        limit: 1);
    return rows.isEmpty ? null : rows.first;
  }

  /// 某轮某一趟**还开着的**节点。
  Future<Map<String, dynamic>?> openNodeOf(String taskNo, int phase) async {
    final db = await LocalDb.I.db();
    final rows = await db.query('stocktake_sheet',
        where: 'zone_code = ? and sheet_type = ? and phase = ? and status = ?',
        whereArgs: <Object?>[
          _req(taskNo, 'taskNo'),
          InvSheetType.simple,
          phase,
          InvSheetStatus.open,
        ],
        orderBy: 'started_at desc',
        limit: 1);
    return rows.isEmpty ? null : rows.first;
  }

  /// 开某个任务的某一趟（默认复用还开着的那张 —— 一进来就开新的会让
  /// 上次扫的数据"凭空消失"，员工以为丢了）。
  ///
  /// 🔴 **S1 只放开初盘**。复盘 / 差异复盘要 S2 才做，而差异复盘的准入
  ///    依赖"前两趟的差异集"（现在还没算）。这时候**不能**让它"看起来能开"：
  ///    只扫差异集这条限制如果没实现，员工把对上的商品又盘一遍，
  ///    差异复盘就失去意义了 —— 那是当场看不出来的错。
  ///    S2 实现差异集时把下面这个闸门放开，并补上门禁判据。
  Future<Map<String, dynamic>> openOrCreateNode(
    String taskNo,
    int phase, {
    String? operator,
    bool forceNew = false,
  }) async {
    final no = await _requireTask(taskNo);
    if (phase != SimplePhase.first) {
      throw StateError('简易盘点这一版只做初盘这一趟'
          '（${SimplePhase.label(phase)}是下一版的功能）');
    }
    // `!` 是安全的：_requireTask 刚确认过它存在。
    final task = (await findTask(no))!;
    if (_int(task['status']) != taskOpen) {
      throw StateError('这一轮已经归档（${task['task_no']}），不能再开新的趟次');
    }

    if (!forceNew) {
      final exist = await openNodeOf(no, phase);
      if (exist != null) return exist;
    }

    final db = await LocalDb.I.db();
    final base = nodeNo(no, phase);
    var sheetNo = base;
    var guard = 0;
    while (true) {
      final rows = await db.query('stocktake_sheet',
          where: 'sheet_no = ?', whereArgs: <Object?>[sheetNo], limit: 1);
      if (rows.isEmpty) break;
      guard++;
      sheetNo = '${base}x$guard';
      if (guard > 50) throw StateError('节点号连续撞车 50 次，检查系统时间是否异常');
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    await db.insert('stocktake_sheet', <String, Object?>{
      'sheet_no': sheetNo,
      'zone_code': no, // 🔴 借来存**任务号**，不是点位码
      'phase': phase,
      'status': InvSheetStatus.open,
      'operator': operator,
      'started_at': now,
      'sheet_type': InvSheetType.simple,
    });
    return (await findNode(sheetNo))!;
  }

  // ============================================================
  // 扫码
  // ============================================================

  /// 扫一笔。**判定 + 落库在同一个事务里**：判定用的行数必须写着的那一刻是准的，
  /// 否则扫码枪连发时会算错上限、放错商品进来。
  ///
  /// 🔴 **同一个条码在同一趟里再扫 = 累加**（方案 §0 第 4 条）。
  ///    落库方式是"改写那一行的数量"（不是插第二条流水），与「盘点」的
  ///    `InventoryRepo.scan` 完全同一个语义 —— 两个通道对"再扫一次"的行为
  ///    必须一致，不然员工换个入口就得到不同的数。
  ///
  /// [allowedBarcodes] 只有**差异复盘**那一趟才传（S2）。S1 不传（初盘全量扫）。
  Future<SimpleScanResult> scan(
    String nodeNo,
    String barcode, {
    double qty = 1,
    Set<String>? allowedBarcodes,
  }) async {
    final no = _req(nodeNo, 'nodeNo');
    final code = _req(barcode, 'barcode');
    if (!qty.isFinite || qty <= 0) {
      throw ArgumentError.value(qty, 'qty', '数量必须大于 0（要撤掉这一行请调 deleteRow）');
    }

    final db = await LocalDb.I.db();
    return db.transaction((txn) async {
      final nodeRows = await txn.query('stocktake_sheet',
          where: 'sheet_no = ? and sheet_type = ?',
          whereArgs: <Object?>[no, InvSheetType.simple],
          limit: 1);
      if (nodeRows.isEmpty) {
        throw StateError('这个趟次不存在（$no），可能已被清除数据删掉');
      }
      final node = nodeRows.first;
      final taskNo = (node['zone_code'] ?? '').toString();
      final phase = _int(node['phase']);
      final status = _int(node['status']);

      final exist = await txn.query('scan_record',
          where: 'sheet_no = ? and barcode = ?',
          whereArgs: <Object?>[no, code],
          limit: 1);

      final cnt = await txn.rawQuery(
          'select count(*) as c from scan_record where sheet_no = ?',
          <Object?>[no]);
      final currentRows = _int(cnt.first['c']);

      // 清单内外的判定：读**导入的清单**，不读商档。
      final inList = (await txn.query('simple_item',
              columns: <String>['barcode'],
              where: 'task_no = ? and barcode = ?',
              whereArgs: <Object?>[taskNo, code],
              limit: 1))
          .isNotEmpty;

      final decision = SimpleRules.decide(
        phase: phase,
        barcode: code,
        sheetEditable: InvSheetStatus.editable(status),
        currentRows: currentRows,
        alreadyInNode: exist.isNotEmpty,
        allowedBarcodes: allowedBarcodes,
        inImportedList: inList,
        maxRows: maxRows,
      );

      final existId = exist.isEmpty ? null : _int(exist.first['id']);
      if (!decision.accepted) {
        return SimpleScanResult(decision, rowId: existId);
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
          'loc_code': null, // 简易通道不用货架位
          'uploaded': 0,
        });
        return SimpleScanResult(decision, rowId: id, newQty: qty);
      }

      final oldQty = _dbl(exist.first['qty']);
      final newQty = oldQty + qty;
      await txn.update(
        'scan_record',
        <String, Object?>{'qty': newQty, 'scanned_at': now, 'uploaded': 0},
        where: 'id = ?',
        whereArgs: <Object?>[existId],
      );
      return SimpleScanResult(decision, rowId: existId, newQty: newQty);
    });
  }

  /// 本趟的明细。
  ///
  /// 🔴 商品名从 **`simple_item`（导入的清单）** 左连，**不连 stock_master**。
  ///    必须是 LEFT JOIN：**清单外的商品**（口径允许扫、导出作第三段）
  ///    在 simple_item 里没有行，INNER JOIN 会让它整行消失 ——
  ///    而"少了一行"在明细里根本看不出来，员工会以为没扫上、再扫一遍。
  ///
  /// 排序按 id 升序（＝扫描先后），不是按条码：员工按自己刚才扫的顺序核对最顺，
  /// 按条码排会让刚扫的那条跑到列表中间去。
  Future<List<Map<String, dynamic>>> listNodeRows(String nodeNo) async {
    final db = await LocalDb.I.db();
    return db.rawQuery('''
      select r.id, r.sheet_no, r.barcode, r.qty, r.scanned_at, r.phase,
             r.uploaded,
             i.name as name, i.spec as spec, i.seq as seq
        from scan_record r
        left join stocktake_sheet s on s.sheet_no = r.sheet_no
        left join simple_item i
               on i.task_no = s.zone_code and i.barcode = r.barcode
       where r.sheet_no = ?
       order by r.id asc
    ''', <Object?>[_req(nodeNo, 'nodeNo')]);
  }

  /// 本趟"条码 → 合计数量"。
  ///
  /// 用 `SUM(...) GROUP BY` 而不是直接把行读出来：落库时同码是累加在一行上的
  /// （见 [scan]），一行就是一条，SUM 在这儿是恒等的；但万一同一个条码
  /// 因为历史原因留了两行，SUM 仍然给**正确的合计**，而"只读第一行"会少货。
  Future<Map<String, double>> nodeQtyMap(String nodeNo) async {
    final db = await LocalDb.I.db();
    final rows = await db.rawQuery('''
      select barcode, sum(qty) as qty
        from scan_record
       where sheet_no = ?
       group by barcode
    ''', <Object?>[_req(nodeNo, 'nodeNo')]);
    final out = <String, double>{};
    for (final r in rows) {
      final code = (r['barcode'] ?? '').toString().trim();
      if (code.isEmpty) continue;
      out[code] = _dbl(r['qty']);
    }
    return out;
  }

  /// 本趟小结：行数 / 合计数量 / 清单外的品种数。
  Future<SimpleNodeTally> nodeTally(String nodeNo) async {
    final db = await LocalDb.I.db();
    final rows = await db.rawQuery('''
      select count(*) as rows_,
             coalesce(sum(r.qty), 0) as total_qty,
             sum(case when i.barcode is null then 1 else 0 end) as off_list
        from scan_record r
        left join stocktake_sheet s on s.sheet_no = r.sheet_no
        left join simple_item i
               on i.task_no = s.zone_code and i.barcode = r.barcode
       where r.sheet_no = ?
    ''', <Object?>[_req(nodeNo, 'nodeNo')]);
    final r = rows.isEmpty ? const <String, Object?>{} : rows.first;
    return SimpleNodeTally(
      rows: _int(r['rows_']),
      totalQty: _dbl(r['total_qty']),
      offList: _int(r['off_list']),
    );
  }

  Future<void> setQty(int id, double qty) async {
    final err = SimpleRules.qtyError(qty.toString());
    if (err != null) throw ArgumentError.value(qty, 'qty', err);
    final db = await LocalDb.I.db();
    await db.update('scan_record', <String, Object?>{'qty': qty, 'uploaded': 0},
        where: 'id = ?', whereArgs: <Object?>[id]);
  }

  Future<int> deleteRow(int id) async {
    final db = await LocalDb.I.db();
    return db.delete('scan_record', where: 'id = ?', whereArgs: <Object?>[id]);
  }

  // ============================================================
  // 状态流转
  // ============================================================

  /// 完成本趟（提交）：本地锁死，不再接受写入。可以撤销。
  Future<int> submitNode(String nodeNo) async {
    final db = await LocalDb.I.db();
    return db.update(
        'stocktake_sheet',
        <String, Object?>{
          'status': InvSheetStatus.submitted,
          'submitted_at': DateTime.now().millisecondsSinceEpoch,
        },
        where: 'sheet_no = ? and sheet_type = ?',
        whereArgs: <Object?>[_req(nodeNo, 'nodeNo'), InvSheetType.simple]);
  }

  /// 撤销提交（交错了要能改回来，否则员工只能重扫一遍）。
  Future<int> reopenNode(String nodeNo) async {
    final db = await LocalDb.I.db();
    return db.update(
        'stocktake_sheet',
        <String, Object?>{'status': InvSheetStatus.open, 'submitted_at': null},
        where: 'sheet_no = ? and sheet_type = ?',
        whereArgs: <Object?>[_req(nodeNo, 'nodeNo'), InvSheetType.simple]);
  }

  /// 清空本机的简易盘点数据（界面走在二次确认路径上）。
  /// 返回删掉的【任务 / 节点 / 明细】条数。
  ///
  /// 🔴 **每一处都必须按类型/单号限定**：
  ///    · `simple_task` / `simple_item` 是这条通道独有的，整表清没问题；
  ///    · `stocktake_sheet` 必须 `sheet_type='simple'` —— 不能无脑清表，
  ///      那会把盘点单和减货单一起删掉（**这个 bug 真发生过**，见
  ///      「库房减货」那一版的交付说明：清盘点数据把减货单头删掉了）；
  ///    · `scan_record` 必须**逐个节点单号**删，不能按 `sheet_type` 关联删，
  ///      因为流水表里根本没有类型列 —— 按 sheet_no 删是唯一不会误伤的做法。
  Future<Map<String, int>> clearAll() async {
    final db = await LocalDb.I.db();
    var tasks = 0, nodes = 0, rows = 0;
    await db.transaction((txn) async {
      final nos = (await txn.query('stocktake_sheet',
              columns: <String>['sheet_no'],
              where: 'sheet_type = ?',
              whereArgs: <Object?>[InvSheetType.simple]))
          .map((r) => (r['sheet_no'] ?? '').toString())
          .toList();
      nodes = nos.length;
      for (final no in nos) {
        rows += await txn.delete('scan_record',
            where: 'sheet_no = ?', whereArgs: <Object?>[no]);
      }
      await txn.delete('stocktake_sheet',
          where: 'sheet_type = ?', whereArgs: <Object?>[InvSheetType.simple]);

      // 任务与清单在删之前先数出来 —— delete 返回的是**被删的行数**，
      // 拿"清单条数"当"任务轮数"报给用户是错的（一轮一千条清单会报成 1000 轮）。
      final t = await txn.rawQuery('select count(*) as c from simple_task');
      tasks = _int(t.isEmpty ? null : t.first['c']);
      await txn.delete('simple_item');
      await txn.delete('simple_task');
    });
    return <String, int>{'tasks': tasks, 'nodes': nodes, 'rows': rows};
  }
}

/// 一轮的账（界面顶部的「已盘 N / M 个品」）。
class SimpleTaskTally {
  const SimpleTaskTally({
    required this.totalItems,
    required this.scannedInList,
    required this.scannedOffList,
  });

  /// 导入清单的条数。
  final int totalItems;

  /// 清单里已经盘到的品种数。
  final int scannedInList;

  /// 清单外扫到的品种数（导出作第三段）。
  final int scannedOffList;

  /// 「已盘 51 / 1000 个品」。
  String get progressText => '已盘 $scannedInList / $totalItems 个品';

  bool get allDone => totalItems > 0 && scannedInList >= totalItems;
}

/// 一趟的账。
class SimpleNodeTally {
  const SimpleNodeTally({
    required this.rows,
    required this.totalQty,
    required this.offList,
  });

  final int rows;
  final double totalQty;

  /// 清单外的品种数（界面给黄条提醒用）。
  final int offList;

  bool get isEmpty => rows == 0;
}
