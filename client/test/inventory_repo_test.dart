import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:xiaozhi_im_client/core/inventory_repo.dart';
import 'package:xiaozhi_im_client/core/inventory_rules.dart';
import 'package:xiaozhi_im_client/core/local_db.dart';
import 'package:xiaozhi_im_client/core/stocktake_repo.dart';

/// 盘点仓库层（点位 / 库位 / 单据 / 阶段 / 差异）的测试。
///
/// 判定逻辑本身已经在 inventory_rules_test.dart 里逐条钉过，
/// 这一层盯的是**"喂进判定的参数对不对、落库以后还读得回来吗"**：
///   · 未完成单被复用而不是新开一张（否则上次扫的"消失"）；
///   · 别的点位的商品真被拒绝、且**没写进库**（判定了但照写，等于没判）；
///   · 提交后本地就锁死；
///   · 清缓存别把扫码枪（PD 单）的数据一起清了。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
  final supportDir = '${Directory.systemTemp.path}/xz_inventory_test';
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

  Future<void> seedMaster(String barcode, String name, double accountQty) async {
    final db = await LocalDb.I.db();
    await db.insert(
      'stock_master',
      <String, Object?>{
        'barcode': barcode,
        'name': name,
        'spec': '',
        'unit': '个',
        'unit_price': 5.0,
        'account_qty': accountQty,
        'source': 'tiger',
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// 建点位 + 一个库位 + 把若干条码绑到该库位（最常用的开场）。
  Future<InventoryRepo> seedZone({
    String zone = 'Z01',
    String loc = 'Z01-A01',
    List<String> barcodes = const <String>[],
    int maxRows = 500,
  }) async {
    final repo = InventoryRepo(maxRows: maxRows);
    await repo.saveZone(code: zone, name: '生鲜区');
    await repo.saveLocation(locCode: loc, zoneCode: zone, name: 'A01 货架', sortNo: 1);
    for (final b in barcodes) {
      await repo.bindBarcode(b, loc);
    }
    return repo;
  }

  // ============================================================
  group('盘点位', () {
    test('saveZone 建得出来、查得回来', () async {
      final repo = InventoryRepo();
      await repo.saveZone(code: 'Z01', name: '生鲜区', storeCode: 'S001');
      final z = await repo.findZone('Z01');
      expect(z, isNotNull);
      expect(z!['zone_name'], '生鲜区');
      expect(z['store_code'], 'S001');
      expect(z['locked'], 0);
    });

    test('重复 saveZone 改名，但不得清掉 locked / created_at', () async {
      final repo = InventoryRepo();
      await repo.saveZone(code: 'Z01', name: '生鲜区');
      final before = await repo.findZone('Z01');
      await repo.setZoneLocked('Z01', true);
      await repo.saveZone(code: 'Z01', name: '生鲜区（改过名）');

      final after = await repo.findZone('Z01');
      expect(after!['zone_name'], '生鲜区（改过名）');
      expect(after['locked'], 1,
          reason: '点一次保存就把锁解了，这把锁等于没有');
      expect(after['created_at'], before!['created_at'],
          reason: '重复保存把创建时间也覆写了');
    });

    test('listZones 带库位数，锁定的排最后', () async {
      final repo = InventoryRepo();
      await repo.saveZone(code: 'Z01', name: '甲');
      await repo.saveZone(code: 'Z02', name: '乙');
      await repo.saveLocation(locCode: 'Z01-A', zoneCode: 'Z01');
      await repo.setZoneLocked('Z01', true);

      final list = await repo.listZones();
      expect(list.map((r) => r['zone_code']).toList(), <String>['Z02', 'Z01']);
      final z1 = list.firstWhere((r) => r['zone_code'] == 'Z01');
      expect(z1['loc_count'], 1);
    });

    test('deleteZone 级联清库位 + 绑定 + 该点位单据与流水，别的点位不受影响', () async {
      final repo = await seedZone(zone: 'Z01', loc: 'Z01-A01', barcodes: <String>['6901']);
      final repo2 = InventoryRepo();
      await repo2.saveZone(code: 'Z02', name: '日配区');
      await repo2.saveLocation(locCode: 'Z02-A01', zoneCode: 'Z02');
      await repo2.bindBarcode('6902', 'Z02-A01');
      final s2 = await repo2.openSheet(zoneCode: 'Z02', phase: 1);
      await repo2.scan(s2['sheet_no'] as String, '6902');

      final s1 = await repo.openSheet(zoneCode: 'Z01', phase: 1);
      await repo.scan(s1['sheet_no'] as String, '6901');

      final r = await repo.deleteZone('Z01');
      expect(r['zone'], 1);
      expect(r['location'], 1);
      expect(r['barcode_location'], 1);
      expect(r['scan_record'], 1);

      expect(await repo.findZone('Z01'), isNull);
      expect(await repo.listLocations('Z01'), isEmpty);
      expect(await repo.locationsOfBarcode('6901'), isEmpty);
      expect(await repo.listRows(s1['sheet_no'] as String), isEmpty);

      // 隔壁点位一根毛都不能少
      expect(await repo2.findZone('Z02'), isNotNull);
      expect(await repo2.listLocations('Z02'), hasLength(1));
      expect(await repo2.locationsOfBarcode('6902'), hasLength(1));
      expect(await repo2.listRows(s2['sheet_no'] as String), hasLength(1));
    });
  });

  // ============================================================
  group('库位与商品绑定', () {
    test('saveLocation 按 sort_no 排序', () async {
      final repo = InventoryRepo();
      await repo.saveZone(code: 'Z01', name: '生鲜区');
      await repo.saveLocation(locCode: 'Z01-C', zoneCode: 'Z01', sortNo: 3);
      await repo.saveLocation(locCode: 'Z01-A', zoneCode: 'Z01', sortNo: 1);
      await repo.saveLocation(locCode: 'Z01-B', zoneCode: 'Z01', sortNo: 2);

      final list = await repo.listLocations('Z01');
      expect(list.map((r) => r['loc_code']).toList(),
          <String>['Z01-A', 'Z01-B', 'Z01-C']);
    });

    test('saveLocation 不传名字时用货架位码当名字（界面不至于空着）', () async {
      final repo = InventoryRepo();
      await repo.saveZone(code: 'Z01', name: '生鲜区');
      await repo.saveLocation(locCode: 'Z01-A', zoneCode: 'Z01');
      final loc = await repo.findLocation('Z01-A');
      expect(loc!['loc_name'], 'Z01-A');
    });

    test('bindBarcode 幂等：第一次返回 1，再绑返回 0 且不报错', () async {
      final repo = await seedZone(zone: 'Z01', loc: 'Z01-A01');
      expect(await repo.bindBarcode('6901', 'Z01-A01'), 1);
      expect(await repo.bindBarcode('6901', 'Z01-A01'), 0,
          reason: '重复绑定抛异常的话，调用处就得到处 try/catch，容易把真异常一起吞掉');
      expect(await repo.locationsOfBarcode('6901'), hasLength(1));
    });

    test('一品多位：同一商品绑两个点位，zonesOfBarcode 两个都要有', () async {
      final db = await LocalDb.I.db();
      final repo = InventoryRepo();
      await repo.saveZone(code: 'Z01', name: '生鲜区');
      await repo.saveZone(code: 'Z02', name: '日配区');
      await repo.saveLocation(locCode: 'Z01-A', zoneCode: 'Z01');
      await repo.saveLocation(locCode: 'Z02-B', zoneCode: 'Z02');
      await repo.bindBarcode('6901', 'Z01-A');
      await repo.bindBarcode('6901', 'Z02-B');

      final zones = await repo.zonesOfBarcode('6901');
      expect(zones, <String>{'Z01', 'Z02'},
          reason: '主键写成单列 barcode 的话，第二个点位会把第一个顶掉，货就"消失"了');
      expect(db.isOpen, isTrue);
    });

    test('没绑过的条码 zonesOfBarcode 是空集（不是"不属于任何点位"）', () async {
      final repo = InventoryRepo();
      expect(await repo.zonesOfBarcode('0000NEW'), isEmpty);
    });

    test('deleteLocation 解绑商品，但不删商品档案', () async {
      final repo = await seedZone(zone: 'Z01', loc: 'Z01-A01', barcodes: <String>['6901']);
      await seedMaster('6901', '海盐饼干', 10);
      final r = await repo.deleteLocation('Z01-A01');
      expect(r['location'], 1);
      expect(r['barcode_location'], 1);
      expect(await repo.locationsOfBarcode('6901'), isEmpty);

      final db = await LocalDb.I.db();
      expect(await db.query('stock_master'), hasLength(1),
          reason: '删货架位把商品档案一起删了 —— 那是另一张表的事');
    });
  });

  // ============================================================
  group('开单', () {
    test('单号形如 INV-点位-阶段-时间戳', () {
      final no = InventoryRepo.newSheetNo('Z01', 2, DateTime(2026, 9, 19, 13, 4, 5));
      expect(no, 'INV-Z01-2-20260919130405');
      expect(no, startsWith('INV-'));
    });

    test('点位码带中文/斜杠会被洗掉，不会把 CSV 文件名搞坏', () {
      final no = InventoryRepo.newSheetNo('生鲜区/3', 1, DateTime(2026, 9, 19, 13, 4, 5));
      expect(no.contains('/'), isFalse, reason: '单号里有斜杠，导出文件名会被当目录');
      expect(no, startsWith('INV-'));
      expect(no, endsWith('-1-20260919130405'),
          reason: '阶段和时间戳不能被洗掉，否则单号看不出是哪一轮');
    });

    test('openSheet 复用该点位该阶段的未完成单（不新开）', () async {
      final repo = await seedZone();
      final a = await repo.openSheet(zoneCode: 'Z01', phase: 1);
      await repo.scan(a['sheet_no'] as String, '6901');
      final b = await repo.openSheet(zoneCode: 'Z01', phase: 1);
      expect(b['sheet_no'], a['sheet_no'],
          reason: '一进来就开新单，上次扫的数据在界面上"凭空消失"');
      expect(await repo.listRows(a['sheet_no'] as String), hasLength(1));
    });

    test('forceNew 才开新单，且旧单数据还在', () async {
      final repo = await seedZone();
      final a = await repo.openSheet(zoneCode: 'Z01', phase: 1);
      await repo.scan(a['sheet_no'] as String, '6901');
      final b = await repo.openSheet(zoneCode: 'Z01', phase: 1, forceNew: true);
      expect(b['sheet_no'], isNot(a['sheet_no']));
      expect(await repo.listRows(a['sheet_no'] as String), hasLength(1),
          reason: '重开新单把老单数据删了 —— 那应该走"清数据"的二次确认路径');
      expect(await repo.listRows(b['sheet_no'] as String), isEmpty);
    });

    test('已提交的单不算"未完成"，openSheet 会开新的一张', () async {
      final repo = await seedZone();
      final a = await repo.openSheet(zoneCode: 'Z01', phase: 1);
      await repo.scan(a['sheet_no'] as String, '6901');
      await repo.submitSheet(a['sheet_no'] as String);
      final b = await repo.openSheet(zoneCode: 'Z01', phase: 1);
      expect(b['sheet_no'], isNot(a['sheet_no']));
    });

    test('不同阶段是两张单（初盘和复盘不能混）', () async {
      final repo = await seedZone();
      final a = await repo.openSheet(zoneCode: 'Z01', phase: 1);
      final b = await repo.openSheet(zoneCode: 'Z01', phase: 2);
      expect(b['sheet_no'], isNot(a['sheet_no']));
      expect(b['phase'], 2);
    });

    test('点位锁定后开单被拒（错误信息要说清是哪个点位）', () async {
      final repo = await seedZone();
      await repo.setZoneLocked('Z01', true);
      await expectLater(
        repo.openSheet(zoneCode: 'Z01', phase: 1),
        throwsA(isA<StateError>()),
      );
      // 解锁后又能开
      await repo.setZoneLocked('Z01', false);
      final s = await repo.openSheet(zoneCode: 'Z01', phase: 1);
      expect(s['sheet_no'], isNotNull);
    });

    test('点位不存在 → 抛，不静默建一个空点位', () async {
      final repo = InventoryRepo();
      await expectLater(
        repo.openSheet(zoneCode: 'NOPE', phase: 1),
        throwsA(isA<StateError>()),
      );
    });

    test('非法阶段被拒（0 / 4 / -1）', () async {
      final repo = await seedZone();
      for (final p in <int>[0, 4, -1]) {
        await expectLater(
          repo.openSheet(zoneCode: 'Z01', phase: p),
          throwsA(isA<ArgumentError>()),
          reason: '阶段 $p 落库以后谁也说不清是什么',
        );
      }
    });
  });

  // ============================================================
  group('采集', () {
    test('同条码重复扫是数量累加，不是插新行', () async {
      final repo = await seedZone(barcodes: <String>['6901']);
      final s = await repo.openSheet(zoneCode: 'Z01', phase: 1);
      final no = s['sheet_no'] as String;

      final r1 = await repo.scan(no, '6901');
      expect(r1.accepted, isTrue);
      expect(r1.newQty, 1.0);
      final r2 = await repo.scan(no, '6901');
      expect(r2.newQty, 2.0);
      expect(r2.rowId, r1.rowId, reason: '插成两行的话汇总会多算一个品种');

      expect(await repo.listRows(no), hasLength(1));
    });

    test('阶段与货架位真的落库了（不是只在参数里过了一遍）', () async {
      final repo = await seedZone(barcodes: <String>['6901']);
      final s = await repo.openSheet(zoneCode: 'Z01', phase: 3);
      final no = s['sheet_no'] as String;
      await repo.scan(no, '6901', locCode: 'Z01-A01');

      final rows = await repo.listRows(no);
      expect(rows.first['phase'], 3);
      expect(rows.first['loc_code'], 'Z01-A01');
    });

    test('别的点位的商品被拒，而且**没写进库**', () async {
      final repo = await seedZone(zone: 'Z01', loc: 'Z01-A01');
      await repo.saveZone(code: 'Z02', name: '日配区');
      await repo.saveLocation(locCode: 'Z02-A01', zoneCode: 'Z02');
      await repo.bindBarcode('6909', 'Z02-A01');

      final s = await repo.openSheet(zoneCode: 'Z01', phase: 1);
      final no = s['sheet_no'] as String;
      final r = await repo.scan(no, '6909');

      expect(r.verdict, ScanVerdict.otherZone);
      expect(r.message, '当前盘点位不包含该商品');
      expect(await repo.listRows(no), isEmpty,
          reason: '判定了但照写 —— 等于没判，差异集会被别的点位的货污染');
    });

    test('没绑过货架位的条码放行，并提示未绑定', () async {
      final repo = await seedZone();
      final s = await repo.openSheet(zoneCode: 'Z01', phase: 1);
      final r = await repo.scan(s['sheet_no'] as String, '0000NEW');
      expect(r.verdict, ScanVerdict.okUnbound);
      expect(r.accepted, isTrue);
      expect(r.message, isNotNull);
    });

    test('达到条数上限后续扫被拦（上限可注入，不用真灌 500 条）', () async {
      final repo = await seedZone(maxRows: 3);
      final s = await repo.openSheet(zoneCode: 'Z01', phase: 1);
      final no = s['sheet_no'] as String;
      for (var i = 1; i <= 3; i++) {
        expect((await repo.scan(no, '690$i')).accepted, isTrue);
      }
      final over = await repo.scan(no, '6904');
      expect(over.verdict, ScanVerdict.phaseLimit);
      expect(over.message, contains('提交'));
      expect(await repo.listRows(no), hasLength(3), reason: '被拦的笔不该入账');
    });

    test('已在单里的条码累加不受上限限制', () async {
      final repo = await seedZone(maxRows: 2);
      final s = await repo.openSheet(zoneCode: 'Z01', phase: 1);
      final no = s['sheet_no'] as String;
      await repo.scan(no, '6901');
      await repo.scan(no, '6902');
      // 到了上限，但 6901 已经在这张单里 —— 给同一个商品加一件必须放行
      final again = await repo.scan(no, '6901');
      expect(again.accepted, isTrue,
          reason: '被自己的上限拦住，员工完全无法理解（他只是加了 1 件）');
      expect(again.newQty, 2.0);
    });

    test('提交后本地就锁死：任何写入都被拒', () async {
      final repo = await seedZone(barcodes: <String>['6901']);
      final s = await repo.openSheet(zoneCode: 'Z01', phase: 1);
      final no = s['sheet_no'] as String;
      await repo.scan(no, '6901');
      await repo.submitSheet(no);

      final r = await repo.scan(no, '6901');
      expect(r.verdict, ScanVerdict.sheetLocked);
      expect(await repo.summary(no).then((m) => m['total_qty']), 1.0,
          reason: '提交后还被改数，盘点结果就成了"可以事后修饰"的东西');
    });

    test('撤销提交后又能改（主管改口的那条路）', () async {
      final repo = await seedZone(barcodes: <String>['6901']);
      final s = await repo.openSheet(zoneCode: 'Z01', phase: 1);
      final no = s['sheet_no'] as String;
      await repo.submitSheet(no);
      expect(await repo.reopenSheet(no), 1);
      final r = await repo.scan(no, '6901');
      expect(r.accepted, isTrue);
    });

    test('setQty 改 0 / 负数 = 删掉这行，不留数量 0 的空记录', () async {
      final repo = await seedZone(barcodes: <String>['6901', '6902']);
      final s = await repo.openSheet(zoneCode: 'Z01', phase: 1);
      final no = s['sheet_no'] as String;
      await repo.scan(no, '6901');
      final r2 = await repo.scan(no, '6902');

      await repo.setQty(r2.rowId!, 0);
      expect(await repo.listRows(no), hasLength(1));
      expect((await repo.summary(no))['kinds'], 1);

      await repo.setQty((await repo.listRows(no)).first['id'] as int, 12);
      expect((await repo.summary(no))['total_qty'], 12.0);
    });

    test('scan 传 0 或 NaN 数量被拒（0 应该走 deleteRow）', () async {
      final repo = await seedZone();
      final s = await repo.openSheet(zoneCode: 'Z01', phase: 1);
      final no = s['sheet_no'] as String;
      await expectLater(repo.scan(no, '6901', qty: 0), throwsA(isA<ArgumentError>()));
      await expectLater(
          repo.scan(no, '6901', qty: double.nan), throwsA(isA<ArgumentError>()));
    });

    test('空条码 / 空白条码被拒', () async {
      final repo = await seedZone();
      final s = await repo.openSheet(zoneCode: 'Z01', phase: 1);
      await expectLater(
          repo.scan(s['sheet_no'] as String, '   '), throwsA(isA<ArgumentError>()));
    });

    test('单号不存在时抛，不静默吞掉（前台提示"已被清除缓存删掉"）', () async {
      final repo = await seedZone();
      await expectLater(
          repo.scan('INV-NOPE-1-20260101000000', '6901'), throwsA(isA<StateError>()));
    });

    test('减少到 0 会删行：再加一件回到 1（不是 0+1 的幽灵）', () async {
      final repo = await seedZone(barcodes: <String>['6901']);
      final s = await repo.openSheet(zoneCode: 'Z01', phase: 1);
      final no = s['sheet_no'] as String;
      await repo.scan(no, '6901');
      await repo.scan(no, '6901', qty: -1); // 归零 → 删行
      expect(await repo.listRows(no), isEmpty);
      final again = await repo.scan(no, '6901');
      expect(again.newQty, 1.0);
    });
  });

  // ============================================================
  group('阶段差异与失误笔数', () {
    test('初盘差异集 = 实盘 ≠ 账面，且含"账上没有"的条码', () async {
      final repo = await seedZone(barcodes: <String>['6901', '6902', '6903']);
      await seedMaster('6901', '对的', 10); // 实盘 10 → 无差异
      await seedMaster('6902', '少了', 10); // 实盘 8  → 差异
      // 6903 商档里没有 → 账面缺失，必须算差异

      final s = await repo.openSheet(zoneCode: 'Z01', phase: 1);
      final no = s['sheet_no'] as String;
      await repo.scan(no, '6901', qty: 10);
      await repo.scan(no, '6902', qty: 8);
      await repo.scan(no, '6903', qty: 1);

      final diff = await repo.diffBarcodes('Z01', 1);
      expect(diff, <String>{'6902', '6903'},
          reason: '账面缺失的条码被漏掉 = 最严重的一类差异没人看');
    });

    test('复盘只放差异集里的商品，非差异被拒且不入账', () async {
      final repo = await seedZone(barcodes: <String>['6901', '6902']);
      await seedMaster('6901', '对的', 10);
      await seedMaster('6902', '少了', 10);

      final s1 = await repo.openSheet(zoneCode: 'Z01', phase: 1);
      await repo.scan(s1['sheet_no'] as String, '6901', qty: 10); // 无差异
      await repo.scan(s1['sheet_no'] as String, '6902', qty: 8); // 有差异
      await repo.submitSheet(s1['sheet_no'] as String);

      final s2 = await repo.openSheet(zoneCode: 'Z01', phase: 2);
      final no2 = s2['sheet_no'] as String;

      final bad = await repo.scan(no2, '6901');
      expect(bad.verdict, ScanVerdict.notInDiffSet);
      expect(await repo.listRows(no2), isEmpty);

      final ok = await repo.scan(no2, '6902', qty: 10);
      expect(ok.accepted, isTrue);
      expect(await repo.listRows(no2), hasLength(1));
    });

    test('抽盘不受差异集限制', () async {
      final repo = await seedZone(barcodes: <String>['6901']);
      await seedMaster('6901', '对的', 10);
      final s1 = await repo.openSheet(zoneCode: 'Z01', phase: 1);
      await repo.scan(s1['sheet_no'] as String, '6901', qty: 10);
      await repo.submitSheet(s1['sheet_no'] as String);

      final s3 = await repo.openSheet(zoneCode: 'Z01', phase: 3);
      final r = await repo.scan(s3['sheet_no'] as String, '6901', qty: 9);
      expect(r.accepted, isTrue, reason: '抽盘被差异集卡住 = 主管没法抽查"看着正常"的商品');
    });

    test('失误笔数：初盘 12、复盘 15 → 1 笔；复盘没复核的不算失误', () async {
      final repo = await seedZone(barcodes: <String>['6901', '6902', '6903']);
      await seedMaster('6901', 'A', 10);
      await seedMaster('6902', 'B', 10);
      await seedMaster('6903', 'C', 10);

      // 初盘：6901/6902 都盘出差异（12、15），6903 正好 10 无差异
      final s1 = await repo.openSheet(zoneCode: 'Z01', phase: 1);
      final no1 = s1['sheet_no'] as String;
      await repo.scan(no1, '6901', qty: 12);
      await repo.scan(no1, '6902', qty: 15);
      await repo.scan(no1, '6903', qty: 10);
      await repo.submitSheet(no1);
      expect(await repo.diffBarcodes('Z01', 1), <String>{'6901', '6902'});
      expect(await repo.mistakeCount('Z01', 1), 0, reason: '初盘没有上一阶段');

      // 复盘只允许扫差异集：6901 改成 15（失误 1 笔），6902 不复核（不算失误）
      final s2 = await repo.openSheet(zoneCode: 'Z01', phase: 2);
      final no2 = s2['sheet_no'] as String;
      await repo.scan(no2, '6901', qty: 15);
      expect(await repo.listRows(no2), hasLength(1),
          reason: '6903 无差异却进了复盘的差异集，说明差异集算错了');

      expect(await repo.mistakeCount('Z01', 2), 1);
      expect(await repo.mistakeCount('Z01', 3), 0, reason: '抽盘还没扫，不该有失误数');
    });

    test('phaseProgress 给出三阶段的小结与状态', () async {
      final repo = await seedZone(barcodes: <String>['6901']);
      await seedMaster('6901', 'A', 10);
      final s = await repo.openSheet(zoneCode: 'Z01', phase: 1);
      await repo.scan(s['sheet_no'] as String, '6901', qty: 7);

      final prog = await repo.phaseProgress('Z01');
      expect(prog, hasLength(3));
      expect(prog[0]['phase'], 1);
      expect(prog[0]['label'], '初盘');
      expect(prog[0]['kinds'], 1);
      expect(prog[0]['diff'], 1);
      expect(prog[0]['status'], InvSheetStatus.open);
      expect(prog[1]['status'], -1, reason: '还没开的阶段要用 -1 表示"没有单"');
      expect(prog[2]['status'], -1);
    });

    test('phaseRows 跨该阶段的多张单做汇总（不是只看最后一张）', () async {
      final repo = await seedZone(barcodes: <String>['6901']);
      await seedMaster('6901', 'A', 10);
      final a = await repo.openSheet(zoneCode: 'Z01', phase: 1);
      await repo.scan(a['sheet_no'] as String, '6901', qty: 3);
      final b = await repo.openSheet(zoneCode: 'Z01', phase: 1, forceNew: true);
      await repo.scan(b['sheet_no'] as String, '6901', qty: 4);

      final rows = await repo.phaseRows('Z01', 1);
      expect(rows, hasLength(1), reason: '按条码汇总了，不该是两行');
      expect((rows.first['qty'] as num).toDouble(), 7.0);
      expect((rows.first['diff_qty'] as num).toDouble(), -3.0);
    });
  });

  // ============================================================
  group('缓存清理', () {
    test('clearZoneData 只清本点位的单据流水，点位/库位档案留着', () async {
      final repo = await seedZone(zone: 'Z01', loc: 'Z01-A01', barcodes: <String>['6901']);
      await repo.saveZone(code: 'Z02', name: '日配区');
      await repo.saveLocation(locCode: 'Z02-A01', zoneCode: 'Z02');
      final s1 = await repo.openSheet(zoneCode: 'Z01', phase: 1);
      await repo.scan(s1['sheet_no'] as String, '6901');
      final s2 = await repo.openSheet(zoneCode: 'Z02', phase: 1);
      // 6902 没绑任何货架位 → 放行并提示；这里只是要 Z02 有自己的数据
      await repo.scan(s2['sheet_no'] as String, '6902');

      final r = await repo.clearZoneData('Z01');
      expect(r['sheet'], 1);
      expect(r['scan_record'], 1);

      expect(await repo.findZone('Z01'), isNotNull, reason: '清数据不该把点位档案删了');
      expect(await repo.listLocations('Z01'), hasLength(1));
      expect(await repo.locationsOfBarcode('6901'), hasLength(1));
      // 隔壁点位数据还在
      expect(await repo.listRows(s2['sheet_no'] as String), hasLength(1));
    });

    test('clearAllData 清掉所有盘点单，但**不许碰扫码枪（PD）的数据**', () async {
      final repo = await seedZone(barcodes: <String>['6901']);
      final s = await repo.openSheet(zoneCode: 'Z01', phase: 1);
      await repo.scan(s['sheet_no'] as String, '6901');

      // 扫码枪模块的单（同一个 scan_record 表）
      final scan = StocktakeRepo();
      final pd = StocktakeRepo.newSheetNo();
      await scan.addScan(pd, '8888', qty: 2);

      await repo.clearAllData();
      expect(await repo.listSheetsOfZone('Z01'), isEmpty,
          reason: '盘点单没清干净');
      expect(await scan.listScans(pd), hasLength(1),
          reason: '清盘点缓存把扫码枪的单也清了 —— 那批扫码数据就白干了');
    });

    test('clearAllData 之后还能重新开单（不是把库搞坏了）', () async {
      final repo = await seedZone(barcodes: <String>['6901']);
      final a = await repo.openSheet(zoneCode: 'Z01', phase: 1);
      await repo.scan(a['sheet_no'] as String, '6901');
      await repo.clearAllData();
      final b = await repo.openSheet(zoneCode: 'Z01', phase: 1);
      expect(await repo.listRows(b['sheet_no'] as String), isEmpty);
      expect((await repo.scan(b['sheet_no'] as String, '6901')).accepted, isTrue);
    });

    test('deleteSheet 只删指定那张单', () async {
      final repo = await seedZone(barcodes: <String>['6901']);
      final a = await repo.openSheet(zoneCode: 'Z01', phase: 1);
      await repo.scan(a['sheet_no'] as String, '6901');
      final b = await repo.openSheet(zoneCode: 'Z01', phase: 1, forceNew: true);
      await repo.scan(b['sheet_no'] as String, '6901');

      await repo.deleteSheet(b['sheet_no'] as String);
      expect(await repo.listRows(b['sheet_no'] as String), isEmpty);
      expect(await repo.listRows(a['sheet_no'] as String), hasLength(1));
    });
  });

  // ============================================================
  group('上传标记', () {
    test('markUploaded 把单置为已上传并清掉流水的未上传标记', () async {
      final repo = await seedZone(barcodes: <String>['6901']);
      final s = await repo.openSheet(zoneCode: 'Z01', phase: 1);
      final no = s['sheet_no'] as String;
      await repo.scan(no, '6901');
      await repo.submitSheet(no);
      expect((await repo.summary(no))['pending'], 1);

      await repo.markUploaded(no);
      expect((await repo.findSheet(no))!['status'], InvSheetStatus.uploaded);
      expect((await repo.summary(no))['pending'], 0);
    });

    test('已上传的单也照样锁着（不能再扫）', () async {
      final repo = await seedZone(barcodes: <String>['6901']);
      final s = await repo.openSheet(zoneCode: 'Z01', phase: 1);
      final no = s['sheet_no'] as String;
      await repo.scan(no, '6901');
      await repo.submitSheet(no);
      await repo.markUploaded(no);
      expect((await repo.scan(no, '6901')).verdict, ScanVerdict.sheetLocked);
    });
  });
}
