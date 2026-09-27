import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xiaozhi_im_client/core/config.dart';
import 'package:xiaozhi_im_client/core/deduct_export.dart';
import 'package:xiaozhi_im_client/core/deduct_rules.dart';
import 'package:xiaozhi_im_client/core/local_db.dart';
import 'package:xiaozhi_im_client/screens/deduct.dart';
import 'support/api_stub.dart';

/// 库房减货：导出格式化（纯函数）+ 页面行为。
///
/// 页面这一层钉的是"现场唯一的主路径到底通不通，以及没数据时看不看得见东西"：
///   ① 空单时**表头、输入框、按钮都还在**（没数据时用户怎么知道这里有功能）
///   ② 扫码 + 数量 → 真的落进单里，汇总跟着变
///   ③ 重复条码 → 出 PG 那句原文，且**行数不变**
///   ④ 提交后本地锁死（输入框点不动）
///   ⑤ 空单点导出 → 明说"先扫几条"，不是静默也不是报错
///
/// ── 测试基建（和 inventory_page_test 同一套坑）──────────────────
/// · SQLite 走 isolate、是真实异步；widget 测试跑在**假时钟**里，
///   所以每次等库都必须包 `tester.runAsync`，否则页面永远停在转圈。
/// · **不要用裸 `pumpAndSettle()`**（撞上转圈会等到 10 分钟超时，表现为卡死）。
/// · `tester.pump()` 只推假时钟、不给真实时间 → 落库之后必须用带 runAsync 的轮询。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
  final supportDir = '${Directory.systemTemp.path}/xz_deduct_page_test';
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
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 40));
      if (ok()) return;
    }
    fail('等待超时：$why');
  }

  /// 等页面读完库（转圈消失）。
  Future<void> settle(WidgetTester tester) => pumpUntil(
        tester,
        () => find.byType(CircularProgressIndicator).evaluate().isEmpty,
        why: '页面一直停在 loading：DB 初始化没在预期次数内完成',
      );

  /// 等所有 SnackBar 散掉。
  ///
  /// 不是迁就测试：底部浮动的 SnackBar 会**压住它上方那块的按钮**，
  /// 那几秒里点了没反应 —— 真机上也是这样。
  Future<void> drain(WidgetTester tester) async {
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 200));
      if (find.byType(SnackBar).evaluate().isEmpty) return;
    }
  }

  setUp(() async {
    await LocalDb.I.resetForTest();
  });

  tearDown(() async {
    await LocalDb.I.close();
  });

  Future<void> pumpPage(WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: DeductPage()));
    await settle(tester);
  }

  /// 当前列表行数。
  ///
  /// 按行 key 数，**不靠文字找** —— 输入框里也可能有同一个条码，
  /// 那样"被拒的扫码有没有多写一行"就永远测不出来（假绿）。
  int rowCount(WidgetTester tester) => tester
      .widgetList(find.byWidgetPredicate((w) =>
          w.key is ValueKey<String> &&
          (w.key as ValueKey<String>).value.startsWith('deduct-row-')))
      .length;

  /// 当前单号。**读不到就回 null，不许抛** ——
  /// 刷新期间页面上只有转圈、表头整个不在树里，用 `widget<T>()` 会在轮询的
  /// 判据里抛 StateError，报出来是"测试异常"而不是"没等到"，方向全乱。
  String? sheetNo(WidgetTester tester) {
    final f = find.byKey(const Key('deduct-sheet-no'));
    if (f.evaluate().isEmpty) return null;
    return tester.widget<Text>(f).data;
  }

  Future<void> scan(
    WidgetTester tester, {
    required String barcode,
    String qty = '2',
  }) async {
    final before = rowCount(tester);
    await tester.enterText(find.byKey(const Key('deduct-barcode-input')), barcode);
    await tester.enterText(find.byKey(const Key('deduct-qty-field')), qty);
    await tester.tap(find.byKey(const Key('deduct-add')));
    // 成功路径**不弹 SnackBar**（列表多一行 + 音效就是反馈；每扫一次糊一条提示
    // 反而挡住下面的行）。所以这里等的是"要么进了列表，要么出了提示"。
    await pumpUntil(
      tester,
      () =>
          rowCount(tester) > before ||
          find.byType(SnackBar).evaluate().isNotEmpty,
      why: '点了「确定减货」之后既没进列表、也没有任何提示',
    );
  }

  // ============================================================
  group('DeductExport（纯函数）', () {
    Map<String, dynamic> row({
      String barcode = '6901234567890',
      Object? qty = 2,
      String? name = '海盐饼干',
      Object? at = 1758412800000, // 2025-09-21 08:00:00 UTC+8 附近
    }) =>
        <String, dynamic>{
          'barcode': barcode,
          'qty': qty,
          'name': name,
          'spec': '200g/袋',
          'unit': '袋',
          'scanned_at': at,
        };

    test('🔴 第一行第一列是 UTF-8 BOM（看原始字符，不是看解码后的样子）', () {
      final csv = DeductExport.toCsv(<Map<String, dynamic>>[row()]);
      expect(csv.codeUnitAt(0), 0xFEFF,
          reason: '没 BOM，Excel/WPS 会按 GBK 打开，中文商品名全乱码');
    });

    test('表头是中文且列数对齐（列错位比乱码还难查）', () {
      final csv = DeductExport.toCsv(<Map<String, dynamic>>[row()]);
      // StringBuffer.writeln 只写 \n，不写 \r\n —— 按 \r\n 切会一行都切不开
      // （trim() 顺手兼容万一哪天改成 CRLF）
      final lines = csv
          .split('\n')
          .map((l) => l.trim())
          .where((l) => l.isNotEmpty)
          .toList();
      expect(lines.first.replaceFirst('\uFEFF', ''),
          DeductExport.headers.join(','));
      expect(lines[1].split(',').length, DeductExport.headers.length);
    });

    test('🔴 13 位条码写成 Excel 文本公式（不然变科学计数法/尾数被抹 0）', () {
      final csv = DeductExport.toCsv(<Map<String, dynamic>>[row()]);
      expect(csv.contains('"=""6901234567890"""'), isTrue,
          reason: '长条码没当文本 → 现场照着一个错的条码找不到货');
    });

    test('带前导零的店内码同样当文本', () {
      final csv = DeductExport.toCsv(
          <Map<String, dynamic>>[row(barcode: '0071234')]);
      expect(csv.contains('"=""0071234"""'), isTrue,
          reason: '0071234 变成 71234 就换了商品');
    });

    test('短条码保持原样（不要给所有条码都套 ="..."，那样反而难读）', () {
      final csv = DeductExport.toCsv(
          <Map<String, dynamic>>[row(barcode: '12345')]);
      expect(csv.contains('12345'), isTrue);
      expect(csv.contains('"=""12345"""'), isFalse);
    });

    test('整数数量不带小数点，小数保留', () {
      expect(DeductExport.fmtQty(3), '3');
      expect(DeductExport.fmtQty(3.0), '3');
      expect(DeductExport.fmtQty(3.5), '3.5');
      expect(DeductExport.fmtQty(null), '');
    });

    test('账上没有的商品也要出现在 CSV 里（不能因为 join 不到就丢行）', () {
      final csv = DeductExport.toCsv(
          <Map<String, dynamic>>[row(name: null, barcode: '999999999999')]);
      expect(csv.contains('未知条码'), isTrue);
      expect(csv.contains('999999999999'), isTrue,
          reason: '这一行被整行丢掉了 —— 它恰恰是最该被看见的');
    });

    test('时间戳格式化；空值给空串而不是 "null"', () {
      final csv = DeductExport.toCsv(<Map<String, dynamic>>[row(at: null)]);
      expect(csv.contains('null'), isFalse);
    });

    test('文件名带单号，且路径分隔符被挡住', () {
      expect(DeductExport.csvName('JH20260921090000'),
          '减货_JH20260921090000.csv');
      expect(DeductExport.safeSheetNo('a/b:c'), 'a_b_c');
    });

    test('摘要文案：整数合计不带小数点', () {
      expect(
          DeductExport.summaryText(const DeductTally(kinds: 2, totalQty: 5)),
          '共 2 种，合计减货 5');
    });
  });

  // ============================================================
  group('减货页', () {
    testWidgets('🔴 空单时表头/输入框/按钮都还在（没数据也要知道这里有功能）',
        (tester) async {
      await pumpPage(tester);

      expect(find.text('库房减货'), findsOneWidget);
      expect(find.byKey(const Key('deduct-sheet-no')), findsOneWidget);
      expect(find.byKey(const Key('deduct-barcode-input')), findsOneWidget);
      expect(find.byKey(const Key('deduct-qty-field')), findsOneWidget);
      expect(find.byKey(const Key('deduct-add')), findsOneWidget);
      // 列名常显：不画的话没扫过码的人整页看不到列。
      // 🔴 按 key 找，别按文字 —— 输入框的 label 也叫「条码」「数量」，
      //    按文字找会一次命中两个，"列头到底画没画"这件事就说不清了。
      for (final k in <String>[
        'deduct-col-barcode',
        'deduct-col-name',
        'deduct-col-qty',
        'deduct-col-op',
      ]) {
        expect(find.byKey(Key(k)), findsOneWidget, reason: '空单时列头「$k」不见了');
      }
      expect(find.text('还没有减货记录，扫一个条码开始'), findsOneWidget);
      expect(find.byKey(const Key('deduct-summary')), findsOneWidget);
    });

    testWidgets('扫码 + 数量 → 落进单里，汇总跟着变', (tester) async {
      await pumpPage(tester);
      await scan(tester, barcode: '6901234567890', qty: '2');
      expect(rowCount(tester), 1, reason: '扫了一笔，列表里就该有且只有一行');
      // 成功之后输入框会清空，所以这串文字只可能来自列表那一行
      expect(find.text('6901234567890'), findsOneWidget);
      expect(find.text('共 1 种，合计减货 2'), findsOneWidget);
    });

    testWidgets('🔴 重复条码 → 出 PG 那句原文，且行数不变', (tester) async {
      await pumpPage(tester);
      await scan(tester, barcode: '6901234567890', qty: '2');
      await drain(tester);

      await scan(tester, barcode: '6901234567890', qty: '9');
      await pumpUntil(
        tester,
        () => find.text('减货列表已存在，请处理后重新扫码').evaluate().isNotEmpty,
        why: '重复扫码没有提示 —— 员工会以为已经减了两次',
      );
      // 行数没变：被拒的那一笔一行都没多写。
      // 🔴 这里**不能**按文字断言 —— 被拒时输入框是故意保留条码的
      //    （员工要看清自己扫的是哪个码），find.text 会命中两处，永远假绿。
      expect(rowCount(tester), 1, reason: '重复条码被拒了，却还是多写了一行');
      expect(find.text('共 1 种，合计减货 2'), findsOneWidget,
          reason: '被拒的那一笔把数量改掉了');
    });

    testWidgets('提交后本地锁死：输入框点不动', (tester) async {
      await pumpPage(tester);
      await scan(tester, barcode: '6901', qty: '1');
      await drain(tester);

      // 走菜单里的「提交这一单」。
      // 菜单动画是多帧的，得一步一 pump 并把每步都 assert 出来 ——
      // 只在最后断言"输入框禁用了"的话，前两步没打开菜单也会报同一句话，
      // 排查时根本分不清是菜单没弹还是提交没生效。
      await tester.tap(find.byKey(const Key('deduct-menu')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('提交这一单'), findsOneWidget, reason: '菜单没弹出来');
      await tester.tap(find.text('提交这一单'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('再核对一下'), findsOneWidget, reason: '确认弹窗没弹出来');
      await tester.tap(find.text('提交'));
      await pumpUntil(
        tester,
        () => find.text('已提交').evaluate().isNotEmpty,
        why: '提交之后状态没转成「已提交」',
      );

      // 🔴 提交之后**还留在刚交的那张单上**：明细还在、状态是已提交。
      //    这里曾经有个真 bug：刷新时无脑 openOrCreate() → 找不到进行中的单
      //    就再开一张空的，现场看到"刚交的单凭空消失、又变回进行中"。
      expect(rowCount(tester), 1,
          reason: '提交后明细不见了 —— 刷新时把单子换成了新开的那张空单');
      expect(find.text('共 1 种，合计减货 1'), findsOneWidget,
          reason: '汇总被换成了新单的 0');
      expect(find.byKey(const Key('deduct-locked-hint')), findsOneWidget,
          reason: '锁死了但没告诉员工为什么点不动');

      final field = tester.widget<TextField>(
          find.byKey(const Key('deduct-barcode-input')));
      expect(field.enabled, isFalse, reason: '提交后还能继续扫，等于单子没锁');
    });

    testWidgets('🔴 撤销提交改的是刚交的那张单，不是新开一张', (tester) async {
      await pumpPage(tester);
      await scan(tester, barcode: '6901', qty: '1');
      await drain(tester);

      await tester.tap(find.byKey(const Key('deduct-menu')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('提交这一单'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('提交'));
      await pumpUntil(tester, () => find.text('已提交').evaluate().isNotEmpty,
          why: '提交之后状态没转成「已提交」');
      await drain(tester);

      await tester.tap(find.byKey(const Key('deduct-menu')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('撤销提交'));
      await pumpUntil(tester, () => find.text('进行中').evaluate().isNotEmpty,
          why: '撤销提交之后没退回「进行中」');

      // 退回之后明细必须还在（改的是同一张单），输入框也要重新可用
      expect(rowCount(tester), 1, reason: '撤销提交之后明细没了 —— 退到了另一张单上');
      final field = tester.widget<TextField>(
          find.byKey(const Key('deduct-barcode-input')));
      expect(field.enabled, isTrue, reason: '撤销提交之后还是点不动');
    });

    testWidgets('🔴 交完单再「开新单」，历史里还翻得回上一张（凭据不能丢）',
        (tester) async {
      await pumpPage(tester);
      final firstNo = sheetNo(tester)!;
      await scan(tester, barcode: '6901', qty: '3');
      await drain(tester);

      // 交掉
      await tester.tap(find.byKey(const Key('deduct-menu')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('提交这一单'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('提交'));
      await pumpUntil(tester, () => find.text('已提交').evaluate().isNotEmpty,
          why: '提交之后状态没转成「已提交」');
      await drain(tester);

      // 换新单：上一张就从眼前消失了
      await tester.tap(find.byKey(const Key('deduct-menu')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('开新单'));
      await pumpUntil(
        tester,
        () => find.text('还没有减货记录，扫一个条码开始').evaluate().isNotEmpty,
        why: '开了新单但界面还是旧的那张',
      );

      // 历史面板里必须还看得见它
      await tester.tap(find.byKey(const Key('deduct-history')));
      await pumpUntil(
        tester,
        () => find.text('历史减货单').evaluate().isNotEmpty,
        why: '历史面板没打开',
      );
      // 🔴 面板是**从屏幕外滑上来**的：文字一出现就点，坐标还在视口外（y>600），
      //    点了个空 —— 报出来却是"点了没切过去"，很容易查错方向。等动画走完。
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(Key('deduct-hs-$firstNo')), findsOneWidget,
          reason: '交过的那张单在历史里找不到 —— 货已经减了却没有凭据');
      expect(find.textContaining('已提交 · 1 条 · 合计 3'), findsOneWidget,
          reason: '历史里看不清那张单交没交、有几条多少量');

      // 点回去
      await tester.tap(find.byKey(Key('deduct-hs-$firstNo')));
      await pumpUntil(
        tester,
        () => sheetNo(tester) == firstNo,
        why: '点了历史里的单没切过去',
      );
      await pumpUntil(tester, () => rowCount(tester) == 1,
          why: '切回老单之后明细没读出来');
      expect(find.text('已提交'), findsOneWidget);
    });

    testWidgets('空单点导出 → 明说"先扫几条"，不静默也不报错', (tester) async {
      await pumpPage(tester);
      await tester.tap(find.byKey(const Key('deduct-export')));
      await pumpUntil(
        tester,
        () => find.text('这一单还没有明细，先扫几条再导出').evaluate().isNotEmpty,
        why: '空单点导出没有任何反馈',
      );
    });

    testWidgets('🔴 交完之后「开新单」→ 换一张空单，单号也换了', (tester) async {
      await pumpPage(tester);
      final firstNo = sheetNo(tester)!;
      await scan(tester, barcode: '6901', qty: '1');
      await drain(tester);

      await tester.tap(find.byKey(const Key('deduct-menu')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('提交这一单'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('提交'));
      await pumpUntil(tester, () => find.text('已提交').evaluate().isNotEmpty,
          why: '提交之后状态没转成「已提交」');
      await drain(tester);

      await tester.tap(find.byKey(const Key('deduct-menu')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('开新单'));
      await pumpUntil(
        tester,
        () => find.text('还没有减货记录，扫一个条码开始').evaluate().isNotEmpty,
        why: '开了新单但界面还是旧的那张（明细没清）',
      );

      expect(rowCount(tester), 0, reason: '新单里还挂着上一张单的明细');
      final newNo = sheetNo(tester)!;
      expect(newNo, isNot(firstNo), reason: '新单和旧单是同一个单号 —— 等于换了个寂寞');
      expect(find.text('进行中'), findsOneWidget);
      final field = tester.widget<TextField>(
          find.byKey(const Key('deduct-barcode-input')));
      expect(field.enabled, isTrue, reason: '开了新单却还是扫不进去');
    });

    // ============================================================
    // 参照数：龙哥 2026-09-26 那条业务链的落点
    //   "库房减货不是盘点的一个流程吗？" —— 它是分开的功能，但判据来自上一次盘点：
    //   盘点完 → 拿货/损耗销售 → 账实对不上 → 用减货把已盘点的数往下减。
    // 这一段钉住现场最容易翻车的两件事：**没网时不能拦人**、**数字不能算错**。
    group('参照数（上一轮盘点 → 剩多少）', () {
      late ApiStub stub;

      // 🔴 ApiStub 必须在 setUp（真实时钟）里起，不能放在 testWidgets 体内：
      //    体内是 FakeAsync 假时钟，HttpServer 的 idleTimeout 周期定时器会变成
      //    fake timer，body 结束即查 pending timer 报红。其它页面测试
      //    （inventory_upload / training / inventory_grant ...）一律这么写，证明可行。
      setUp(() async {
        stub = await ApiStub.start();
        Config.currentUrl = stub.baseUrl;
        addTearDown(() {
          HttpOverrides.global = null;
          return stub.stop();
        });
      });

      /// 给这一个接口挂一个处理函数（每次测试只挂自己的，覆盖上一个测试的）。
      ///
      /// 🔴 为什么不起假 HTTP、偏要真端口：参照数这一块的全部价值就是"服务端
      ///    回什么、界面就显示什么"。mock 掉的 http 会把 `barcode=` 拼错、
      ///    字段名读错、401 当 200 这些事**全都能通过** —— 而它们正好是
      ///    这一版最容易出错的地方（字段名 `countedQty` / `remaining` 全是新的）。
      void stubRef(Object? Function(StubCall) h) {
        stub.on('GET', '/api/deduct/reference', h);
      }

      String refText(WidgetTester tester, String key) {
        final f = find.byKey(Key(key));
        if (f.evaluate().isEmpty) return '';
        return tester.widget<Text>(find.byKey(Key(key))).data ?? '';
      }

      /// 等参照那一次请求**真的回来**（不是"发出去"就够了）。
      ///
      /// 🔴 这里必须给**真实时间**：`tester.pump` 只推假时钟，本地 socket 的
      ///    响应来回比好几帧还快，也可能慢一帧 —— 只等请求打出去就断言，
      ///    测的是"请求发出去了"，不是"拿到响应之后界面怎么画的"。
      ///    所以先用 pumpUntil 确认请求发出，再按真实时间等一段把 RTT 包进去。
      Future<void> waitRefBack(WidgetTester tester, {int ms = 400}) async {
        await pumpUntil(
          tester,
          () => stub.hits('GET', '/api/deduct/reference') > 0,
          why: '扫完码压根没去查参照 —— 参照数这块等于没接上',
        );
        for (var i = 0; i < ms ~/ 20; i++) {
          await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 20)));
          await tester.pump(const Duration(milliseconds: 20));
        }
      }

      testWidgets('🔴 查不到参照 → 卡片整块消失，不留灰字、更不拦人', (tester) async {
        // 500：模拟"服务端炸了"，和 404 区分开 ——
        // 用 404 的话测试会因为"路由没注册"而假通过。
        stubRef((c) => StubResponse(500,
            <String, dynamic>{'error': 'boom'}));
        await pumpPage(tester);
        expect(find.byKey(const Key('deduct-flow-hint')), findsOneWidget,
            reason: '没有参照数时，页面上要有一句话讲清减货和盘点是什么关系');

        await scan(tester, barcode: '6901234567890', qty: '2');
        await waitRefBack(tester);

        // 🔴 库房常常在最里头、信号时有时无。留一块"暂无数据"的灰字，
        //    现场会理解成"这页坏了"；而且绝不能因为查不到就禁止减货 ——
        //    临时减货（破损/赠品出库）本来就不盘。
        expect(find.byKey(const Key('deduct-ref-card')), findsNothing,
            reason: '查不到参照却画了卡片 —— 员工会以为系统不给数据');
        expect(rowCount(tester), 1, reason: '参照查不到就把这一笔也拒了');
        expect(find.text('共 1 种，合计减货 2'), findsOneWidget,
            reason: '这一笔没落库');
      });

      testWidgets('扫完之后带出参照：上一轮盘点 / 已减 / 减完剩', (tester) async {
        stubRef((c) => <String, dynamic>{
          'ok': true,
          'hasRef': true,
          'barcode': c.query['barcode'],
          'name': '海盐饼干',
          'countedQty': 50,
          'countedAt': 1758412800000,
          'countedSheet': 'INV-20260921090000',
          'accountQty': 50,
          'deductedQty': 12,
          'deductedSheets': 2,
          'remaining': 38,
          'windowDays': 30,
        });
        await pumpPage(tester);
        await scan(tester, barcode: '6901234567890', qty: '10');

        // 🔴 等请求真的发出 + 回包（真实时间）再断言：FakeAsync 下直接断言
        //    会早于请求到达（"Expected >0, Actual 0"）。waitRefBack 先等 hits>0。
        await waitRefBack(tester);

        // 🔴 顺手钉一下"条码确实带过去了"。参照是按码查的，参数名写错
        //    （比如 `barcode` 写成 `code`）会永远查空，界面上还看不出异常。
        expect(stub.hits('GET', '/api/deduct/reference'), greaterThan(0),
            reason: '扫完码压根没去查参照');
        expect(stub.last('GET', '/api/deduct/reference').query['barcode'],
            '6901234567890',
            reason: '查参照时条码没带上（服务端只能回空）');

        // 🔴 扫完一笔后输入框数量会被重置回 1（为下一件快速连扫，见 _addRow），
        //    所以这里把数量重新填回 10，让"减完剩"按 剩余 38 - 本次 10 = 28 验证。
        await tester.enterText(find.byKey(const Key('deduct-qty-field')), '10');

        await pumpUntil(
          tester,
          () => find.byKey(const Key('deduct-ref-card')).evaluate().isNotEmpty,
          why: '扫完之后没有带出参照卡',
        );

        expect(find.byKey(const Key('deduct-ref-card')), findsOneWidget);
        expect(find.byKey(const Key('deduct-flow-hint')), findsNothing,
            reason: '已经有参照了，还挂着那句"减货不是盘点的下一步"');
        expect(refText(tester, 'deduct-ref-counted'), '50',
            reason: '上一轮盘点是 50，参照数却不是 50');
        expect(refText(tester, 'deduct-ref-deducted'), '12',
            reason: '这次之前已减 12，却给成了别的数');
        // 🔴 剩 = 盘点 50 - 已减 12 - 本次 10 = 28。算错的话员工会照着
        //    一个假数字去点货，当场就对不上。
        expect(refText(tester, 'deduct-ref-left'), '28',
            reason: '减完剩算错了（应 = 50 - 12 - 10）');

        // 改数量要跟着重算，别等下一次扫码
        await tester.enterText(find.byKey(const Key('deduct-qty-field')), '20');
        await pumpUntil(
          tester,
          () => refText(tester, 'deduct-ref-left') == '18',
          why: '改了数量但「减完剩」没跟着变（要等下次扫码才刷新）',
        );
      });

      testWidgets('没盘过、也没减过 → hasRef=false，卡片不画但能照常减', (tester) async {
        stubRef((c) => <String, dynamic>{
          'ok': true, 'hasRef': false, 'barcode': c.query['barcode'],
          'countedQty': null, 'deductedQty': 0,
          'deductedSheets': 0, 'remaining': null, 'windowDays': 30,
        });
        await pumpPage(tester);
        await scan(tester, barcode: '6901', qty: '1');
        await waitRefBack(tester);

        expect(find.byKey(const Key('deduct-ref-card')), findsNothing,
            reason: 'hasRef=false 却画了参照卡 —— 临时减货会被误认为有依据');
        expect(rowCount(tester), 1, reason: '没查到参照就不许减货了');
        expect(find.text('共 1 种，合计减货 1'), findsOneWidget,
            reason: '这一笔没落库');
      });

      testWidgets('🔴 没盘过但商品档案有 → 账面数带出来，且不冒充盘点', (tester) async {
        // 龙哥 2026-09-26：「商档我已经存到商品档案了，这个要打通共用」。
        // 没盘过的货，账面数也要从商品档案来 —— 否则员工扫完只看到"—"，
        // 连自己扫没扫错码都不知道。
        stubRef((c) => <String, dynamic>{
          'ok': true, 'hasRef': true, 'barcode': c.query['barcode'],
          'name': '德芙兰洗衣伴侣300ml', 'spec': '1×12', 'unit': '瓶',
          'countedQty': null, 'countedAt': null, 'countedSheet': null,
          'accountQty': 300, 'accountFrom': 'master',
          'deductedQty': 0, 'deductedSheets': 0, 'remaining': null,
          'windowDays': 30,
        });
        await pumpPage(tester);
        await scan(tester, barcode: '6949', qty: '2');
        await waitRefBack(tester);

        expect(find.byKey(const Key('deduct-ref-card')), findsOneWidget,
            reason: '商档认得这个码就该给参照（扫完至少能确认扫对了哪个货）');
        final acc = find.byKey(const Key('deduct-ref-account'));
        expect(acc, findsOneWidget, reason: '账面数没带出来 —— 商档没打通');
        expect(tester.widget<Text>(acc).data, contains('300'),
            reason: '账面数应该是商品档案里的 300');
        expect(tester.widget<Text>(acc).data, contains('商品档案'),
            reason: '得说清这数来自商品档案，不是盘点来的');
        // 🔴 商档不冒充盘点：没盘过就是没盘过
        expect(find.byKey(const Key('deduct-ref-counted')).evaluate().single,
            isNotNull);
        expect(tester.widget<Text>(find.byKey(const Key('deduct-ref-counted'))).data,
            '—', reason: '没盘过却显示了一个"盘点数"，那就是拿商档冒充盘点');
        expect(rowCount(tester), 1, reason: '没盘点数也要能照常减');
      });
    });
  });
}
