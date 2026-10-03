import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xiaozhi_im_client/api.dart';
import 'package:xiaozhi_im_client/core/config.dart';
import 'package:xiaozhi_im_client/screens/inventory_approval.dart';

import 'support/api_stub.dart';

/// 审批中心（M2/P2）的测试。
///
/// ── 钉住的是哪几件事 ────────────────────────────────────────────
/// ① **能不能批，由服务端的 `can_approve` 决定**：不能批就**不显示**按钮，
///    而不是显示一个点下去 403 的按钮。（要求里写得很清楚：
///    "不是看按钮隐藏"——隐藏只是界面礼貌，拦住是服务端的事，两边各司其职。）
/// ② **驳回理由必填**：空理由时「驳回」必须**点不动**；填了才可点，
///    而且理由要真的进请求体 —— 提交人全靠这句话知道回去改什么。
/// ③ 通过要二次确认，且**通过后必须重新拉取**（本地自己抹掉一行不算数）。
/// ④ 「我提交的」里被驳回的单子**必须把理由摆出来**（反向：没理由的不该凭空多一段）。
///
/// ── 这个测试里踩过的两个坑（都不是产品问题，但都会长成假失败）────
/// · 默认视口 800x600 太矮 → 长列表下半段**不会被构建**，`find.text` 找不到，
///   看着像"界面没写"；所以先放大视口。
/// · 结束时 **SnackBar 的 4 秒定时器还挂着** → flutter_test 报
///   "A Timer is still pending"，报错完全看不出跟 SnackBar 有关。
///   所以每个用例收尾都 `drain()` 一下把假时钟走完。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 🔴 2026-10-03 补：shared_preferences mock（防 MultiEnterprise 改造后回退）。
  //   ImApi._h 改为读激活档案 token 后，任何走 ImApi 的路径都会碰
  //   SessionManager → SharedPreferences.getInstance()；单元测试里没有 plugin
  //   实现，会抛 MissingPluginException，且是在测试**结束后**才抛
  //   （"failed after test completion"），几个用例一起挂、看不出跟偏好有关。
  //   修法是补 mock，而不是把 _h 改回去 —— 改回去等于把
  //   「切企业后所有请求 401」那个 bug 请回来。
  SharedPreferences.setMockInitialValues({});

  late ApiStub stub;

  setUp(() async {
    stub = await ApiStub.start();
    Config.currentUrl = stub.baseUrl;
    ImApi().setToken('tok');
  });

  tearDown(() => stub.stop());

  Future<void> pumpUntil(WidgetTester tester, bool Function() ok,
      {int tries = 150, required String why}) async {
    for (var i = 0; i < tries; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 15)));
      await tester.pump(const Duration(milliseconds: 20));
      if (ok()) return;
    }
    fail('等待超时：$why');
  }

  /// 收尾：把 SnackBar 的 4 秒定时器走完，否则测试收尾会因"还有定时器在跑"失败。
  Future<void> drain(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 5));
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump(const Duration(milliseconds: 50));
  }

  Map<String, dynamic> pendingItem({
    int id = 1,
    String? title = '抽盘单 Z01-20260920-01',
    String? reason,
    String status = 'pending',
  }) =>
      {
        'id': id,
        'kind': 'stocktake',
        'title': title,
        'ref': 'Z01-20260920-01',
        'payload': {'zone_code': 'Z01', 'phase': 3, 'diff': 4},
        'status': status,
        'submitter_name': '李四',
        'created_at': 1758300000000,
        if (reason != null) 'reject_reason': reason,
        if (status != 'pending') 'decided_by_name': '管理员',
        if (status != 'pending') 'decided_at': 1758400000000,
      };

  /// 打开页面并**等它真的读完**。`ready` 必须是"数据已渲染"的判据。
  ///
  /// ⚠️ 两个都不行的判据（都踩过）：
  ///    · "标签页文字出现了" —— Tab 是静态的，还在转圈时它就在了，
  ///      等待会**立刻返回**，后面所有断言都在"还没加载完"的界面上跑，
  ///      表现出来是"什么都找不到"，让人以为界面是空的；
  ///    · "转圈没了" —— `RefreshIndicator` 里那个 `RefreshProgressIndicator`
  ///      是 `CircularProgressIndicator` 的子类，而且**一直建在树里**
  ///      （只是被 SizeTransition 压成 0 高），所以这个判据**永远不成立**。
  Future<void> open(WidgetTester tester, {required bool Function() ready}) async {
    tester.view.physicalSize = const Size(1000, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MaterialApp(
      home: InventoryApprovalScreen(),
    ));
    await pumpUntil(tester, ready, why: '审批中心应当读完数据并渲染出来');
  }

  /// 找到弹窗里的按钮（卡片上也有同名按钮，不限定范围会"找到 2 个"）。
  Finder inDialog(String text) => find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(TextButton, text),
      );

  testWidgets('① 能不能批由服务端说了算：不能批就不给按钮', (tester) async {
    var canApprove = false;
    stub.on('GET', '/api/approval/pending', (_) => {
          'can_approve': canApprove,
          'items': [pendingItem()],
        });
    stub.on('GET', '/api/approval/mine', (_) => {'items': <Map<String, dynamic>>[]});

    await open(tester,
        ready: () => find.text('抽盘单 Z01-20260920-01').evaluate().isNotEmpty);

    // 单子看得见（不能批 ≠ 看不见）
    expect(find.text('抽盘单 Z01-20260920-01'), findsOneWidget);
    // 但不能批：一个「通过」/「驳回」都不该有
    expect(find.text('通过'), findsNothing);
    expect(find.text('驳回'), findsNothing);
    expect(find.textContaining('只能看、不能批'), findsOneWidget);

    // 反向：服务端说能批 → 按钮必须都出来（读死 canApprove 的话这里会红）
    canApprove = true;
    await tester.tap(find.byTooltip('刷新'));
    await pumpUntil(tester, () => find.text('通过').evaluate().isNotEmpty,
        why: 'can_approve=true 时必须给出「通过」按钮');
    expect(find.text('驳回'), findsOneWidget);
    expect(find.textContaining('只能看、不能批'), findsNothing);
  });

  testWidgets('② 驳回理由必填：空理由点不动，填了才发得出去', (tester) async {
    var rejected = false;
    stub.on('GET', '/api/approval/pending', (_) => {
          'can_approve': true,
          'items': rejected ? <Map<String, dynamic>>[] : [pendingItem()],
        });
    stub.on('GET', '/api/approval/mine', (_) => {'items': <Map<String, dynamic>>[]});
    stub.on('POST', '/api/approval/1/reject', (c) {
      rejected = true;
      return {
        'approval': {
          ...pendingItem(status: 'rejected'),
          'reject_reason': (c.body as Map)['reason'],
        }
      };
    });

    await open(tester,
        ready: () => find.text('抽盘单 Z01-20260920-01').evaluate().isNotEmpty);

    // 卡片上的「驳回」→ 开理由框
    await tester.tap(find.widgetWithText(TextButton, '驳回'));
    await pumpUntil(tester, () => find.byKey(const Key('reject-reason')).evaluate().isNotEmpty,
        why: '驳回应当弹出理由输入框');

    // 空理由：按钮必须是禁用的（可点但服务端会拒 = 让人白填一次）
    final emptyBtn = tester.widget<TextButton>(inDialog('驳回'));
    expect(emptyBtn.onPressed, isNull,
        reason: '理由为空时「驳回」必须点不动');

    // 输入理由后**必须变成可点** —— 这里会因为"输入框不触发重建"而红，
    // 那正是线上会出现的那种 bug（输了字还是点不动）
    await tester.enterText(
        find.byKey(const Key('reject-reason')), '数量不符，请复称后重扫');
    await tester.pump();
    final filledBtn = tester.widget<TextButton>(inDialog('驳回'));
    expect(filledBtn.onPressed, isNotNull,
        reason: '填了理由之后「驳回」必须可用');

    await tester.tap(inDialog('驳回'));
    await pumpUntil(tester, () => stub.hits('POST', '/api/approval/1/reject') == 1,
        why: '确认驳回必须真的发请求');
    expect((stub.last('POST', '/api/approval/1/reject').body as Map)['reason'],
        '数量不符，请复称后重扫');
    // 带上登录态（服务端要按人来判定能不能审）
    expect(stub.last('POST', '/api/approval/1/reject').authorization, 'Bearer tok');

    // 驳回后必须重新拉取（判据取"服务端已经没有这条了、界面跟着空掉"，
    // 不取"请求发出去了" —— 后者不证明回包被处理了，
    // 而没处理完的请求会让收尾报"A Timer is still pending"，极难定位）
    await pumpUntil(
        tester,
        () =>
            stub.hits('GET', '/api/approval/pending') >= 2 &&
            find.text('没有待审批的单子。').evaluate().isNotEmpty,
        why: '驳回之后要重新拉取待审列表');

    await drain(tester);
  });

  testWidgets('③ 通过：二次确认 + 通过后重新拉取', (tester) async {
    var approved = false;
    stub.on('GET', '/api/approval/pending', (_) => {
          'can_approve': true,
          'items': approved ? <Map<String, dynamic>>[] : [pendingItem()],
        });
    stub.on('GET', '/api/approval/mine', (_) => {'items': <Map<String, dynamic>>[]});
    stub.on('POST', '/api/approval/1/approve', (_) {
      approved = true;
      return {'approval': pendingItem(status: 'approved')};
    });

    await open(tester,
        ready: () => find.text('抽盘单 Z01-20260920-01').evaluate().isNotEmpty);
    await tester.tap(find.widgetWithText(FilledButton, '通过'));
    await pumpUntil(tester, () => find.text('再想想').evaluate().isNotEmpty,
        why: '通过前要二次确认');

    await tester.tap(inDialog('通过'));
    await pumpUntil(tester, () => stub.hits('POST', '/api/approval/1/approve') == 1,
        why: '确认通过必须真的发请求');
    // 重新拉取：服务端已经没有这条了，界面必须跟着空掉
    await pumpUntil(
        tester,
        () =>
            stub.hits('GET', '/api/approval/pending') >= 2 &&
            find.text('抽盘单 Z01-20260920-01').evaluate().isEmpty,
        why: '通过之后要重新拉取，不能靠本地抹掉那一行');

    await drain(tester);
  });

  testWidgets('④ 我提交的：被驳回的单子必须把理由摆出来', (tester) async {
    stub.on('GET', '/api/approval/pending',
        (_) => {'can_approve': true, 'items': <Map<String, dynamic>>[]});
    stub.on('GET', '/api/approval/mine', (_) => {
          'items': [
            pendingItem(id: 1, title: '抽盘单 A', status: 'rejected', reason: '数量不符，请复称'),
            // 另一张被驳回但**没有**理由（手改过库的老数据）：不该凭空长出一段
            pendingItem(id: 2, title: '抽盘单 B', status: 'rejected'),
          ],
        });

    await open(tester,
        ready: () => find.text('没有待审批的单子。').evaluate().isNotEmpty);
    await tester.tap(find.text('我提交的'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('驳回理由：数量不符，请复称'), findsOneWidget);
    // 只有一条有理由 → 说明理由是按条目渲染的，不是一个写死的标题
    expect(find.textContaining('驳回理由：'), findsOneWidget);
    expect(find.text('已驳回'), findsNWidgets(2));

    // 待审的才给「撤回」；这两条都已经审完了，一个都不该有
    expect(find.text('撤回'), findsNothing);
  });
}
