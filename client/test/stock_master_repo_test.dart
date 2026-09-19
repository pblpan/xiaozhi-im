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
}
