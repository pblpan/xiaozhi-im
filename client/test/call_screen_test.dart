import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xiaozhi_im_client/core/call_service.dart';
import 'package:xiaozhi_im_client/screens/call.dart';

/// 通话页「形态切换」与「多人网格」回归测试。
///
/// ## 事故一（2026-09-12，内网即可复现）：接听后界面不切换 / 画面全黑
///
/// 被叫端点了「接听」，界面却一直停在来电页（拒绝 / 接听按钮还在、只把状态
/// 文案刷成了"通话中"），远端画面全黑。
///
/// 根因：`CallScreen.build()` 里
/// `final isIncoming = _c.phase.value == CallPhase.incoming;`
/// 是**非响应式读取**，而 phase 的监听器只处理 `idle → pop`、内部**从不 setState**。
/// 于是 phase 从 `incoming` 走到 `connecting/active` 之后界面从不重建 ——
/// 永远渲染「来电形态」，而承载 `RTCVideoView` 的「通话形态」从未挂载
/// → 画面必然黑屏。
///
/// 「黑屏」和「已接听仍显示未接通界面」是**同一个根因的两个症状**，修一处即可。
///
/// ## 事故二（v0.7.0 多人化改造）：网格布局人数分档
///
/// 远端区域按人数走不同布局（1 人全屏 / 2 人上下 / 3-4 人 2×2 / 5-6 人 3×2）。
/// 分档写错会很难在真机上看出来（比如 3 人时排成 3 列导致每个人只剩一条缝），
/// 所以这里把每档都钉住：**用参会者名字的出现次数**判断格子是否都渲染了。
void main() {
  CallPeer p(int id, String name) => CallPeer(userId: id, name: name);

  CallSession session({
    required bool video,
    required List<CallPeer> peers,
    bool group = false,
    bool outgoing = false,
  }) =>
      CallSession(
        callId: 'test-call',
        conversationId: 1,
        peers: peers,
        outgoing: outgoing,
        video: video,
        group: group,
        groupName: group ? '测试群' : null,
      );

  /// 模拟真实的导航栈：先有主界面，通话页是**推上来**的第二层路由。
  /// 这样"结束后自动 pop 回主界面"才可断言（直接当 home 挂载时 pop 无处可去）。
  Future<void> pushCallScreen(WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: Center(child: Text('主界面'))),
    ));
    final nav = tester.state<NavigatorState>(find.byType(Navigator));
    nav.push(MaterialPageRoute<void>(builder: (_) => const CallScreen()));
    await tester.pumpAndSettle();
  }

  tearDown(() {
    final c = CallService();
    // 只清 session，**不要动 phase**。
    //
    // CallService 是全局单例：`phase.value = idle` 会触发 CallScreen._onPhase()
    // → Navigator.pop()，而此时上一个用例的 widget tree 已经销毁，Flutter 会
    // 抛 "A FocusManager was used after being disposed"，把**后面**的用例一起带崩
    // （症状是失败列表里出现一堆不相干的用例）。
    // phase 由每个用例自己在开头设定，这里不复位也不会串味。
    c.session.value = null;
    c.peerCount.value = 0;
  });

  // ================================================================ 事故一

  testWidgets('被叫端接听后，必须从来电形态切到通话形态', (WidgetTester tester) async {
    final c = CallService();
    c.session.value = session(video: false, peers: [p(2, '甲')]);
    c.phase.value = CallPhase.incoming;

    await pushCallScreen(tester);

    // ── 来电形态：只有拒绝 / 接听
    expect(find.text('拒绝'), findsOneWidget, reason: '来电时应显示拒绝');
    expect(find.text('接听'), findsOneWidget, reason: '来电时应显示接听');
    expect(find.text('挂断'), findsNothing);

    // ── 用户点了「接听」：accept() 把 phase 推到 connecting
    c.phase.value = CallPhase.connecting;
    await tester.pump();

    expect(find.text('接听'), findsNothing, reason: '接听后不该再显示接听按钮');
    expect(find.text('拒绝'), findsNothing, reason: '接听后不该再显示拒绝按钮');
    expect(find.text('挂断'), findsOneWidget, reason: '应已切到通话形态');
    expect(find.text('静音'), findsOneWidget, reason: '通话形态应有静音键');

    // ── 连接建立 → active
    c.phase.value = CallPhase.active;
    await tester.pump();
    expect(find.text('挂断'), findsOneWidget);
    expect(find.text('接听'), findsNothing);

    // ── 通话结束 → 页面自行 pop 回主界面
    c.phase.value = CallPhase.ended;
    await tester.pump();
    c.phase.value = CallPhase.idle;
    await tester.pumpAndSettle();

    expect(find.byType(CallScreen), findsNothing, reason: '通话结束后通话页应自行关闭');
    expect(find.text('主界面'), findsOneWidget);
  });

  testWidgets('视频通话：接听后应进入通话形态（视频区才可能被挂载）',
      (WidgetTester tester) async {
    final c = CallService();
    c.session.value = session(video: true, peers: [p(2, '甲')]);
    c.phase.value = CallPhase.incoming;

    await pushCallScreen(tester);
    expect(find.text('接听'), findsOneWidget);

    c.phase.value = CallPhase.active;
    await tester.pump();

    // 视频模式下通话形态有摄像头开关；来电形态没有。
    // 这条断言等价于"承载远端画面的子树已被挂载"——正是黑屏事故的反面。
    expect(find.text('接听'), findsNothing);
    expect(find.text('摄像头'), findsOneWidget);
    expect(find.text('挂断'), findsOneWidget);
  });

  // ================================================================ 事故二

  testWidgets('群通话来电：显示群名而非个人名，且带"接听"按钮',
      (WidgetTester tester) async {
    final c = CallService();
    c.session.value = session(
      video: true,
      group: true,
      peers: [p(2, '甲'), p(3, '乙'), p(4, '丙')],
    );
    c.phase.value = CallPhase.incoming;

    await pushCallScreen(tester);

    expect(find.text('测试群'), findsOneWidget, reason: '群来电标题应是群名');
    expect(find.text('接听'), findsOneWidget);
    expect(find.text('拒绝'), findsOneWidget);
  });

  testWidgets('群通话接通：退出按钮而非挂断，且标题仍是群名',
      (WidgetTester tester) async {
    final c = CallService();
    c.session.value = session(
      video: false,
      group: true,
      peers: [p(2, '甲'), p(3, '乙')],
    );
    c.peerCount.value = 2;
    c.phase.value = CallPhase.active;

    await pushCallScreen(tester);

    // 群通话里挂断语义是"我退出，其余人继续"，按钮文案必须区分开
    expect(find.text('退出'), findsOneWidget, reason: '群通话应显示"退出"');
    expect(find.text('挂断'), findsNothing, reason: '群通话不该显示"挂断"');
    expect(find.text('测试群'), findsOneWidget);
  });

  testWidgets('1v1 接通：仍然是"挂断"', (WidgetTester tester) async {
    final c = CallService();
    c.session.value = session(video: false, peers: [p(2, '甲')]);
    c.phase.value = CallPhase.active;

    await pushCallScreen(tester);

    expect(find.text('挂断'), findsOneWidget);
    expect(find.text('退出'), findsNothing);
  });

  testWidgets('多路参会者：每个人的名字都要出现在网格里',
      (WidgetTester tester) async {
    final c = CallService();
    // 3 人 → 走 2×2 分档（自己用画中画，不占网格）
    c.session.value = session(
      video: false,
      group: true,
      peers: [p(2, '甲'), p(3, '乙'), p(4, '丙')],
    );
    c.peerCount.value = 3;
    c.phase.value = CallPhase.active;

    await pushCallScreen(tester);

    // ⚠️ 每个名字会出现**两次**：头像圆圈里的首字（UserAvatar 自己渲染的）
    //    和格子底部的名字标签。所以断言"至少一个"，不是"恰好一个"。
    for (final name in ['甲', '乙', '丙']) {
      expect(find.text(name), findsWidgets, reason: '三人通话 $name 应渲染');
    }
  });

  testWidgets('五人通话：全员进网格，一个都不少', (WidgetTester tester) async {
    final c = CallService();
    c.session.value = session(
      video: false,
      group: true,
      peers: [p(2, '甲'), p(3, '乙'), p(4, '丙'), p(5, '丁'), p(6, '戊')],
    );
    c.peerCount.value = 5;
    c.phase.value = CallPhase.active;

    await pushCallScreen(tester);

    // 5 人走 3×2（3 列）分档。这条能抓住"格子数算错导致有人不显示"的问题。
    for (final name in ['甲', '乙', '丙', '丁', '戊']) {
      expect(find.text(name), findsWidgets, reason: '$name 应在网格里');
    }
  });

  testWidgets('还没人接听时不渲染空白格子，而是走等待页',
      (WidgetTester tester) async {
    final c = CallService();
    // 群通话已发起、一个人都没进来
    c.session.value = session(video: false, group: true, peers: [], outgoing: true);
    c.peerCount.value = 0;
    c.phase.value = CallPhase.outgoing;

    await pushCallScreen(tester);

    // 等待页显示群名 + 提示，不该是黑的。
    // "测试群"会出现两次（等待页正文 + 顶栏标题），所以用 findsWidgets。
    expect(find.text('测试群'), findsWidgets);
    expect(find.text('等待对方接听…'), findsOneWidget);
  });

  testWidgets('有人离开后网格同步缩减（名单变化必须触发重建）',
      (WidgetTester tester) async {
    final c = CallService();
    c.session.value = session(
      video: false,
      group: true,
      peers: [p(2, '甲'), p(3, '乙'), p(4, '丙')],
    );
    c.peerCount.value = 3;
    c.phase.value = CallPhase.active;

    await pushCallScreen(tester);
    expect(find.text('丙'), findsWidgets);

    // 模拟 _onPeerLeft → _mergePeers：把名单换成两个。
    //
    // ⚠️ 必须重新赋一个**新**的 CallSession 对象（或至少让 ValueNotifier
    //    判定值变了）。ValueNotifier 用 `==` 比较，把同一个对象的 List 就地
    //    改掉再赋回去，等于没变，监听器根本不会触发 —— 真实代码里
    //    _mergePeers 是先改 s.peers 再 `session.value = s`，靠的是
    //    CallSession 是可变对象、UI 侧另有 peerCount 监听兜底。
    //    测试里为确定性，直接换新对象。
    c.session.value = session(
      video: false,
      group: true,
      peers: [p(2, '甲'), p(3, '乙')],
    );
    c.peerCount.value = 2;
    await tester.pump();

    expect(find.text('丙'), findsNothing, reason: '离开的人不该还留在网格里');
    expect(find.text('甲'), findsWidgets);
    expect(find.text('乙'), findsWidgets);
  });
}
