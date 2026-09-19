import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:xiaozhi_im_client/core/local_db.dart';
import 'package:xiaozhi_im_client/core/stocktake_repo.dart';

/// 扫码枪采集（本地扫码流水）的单元测试。
///
/// 这一层最容易出事的地方不是"存不进去"，而是**存进去了但语义不对**：
///   · 同条码重复扫被插成两行 → 汇总多算一个品种；
///   · 商档里没有的条码被 JOIN 吃掉 → 员工以为没扫进去，再扫一遍数量翻倍；
///   · 数量减到 0 却留一行空记录 → 盈亏表里凭空多一个品种。
/// 这三条都不会报错，只是数字悄悄变错，所以用测试钉死。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
  final supportDir = '${Directory.systemTemp.path}/xz_stocktake_test';
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

  /// 造一条商档（模拟已同步下来的商品）
  Future<void> seedMaster(String barcode, String name, double accountQty) async {
    final db = await LocalDb.I.db();
    await db.insert('stock_master', <String, Object?>{
      'barcode': barcode,
      'name': name,
      'spec': '',
      'unit': '个',
      'unit_price': 5.0,
      'account_qty': accountQty,
      'source': 'tiger',
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  // ============================================================
  group('addScan：累加语义（最容易写成"插两行"的地方）', () {
    // ============================================================
    test('同条码扫两次 = 数量累加成 2，仍然只有一行', () async {
      final repo = StocktakeRepo();
      await repo.addScan('PD001', '69001');
      await repo.addScan('PD001', '69001');

      final rows = await repo.listScans('PD001');
      expect(rows, hasLength(1), reason: '同条码被插成两行，汇总会多算一个品种');
      expect((rows.first['qty'] as num).toDouble(), 2.0);
    });

    test('扫三次累加到 3，时间更新为最后一次', () async {
      final repo = StocktakeRepo();
      final id1 = await repo.addScan('PD001', '69001');
      await repo.addScan('PD001', '69001');
      final id3 = await repo.addScan('PD001', '69001');
      // 累加走的是同一行，id 必须一致
      expect(id3, id1);

      final rows = await repo.listScans('PD001');
      expect((rows.first['qty'] as num).toDouble(), 3.0);
    });

    test('称重商品可以传小数数量', () async {
      final repo = StocktakeRepo();
      await repo.addScan('PD001', '69001', qty: 1.25);
      await repo.addScan('PD001', '69001', qty: 0.5);
      final rows = await repo.listScans('PD001');
      expect((rows.first['qty'] as num).toDouble(), closeTo(1.75, 1e-9));
    });

    test('数量减到 0（含）以下时删掉该行，不留空记录', () async {
      final repo = StocktakeRepo();
      await repo.addScan('PD001', '69001', qty: 2);
      await repo.addScan('PD001', '69001', qty: -2);

      expect(await repo.listScans('PD001'), isEmpty,
          reason: '留一行 0 数量的记录，盈亏表会凭空多一个品种');
    });

    test('不同的单号互不干扰', () async {
      final repo = StocktakeRepo();
      await repo.addScan('PDA', '69001', qty: 2);
      await repo.addScan('PDB', '69001', qty: 5);

      expect((await repo.listScans('PDA')).first['qty'], 2.0);
      expect((await repo.listScans('PDB')).first['qty'], 5.0);
    });

    // ---- 反向断言 ----
    test('反向断言：空条码 / 纯空格条码必须抛异常，不能落库', () async {
      final repo = StocktakeRepo();
      expect(() => repo.addScan('PD001', ''), throwsA(isA<ArgumentError>()));
      expect(() => repo.addScan('PD001', '   '), throwsA(isA<ArgumentError>()));
      expect(await repo.listScans('PD001'), isEmpty,
          reason: '空条码竟然写进去了，后面 JOIN 会全落空');
    });

    test('反向断言：数量传 0 抛异常（要删请调 deleteScan）', () async {
      final repo = StocktakeRepo();
      expect(() => repo.addScan('PD001', '69001', qty: 0),
          throwsA(isA<ArgumentError>()));
    });
  });

  // ============================================================
  group('listWithMaster：左连商品档案', () {
    // ============================================================
    test('商档里有的条码，能带出品名/单位/账面数，并算出差异', () async {
      await seedMaster('69001', '苹果', 80);
      final repo = StocktakeRepo();
      await repo.addScan('PD001', '69001', qty: 83);

      final rows = await repo.listWithMaster('PD001');
      expect(rows, hasLength(1));
      expect(rows.first['name'], '苹果');
      expect(rows.first['unit'], '个');
      expect(rows.first['account_qty'], 80.0);
      // 实盘 83 - 账面 80 = 盘盈 3
      expect(rows.first['diff_qty'], 3.0);
    });

    test('🔴 商档里没有的条码照样要出现（不能被 JOIN 吃掉）', () async {
      await seedMaster('69001', '苹果', 80);
      final repo = StocktakeRepo();
      await repo.addScan('PD001', '69001', qty: 1);
      await repo.addScan('PD001', '99999', qty: 1); // 商档里没有

      final rows = await repo.listWithMaster('PD001');
      expect(rows, hasLength(2),
          reason: '未知条码被 JOIN 吃掉了——员工会以为没扫进去，再扫一遍数量翻倍');

      final unknown = rows.firstWhere((r) => r['barcode'] == '99999');
      expect(unknown['name'], isNull);
      // 账面缺失 → 差异是 null（"不知道差多少"），不能显示成 0
      expect(unknown['diff_qty'], isNull, reason: '账面缺失时差异应是 null，不是 0');
    });

    test('差异可以是负数（盘亏）', () async {
      await seedMaster('69001', '苹果', 80);
      final repo = StocktakeRepo();
      await repo.addScan('PD001', '69001', qty: 77);
      final rows = await repo.listWithMaster('PD001');
      expect(rows.first['diff_qty'], -3.0);
    });
  });

  // ============================================================
  group('summary / 修正 / 清理', () {
    // ============================================================
    test('汇总：品种数、总数量、未知数、未回传数', () async {
      await seedMaster('69001', '苹果', 80);
      final repo = StocktakeRepo();
      await repo.addScan('PD001', '69001', qty: 3);
      await repo.addScan('PD001', '69002', qty: 2); // 未知
      await repo.addScan('PD001', '69003', qty: 4); // 未知

      final s = await repo.summary('PD001');
      expect(s['kinds'], 3);
      expect(s['total_qty'], 9.0);
      expect(s['unknown'], 2, reason: '未知条码数不对，界面提示会误导');
      expect(s['pending'], 3, reason: '全部未回传');
    });

    test('改数量会把 uploaded 打回 0（已回传的数据对不上了）', () async {
      final repo = StocktakeRepo();
      final id = await repo.addScan('PD001', '69001', qty: 1);
      final db = await LocalDb.I.db();
      await db.update('scan_record', {'uploaded': 1},
          where: 'id = ?', whereArgs: [id]);

      await repo.setQty(id, 9);
      final rows = await repo.listScans('PD001');
      expect(rows.first['uploaded'], 0, reason: '改了数量还标着已上传，回传会漏');
      expect(rows.first['qty'], 9.0);
    });

    test('setQty 传 0 或负数 = 删除该笔', () async {
      final repo = StocktakeRepo();
      final id = await repo.addScan('PD001', '69001', qty: 1);
      await repo.setQty(id, 0);
      expect(await repo.listScans('PD001'), isEmpty);
    });

    test('deleteScan 只删指定那笔', () async {
      final repo = StocktakeRepo();
      await repo.addScan('PD001', '69001');
      final id2 = await repo.addScan('PD001', '69002');
      await repo.deleteScan(id2);

      final rows = await repo.listScans('PD001');
      expect(rows, hasLength(1));
      expect(rows.first['barcode'], '69001');
    });

    test('listSheets 按最后扫码时间倒序，带品种数', () async {
      final repo = StocktakeRepo();
      await repo.addScan('PDOLD', '69001');
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await repo.addScan('PDNEW', '69002', qty: 2);

      final sheets = await repo.listSheets();
      expect(sheets.first['sheet_no'], 'PDNEW');
      expect(sheets.length, 2);
    });

    test('deleteSheet 整单清掉，别的单不受影响', () async {
      final repo = StocktakeRepo();
      await repo.addScan('PDA', '69001');
      await repo.addScan('PDA', '69002');
      await repo.addScan('PDB', '69003');

      expect(await repo.deleteSheet('PDA'), 2);
      expect(await repo.listScans('PDA'), isEmpty);
      expect(await repo.listScans('PDB'), hasLength(1));
    });

    test('空单的汇总全是 0，不返回 null', () async {
      final s = await StocktakeRepo().summary('PD_NOT_EXIST');
      expect(s['kinds'], 0);
      expect(s['total_qty'], 0.0);
      expect(s['unknown'], 0);
      expect(s['pending'], 0);
    });
  });

  // ============================================================
  group('单号', () {
    // ============================================================
    test('newSheetNo 形如 PD + 年月日时分秒', () {
      final no = StocktakeRepo.newSheetNo(DateTime(2026, 9, 19, 5, 40, 12));
      expect(no, 'PD20260919054012');
      expect(no.length, 16);
    });

    test('不传时间就用当前时间（仍然合规）', () {
      expect(StocktakeRepo.newSheetNo(), startsWith('PD'));
      expect(StocktakeRepo.newSheetNo().length, 16);
    });
  });
}
