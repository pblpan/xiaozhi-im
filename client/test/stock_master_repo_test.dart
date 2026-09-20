import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xiaozhi_im_client/core/local_db.dart';
import 'package:xiaozhi_im_client/core/stock_master_repo.dart';

/// 商档仓库（泰格 → 手机本地表）的单元测试。
///
/// 这里钉死的是三条**最容易被写成假通过**的规则：
///   1. 上游回包有 `data` 外壳，清单在 `data.items` —— 当裸数据用会一路返回空，
///      而"空"看起来特别像"同步成功了"；
///   2. decimal 经 JSON 会变成 "83.00" 字符串，不转 double 就在算盈亏时出 NaN；
///   3. 空清单**绝不能**清空本地底表（一次网络抖动 ≠ 库存清零）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 与 local_db_test 同一个套路：flutter test 桌面环境没有 path_provider 原生实现，
  // mock 到系统临时目录，resetForTest 会清掉。
  const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
  final supportDir = '${Directory.systemTemp.path}/xz_stock_master_test';
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

  Map<String, dynamic> envelope(List<dynamic> items) => <String, dynamic>{
        'ok': true,
        'upstream': 'tiger',
        'status': 200,
        'data': <String, dynamic>{
          'branch': '00',
          'count': items.length,
          'items': items,
        },
      };

  // ============================================================
  group('parseItems：信封结构与字段归一', () {
    // ============================================================
    test('正常回包能取出 items，并补上默认字段', () {
      final items = StockMasterRepo.parseItems(envelope([
        {'barcode': '69001', 'name': '苹果', 'unit_price': '5.80', 'account_qty': '83.00'},
      ]));
      expect(items, hasLength(1));
      expect(items.first['barcode'], '69001');
      expect(items.first['name'], '苹果');
      expect(items.first['spec'], '');
      expect(items.first['unit'], '');
    });

    test('"83.00" 这类字符串金额必须转成 double（否则算盈亏出 NaN）', () {
      final items = StockMasterRepo.parseItems(envelope([
        {'barcode': '69001', 'unit_price': '5.80', 'account_qty': '83.00'},
      ]));
      expect(items.first['unit_price'], isA<double>());
      expect(items.first['unit_price'], 5.8);
      expect(items.first['account_qty'], isA<double>());
      expect(items.first['account_qty'], 83.0);
      // 真的能参与运算，不是 NaN
      expect((items.first['account_qty'] as double) - 80, 3.0);
    });

    test('null 的价格/库存保持 null，不补 0（0=真的没有，null=不知道）', () {
      final items = StockMasterRepo.parseItems(envelope([
        {'barcode': '69002', 'unit_price': null, 'account_qty': null},
      ]));
      expect(items.first['unit_price'], isNull);
      expect(items.first['account_qty'], isNull);
    });

    test('空条码 / 纯空格条码被丢弃', () {
      final items = StockMasterRepo.parseItems(envelope([
        {'barcode': ''},
        {'barcode': '   '},
        {'barcode': '69003', 'name': '有效'},
      ]));
      expect(items, hasLength(1));
      expect(items.first['barcode'], '69003');
    });

    // ---- 反向断言：这三条绿不了说明"空"被当成了"成功" ----
    test('反向断言：缺少 data 外壳必须抛异常，不能静默返回空数组', () {
      expect(
        () => StockMasterRepo.parseItems({'ok': true, 'items': []}),
        throwsA(isA<FormatException>()),
        reason: '缺 data 却没报错——上层会以为"同步成功、0 个商品"',
      );
    });

    test('反向断言：data.items 不是数组也必须抛异常', () {
      expect(
        () => StockMasterRepo.parseItems({
          'ok': true,
          'data': {'items': 'not-a-list'},
        }),
        throwsA(isA<FormatException>()),
      );
    });

    test('反向断言：回包不是 JSON 对象时抛异常', () {
      expect(() => StockMasterRepo.parseItems('oops'),
          throwsA(isA<FormatException>()));
      expect(() => StockMasterRepo.parseItems(null),
          throwsA(isA<FormatException>()));
    });
  });

  // ============================================================
  group('upsertAll：落库语义', () {
    // ============================================================
    test('整份写入，条数与内容都对', () async {
      final db = await LocalDb.I.db();
      final items = StockMasterRepo.parseItems(envelope([
        {'barcode': '69001', 'name': '苹果', 'unit': 'JIN', 'unit_price': 5.8, 'account_qty': 83},
        {'barcode': '69002', 'name': '梨', 'unit': 'JIN', 'unit_price': 4.2, 'account_qty': 12},
      ]));
      final n = await StockMasterRepo.upsertAll(db, items);
      expect(n, 2);

      final rows = await db.query('stock_master', orderBy: 'barcode');
      expect(rows, hasLength(2));
      expect(rows.first['name'], '苹果');
      expect(rows.first['source'], 'tiger');
      expect(rows.first['updated_at'], isA<int>());
    });

    test('同 barcode 再同步一次是覆盖，不是重复插入（商档是全量对齐语义）', () async {
      final db = await LocalDb.I.db();
      final first = StockMasterRepo.parseItems(envelope([
        {'barcode': '69001', 'name': '苹果（旧名）', 'unit_price': 5.8, 'account_qty': 83},
      ]));
      await StockMasterRepo.upsertAll(db, first);

      final second = StockMasterRepo.parseItems(envelope([
        {'barcode': '69001', 'name': '苹果（新名）', 'unit_price': 6.5, 'account_qty': 40},
      ]));
      await StockMasterRepo.upsertAll(db, second);

      final rows = await db.query('stock_master');
      expect(rows, hasLength(1), reason: '同条码被插成了多行，扫码会重复计数');
      expect(rows.first['name'], '苹果（新名）');
      expect(rows.first['unit_price'], 6.5);
      expect(rows.first['account_qty'], 40.0);
    });

    test('本次清单里没有的旧记录会被清掉（商品下架不该还留账面数）', () async {
      final db = await LocalDb.I.db();
      await StockMasterRepo.upsertAll(db, [
        {'barcode': '69001', 'name': '苹果', 'unit_price': 5.8, 'account_qty': 83},
        {'barcode': '69002', 'name': '梨', 'unit_price': 4.2, 'account_qty': 12},
      ]);
      expect(await db.query('stock_master'), hasLength(2));

      // 第二次只有苹果 → 梨应消失
      await StockMasterRepo.upsertAll(db, [
        {'barcode': '69001', 'name': '苹果', 'unit_price': 5.8, 'account_qty': 83},
      ]);
      final rows = await db.query('stock_master');
      expect(rows, hasLength(1));
      expect(rows.first['barcode'], '69001');
    });

    test('🔴 空清单绝不清空本地底表（一次网络抖动 ≠ 库存清零）', () async {
      final db = await LocalDb.I.db();
      await StockMasterRepo.upsertAll(db, [
        {'barcode': '69001', 'name': '苹果', 'unit_price': 5.8, 'account_qty': 83},
      ]);

      await StockMasterRepo.upsertAll(db, [], purgeMissing: true);

      expect(await db.query('stock_master'), hasLength(1),
          reason: '空清单把底表清了——员工会扫什么都是"未知商品"');
    });

    test('同步时拿到 0 条要抛异常，不装作成功', () async {
      final repo = StockMasterRepo(
        call: (p, {method = 'GET', body}) async => envelope([]),
      );
      expect(() => repo.sync(), throwsA(isA<StateException>()),
          reason: '0 条却返回成功，上游配错就永远没人发现');
    });

    test('sync 走注入的取数函数并落库，返回条数', () async {
      final repo = StockMasterRepo(
        call: (p, {method = 'GET', body}) async {
          expect(p, StockMasterRepo.defaultPath);
          return envelope([
            {'barcode': '69009', 'name': '香蕉', 'unit_price': 3.5, 'account_qty': 7},
          ]);
        },
      );
      final n = await repo.sync();
      expect(n, 1);
      expect(await repo.countLocal(), 1);
    });

    test('countLocal 只数本来源的，别的来源不混进来', () async {
      final db = await LocalDb.I.db();
      await StockMasterRepo.upsertAll(db, [
        {'barcode': '69001', 'name': '苹果', 'unit_price': 5.8, 'account_qty': 83},
      ]);
      await StockMasterRepo.upsertAll(db, [
        {'barcode': '69002', 'name': '苹果（手工补的）', 'unit_price': 9.9, 'account_qty': 1},
      ], source: 'manual');

      expect(await StockMasterRepo().countLocal(), 1);
      expect(await StockMasterRepo().countLocal(source: 'manual'), 1);
      expect(await db.query('stock_master'), hasLength(2));
    });

    test('清库只清本来源：manual 补的商品不会被 tiger 同步删掉', () async {
      final db = await LocalDb.I.db();
      await StockMasterRepo.upsertAll(db, [
        {'barcode': '69001', 'name': '苹果', 'unit_price': 5.8, 'account_qty': 83},
      ], source: 'manual');
      // tiger 同步，清单里没有 69001 → 只该清 tiger 的行，manual 的必须留着
      await StockMasterRepo.upsertAll(db, [
        {'barcode': '69002', 'name': '梨', 'unit_price': 4.2, 'account_qty': 12},
      ]);

      final rows = await db.query('stock_master', orderBy: 'barcode');
      expect(rows, hasLength(2), reason: 'manual 的 69001 被 tiger 同步误删了');
      expect(rows.first['barcode'], '69001');
      expect(rows.first['source'], 'manual');
    });

    test('同一条码不同来源不能共存：barcode 是唯一主键，后写的覆盖先写的', () async {
      // 这是刻意的业务选择：一个条码在扫码里只该有一条档案，
      // 所以"手工改价"覆盖泰格数据是预期行为，不是 bug。
      final db = await LocalDb.I.db();
      await StockMasterRepo.upsertAll(db, [
        {'barcode': '69001', 'name': '苹果（泰格）', 'unit_price': 5.8, 'account_qty': 83},
      ]);
      await StockMasterRepo.upsertAll(db, [
        {'barcode': '69001', 'name': '苹果（手工改）', 'unit_price': 9.9, 'account_qty': 83},
      ], source: 'manual');

      final rows = await db.query('stock_master');
      expect(rows, hasLength(1));
      expect(rows.first['name'], '苹果（手工改）');
      expect(rows.first['source'], 'manual');
    });
  });

  // ============================================================
  group('syncFromServer：从自家服务端拉商档', () {
    /// 造一个假的服务端：整份清单按 pageSize 分页应答。
    (Future<Map<String, dynamic>> Function(), Future<Map<String, dynamic>> Function(int, int))
        fakeServer(List<Map<String, dynamic>> all, int pageSize,
            {int failAtPage = -1}) {
      Future<Map<String, dynamic>> count() async =>
          <String, dynamic>{'total': all.length, 'updated_at': 1, 'server_time': 2};

      Future<Map<String, dynamic>> page(int p, int ps) async {
        if (p == failAtPage) throw Exception('网断了');
        final start = (p - 1) * ps;
        if (start >= all.length) return <String, dynamic>{'items': <dynamic>[], 'has_more': false};
        final slice = all.sublist(start, (start + ps).clamp(0, all.length));
        return <String, dynamic>{
          'items': slice,
          'total': all.length,
          'page': p,
          'pageSize': ps,
          'has_more': start + slice.length < all.length,
        };
      }
      return (count, page);
    }

    test('分页拉完，整份落库且来源是 server', () async {
      final all = List<Map<String, dynamic>>.generate(
          5, (i) => <String, dynamic>{'barcode': '6900$i', 'name': '商品$i', 'account_qty': i});
      final (count, page) = fakeServer(all, 2);

      final n = await StockMasterRepo.syncFromServer(countCall: count, pageCall: page);
      expect(n, 5);

      final db = await LocalDb.I.db();
      final rows = await db.query('stock_master', orderBy: 'barcode');
      expect(rows, hasLength(5));
      expect(rows.every((r) => r['source'] == 'server'), isTrue);
      expect(await StockMasterRepo().countAll(), 5);
    });

    test('进度回调会报 done/total（12 万行要有得看）', () async {
      final all = List<Map<String, dynamic>>.generate(
          7, (i) => <String, dynamic>{'barcode': 'B$i', 'account_qty': 1});
      final (count, page) = fakeServer(all, 3);
      final seen = <String>[];
      // 🔴 pageSize **必须显式传小**：不传的话默认 2000，7 条一页就拉完了，
      //    这个用例就变成了"一页也能跑通"—— 分页逻辑压根没被走到，
      //    而它恰恰是 12 万行能不能拉下来的关键。
      await StockMasterRepo.syncFromServer(
        pageSize: 3,
        countCall: count,
        pageCall: page,
        onProgress: (done, total) => seen.add('$done/$total'),
      );
      expect(seen, <String>['3/7', '6/7', '7/7']);
    });

    test('🔴 拉到一半断网：正式底表必须还是上一次那份完整的', () async {
      // 先同步一份完整的（3 条），再模拟"换新商档拉到第 2 页断网"
      final first = List<Map<String, dynamic>>.generate(
          3, (i) => <String, dynamic>{'barcode': 'OLD$i', 'name': '旧$i', 'account_qty': 10});
      var (c1, p1) = fakeServer(first, 2);
      await StockMasterRepo.syncFromServer(pageSize: 2, countCall: c1, pageCall: p1);

      final second = List<Map<String, dynamic>>.generate(
          6, (i) => <String, dynamic>{'barcode': 'NEW$i', 'name': '新$i', 'account_qty': 1});
      final (c2, p2) = fakeServer(second, 2, failAtPage: 2);

      await expectLater(
        // pageSize 必须显式传 2：默认 2000 的话一页就拉完了，"第 2 页断网"
        // 这个场景根本不会发生，测试会假通过。
        StockMasterRepo.syncFromServer(pageSize: 2, countCall: c2, pageCall: p2),
        throwsA(isA<Exception>()),
      );

      final db = await LocalDb.I.db();
      final rows = await db.query('stock_master', orderBy: 'barcode');
      // 🔴 这条是整个测试里最要命的断言：拉一半失败后手机上一个商品都不能少。
      //    少一条就意味着员工会拿着残缺底表盘出一批假的"账上无此商品"。
      expect(rows, hasLength(3), reason: '拉一半失败把上一次的底表弄丢了');
      expect(rows.map((r) => r['barcode']).toList(), <String>['OLD0', 'OLD1', 'OLD2']);
      // 暂存表必须已经清掉，不能留在库里污染下次同步
      final leftover = await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
          <Object?>[StockMasterRepo.stagingTable]);
      expect(leftover, isEmpty);
    });

    test('服务端一份都没有 → 抛异常，且不碰本地底表', () async {
      final db = await LocalDb.I.db();
      await StockMasterRepo.upsertAll(db, <Map<String, dynamic>>[
        <String, dynamic>{'barcode': 'KEEP1', 'name': '留着', 'account_qty': 5},
      ]);

      Future<Map<String, dynamic>> count() async =>
          <String, dynamic>{'total': 0, 'updated_at': 0};
      Future<Map<String, dynamic>> page(int p, int ps) async =>
          <String, dynamic>{'items': <dynamic>[], 'has_more': false};

      await expectLater(
        StockMasterRepo.syncFromServer(countCall: count, pageCall: page),
        throwsA(isA<StateException>()),
      );
      final rows = await db.query('stock_master');
      expect(rows, hasLength(1));
      expect(rows.first['barcode'], 'KEEP1');
    });

    test('再同步一次：下架的商品不该还留着账面数（全量替换语义）', () async {
      final first = <Map<String, dynamic>>[
        <String, dynamic>{'barcode': 'A1', 'account_qty': 3},
        <String, dynamic>{'barcode': 'A2', 'account_qty': 4},
      ];
      var (c1, p1) = fakeServer(first, 10);
      await StockMasterRepo.syncFromServer(countCall: c1, pageCall: p1);

      final second = <Map<String, dynamic>>[
        <String, dynamic>{'barcode': 'A1', 'account_qty': 9},   // 改了数
        // A2 下架了，这次清单里没有
      ];
      final (c2, p2) = fakeServer(second, 10);
      await StockMasterRepo.syncFromServer(countCall: c2, pageCall: p2);

      final db = await LocalDb.I.db();
      final rows = await db.query('stock_master', orderBy: 'barcode');
      expect(rows, hasLength(1));
      expect(rows.first['barcode'], 'A1');
      expect(rows.first['account_qty'], 9);
    });
  });
}
