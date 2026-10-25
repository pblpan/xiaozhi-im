// 控制端画布渲染复现测试（龙哥 2026-10-25 真机"一片漆黑、缩放条/诊断行全无"）
//
// 【这个测试要抓的 bug】
// 真机截图里：顶栏"已连接"、窗口模式栏正常，但**舞台整段纯黑**，
// 连无条件渲染的缩放条（1.0x / ＋ / 适应窗口）和诊断行都不见。
// 同一份代码在另一台设备/另一次会话里却渲染正常 —— 所以要把
// `RemoteControlScreen` 用**可控的假会话状态**泵出来，看组件树到底给不给画面。
//
// 【怎么用】
// 服务单例的字段除了 RTCVideoRenderer（构造是轻的，重活在 initialize()）
// 全是 ValueNotifier / 计数器，测试里可以直接摆状态。
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:xiaozhi_im_client/core/remote_assist.dart';
import 'package:xiaozhi_im_client/screens/remote.dart';

/// 一张能解的真 JPEG（64x32 红块），用来喂自研画面通道。
/// 测试里现编码，不内嵌字节 —— 手写的 JPEG 字节几乎一定是坏的。
final Uint8List _kJpeg = () {
  final im = img.Image(width: 64, height: 32);
  img.fill(im, color: img.ColorRgb8(220, 30, 30));
  return Uint8List.fromList(img.encodeJpg(im, quality: 80));
}();

void main() {
  final svc = RemoteAssistService.instance;

  setUp(() {
    svc.phase.value = RemotePhase.active;
    svc.session.value = const RemoteSession(
      id: 'sess-test',
      hostId: 1,
      controllerId: 2,
      mode: 'attended',
      hostName: '我的电脑',
      controllerName: '我',
    );
    svc.windowMode.value = false;
    svc.currentWindow.value = null;
    svc.frameJpeg.value = null;
    svc.frameSize.value = null;
    svc.reconnecting.value = false;
    svc.diag.value = '';
    // 诊断计数：单例是跨测试共享的，不归零会互相污染（③ 会真实解码加计数）
    svc.framesFragIn = 0;
    svc.framesIn = 0;
    svc.framesDecoded = 0;
    svc.framesDecodeFail = 0;
    svc.frameRecvDcState = 'none';
    svc.hostStatsText.value = '';
  });

  Future<void> _pumpScreen(WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: RemoteControlScreen()));
    await tester.pump();
  }

  /// 收尾：先把 initState 里那个 200ms 聚焦定时器烧完，再卸掉整棵树
  /// （诊断行的 1s 周期定时器随 dispose 取消），否则 testWidgets 的
  /// "pending timers" 不变量会假红。
  Future<void> _teardown(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  }

  testWidgets('① active + 无帧：缩放条和诊断行也必须渲染（真机缺失项）', (tester) async {
    await _pumpScreen(tester);

    // 缩放条（无条件渲染）
    expect(find.text('1.0x'), findsOneWidget,
        reason: '缩放条整条不见 = 舞台没布置（真机故障形态）');
    // 诊断行（active 时渲染）
    expect(find.textContaining('分片'), findsOneWidget);
    // 连接状态
    expect(find.text('已连接'), findsOneWidget);

    await _teardown(tester);
  });

  testWidgets('② active + 窗口模式：窗口栏在，缩放条/诊断行照样在', (tester) async {
    svc.windowMode.value = true;
    svc.currentWindow.value = const RemoteWindowInfo(
      hwnd: 12345,
      title: '微信',
      process: 'WeChat.exe',
      left: 0,
      top: 0,
      width: 1200,
      height: 800,
      minimized: false,
    );
    await _pumpScreen(tester);

    expect(find.text('微信'), findsOneWidget);
    expect(find.text('退出'), findsOneWidget);
    expect(find.text('1.0x'), findsOneWidget);
    expect(find.textContaining('分片'), findsOneWidget);

    await _teardown(tester);
  });

  testWidgets('③ active + 有帧：画面件接管，缩放条/诊断行仍在', (tester) async {
    svc.frameSize.value = (w: 64, h: 32);
    svc.frameJpeg.value = _kJpeg;
    await _pumpScreen(tester);
    // 等异步解码（instantiateImageCodec + getNextFrame 是真实异步，得放事件循环跑）
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 150)));
    await tester.pump();

    expect(find.text('1.0x'), findsOneWidget);
    expect(find.textContaining('分片'), findsOneWidget);
    expect(svc.framesDecoded + svc.framesDecodeFail, greaterThan(0),
        reason: '喂进去的 JPEG 必须被解码（成功或失败都计数）');

    await _teardown(tester);
  });

  testWidgets('⑤ 真机时序：先建屏(connecting)再转 active —— 复现"舞台整块不渲染"', (tester) async {
    // 真机的顺序是：redeem() → push RemoteControlScreen（此时 connecting）→
    // ICE/DataChannel 建立后 phase 才翻 active。前面的测试都是"先 active 再建屏"，
    // 跳过了这个转换。如果转换之后舞台的浮件反而不见了，这就是真机黑屏的根因。
    svc.phase.value = RemotePhase.connecting;
    await _pumpScreen(tester);
    // connecting 态：黑底 + "连接中"覆盖层 + 缩放条（无条件）
    expect(find.text('1.0x'), findsOneWidget, reason: '建屏时缩放条就必须在');

    // 连接建立 → phase 翻 active（真实会话里由 ICE connected + 握手触发）
    svc.phase.value = RemotePhase.active;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('已连接'), findsOneWidget, reason: '状态点必须跟着翻');
    expect(find.text('1.0x'), findsOneWidget,
        reason: '🔴 翻 active 后缩放条不见了 = 复现真机"舞台整块不渲染"');
    expect(find.textContaining('分片'), findsOneWidget,
        reason: '🔴 翻 active 后诊断行不见了 = 同上');

    await _teardown(tester);
  });

  testWidgets('④ 画面矩形几何：16:9  contain 位置必须对（坐标点击依赖它）', (tester) async {
    final r = remoteVideoRect(const Size(1200, 1960), const Size(1920, 1080));
    expect(r.width, closeTo(1200, 0.001));
    expect(r.height, closeTo(675, 0.001));
    expect(r.top, closeTo((1960 - 675) / 2, 0.001));
  });

  // ── 2026-10-25 黑屏归因包（龙哥真机连黑三轮）─────────────────────

  test('⑥ hs 心跳协议解析：全字段 / 缺字段默认 / 畸形不崩 / 版本不对拒', () {
    final m = parseWindowHostMessage(
        '{"v":1,"t":"hs","prod":120,"sent":118,"drop":2,"w":1280,"h":720,"win":true,"wst":"ok"}');
    expect(m, isA<HostStatsMessage>());
    final h = m as HostStatsMessage;
    expect(h.produced, 120);
    expect(h.sent, 118);
    expect(h.dropped, 2);
    expect(h.width, 1280);
    expect(h.height, 720);
    expect(h.windowMode, isTrue);
    expect(h.windowState, 'ok');

    // 字段全缺也不能抛（老版本/半条报文），全部落默认值
    final h2 = parseWindowHostMessage('{"v":1,"t":"hs"}') as HostStatsMessage;
    expect(h2.produced, 0);
    expect(h2.sent, 0);
    expect(h2.windowMode, isFalse);
    expect(h2.windowState, '');

    // 畸形输入与版本不符一律 null，绝不让它冒到上层
    expect(parseWindowHostMessage('not json at all'), isNull);
    expect(parseWindowHostMessage('{"v":2,"t":"hs","prod":1}'), isNull);
    expect(parseWindowHostMessage(''), isNull);
    expect(parseWindowHostMessage('{"v":1,"t":"hs","prod":"x"}'),
        isA<HostStatsMessage>());
    expect(
        (parseWindowHostMessage('{"v":1,"t":"hs","prod":"x"}')
                as HostStatsMessage)
            .produced,
        0,
        reason: 'prod 不是数字时 asInt 给 null，落默认 0，不能抛');
  });

  test('⑦ hostStatsVerdict 判读表：六种状态各说各的话，优先级不乱', () {
    String v({
      int produced = 10,
      int dProd = 5,
      int dSent = 5,
      int dIn = 5,
      int decoded = 5,
      int fail = 0,
      String wst = 'ok',
    }) =>
        hostStatsVerdict(
          produced: produced,
          dProduced: dProd,
          dSent: dSent,
          dFramesIn: dIn,
          decoded: decoded,
          decodeFail: fail,
          windowState: wst,
        );

    expect(v(produced: 0), contains('一帧没采到'),
        reason: '对端总产出 0 = 采集没起来，这是最常见的黑屏因');
    expect(v(produced: 10, dProd: 0), contains('采集停了'));
    expect(v(dSent: 0), contains('没发出'));
    expect(v(dIn: 0), contains('网络吞了'));
    expect(v(decoded: 0, fail: 3), contains('解不开'));
    expect(v(), contains('链路正常'));

    // 优先级：产出 0 时即使别的也全异常，也必须先报"没采到"——
    // 判读顺序错了会让现场按错误方向排查
    expect(v(produced: 0, dSent: 0, dIn: 0, decoded: 0, fail: 9),
        contains('一帧没采到'));
    // 窗口状态要进文案（最小化是最容易被忽略的一种"采集停了"）
    expect(v(produced: 10, dProd: 0, wst: 'min'), contains('窗口min'));
  });

  testWidgets('⑧ 诊断搬出舞台：active 时底部永远显示链路行 + 对端心跳行', (tester) async {
    // 🔴 这条锁的是"诊断不能住在舞台里"：龙哥三轮黑屏，舞台整块不绘制，
    //    藏在舞台里的诊断行跟着一起消失，于是每轮反馈都只有"还是黑"。
    svc.framesFragIn = 12;
    svc.framesIn = 4;
    svc.framesDecoded = 4;
    svc.frameRecvDcState = 'open';
    svc.hostStatsText.value = '对端整屏 1280×720 采100·发98·丢2 → 链路正常';
    await _pumpScreen(tester);

    // 链路行（分片/帧/解/通道）——在舞台外，舞台全黑它也必须在
    expect(find.textContaining('分片 12'), findsOneWidget,
        reason: '底部诊断行的链路计数必须可见（黑屏自证的关键）');
    expect(find.textContaining('通道 open'), findsOneWidget);
    // 对端 hs 心跳行
    expect(find.textContaining('链路正常'), findsOneWidget,
        reason: '对端统计行必须渲染，否则黑屏时仍然分不清责任在谁');

    await _teardown(tester);
  });

  testWidgets('⑨ idle 时不显示链路行（避免满屏 0 的噪音）', (tester) async {
    svc.phase.value = RemotePhase.idle;
    await _pumpScreen(tester);
    expect(find.textContaining('分片'), findsNothing);
    // 但状态行仍在
    expect(find.textContaining('准备就绪'), findsOneWidget);
    await _teardown(tester);
  });
}
