import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xiaozhi_im_client/api.dart';
import 'package:xiaozhi_im_client/core/config.dart';
import 'package:xiaozhi_im_client/core/theme.dart';
import 'package:xiaozhi_im_client/screens/workbench.dart';

import 'support/api_stub.dart';

/// 工作台的渲染测试 —— 钉住的是"**服务端说什么就长什么样**"。
///
/// 这一页最容易出的错不是崩溃，而是"配了没反应"：组名写死在客户端、
/// 图标底色没接服务端下发、公告压根没渲染。这三样在 `flutter analyze`
/// 阶段全都是绿的，只有真的渲染一遍才看得见。
///
/// 所以这里用**真 HTTP 桩**（不起真服务器进程，但请求真的发出去、真的解析），
/// 而不是把 http 换成 mock：字段名读错一个字母，mock 会照旧"通过"。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ApiStub stub;

  /// 一份典型的 /api/client/apps 响应。
  ///   · attendance / inventory 是客户端认得的内置应用；
  ///   · zzz_unknown 是**客户端不认识**的内置 id（老客户端 + 新服务端的情况）；
  ///   · 自定义模块模块走 dynamic。
  Map<String, Object?> payload({
    List<Map<String, Object?>> notices = const [
      {'id': 1, 'text': '明天盘点，全店 9 点前把货架归位', 'sort': 100},
    ],
    List<Map<String, Object?>> groups = const [
      {'key': 'work', 'label': '办公协同', 'sort': 10},
      {'key': 'custom', 'label': '自建', 'sort': 20},
    ],
    List<Map<String, Object?>> apps = const [
      {'id': 'attendance', 'title': '考勤打卡', 'icon': 'schedule', 'group': 'work',
       'groupLabel': '办公协同', 'desc': '', 'kind': 'builtin', 'sort': 10, 'params': {}},
      // inventory 带 color：拼错字段名（'iconColor' / 'tint'）时底色会静默退回品牌色，
      // 只有真渲染一遍才看得见
      {'id': 'inventory', 'title': '盘点', 'icon': 'inventory', 'group': 'work',
       'groupLabel': '办公协同', 'desc': '', 'kind': 'builtin', 'sort': 20,
       'color': '#C0392B', 'params': {}},
      {'id': 'zzz_unknown', 'title': '未来的应用', 'icon': 'box', 'group': 'work',
       'groupLabel': '办公协同', 'desc': '', 'kind': 'builtin', 'sort': 30, 'params': {}},
      {'id': 'm1', 'title': '报修单', 'icon': 'build', 'group': 'custom', 'groupLabel': '自建',
       'desc': '', 'kind': 'dynamic', 'sort': 40, 'params': {}},
    ],
  }) => {
        'apps': apps,
        'groups': groups,
        'notices': notices,
        'workMode': 'work',
        'ts': 1700000000000,
      };

  /// 手机宽度（4 列的那一档）。桌面宽屏走的是同一套代码、更多列，不用重复测。
  Future<void> pumpPhone(WidgetTester t, Map<String, Object?> body) async {
    // 🔴 `setSurfaceSize` 返回的是 Future（受 TestAsyncUtils 保护）。
    //    不加 await 就接着调 pumpWidget，报的是
    //    "Guarded function conflict / You must use await with all Future-returning
    //    test APIs" —— **指向的是这一行，但真正的错是漏了 await**。
    //    这轮的 7 条测试全挂在这上面，一条都没走到断言。
    await t.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() async {
      await t.binding.setSurfaceSize(null);
    });
    stub.on('GET', '/api/client/apps', (r) => body);
    await t.pumpWidget(const MaterialApp(home: Scaffold(body: WorkbenchPage())));
    // runAsync：把真实时间借给 HTTP（真 socket），假时钟下永远等不到回包
    for (var i = 0; i < 80; i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await t.pump(const Duration(milliseconds: 20));
      if (find.byType(GridView).evaluate().isNotEmpty) return;
    }
    // 🔴 超时时把"此刻页面上到底有什么"打出来。
    //    不然报错只有一句"等待超时"，下一轮排查还是靠猜：
    //    到底是请求没发出去（桩 404）、apps 全被客户端跳过（字段读错），
    //    还是根本渲染到另一棵树上。
    final texts = find
        .byType(Text)
        .evaluate()
        .map((e) => (e.widget as Text).data ?? '')
        .where((s) => s.isNotEmpty)
        .toList();
    fail('等待工作台渲染超时（服务端没回，或 apps 全被客户端跳过）\n'
        '  桩收到过的请求：${stub.calls.map((c) => '${c.method} ${c.path}').toList()}\n'
        '  此刻页面上的文字：$texts');
  }

  setUp(() async {
    stub = await ApiStub.start();
    Config.currentUrl = stub.baseUrl;
    ImApi().setToken('tok');
  });

  tearDown(() => stub.stop());

  testWidgets('组名用服务端下发的，不写死「工作」', (t) async {
    await pumpPhone(t, payload());
    expect(find.text('办公协同'), findsOneWidget);
    expect(find.text('自建'), findsOneWidget);
    expect(find.text('工作'), findsNothing);
  });

  testWidgets('不认识的内置 id 直接跳过（不是空白、也不是报错）', (t) async {
    await pumpPhone(t, payload());
    expect(find.text('未来的应用'), findsNothing);
    // 剩下的三个照常出现
    expect(find.text('考勤打卡'), findsOneWidget);
    expect(find.text('盘点'), findsOneWidget);
    expect(find.text('报修单'), findsOneWidget);
  });

  test('列数：手机固定 4 列，宽屏只放宽、不收窄', () {
    // 手机（含小屏手机）必须是 4 列 —— 3 列格子大得像卡片、2 列太宽，
    // 两者都不是企微/飞书那个"一排四个"的手感。
    for (final w in [320, 360, 390, 400, 430]) {
      expect(workbenchColumns(w.toDouble()), 4, reason: '宽度 $w 应是 4 列');
    }
    expect(workbenchColumns(599), 4);
    expect(workbenchColumns(600), 5);
    expect(workbenchColumns(820), 6);
    expect(workbenchColumns(1100), 8);
  });

  test('图标底色取服务端下发的 color（一排同色等于分不出谁是谁）', () {
    // 出厂色（server/src/apps.js）：inventory = #C0392B
    expect(
      workbenchAppColor({'color': '#C0392B'}),
      const Color(0xFFC0392B),
    );
    // 没下发 color 时用品牌色兜底，不是"变透明"或"变黑"
    expect(workbenchAppColor({'color': null}), AppColors.brand);
    // 下发了个解析不了的值：照样兜底，不炸
    expect(workbenchAppColor({'color': 'red'}), AppColors.brand);
  });

  testWidgets('格子底色真的画出来了（上面那条只验了算得对）', (t) async {
    await pumpPhone(t, payload());
    expect(
      find.byWidgetPredicate((w) =>
          w is Container &&
          w.decoration is BoxDecoration &&
          (w.decoration as BoxDecoration).color == const Color(0xFFC0392B)),
      findsOneWidget,
    );
  });

  test('搜索只匹配名称，不匹配 desc', () {
    final apps = <Map<String, dynamic>>[
      {'id': 'a', 'title': '盘点', 'desc': '每月 1 号全店盘一次', 'group': 'work'},
      {'id': 'b', 'title': '考勤打卡', 'desc': '', 'group': 'work'},
    ];
    expect(workbenchFilter(apps, '盘').map((a) => a['id']).toList(), ['a']);
    // desc 里那句"每月 1 号全店"不该被搜出来
    expect(workbenchFilter(apps, '全店'), isEmpty);
    // 空关键词原样返回，不是空列表
    expect(workbenchFilter(apps, ''), hasLength(2));
  });

  test('空组不显示；组外应用仍兜底显示', () {
    final apps = <Map<String, dynamic>>[
      {'id': 'a', 'title': '考勤打卡', 'group': 'work'},
      {'id': 'b', 'title': '自建的', 'group': 'shop'},
    ];
    final groups = <Map<String, Object?>>[
      {'key': 'work', 'label': '办公协同', 'sort': 10},
      {'key': 'empty', 'label': '空的', 'sort': 20},
    ];
    final s = workbenchSections(apps: apps, groups: groups);
    expect(s.map((x) => x['label']).toList(), ['办公协同', 'shop']);
  });

  testWidgets('分组顺序按服务端下发的 sort（管理员把「自建」拖到前面就该在最上面）', (t) async {
    await pumpPhone(t, payload(groups: const [
      {'key': 'custom', 'label': '自建', 'sort': 1},
      {'key': 'work', 'label': '办公协同', 'sort': 2},
    ]));
    // 分组标题在树里的先后 = 屏幕上从上到下的先后
    final titles = find.byWidgetPredicate((w) =>
            w is Text && (w.data == '办公协同' || w.data == '自建'))
        .evaluate()
        .map((e) => (e.widget as Text).data)
        .toList();
    expect(titles, ['自建', '办公协同']);
  });

  testWidgets('顶部公告显示服务端下发的文字', (t) async {
    await pumpPhone(t, payload());
    expect(find.text('明天盘点，全店 9 点前把货架归位'), findsOneWidget);
  });

  testWidgets('没配公告就不渲染这一块（不该编一条默认的出来）', (t) async {
    await pumpPhone(t, payload(notices: const []));
    expect(find.byIcon(Icons.campaign_outlined), findsNothing);
  });

  testWidgets('搜索只按名称过滤，过滤后仍走统一网格', (t) async {
    await pumpPhone(t, payload());
    await t.enterText(find.byType(TextField), '盘');
    await t.pumpAndSettle();
    // 只剩「盘点」；「考勤打卡」与自定义模块都不再出现
    expect(find.text('盘点'), findsOneWidget);
    expect(find.text('考勤打卡'), findsNothing);
    expect(find.byType(GridView), findsOneWidget);
  });
}
