import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xiaozhi_im_client/core/local_db.dart';
import 'package:xiaozhi_im_client/core/stocktake_repo.dart';
import 'package:xiaozhi_im_client/screens/stocktake_result.dart';

/// 扫码盈亏页的 widget 测试。
///
/// 这一页的价值全在"数算得对不对、有没有显示在屏幕上"，
/// 光看代码存在说明不了任何事，所以这里真跑一遍：
/// 造一张"1 盈 1 亏 1 无账面"的单，把界面拉起来，逐条对数字。
///
/// 三条容易写错、且**错了不报错**的口径，都由这个测试钉着：
///   · 盘盈/盘亏金额都显示正数（亏 15 不能显示成 -15，跟盈放一起会看反）；
///   · 净额才带符号（10 - 15 = -5）；
///   · 账面缺失的行进"无账面"计数，不混进盈亏。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
  final supportDir = '${Directory.systemTemp.path}/xz_stocktake_result_test';
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(pathChannel, (call) async {
    if (call.method == 'getApplicationSupportDirectory') return supportDir;
    return null;
  });

  const sheet = 'PD20260919220000';

  /// 造一张"1 盈 1 亏 1 无账面"的单。
  Future<void> seed() async {
    await LocalDb.I.resetForTest();
    final db = await LocalDb.I.db();
    final repo = StocktakeRepo();

    // 商档：两个有账面的、一个故意不建档（模拟没同步到的条码）
    await db.insert('stock_master', <String, Object?>{
      'barcode': 'A',
      'name': '矿泉水',
      'spec': '550ml',
      'unit': '瓶',
      'unit_price': 5,
      'account_qty': 10,
    });
    await db.insert('stock_master', <String, Object?>{
      'barcode': 'B',
      'name': '可乐',
      'spec': '330ml',
      'unit': '瓶',
      'unit_price': 5,
      'account_qty': 10,
    });

    await repo.addScan(sheet, 'A', qty: 12); // 盈 2 → +¥10
    await repo.addScan(sheet, 'B', qty: 7); // 亏 3 → -¥15
    await repo.addScan(sheet, 'ZZZ'); // 商档里没有 → 无账面
  }

  /// ⚠️ widget 测试跑在**假时钟**里，而 SQLite 走 isolate，是真实异步 ——
  ///    假时钟不会把它推进去，所以造数据和等页面读库都必须放进
  ///    `tester.runAsync`，否则页面会永远停在转圈那一帧（表现为
  ///    "找不到任何文字"，很容易被误判成界面写错了）。
  Future<void> pumpPage(WidgetTester tester, {bool withData = true}) async {
    await tester.runAsync(seed);
    await tester.pumpWidget(
        const MaterialApp(home: StocktakeResultPage(sheetNo: sheet)));
    await tester.pump(); // 第一帧：loading
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump(); // 数据到，重绘
  }

  Future<void> pumpEmpty(WidgetTester tester) async {
    await tester.runAsync(seed);
    await tester.pumpWidget(
        const MaterialApp(home: StocktakeResultPage(sheetNo: 'PD_EMPTY')));
    await tester.pump();
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
  }

  testWidgets('盈亏数字算对并显示在屏幕上', (WidgetTester tester) async {
    await pumpPage(tester);

    expect(find.text('实盘品种'), findsOneWidget);
    expect(find.text('3'), findsWidgets); // 3 个品种

    // 盘盈 1 种 ¥10.00 / 盘亏 1 种 ¥15.00 —— 金额都是正数
    expect(find.text('盘盈 1 种'), findsOneWidget);
    expect(find.text('¥10.00'), findsOneWidget);
    expect(find.text('盘亏 1 种'), findsOneWidget);
    expect(find.text('¥15.00'), findsOneWidget);

    // 净额才带符号：10 - 15 = -5
    expect(find.text('净差异 -¥5.00'), findsOneWidget);

    // 无账面单独提示，不混进盈亏
    expect(find.text('1 个无账面'), findsOneWidget);
    expect(find.text('1 个未知码'), findsOneWidget);
  });

  testWidgets('筛选条能切到"只看盘亏"，并且不该出现的行要消失',
      (WidgetTester tester) async {
    await pumpPage(tester);

    expect(find.text('矿泉水'), findsOneWidget);
    expect(find.text('可乐'), findsOneWidget);
    expect(find.text('未知条码 ZZZ'), findsOneWidget);

    await tester.tap(find.byKey(const Key('stocktake_filter_2'))); // 盘亏
    await tester.pump();

    expect(find.text('可乐'), findsOneWidget);
    expect(find.text('矿泉水'), findsNothing);
    expect(find.text('未知条码 ZZZ'), findsNothing);
  });

  testWidgets('切到"无账面"只看得到档案里查不到的码', (WidgetTester tester) async {
    await pumpPage(tester);

    // ⚠️ "无账面" 在界面上出现两次（筛选条 + 行尾标记），按文字找会撞车，
    //    所以筛选条都带固定 key（stocktake_filter_<序号>）。
    await tester.tap(find.byKey(const Key('stocktake_filter_4'))); // 无账面
    await tester.pump();

    expect(find.text('未知条码 ZZZ'), findsOneWidget);
    expect(find.text('矿泉水'), findsNothing);
    expect(find.text('可乐'), findsNothing);
  });

  testWidgets('空单不炸，给回去扫码的出口', (WidgetTester tester) async {
    await pumpEmpty(tester);

    expect(find.text('这张扫码单还没有扫码记录'), findsOneWidget);
    expect(find.text('回去扫码'), findsOneWidget);
  });
}
