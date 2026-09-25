import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xiaozhi_im_client/core/inventory_rules.dart';
import 'package:xiaozhi_im_client/core/local_db.dart';
import 'package:xiaozhi_im_client/core/replenish_repo.dart';
import 'package:xiaozhi_im_client/core/replenish_rules.dart';

/// 补货单仓库层的测试（本地 SQLite）。
///
/// 判定本身在 replenish_rules_test.dart 里逐条钉过；这一层盯的是
/// **"判定被真的执行了没有、两个场景会不会串、有没有波及别人的数据"**：
///   · 生鲜和杂百**各有一张**进行中的单（混在一起就是两种单位混着记）；
///   · 被拒的扫码**不许写库**；
///   · 清补货**一个字节都不能碰盘点单、减货单、简易盘点**（四套单据共用两张表）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
  final supportDir = '${Directory.systemTemp.path}/xz_replenish_test';
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(pathChannel, (call) async {
    if (call.method == 'getApplicationSupportDirectory') return supportDir;
    return null;
  });

  late ReplenishRepo repo;

  setUp(() async {
    await LocalDb.I.resetForTest();
    repo = ReplenishRepo();
  });

  tearDown(() async {
    await LocalDb.I.close();
  });

  /// 造一张减货单（用来验证清补货不会波及它）。
  Future<String> seedDeductSheet() async {
    final db = await LocalDb.I.db();
    const no = 'JH-20260921090000';
    await db.insert('stocktake_sheet', <String, Object?>{
      'sheet_no': no,
      'zone_code': null,
      'phase': 1,
      'status': 0,
      'started_at': DateTime.now().millisecondsSinceEpoch,
      'sheet_type': InvSheetType.deduct,
    });
    await db.insert('scan_record', <String, Object?>{
      'sheet_no': no,
      'barcode': '6901234567890',
      'qty': 9.0,
      'scanned_at': DateTime.now().millisecondsSinceEpoch,
      'phase': 1,
      'uploaded': 0,
    });
    return no;
  }

  group('单据', () {
    test('🔴 生鲜和杂百各有一张进行中的单', () async {
      final dry = await repo.openOrCreate(scene: ReplenishScene.dry);
      final fresh = await repo.openOrCreate(scene: ReplenishScene.fresh);
      expect(dry['sheet_no'], isNot(fresh['sheet_no']),
          reason: '合成一张的话，生鲜按公斤、杂百按件，一张单里两种单位混着');

      // 再各开一次 → 复用（一进来就开新单会让上次扫的数据凭空消失）
      expect((await repo.openOrCreate(scene: ReplenishScene.dry))['sheet_no'],
          dry['sheet_no']);
      expect((await repo.openOrCreate(scene: ReplenishScene.fresh))['sheet_no'],
          fresh['sheet_no']);
    });

    test('场景认不出来时按杂百记（不会开出一个场景不明的单）', () async {
      final s = await repo.openOrCreate(scene: '啥也不是');
      expect(s['zone_code'], ReplenishScene.dry);
    });

    test('单号前缀是 BH-（扫一眼就知道是补货单）', () async {
      final s = await repo.openOrCreate(scene: ReplenishScene.dry);
      expect((s['sheet_no'] as String).startsWith('BH-'), isTrue);
    });
  });

  group('明细', () {
    test('扫一笔入账，数量按原值存', () async {
      final s = await repo.openOrCreate(scene: ReplenishScene.fresh);
      final no = s['sheet_no'] as String;
      final d = await repo.addRow(sheetNo: no, barcode: '6901', qtyRaw: '1.25');
      expect(d.accepted, isTrue);

      final rows = await repo.listRows(no);
      expect(rows, hasLength(1));
      expect(rows.first['qty'], 1.25);
    });

    test('🔴 同码重复 → 被拒且**不写库**', () async {
      final s = await repo.openOrCreate(scene: ReplenishScene.dry);
      final no = s['sheet_no'] as String;
      await repo.addRow(sheetNo: no, barcode: '6901', qtyRaw: '1');
      final d = await repo.addRow(sheetNo: no, barcode: '6901', qtyRaw: '2');
      expect(d.accepted, isFalse);
      expect((await repo.listRows(no)), hasLength(1));
      expect((await repo.listRows(no)).first['qty'], 1.0,
          reason: '覆盖的话员工会以为没扫上、再扫一次');
    });

    test('数量为 0 → 被拒且不写库', () async {
      final s = await repo.openOrCreate(scene: ReplenishScene.dry);
      final no = s['sheet_no'] as String;
      final d = await repo.addRow(sheetNo: no, barcode: '6901', qtyRaw: '0');
      expect(d.accepted, isFalse);
      expect(await repo.listRows(no), isEmpty);
    });

    test('单不存在 → 报错（不静默）', () async {
      await expectLater(
          repo.addRow(sheetNo: 'BH-nope', barcode: '6901', qtyRaw: '1'),
          throwsA(isA<StateError>()));
    });

    test('提交后锁死', () async {
      final s = await repo.openOrCreate(scene: ReplenishScene.dry);
      final no = s['sheet_no'] as String;
      await repo.addRow(sheetNo: no, barcode: '6901', qtyRaw: '1');
      await repo.submitSheet(no);
      final d = await repo.addRow(sheetNo: no, barcode: '6902', qtyRaw: '1');
      expect(d.accepted, isFalse);

      // 撤销后能继续
      await repo.reopenSheet(no);
      expect((await repo.addRow(sheetNo: no, barcode: '6902', qtyRaw: '1'))
          .accepted, isTrue);
    });
  });

  group('汇总', () {
    test('生鲜按公斤合计', () async {
      final s = await repo.openOrCreate(scene: ReplenishScene.fresh);
      final no = s['sheet_no'] as String;
      await repo.addRow(sheetNo: no, barcode: '6901', qtyRaw: '2');
      await repo.addRow(sheetNo: no, barcode: '6902', qtyRaw: '1.5');

      final t = await repo.summary(no, ReplenishScene.fresh);
      expect(t.kinds, 2);
      expect(t.totalQty, 3.5);
      expect(t.totalKg, 3.5);
    });

    test('杂百按最小单位合计，规格里没克重则折不出的行数出来', () async {
      final s = await repo.openOrCreate(scene: ReplenishScene.dry);
      final no = s['sheet_no'] as String;
      await repo.addRow(sheetNo: no, barcode: '6901', qtyRaw: '3');
      await repo.addRow(sheetNo: no, barcode: '6902', qtyRaw: '2');

      final t = await repo.summary(no, ReplenishScene.dry);
      expect(t.totalQty, 5.0);
      expect(t.unknownWeight, 2, reason: '商档没给规格，折不出公斤 —— 要数出来');
      expect(t.totalKg, 0.0);
    });
  });

  group('清数据', () {
    test('🔴 清补货不碰减货单', () async {
      final dno = await seedDeductSheet();
      final s = await repo.openOrCreate(scene: ReplenishScene.dry);
      await repo.addRow(sheetNo: s['sheet_no'] as String, barcode: '6901',
          qtyRaw: '1');

      final r = await repo.clearAll();
      expect(r['sheets'], 1);
      expect(r['rows'], 1);

      final db = await LocalDb.I.db();
      final dSheets = await db.query('stocktake_sheet',
          where: 'sheet_no = ?', whereArgs: <Object?>[dno]);
      expect(dSheets, hasLength(1), reason: '清补货把减货单一起清了');
      final dRows = await db.query('scan_record',
          where: 'sheet_no = ?', whereArgs: <Object?>[dno]);
      expect(dRows, hasLength(1), reason: '清补货把减货的明细一起清了');
      expect(dRows.first['qty'], 9.0);
    });

    test('补货单不会出现在减货的查询里', () async {
      await repo.openOrCreate(scene: ReplenishScene.dry);
      final db = await LocalDb.I.db();
      final deductOnly = await db.query('stocktake_sheet',
          where: 'sheet_type = ?', whereArgs: <Object?>[InvSheetType.deduct]);
      expect(deductOnly, isEmpty);
    });
  });
}
