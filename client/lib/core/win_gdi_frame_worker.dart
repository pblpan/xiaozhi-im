// Windows 自研画面通道的采集线程（独立 isolate）。
//
// ─────────────────────────────────────────────────────────────
// 【为什么必须另开 isolate】
// ─────────────────────────────────────────────────────────────
// GDI 抓屏 + JPEG 编码在本机实测是**同步**的几十到一百多毫秒。放在主
// isolate 上跑，等于每隔一百来毫秒把被控电脑的界面冻住一次 —— 鼠标不动、
// 按钮点不动。被控端的人正坐在屏幕前，这比黑屏还难受（他以为电脑卡死了）。
// 所以把「抓 + 编」整段丢进独立 isolate；主 isolate 只做一件事：把最新
// 一帧塞进 DataChannel（那一步几百微秒，感知不到）。
//
// ─────────────────────────────────────────────────────────────
// 【为什么是"持续产帧"而不是"收到请求再抓"】
// ─────────────────────────────────────────────────────────────
// 请求/响应模型会让两端互相拖：主线程等抓屏，worker 等主线程取走。
// 这里改成 worker 尽自己最大速度产帧、直接把每帧推给主线程；主线程按自己
// 的发送节奏取「手上最新的那一帧」，没新的就跳过。好处：
//   · 谁都不用等谁（没有往返延迟）；
//   · 网络慢时天然丢帧（旧帧直接作废），不会像队列那样越积越旧；
//   · 画质切换只是发一条 set 消息，worker 在帧与帧之间读掉。
//
// ─────────────────────────────────────────────────────────────
// 【跨 isolate 的线程亲和性 —— 这是本文件唯一需要小心的地方】
// ─────────────────────────────────────────────────────────────
// GDI 的设备上下文是进程级句柄，但 Dart 的 isolate 有可能在不同消息之间被
// 调度到不同的 OS 线程上。同一时刻两个线程用同一个 DC 会出问题 —— 而我们
// 本来就是串行使用的（一次只抓一帧），不存在并发；跨消息的顺序使用在实际
// 运行中是安全的。为稳妥起见：一旦连续抓失败 3 次，就**重建整个采集器**
// （dispose + open），而不是把失败一路带到黑屏。
//
// 这个文件不依赖 Flutter（只用 dart:isolate / dart:typed_data），所以能脱离
// 真机在命令行里跑通 —— 见 _scratch/gdi_probe 的验证脚本。
import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'win_gdi_capture.dart';

/// 采集线程句柄（主 isolate 侧）。
///
/// 用法：
/// ```dart
/// final hub = await GdiFrameHub.start();
/// hub?.onFrame = (w, h, jpeg) { ... };
/// hub?.setTarget(maxWidth: 960, quality: 65);
/// hub?.setWindow(hwnd);   // 可选：窗口模式，只投射一个窗口
/// hub?.clearWindow();     // 退出窗口模式，回到整屏
/// ...
/// await hub?.stop();
/// ```
class GdiFrameHub {
  GdiFrameHub._();

  ReceivePort? _rx;
  Isolate? _isolate;
  SendPort? _tx;
  bool _stopped = false;

  /// 每产出一帧回调一次（在**主 isolate** 上执行）。
  ///
  /// ⚠️ jpeg 是这一帧的字节，下一帧就会换掉 —— 不要长期持有，
  ///    需要留就自己复制一份。
  void Function(int width, int height, Uint8List jpeg)? onFrame;

  /// 出错/状态文案（进诊断条）。被控端的人看不到控制端的日志，
  /// 所以这里必须有一条能显示出来的路。
  void Function(String text)? onInfo;

  /// 窗口模式状态变化回调（见 WinGdiCapture.windowState）：
  ///   'ok'   正常跟拍
  ///   'min'  目标窗口被最小化（没画面，等恢复）
  ///   'gone' 目标窗口已关闭（worker 暂停轮询，等新指令）
  ///   'off'  目标窗口不在采集区（如搬到了副屏）
  /// 只在状态**变化**时回调，不会每帧刷。
  void Function(String state)? onWindowState;

  /// 采集区的人话描述，例如「主显示器 1536x864」。
  String info = '';

  /// 已产出的帧数（诊断用）。
  int produced = 0;

  /// 抓失败次数（诊断用）。
  int failed = 0;

  /// 最近一次错误。
  String lastError = '';

  bool get isRunning => !_stopped && _tx != null;

  /// 启动采集线程。返回 null 表示不支持 / 启不来（调用方回落到原采集方式）。
  ///
  /// [allMonitors] true=抓整个虚拟桌面。**默认只抓主显示器**，理由见
  /// win_gdi_capture.dart 头注（双屏拼起来在手机上没法看）。
  static Future<GdiFrameHub?> start({bool allMonitors = false}) async {
    final hub = GdiFrameHub._();
    final rx = ReceivePort();
    hub._rx = rx;
    final ready = Completer<bool>();

    rx.listen((Object? m) {
      if (m is! List || m.isEmpty) return;
      switch (m[0]) {
        case 'ready':
          hub._tx = m.length > 1 ? m[1] as SendPort : null;
          hub.info = m.length > 2 ? m[2] as String : '';
          if (!ready.isCompleted) ready.complete(hub._tx != null);
        case 'f':
          // ['f', w, h, TransferableTypedData]
          if (m.length < 4) return;
          final w = m[1] as int;
          final h = m[2] as int;
          final ttd = m[3] as TransferableTypedData;
          hub.produced++;
          hub.onFrame?.call(w, h, ttd.materialize().asUint8List());
        case 'err':
          final s = m.length > 1 ? '${m[1]}' : '未知错误';
          hub.failed++;
          hub.lastError = s;
          if (!ready.isCompleted) {
            ready.complete(false);
          } else {
            hub.onInfo?.call('画面采集出错：$s');
          }
        case 'wst':
          // ['wst', state]：窗口模式状态变化（见 onWindowState 注释）
          if (m.length < 2) return;
          hub.onWindowState?.call('${m[1]}');
        case 'x':
          // isolate 自身抛出来的（onError 端口），标签 'x' 不会和上面撞
          final s = m.length > 1 ? '${m[1]}' : '未知异常';
          hub.failed++;
          hub.lastError = s;
          if (!ready.isCompleted) {
            ready.complete(false);
          } else {
            hub.onInfo?.call('画面采集线程异常：$s');
          }
      }
    });

    try {
      hub._isolate = await Isolate.spawn<List<Object?>>(
        _gdiWorkerEntry,
        <Object?>[rx.sendPort, allMonitors],
        debugName: 'xiaozhi-gdi-capture',
        onError: rx.sendPort,
        errorsAreFatal: false,
      );
    } catch (e) {
      hub.lastError = '采集线程启动失败：$e';
      await hub.stop();
      return null;
    }

    final ok = await ready.future
        .timeout(const Duration(seconds: 12), onTimeout: () => false);
    if (!ok) {
      if (hub.lastError.isEmpty) hub.lastError = '采集线程启动超时';
      await hub.stop();
      return null;
    }
    return hub;
  }

  /// 切换画质档位（目标最大宽度 + JPEG 质量）。随时可调，立即生效。
  void setTarget({required int maxWidth, required int quality}) {
    final tx = _tx;
    if (tx == null || _stopped) return;
    try {
      tx.send(<Object?>['set', maxWidth, quality]);
    } catch (_) {
      // 线程已经死了就算了：没有画面时上层还有黑屏提示兜底
    }
  }

  /// 进入窗口模式：之后只投射 [hwnd]（句柄地址值，见
  /// WinWindowInfo.hwnd）这一个窗口。
  void setWindow(int hwnd) {
    final tx = _tx;
    if (tx == null || _stopped) return;
    try {
      tx.send(<Object?>['setwin', hwnd]);
    } catch (_) {}
  }

  /// 退出窗口模式，回到整屏。
  void clearWindow() {
    final tx = _tx;
    if (tx == null || _stopped) return;
    try {
      tx.send(<Object?>['clrwin']);
    } catch (_) {}
  }

  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    try {
      _tx?.send('stop');
    } catch (_) {}
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _tx = null;
    try {
      _rx?.close();
    } catch (_) {}
    _rx = null;
    onFrame = null;
    onWindowState = null;
  }
}

/// 采集线程主体。参数：[主线程 SendPort, 是否抓全部显示器]。
///
/// ⚠️ 必须是顶层函数（Isolate.spawn 的要求），且只能通过消息与外界交互。
Future<void> _gdiWorkerEntry(List<Object?> args) async {
  final SendPort reply = args[0] as SendPort;
  final bool allMonitors = (args.length > 1 ? args[1] : false) as bool;

  var cap = WinGdiCapture(allMonitors: allMonitors);
  if (!cap.open()) {
    reply.send(<Object?>['err', '打开屏幕采集失败：${cap.lastError}']);
    return;
  }

  var maxWidth = 1280;
  var quality = 70;
  var running = true;
  // 窗口模式：目标窗口句柄地址（0 = 整屏模式）；gone 时暂停轮询，
  // 等 setwin/clrwin 新指令再醒（窗口已经死了，继续轮询是白烧 CPU）。
  var winHwnd = 0;
  var paused = false;
  // 上一次报给主线程的窗口状态，只在变化时发消息（避免每帧刷）
  var lastWinState = '';

  // 控制消息端口：主线程通过它下发 set / stop / setwin / clrwin
  final ctl = ReceivePort();
  ctl.listen((Object? m) {
    if (m == 'stop') {
      running = false;
      return;
    }
    if (m is List && m.length >= 3 && m[0] == 'set') {
      final w = m[1] as int;
      final q = m[2] as int;
      if (w > 0) maxWidth = w;
      if (q > 0) quality = q;
      paused = false; // 换画质不该被暂停状态卡住
      return;
    }
    if (m is List && m.length >= 2 && m[0] == 'setwin') {
      winHwnd = m[1] as int;
      if (winHwnd > 0) cap.setWindow(winHwnd);
      paused = false;
      lastWinState = ''; // 强制把新窗口的状态重发一遍
      return;
    }
    if (m is List && m.length >= 1 && m[0] == 'clrwin') {
      winHwnd = 0;
      cap.clearWindow();
      paused = false;
      lastWinState = '';
      return;
    }
  });

  reply.send(<Object?>['ready', ctl.sendPort, cap.describe()]);

  var consecFail = 0;
  while (running) {
    if (paused) {
      // 目标窗口已关闭：歇着等指令。100ms 轮询指令，不烧 CPU。
      await Future<void>.delayed(const Duration(milliseconds: 100));
      continue;
    }

    final f = cap.captureJpeg(maxWidth: maxWidth, quality: quality);

    // 窗口状态变化才上报（''=整屏模式，主线程不关心就不该收到噪音）
    final st = cap.windowState;
    if (st != lastWinState) {
      lastWinState = st;
      if (st.isNotEmpty) reply.send(<Object?>['wst', st]);
      if (st == 'gone') paused = true;
    }

    if (f != null) {
      consecFail = 0;
      // TransferableTypedData：把字节的所有权直接交给对面，不做一次拷贝
      reply.send(<Object?>[
        'f',
        f.width,
        f.height,
        TransferableTypedData.fromList(<Uint8List>[f.jpeg]),
      ]);
    } else if (st == 'min' || st == 'off') {
      // 最小化/不在采集区：不是故障，是"暂时没画面"。
      // 慢速轮询等用户把窗口还原/挪回来，**不计失败、不重建采集器**
      // （重建对这两种状态毫无帮助，只会把 open() 的开销反复付）。
      await Future<void>.delayed(const Duration(milliseconds: 150));
      continue;
    } else {
      consecFail++;
      reply.send(<Object?>['err', cap.lastError]);
      if (consecFail >= 3) {
        // 连续失败：句柄很可能已经不可用了，重建一次再试。
        cap.dispose();
        cap = WinGdiCapture(allMonitors: allMonitors);
        if (!cap.open()) {
          reply.send(<Object?>['err', '重建采集器失败：${cap.lastError}']);
          break;
        }
        consecFail = 0;
        // 重建会丢掉窗口目标，按当前模式恢复
        if (winHwnd > 0) cap.setWindow(winHwnd);
        reply.send(<Object?>['ready', ctl.sendPort, cap.describe()]);
      }
    }
    // 让出事件循环：既给控制消息一条活路，也避免把这颗核跑满
    // （抓屏本身已经耗时几十毫秒，这里只是礼节性的小睡）。
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }

  cap.dispose();
  ctl.close();
}
