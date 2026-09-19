import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xiaozhi_im_client/core/local_db.dart';
import 'package:xiaozhi_im_client/core/stocktake_repo.dart';
import 'package:xiaozhi_im_client/screens/stocktake.dart';

/// 扫码枪（采集页）的 widget 测试。
///
/// ── 这个测试是为一次真实事故补的 ────────────────────────────────
/// 采集页的「明细列表表头」和「底部导出栏」原先都挂在 `_rows.isNotEmpty` 上 ——
/// 没扫过码就**整页看不到**。现场反馈是"这功能没做"，因为扫之前确实什么都看不见。
/// **代码写了不等于用户看得见**，所以这里专门盯"空列表"这一帧。
///
/// 钉住的四条：
///   ① 标题是「扫码枪」，且页面里不再出现「盘点」（名字让给盘点模块）
///   ② 没有任何扫码记录时，四列表头仍然在（序号/条码/数量/商品名称）
///   ③ 没有任何扫码记录时，底部两个导出按钮仍然在（导出文档/导出表格）
///   ④ 有数据时：重复扫同一个码**合并成一行、数量加 1**；商档查不到的码显示
///      预留值「未知条码」；每行行尾都有删除按钮，点了只删这一行
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
  final supportDir = '${Directory.systemTemp.path}/xz_stocktake_page_test';
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(pathChannel, (call) async {
    if (call.method == 'getApplicationSupportDirectory') return supportDir;
    return null;
  });

  const sheet = 'PD20260919130000';

  /// ⚠️ widget 测试跑在**假时钟**里，而 SQLite 走 isolate、是真实异步 ——
  ///    假时钟不会把它推进去。所以"造数据"和"等页面读完库"都必须放进
  ///    `tester.runAsync`，否则页面永远停在转圈那一帧，
  ///    表现为"什么都找不到"，很容易被误判成界面写错了。
  ///
  /// 这里不用"固定睡 50ms"这种写法：机器快慢不同，睡少了就是随机失败。
  /// 改成**循环到转圈消失**为止，并在没消失时报红（不静默通过）。
  Future<void> settle(WidgetTester tester, {int tries = 40}) async {
    for (var i = 0; i < tries; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
      if (find.byType(CircularProgressIndicator).evaluate().isEmpty) return;
    }
    fail('页面一直停在 loading：DB 初始化没有在预期次数内完成');
  }

  Future<void> pumpPage(WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: StocktakePage()));
    await tester.pump(); // 第一帧：loading
    await settle(tester);
  }

  /// 造一张"2 件 A + 1 个商档里没有的码"的扫码单。
  /// `_boot` 会挑最近一张单接着扫，所以页面一进来就落在 [sheet] 上。
  Future<void> seedScans() async {
    await LocalDb.I.resetForTest();
    final db = await LocalDb.I.db();
    await db.insert('stock_master', <String, Object?>{
      'barcode': 'A',
      'name': '矿泉水',
      'spec': '550ml',
      'unit': '瓶',
      'unit_price': 5,
      'account_qty': 10,
    });
    final repo = StocktakeRepo();
    await repo.addScan(sheet, 'A'); // 第 1 件
    await repo.addScan(sheet, 'A'); // 第 2 件 → 必须并进上一行
    await repo.addScan(sheet, 'ZZZ'); // 商档里没有 → 用预留值
  }

  Future<void> resetEmpty() async {
    await LocalDb.I.resetForTest();
    await LocalDb.I.db();
  }

  // ── ①②③ 空列表：能力必须一眼可见 ─────────────────────────────
  testWidgets('空列表时：标题「扫码枪」、四列表头、两个导出按钮都在', (tester) async {
    await tester.runAsync(resetEmpty);
    await pumpPage(tester);

    expect(find.text('扫码枪'), findsWidgets, reason: '标题应为「扫码枪」');

    // 🔴 本条是这次回归的核心：一个扫码记录都没有时，列表结构也得画出来
    for (final h in ['序号', '条码', '数量', '商品名称']) {
      expect(find.text(h), findsOneWidget, reason: '空列表也必须显示列头「$h」');
    }

    // 🔴 同理：底部导出能力不能"扫完才长出来"
    expect(find.text('导出文档'), findsOneWidget, reason: '空列表也必须看得到导出文档');
    expect(find.text('导出表格'), findsOneWidget, reason: '空列表也必须看得到导出表格');

    expect(find.textContaining('还没有扫码记录'), findsOneWidget);
    // 「盘点」这个名字已经让给盘点模块，这一页不该再出现
    expect(find.textContaining('盘点'), findsNothing);
  });

  // ── ④ 有数据：合并加一 / 预留值 / 行尾删除 ────────────────────
  testWidgets('重复扫同一个码合并成一行、数量加 1；未知码显示预留值；行尾能删', (tester) async {
    await tester.runAsync(seedScans);
    await pumpPage(tester);

    // 两个条码 = 两行，扫了两次的 A 不能变成两行
    expect(find.byTooltip('删除本行'), findsNWidgets(2),
        reason: '每行最后面都要有一个删除按钮');

    // A：名称来自商档；数量必须是 2（扫了两次并进一行）
    expect(find.text('A'), findsOneWidget, reason: '同一个码扫两次必须合并成一行');
    expect(find.text('矿泉水'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('scan-qty-A')),
        matching: find.text('2'),
      ),
      findsOneWidget,
      reason: '同一码扫两次 → 数量加 1 变成 2',
    );

    // ZZZ：商档里没有 → 预留值
    expect(find.text('未知条码'), findsOneWidget, reason: '商档查不到的名称要用预留值');

    // 删掉 ZZZ 那一行
    await tester.runAsync(() async {
      await tester.tap(find.descendant(
        of: find.byKey(const ValueKey<String>('scan-row-ZZZ')),
        matching: find.byTooltip('删除本行'),
      ));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();

    expect(find.text('未知条码'), findsNothing, reason: '删除后该行应消失');
    expect(find.text('矿泉水'), findsOneWidget, reason: '别的行不能被误删');
    expect(find.byTooltip('删除本行'), findsOneWidget);
  });
}
