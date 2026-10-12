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
  static const int schemaVersion = 4;

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

    // v3：扫码单命名（龙哥 2026-10-04）。
    // 单据一多，光看 PD+时间戳的单号分不清哪张单里是什么；
    // 新建时弹窗起名，列表/顶栏优先显示名字。
    // 为什么单独一张 meta 表而不是给 scan_record 加列：名字是**单据级**属性，
    // 加到流水行上要么冗余十几万倍、要么只有每单第一行有值（读的时候还要挑）。
    (Database db) async {
      await db.execute('''
        CREATE TABLE sheet_meta (
          sheet_no   TEXT PRIMARY KEY,
          name       TEXT,
          created_at INTEGER
        )
      ''');
    },

    // v4：商档补四列（龙哥 2026-10-12）。
    // 把"商档查询"对齐到 IM 客户端 0.26.68：确认卡要显示
    // 进价 / 会员价 / 特价 / 供应商。这四列都是**可选**——老的 7 列商档
    // （好又多版旧内置档、员工手导的 4 列模板）落库时这四项为 NULL，
    // 界面按"没有就不显示"处理，不会崩。
    //
    // 🔴 加列用 PRAGMA 判存在再 ALTER（幂等）：迁移框架只在版本跳变时跑一次，
    // 但测试里会反复 resetForTest 重开库、以及未来若有人手改 schemaVersion 回退，
    // 重复 ALTER 会抛 "duplicate column" 把整个升级砸挂、App 起不来。
    // 逐列判断、缺哪个加哪个，最稳。
    (Database db) async {
      final cols = (await db.rawQuery('PRAGMA table_info(stock_master)'))
          .map((r) => (r['name'] as String))
          .toSet();
      final add = <String, String>{
        'purchase_price': 'REAL', // 进价
        'member_price': 'REAL', // 会员价
        'special_price': 'REAL', // 特价
        'supplier': 'TEXT', // 供应商名称
      };
      for (final entry in add.entries) {
        if (!cols.contains(entry.key)) {
          await db.execute(
              'ALTER TABLE stock_master ADD COLUMN ${entry.key} ${entry.value}');
        }
      }
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
  /// 冷启动在 v1 时只跑 _migrations[0]；将来从 0 直装到 v3 会跑 [0,1,2]。
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
