import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xiaozhi_im_client/core/local_db.dart';
import 'package:xiaozhi_im_client/screens/inventory_collect.dart';

/// 盘点采集页的 widget 测试。
///
/// ── 钉住的是哪几件事 ────────────────────────────────────────────
/// ① 一进来是**初盘**，三段阶段条都在（盘点的全部意义就在"分阶段"）
/// ② 扫码枪敲回车能把条码记进去（现场唯一的主路径）
/// ③ **数量格可以点开改**（上一轮扫码枪就是因为界面没接上，被反馈"不能改"）
/// ④ 改成 0 要先二次确认，取消则一行不动（手滑多按一个 0 就静默删行最阴）
/// ⑤ **抽盘只收"上一轮对不上"的清单**：清单外的商品扫了必须被拒，
///    而且要当场说明原因（不是"什么都没发生"）。复盘反过来**不设限** ——
///    它要是也按清单卡，就等于默认初盘是对的，初盘漏扫的货永远没人补。
/// ⑥ 提交后**本地就锁死**：数量格点不动了
/// ⑦ 两遍都对得上时，抽盘不能是死胡同（否则主管卡在"提交"是灰的那一步）；
///    以及初盘提交后**一定要问**"现在开始复盘？"
/// ⑧ 撤销提交之后**真的能改**（那个锁不是画上去的）
///
/// ── 两个测试基建的坑（都吃过）─────────────────────────────────
/// · widget 测试跑在**假时钟**里，而 SQLite 走 isolate、是真实异步 ——
///   造数据/等页面读完库都必须包 `tester.runAsync`，否则页面永远停在转圈，
///   表现为"什么都找不到"，极容易被误判成界面写错了。
/// · **不要用裸 `pumpAndSettle()`**：撞上转圈会一直等到 10 分钟默认超时，
///   现象是"测试卡死"。改用有界推帧 + 轮询到条件成立。
/// · 🔴 **`tester.pump()` 只推假时钟、不给真实时间** —— SQLite（isolate）
///   的回包永远到不了。所以每次扫码/落库之后**必须**用下面这个带
///   `runAsync` 的轮询去等，光 `pump` 几下会看到"扫了没反应"，
///   而这**不是产品的问题，是测试没给它真实时间**（这一轮踩了两回）。
/// · 同一个 `pumpUntil` 还负责**推进假时钟**：SnackBar 按 4 秒自动消失，
///   不推时长的话上一条提示会一直占着位置，把下一条挤在后面看不见。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
  final supportDir = '${Directory.systemTemp.path}/xz_inventory_page_test';
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(pathChannel, (call) async {
    if (call.method == 'getApplicationSupportDirectory') return supportDir;
    return null;
  });

  Future<void> pumpUntil(
    WidgetTester tester,
    bool Function() ok, {
    int tries = 120,
    required String why,
  }) async {
    for (var i = 0; i < tries; i++) {
      // runAsync：把真实时间借给 SQLite（它走 isolate），否则假时钟下永远等不到回包
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      // 带时长的 pump：同时推进**假时钟**（SnackBar 这类按时间消失的东西才会走完）
      await tester.pump(const Duration(milliseconds: 40));
      if (ok()) return;
    }
    fail('等待超时：$why');
  }

  Future<void> settleAnim(WidgetTester tester, {int frames = 14}) async {
    for (var i = 0; i < frames; i++) {
      await tester.pump(const Duration(milliseconds: 40));
    }
  }

  Future<void> settle(WidgetTester tester) => pumpUntil(
        tester,
        () => find.byType(CircularProgressIndicator).evaluate().isEmpty,
        why: '页面一直停在 loading：DB 初始化没有在预期次数内完成',
      );

  /// 等到**所有 SnackBar 都散掉**。
  ///
  /// 这不是"迁就测试"：底部浮动的 SnackBar 会**压住它上方那块区域的按钮**，
  /// 那几秒里点了没反应 —— 真机上也是这样。所以要点底部区域的按钮之前，
  /// 先等提示散掉既是对的测试写法，也顺手把这条行为记下来。
  /// 排队中的提示得一条条过（一条 4 秒），所以给足次数。
  Future<void> waitSnackClear(WidgetTester tester) => pumpUntil(
        tester,
        () => find.byType(SnackBar).evaluate().isEmpty,
        tries: 300,
        why: 'SnackBar 一直没散（可能一直在排队，说明某处在疯狂弹提示）',
      );

  /// 造一份最小可用的现场：一个点位、一个货架位、两个商品（6901 已绑 A01）。
  Future<void> seed() async {
    await LocalDb.I.resetForTest();
    final db = await LocalDb.I.db();
    await db.insert('stocktake_zone', <String, Object?>{
      'zone_code': 'Z01',
      'zone_name': '生鲜区',
      'locked': 0,
      'created_at': 1,
    });
    await db.insert('location', <String, Object?>{
      'loc_code': 'A01',
      'loc_name': 'A01',
      'zone_code': 'Z01',
      'sort_no': 0,
      'created_at': 1,
    });
    for (final m in <Map<String, Object?>>[
      <String, Object?>{
        'barcode': '6901',
        'name': '矿泉水',
        'spec': '550ml',
        'unit': '瓶',
        'unit_price': 5.0,
        'account_qty': 10.0,
      },
      <String, Object?>{
        'barcode': '6902',
        'name': '方便面',
        'spec': '袋',
        'unit': '袋',
        'unit_price': 3.0,
        'account_qty': 10.0,
      },
    ]) {
      await db.insert('stock_master', <String, Object?>{
        ...m,
        'source': 'tiger',
        'updated_at': 1,
      });
    }
    await db.insert('barcode_location', <String, Object?>{
      'barcode': '6901',
      'loc_code': 'A01',
      'bound_at': 1,
    });
  }

  Future<void> pumpPage(WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: InventoryCollectPage(zoneCode: 'Z01', zoneName: '生鲜区'),
    ));
    await tester.pump();
    await settle(tester);
  }

  /// 走扫码枪那条路：往输入框敲条码 + 回车。
  Future<void> scan(WidgetTester tester, String code) async {
    await tester.enterText(find.byKey(const Key('inv-scan-input')), code);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settleAnim(tester);
  }

  /// 直接查本地库（真 IO，必须 runAsync）。
  Future<List<Map<String, dynamic>>> rowsOf(
    WidgetTester tester,
    String barcode,
  ) async {
    List<Map<String, dynamic>> out = const [];
    await tester.runAsync(() async {
      final db = await LocalDb.I.db();
      out = await db.query('scan_record',
          where: 'barcode = ?', whereArgs: <Object?>[barcode]);
    });
    return out;
  }

  /// 数量格里显示的数字。
  Finder qtyText(String barcode, String text) => find.descendant(
        of: find.byKey(Key('inv-qty-$barcode')),
        matching: find.text(text),
      );

  setUp(() async {
    await seed();
  });

  testWidgets('① 一进来是初盘，三段阶段条都在', (tester) async {
    await pumpPage(tester);

    for (final label in <String>['初盘', '复盘', '抽盘']) {
      expect(find.text(label), findsWidgets, reason: '缺了「$label」这一段');
    }
    // 默认落在初盘：空列表的提示语会点名当前阶段
    expect(find.text('初盘还没扫'), findsOneWidget);
    // 还没扫，提交按钮是灰的（"先扫一件再提交"）
    expect(find.text('先扫一件再提交'), findsOneWidget);
  });

  testWidgets('② 敲条码回车 → 记一行；数字显示为整数不是 1.0', (tester) async {
    await pumpPage(tester);
    await scan(tester, '6901');

    await pumpUntil(
      tester,
      () => find.byKey(const Key('inv-row-6901')).evaluate().isNotEmpty,
      why: '扫了 6901 但列表里没有这一行',
    );

    expect(find.text('矿泉水'), findsOneWidget);
    expect(find.text('1'), findsWidgets, reason: '数量 1 要显示成 1，不是 1.0');
    // 6901 绑在 A01，货架位要跟着显示出来 —— 盘点的意义就在"在哪儿数的"
    expect(find.text('A01'), findsWidgets);
    // 绑过的商品不该报"未绑定"：那条提醒是给档案还没建的商品用的
    expect(find.textContaining('未绑定货架位'), findsNothing,
        reason: '绑过 A01 的商品还提醒"未绑定"，员工会以为绑定没生效');

    // 本地库也真的落了
    final rows = await rowsOf(tester, '6901');
    expect(rows, hasLength(1));
    expect((rows.first['qty'] as num).toDouble(), 1);
    expect(rows.first['phase'], 1, reason: '记到了初盘');
    expect(rows.first['loc_code'], 'A01');
  });

  testWidgets('②b 没绑过货架位的商品：放行 + 提醒，并落到当前选的货架位', (tester) async {
    await pumpPage(tester);
    await scan(tester, '6902'); // 6902 没绑过任何货架位

    await pumpUntil(
      tester,
      () => find.byKey(const Key('inv-row-6902')).evaluate().isNotEmpty,
      why: '没绑过货架位的商品被挡在外面了',
    );
    expect(find.textContaining('未绑定货架位'), findsWidgets,
        reason: '放行了但没提醒 —— 货架位档案就永远补不齐');

    final rows = await rowsOf(tester, '6902');
    expect(rows, hasLength(1),
        reason: '🔴 没绑过就拒绝的话，上线第一天不可能有全店货架位档案，'
            '整个盘点当场没法用 —— 必须放行');
    expect(rows.first['loc_code'], 'A01',
        reason: '要落到当前选中的货架位（点位默认库位），否则这一件"记在哪儿"丢了');
  });

  testWidgets('③ 点数量格能改数量（界面 + 本地库双验证）', (tester) async {
    await pumpPage(tester);
    await scan(tester, '6901');
    await pumpUntil(
      tester,
      () => find.byKey(const Key('inv-qty-6901')).evaluate().isNotEmpty,
      why: '数量格没出现',
    );

    await tester.tap(find.byKey(const Key('inv-qty-6901')));
    await settleAnim(tester);
    expect(find.text('改数量'), findsOneWidget, reason: '点了数量格没弹改数量对话框');

    await tester.enterText(
      find.descendant(
          of: find.byType(AlertDialog), matching: find.byType(TextField)),
      '12',
    );
    await tester.tap(find.text('保存'));
    await settleAnim(tester);

    await pumpUntil(
      tester,
      () => qtyText('6901', '12').evaluate().isNotEmpty,
      why: '改成 12 之后界面上没变成 12',
    );
    final rows = await rowsOf(tester, '6901');
    expect((rows.first['qty'] as num).toDouble(), 12,
        reason: '界面显示 12 但库里没改 —— 这种"看着改了其实没落库"最误事');
  });

  testWidgets('④ 改成 0 要先二次确认；点取消则一行不动', (tester) async {
    await pumpPage(tester);
    await scan(tester, '6901');
    await pumpUntil(
      tester,
      () => find.byKey(const Key('inv-qty-6901')).evaluate().isNotEmpty,
      why: '数量格没出现',
    );

    await tester.tap(find.byKey(const Key('inv-qty-6901')));
    await settleAnim(tester);
    await tester.enterText(
      find.descendant(
          of: find.byType(AlertDialog), matching: find.byType(TextField)),
      '0',
    );
    await tester.tap(find.text('保存'));
    await settleAnim(tester);

    expect(find.text('改成 0 = 删掉这一行'), findsOneWidget,
        reason: '改成 0 直接删了：手滑多按一个 0 就会静默删行，员工第二天才发现');

    await tester.tap(find.text('取消'));
    await settleAnim(tester);

    expect(find.byKey(const Key('inv-row-6901')), findsOneWidget,
        reason: '点了取消却还是把行删了');
    final rows = await rowsOf(tester, '6901');
    expect(rows, hasLength(1));
    expect((rows.first['qty'] as num).toDouble(), 1, reason: '取消之后数量不该变');
    // 负数是直接拒的，不该落到库里
    expect((rows.first['qty'] as num).toDouble() >= 0, isTrue);
  });

  testWidgets('⑤ 抽盘只收上一轮对不上的商品：清单外的扫了必须被拒且说明原因', (tester) async {
    await pumpPage(tester);
    // 初盘扫 6901（实盘 1）
    await scan(tester, '6901');
    await pumpUntil(
      tester,
      () => find.byKey(const Key('inv-row-6901')).evaluate().isNotEmpty,
      why: '初盘那一行没出现',
    );

    // 提交初盘 → 接着复盘
    await waitSnackClear(tester);
    await tester.tap(find.byKey(const Key('inv-submit')));
    await settleAnim(tester);
    await tester.tap(find.text('提交'));
    await pumpUntil(
      tester,
      () => find.text('现在开始复盘？').evaluate().isNotEmpty,
      why: '初盘提交后没问"现在开始复盘？"',
    );
    await tester.tap(find.text('开始复盘'));

    // ⚠️ 等**这一阶段的数据真的读完**，不能用"提醒语出现"当信号 ——
    //    提醒语在 `_phase` 一变就有了，那时候列表里还是**上一个阶段的行**。
    await pumpUntil(
      tester,
      () => find.textContaining('复盘是这一片重新盘一遍').evaluate().isNotEmpty,
      why: '复盘阶段的提示没载进来',
    );
    // 顺带钉住"串台"这件事：切过去的那一刻不能还显示初盘的商品
    expect(find.byKey(const Key('inv-row-6901')), findsNothing,
        reason: '复盘单里混进了初盘的行：新阶段的标题 + 旧阶段的数据，'
            '员工瞥一眼就会以为"复盘已经有这些了"');

    // 复盘把它盘成 2（初盘是 1）→ 6901 成为"上一轮对不上"的疑问项。
    // 🔴 复盘**不设限制**，所以这两枪必须都能进去。
    await scan(tester, '6901');
    await scan(tester, '6901');
    await pumpUntil(
      tester,
      () => qtyText('6901', '2').evaluate().isNotEmpty,
      why: '复盘把商品挡住了 —— 复盘的价值就在于不知道哪里会错，'
          '先按差异集卡住等于默认初盘是对的，初盘漏扫的货永远没人补',
    );

    await waitSnackClear(tester);
    await tester.tap(find.byKey(const Key('inv-submit')));
    await settleAnim(tester);
    await tester.tap(find.text('提交'));
    await pumpUntil(
      tester,
      () => find.text('现在开始抽盘？').evaluate().isNotEmpty,
      why: '两遍对不上，提交复盘后却没问"现在开始抽盘？"',
    );
    await tester.tap(find.text('开始抽盘'));
    await pumpUntil(
      tester,
      () => find.textContaining('共 1 种').evaluate().isNotEmpty,
      why: '抽盘要复核的清单没载进来（上一轮对不上的只有 6901 一条）',
    );

    // 反向：6902 不在要复核的清单里 → 必须被拒，而且**要说清原因**
    await scan(tester, '6902');
    await pumpUntil(
      tester,
      () => find.textContaining('不在差异集内').evaluate().isNotEmpty,
      why: '拒了但没说原因 —— 现场只会看到"扫了没反应"，那是最难查的一种反馈',
    );
    expect(find.byKey(const Key('inv-row-6902')), findsNothing,
        reason: '复核清单外的商品被放进抽盘了：主管的抽盘单会被"看着正常"的商品淹掉');

    // 正向：6901 在清单里 → 能进（否则就是把抽盘整个堵死了）
    await scan(tester, '6901');
    await pumpUntil(
      tester,
      () => find.byKey(const Key('inv-row-6901')).evaluate().isNotEmpty,
      why: '要复核的商品反而扫不进去',
    );
  });

  testWidgets('⑥ 提交后本地锁死：数量格点不动了，且不再收新数据', (tester) async {
    await pumpPage(tester);
    await scan(tester, '6901');
    await pumpUntil(
      tester,
      () => find.byKey(const Key('inv-row-6901')).evaluate().isNotEmpty,
      why: '6901 没进列表',
    );
    // 一条都没扫时提交按钮必须是灰的（空手点提交会把初盘标记成完成，
    // 差异集随之定格为空，后面整条链全废）
    await pumpUntil(
      tester,
      () => find.text('提交初盘').evaluate().isNotEmpty,
      why: '扫过之后提交按钮没变成「提交初盘」',
    );

    await tester.tap(find.byKey(const Key('inv-submit')));
    await settleAnim(tester);
    expect(find.textContaining('提交后这张单'), findsOneWidget);
    await tester.tap(find.text('提交'));
    await pumpUntil(
      tester,
      () => find.byKey(const Key('inv-reopen')).evaluate().isNotEmpty,
      why: '提交之后按钮没变成「撤销提交」',
    );

    // 文案不能拼出"已已提交"（label 本身就带"已"）
    expect(find.textContaining('已提交 · 撤销提交'), findsOneWidget);
    expect(find.textContaining('已已提交'), findsNothing);

    // 提交后往往还会弹"现在开始复盘？"，先关掉再检查列表本身
    if (find.text('待会儿').evaluate().isNotEmpty) {
      await tester.tap(find.text('待会儿'));
      await settleAnim(tester);
    }

    // 已提交 = 不能再改。点数量格不该弹出改数量对话框。
    await tester.tap(find.byKey(const Key('inv-qty-6901')), warnIfMissed: false);
    await settleAnim(tester);
    expect(find.text('改数量'), findsNothing,
        reason: '提交之后还能改数量，等于"盘点结果可以事后修饰"，这套制度就没意义了');

    // 提交后再扫也不该进
    await scan(tester, '6902');
    final rows = await rowsOf(tester, '6902');
    expect(rows, isEmpty, reason: '已提交的单还在往里写数据');
  });

  testWidgets('⑦ 两遍都对得上时，抽盘不能是死胡同（要给「返回点位」）', (tester) async {
    await pumpPage(tester);
    await scan(tester, '6901');
    await pumpUntil(
      tester,
      () => find.byKey(const Key('inv-row-6901')).evaluate().isNotEmpty,
      why: '初盘那一行没出现',
    );

    // 提交初盘 → **一定要问**"现在开始复盘？"
    // 🔴 旧写法拿"本单差异数 > 0"当门槛；差异基准换成"比上一阶段"以后，
    //    初盘的差异恒为 0，这一问就再也不会弹 —— 三遍制的第一遍当场断在这。
    await waitSnackClear(tester);
    await tester.tap(find.byKey(const Key('inv-submit')));
    await settleAnim(tester);
    await tester.tap(find.text('提交'));
    await pumpUntil(
      tester,
      () => find.text('现在开始复盘？').evaluate().isNotEmpty,
      why: '初盘提交后没问"现在开始复盘？"（拿本单差异数当门槛就会漏掉这一问）',
    );
    await tester.tap(find.text('开始复盘'));
    await pumpUntil(
      tester,
      () => find.textContaining('复盘是这一片重新盘一遍').evaluate().isNotEmpty,
      why: '点了"开始复盘"没切到复盘',
    );

    // 复盘盘成同样的 1 件 → 两遍对得上
    await scan(tester, '6901');
    await pumpUntil(
      tester,
      () => qtyText('6901', '1').evaluate().isNotEmpty,
      why: '复盘那一行没出现',
    );
    await waitSnackClear(tester);
    await tester.tap(find.byKey(const Key('inv-submit')));
    await settleAnim(tester);
    await tester.tap(find.text('提交'));
    // 先等**状态真的变了**（提交成功会把按钮换成「撤销提交」），
    // 别拿提示语当提交成功的信号 —— SnackBar 是**排队**的，
    // 上一条"复盘已提交"还没走完，下一条要等 4 秒才轮得到。
    await pumpUntil(
      tester,
      () => find.byKey(const Key('inv-reopen')).evaluate().isNotEmpty,
      why: '复盘提交失败（没等到「撤销提交」）',
    );
    await pumpUntil(
      tester,
      () => find.textContaining('都对得上').evaluate().isNotEmpty,
      tries: 300,
      why: '两遍对得上时没给出"没有要复核的商品"的反馈',
    );
    expect(find.text('现在开始抽盘？'), findsNothing,
        reason: '两遍全对得上还把人拉进抽盘 —— 那个阶段扫什么都进不去，'
            '进去了就是个死胡同');

    // 手动切抽盘：切阶段要二次确认（串阶段在货架中间解释不清）
    await tester.tap(find.byKey(const Key('inv-phase-3')));
    await settleAnim(tester);
    expect(find.text('切到抽盘？'), findsOneWidget, reason: '切阶段没有二次确认，串阶段查不出来');
    await tester.tap(find.text('切到抽盘'));
    await pumpUntil(
      tester,
      () => find.text('前两遍都对得上').evaluate().isNotEmpty,
      why: '没有要复核的商品时抽盘页没给出路 —— 提交按钮因为"一条都没扫"灰着，'
          '主管就卡在抽盘阶段出不去（两遍都对得上反而是常态，不是异常）',
    );
    expect(find.byKey(const Key('inv-back-to-zone')), findsOneWidget);
  });

  testWidgets('⑧ 撤销提交之后又能改了（锁是真的锁，不是画上去的）', (tester) async {
    await pumpPage(tester);
    await scan(tester, '6901');
    await pumpUntil(
      tester,
      () => find.text('提交初盘').evaluate().isNotEmpty,
      why: '提交按钮没出现',
    );

    await tester.tap(find.byKey(const Key('inv-submit')));
    await settleAnim(tester);
    await tester.tap(find.text('提交'));
    await pumpUntil(
      tester,
      () => find.byKey(const Key('inv-reopen')).evaluate().isNotEmpty,
      why: '提交失败',
    );
    if (find.text('待会儿').evaluate().isNotEmpty) {
      await tester.tap(find.text('待会儿'));
      await settleAnim(tester);
    }

    await tester.tap(find.byKey(const Key('inv-reopen')));
    await settleAnim(tester);
    expect(find.textContaining('撤销提交初盘？'), findsOneWidget);
    await tester.tap(find.text('撤销提交'));
    await pumpUntil(
      tester,
      () => find.byKey(const Key('inv-submit')).evaluate().isNotEmpty,
      why: '撤销提交之后没回到可编辑状态',
    );

    // 真的能改了：改数量 → 落库
    await tester.tap(find.byKey(const Key('inv-qty-6901')));
    await settleAnim(tester);
    expect(find.text('改数量'), findsOneWidget,
        reason: '撤销提交之后还是改不动 —— 那个「撤销提交」就是假按钮');
    await tester.enterText(
      find.descendant(
          of: find.byType(AlertDialog), matching: find.byType(TextField)),
      '7',
    );
    await tester.tap(find.text('保存'));
    await settleAnim(tester);
    await pumpUntil(
      tester,
      () => qtyText('6901', '7').evaluate().isNotEmpty,
      why: '撤销提交后改的数量没生效',
    );
  });
}
