import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xiaozhi_im_client/api.dart';
import 'package:xiaozhi_im_client/core/config.dart';
import 'package:xiaozhi_im_client/screens/inventory_grant.dart';

import 'support/api_stub.dart';

/// 抽盘授权页的测试。
///
/// ── 钉住的是哪几件事 ────────────────────────────────────────────
/// ① **生效中 / 已解除（留痕）两段都按数据渲染**：解除 ≠ 删除，
///    历史那一段必须真的出现（去掉那条 revoked 数据就该消失 —— 反向也测了）。
/// ② **没有管理权就不给按钮**：不给一个点下去 403 的按钮，
///    而是明说"只能查看"。（要求里写得很清楚：不是看按钮隐藏，
///    是服务端拦住；界面这里负责**别让用户去撞墙**。）
/// ③ 点「授权」**真的发出 POST**，而且 `user_id` 是选中的那个人；
///    授权完刷新后那人进「生效中」—— 不是本地自己改一行算是成功。
/// ④ 解除要二次确认，且确认框里必须写明"**记录不会删掉**"（这是留痕的依据）；
///    点"不解除"**一个请求都不能发**。
/// ⑤ 拿不到服务端时**明说 + 给重试**，不是静默当成"没授权"。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ApiStub stub;
  const path = '/api/stocktake/zone/Z01/grant';

  setUp(() async {
    stub = await ApiStub.start();
    Config.currentUrl = stub.baseUrl;
    ImApi().setToken('tok');
  });

  tearDown(() => stub.stop());

  Future<void> pumpUntil(WidgetTester tester, bool Function() ok,
      {int tries = 150, required String why}) async {
    for (var i = 0; i < tries; i++) {
      // runAsync：把真实时间借给 HTTP（真 socket），假时钟下永远等不到回包
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 15)));
      await tester.pump(const Duration(milliseconds: 20));
      if (ok()) return;
    }
    fail('等待超时：$why');
  }

  /// 收尾：把还在跑的假时钟定时器走完。
  ///
  /// 🔴 SnackBar 自带一个 4 秒的自动消失定时器，测试结束时它还挂着，
  ///    flutter_test 会直接判失败（"A Timer is still pending"）——
  ///    报错信息完全看不出跟 SnackBar 有关，很容易被当成是页面的 bug。
  Future<void> drain(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 5));
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump(const Duration(milliseconds: 50));
  }

  Future<void> open(WidgetTester tester) async {
    // 屏幕放大到 1000x2400：这一页是长列表（生效中 / 名册 / 留痕三段），
    // 默认 800x600 下面那两段**根本不会被构建**，`find.text` 找不到它们 ——
    // 那不是界面坏了，是它压根没进视口（ListView 只建可见的）。
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MaterialApp(
      home: InventoryGrantScreen(zoneCode: 'Z01', zoneName: '生鲜区'),
    ));
    await pumpUntil(tester, () => find.text('生效中').evaluate().isNotEmpty,
        why: '授权页应当读完服务端数据并渲染出「生效中」那一段');
  }

  Map<String, dynamic> member(int id, String name, String no) => {
        'id': id,
        'username': no,
        'nickname': name,
        'dept_name': '门店',
        'position_name': '理货',
      };

  /// 名册：张三(7,生效中) / 李四(8,已解除) / 王五(9,还没授权)
  void stubRoster({List<int> live = const [7]}) {
    stub.on('GET', '/api/orgs/my', (_) => {
          'org': {'id': 1, 'name': '测试门店'},
          'members': [member(7, '张三', 'A001'), member(8, '李四', 'A002'), member(9, '王五', 'A003')],
        });
    stub.on('GET', path, (_) {
      final rows = <Map<String, dynamic>>[
        {
          'user_id': 7,
          'username': 'A001',
          'nickname': '张三',
          'granted_by': 1,
          'granted_at': 1758300000000,
          'revoked_at': null,
        },
        {
          'user_id': 8,
          'username': 'A002',
          'nickname': '李四',
          'granted_by': 1,
          'granted_at': 1758200000000,
          'revoked_at': 1758500000000,
        },
      ];
      return {
        'zone_code': 'Z01',
        'mine': true,
        'is_admin': false,
        'can_manage': true,
        'live_user_ids': live,
        'grants': rows,
      };
    });
  }

  testWidgets('① 生效中与已解除（留痕）都按数据渲染', (tester) async {
    stubRoster();
    await open(tester);

    expect(find.text('生效中'), findsOneWidget);
    expect(find.text('已解除（留痕）'), findsOneWidget);
    // 两段各自带人数：生效中 1、留痕 1
    expect(find.textContaining('这些记录不会删除'), findsOneWidget);

    // 生效中那行是张三、留痕那行是李四
    expect(find.text('张三'), findsWidgets);
    expect(find.text('李四'), findsWidgets);

    // 反向：把"已解除"那条数据删掉，留痕那一段**必须消失**
    // （否则这段就是写死的装饰品，不是数据驱动的）
    stub.on('GET', path, (_) => {
          'zone_code': 'Z01',
          'mine': true,
          'is_admin': false,
          'can_manage': true,
          'live_user_ids': [7],
          'grants': [
            {
              'user_id': 7,
              'username': 'A001',
              'nickname': '张三',
              'granted_at': 1758300000000,
              'revoked_at': null,
            }
          ],
        });
    await tester.pumpWidget(const SizedBox());
    await open(tester);
    expect(find.text('已解除（留痕）'), findsNothing);
  });

  testWidgets('② 没有管理权：不给按钮，明说只能查看', (tester) async {
    stub.on('GET', '/api/orgs/my', (_) => {
          'org': {'id': 1, 'name': '测试门店'},
          'members': [member(9, '王五', 'A003')],
        });
    stub.on('GET', path, (_) => {
      'zone_code': 'Z01',
      'mine': false,
      'is_admin': false,
      'can_manage': false,
      'live_user_ids': <int>[],
      'grants': <Map<String, dynamic>>[],
    });
    await open(tester);

    expect(find.text('只能查看'), findsOneWidget);
    expect(find.text('可授权/解除'), findsNothing);
    expect(find.textContaining('只能查看名单'), findsOneWidget);
    // 核：一个「授权」按钮都不该有（连"点了会 403"的按钮也不给）
    expect(find.text('授权'), findsNothing);
    expect(find.text('无权限操作'), findsOneWidget);
  });

  testWidgets('③ 点授权：POST 出去且 user_id 是被选的人，刷新后进「生效中」', (tester) async {
    var live = <int>[7];
    stub.on('GET', '/api/orgs/my', (_) => {
          'org': {'id': 1, 'name': '测试门店'},
          'members': [member(9, '王五', 'A003')],
        });
    stub.on('GET', path, (_) => {
      'zone_code': 'Z01',
      'mine': true,
      'is_admin': true,
      'can_manage': true,
      'live_user_ids': live,
      'grants': [
        if (live.contains(9))
          {
            'user_id': 9,
            'username': 'A003',
            'nickname': '王五',
            'granted_by': 1,
            'granted_at': 1758600000000,
            'revoked_at': null,
          }
      ],
    });
    stub.on('POST', path, (c) {
      final id = ((c.body as Map)['user_id'] as num).toInt();
      live = [...live, id];
      return {'ok': true, 'already': false, 'user': {'id': id}};
    });

    await open(tester);
    await tester.tap(find.text('授权'));
    await pumpUntil(tester, () => stub.hits('POST', path) == 1,
        why: '点「授权」必须真的发出 POST');
    expect((stub.last('POST', path).body as Map)['user_id'], 9);

    // 刷新后王五进「生效中」→ 名册那一栏他变成「已授权」
    await pumpUntil(tester, () => find.text('已授权').evaluate().isNotEmpty,
        why: '授权后应重新拉取，并把王五标成已授权');

    await drain(tester);
  });

  testWidgets('④ 解除：确认框写明留痕；点"不解除"一个请求都不发', (tester) async {
    var live = <int>[7];
    stub.on('GET', '/api/orgs/my', (_) => {
          'org': {'id': 1, 'name': '测试门店'},
          'members': [member(7, '张三', 'A001')],
        });
    stub.on('GET', path, (_) => {
      'zone_code': 'Z01',
      'mine': true,
      'is_admin': false,
      'can_manage': true,
      'live_user_ids': live,
      'grants': [
        {
          'user_id': 7,
          'username': 'A001',
          'nickname': '张三',
          'granted_by': 1,
          'granted_at': 1758300000000,
          'revoked_at': live.contains(7) ? null : 1758700000000,
        }
      ],
    });
    stub.on('DELETE', path, (c) {
      live = <int>[];
      return {'ok': true, 'revoked': 1, 'user_id': c.query['user_id']};
    });

    await open(tester);
    await tester.tap(find.text('解除'));
    await pumpUntil(tester, () => find.text('不解除').evaluate().isNotEmpty,
        why: '解除要有二次确认');

    // 确认框必须说清"记录不会删掉" —— 这是"留痕"这套设计的界面依据
    expect(find.textContaining('不会删掉'), findsOneWidget);

    await tester.tap(find.text('不解除'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(stub.hits('DELETE', path), 0,
        reason: '点"不解除"就不能发任何请求');

    // 真的确认一次
    await tester.tap(find.text('解除'));
    await pumpUntil(tester, () => find.text('不解除').evaluate().isNotEmpty,
        why: '再开一次确认');
    // 只能点确认框里那个「解除」：列表行上也有一个同名按钮，
    // 不限定范围会"找到 2 个"直接报错。
    await tester.tap(find.descendant(
      of: find.byType(AlertDialog),
      matching: find.widgetWithText(TextButton, '解除'),
    ));
    await pumpUntil(tester, () => stub.hits('DELETE', path) == 1,
        why: '确认解除必须真的发 DELETE');
    expect(stub.last('DELETE', path).query['user_id'], '7');

    // 必须**重新拉一次**才算数（本地自己改一行不算成功）。
    // 判据取"重新拉回来的数据已经渲染出来了"（生效中空了），
    // 而不是"服务端收到了请求" —— 后者只证明发出去了，不证明回来了。
    await pumpUntil(
        tester,
        () =>
            stub.hits('GET', path) >= 2 &&
            find.textContaining('目前没有人被单独授权').evaluate().isNotEmpty,
        why: '解除后要重新拉授权现状并渲染出来');

    await drain(tester);
  });

  testWidgets('⑤ 服务端不通：明说拿不到 + 给重试，不静默当成没授权', (tester) async {
    stub.on('GET', path,
        (_) => const StubResponse(500, {'error': '服务器开小差了'}));
    stub.on('GET', '/api/orgs/my',
        (_) => {'org': null, 'members': <Map<String, dynamic>>[]});

    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MaterialApp(
      home: InventoryGrantScreen(zoneCode: 'Z01', zoneName: '生鲜区'),
    ));
    await pumpUntil(tester, () => find.text('重试').evaluate().isNotEmpty,
        why: '拿不到授权现状时要给重试，而不是装作"没人有权"');

    expect(find.textContaining('服务器开小差了'), findsOneWidget);
    expect(find.textContaining('只有连上服务器才能看和改'), findsOneWidget);
    // 核：这种状态下不应该出现"目前没有人被单独授权"这种会被误读成结论的话
    expect(find.textContaining('目前没有人被单独授权'), findsNothing);
  });
}
