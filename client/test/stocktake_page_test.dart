import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xiaozhi_im_client/core/local_db.dart';
import 'package:xiaozhi_im_client/core/stocktake_repo.dart';
import 'package:xiaozhi_im_client/screens/stocktake.dart';

/// 扫码枪（采集页）的 widget 测试。
///
/// ── 这个测试是为两次真实反馈补的 ────────────────────────────────
/// ① 2026-09-19 上午：「没有扫码列表和导出」——
///    表头和导出栏原先挂在 `_rows.isNotEmpty` 上，没扫过码就**整页看不见**。
///    现场反馈是"这功能没做"，因为扫之前确实什么都看不见。
///    **代码写了不等于用户看得见**，所以专门盯"空列表"这一帧。
/// ② 2026-09-19 下午：「数量栏不能改」「导出只能先存本地再发送」——
///    前者是 `setQty()` 早就写好了、界面没接上；后者是导出后只给
///    "打开 / 另存为"，没有直接把文件交给分享面板。两条都补了测试。
///
/// 钉住的：
///   ① 标题是「扫码枪」，且页面里不再出现「盘点」（名字让给盘点模块）
///   ② 没有任何扫码记录时，四列表头仍然在（序号/条码/数量/商品名称）
///   ③ 没有任何扫码记录时，底部两个导出按钮仍然在（导出文档/导出表格）
///   ④ 重复扫同一个码**合并成一行、数量加 1**；未知码用预留值；行尾能删
///   ⑤ **数量可以点开改**（改大 / 改成 0 = 二次确认后删行 / 取消则不动）
///   ⑥ 导出后弹层里**这条"把文件发出去"的路与当前平台匹配**
///      （Android/iOS=分享面板 / Windows=打开文件夹 / 其它平台=一条都不给）
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
  /// 改成**轮询到条件成立**，并在等不到时报红（不静默通过）。
  Future<void> pumpUntil(
    WidgetTester tester,
    bool Function() ok, {
    int tries = 80,
    required String why,
  }) async {
    for (var i = 0; i < tries; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
      if (ok()) return;
    }
    fail('等待超时：$why');
  }

  /// 有界地推进动画。
  ///
  /// 🔴 **不要用裸 `pumpAndSettle()`**：它只在"没有待调度帧"时才返回，
  ///    页面上只要有一个永不停歇的动画（转圈就是），它会一直等到 **10 分钟**
  ///    默认超时才报错 —— 现象是"测试卡死"，而且看不出卡在哪一步。
  ///    （这一版实测就卡在这儿：单独跑一个文件跑了 4 分钟没结束。）
  ///    改成固定推 N 帧：跑得快，超了也是立刻继续，不会把整轮 CI 挂住。
  Future<void> settleAnim(WidgetTester tester, {int frames = 12}) async {
    for (var i = 0; i < frames; i++) {
      await tester.pump(const Duration(milliseconds: 40));
    }
  }

  /// 等到页面不再转圈（DB 初始化完成）
  Future<void> settle(WidgetTester tester) => pumpUntil(
        tester,
        () => find.byType(CircularProgressIndicator).evaluate().isEmpty,
        why: '页面一直停在 loading：DB 初始化没有在预期次数内完成',
      );

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

  /// 点某一行数量胶囊 → 等「改数量」对话框弹出来
  Future<void> openQtyDialog(WidgetTester tester, String barcode) async {
    await tester.tap(find.byKey(ValueKey<String>('scan-qty-$barcode')));
    await tester.pump();
    await pumpUntil(tester, () => find.text('改数量').evaluate().isNotEmpty,
        why: '点数量应该弹出「改数量」对话框');
  }

  /// 在对话框里输一个新数量并点保存。
  ///
  /// 输入框**没有** controller 归测试持有（见 `_QtyDialog` 的注释：
  /// 控制器由对话框自己管理，提前 dispose 会炸），所以这里只能
  /// 通过 `enterText` 驱动。
  Future<void> typeQty(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(TextField).last, text);
    await tester.pump();
    await tester.tap(find.text('保存'));
    await tester.pump();
    // 等「改数量」真正退场（退场动画跑完路由才被移除）。
    // 不先等它走，后面 find.text('取消') 会同时匹配到两个对话框上的按钮。
    await pumpUntil(tester, () => find.text('改数量').evaluate().isEmpty,
        why: '点了保存，「改数量」对话框应该关闭');
  }

  // ── ①②③ 空列表：能力必须一眼可见 ─────────────────────────────
  testWidgets('空列表时：标题「扫码枪」、四列表头、两个导出按钮都在', (tester) async {
    await tester.runAsync(resetEmpty);
    await pumpPage(tester);

    expect(find.text('扫码枪'), findsWidgets, reason: '标题应为「扫码枪」');

    // 🔴 本条是回归①的核心：一个扫码记录都没有时，列表结构也得画出来
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
    await tester.tap(find.descendant(
      of: find.byKey(const ValueKey<String>('scan-row-ZZZ')),
      matching: find.byTooltip('删除本行'),
    ));
    await pumpUntil(tester, () => find.text('未知条码').evaluate().isEmpty,
        why: '点了行尾删除，那一行应该消失');

    expect(find.text('矿泉水'), findsOneWidget, reason: '别的行不能被误删');
    expect(find.byTooltip('删除本行'), findsOneWidget);
  });

  // ── ⑤ 数量可改（2026-09-19 下午反馈）─────────────────────────
  group('数量栏可以改', () {
    testWidgets('点数量 → 改大 → 列表和数据库都跟着变', (tester) async {
      await tester.runAsync(seedScans);
      await pumpPage(tester);

      await openQtyDialog(tester, 'A');
      await typeQty(tester, '12');

      await pumpUntil(
        tester,
        () => find
            .descendant(
              of: find.byKey(const ValueKey<String>('scan-qty-A')),
              matching: find.text('12'),
            )
            .evaluate()
            .isNotEmpty,
        why: '改成 12 之后列表里那一格应该显示 12',
      );

      // 不只界面变了，库里也得真变了 —— 否则重启 App 又变回去
      final rows = await tester.runAsync(
          () => StocktakeRepo().listWithMaster(sheet));
      final a = rows!.firstWhere((r) => r['barcode'] == 'A');
      expect((a['qty'] as num).toDouble(), 12,
          reason: '改数量必须落到本地库，不能只是界面上好看');
    });

    testWidgets('改成 0 要二次确认，确认后才删行', (tester) async {
      await tester.runAsync(seedScans);
      await pumpPage(tester);

      await openQtyDialog(tester, 'A');
      await typeQty(tester, '0');
      await settleAnim(tester);

      // 手滑多按一个 0 就静默删行，是员工第二天才发现的那种错 → 必须再问一次
      expect(find.text('改成 0 = 删掉这一行'), findsOneWidget,
          reason: '改成 0 会删数据，必须先确认');

      await tester.tap(find.text('删除'));
      await pumpUntil(tester, () => find.text('矿泉水').evaluate().isEmpty,
          why: '确认后 A 那一行应被删掉');

      expect(find.text('未知条码'), findsOneWidget, reason: '别的行不能被连带删掉');
    });

    testWidgets('取消二次确认 → 什么都不改', (tester) async {
      await tester.runAsync(seedScans);
      await pumpPage(tester);

      await openQtyDialog(tester, 'A');
      await typeQty(tester, '0');
      await settleAnim(tester);

      expect(find.text('改成 0 = 删掉这一行'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await settleAnim(tester);

      expect(find.text('矿泉水'), findsOneWidget, reason: '取消就不该删行');

      final rows = await tester.runAsync(
          () => StocktakeRepo().listWithMaster(sheet));
      final a = rows!.firstWhere((r) => r['barcode'] == 'A');
      expect((a['qty'] as num).toDouble(), 2, reason: '取消后数量必须还是原来的 2');
    });
  });

  // ── ⑥ 导出后能直接发出去（2026-09-19 下午反馈）──────────────
  //
  // 🔴 2026-09-25 修：老写法只判了「Windows ? 文件夹 : 手机分享」两个分支，
  //    而 CI 跑在 **Linux**（`subosito/flutter-action` 的 ubuntu runner）——
  //    Linux 既不是手机也不是 Windows，`FileShare.channel` 真值是 `none`，
  //    弹层里一条都不渲染，期望值却落在"手机那条"上 → 必然超时。
  //    （现象：`等待超时：导出之后应弹出"发给同事 / 打开文件夹"的弹层`，
  //      546 passed / 1 failed，整轮 CI 就是这个红。）
  //    App 只投放 Android / iOS / Windows，第三个分支代表本平台**故意不给**，
  //    要当成**反向判据**验（多一条才是错），不能当成"跳过"。
  testWidgets('导出后弹层里的"发出去"那条路与当前平台匹配（本平台没有就要真没有）',
      (tester) async {
    await tester.runAsync(seedScans);
    await pumpPage(tester);

    await tester.tap(find.text('导出文档'));

    // 导出会真写文件（真实 IO），假时钟推不动，必须让出真实异步。
    //
    // ⚠️ 等的判据用「已生成 N 行」—— 那是弹层的第一行，**任何平台都有**。
    //    不要等 `share-to-others`：本平台没有那条路时它本来就不该出现，
    //    等它 = 把"正确行为"等成超时，正是这一版红掉的原因。
    await pumpUntil(
      tester,
      () => find.textContaining('已生成').evaluate().isNotEmpty,
      why: '导出之后应弹出操作面板',
    );

    // 🔴 这一条是独立判据，不复用 FileShare.channelFor —— 复用就成了
    //    "实现自己验自己"。直接按平台写死期望值，写反分支必然报红。
    //    三个分支**必须写全**：少写一个，那个平台就会静默按错的期望走。
    final String? want;
    if (Platform.isAndroid || Platform.isIOS) {
      want = '发给同事（微信 / 企微 / 钉钉…）';
    } else if (Platform.isWindows) {
      want = '打开所在文件夹（拖进微信发送）';
    } else {
      want = null; // CI 的 Linux 等：App 不投放，本来就不该有这一条
    }

    if (want == null) {
      expect(find.byKey(const Key('share-to-others')), findsNothing,
          reason: '${Platform.operatingSystem} 上没有可用的分享通道，'
              '弹层里就不该摆这一条 —— 摆了就是"点了没反应"的假按钮');
    } else {
      expect(
        find.descendant(
          of: find.byKey(const Key('share-to-others')),
          matching: find.text(want),
        ),
        findsOneWidget,
        reason: '弹层第一条必须是这台设备真能走的那条路',
      );
    }

    // 打开 / 另存为 仍然要在（发不出去时的兜底不能丢）
    expect(find.text('打开（用 WPS / Excel / 记事本看）'), findsOneWidget);
    expect(find.text('另存为 / 发到别处'), findsOneWidget);

    // 点弹层外面关掉它。**不去点"先不用"**：选项一多它就落到屏幕外了，
    // 那种 tap 会静默打偏（只留一句 warning），是最难查的假失败。
    await tester.tapAt(const Offset(10, 10));
    await settleAnim(tester);

    // 🔴 文件检查必须放进 `runAsync`。
    //    `File.exists()` / `readAsString()` 是**真实文件 IO**，而测试体跑在
    //    假时钟里 —— 直接在测试体里 await 一个真实 IO，它**永远不会完成**，
    //    表现为"整轮测试无声卡死"（实测卡了 4 分钟直到被外部 timeout 杀掉，
    //    日志里连一句异常都没有，最难查的那种）。
    //    造数据、读库、读写文件，凡是真的 IO 都要走 runAsync。
    final content = await tester.runAsync(() async {
      final f = File('$supportDir/downloads/扫码明细_$sheet.txt');
      if (!await f.exists()) return null;
      return f.readAsString();
    });

    expect(content, isNotNull,
        reason: '导出的文件必须真的写出来：$supportDir/downloads/扫码明细_$sheet.txt');
    expect(content, contains('矿泉水'), reason: '导出内容里应该真有扫到的商品');
  });
}
