// 远程协助服务（客户端核心）
//
// 【角色术语】为了不混淆，这里统一叫：
//   host       被控端 —— 屏幕被看、键鼠被操作的一方
//   controller 控制端 —— 看屏幕、发指令的一方
//
// 【不复用 CallService 的原因】
// 通话是"多方 + 可中途加入 + 结束后群里留记录"，远程协助是"严格 1v1 +
// 必须审计 + 控制权要被显式授予"。语义差别太大，硬凑会让两边都难改。
//
// 【最重要的两条红线】（改这个文件的人请务必看清）
// 1. **主机端在 phase != active 时，收到的任何控制指令一律丢弃**。
//    这是"点了同意之前不能被控"的最后一道保险 —— 服务端已经拦了一层，
//    但服务端被绕过/实现有 bug 时不该导致用户被悄悄控住。
// 2. **主机端的桌面帧只推给自己建立的 DataChannel 的另一端**，
//    且整条链路建立前不发任何东西。

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../api.dart';
import '../socket.dart';
import 'input_inject.dart';
import 'remote_models.dart';
import 'sound_service.dart';

/// 一条已解析的远程输入指令。
///
/// 用 sealed 是为了让上层执行时必须穷举所有分支 —— 将来加"剪贴板同步"时
/// 漏写一个分支会在编译期就报错，而不是上线后静默失效。
sealed class RemoteInputAction {}

final class MoveAction extends RemoteInputAction {
  MoveAction(this.x, this.y);
  final double x;
  final double y;
}

final class ButtonAction extends RemoteInputAction {
  ButtonAction(this.button, this.down);
  final RemoteMouseButton button;
  final bool down;
}

final class WheelAction extends RemoteInputAction {
  WheelAction(this.delta);
  final int delta;
}

final class KeyAction extends RemoteInputAction {
  KeyAction(this.key, this.down);
  final RemoteKey key;
  final bool down;
}

/// 解析一条控制通道报文 → 动作；解析不了返回 null，调用方丢弃即可。
///
/// 【为什么单独抽成纯函数】
/// 控制通道里流过来的是**对方发的任意字符串**。协议故意带上了 `v` 版本号，
/// 将来加剪贴板 / 文件传输时新老版本还能互相认出对方支持的字段。这么关键的
/// 一段解析逻辑如果埋在 WebRTC 回调里，就永远只能靠真机联调验证 —— 抽出来
/// 才能单测"畸形输入不崩"。
RemoteInputAction? parseRemoteInput(String text) {
  // 正常的键鼠报文只有十几个字节，超长的直接丢，不必进入 JSON 解析
  if (text.isEmpty || text.length > 4096) return null;

  Map<String, dynamic> m;
  try {
    final d = jsonDecode(text);
    if (d is! Map) return null;
    m = Map<String, dynamic>.from(d);
  } catch (_) {
    return null; // JSON 坏了就丢，绝不让它冒到上层
  }
  if (m['v'] != 1) return null;

  final t = m['t']?.toString();
  switch (t) {
    case 'mm': // mouse move
      final x = asDouble(m['x']);
      final y = asDouble(m['y']);
      if (x == null || y == null) return null;
      return MoveAction(x, y);
    case 'md': // mouse down
    case 'mu': // mouse up
      return ButtonAction(buttonOfName(m['b']?.toString()), t == 'md');
    case 'mw': // wheel
      return WheelAction(asInt(m['dy']) ?? 0);
    case 'kd': // key down
    case 'ku': // key up
      return KeyAction(keyOfJson(m), t == 'kd');
    default:
      // 未知类型忽略：老版本遇到新指令不该崩
      return null;
  }
}

/// 宽容取 double。
///
/// ⚠️ 必须写成 `v is num ? ...` 而不是 `(v as num?)`：对端发来
/// `{"x":"0.5"}` 时后者会抛 `String is not a subtype of num` ——
/// 也就是说**对方在控制通道里塞一个字符串就能把被控端的 App 搞崩**。
double? asDouble(dynamic v) => v is num ? v.toDouble() : null;

int? asInt(dynamic v) => v is num ? v.toInt() : null;

String asStr(dynamic v) => v is String ? v : '';

RemoteMouseButton buttonOfName(String? s) {
  switch (s) {
    case 'middle':
      return RemoteMouseButton.middle;
    case 'right':
      return RemoteMouseButton.right;
    default:
      // 认不出来的一律当左键，绝不当非法值丢掉：
      // "点了没反应"比"点了但出了意外"安全。
      return RemoteMouseButton.left;
  }
}

RemoteKey keyOfJson(Map<String, dynamic> m) {
  // 同样用"宽容取值"：这里若直接 `as String?` / `as int?`，
  // 对端发个 {"c":123} 就能让被控端解析时抛异常。
  final rawChar = m['c'];
  final char = (rawChar is String && rawChar.isNotEmpty) ? rawChar : null;
  return RemoteKey(
    vk: asInt(m['k']),
    char: char,
    extended: m['ext'] == true,
  );
}

enum RemotePhase { idle, requesting, connecting, active, ended }

/// 当前会话的描述（谁跟谁、什么模式、什么时候到期）
class RemoteSession {
  const RemoteSession({
    required this.id,
    required this.hostId,
    this.controllerId,
    required this.mode,
    this.abortDeadline,
    this.hostName = '',
    this.controllerName = '',
  });

  final String id;
  final int hostId;
  final int? controllerId;
  final String mode; // attended | unattended
  final DateTime? abortDeadline;
  final String hostName;
  final String controllerName;

  bool get unattended => mode == 'unattended';
}

/// 内置的兜底 STUN。正常情况用服务端下发的（含 TURN 中继）。
const List<Map<String, dynamic>> kRemoteIceServers = <Map<String, dynamic>>[
  {'urls': 'stun:stun.chat.bilibili.com:3478'},
  {'urls': 'stun:stun.miwifi.com:3478'},
];

class RemoteAssistService {
  RemoteAssistService._();
  static final RemoteAssistService instance = RemoteAssistService._();

  final ValueNotifier<RemoteSession?> session = ValueNotifier<RemoteSession?>(null);
  final ValueNotifier<RemotePhase> phase = ValueNotifier<RemotePhase>(RemotePhase.idle);
  final ValueNotifier<String> diag = ValueNotifier<String>('');

  /// 当前是否处于**被控**状态。UI 拿它决定要不要显示"正在被协助"警示条。
  bool get isHost =>
      session.value != null && session.value!.hostId == SoundService().myId;

  bool get isController => session.value?.controllerId == SoundService().myId;

  final RTCVideoRenderer remoteRenderer = RTCVideoRenderer();
  bool _rendererReady = false;

  RTCPeerConnection? _pc;
  RTCDataChannel? _dc;
  MediaStream? _localScreen;

  late final InputInjector _injector = createInputInjector();

  bool _started = false;
  StreamSubscription<dynamic>? _sub;

  // ICE 缓存：同一次会话里不必反复拉
  List<Map<String, dynamic>>? _ice;
  DateTime? _iceAt;

  void start() {
    if (_started) return;
    _started = true;
    _sub = SocketService().stream.listen(_onFrame);
  }

  void dispose() {
    _sub?.cancel();
    _sub = null;
    _started = false;
  }

  void _log(String s) {
    debugPrint('[remote] $s');
    diag.value = s;
  }

  // ------------------------------------------------------------ 信令入口

  void _onFrame(dynamic raw) {
    if (raw is! Map) return;
    final type = raw['type']?.toString() ?? '';
    if (!type.startsWith('remote:')) return;

    switch (type) {
      case 'remote:invite':
        _onInvite(Map<String, dynamic>.from(raw['session'] as Map));
        break;
      case 'remote:accept':
        // 主机同意了（attended）或撤销窗口已过（unattended）→ 等着收 offer
        _log('对方已同意，等待建立连接');
        if (isController) _ensurePc();
        break;
      case 'remote:authed':
        // 无人值守：窗口过了没人反对，自动开始共享 —— 这正是无人值守的意义
        _log('无人值守窗口已过，自动开始共享');
        if (isHost) unawaited(_hostStart());
        break;
      case 'remote:offer':
        unawaited(_onRemoteOffer(Map<String, dynamic>.from(raw['data'] as Map)));
        break;
      case 'remote:answer':
        unawaited(_onRemoteAnswer(Map<String, dynamic>.from(raw['data'] as Map)));
        break;
      case 'remote:ice':
        unawaited(_onRemoteIce(Map<String, dynamic>.from(raw['data'] as Map)));
        break;
      case 'remote:active':
        phase.value = RemotePhase.active;
        _log('远程协助已生效');
        break;
      case 'remote:end':
        onEndedByPeer(raw['reason']?.toString() ?? '');
        break;
      default:
        break;
    }
  }

  void _onInvite(Map<String, dynamic> s) {
    session.value = RemoteSession(
      id: asStr(s['sessionId']),
      hostId: asInt(s['hostId']) ?? 0,
      controllerId: asInt(s['controllerId']),
      mode: asStr(s['mode']).isEmpty ? 'attended' : asStr(s['mode']),
      abortDeadline: s['abortDeadline'] is int
          ? DateTime.fromMillisecondsSinceEpoch(s['abortDeadline'] as int)
          : null,
      hostName: asStr(s['hostName']),
      controllerName: asStr(s['controllerName']),
    );
    phase.value = RemotePhase.requesting;

    if (isHost) {
      _log('收到协助请求（${session.value!.unattended ? '无人值守' : '有人值守'}）');
      // 无人值守到点自动开始；有人值守等用户点同意（UI 负责）
      final d = session.value!.abortDeadline;
      if (d != null) {
        final wait = d.difference(DateTime.now());
        Future<void>.delayed(
          wait.isNegative ? Duration.zero : wait,
          () {
            // 服务端也会到点放行；这里只是本地补一次，防止我们和服务端时钟有偏差
            if (phase.value == RemotePhase.requesting && isHost) {
              unawaited(_hostStart());
            }
          },
        );
      }
    } else {
      _log('已向 ${session.value!.hostName} 发起远程协助请求');
    }
  }

  // ------------------------------------------------------------ 控制端动作

  /// 向某人发起远程协助
  Future<String?> requestFrom(int hostId) async {
    if (SocketService().state.value != ConnState.online) {
      return '未连接到服务器，无法发起远程协助';
    }
    if (hostId == SoundService().myId) return '不能远程协助自己';
    SocketService().send({'type': 'remote:invite', 'hostId': hostId});
    // 结果通过 remote:invite / error 帧回来，这里不阻塞等
    return null;
  }

  /// 用访问码连接（无人值守）
  Future<String?> redeem(String code) async {
    if (SocketService().state.value != ConnState.online) {
      return '未连接到服务器，无法连接';
    }
    SocketService().send({'type': 'remote:redeem', 'code': code.trim()});
    return null;
  }

  /// 被控端同意
  Future<void> acceptAsHost() async {
    if (!isHost) return;
    SocketService().send({'type': 'remote:accept', 'sessionId': session.value?.id});
    await _hostStart();
  }

  Future<void> rejectAsHost() async {
    if (!isHost) return;
    SocketService().send({'type': 'remote:reject', 'sessionId': session.value?.id});
    await _teardown();
  }

  Future<void> cancelByController() async {
    if (!isController) return;
    SocketService().send({'type': 'remote:cancel', 'sessionId': session.value?.id});
    await _teardown();
  }

  /// 任一方主动结束
  Future<void> hangUp() async {
    final id = session.value?.id;
    if (id == null) return;
    SocketService().send({'type': 'remote:end', 'sessionId': id});
    await _teardown();
  }

  void onEndedByPeer(String reason) {
    final r = remoteEndReasonText(reason);
    unawaited(_teardown(reason: reason));
    if (r.isNotEmpty) _log('会话结束：$r');
  }

  // ------------------------------------------------------------ 被控端采集

  Future<void> _hostStart() async {
    try {
      phase.value = RemotePhase.connecting;
      // 桌面采集。**不要**同时要音频 —— 远控场景里麦克风采集既没必要
      // 又会让系统弹出多余的权限提示，反而增加被拒绝的概率。
      final stream = await navigator.mediaDevices.getDisplayMedia(<String, dynamic>{
        'video': true,
        'audio': false,
      });
      _localScreen = stream;

      await _ensureRenderer();
      final pc = await _ensurePc();

      for (final t in stream.getVideoTracks()) {
        await pc.addTrack(t, stream);
      }

      // 控制通道由**被控端**创建并随 offer 一起协商出去 ——
      // 这样"谁可以给我发控制指令"这件事在 SDP 里就定死了。
      final dc = await pc.createDataChannel(
        'control',
        RTCDataChannelInit()
          ..ordered = true
          ..maxRetransmits = -1,
      );
      _bindControlChannel(dc);

      final offer = await pc.createOffer();
      await pc.setLocalDescription(offer);
      SocketService().send({
        'type': 'remote:offer',
        'sessionId': session.value?.id,
        'data': offer.toMap(),
      });
      _log('已发送共享offer，等待对方接入');
    } catch (e) {
      _log('开始共享失败：$e');
      phase.value = RemotePhase.ended;
      SocketService().send({'type': 'remote:end', 'sessionId': session.value?.id});
      await _teardown();
    }
  }

  // ------------------------------------------------------------ 控制端接入

  Future<void> _onRemoteOffer(Map<String, dynamic> data) async {
    try {
      await _ensureRenderer();
      final pc = await _ensurePc();
      await pc.setRemoteDescription(RTCSessionDescription(
        data['sdp']?.toString() ?? '',
        data['type']?.toString() ?? 'offer',
      ));
      // 只收不发：控制端不需要把自己的画面给对方
      await pc.addTransceiver(
        kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
        init: RTCRtpTransceiverInit(
          direction: TransceiverDirection.RecvOnly,
        ),
      );
      final answer = await pc.createAnswer();
      await pc.setLocalDescription(answer);
      SocketService().send({
        'type': 'remote:answer',
        'sessionId': session.value?.id,
        'data': answer.toMap(),
      });
      _log('已应答，等待画面');
    } catch (e) {
      _log('处理 offer 失败：$e');
    }
  }

  Future<void> _onRemoteAnswer(Map<String, dynamic> data) async {
    final pc = _pc;
    if (pc == null) return;
    try {
      await pc.setRemoteDescription(RTCSessionDescription(
        data['sdp']?.toString() ?? '',
        data['type']?.toString() ?? 'answer',
      ));
      _log('对方已应答');
    } catch (e) {
      _log('处理 answer 失败：$e');
    }
  }

  Future<void> _onRemoteIce(Map<String, dynamic> data) async {
    final pc = _pc;
    if (pc == null) return;
    try {
      await pc.addCandidate(RTCIceCandidate(
        data['candidate']?.toString() ?? '',
        data['sdpMid']?.toString(),
        (data['sdpMLineIndex'] is int) ? data['sdpMLineIndex'] as int : null,
      ));
    } catch (e) {
      // ICE 候选失败很常见（尤其一端换网络），吞掉不要刷屏
      debugPrint('[remote] addCandidate 失败: $e');
    }
  }

  // ------------------------------------------------------------ 连接管理

  Future<void> _ensureRenderer() async {
    if (_rendererReady) return;
    await remoteRenderer.initialize();
    _rendererReady = true;
  }

  Future<List<Map<String, dynamic>>> _iceServers() async {
    final c = _ice;
    final at = _iceAt;
    if (c != null &&
        at != null &&
        DateTime.now().difference(at) < const Duration(minutes: 5)) {
      return c;
    }
    try {
      final d = await ImApi().callIce();
      final raw = d['iceServers'];
      if (raw is List) {
        final list = raw
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .where((e) => e['urls'] != null)
            .toList();
        if (list.isNotEmpty) {
          _ice = list;
          _iceAt = DateTime.now();
          return list;
        }
      }
    } catch (e) {
      _log('拉取 ICE 失败（$e），用内置 STUN');
    }
    _ice = kRemoteIceServers;
    _iceAt = DateTime.now();
    return kRemoteIceServers;
  }

  Future<RTCPeerConnection> _ensurePc() async {
    final exist = _pc;
    if (exist != null) return exist;

    final pc = await createPeerConnection(<String, dynamic>{
      'iceServers': await _iceServers(),
      'sdpSemantics': 'unified-plan',
    });

    pc.onIceCandidate = (c) {
      if (c.candidate == null || c.candidate!.isEmpty) return;
      SocketService().send({
        'type': 'remote:ice',
        'sessionId': session.value?.id,
        'data': c.toMap(),
      });
    };

    // ⚠️ Windows 桌面端的 onTrack 常常带回空的 streams 列表（平台差异），
    // 只在 streams 非空时挂渲染器会导致"手机能看、电脑黑屏"。
    // 所以按轨道兜底：没有 stream 就自己建一个装进去。
    pc.onTrack = (event) => unawaited(_onTrack(event));

    pc.onDataChannel = (dc) {
      // 控制端的数据通道由被控端创建，这里是接收端
      _bindControlChannel(dc);
    };

    pc.onConnectionState = (st) {
      switch (st) {
        case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
          phase.value = RemotePhase.active;
          _log('连接已建立${isController ? '，你现在可以操作对方电脑' : '，对方可以看到你的屏幕'}');
          SocketService().send({
            'type': 'remote:active',
            'sessionId': session.value?.id,
          });
          break;
        case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
          _log('连接失败，可能双方不在同一网络且中继不可用');
          unawaited(_teardown(reason: 'failed'));
          break;
        case RTCPeerConnectionState.RTCPeerConnectionStateClosed:
          break;
        default:
          break;
      }
    };

    _pc = pc;
    return pc;
  }

  Future<void> _onTrack(RTCTrackEvent event) async {
    MediaStream stream;
    if (event.streams.isNotEmpty) {
      stream = event.streams.first;
    } else {
      // 桌面端经常只给轨道不给 stream，自己建一个装进去
      try {
        stream = await createLocalMediaStream('remote-screen');
        await stream.addTrack(event.track);
      } catch (e) {
        _log('自建远端流失败: $e');
        return;
      }
    }
    if (event.track.kind == 'video') {
      remoteRenderer.srcObject = stream;
      _log('已收到对方屏幕');
    }
  }

  void _bindControlChannel(RTCDataChannel dc) {
    _dc = dc;
    dc.onMessage = (RTCDataChannelMessage msg) {
      // ⚠️ 红线 1：只有**被控端**且会话已生效时才能执行输入指令。
      // 这是"点了同意之前不能被控"的最后一道保险 —— 服务端已经拦了一层，
      // 但服务端被绕过/实现有 bug 时不该导致用户被悄悄控住。
      if (!isHost) return;
      if (phase.value != RemotePhase.active) {
        debugPrint('[remote] 忽略未生效会话的控制指令');
        return;
      }
      _execRemoteInput(msg.text);
    };
  }

  // ------------------------------------------------------------ 控制指令

  /// 执行一条控制指令。解析不了 / 不是本版协议的报文直接丢弃，不崩。
  void _execRemoteInput(String text) {
    final a = parseRemoteInput(text);
    if (a == null) return;
    switch (a) {
      case MoveAction(:final x, :final y):
        _injector.moveAbsolute(x, y);
      case ButtonAction(:final button, :final down):
        _injector.mouseButton(button, down);
      case WheelAction(:final delta):
        _injector.scroll(delta);
      case KeyAction(:final key, :final down):
        if (down) {
          _injector.keyDown(key);
        } else {
          _injector.keyUp(key);
        }
    }
  }

  // ---- 发送侧（控制端 UI 调用）----

  void _send(Map<String, dynamic> m) {
    final dc = _dc;
    if (dc == null) return;
    try {
      dc.send(RTCDataChannelMessage(jsonEncode(<String, dynamic>{'v': 1, ...m})));
    } catch (_) { /* 通道没就绪就算了 */ }
  }

  void sendPointer(double nx, double ny) =>
      _send(<String, dynamic>{'t': 'mm', 'x': nx, 'y': ny});
  void sendMouseDown(RemoteMouseButton b) =>
      _send(<String, dynamic>{'t': 'md', 'b': b.name});
  void sendMouseUp(RemoteMouseButton b) =>
      _send(<String, dynamic>{'t': 'mu', 'b': b.name});
  void sendWheel(int delta) => _send(<String, dynamic>{'t': 'mw', 'dy': delta});
  void sendKeyDown(RemoteKey k) => _send(<String, dynamic>{
        't': 'kd',
        if (k.char != null) 'c': k.char,
        if (k.vk != null) 'k': k.vk,
        if (k.extended) 'ext': true,
      });
  void sendKeyUp(RemoteKey k) => _send(<String, dynamic>{
        't': 'ku',
        if (k.char != null) 'c': k.char,
        if (k.vk != null) 'k': k.vk,
        if (k.extended) 'ext': true,
      });

  // ------------------------------------------------------------ 收尾

  Future<void> _teardown({String reason = ''}) async {
    try {
      _dc?.close();
    } catch (_) {}
    _dc = null;

    _localScreen?.getTracks().forEach((t) async {
      try {
        await t.stop();
      } catch (_) {}
    });
    _localScreen = null;

    final pc = _pc;
    _pc = null;
    if (pc != null) {
      try {
        await pc.close();
      } catch (_) {}
    }
    try {
      remoteRenderer.srcObject = null;
    } catch (_) {}

    session.value = null;
    phase.value = reason.isNotEmpty ? RemotePhase.ended : RemotePhase.idle;
  }
}
