import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xiaozhi_im_client/core/local_db.dart';
import 'package:xiaozhi_im_client/core/simple_repo.dart';
import 'package:xiaozhi_im_client/core/simple_rules.dart';
import 'package:xiaozhi_im_client/core/simple_scan_sink.dart';

/// 「简易盘点」摄像头扫码适配层的测试。
///
/// 相机机制本身（去重/冷却/闪绿）在 CameraScanPage 与 scan_dedup 里钉过；
/// 这一层只有一个职责：**把扫到的码交给 SimpleRepo.scan，别走私第二条路**。
/// 钉的是：
///   · record 走的就是手输同一个入口 —— 同码累加、清单外放行都成立；
///   · 差异复盘的 allowedBarcodes 会被真的带下去（构造时传了就必须拦）；
///   · 被拒的扫码 accepted=false 且不落库（不能闪绿）；
///   · summary / recent 的字段口径（相机页底部信息区靠它显示）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
  final supportDir = '${Directory.systemTemp.path}/xz_simple_sink_test';
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

  List<SimpleImportRow> rows(int n) => List<SimpleImportRow>.generate(
        n,
        (i) => SimpleImportRow(
          barcode: '6901234${(567890 + i).toString().padLeft(6, '0')}',
          name: '商品$i',
          spec: '',
          seq: i + 1,
        ),
      );

  /// 开一轮 + 开初盘趟，返回 (taskNo, nodeNo)。
  Future<(String, String)> openFirstNode({int n = 3}) async {
    final t = await repo.startNewRound(scene: SimpleScene.store, rows: rows(n));
    final taskNo = (t['task_no'] ?? '').toString();
    final node = await repo.openOrCreateNode(taskNo, SimplePhase.first);
    return (taskNo, (node['sheet_no'] ?? '').toString());
  }

  group('SimpleScanSink', () {
    test('record 与手输同一个入口：入账 + 同码再扫累加', () async {
      final (_, nodeNo) = await openFirstNode();
      final sink = SimpleScanSink(repo);
      final b0 = rows(1).first.barcode;

      final r1 = await sink.record(nodeNo, b0);
      expect(r1.accepted, isTrue);
      expect(r1.hit, isNotNull);
      expect(r1.hit!['barcode'], b0);
      expect(r1.hit!['qty'], 1);

      // 同码再扫 = 累加（和手输同一条规则，不是插第二行）
      final r2 = await sink.record(nodeNo, b0);
      expect(r2.accepted, isTrue);
      expect(r2.hit!['qty'], 2);

      final tally = await repo.nodeTally(nodeNo);
      expect(tally.rows, 1);
      expect(tally.totalQty, 2);
    });

    test('清单外放行（口径不因换了入口而改变）', () async {
      final (_, nodeNo) = await openFirstNode();
      final sink = SimpleScanSink(repo);
      final r = await sink.record(nodeNo, '6900000000009');
      expect(r.accepted, isTrue);
      final tally = await repo.nodeTally(nodeNo);
      expect(tally.offList, 1);
    });

    test('差异复盘的 allowedBarcodes 真的被带下去：不在集合里的被拒不落库', () async {
      // 🔴 场景必须是**真的差异复盘趟**：规则刻意规定"非差异趟不许被
      //    allowedBarcodes 限制"（方案 §2 规矩 4）—— 给初盘传集合是拦不住的，
      //    那是设计不是 bug。所以要老老实实走完初盘/复盘、造出差异、开第三趟。
      final rs = rows(2);
      final t =
          await repo.startNewRound(scene: SimpleScene.store, rows: rows(2));
      final taskNo = (t['task_no'] ?? '').toString();

      // 初盘：A 扫 5 件 → 提交
      final n1 = await repo.openOrCreateNode(taskNo, SimplePhase.first);
      await repo.scan((n1['sheet_no'] ?? '').toString(), rs[0].barcode,
          qty: 5);
      await repo.submitNode((n1['sheet_no'] ?? '').toString());

      // 复盘：A 扫 3 件（造差异）→ 提交
      final n2 = await repo.openOrCreateNode(taskNo, SimplePhase.second);
      await repo.scan((n2['sheet_no'] ?? '').toString(), rs[0].barcode,
          qty: 3);
      await repo.submitNode((n2['sheet_no'] ?? '').toString());

      // 差异集 = {A}；开第三趟
      final diff = await repo.diffSet(taskNo);
      expect(diff, contains(rs[0].barcode));
      final n3 = await repo.openOrCreateNode(taskNo, SimplePhase.third);
      final nodeNo = (n3['sheet_no'] ?? '').toString();

      // 摄像头页拿到的是这个差异集 —— 扫 B（不在集合里）必须被拒
      final sink = SimpleScanSink(repo, allowedBarcodes: diff);
      final rejected = await sink.record(nodeNo, rs[1].barcode);
      expect(rejected.accepted, isFalse,
          reason: '差异复盘里扫非差异品必须被拒');
      expect(rejected.hit, isNull, reason: '被拒的不能带 hit（不能闪绿）');
      expect((await repo.nodeTally(nodeNo)).rows, 0,
          reason: '被拒的扫码一个字节都不能写');

      // 反面：扫差异集里的 A 应该放行（同一入口不改变规则）
      final ok = await sink.record(nodeNo, rs[0].barcode);
      expect(ok.accepted, isTrue);
    });

    test('summary / recent 的口径：kinds=品种数、recent 新的在前', () async {
      final (_, nodeNo) = await openFirstNode();
      final sink = SimpleScanSink(repo);
      final rs = rows(2);
      await sink.record(nodeNo, rs[0].barcode);
      await sink.record(nodeNo, rs[1].barcode);

      final s = await sink.summary(nodeNo);
      expect(s['kinds'], 2);
      expect(s['total_qty'], 2);

      final recent = await sink.recent(nodeNo);
      expect(recent.length, 2);
      expect(recent.first['barcode'], rs[1].barcode,
          reason: '相机页信息区要"刚扫的在最上"');
    });
  });
}
