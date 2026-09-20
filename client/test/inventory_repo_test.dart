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
      final s = await repo.openSheet(zoneCode: 'Z01', phase: 2);
      final no = s['sheet_no'] as String;
      await repo.scan(no, '6901', locCode: 'Z01-A01');

      final rows = await repo.listRows(no);
      expect(rows.first['phase'], 2,
          reason: '阶段没落库的话，三遍制的差异汇总会把初盘/复盘/抽盘混成一锅');
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
    test('初盘没有上一阶段 → 差异集必空（账面数不参与判定）', () async {
      final repo = await seedZone(barcodes: <String>['6901', '6902', '6903']);
      await seedMaster('6901', '对的', 10); // 实盘 10
      await seedMaster('6902', '少了', 10); // 实盘 8
      // 6903 商档里没有

      final s = await repo.openSheet(zoneCode: 'Z01', phase: 1);
      final no = s['sheet_no'] as String;
      await repo.scan(no, '6901', qty: 10);
      await repo.scan(no, '6902', qty: 8);
      await repo.scan(no, '6903', qty: 1);

      expect(await repo.diffBarcodes('Z01', 1), isEmpty,
          reason: '初盘拿账面当基准的话这里会冒出 {6902,6903} —— 差异集恒等于全部商品，'
              '三遍制就退化成把同一个货架扫三遍（门店的泰格库里根本没有可用账面数）');

      // 账面数不参与判定 ≠ 不用显示：明细里仍要带出来当参考列
      final rows = await repo.phaseRows('Z01', 1);
      final r2 = rows.firstWhere((r) => r['barcode'] == '6902');
      expect((r2['account_qty'] as num).toDouble(), 10.0);
      expect(r2['prev_qty'], isNull);
      expect(r2['diff_qty'], isNull);
    });

    test('复盘与初盘数量对不上就是差异（含上一轮有这一轮没了）', () async {
      final repo = await seedZone(barcodes: <String>['6901', '6902', '6903']);
      final s1 = await repo.openSheet(zoneCode: 'Z01', phase: 1);
      await repo.scan(s1['sheet_no'] as String, '6901', qty: 10);
      await repo.scan(s1['sheet_no'] as String, '6902', qty: 8);
      await repo.scan(s1['sheet_no'] as String, '6903', qty: 1);
      await repo.submitSheet(s1['sheet_no'] as String);

      final s2 = await repo.openSheet(zoneCode: 'Z01', phase: 2);
      final no2 = s2['sheet_no'] as String;
      await repo.scan(no2, '6901', qty: 10); // 一致 → 不是差异
      await repo.scan(no2, '6902', qty: 9); // 8 → 9 → 差异
      // 6903 第二遍没扫到 → 漏盘，也是差异

      expect(await repo.diffBarcodes('Z01', 2), <String>{'6902', '6903'},
          reason: '漏盘的条码被漏掉 = 最严重的一类差异没人看（明细里"少一行"看不出来）');
    });

    test('抽盘只放"和上一阶段对不上"的商品，一致的被拒且不入账', () async {
      final repo = await seedZone(barcodes: <String>['6901', '6902']);

      final s1 = await repo.openSheet(zoneCode: 'Z01', phase: 1);
      await repo.scan(s1['sheet_no'] as String, '6901', qty: 10);
      await repo.scan(s1['sheet_no'] as String, '6902', qty: 8);
      await repo.submitSheet(s1['sheet_no'] as String);

      final s2 = await repo.openSheet(zoneCode: 'Z01', phase: 2);
      await repo.scan(s2['sheet_no'] as String, '6901', qty: 10); // 与初盘一致
      await repo.scan(s2['sheet_no'] as String, '6902', qty: 12); // 与初盘不一致
      await repo.submitSheet(s2['sheet_no'] as String);
      expect(await repo.diffBarcodes('Z01', 2), <String>{'6902'});

      final s3 = await repo.openSheet(zoneCode: 'Z01', phase: 3);
      final no3 = s3['sheet_no'] as String;

      final bad = await repo.scan(no3, '6901');
      expect(bad.verdict, ScanVerdict.notInDiffSet);
      expect(await repo.listRows(no3), isEmpty,
          reason: '判定了但照写 —— 等于没判，主管的抽盘单会被"看着正常"的商品淹掉');

      final ok = await repo.scan(no3, '6902', qty: 11);
      expect(ok.accepted, isTrue);
      expect(await repo.listRows(no3), hasLength(1));
    });

    test('复盘不受差异集限制：这一片要能重新全盘一遍', () async {
      final repo = await seedZone(barcodes: <String>['6901', '6902']);
      final s1 = await repo.openSheet(zoneCode: 'Z01', phase: 1);
      await repo.scan(s1['sheet_no'] as String, '6901', qty: 10);
      await repo.scan(s1['sheet_no'] as String, '6902', qty: 10);
      await repo.submitSheet(s1['sheet_no'] as String);
      expect(await repo.diffBarcodes('Z01', 1), isEmpty);

      final s2 = await repo.openSheet(zoneCode: 'Z01', phase: 2);
      final no2 = s2['sheet_no'] as String;
      expect((await repo.scan(no2, '6901', qty: 10)).accepted, isTrue);
      expect((await repo.scan(no2, '6902', qty: 9)).accepted, isTrue,
          reason: '复盘先按差异集卡住 = 默认初盘是对的，复盘就变成走过场，'
              '初盘漏扫的货永远没人补');
    });

    test('失误笔数：初盘 12 → 复盘 15 算 1 笔；复盘没复核的不算失误', () async {
      final repo = await seedZone(barcodes: <String>['6901', '6902', '6903']);
      await seedMaster('6901', 'A', 10);
      await seedMaster('6902', 'B', 10);
      await seedMaster('6903', 'C', 10);

      // 初盘：6901=12、6902=15、6903=10
      final s1 = await repo.openSheet(zoneCode: 'Z01', phase: 1);
      final no1 = s1['sheet_no'] as String;
      await repo.scan(no1, '6901', qty: 12);
      await repo.scan(no1, '6902', qty: 15);
      await repo.scan(no1, '6903', qty: 10);
      await repo.submitSheet(no1);
      expect(await repo.diffBarcodes('Z01', 1), isEmpty,
          reason: '初盘没有上一阶段，不产生差异集');
      expect(await repo.mistakeCount('Z01', 1), 0, reason: '初盘没有上一阶段');

      // 复盘：6901 改成 15（≠12 → 1 笔失误）；6902 不复核（不算失误）；6903 照抄
      final s2 = await repo.openSheet(zoneCode: 'Z01', phase: 2);
      final no2 = s2['sheet_no'] as String;
      await repo.scan(no2, '6901', qty: 15);
      await repo.scan(no2, '6903', qty: 10);
      expect(await repo.listRows(no2), hasLength(2));

      expect(await repo.diffBarcodes('Z01', 2), <String>{'6901', '6902'},
          reason: '6901 数量对不上；6902 初盘有、复盘根本没扫 = 漏盘，也必须进差异集 '
              '（差异集是"抽盘要去看的清单"，不是"员工犯错的清单"）');
      expect(await repo.mistakeCount('Z01', 2), 1,
          reason: '6902 上一轮 15、这一轮没扫，是"差异未复核"，不算失误 —— '
              '混进失误笔数会让这个数虚高，主管没法拿它考核。'
              '差异集 ⊇ 失误，两者本来就不是一个东西');
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
      expect(prog[0]['diff'], 0,
          reason: '初盘没有上一阶段 → 差异数只能是 0（拿账面 10 当基准的话这里会变成 1）');
      expect(prog[0]['mistakes'], 0);
      expect(prog[0]['status'], InvSheetStatus.open);
      expect(prog[1]['status'], -1, reason: '还没开的阶段要用 -1 表示"没有单"');
      expect(prog[2]['status'], -1);

      // 复盘扫成 9 → 相对初盘的 7 差 2
      final s2 = await repo.openSheet(zoneCode: 'Z01', phase: 2);
      await repo.scan(s2['sheet_no'] as String, '6901', qty: 9);
      final prog2 = await repo.phaseProgress('Z01');
      expect(prog2[0]['diff'], 0, reason: '初盘的差异数不该被后来的复盘改写');
      expect(prog2[1]['diff'], 1);
      expect(prog2[1]['mistakes'], 1, reason: '初盘 7 → 复盘 9，是 1 笔失误');
    });

    test('🔴 diffRows 把漏盘补成一行（含商品名），差异表才看得见', () async {
      final repo = await seedZone(barcodes: <String>['6901', '6902']);
      await seedMaster('6902', '方便面', 10);

      final s1 = await repo.openSheet(zoneCode: 'Z01', phase: 1);
      await repo.scan(s1['sheet_no'] as String, '6901', qty: 10);
      await repo.scan(s1['sheet_no'] as String, '6902', qty: 4);
      await repo.submitSheet(s1['sheet_no'] as String);

      final s2 = await repo.openSheet(zoneCode: 'Z01', phase: 2);
      await repo.scan(s2['sheet_no'] as String, '6901', qty: 7); // 10 → 7
      // 6902 这一遍没扫 → 漏盘

      final rows = await repo.diffRows('Z01', 2);
      expect(rows, hasLength(2), reason: '只挑本阶段的行会漏掉 6902 这一条漏盘');

      final a = rows.firstWhere((r) => r['barcode'] == '6901');
      expect(a['missing'], isNot(true), reason: '数量对不上，不是漏盘');
      expect((a['diff_qty'] as num).toDouble(), -3.0);

      final b = rows.firstWhere((r) => r['barcode'] == '6902');
      expect(b['missing'], isTrue);
      expect((b['qty'] as num).toDouble(), 0.0);
      expect((b['prev_qty'] as num).toDouble(), 4.0);
      expect((b['diff_qty'] as num).toDouble(), -4.0);
      expect(b['name'], '方便面',
          reason: '差异表上只有一串条码的话，主管不知道该去货架上找什么');
    });

    test('diffRows 在初盘没有参照 → 空表（不是"全部商品都是差异"）', () async {
      final repo = await seedZone(barcodes: <String>['6901']);
      final s = await repo.openSheet(zoneCode: 'Z01', phase: 1);
      await repo.scan(s['sheet_no'] as String, '6901', qty: 3);
      expect(await repo.diffRows('Z01', 1), isEmpty);
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
      expect(rows.first['prev_qty'], isNull, reason: '初盘没有上一阶段');
      expect(rows.first['diff_qty'], isNull);
      expect((rows.first['account_qty'] as num).toDouble(), 10.0,
          reason: '账面数仍要带出来当参考列，只是不参与差异判定');

      // 复盘扫 5 → 相对初盘 7 是 -2
      final c = await repo.openSheet(zoneCode: 'Z01', phase: 2);
      await repo.scan(c['sheet_no'] as String, '6901', qty: 5);
      final r2 = await repo.phaseRows('Z01', 2);
      expect((r2.first['prev_qty'] as num).toDouble(), 7.0);
      expect((r2.first['diff_qty'] as num).toDouble(), -2.0);
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

  // ============================================================
  // 抽盘的复核清单（第三遍）
  //
  // 🔴 这里钉的是**行集的来源**：必须是"初盘 vs 复盘"对不上的那批，
  //    而不是"抽盘 − 复盘"。后者在主管把数量改对之后会变成 0，
  //    那一行就当场从表上消失 —— 可"改对了"不等于"这个商品没疑问"。
  // ============================================================
  group('抽盘复核清单', () {
    /// 初盘 [first] / 复盘 [second] 各扫一遍，返回 repo。
    Future<InventoryRepo> seedTwoPasses(
      Map<String, double> first,
      Map<String, double> second,
    ) async {
      final repo = await seedZone(
          barcodes: <String>{...first.keys, ...second.keys}.toList());
      for (final e in first.entries) {
        final s = await repo.openSheet(zoneCode: 'Z01', phase: 1);
        await repo.scan(s['sheet_no'] as String, e.key, qty: e.value);
      }
      for (final e in second.entries) {
        final s = await repo.openSheet(zoneCode: 'Z01', phase: 2);
        await repo.scan(s['sheet_no'] as String, e.key, qty: e.value);
      }
      return repo;
    }

    List<String> codesOf(List<Map<String, dynamic>> rows) =>
        rows.map((r) => r['barcode'] as String).toList()..sort();

    test('清单 = 前两遍对不上的那批（对得上的不进）', () async {
      final repo = await seedTwoPasses(
        {'6901': 10, '6902': 5},
        {'6901': 10, '6902': 7},
      );
      final rows = await repo.diffRows('Z01', InvPhase.third);
      expect(codesOf(rows), ['6902']);
      final r = rows.single;
      expect(r['base_qty'], 5.0, reason: '初盘数量');
      expect(r['prev_qty'], 7.0, reason: '复盘数量');
      expect(r['base_diff'], 2.0, reason: '前两遍的差异（复盘 − 初盘）');
      expect(r['review'], InventoryRules.reviewPending, reason: '抽盘还没扫');
      expect((r['qty'] as num).toDouble(), 0.0);
    });

    // 🔴 这条是这次修复的核心反向用例：
    //    主管把抽盘数量改成跟复盘一致（= 复核通过）之后，
    //    那一行**必须还在清单里**，review 从 pending 变 aligned。
    //    旧口径（行集 = 抽盘 − 复盘）在这条上会得到空表 —— 越认真复核表越短。
    test('复核改对之后那一行仍在清单里，只是结论变成"已复核一致"', () async {
      final repo = await seedTwoPasses(
        {'6902': 5},
        {'6902': 7},
      );
      final s3 = await repo.openSheet(zoneCode: 'Z01', phase: 3);
      await repo.scan(s3['sheet_no'] as String, '6902', qty: 7);

      final rows = await repo.diffRows('Z01', InvPhase.third);
      expect(codesOf(rows), ['6902'],
          reason: '复核改对后行从清单里消失了 —— 主管最终核对时就没有台账了');
      final r = rows.single;
      expect(r['review'], InventoryRules.reviewAligned);
      expect(r['diff_qty'], 0.0, reason: '复核结果 = 抽盘 − 复盘 = 0（改对了）');
      expect(r['base_diff'], 2.0, reason: '前两遍的差异不受复核影响，仍是 2');

      final t = InventoryRules.tallyReview(rows);
      expect(t.total, 1);
      expect(t.aligned, 1);
      expect(t.pending, 0);
    });

    test('复盘漏盘（初盘盘过、复盘没扫）也在清单里', () async {
      final repo = await seedTwoPasses(
        {'6901': 10, '6902': 5},
        {'6901': 10},
      );
      final rows = await repo.diffRows('Z01', InvPhase.third);
      expect(codesOf(rows), ['6902'],
          reason: '"少一行"在明细里看不出来，最该复核的一类不许漏');
      expect(rows.single['base_missing'], isTrue);
      expect(rows.single['prev_qty'], isNull);
      expect(rows.single['base_qty'], 5.0);
    });

    test('复盘新扫出来（初盘没有）也在清单里，而且**扫得进去**', () async {
      final repo = await seedTwoPasses(
        {'6901': 10},
        {'6901': 10, '6902': 3},
      );
      final rows = await repo.diffRows('Z01', InvPhase.third);
      expect(codesOf(rows), ['6902']);

      // 准入集合必须和清单**同一个集合**：表上列着、枪上拒收，
      // 员工就只能干瞪眼，最后靠"随手改个数量"绕过去。
      final admit = await repo.reviewBarcodes('Z01');
      expect(admit, {'6902'});
      final s3 = await repo.openSheet(zoneCode: 'Z01', phase: 3);
      final r = await repo.scan(s3['sheet_no'] as String, '6902', qty: 3);
      expect(r.accepted, isTrue,
          reason: '复核清单上有的商品，抽盘时却被当成"不在差异集"拒收');
    });

    test('两遍全对得上 → 清单为空（反向）', () async {
      final repo = await seedTwoPasses(
        {'6901': 10, '6902': 5},
        {'6901': 10, '6902': 5},
      );
      expect(await repo.diffRows('Z01', InvPhase.third), isEmpty);
      expect(await repo.reviewBarcodes('Z01'), isEmpty);
      final rp = await repo.reviewProgress('Z01');
      expect(rp['total'], 0);
    });

    test('抽盘扫了清单外的商品 → 拒收（准入仍然成立）', () async {
      final repo = await seedTwoPasses(
        {'6901': 10, '6902': 5},
        {'6901': 10, '6902': 7},
      );
      final s3 = await repo.openSheet(zoneCode: 'Z01', phase: 3);
      // 6901 前两遍对得上，不属于复核清单
      final r = await repo.scan(s3['sheet_no'] as String, '6901', qty: 10);
      expect(r.verdict, ScanVerdict.notInDiffSet);
    });

    test('阶段条：抽盘报的是"待复核数"，不是"抽盘 − 复盘"', () async {
      final repo = await seedTwoPasses(
        {'6901': 10, '6902': 5, '6903': 2},
        {'6901': 10, '6902': 7, '6903': 4},
      );
      var p = (await repo.phaseProgress('Z01'))
          .firstWhere((x) => (x['phase'] as num).toInt() == 3);
      expect(p['diff'], 2, reason: '复核清单 2 种');
      expect(p['pending_review'], 2);

      // 把两条都复核成与复盘一致
      final s3 = await repo.openSheet(zoneCode: 'Z01', phase: 3);
      final no = s3['sheet_no'] as String;
      await repo.scan(no, '6902', qty: 7);
      await repo.scan(no, '6903', qty: 4);

      p = (await repo.phaseProgress('Z01'))
          .firstWhere((x) => (x['phase'] as num).toInt() == 3);
      expect(p['pending_review'], 0, reason: '都复核过了');
      expect(p['diff'], 2,
          reason: '这里掉到 0 的话，阶段条会显示"没问题"，'
              '而实际上是"刚认真复核完一遍" —— 两个意思正好相反');
    });

    test('清单外的条码不因为"反正扫不进去"被静默丢掉', () async {
      // 拒收时库里不能留下这一行（否则汇总会多算品种）。
      final repo = await seedTwoPasses(
        {'6901': 10, '6902': 5},
        {'6901': 10, '6902': 7},
      );
      final s3 = await repo.openSheet(zoneCode: 'Z01', phase: 3);
      final no = s3['sheet_no'] as String;
      await repo.scan(no, '6901', qty: 10);
      expect(await repo.listRows(no), isEmpty);
    });
  });
}
