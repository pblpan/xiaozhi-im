import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:xiaozhi_im_client/core/local_db.dart';

/// 本地 SQLite 引擎（离线地基）的单元测试。
///
/// 这里要钉死的不是"能跑"，而是"弱网/断网/App 被杀后数据真的还在"：
///   - 库能开、schema 版本对得上（以后升版本迁移框架不能把它搞丢）；
///   - 两张表插入→查询往返，字段值**和类型**都对（REAL 不能变 int、INTEGER 不能变 double）；
///   - idempotent：连续 db() 拿同一个 handle，close 后再开不丢数据；
///   - 索引存在（查某张扫码单的所有记录要靠它）；
///   - 反向断言：同 barcode 插两行必须被主键拒绝——这条不过说明主键没生效，
///     要回头修 schema，不能删断言；
///   - 桌面 ffi 分支在本机（Windows）能真的打开并落盘。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // flutter test 桌面环境下 path_provider 没有原生实现，getApplicationSupportDirectory
  // 会直接抛 MissingPluginException（本地库根本开不了）。这里 mock 出 ApplicationSupport
  // 目录，指向系统临时目录下的固定子目录——resetForTest 会清掉它，不污染真实 AppData。
  // 这只在测试里生效，生产代码照旧走真实的 path_provider。
  const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
  final supportDir = '${Directory.systemTemp.path}/xz_local_db_test';
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(pathChannel, (call) async {
    if (call.method == 'getApplicationSupportDirectory') return supportDir;
    return null;
  });

  setUp(() async {
    await LocalDb.I.resetForTest();
  });

  tearDown(() async {
    await LocalDb.I.close();
  });

  test('库能打开，PRAGMA user_version == schemaVersion', () async {
    final db = await LocalDb.I.db();
    final rows = await db.rawQuery('PRAGMA user_version');
    final ver = rows.first.values.first;
    expect(ver, LocalDb.schemaVersion,
        reason: '建库时没把 user_version 设成 schemaVersion，迁移框架会判定错版本');
  });

  test('桌面 ffi 分支能在本机跑起来并落盘到 ApplicationSupport', () async {
    final db = await LocalDb.I.db();
    expect(db.isOpen, isTrue);
    // 本机就是 Windows，走的是 sqfliteFfiInit + databaseFactoryFfi。
    // 验证库文件确实落在 getApplicationSupportDirectory 下且存在。
    final dir = await getApplicationSupportDirectory();
    final path = p.join(dir.path, 'xiaozhi.db');
    expect(File(path).existsSync(), isTrue,
        reason: 'ffi 分支没在 ApplicationSupport 下生成 xiaozhi.db，路径分支可能写错');
  });

  test('stock_master 插入+查询往返（字段值与类型都对）', () async {
    final db = await LocalDb.I.db();
    await db.insert('stock_master', {
      'barcode': '6901234500001',
      'name': '海盐饼干',
      'spec': '200g/袋',
      'unit': '袋',
      'unit_price': 12.5,
      'account_qty': 30.0,
      'source': 'server',
      'updated_at': 1700000000000,
    });

    final rows = await db.query('stock_master',
        where: 'barcode = ?', whereArgs: ['6901234500001']);
    expect(rows, hasLength(1));
    final row = rows.first;

    expect(row['barcode'], '6901234500001');
    expect(row['name'], '海盐饼干');
    expect(row['spec'], '200g/袋');
    expect(row['unit'], '袋');
    expect(row['source'], 'server');

    // 类型不能悄悄变形：单价/账面数量是 REAL，时间戳是 INTEGER。
    expect(row['unit_price'], isA<double>());
    expect(row['unit_price'], 12.5);
    expect(row['account_qty'], isA<double>());
    expect(row['account_qty'], 30.0);
    expect(row['updated_at'], isA<int>());
    expect(row['updated_at'], 1700000000000);
  });

  test('scan_record 插入+查询往返（含自增 id 与默认值）', () async {
    final db = await LocalDb.I.db();
    final id = await db.insert('scan_record', {
      'sheet_no': 'PD20260918',
      'barcode': '6901234500001',
      'qty': 3.0,
      'scanned_at': 1700000000000,
      'note': '货架A',
    });
    expect(id, greaterThan(0), reason: 'AUTOINCREMENT 没生效，id 没自增出来');

    final rows =
        await db.query('scan_record', where: 'id = ?', whereArgs: [id]);
    expect(rows, hasLength(1));
    final row = rows.first;

    expect(row['sheet_no'], 'PD20260918');
    expect(row['barcode'], '6901234500001');
    expect(row['qty'], isA<double>());
    expect(row['qty'], 3.0);
    expect(row['scanned_at'], isA<int>());
    expect(row['scanned_at'], 1700000000000);
    expect(row['note'], '货架A');
    // uploaded 有 NOT NULL DEFAULT 0
    expect(row['uploaded'], isA<int>());
    expect(row['uploaded'], 0);
  });

  test('幂等：连续 db() 两次拿到同一个 handle', () async {
    final a = await LocalDb.I.db();
    final b = await LocalDb.I.db();
    expect(identical(a, b), isTrue,
        reason: 'db() 没缓存 handle，每次都重开——close 后状态会丢');
  });

  test('重开不丢数据：close 后重新打开仍能查到', () async {
    final db = await LocalDb.I.db();
    await db.insert('stock_master', {
      'barcode': '6901234500002',
      'name': '椰子水',
      'unit': '瓶',
      'unit_price': 8.0,
      'account_qty': 12.0,
      'source': 'server',
      'updated_at': 1700000000999,
    });

    // 模拟 App 被杀：关掉当前连接（handle 也清掉）。
    await LocalDb.I.close();

    // 重新打开（全新进程从同一个库文件恢复）。
    final db2 = await LocalDb.I.db();
    final rows = await db2.query('stock_master',
        where: 'barcode = ?', whereArgs: ['6901234500002']);
    expect(rows, hasLength(1),
        reason: '重开后查不到——本地持久化没落地，扫码数据会丢');
    expect(rows.first['name'], '椰子水');
  });

  test('索引 idx_scan_record_sheet 存在', () async {
    final db = await LocalDb.I.db();
    final rows = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'scan_record'");
    final names = rows.map((r) => r['name']).toList();
    expect(names, contains('idx_scan_record_sheet'),
        reason: '索引没建出来，按单号查扫码会全表扫');
  });

  test('反向断言：同 barcode 插两行必须被主键拒绝', () async {
    final db = await LocalDb.I.db();
    await db.insert('stock_master', {
      'barcode': '6901234500003',
      'name': '第一版',
      'unit': '个',
      'unit_price': 1.0,
      'account_qty': 1.0,
      'source': 'server',
      'updated_at': 1,
    });

    // 第二条同主键 → 必须抛 SQLite 约束异常。
    // 用 expect(..., throwsA(...)) 会被 test 框架 await，无需手动 expectLater。
    expect(() => db.insert('stock_master', {
          'barcode': '6901234500003',
          'name': '想覆盖但没用',
          'unit': '个',
          'unit_price': 2.0,
          'account_qty': 2.0,
          'source': 'server',
          'updated_at': 2,
        }), throwsA(isA<DatabaseException>()),
        reason: '同 barcode 居然插进去了——PRIMARY KEY 没生效，扫码会重复落库');

    // 确认只有一行（拒绝是真正的拒绝，不是异常被吞了）。
    final after = await db.query('stock_master');
    expect(after, hasLength(1),
        reason: '约束异常抛了但数据还是写进去了，主键形同虚设');
  });
}
