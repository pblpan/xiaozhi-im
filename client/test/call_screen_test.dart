import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xiaozhi_im_client/core/call_service.dart';
import 'package:xiaozhi_im_client/screens/call.dart';

/// 通话页「形态切换」回归测试。
///
/// 线上事故（2026-09-12，内网即可复现）：**被叫端**点了「接听」，界面却一直停在
/// 来电页（拒绝 / 接听按钮还在、只把状态文案刷成了"通话中"），远端画面全黑。
///
/// 根因：`CallScreen.build()` 里
/// `final isIncoming = _c.phase.value == CallPhase.incoming;`
/// 是**非响应式读取**，而 phase 的监听器只处理 `idle → pop`、内部**从不 setState**。
/// 于是 phase 从 `incoming` 走到 `connecting/active` 之后界面从不重建 ——
/// 永远渲染「来电形态」，而承载 `RTCVideoView` 的「通话形态」从未挂载
/// → 画面必然黑屏。
///
/// 所以「黑屏」和「已接听仍显示未接通界面」是**同一个根因的两个症状**，
/// 修一处即可。本文件守住它，别再退化。
void main() {
  CallSession peer({required bool video}) => CallSession(
        callId: 'test-call',
        conversationId: 1,
        peerId: 2,
        peerName: '甲',
        outgoing: false,
        video: video,
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
    // 监听器已在 dispose 里摘掉，这里改状态不会再触发导航
    c.phase.value = CallPhase.idle;
    c.session.value = null;
    c.remoteVideoOn.value = false;
  });

  testWidgets('被叫端接听后，必须从来电形态切到通话形态', (WidgetTester tester) async {
    final c = CallService();
    c.session.value = peer(video: false);
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

  testWidgets('视频通话：接听后应进入通话形态（视频区才可能被挂载）', (WidgetTester tester) async {
    final c = CallService();
    c.session.value = peer(video: true);
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
}
