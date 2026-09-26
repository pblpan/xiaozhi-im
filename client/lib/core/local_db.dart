import 'dart:io';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_common_ffi.dart';

/// 本地 SQLite 引擎 + 迁移框架（小智 IM「离线地基」第一期）。
///
/// 为什么要有这张本地表？
/// ------------------------
/// 现在 App 本地持久化几乎为零（只有 shared_preferences 键值存储），数据一旦
/// App 被杀就没了。本期目标是给后续的原生「扫码枪」模块打底：扫码场景必然
/// 弱网/断网，扫码记录必须先在本地落库、联网后再批量上传，否则数据会丢。
/// 这两张表就是扫码流程的真骨架，先建好：
///   - stock_master：商品主数据（条码 + 名称/规格/单位/单价/账面数量），扫码前
///     从服务端拉一份缓存到本地，断网时也能查到"这个条码是什么、账面是多少"。
///   - scan_record：扫码流水（哪张扫码单、哪个条码、扫了多少、何时扫、是否已上传），
///     弱网时只管往里写，uploaded 标记等联网后回写。
///
/// v2（盘点内核）在这一层之上又加了四张表：盘点位 stocktake_zone、
/// 库位货架位 location、商品↔货架位绑定 barcode_location、盘点单 stocktake_sheet，
/// 并给 scan_record 追加 phase（初盘/复盘/抽盘）+ loc_code。
/// 见 [_migrations] 里 v2 那段注释。
///
/// 迁移框架为什么要写成「有序列表」？
/// --------------------------------
/// 以后加表/加字段 = 在 [_migrations] 末尾追加一个新函数（索引 = 目标版本-1），
/// 不要在已有函数里改逻辑。这样 v2、v3 永远只 append，老用户在任意旧版本上升级
/// 都能从 oldV+1 一路跑到当前版本，不会漏跑也不会把建表语句改坏。
///
/// 桌面 / 移动两条 factory 分支为什么必须这么写？
/// -------------------------------------------
/// sqflite 在 Android/iOS 上有内建的原生 factory（openDatabase 直接用），但在
/// Windows/Linux/macOS 上没有内建 factory，直接 openDatabase 会因为没有可用的
/// 实现而崩。所以桌面端必须先 sqfliteFfiInit() 加载 sqlite3_flutter_libs 提供的
/// 原生库，再用 databaseFactoryFfi 打开。两端区别只在这条 factory，表的 schema
/// 完全一致，所以逻辑上只切 factory、不切 SQL。
///
/// 路径也分两条：桌面端 path_provider 不支持 getDatabasesPath()，库文件必须落在
/// getApplicationSupportDirectory() 下，并先 createSync(recursive:true) 保证目录在；
/// 移动端用 getDatabasesPath() 再拼文件名。
class LocalDb {
  static const int schemaVersion = 5;

  LocalDb._();
  static final LocalDb I = LocalDb._();

  Database? _db;

  /// 有序迁移列表：索引 = 目标版本 - 1。
  /// 未来加表/改表 = 在末尾追加，禁止改已有函数。
  static final List<Future<void> Function(Database)> _migrations = [
    // v1：扫码枪骨架的两张表
    (Database db) async {
      await db.execute('''
        CREATE TABLE stock_master (
          barcode TEXT PRIMARY KEY,
          name TEXT,
          spec TEXT,
          unit TEXT,
          unit_price REAL,
          account_qty REAL,
          source TEXT,
          updated_at INTEGER
        )
      ''');
      await db.execute('''
        CREATE TABLE scan_record (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          sheet_no TEXT,
          barcode TEXT,
          qty REAL,
          scanned_at INTEGER,
          note TEXT,
          uploaded INTEGER NOT NULL DEFAULT 0
        )
      ''');
      await db.execute(
          'CREATE INDEX idx_scan_record_sheet ON scan_record(sheet_no)');
    },

    // v2：盘点内核（盘点位 / 库位货架位 / 商品→货架位绑定 / 盘点单），
    //     并给 scan_record 追加 phase + loc_code 两列。
    //
    // 🔴 表名沿用方案文档（docs/盘点复刻与开放接口方案-v1.md §P1）：
    //    stocktake_zone / location / barcode_location / stocktake_sheet。
    //    别自作主张改成 inv_ 前缀 —— 文档、接口、管理台三处都以这套名字对齐，
    //    单方面改名只会让"文档写的和代码里的不是一张表"。
    //
    // 🔴 为什么 scan_record 是**加列**而不是建新表：
    //    盘点单和扫码单共用这一张流水表（都是"某单某条码某数量"），
    //    phase 默认 1 让**老的扫码流水一行都不用改**就能继续读 ——
    //    扫码枪（stocktake 模块）完全不知道自己脚下多了两列。
    //    存量行 phase=1、loc_code=NULL，语义正好是"没分阶段的采集"。
    (Database db) async {
      // 盘点位（一个门店可以有多个盘点位，如"生鲜区""日配区"）
      await db.execute('''
        CREATE TABLE stocktake_zone (
          zone_code  TEXT PRIMARY KEY,
          zone_name  TEXT,
          store_code TEXT,
          locked     INTEGER NOT NULL DEFAULT 0,
          created_at INTEGER
        )
      ''');

      // 库位 / 货架位（挂在盘点位下）
      await db.execute('''
        CREATE TABLE location (
          loc_code   TEXT PRIMARY KEY,
          loc_name   TEXT,
          zone_code  TEXT,
          sort_no    INTEGER,
          created_at INTEGER
        )
      ''');
      await db.execute(
          'CREATE INDEX idx_location_zone ON location(zone_code)');

      // 商品 ↔ 货架位 绑定。一个商品可以在多个货架位（一品多点），
      // 所以主键是 (barcode, loc_code) 而不是单列 ——
      // 单列主键会让第二个货架位的绑定把第一个顶掉，盘点时货就"消失"了。
      await db.execute('''
        CREATE TABLE barcode_location (
          barcode  TEXT NOT NULL,
          loc_code TEXT NOT NULL,
          bound_at INTEGER,
          PRIMARY KEY (barcode, loc_code)
        )
      ''');
      await db.execute(
          'CREATE INDEX idx_barcode_location_loc ON barcode_location(loc_code)');

      // 盘点单：一张单 = 一个盘点位 × 一个阶段。
      // phase  1初盘 2复盘 3抽盘
      // status 0进行中 1已提交(已锁) 2已上传
      await db.execute('''
        CREATE TABLE stocktake_sheet (
          sheet_no     TEXT PRIMARY KEY,
          zone_code    TEXT,
          phase        INTEGER NOT NULL DEFAULT 1,
          status       INTEGER NOT NULL DEFAULT 0,
          operator     TEXT,
          started_at   INTEGER,
          submitted_at INTEGER,
          uploaded_at  INTEGER
        )
      ''');
      await db.execute(
          'CREATE INDEX idx_sheet_zone_phase ON stocktake_sheet(zone_code, phase)');

      // 存量扫码流水落成"初盘、无货架位"，语义上等于改造前的行为。
      await db.execute(
          'ALTER TABLE scan_record ADD COLUMN phase INTEGER NOT NULL DEFAULT 1');
      await db.execute('ALTER TABLE scan_record ADD COLUMN loc_code TEXT');
      // 按 (单号, 阶段) 取流水是最热的查询：界面每扫一次都要重算。
      await db.execute(
          'CREATE INDEX idx_scan_record_sheet_phase ON scan_record(sheet_no, phase)');
    },

    // v3：单据加"类型"列，把**库房减货单**挂到同一套单据/流水上。
    //
    // 🔴 为什么是加一列而不是建一套新表：
    //    减货单和盘点单在结构上是同一件事 —— "某单、某条码、某数量、
    //    某个状态（进行中/已提交/已上传）"。差别只在**规则**（减货不看点位、
    //    不看阶段、同码不许出现两次）。另建一套表就要把提交/上传/导出/
    //    本地序号这四条链路各抄一遍，抄完两边就会开始漂移。
    //
    // 🔴 默认值 'stocktake' 是关键：盘点的存量单**一行都不用改**，
    //    读出来的语义就是"这是一张盘点单"。老版本 App 读新库时看不到这一列，
    //    也照样能用（它只 select 自己认识的列）。
    //
    // 补货单等做的时候再追加 sub_kind（生鲜/杂百）—— 现在不加，
    // 一个没人读的列比没有这一列更糟（下一个人会以为已经支持了）。
    (Database db) async {
      await db.execute(
          "ALTER TABLE stocktake_sheet ADD COLUMN sheet_type TEXT NOT NULL DEFAULT 'stocktake'");
      await db.execute(
          'CREATE INDEX idx_sheet_type_status ON stocktake_sheet(sheet_type, status)');
    },

    // v4：简易盘点（`simple_stocktake`）的**任务**与**待盘清单**两张表。
    //
    // 🔴 为什么只加两张表，节点与扫码明细还是复用现有两张：
    //    简易通道的"一趟"就是一张 `stocktake_sheet`（`sheet_type='simple'`、
    //    `zone_code` 借来存任务号、`phase` 用 1/2/3），"一笔扫码"就是一条
    //    `scan_record`（`sheet_no` = 节点号）。提交 / 撤销 / 本地单号 / 导出
    //    这四条链路现有代码已经写好且有测试钉着，另起一套表等于各抄一遍。
    //    见 docs/简易盘点通道方案-v1.md §3。
    //
    // ⚠️ `zone_code` 借来存任务号：简易通道**本来就不看点位**，这一列在这条
    //    通道里没有别的含义。借它比新增一列（要动所有读表的地方）划算。
    //
    // 🔴 `simple_item` 是**这一轮导入的清单**，不是商品档案：
    //    简易通道**绝不读** `stock_master` / `stocktake_zone` / `location` /
    //    `barcode_location` 里的任何一个 —— 一旦读了，"盘点那边改了设置、
    //    简易盘点跟着变"这种问题就会冒出来，而且极难查。商品名称只从导入的
    //    CSV 来（CSV 里没有名称就留空）。
    //
    // 主键写成 (task_no, barcode)：同一轮里同一个条码重复导入没有意义，
    // 用主键让"重复只留一行"这件事由数据库兜底，而不是只靠导入前的代码去重。
    (Database db) async {
      await db.execute('''
        CREATE TABLE simple_task (
          task_no     TEXT PRIMARY KEY,
          task_name   TEXT,
          scene       TEXT NOT NULL DEFAULT 'store',
          total_items INTEGER NOT NULL DEFAULT 0,
          status      INTEGER NOT NULL DEFAULT 0,
          created_at  INTEGER,
          closed_at   INTEGER
        )
      ''');
      await db.execute(
          'CREATE INDEX idx_simple_task_scene ON simple_task(scene, status)');

      await db.execute('''
        CREATE TABLE simple_item (
          task_no  TEXT NOT NULL,
          barcode  TEXT NOT NULL,
          name     TEXT,
          spec     TEXT,
          seq      INTEGER,
          PRIMARY KEY (task_no, barcode)
        )
      ''');
      await db.execute(
          'CREATE INDEX idx_simple_item_task ON simple_item(task_no, seq)');
    },
    // v5：商品档案补「进价」。
    //
    // 🔴 服务端标准六列里新加了进价（barcode/name/spec/进价/售价/库存），
    //    客户端这张表是商档的**离线副本**，不同步这一列，同步完本地永远
    //    是空的 —— 而且不报错（2026-09-26 的教训：字段被静默丢弃最难查）。
    //    叫 SaveToRefresh，等补货/盘点的金额口径真要用它时才有数据。
    (Database db) async {
      await _addColumn(db, 'stock_master', 'purchase_price', 'REAL');
    },
  ];

  /// 有序迁移列表（**仅供测试**读取）。生产代码不要碰它。
  ///
  /// 为什么必须把它开出来：唯一能真正验证"老用户升级不丢数据"的做法，
  /// 就是**用真身**在 v1 建一个库、塞数据、再用 db() 打开触发升级。
  /// 若测试里自己抄一份 v1 DDL，那份抄本和真身一旦漂移，测试会给出
  /// **假安心**（"升级没问题"—— 其实测的是抄出来那个不存在的库）。
  @visibleForTesting
  static List<Future<void> Function(Database)> get migrationsForTest =>
      _migrations;

  /// 库文件路径（**仅供测试**：用它在测试里手动建老版本库）。
  @visibleForTesting
  Future<String> dbPathForTest() => _dbPath();

  /// 单例访问点：懒开，开了缓存 handle，后续调用都返回同一个实例。
  Future<Database> db() async {
    if (_db != null && _db!.isOpen) return _db!;
    _db = await _open();
    return _db!;
  }

  Future<Database> _open() async {
    final path = await _dbPath();

    if (_isDesktop) {
      // 桌面端没有 sqflite 默认 factory，必须走 FFI + 原生 sqlite3 库。
      sqfliteFfiInit();
      return databaseFactoryFfi.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: schemaVersion,
          onCreate: _onCreate,
          onUpgrade: _onUpgrade,
        ),
      );
    }

    // 移动端走 sqflite 默认 factory（Android/iOS 内建）。
    return openDatabase(
      path,
      version: schemaVersion,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  /// 平台分支：桌面走 FFI，移动走默认 factory。
  static bool get _isDesktop =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  /// 库文件路径：桌面落在 ApplicationSupport、移动落在 DatabasesPath。
  Future<String> _dbPath() async {
    if (_isDesktop) {
      final dir = await getApplicationSupportDirectory();
      // 桌面端该目录可能还不存在，必须先建出来，否则 open 直接失败。
      dir.createSync(recursive: true);
      return p.join(dir.path, 'xiaozhi.db');
    }
    final dir = await getDatabasesPath();
    return p.join(dir, 'xiaozhi.db');
  }

  /// 新建库（onCreate 收到的 version 即当前 schemaVersion）。
  /// 冷启动在 v1 时只跑 _migrations[0]；从 0 直装到 v5 会跑 [0,1,2,3,4]。
  /// ⚠️ 加迁移时这句里的数字要跟着改（写死的版本号最容易变成假说明）。
  Future<void> _onCreate(Database db, int version) async {
    for (var i = 1; i <= version; i++) {
      await _migrations[i - 1](db);
    }
  }

  /// 升级：从 oldV 跑 [oldV .. newV] 之间的每一个迁移，绝不漏。
  Future<void> _onUpgrade(Database db, int oldV, int newV) async {
    for (var i = oldV + 1; i <= newV; i++) {
      await _migrations[i - 1](db);
    }
  }

  /// 关闭并丢弃缓存的 handle。再次 db() 会重新打开同一个库文件。
  Future<void> close() async {
    if (_db != null && _db!.isOpen) {
      await _db!.close();
    }
    _db = null;
  }

  /// 仅供测试：删库重开。生产代码禁止调用。
  ///
  /// 直接删文件，把 sqlite3 可能落下的 -wal / -shm / -journal 一并清掉，
  /// 否则残留 journal 会让下次 open 读到旧数据，测不出"重开不丢"。
  Future<void> resetForTest() async {
    await close();
    final path = await _dbPath();
    final candidates = [path, '$path-wal', '$path-shm', '$path-journal'];
    for (final c in candidates) {
      final f = File(c);
      if (f.existsSync()) await f.delete();
    }
    _db = null;
  }
}

/// 给已有表补一列，**列在就什么都不做**。
///
/// 🔴 为什么不能直接 `ALTER TABLE … ADD COLUMN`：同一份库可能走过不同路径
///    （新建时按最新 DDL 建表、之后再跑迁移；或者老库升级），
///    直接 ALTER 会撞 "duplicate column name"，SQLite 抛错 = App 起不来。
///    加列这种"跑一次就够"的事，判据必须写在 SQL 之前。
Future<void> _addColumn(
    Database db, String table, String column, String type) async {
  final cols = await db.rawQuery('PRAGMA table_info($table)');
  final has = cols.any((r) => (r['name'] ?? '').toString() == column);
  if (has) return;
  await db.execute('ALTER TABLE $table ADD COLUMN $column $type');
}
