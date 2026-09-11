import 'dart:async';
import 'dart:convert';
import 'package:flutter/widgets.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'core/config.dart';
import 'core/storage.dart';

enum ConnState { idle, connecting, online, offline }

/// WebSocket 实时通道：仅用于接收服务端推送（消息/好友/群事件）
///
/// ## 为什么这块要写得这么"重"
///
/// 来电提醒、消息提醒全靠这条长连接推送，**一旦它悄悄死掉，用户什么都收不到**，
/// 表现就是"对方打我视频，我手机毫无反应，等对方挂了才看见一条未接记录"。
///
/// 老实现有两个致命短板，2026-09 外网通话排障时确认：
///
/// 1. **重试 12 次后永久放弃**（退避 1+2+4+8×9 ≈ 80 秒）。断网超过一分多钟，
///    这条连接就再也不会恢复，除非用户手动切服务器或重启 App。
/// 2. **没有心跳**。NAT 网关和内网穿透隧道（ZeroNews 这类）会在空闲时静默回收
///    连接，TCP 层不报错、`onDone` 不触发 —— 连接"看着还在、其实早死了"。
///
/// 现在改为：无限重连（退避封顶 30 秒）+ 20 秒应用层心跳 + 看门狗识别假死
/// + App 回到前台/网络可用时主动探活重建。
class SocketService {
  static final SocketService _i = SocketService._();
  factory SocketService() => _i;
  SocketService._();

  WebSocketChannel? _ch;
  StreamSubscription<dynamic>? _sub;
  final _ctrl = StreamController<dynamic>.broadcast();
  Stream<dynamic> get stream => _ctrl.stream;

  /// 连接状态，界面可监听显示"连接中/已连接/已断开"
  final ValueNotifier<ConnState> state = ValueNotifier(ConnState.idle);

  Timer? _retry;
  Timer? _heartbeat;
  int _tries = 0;
  bool _closedByUs = false;

  /// 最后一次收到服务端任何帧的时间（含 pong）。
  /// 看门狗靠它识别"半死连接"：状态还是 online，但早已收不到东西。
  DateTime? _lastFrameAt;

  /// 心跳间隔：20 秒。
  /// 不追求省电 —— 外网/移动网络下，快 20 秒发现断线，就少漏一通来电。
  static const _heartbeatEvery = Duration(seconds: 20);

  /// 超过这个时长没收到任何数据 → 判定连接已死，主动重建。
  /// 留 2.5 个心跳周期的余量，避免网络抖动时误杀。
  static const _deadAfter = Duration(seconds: 50);

  /// 回到前台时，若距上次收帧超过这个时长就直接重建，不再慢慢等心跳
  static const _staleAfterResume = Duration(seconds: 25);

  AppLifecycleListener? _lifecycle;

  Future<void> connect() async {
    final t = await Storage.getToken();
    if (t == null) return;
    _closedByUs = false;
    _ensureLifecycle();
    _open(t);
  }

  /// App 前后台切换时探活。
  ///
  /// 手机锁屏再解锁、WiFi 切 4G，旧 socket 多半已经是半死状态了。
  /// 这里不盲目重建（重建有成本），但也绝不"什么都不做"：
  /// 距上次收帧太久就果断重连，否则发个心跳探一下。
  void _ensureLifecycle() {
    if (_lifecycle != null) return;
    try {
      _lifecycle = AppLifecycleListener(onResume: poke);
    } catch (e) {
      debugPrint('[ws] 生命周期监听注册失败: $e');
    }
  }

  void _open(String token) {
    _heartbeat?.cancel();
    _retry?.cancel();

    // 先彻底拆掉旧连接：不 cancel 订阅的话，
    // 旧 socket 的 onDone 还会回来触发一次重连，形成连接风暴。
    final oldSub = _sub;
    _sub = null;
    unawaited(oldSub?.cancel());
    try {
      _ch?.sink.close();
    } catch (_) {
      /* 已关闭 */
    }

    state.value = ConnState.connecting;
    _lastFrameAt = DateTime.now();

    try {
      final ch = WebSocketChannel.connect(
          Uri.parse('${Config.wsUrl}/ws?token=$token'));
      _ch = ch;
      _sub = ch.stream.listen(
        (e) {
          _lastFrameAt = DateTime.now();
          _tries = 0;
          if (state.value != ConnState.online) state.value = ConnState.online;
          try {
            _ctrl.add(jsonDecode(e));
          } catch (_) {
            /* 非 JSON 帧忽略 */
          }
        },
        onError: (_) => _scheduleRetry(),
        onDone: () => _scheduleRetry(),
        cancelOnError: true,
      );
      _startHeartbeat();
    } catch (_) {
      _scheduleRetry();
    }
  }

  /// 心跳：定时发 ping，并兼做看门狗。
  void _startHeartbeat() {
    _heartbeat?.cancel();
    _heartbeat = Timer.periodic(_heartbeatEvery, (_) {
      if (_closedByUs) return;
      if (state.value != ConnState.online) return; // 未连上，交给重连逻辑

      final last = _lastFrameAt;
      if (last != null && DateTime.now().difference(last) > _deadAfter) {
        debugPrint('[ws] 心跳超时（${_deadAfter.inSeconds}s 无数据），重建连接');
        _hardReconnect();
        return;
      }
      send({'type': 'ping', 'ts': DateTime.now().millisecondsSinceEpoch});
    });
  }

  /// 不重置重试计数地重建连接（用于假死恢复）
  void _hardReconnect() {
    _heartbeat?.cancel();
    state.value = ConnState.offline;
    unawaited(connect());
  }

  /// 外部探活入口：App 回到前台时调用。
  void poke() {
    if (_closedByUs) return;
    final last = _lastFrameAt;
    final stale = last == null ||
        DateTime.now().difference(last) > _staleAfterResume;
    if (state.value == ConnState.online && !stale) {
      send({'type': 'ping', 'ts': DateTime.now().millisecondsSinceEpoch});
      return;
    }
    debugPrint('[ws] 前台恢复/网络变化，主动重连（state=${state.value.name}）');
    _tries = 0;
    unawaited(connect());
  }

  /// 断线重连：**永不放弃**，退避封顶 30 秒。
  ///
  /// 这是修复"外网来电不弹"的核心 —— 老版这里 `if (_tries >= 12) return;`
  /// 让 App 在断网约 80 秒后永久失去接收能力，用户完全无感知。
  void _scheduleRetry() {
    if (_closedByUs) return;
    _heartbeat?.cancel();
    if (state.value != ConnState.offline) state.value = ConnState.offline;
    _retry?.cancel();
    final wait = switch (_tries) {
      0 => 1,
      1 => 2,
      2 => 4,
      3 => 8,
      4 => 15,
      _ => 30,
    };
    if (_tries < 5) _tries++;
    debugPrint('[ws] $wait 秒后重连（第 $_tries 次）');
    _retry = Timer(Duration(seconds: wait), () async {
      final t = await Storage.getToken();
      if (t == null || _closedByUs) return;
      // 连了几次还上不去，八成是当前选中的服务器地址根本不通 ——
      // 典型：在外网却探测到了内网地址（探测缓存命中或走了 fallback），
      // 于是永远连不上。这里重新探一次，别死抱着一个地址。
      if (_tries >= 3) {
        try {
          final url = await Config.resolveNow();
          debugPrint('[ws] 重探地址 -> $url');
        } catch (_) {
          /* 探测失败就用原地址 */
        }
      }
      _open(t);
    });
  }

  /// 手动重连（例如切换服务器地址后）
  Future<void> reconnect() async {
    _retry?.cancel();
    _tries = 0;
    _closedByUs = false;
    await connect();
  }

  void send(Map<String, dynamic> frame) {
    try {
      _ch?.sink.add(jsonEncode(frame));
    } catch (_) {
      /* 连接已断，交给重连逻辑 */
    }
  }

  void disconnect() {
    _closedByUs = true;
    _retry?.cancel();
    _heartbeat?.cancel();
    unawaited(_sub?.cancel());
    _sub = null;
    try {
      _ch?.sink.close();
    } catch (_) {
      /* 忽略 */
    }
    _ch = null;
    state.value = ConnState.idle;
  }
}
