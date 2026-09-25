import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xiaozhi_im_client/core/inventory_rules.dart';
import 'package:xiaozhi_im_client/core/local_db.dart';
import 'package:xiaozhi_im_client/core/simple_repo.dart';
import 'package:xiaozhi_im_client/core/simple_rules.dart';

/// 简易盘点仓库层（本地 SQLite）的测试。
///
/// 判定本身在 simple_rules_test.dart 里逐条钉过；这一层盯的是
/// **"判定被真的执行了没有、落库以后还读得回来吗、有没有波及别人的数据"**：
///   · 同一场景只允许一个进行中的任务，换清单要能**归档旧的而不删旧的**；
///   · 同一趟里同码再扫 = **累加**（不是插第二行、更不是被拒）；
///   · 清单外的商品**必须放行**，而且明细里要看得见它（LEFT JOIN 不能写成 INNER）；
///   · 被拒的扫码**不许写库**；
///   · 清简易盘点**一个字节都不能碰盘点单和减货单**（三套单据共用两张表）。
///
/// ⚠️ 还有一个同名的本机自测 `tools/simple_selftest.dart`（纯函数部分）——
///    那个是因为这台机器 `flutter test` 起不来才凑的**预检**，
///    正式判据是**本文件**。见 tools/run_pure_tests.sh 顶上的说明。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
  final supportDir = '${Directory.systemTemp.path}/xz_simple_test';
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(pathChannel, (call) async {
    if (call.method == 'getApplicationSupportDirectory') return supportDir;
    return null;
  });

  late SimpleRepo repo;

  setUp(() async {
    await LocalDb.I.resetForTest();
    repo = SimpleRepo();
  });

  tearDown(() async {
    await LocalDb.I.close();
  });

  /// 造一批清单行（条码 13 位，像真条码）。
  List<SimpleImportRow> rows(int n, {int from = 0}) =>
      List<SimpleImportRow>.generate(
        n,
        (i) => SimpleImportRow(
          barcode: '6901234${(567890 + from + i).toString().padLeft(6, '0')}',
          name: '商品${from + i}',
          spec: '',
          seq: i + 1,
        ),
      );

  /// 开一轮（默认卖场），返回任务号。
  Future<String> openRound({String scene = 'store', int n = 5}) async {
    final t = await repo.startNewRound(scene: scene, rows: rows(n));
    return (t['task_no'] ?? '').toString();
  }

  // ============================================================
  group('轮次（任务）', () {
    test('新建一轮：任务号带 SMP- 前缀，进行中，清单条数回写到 total_items', () async {
      final t = await repo.startNewRound(
          scene: SimpleScene.store, rows: rows(3));
      expect((t['task_no'] as String), startsWith(SimpleRepo.taskPrefix));
      expect(t['scene'], SimpleScene.store);
      expect(t['status'], SimpleRepo.taskOpen);
      expect(t['total_items'], 3);
      expect(
          (await repo.listItems(t['task_no'] as String)).length, 3);
    });

    test('清单按导入顺序排（seq 保序），导出照这个排才对得上手写的单子', () async {
      final t = await repo.startNewRound(
        scene: SimpleScene.store,
        rows: <SimpleImportRow>[
          const SimpleImportRow(
              barcode: 'B3', name: '第三', spec: '', seq: 1),
          const SimpleImportRow(
              barcode: 'B1', name: '第一', spec: '', seq: 2),
          const SimpleImportRow(
              barcode: 'B2', name: '第二', spec: '', seq: 3),
        ],
      );
      final items = await repo.listItems(t['task_no'] as String);
      expect(items.map((i) => i['barcode']).toList(), <String>['B3', 'B1', 'B2']);
    });

    test('🔴 换一份清单：同场景旧的被**归档**（不是删掉），新的才是进行中', () async {
      final first = await openRound(n: 3);
      final second = await openRound(n: 4);

      final old = await repo.findTask(first);
      final now = await repo.findTask(second);
      expect(old!['status'], SimpleRepo.taskArchived, reason: '旧的必须被归档');
      expect(now!['status'], SimpleRepo.taskOpen);

      // 🔴 归档**不删数据**：方案 §7 第 8 条要求"上一轮的数还在、导出仍对"
      expect((await repo.listItems(first)).length, 3,
          reason: '上一轮的清单必须还在');
    });

    test('🔴 同一场景不可能同时有两轮进行中', () async {
      await openRound(scene: SimpleScene.store, n: 2);
      await openRound(scene: SimpleScene.store, n: 2);
      final all = await repo.listTasks();
      final open = all
          .where((t) => (t['status'] as num).toInt() == SimpleRepo.taskOpen)
          .toList();
      expect(open.length, 1);
    });

    test('仓库与卖场可以各有一轮进行中（两个场景互不影响）', () async {
      final s = await openRound(scene: SimpleScene.store, n: 2);
      final w = await openRound(scene: SimpleScene.warehouse, n: 2);
      expect(s, isNot(w));
      expect((await repo.openTaskOf(SimpleScene.store))!['task_no'], s);
      expect((await repo.openTaskOf(SimpleScene.warehouse))!['task_no'], w);
    });

    test('latestTask 优先给进行中的那一轮（不是刚归档的那一轮）', () async {
      final a = await openRound(scene: SimpleScene.store, n: 1);
      // 把卖场那轮归档，换成仓库的一轮（仓库那轮才是进行中）
      final b = await openRound(scene: SimpleScene.warehouse, n: 1);
      await repo.archiveTask(a);
      expect((await repo.latestTask())!['task_no'], b);
    });

    test('任务不存在时报错，不静默', () async {
      // 两种语义要分清：
      //   · "它到底在不在" → findTask 返回 null（它就是干查询的）；
      //   · "拿这一轮的内容" → **必须吵起来**。给空列表的话，界面上和
      //     "还没导清单 / 一件都没盘"长得一模一样 —— 员工会照着空清单
      //     盘一整趟，导出来才发现 0 行。
      await expectLater(repo.findTask('SMP-nope'), completion(isNull));
      await expectLater(repo.listItems('SMP-nope'), throwsA(isA<StateError>()));
      // 同一个口径要盖住"拿内容"的每个入口：只拦一个等于没拦
      // （换个入口照样静默，而且更难发现）。
      await expectLater(repo.listNodes('SMP-nope'), throwsA(isA<StateError>()));
      await expectLater(repo.taskTally('SMP-nope'), throwsA(isA<StateError>()));
      // ⚠️ 空串是**参数本身不合法**（ArgumentError），跟"目标不存在"
      //    （StateError）分开：这两种错排查方向完全不同。
      await expectLater(repo.listItems('  '), throwsA(isA<ArgumentError>()));
    });
  });

  // ============================================================
  group('待盘清单', () {
    test('🔴 重新导清单是**整份替换**，不留上一份的残留', () async {
      final no = await openRound(n: 3);
      final want = rows(2, from: 900).map((r) => r.barcode).toList();
      await repo.importItems(no, rows(2, from: 900));
      final items = await repo.listItems(no);
      // 断言**集合完全相等**，不用 contains 之类的弱判据：
      // 弱判据在"旧的没清掉但新的进来了"时照样能过，而那正是这条要防的。
      expect(items.map((i) => i['barcode']).toList(), want);
      expect((await repo.findTask(no))!['total_items'], 2);
    });

    test('inImportedList 认条码（带空格也要认）', () async {
      final no = await openRound(n: 2);
      final code = rows(2).first.barcode;
      expect(await repo.inImportedList(no, code), isTrue);
      expect(await repo.inImportedList(no, code), isTrue);
      expect(await repo.inImportedList(no, '0000000000000'), isFalse);
    });
  });

  // ============================================================
  group('节点（一趟）', () {
    test('节点号 = 任务号-阶段号，sheet_type=simple，zone_code 存任务号', () async {
      final no = await openRound();
      final n = await repo.openOrCreateNode(no, SimplePhase.first);
      expect(n['sheet_no'], '${no}-01');
      expect(n['sheet_type'], InvSheetType.simple);
      expect(n['zone_code'], no, reason: 'zone_code 借来存任务号');
      expect(n['phase'], SimplePhase.first);
      expect(n['status'], InvSheetStatus.open);
    });

    test('重复调用复用同一趟（不会一进来就新开一张，让上次扫的数据"消失"）', () async {
      final no = await openRound();
      final a = await repo.openOrCreateNode(no, SimplePhase.first);
      final b = await repo.openOrCreateNode(no, SimplePhase.first);
      expect(a['sheet_no'], b['sheet_no']);
      expect((await repo.listNodes(no)).length, 1);
    });

    test('🔴 S1 的阶段闸门：复盘 / 差异复盘要 S2 才做，现在**明说做不到**', () async {
      final no = await openRound();
      // 差异复盘的准入依赖"前两趟的差异集"，现在还没算 —— 这时候若让它
      // "看起来能开"，员工把对上的商品又盘一遍，差异复盘就失去意义了。
      await expectLater(
          repo.openOrCreateNode(no, SimplePhase.second), throwsA(isA<StateError>()));
      await expectLater(
          repo.openOrCreateNode(no, SimplePhase.third), throwsA(isA<StateError>()));
    });

    test('归档的一轮不再开新趟', () async {
      final a = await openRound(n: 1);
      await openRound(n: 1); // 把 a 归档
      await expectLater(
          repo.openOrCreateNode(a, SimplePhase.first), throwsA(isA<StateError>()));
    });

    test('完成本趟 → 锁死；撤销 → 能继续扫', () async {
      final no = await openRound();
      final n = await repo.openOrCreateNode(no, SimplePhase.first);
      final nno = n['sheet_no'] as String;
      // ⚠️ 用 rows(2)：下面要取第 2 个条码。早先这里写的是 rows(1)[1]，
      //    长度 1 的列表取下标 1 —— 直接 RangeError，看着像产品坏了。
      final two = rows(2);
      await repo.scan(nno, two[0].barcode);
      await repo.submitNode(nno);
      expect((await repo.findNode(nno))!['status'], InvSheetStatus.submitted);
      // 锁死之后扫码被拒（不是"判定了但照写"）
      final r = await repo.scan(nno, two[1].barcode);
      expect(r.accepted, isFalse);
      expect(r.decision.verdict, SimpleScanVerdict.sheetLocked);
      await repo.reopenNode(nno);
      expect((await repo.findNode(nno))!['status'], InvSheetStatus.open);
      expect((await repo.scan(nno, two[1].barcode)).accepted, isTrue);
    });
  });

  // ============================================================
  group('扫码', () {
    test('🔴 同一趟里同码再扫 = 累加（不是被拒、也不是插第二行）', () async {
      final no = await openRound();
      final nno = (await repo.openOrCreateNode(no, SimplePhase.first))['sheet_no']
          as String;
      final code = rows(1).first.barcode;

      final r1 = await repo.scan(nno, code);
      expect(r1.accepted, isTrue);
      expect(r1.newQty, 1.0);

      final r2 = await repo.scan(nno, code);
      expect(r2.accepted, isTrue, reason: '同码再扫必须放行');
      expect(r2.rowId, r1.rowId, reason: '累加在同一行上，不该多出一行');
      expect(r2.newQty, 2.0);

      final list = await repo.listNodeRows(nno);
      expect(list.length, 1, reason: '一个条码一行');
      expect((list.first['qty'] as num).toDouble(), 2.0);
      expect((await repo.nodeQtyMap(nno))[code], 2.0);
    });

    test('扫第二遍不占用条数上限（否则扫第 500 个商品的第二件会被拒）', () async {
      await LocalDb.I.resetForTest();
      final small = SimpleRepo(maxRows: 2);
      final t = await small.startNewRound(
          scene: SimpleScene.store, rows: rows(3));
      final no = (t['task_no'] ?? '').toString();
      final nno = (await small.openOrCreateNode(no, SimplePhase.first))['sheet_no']
          as String;
      final list = rows(3);

      expect((await small.scan(nno, list[0].barcode)).accepted, isTrue);
      expect((await small.scan(nno, list[1].barcode)).accepted, isTrue);
      // 满了两行：**再扫已扫过的那个**要放行（累加不算新行）
      expect((await small.scan(nno, list[0].barcode)).accepted, isTrue,
          reason: '同码累加不受上限限制');
      // 新的条码才被上限拦
      final r = await small.scan(nno, list[2].barcode);
      expect(r.accepted, isFalse);
      expect(r.decision.verdict, SimpleScanVerdict.phaseLimit);
      // 🔴 被拒的那条**一行都不许写进去**
      expect((await small.listNodeRows(nno)).length, 2);
    });

    test('🔴 清单外的商品放行，并挂黄条提醒（口径：不拦，导出作第三段）', () async {
      final no = await openRound(n: 2);
      final nno = (await repo.openOrCreateNode(no, SimplePhase.first))['sheet_no']
          as String;
      final r = await repo.scan(nno, '9999999999999');
      expect(r.accepted, isTrue, reason: '清单外必须放行 —— 拦了现场就没法干活');
      expect(r.decision.verdict, SimpleScanVerdict.okOffList);
      expect(r.decision.warned, isTrue);
      expect((r.decision.message ?? ''), isNotEmpty);
    });

    test('🔴 清单外的行必须在明细里**看得见**（LEFT JOIN 不能写成 INNER）', () async {
      final no = await openRound(n: 2);
      final nno = (await repo.openOrCreateNode(no, SimplePhase.first))['sheet_no']
          as String;
      await repo.scan(nno, '9999999999999');
      final list = await repo.listNodeRows(nno);
      expect(list.length, 1, reason: '清单外的商品整行都不许消失');
      expect(list.first['name'], isNull, reason: '导入清单里没有它，所以没名字');
    });

    test('数量必须大于 0；<=0 抛错（要撤就删行）', () async {
      final no = await openRound();
      final nno = (await repo.openOrCreateNode(no, SimplePhase.first))['sheet_no']
          as String;
      await expectLater(repo.scan(nno, '123', qty: 0),
          throwsA(isA<ArgumentError>()));
      await expectLater(repo.scan(nno, '123', qty: -1),
          throwsA(isA<ArgumentError>()));
    });

    test('扫不存在的趟次 → 抛错（不是静默记账）', () async {
      await expectLater(
          repo.scan('SMP-nope-01', '123'), throwsA(isA<StateError>()));
    });

    test('改数量 / 删行', () async {
      final no = await openRound();
      final nno = (await repo.openOrCreateNode(no, SimplePhase.first))['sheet_no']
          as String;
      final r = await repo.scan(nno, rows(1).first.barcode);
      await repo.setQty(r.rowId!, 7);
      expect((await repo.listNodeRows(nno)).first['qty'], 7.0);
      await repo.deleteRow(r.rowId!);
      expect((await repo.listNodeRows(nno)), isEmpty);
    });
  });

  // ============================================================
  group('账', () {
    test('taskTally：清单内 / 清单外分开数（"已盘 N / M" 不能被清单外撑大）', () async {
      final no = await openRound(n: 5);
      final nno = (await repo.openOrCreateNode(no, SimplePhase.first))['sheet_no']
          as String;
      final list = rows(5);
      await repo.scan(nno, list[0].barcode);
      await repo.scan(nno, list[0].barcode); // 同码累加，仍算 1 个品
      await repo.scan(nno, list[1].barcode);
      await repo.scan(nno, '9999999999999'); // 清单外

      final t = await repo.taskTally(no);
      expect(t.totalItems, 5);
      expect(t.scannedInList, 2, reason: '同码累加只算一个品种');
      expect(t.scannedOffList, 1);
      expect(t.progressText, '已盘 2 / 5 个品');
      expect(t.allDone, isFalse);
    });

    test('nodeTally：行数与清单外品种数', () async {
      final no = await openRound(n: 2);
      final nno = (await repo.openOrCreateNode(no, SimplePhase.first))['sheet_no']
          as String;
      final list = rows(2);
      await repo.scan(nno, list[0].barcode);
      await repo.scan(nno, '9999999999999');
      final n = await repo.nodeTally(nno);
      expect(n.rows, 2);
      expect(n.offList, 1);
    });

    test('listTasks 带出"已盘 / 共多少"（历史面板要显示）', () async {
      final no = await openRound(n: 4);
      final nno = (await repo.openOrCreateNode(no, SimplePhase.first))['sheet_no']
          as String;
      await repo.scan(nno, rows(4).first.barcode);
      final t = (await repo.listTasks()).firstWhere((x) => x['task_no'] == no);
      expect(t['items'], 4);
      expect(t['scanned'], 1);
      expect(t['scene'], SimpleScene.store);
    });
  });

  // ============================================================
  group('清数据：绝不许波及其它通道', () {
    /// 造一张盘点单 + 一笔流水，和一张减货单 + 一笔流水。
    Future<void> seedOthers() async {
      final db = await LocalDb.I.db();
      final now = DateTime.now().millisecondsSinceEpoch;
      await db.insert('stocktake_sheet', {
        'sheet_no': 'INV-Z01-1-20260921080000',
        'zone_code': 'Z01',
        'phase': 1,
        'status': 0,
        'started_at': now,
        'sheet_type': InvSheetType.stocktake,
      });
      await db.insert('scan_record', {
        'sheet_no': 'INV-Z01-1-20260921080000',
        'barcode': '6900000000001',
        'qty': 9.0,
        'scanned_at': now,
        'uploaded': 0,
        'phase': 1,
      });
      await db.insert('stocktake_sheet', {
        'sheet_no': 'JH-20260921090000',
        'zone_code': null,
        'phase': 1,
        'status': 0,
        'started_at': now,
        'sheet_type': InvSheetType.deduct,
      });
      await db.insert('scan_record', {
        'sheet_no': 'JH-20260921090000',
        'barcode': '6900000000002',
        'qty': 3.0,
        'scanned_at': now,
        'uploaded': 0,
        'phase': 1,
      });
    }

    test('🔴 清简易盘点：盘点单与减货单**一行都不许少**', () async {
      await seedOthers();
      final no = await openRound(n: 3);
      final nno = (await repo.openOrCreateNode(no, SimplePhase.first))['sheet_no']
          as String;
      await repo.scan(nno, rows(3).first.barcode);

      final r = await repo.clearAll();
      expect(r['tasks'], 1);
      expect(r['nodes'], 1);
      expect(r['rows'], 1);

      // 简易盘点自己的都没了
      expect(await repo.findTask(no), isNull);
      // ⚠️ 这里**不能**写 `expect(await repo.listNodes(no), isEmpty)` 来表达"没了"：
      //    任务都没了，"读它的内容"按本轮定的口径是要**抛错**的
      //    （返回空列表会和"还没开趟次 / 还没导清单"分不清，正是要消掉的静默）。
      //    要验"真没了"就看**库里**还有没有残留 —— 也就是下面那段 DB 断言。
      await expectLater(repo.listNodes(no), throwsA(isA<StateError>()));
      await expectLater(repo.listItems(no), throwsA(isA<StateError>()));

      // 别人的还在（这条是这个测试存在的理由）
      final db = await LocalDb.I.db();
      final sheets = await db.query('stocktake_sheet');
      final nos = sheets.map((s) => s['sheet_no'].toString()).toSet();
      expect(nos.contains('INV-Z01-1-20260921080000'), isTrue,
          reason: '盘点单头被清掉了 —— 这个 bug 在减货那一版真发生过');
      expect(nos.contains('JH-20260921090000'), isTrue,
          reason: '减货单头被清掉了');
      final recs = await db.query('scan_record');
      final rnos = recs.map((s) => s['sheet_no'].toString()).toSet();
      expect(rnos.contains('INV-Z01-1-20260921080000'), isTrue);
      expect(rnos.contains('JH-20260921090000'), isTrue);
    });

    test('清单也一起清掉', () async {
      final no = await openRound(n: 3);
      await repo.clearAll();
      final db = await LocalDb.I.db();
      expect(await db.query('simple_item'), isEmpty);
      expect(await db.query('simple_task'), isEmpty);
      // "读出来是空的"**不算**"清掉了"的判据（任务都没了，读它本来就该抛错）；
      // 上面两条直接数库里的行数才是判据。这条只是顺带把新口径钉住。
      await expectLater(repo.listItems(no), throwsA(isA<StateError>()));
    });

    test('清完还能正常开新一轮（不留半截状态）', () async {
      await openRound(n: 2);
      await repo.clearAll();
      final t = await repo.startNewRound(scene: SimpleScene.store, rows: rows(2));
      expect(t['status'], SimpleRepo.taskOpen);
      expect((await repo.listItems(t['task_no'] as String)).length, 2);
    });
  });
}
