import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xiaozhi_im_client/core/deduct_repo.dart';
import 'package:xiaozhi_im_client/core/deduct_rules.dart';
import 'package:xiaozhi_im_client/core/inventory_rules.dart';
import 'package:xiaozhi_im_client/core/local_db.dart';

/// 库房减货单仓库层（本地 SQLite）的测试。
///
/// 判定本身在 deduct_rules_test.dart 里逐条钉过；这一层盯的是
/// **"判定被真的执行了没有、落库以后还读得回来吗、有没有波及盘点的数据"**：
///   · 被拒的扫码**不许写库**（判定了但照写 = 没判）；
///   · 同一时间只有一张进行中的单，未完成单被复用而不是新开；
///   · 提交后本地就锁死；
///   · 清减货**一个字节都不能碰盘点单**（两套单据共用 stocktake_sheet / scan_record）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
  final supportDir = '${Directory.systemTemp.path}/xz_deduct_test';
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(pathChannel, (call) async {
    if (call.method == 'getApplicationSupportDirectory') return supportDir;
    return null;
  });

  late DeductRepo repo;

  setUp(() async {
    await LocalDb.I.resetForTest();
    repo = DeductRepo();
  });

  tearDown(() async {
    await LocalDb.I.close();
  });

  /// 造一张"盘点单"（sheet_type='stocktake'）带一笔流水 ——
  /// 用来验证减货的各种批量操作不会波及它。
  Future<String> seedStocktakeSheet() async {
    final db = await LocalDb.I.db();
    const no = 'INV-Z01-1-20260921080000';
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.insert('stocktake_sheet', {
      'sheet_no': no,
      'zone_code': 'Z01',
      'phase': 1,
      'status': 0,
      'operator': 'pblpa',
      'started_at': now,
      // 不写 sheet_type：走列默认值，正好也验一遍 DEFAULT 生效
    });
    await db.insert('scan_record', {
      'sheet_no': no,
      'barcode': '6900000000001',
      'qty': 9.0,
      'scanned_at': now,
      'uploaded': 0,
      'phase': 1,
    });
    return no;
  }

  // ============================================================
  group('开单', () {
    test('新建的单 sheet_type 是 deduct，且不挂盘点位', () async {
      final s = await repo.openOrCreate(operator: 'pblpa');
      expect(s['sheet_no'], startsWith(DeductRepo.sheetPrefix));
      expect(s['sheet_type'], InvSheetType.deduct);
      expect(s['zone_code'], isNull, reason: '减货不挂盘点位');
      expect(s['status'], InvSheetStatus.open);
    });

    test('🔴 再次开单复用未完成的那张（不然上次扫的"凭空消失"）', () async {
      final a = await repo.openOrCreate();
      await repo.addRow(
          sheetNo: a['sheet_no'] as String, barcode: '6901', qtyRaw: '3');
      final b = await repo.openOrCreate();
      expect(b['sheet_no'], a['sheet_no']);
      expect(await repo.listRows(a['sheet_no'] as String), hasLength(1),
          reason: '复用单必须带着已有明细');
    });

    test('forceNew 才真开新单', () async {
      final a = await repo.openOrCreate();
      final b = await repo.openOrCreate(forceNew: true);
      expect(b['sheet_no'], isNot(a['sheet_no']));
      expect(await repo.listSheets(), hasLength(2));
    });

    test('同秒 forceNew 撞号时挂序号，不是覆盖', () async {
      final a = await repo.openOrCreate();
      final b = await repo.openOrCreate(forceNew: true);
      final c = await repo.openOrCreate(forceNew: true);
      expect({a['sheet_no'], b['sheet_no'], c['sheet_no']}, hasLength(3));
      expect(await repo.listSheets(), hasLength(3));
    });
  });

  // ============================================================
  group('明细录入', () {
    test('正常入库：数量与中性 phase 都对', () async {
      final s = await repo.openOrCreate();
      final no = s['sheet_no'] as String;
      final d = await repo.addRow(sheetNo: no, barcode: '6901', qtyRaw: '2.5');
      expect(d.accepted, isTrue);

      final rows = await repo.listRows(no);
      expect(rows, hasLength(1));
      expect(rows.first['barcode'], '6901');
      expect(rows.first['qty'], 2.5);
      // 减货不看阶段，写进去的是中性值 1（不是"初盘"）
      expect(rows.first['phase'], DeductRepo.neutralPhase);
      expect(rows.first['uploaded'], 0);
    });

    test('🔴 重复条码被拒，且**一行都没多写**（判定了但照写 = 没判）', () async {
      final s = await repo.openOrCreate();
      final no = s['sheet_no'] as String;
      await repo.addRow(sheetNo: no, barcode: '6901', qtyRaw: '3');

      final d = await repo.addRow(sheetNo: no, barcode: '6901', qtyRaw: '7');
      expect(d.verdict, DeductVerdict.duplicate);
      expect(d.message, '减货列表已存在，请处理后重新扫码');

      final rows = await repo.listRows(no);
      expect(rows, hasLength(1), reason: '被拒的扫码写进库了，减货量会翻倍');
      expect(rows.first['qty'], 3.0, reason: '被拒的扫码把已有一行的数量改了');
    });

    test('数量非法被拒 + 不写库', () async {
      final s = await repo.openOrCreate();
      final no = s['sheet_no'] as String;
      for (final bad in ['0', '-1', 'abc', '']) {
        final d = await repo.addRow(sheetNo: no, barcode: '6901', qtyRaw: bad);
        expect(d.accepted, isFalse, reason: '"$bad" 不该通过');
      }
      expect(await repo.listRows(no), isEmpty,
          reason: '被拒的行写进库了');
    });

    test('提交之后加行 → 锁死，不写库', () async {
      final s = await repo.openOrCreate();
      final no = s['sheet_no'] as String;
      await repo.addRow(sheetNo: no, barcode: '6901', qtyRaw: '1');
      await repo.submitSheet(no);

      final d = await repo.addRow(sheetNo: no, barcode: '6902', qtyRaw: '1');
      expect(d.verdict, DeductVerdict.sheetLocked);
      expect(await repo.listRows(no), hasLength(1));
    });

    test('删行是重复条码的解法：删掉后可以重新扫', () async {
      final s = await repo.openOrCreate();
      final no = s['sheet_no'] as String;
      await repo.addRow(sheetNo: no, barcode: '6901', qtyRaw: '3');
      final rows = await repo.listRows(no);

      await repo.deleteRow(rows.first['id'] as int);
      expect(await repo.listRows(no), isEmpty);

      final again = await repo.addRow(sheetNo: no, barcode: '6901', qtyRaw: '7');
      expect(again.accepted, isTrue, reason: '删掉旧行后重新扫必须能进');
      expect((await repo.listRows(no)).first['qty'], 7.0);
    });

    test('setQty 改数量；非法数量直接抛（不静默吞掉）', () async {
      final s = await repo.openOrCreate();
      final no = s['sheet_no'] as String;
      await repo.addRow(sheetNo: no, barcode: '6901', qtyRaw: '3');
      final id = (await repo.listRows(no)).first['id'] as int;

      await repo.setQty(id, 8);
      expect((await repo.listRows(no)).first['qty'], 8.0);

      expect(() => repo.setQty(id, 0), throwsArgumentError);
      expect((await repo.listRows(no)).first['qty'], 8.0,
          reason: '抛异常的那次不该已经写进去了');
    });

    test('汇总：品种数与合计', () async {
      final s = await repo.openOrCreate();
      final no = s['sheet_no'] as String;
      await repo.addRow(sheetNo: no, barcode: '6901', qtyRaw: '2');
      await repo.addRow(sheetNo: no, barcode: '6902', qtyRaw: '3.5');

      final t = await repo.summary(no);
      expect(t.kinds, 2);
      expect(t.totalQty, 5.5);
      expect(t.totalText, '5.5');
    });

    test('条数上限：到顶后新条码被拦（用调小的 maxRows 验，不灌 500 行）', () async {
      final small = DeductRepo(maxRows: 2);
      final s = await small.openOrCreate();
      final no = s['sheet_no'] as String;
      await small.addRow(sheetNo: no, barcode: 'a', qtyRaw: '1');
      await small.addRow(sheetNo: no, barcode: 'b', qtyRaw: '1');

      final d = await small.addRow(sheetNo: no, barcode: 'c', qtyRaw: '1');
      expect(d.verdict, DeductVerdict.limit);
      expect(await small.listRows(no), hasLength(2), reason: '被上限拦的行写进库了');

      // 满了之后对**已存在的**条码仍报"重复"：它不算新行，
      // 报"上限"会把人往"去提交"引，而正确动作是"处理那一行"。
      final dup = await small.addRow(sheetNo: no, barcode: 'a', qtyRaw: '1');
      expect(dup.verdict, DeductVerdict.duplicate,
          reason: '满单时对已存在的条码报"上限"，会让人不知道该去处理那一行');
    });

    test('找不到的单 → 拒绝并说清楚，不是往空气里写', () async {
      expect(
          () => repo.addRow(
              sheetNo: 'JH-nope', barcode: '6901', qtyRaw: '1'),
          throwsStateError);
    });
  });

  // ============================================================
  group('状态流转', () {
    test('submit → reopen 能来回（交错了要能改回来）', () async {
      final s = await repo.openOrCreate();
      final no = s['sheet_no'] as String;
      await repo.submitSheet(no);
      expect((await repo.findSheet(no))!['status'], InvSheetStatus.submitted);

      await repo.reopenSheet(no);
      expect((await repo.findSheet(no))!['status'], InvSheetStatus.open);
      expect((await repo.findSheet(no))!['submitted_at'], isNull,
          reason: '撤销提交后还留着提交时间，报表会把它算成已交的单');
    });

    test('未提交的单能删（连明细一起）', () async {
      final s = await repo.openOrCreate();
      final no = s['sheet_no'] as String;
      await repo.addRow(sheetNo: no, barcode: '6901', qtyRaw: '1');

      await repo.deleteSheet(no);
      expect(await repo.findSheet(no), isNull);
      expect(await repo.listRows(no), isEmpty,
          reason: '单删了但明细还在，库里会攒一堆孤儿行');
    });

    test('🔴 已提交的单不能删（那是"货已经减了"的凭据）', () async {
      final s = await repo.openOrCreate();
      final no = s['sheet_no'] as String;
      await repo.submitSheet(no);
      expect(() => repo.deleteSheet(no), throwsStateError);
      expect(await repo.findSheet(no), isNotNull);
    });
  });

  // ============================================================
  group('历史单据（sheetBriefs）', () {
    test('🔴 没有明细的单算 0 条，不是 1 条（COUNT(*) 会把它算成 1）', () async {
      final s = await repo.openOrCreate();
      final no = s['sheet_no'] as String;
      final b = (await repo.sheetBriefs()).single;
      expect(b['sheet_no'], no);
      expect((b['rows'] as num).toInt(), 0,
          reason: '空单被算成 1 条 —— 面板上写"1 条"，点进去却是空的');
      expect((b['total_qty'] as num).toDouble(), 0.0);
    });

    test('交过的单也留在历史里，条数与合计都算得对', () async {
      final a = await repo.openOrCreate();
      final noA = a['sheet_no'] as String;
      await repo.addRow(sheetNo: noA, barcode: '6901', qtyRaw: '2');
      await repo.addRow(sheetNo: noA, barcode: '6902', qtyRaw: '3');
      await repo.submitSheet(noA);

      // 已经没有被提交之外的单了 → 这里必须开出一张新的（也是页面"开新单"的底层行为）
      final b = await repo.openOrCreate();
      final noB = b['sheet_no'] as String;
      expect(noB, isNot(noA), reason: '交过的单被当成了可复用的"进行中单"');

      final briefs = await repo.sheetBriefs();
      expect(briefs, hasLength(2));
      final byNo = <String, Map<String, dynamic>>{
        for (final x in briefs) x['sheet_no'] as String: x
      };
      expect((byNo[noA]!['rows'] as num).toInt(), 2);
      expect((byNo[noA]!['total_qty'] as num).toDouble(), 5.0);
      expect((byNo[noA]!['status'] as num).toInt(), InvSheetStatus.submitted,
          reason: '历史里看不出哪张交过 —— 员工会重复交一遍');
      expect((byNo[noB]!['rows'] as num).toInt(), 0);
      expect((byNo[noB]!['status'] as num).toInt(), InvSheetStatus.open);
    });

    test('历史里看不到盘点的单（又是那个 sheet_type 过滤）', () async {
      await seedStocktakeSheet();
      final s = await repo.openOrCreate();
      final briefs = await repo.sheetBriefs();
      expect(briefs.map((x) => x['sheet_no']).toList(),
          <Object?>[s['sheet_no']],
          reason: '盘点单混进减货历史了');
    });
  });

  // ============================================================
  group('🔴 与盘点的隔离（两套单共用两张表，这里最容易出事）', () {
    test('减货的查询看不见盘点的单', () async {
      await seedStocktakeSheet();
      // 盘点单是 status=0 的"进行中"单，如果查询漏了 sheet_type 过滤，
      // 减货页一进去就会把它当成自己的单打开 —— 员工会看到别人的盘点数据
      expect(await repo.openSheet(), isNull,
          reason: '减货把盘点的未完成单当成了自己的单');
      expect(await repo.listSheets(), isEmpty);
    });

    test('减货的汇总不把盘点的流水算进来', () async {
      await seedStocktakeSheet();
      final s = await repo.openOrCreate();
      final no = s['sheet_no'] as String;
      await repo.addRow(sheetNo: no, barcode: '6901', qtyRaw: '2');

      final t = await repo.summary(no);
      expect(t.kinds, 1, reason: '把盘点那笔流水算进减货汇总了');
      expect(t.totalQty, 2.0);
    });

    test('clearAll 清干净减货，但盘点的单与流水一动不动', () async {
      final invNo = await seedStocktakeSheet();
      final s = await repo.openOrCreate();
      final no = s['sheet_no'] as String;
      await repo.addRow(sheetNo: no, barcode: '6901', qtyRaw: '1');
      await repo.addRow(sheetNo: no, barcode: '6902', qtyRaw: '2');

      final r = await repo.clearAll();
      expect(r['sheets'], 1);
      expect(r['rows'], 2);

      // 减货侧空了
      expect(await repo.listSheets(), isEmpty);

      // 盘点侧**必须原样还在**
      final db = await LocalDb.I.db();
      final invSheets = await db.query('stocktake_sheet',
          where: 'sheet_no = ?', whereArgs: <Object?>[invNo]);
      expect(invSheets, hasLength(1), reason: '清减货把盘点单一起清了');
      expect(invSheets.first['sheet_type'], InvSheetType.stocktake);
      final invRows = await db.query('scan_record',
          where: 'sheet_no = ?', whereArgs: <Object?>[invNo]);
      expect(invRows, hasLength(1), reason: '清减货把盘点的流水一起清了');
      expect(invRows.first['qty'], 9.0);
    });

    test('减货单不会出现在盘点仓库的查询里（反向）', () async {
      final s = await repo.openOrCreate();
      await repo.addRow(
          sheetNo: s['sheet_no'] as String, barcode: '6901', qtyRaw: '1');

      final db = await LocalDb.I.db();
      final invOnly = await db.query('stocktake_sheet',
          where: "sheet_type = ?", whereArgs: <Object?>[InvSheetType.stocktake]);
      expect(invOnly, isEmpty, reason: '减货单被盘点侧认成了盘点单');
    });
  });
}
