import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xiaozhi_im_client/api.dart';
import 'package:xiaozhi_im_client/core/badges.dart';
import 'package:xiaozhi_im_client/core/config.dart';
import 'package:xiaozhi_im_client/core/read_bus.dart';
import 'package:xiaozhi_im_client/screens/conversations.dart';

import 'support/api_stub.dart';

/// 已读后「提示小点马上消失」的回归测试（2026-10-13 龙哥报的 bug：
/// 消息已经读了，但红点不是马上消失）。
///
/// ── 钉住的三件事 ────────────────────────────────────────────────
/// ① **本地即时清零**：chat 页 markRead 成功 → ReadBus 广播 → 会话列表
///    同步把该会话 unread/@我 抹掉并重算角标，**不等 WS 的 message:read 帧**
///    （宽屏同屏时 WS 往返那几百毫秒，就是龙哥看到的"读了还不消"）。
/// ② **不是本地撒谎**：清零之后必须再拉一次服务端真值校准 —— 防的是旧
///    markRead 响应晚到的竞态（清零后对方又发一条，不能把那条也吞成已读）。
/// ③ **不影响别人**：广播一个陌生会话 id 不能炸、不能动别的会话未读。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 与授权页测试同一套理由：ImApi 任何请求都会过 SessionManager →
  // SharedPreferences，没有 mock 会在测试结束后抛 MissingPluginException。
  SharedPreferences.setMockInitialValues({});

  late ApiStub stub;

  setUp(() async {
    stub = await ApiStub.start();
    Config.currentUrl = stub.baseUrl;
    ImApi().setToken('tok');
    Badges.instance.clear();
    // 🔴 故意不往 Storage 写 token：SocketService.connect() 读不到 token 会
    //    直接返回，测试里就不会真去连 WS。连不上会挂重连定时器，
    //    flutter_test 结束时会判 "A Timer is still pending" 失败，
    //    而报错信息完全看不出跟 WS 有关。
  });

  tearDown(() => stub.stop());

  Map<String, dynamic> convJson(int id, String title, int unread,
      {bool mention = false}) =>
      {
        'id': id,
        'type': 'dm',
        'title': title,
        'unread': unread,
        'has_mention': mention,
        'last_at': 1758300000000,
        'last_content': '在吗',
      };

  /// 把三个必需路由装上。conversations 路由是**有状态的**：第一次拉取返回
  /// 未读，之后返回 0 —— 模拟"markRead 已落库"的服务端真值。
  void stubBasics({int firstUnread = 3, bool firstMention = true}) {
    var convCalls = 0;
    stub.on('GET', '/auth/me',
        (_) => {'user': {'id': 7, 'username': 'me', 'nickname': '我', 'role': 'user'}});
    stub.on('GET', '/conversations', (_) {
      convCalls++;
      final unread = convCalls == 1 ? firstUnread : 0;
      return [
        convJson(101, '张三', unread, mention: convCalls == 1 && firstMention),
        convJson(102, '李四', 0),
      ];
    });
    stub.on('GET', '/friends', (_) => {'friends': <dynamic>[], 'pending': <dynamic>[]});
  }

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

  testWidgets('① markRead 广播后：红点与「有人@我」本地即时清零，角标同步归零',
      (t) async {
    stubBasics();
    await t.pumpWidget(const MaterialApp(home: ConversationsScreen()));
    await pumpUntil(t, () => find.text('张三').evaluate().isNotEmpty,
        why: '会话列表应加载出来');

    // 前置：3 条未读 + 有人@我 + 角标 3
    expect(find.text('3'), findsOneWidget);
    expect(find.text('有人@我'), findsOneWidget);
    expect(Badges.instance.unread.value, 3);

    // ---- 关键动作：chat 页 _markRead HTTP 成功后的广播 ----
    ReadBus.instance.fire(101);
    await t.pump(); // 本地清算是同步 setState，一帧就够

    // 即时生效，不等 WS 帧
    expect(find.text('3'), findsNothing, reason: '红点必须本地马上消失');
    expect(find.text('有人@我'), findsNothing);
    expect(Badges.instance.unread.value, 0);

    // ---- 校准：清零后会再拉一次服务端真值（双保险，不是本地撒谎）----
    await pumpUntil(t, () => stub.hits('GET', '/conversations') >= 2,
        why: '清零后应触发一次校准拉取');
    await t.pump();
    expect(stub.hits('GET', '/conversations'), 2);
    expect(find.text('3'), findsNothing, reason: '服务端确认已读，不能闪回来');
    expect(Badges.instance.unread.value, 0);
  });

  testWidgets('② 广播陌生会话 id：不炸、不动别人的未读、不触发校准拉取', (t) async {
    stubBasics(firstUnread: 3, firstMention: false);
    await t.pumpWidget(const MaterialApp(home: ConversationsScreen()));
    await pumpUntil(t, () => find.text('张三').evaluate().isNotEmpty,
        why: '会话列表应加载出来');

    ReadBus.instance.fire(999); // 列表里没有的会话
    await t.pump();

    expect(find.text('3'), findsOneWidget, reason: '没命中任何会话，未读不该动');
    expect(Badges.instance.unread.value, 3);
    expect(stub.hits('GET', '/conversations'), 1,
        reason: '没有可清零的会话，不该多打一次校准请求');
  });

  testWidgets('③ 已是清零态的会话再广播：不发校准请求（去重，别把服务端打爆）',
      (t) async {
    stubBasics(firstUnread: 0, firstMention: false);
    await t.pumpWidget(const MaterialApp(home: ConversationsScreen()));
    await pumpUntil(t, () => find.text('张三').evaluate().isNotEmpty,
        why: '会话列表应加载出来');
    expect(Badges.instance.unread.value, 0);

    ReadBus.instance.fire(101); // 本来就是 0 未读
    await t.pump();

    expect(stub.hits('GET', '/conversations'), 1,
        reason: '清零态重复广播不该触发额外拉取');
    expect(Badges.instance.unread.value, 0);
  });
}
