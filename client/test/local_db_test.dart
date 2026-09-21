import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_common_ffi.dart';
import 'package:xiaozhi_im_client/core/inventory_rules.dart';
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

  // ============================================================
  // v1 → v2 迁移（盘点内核）
  // ============================================================
  //
  // 这一组测的是**老用户升级**，不是"新装能不能用"。
  // 新装永远跑 onCreate（一次性跑完全部迁移），不会暴露 onUpgrade 的 bug；
  // 而线上绝大多数人是从上一版升上来的，走的是 onUpgrade。
  // 所以必须**真的造一个 v1 的老库**再用生产入口打开 —— 而且是用真身的
  // 迁移函数造（LocalDb.migrationsForTest），不是测试里另抄一份 DDL。
  group('v1 → v2 迁移', () {
    /// 用真身迁移建一个 v1 老库（等价于老用户手机上那个文件）。
    Future<Database> openLegacyV1() async {
      sqfliteFfiInit();
      final path = await LocalDb.I.dbPathForTest();
      return databaseFactoryFfi.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: 1,
          onCreate: (db, v) async {
            for (var i = 1; i <= v; i++) {
              await LocalDb.migrationsForTest[i - 1](db);
            }
          },
        ),
      );
    }

    test('老 v1 库升到 v2：老数据不丢，新表在新列可用', () async {
      // ── 造老库：一个商品 + 一笔扫码流水 ──
      final old = await openLegacyV1();

      // 前置条件自检：此刻**必须**还是个真正的 v1 库。
      // 不检查的话，万一 openLegacyV1 实际建成了 v2，"升级不丢数据"就成了
      // 一句空话 —— 什么都没升过，当然不丢。
      final ver = (await old.rawQuery('PRAGMA user_version')).first.values.first;
      expect(ver, 1, reason: '老库没建成 v1，onUpgrade 根本不会触发，这轮测的是空气');
      final v1Cols =
          (await old.rawQuery('PRAGMA table_info(scan_record)')).map((r) => r['name']);
      expect(v1Cols, isNot(contains('phase')), reason: '老库里居然已经有 phase 了');
      expect(v1Cols, isNot(contains('loc_code')));

      await old.insert('stock_master', {
        'barcode': '6901234599999',
        'name': '老库里的海盐饼干',
        'spec': '200g/袋',
        'unit': '袋',
        'unit_price': 12.5,
        'account_qty': 30.0,
        'source': 'server',
        'updated_at': 1700000000000,
      });
      await old.insert('scan_record', {
        'sheet_no': 'PD20260901090000',
        'barcode': '6901234599999',
        'qty': 7.0,
        'scanned_at': 1700000001111,
        'note': '三号架',
        'uploaded': 1,
      });
      await old.close();

      // ── 用生产入口打开：这一步才会跑 onUpgrade(1 → 2) ──
      final db = await LocalDb.I.db();
      expect((await db.rawQuery('PRAGMA user_version')).first.values.first,
          LocalDb.schemaVersion);

      // 老数据逐字段核对（不是"还在就算过"）
      final m = await db.query('stock_master',
          where: 'barcode = ?', whereArgs: ['6901234599999']);
      expect(m, hasLength(1), reason: '升级把商品档案弄丢了');
      expect(m.first['name'], '老库里的海盐饼干');
      expect(m.first['unit_price'], isA<double>());
      expect(m.first['account_qty'], 30.0);

      final s = await db.query('scan_record',
          where: 'sheet_no = ?', whereArgs: ['PD20260901090000']);
      expect(s, hasLength(1), reason: '升级把扫码流水弄丢了');
      expect(s.first['qty'], 7.0);
      expect(s.first['note'], '三号架');
      // 🔴 存量行的语义必须是"初盘、无货架位"：
      //    非 1 的话老流水会被算进复盘/抽盘的差异里，账面直接错。
      expect(s.first['phase'], 1,
          reason: 'ALTER 的 DEFAULT 没生效，老流水被塞进了别的阶段');
      expect(s.first['loc_code'], isNull,
          reason: '老流水不该凭空长出一个货架位');
      // uploaded 不能被升级重置成 0，否则整库数据会被重复回传一遍
      expect(s.first['uploaded'], 1, reason: '升级把 uploaded 标记清了，会重复上传');

      // 新表真的建出来了，而且能用（建表语句写错的话这一步会抛）
      final now = DateTime.now().millisecondsSinceEpoch;
      await db.insert('stocktake_zone', {
        'zone_code': 'Z01',
        'zone_name': '生鲜区',
        'store_code': 'S001',
        'locked': 0,
        'created_at': now,
      });
      await db.insert('location', {
        'loc_code': 'Z01-A01',
        'loc_name': 'A01 货架',
        'zone_code': 'Z01',
        'sort_no': 1,
        'created_at': now,
      });
      await db.insert('barcode_location', {
        'barcode': '6901234599999',
        'loc_code': 'Z01-A01',
        'bound_at': now,
      });
      await db.insert('stocktake_sheet', {
        'sheet_no': 'INV-Z01-1-20260919130000',
        'zone_code': 'Z01',
        'phase': 1,
        'status': 0,
        'operator': 'pblpa',
        'started_at': now,
      });
      expect(await db.query('stocktake_zone'), hasLength(1));
      expect(await db.query('location'), hasLength(1));
      expect(await db.query('barcode_location'), hasLength(1));
      final sh = await db.query('stocktake_sheet');
      expect(sh, hasLength(1));
      expect(sh.first['phase'], 1);

      // 升级后再关再开一次：v2 的东西不能是"只在本次连接里才存在"
      await LocalDb.I.close();
      final db2 = await LocalDb.I.db();
      // 🔴 这里**不写死数字**：写死 2 的话，下次把 schemaVersion 提到 3 时
      //    这条会红，而红得毫无信息量（"我改版本号了"不是缺陷）。
      //    要断的是"打开后的版本 = 当前 schemaVersion"，以及"再打开不回落"。
      expect((await db2.rawQuery('PRAGMA user_version')).first.values.first,
          LocalDb.schemaVersion,
          reason: '重开后版本回落，说明迁移没落盘或被重复执行');
      expect(await db2.query('stocktake_zone'), hasLength(1),
          reason: '重开后 v2 的表没了，说明迁移没落盘/被重复执行');
    });

    test('新装直接到 v2：四张新表和两列都在，且索引齐', () async {
      // resetForTest 已由 setUp 删过文件，这里 db() 走的是 onCreate 全量路径。
      final db = await LocalDb.I.db();
      final cols = (await db.rawQuery('PRAGMA table_info(scan_record)'))
          .map((r) => r['name'])
          .toList();
      expect(cols, containsAll(<String>['phase', 'loc_code']));

      final idx = (await db.rawQuery(
              "SELECT name FROM sqlite_master WHERE type = 'index'"))
          .map((r) => r['name'])
          .toList();
      expect(
          idx,
          containsAll(<String>[
            'idx_scan_record_sheet',
            'idx_scan_record_sheet_phase',
            'idx_location_zone',
            'idx_barcode_location_loc',
            'idx_sheet_zone_phase',
          ]),
          reason: '索引没建齐，场景里全靠全表扫');
    });

    test('barcode_location 主键是 (barcode, loc_code)：一品多位可共存，重复绑定被拒', () async {
      final db = await LocalDb.I.db();
      final now = DateTime.now().millisecondsSinceEpoch;
      // 同一个商品绑两个货架位 —— 必须允许（一品多点，盘点是靠这个找货的）
      await db.insert('barcode_location',
          {'barcode': '6901', 'loc_code': 'A01', 'bound_at': now});
      await db.insert('barcode_location',
          {'barcode': '6901', 'loc_code': 'B02', 'bound_at': now});
      expect(await db.query('barcode_location'), hasLength(2),
          reason: '主键写成了单列 barcode，第二个货架位把第一个顶掉了');

      // 反向：同一对再绑一次必须被主键拒（不是静默覆盖，也不是插两行）
      expect(
          () => db.insert('barcode_location',
              {'barcode': '6901', 'loc_code': 'A01', 'bound_at': now}),
          throwsA(isA<DatabaseException>()));
      expect(await db.query('barcode_location'), hasLength(2));
    });
  });

  // ============================================================
  //
  // v2 → v3：单据加 sheet_type 列（v3 起「减货单」挂在同一套单据/流水上）。
  //
  // 这一组比 v1→v2 更要紧：v3 是**给已经装满盘点数据的库加列**，
  // 一旦 DEFAULT 没生效，线上所有存量盘点单的 sheet_type 会是空字符串 ——
  // 那种单既不算盘点也不算减货，界面上直接看不见（数据还在，但没人找得到）。
  group('v2 → v3 迁移', () {
    /// 用真身迁移建一个 v2 库（等价于"上次装的那一版"留下的文件）。
    Future<Database> openLegacyV2() async {
      sqfliteFfiInit();
      final path = await LocalDb.I.dbPathForTest();
      return databaseFactoryFfi.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: 2,
          onCreate: (db, v) async {
            for (var i = 1; i <= v; i++) {
              await LocalDb.migrationsForTest[i - 1](db);
            }
          },
        ),
      );
    }

    test('老 v2 库升到 v3：存量盘点单不被弄丢，且被认成「盘点」', () async {
      final old = await openLegacyV2();

      // 前置条件自检：此刻必须真的是 v2，且还没有 sheet_type 这一列。
      // 不检查的话，"加列不丢数据"可能测的是空气（库本来就是 v3）。
      final ver = (await old.rawQuery('PRAGMA user_version')).first.values.first;
      expect(ver, 2, reason: '老库没建成 v2，onUpgrade 不会触发，这轮测的是空气');
      final v2Cols = (await old.rawQuery('PRAGMA table_info(stocktake_sheet)'))
          .map((r) => r['name'])
          .toList();
      expect(v2Cols, isNot(contains('sheet_type')),
          reason: '老库里居然已经有 sheet_type 了');

      // 造一张"老版本盘出来的单"，带一笔流水（phase=2 复盘，好验证值没被改）
      await old.insert('stocktake_sheet', {
        'sheet_no': 'INV-Z01-2-20260920150000',
        'zone_code': 'Z01',
        'phase': 2,
        'status': 2, // 已上传 —— 升级绝不能把它退回未上传
        'operator': 'pblpa',
        'started_at': 1700000000000,
        'submitted_at': 1700000001000,
        'uploaded_at': 1700000002000,
      });
      await old.insert('scan_record', {
        'sheet_no': 'INV-Z01-2-20260920150000',
        'barcode': '6901234599999',
        'qty': 3.0,
        'scanned_at': 1700000000500,
        'note': '老流水',
        'uploaded': 1,
        'phase': 2,
      });
      await old.close();

      // ── 生产入口打开：跑 onUpgrade(2 → 3) ──
      final db = await LocalDb.I.db();
      expect((await db.rawQuery('PRAGMA user_version')).first.values.first,
          LocalDb.schemaVersion);

      final sh = await db.query('stocktake_sheet',
          where: 'sheet_no = ?', whereArgs: ['INV-Z01-2-20260920150000']);
      expect(sh, hasLength(1), reason: '升级把老的盘点单弄丢了');

      // 🔴 最关键的一条：存量单必须落成 'stocktake'。
      //    DEFAULT 没生效的话这里是 ''（或 null）→ 那张单在新版本里
      //    "既不显示盘点也不显示减货"，数据还在却谁也找不到。
      expect(sh.first['sheet_type'], InvSheetType.stocktake,
          reason: 'ALTER 的 DEFAULT 没生效，存量盘点单变成了"未知单据"');
      // 其它字段一个都不能被升级顺手改掉
      expect(sh.first['phase'], 2, reason: '升级把阶段改了，差异口径会整体错位');
      expect(sh.first['status'], 2, reason: '升级把"已上传"退回未上传，会重复上传一遍');
      expect(sh.first['zone_code'], 'Z01');
      expect(sh.first['uploaded_at'], 1700000002000);

      final s = await db.query('scan_record',
          where: 'sheet_no = ?', whereArgs: ['INV-Z01-2-20260920150000']);
      expect(s, hasLength(1), reason: '升级把老流水弄丢了');
      expect(s.first['qty'], 3.0);
      expect(s.first['phase'], 2);

      // 新列真的能用：插一张减货单
      final now = DateTime.now().millisecondsSinceEpoch;
      await db.insert('stocktake_sheet', {
        'sheet_no': 'JH20260921090000',
        'zone_code': null,
        'phase': 1,
        'status': 0,
        'operator': 'pblpa',
        'started_at': now,
        'sheet_type': InvSheetType.deduct,
      });
      final jh = await db.query('stocktake_sheet',
          where: 'sheet_type = ?', whereArgs: [InvSheetType.deduct]);
      expect(jh, hasLength(1));
      expect(jh.first['sheet_no'], 'JH20260921090000');

      // 索引也在（按类型+状态翻单据列表是减货页最热的查询）
      final idx =
          (await db.rawQuery("SELECT name FROM sqlite_master WHERE type = 'index'"))
              .map((r) => r['name'])
              .toList();
      expect(idx, contains('idx_sheet_type_status'),
          reason: 'v3 的索引没建，单据列表会全表扫');

      // 关再开：v3 的列不能只活在本次连接里
      await LocalDb.I.close();
      final db2 = await LocalDb.I.db();
      expect((await db2.rawQuery('PRAGMA user_version')).first.values.first,
          LocalDb.schemaVersion);
      final again = await db2.query('stocktake_sheet',
          where: 'sheet_no = ?', whereArgs: ['INV-Z01-2-20260920150000']);
      expect(again, hasLength(1));
      expect(again.first['sheet_type'], InvSheetType.stocktake,
          reason: '重开后存量单的类型变了，说明迁移被重复执行/没落盘');
    });

    test('新装直接到 v3：sheet_type 列与索引都在，默认值是 stocktake', () async {
      final db = await LocalDb.I.db();
      final cols = (await db.rawQuery('PRAGMA table_info(stocktake_sheet)'))
          .map((r) => r['name'])
          .toList();
      expect(cols, contains('sheet_type'));

      // 默认值要在**新装**路径上也生效（onCreate 与 onUpgrade 走的是同一段 SQL，
      // 但这里仍然验一遍 —— 建表语句被谁改坏时两边表现会不一样）
      await db.insert('stocktake_sheet', {
        'sheet_no': 'NO-TYPE',
        'status': 0,
        'started_at': DateTime.now().millisecondsSinceEpoch,
      });
      final r = await db.query('stocktake_sheet',
          where: 'sheet_no = ?', whereArgs: ['NO-TYPE']);
      expect(r.first['sheet_type'], InvSheetType.stocktake);
    });
  });
}
