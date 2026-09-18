import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_common_ffi.dart';

/// 本地 SQLite 引擎 + 迁移框架（小智 IM「离线地基」第一期）。
///
/// 为什么要有这张本地表？
/// ------------------------
/// 现在 App 本地持久化几乎为零（只有 shared_preferences 键值存储），数据一旦
/// App 被杀就没了。本期目标是给后续的「原生门店盘点模块」打底：盘点场景必然
/// 弱网/断网，扫码记录必须先在本地落库、联网后再批量上传，否则数据会丢。
/// 这两张表就是盘点流程的真骨架，先建好：
///   - stock_master：商品主数据（条码 + 名称/规格/单位/单价/账面数量），盘点前
///     从服务端拉一份缓存到本地，断网时也能查到"这个条码是什么、账面是多少"。
///   - scan_record：扫码流水（哪张盘点单、哪个条码、扫了多少、何时扫、是否已上传），
///     弱网时只管往里写，uploaded 标记等联网后回写。
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
  static const int schemaVersion = 1;

  LocalDb._();
  static final LocalDb I = LocalDb._();

  Database? _db;

  /// 有序迁移列表：索引 = 目标版本 - 1。
  /// 未来加表/改表 = 在末尾追加，禁止改已有函数。
  static final List<Future<void> Function(Database)> _migrations = [
    // v1：盘点骨架的两张表
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
  ];

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
