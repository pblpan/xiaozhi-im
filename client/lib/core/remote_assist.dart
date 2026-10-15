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
import 'remote_capture.dart';
import 'remote_models.dart';
import 'rtc_video_degrader.dart';
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

  /// UU-a：是否正在自动重连。UI 据此显示"网络波动，正在重连"的居中提示，
  /// 别让用户以为软件卡死/断了而手动退出（手动退出反而真断了）。
  final ValueNotifier<bool> reconnecting = ValueNotifier<bool>(false);

  /// UU-a：当前重连到第几次（配合上限显示"第 n/5 次"）。
  final ValueNotifier<int> reconnectAttempt = ValueNotifier<int>(0);

  /// UU-c：画质自适应档位。0=原画不限制，数字越大越省带宽越糊。
  /// 来自 RtcVideoDegrader 的 onChange，UI 在控制条上显示当前画质。
  final ValueNotifier<int> qualityLevel = ValueNotifier<int>(0);

  /// 当前是否处于**被控**状态。UI 拿它决定要不要显示"正在被协助"警示条。
  ///
  /// 🔴 修复（2026-10-15）：原先直接读 `SoundService().myId`，而那个值
  ///    默认 0、只有进过会话列表页才被赋值 —— 从远程页直接进时 isHost
  ///    恒 false，被控端收得到邀请也不弹框、不共享（"双向无反应"的一半）。
  ///    现在改为：本地确保过的 _myId 优先，SoundService 的作为同步补充。
  int get _me {
    final s = SoundService().myId;
    return s > 0 ? s : _myId;
  }

  bool get isHost {
    final s = session.value;
    if (s == null) return false;
    // 收到 remote:invite 即被控端（服务端只发给 hostId）；_me 比对作为兜底。
    return _hostByFrame || s.hostId == _me;
  }

  bool get isController => session.value?.controllerId == _me;

  final RTCVideoRenderer remoteRenderer = RTCVideoRenderer();
  bool _rendererReady = false;

  RTCPeerConnection? _pc;
  RTCDataChannel? _dc;
  MediaStream? _localScreen;

  /// UU-c：被控端屏幕共享发送端的画质自适应控制器（网络差自动降级）
  RtcVideoDegrader? _degrader;

  late final InputInjector _injector = createInputInjector();

  bool _started = false;
  StreamSubscription<dynamic>? _sub;

  /// 本地缓存的"我是谁"。SoundService().myId 只在会话列表页加载后才赋值，
  /// 远程协助可能从任意入口进，所以这里自己兜一份：start() 时预热，
  /// 每次会话帧到来前再确保一次（_ensureMyId）。
  int _myId = 0;

  /// _hostStart 幂等标志：无人值守时本地倒计时 + 服务端 remote:authed
  /// 两条路都会触发共享，不加标志会重复 getDisplayMedia / createOffer。
  bool _hostStarting = false;

  /// 以帧定角色：收到 `remote:invite` 即认定"我是被控端"。
  ///
  /// 🔴 修复（2026-10-15）：服务端的 remote:invite 只广播给 hostId
  ///    （remote.js request()/redeem() 两处都是 broadcastToUser(hostId)），
  ///    所以"收到邀请"本身就是权威的角色判定，不再依赖 _me 是否预热成功。
  ///    此前 isHost 纯靠 hostId == _me 比对，而 _me 拉 /me 失败时恒为 0
  ///    —— 被控端收得到邀请也不弹框、无人值守也不自动开始，表现就是
  ///    "发起了却永远超时"。
  bool _hostByFrame = false;

  // ICE 缓存：同一次会话里不必反复拉
  List<Map<String, dynamic>>? _ice;
  DateTime? _iceAt;
  /// UU-b：服务端下发的打洞策略（all / relay）
  String _icePolicy = 'all';

  // ---- UU-a：自动重连（被控端连接断了不等用户，自己退避重连）----
  // 借鉴 UU 远控：网络抖一下不该让用户手动重连。被控端作为 offer 方，
  // 在连接 Disconnected/Failed 时自己指数退避地发起 ICE 重启（restartIce），
  // 把屏幕共享接回来；连不上才最终放弃。重连期间**绝不停止屏幕采集轨**，
  // 否则轨没了就没法 ICE 重启了（这正是老逻辑一断就废的根因）。
  int _iceRestarts = 0;
  bool _reconnecting = false;
  Timer? _reconnectTimer;
  static const List<int> _kReconnectBackoffMs = <int>[1000, 2000, 4000, 8000];
  static const int _kMaxReconnectAttempts = 5;

  /// 确保"我是谁"已加载。有网时拉 /me 并同步给 SoundService（别的模块也受益）。
  Future<void> _ensureMyId() async {
    if (_me > 0) return;
    try {
      final me = await ImApi().me();
      final id = (me['user'] is Map) ? (me['user']['id'] as int?) : null;
      if (id != null && id > 0) {
        _myId = id;
        SoundService().myId = id;
      }
    } catch (_) {
      // 拉不到就先靠 SoundService 的旧值；再不行角色判定失败时会走
      // "无响应"路径，但至少不会崩
    }
  }

  void start() {
    if (_started) return;
    _started = true;
    _sub = SocketService().stream.listen(_onFrame);
    // WS 重连后主动恢复远程协助媒体（UU-a）
    SocketService().state.addListener(_onConnStateChanged);
    unawaited(_ensureMyId());
  }

  void dispose() {
    SocketService().state.removeListener(_onConnStateChanged);
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
        // 先确保 myId 再判角色：否则"我是被控端还是控制端"可能判错
        // 🔴 修复（2026-10-15）：invite 帧只发给被控端，置 _hostByFrame，
        //    角色判定不再押在 _me 上（_me 拉不到时恒 0 → 不弹框/不自动开始）。
        _hostByFrame = true;
        unawaited(_onInviteAsync(Map<String, dynamic>.from(raw['session'] as Map)));
        break;
      case 'remote:session':
        // 控制端侧的 session 落地帧（服务端 request/redeem 成功后补发）。
        // 🔴 修复（2026-10-15）：此前控制端本地 session 恒为 null，
        //    isController 判不出来、后续信令 sessionId 为 null 被服务端
        //    全部拒收 —— 表现就是"发起了却永远超时"。
        unawaited(_onSessionFrame(Map<String, dynamic>.from(raw['session'] as Map)));
        break;
      case 'remote:redeem:ok':
        // 兼容帧：session 已由 remote:session 落地，这里只记一笔日志
        _log('访问码兑换成功，等待对方撤销窗口结束');
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
      case 'remote:peer-offline':
        // 服务端宽限中（UU-a）：对方网络中断，但会话还在。提示并等待其重连。
        _log('对方网络中断，正在等待重连…');
        break;
      case 'remote:peer-online':
        // 对方重连回来了。被控端作为 offer 方立即 ICE 重协商把画面接回来；
        // 控制端无需动作，等被控端的重连 offer 即可。
        _log('对方网络已恢复，正在重连…');
        if (isHost) _scheduleReconnect();
        break;
      case 'remote:end':
        onEndedByPeer(raw['reason']?.toString() ?? '');
        break;
      default:
        break;
    }
  }

  Future<void> _onInviteAsync(Map<String, dynamic> s) async {
    await _ensureMyId();
    _onInvite(s);
  }

  /// 控制端侧的 session 落地：本地建立 session，让 isController 与后续
  /// 信令的 sessionId 有着落。无人值守的撤销窗口期同样走 requesting。
  Future<void> _onSessionFrame(Map<String, dynamic> s) async {
    await _ensureMyId();
    final prev = session.value;
    final next = RemoteSession(
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
    // 已在同一会话里就别重置 phase（避免 accept/offer 途中被打回 requesting）
    if (prev?.id == next.id) {
      session.value = next;
      return;
    }
    session.value = next;
    if (phase.value == RemotePhase.idle || phase.value == RemotePhase.ended) {
      phase.value = RemotePhase.requesting;
    }
    _log('已进入协助会话（${next.unattended ? '无人值守' : '有人值守'}），等待建立连接');
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
    await _ensureMyId();
    if (hostId == _me) return '不能远程协助自己';
    SocketService().send({'type': 'remote:invite', 'hostId': hostId});
    // 本地先把相位立起来：控制页要立刻显示"等待中"。
    // session 本身等服务端 remote:session 帧落地（信令的 sessionId 靠它）。
    if (phase.value == RemotePhase.idle || phase.value == RemotePhase.ended) {
      phase.value = RemotePhase.requesting;
    }
    // 结果通过 remote:invite / error 帧回来，这里不阻塞等
    return null;
  }

  /// 用访问码连接（无人值守）
  Future<String?> redeem(String code) async {
    if (SocketService().state.value != ConnState.online) {
      return '未连接到服务器，无法连接';
    }
    await _ensureMyId();
    SocketService().send({'type': 'remote:redeem', 'code': code.trim()});
    if (phase.value == RemotePhase.idle || phase.value == RemotePhase.ended) {
      phase.value = RemotePhase.requesting;
    }
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

  /// 采集桌面画面。
  ///
  /// 🔴 修复（2026-10-15）：flutter_webrtc 原生的 getDisplayMedia 依赖
  ///    sources_ 缓存（只有 getDesktopSources / updateDesktopSources 会填），
  ///    而"source 找不到就退第一个屏幕"的兜底只编进了 Linux
  ///    （flutter_screen_capture.cc 的 `#ifdef __linux__` 分支）——
  ///    Windows 上不先枚举直接采集必报 `source not found!`，
  ///    被控端静默失败（remote:end host_end、控制端干等超时）。
  ///    所以桌面平台先枚举、再显式指定 screen 源；移动端走 MediaProjection，
  ///    不需要这一步。
  Future<MediaStream> _captureScreen() async {
    // 🔴 Android 14（API 34）起，没有正在运行的 mediaProjection 前台服务，
    //    下面的 getDisplayMedia 会直接抛 SecurityException ——
    //    现象是"权限都给了、画面永远是黑的"，光看异常根本猜不到原因。
    //    所以必须先把它拉起来（桌面端这一句是空操作）。
    await RemoteCapture.ensure();
    String? screenId;
    if (WebRTC.platformIsDesktop) {
      try {
        final sources =
            await desktopCapturer.getSources(types: [SourceType.Screen]);
        for (final s in sources) {
          if (s.type == SourceType.Screen && s.id.isNotEmpty) {
            screenId = s.id;
            break;
          }
        }
      } catch (e) {
        _log('枚举桌面源失败（$e），按默认源采集');
      }
    }
    // 桌面采集。**不要**同时要音频 —— 远控场景里麦克风采集既没必要
    // 又会让系统弹出多余的权限提示，反而增加被拒绝的概率。
    return navigator.mediaDevices.getDisplayMedia(<String, dynamic>{
      'video': screenId != null
          ? <String, dynamic>{'deviceId': <String, dynamic>{'exact': screenId}}
          : true,
      'audio': false,
    });
  }

  Future<void> _hostStart() async {
    // 无人值守时本地倒计时 + 服务端 remote:authed 两条路都会触发，
    // 不加这个标志会重复弹采集框 / 重复 createOffer。
    if (_hostStarting) return;
    _hostStarting = true;
    try {
      phase.value = RemotePhase.connecting;
      final stream = await _captureScreen();
      _localScreen = stream;

      await _ensureRenderer();
      final pc = await _ensurePc();

      for (final t in stream.getVideoTracks()) {
        await pc.addTrack(t, stream);
      }

      // UU-c：屏幕共享的发送端挂在质量自适应控制器上，网络差时自动降码率/帧率
      final senders = await pc.getSenders();
      for (final s in senders) {
        if (s.track?.kind == 'video') {
          _degrader = RtcVideoDegrader(pc, s, onChange: (lvl, r) {
            qualityLevel.value = lvl;
            _log('画质自适应：等级 $lvl（$r）');
          });
          _degrader!.start();
          break;
        }
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
      // 失败必须留痕：diag 栏（远程页底部）会展示这句话，
      // 不能再像以前那样只有 debugPrint、release 版里什么都看不到。
      _log('开始共享失败：$e'
          '（如提示 source not found，请重启客户端后重试）');
      phase.value = RemotePhase.ended;
      SocketService().send({'type': 'remote:end', 'sessionId': session.value?.id});
      await _teardown();
    } finally {
      _hostStarting = false;
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
      // ⚠️ 不要再 addTransceiver(RecvOnly)：setRemoteDescription 后
      // unified-plan 的 transceiver 已按 offer 的 m-line 对齐，这里再
      // addTransceiver 会 append 一条没有对应 offer m-line 的 recvonly，
      // answer 出来是畸形 SDP，对端 setRemoteDescription 直接失败。
      // offer 里被控端已经 addTrack(video)，answer 会自动带上 recvonly。
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

  // ------------------------------------------------------------ 自动重连（UU-a）

  /// 启动退避重连（幂等：已在重连中就忽略）。
  void _scheduleReconnect() {
    if (_reconnecting) return;
    _reconnecting = true;
    reconnecting.value = true;
    reconnectAttempt.value = 0;
    _log('连接中断，准备自动重连…');
    _reconnectTick();
  }

  /// 退避循环：每次按 1/2/4/8s（封顶）等待后发起一次 ICE 重启；
  /// 连上会由 onConnectionState(Connected) 打断并清零；超上限则放弃。
  void _reconnectTick() {
    if (!_reconnecting) return;
    if (_iceRestarts >= _kMaxReconnectAttempts) {
      _log('自动重连失败，已放弃');
      _reconnecting = false;
      reconnecting.value = false;
      unawaited(_teardown(reason: 'failed'));
      return;
    }
    final idx = _iceRestarts < _kReconnectBackoffMs.length
        ? _iceRestarts
        : _kReconnectBackoffMs.length - 1;
    final delay = _kReconnectBackoffMs[idx];
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(Duration(milliseconds: delay), () async {
      _iceRestarts++;
      reconnectAttempt.value = _iceRestarts;
      await _restartIce();
      // 仍未恢复则继续下一轮；恢复由 onConnectionState(Connected) 处理
      _reconnectTick();
    });
  }

  /// 被控端（offer 方）发起 ICE 重启：restartIce() 后重新 createOffer 并发出，
  /// 控制端照常应答即可把屏幕共享接回来。重连期间**绝不停止屏幕采集轨**。
  Future<void> _restartIce() async {
    final pc = _pc;
    if (pc == null || session.value?.id == null) return;
    try {
      // 现代 flutter_webrtc 支持 restartIce()，再 createOffer() 即带新 ICE 凭证
      await pc.restartIce();
      final offer = await pc.createOffer();
      await pc.setLocalDescription(offer);
      _sendOffer(offer);
    } catch (e) {
      // 兜底：部分实现无 restartIce，改用 createOffer 的 iceRestart 选项
      try {
        final offer =
            await pc.createOffer(<String, dynamic>{'iceRestart': true});
        await pc.setLocalDescription(offer);
        _sendOffer(offer);
      } catch (e2) {
        _log('重连 offer 失败：$e2');
      }
    }
  }

  void _sendOffer(RTCSessionDescription offer) {
    SocketService().send({
      'type': 'remote:offer',
      'sessionId': session.value?.id,
      'data': offer.toMap(),
    });
    _log('已发送重连 offer（第 $_iceRestarts 次）');
  }

  /// WS 重连回来后，若正处于远程会话，被控端立即尝试恢复媒体（不用等退避定时器）。
  void _onConnStateChanged() {
    if (SocketService().state.value == ConnState.online &&
        (phase.value == RemotePhase.active ||
            phase.value == RemotePhase.connecting) &&
        isHost) {
      _scheduleReconnect();
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
          final p = d['iceTransportPolicy'];
          _icePolicy = p == 'relay' ? 'relay' : 'all';
          return list;
        }
      }
    } catch (e) {
      _log('拉取 ICE 失败（$e），用内置 STUN');
    }
    _ice = kRemoteIceServers;
    _iceAt = DateTime.now();
    _icePolicy = 'all';
    return kRemoteIceServers;
  }

  Future<RTCPeerConnection> _ensurePc() async {
    final exist = _pc;
    if (exist != null) return exist;

    final pc = await createPeerConnection(<String, dynamic>{
      'iceServers': await _iceServers(),
      'sdpSemantics': 'unified-plan',
      // UU-b：服务端下发的打洞策略（all / relay）
      'iceTransportPolicy': _icePolicy,
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
          // 连上了：清零退避计数，取消重连定时器，恢复正常相位
          _iceRestarts = 0;
          _reconnecting = false;
          reconnecting.value = false;
          reconnectAttempt.value = 0;
          _reconnectTimer?.cancel();
          _reconnectTimer = null;
          if (phase.value != RemotePhase.active) {
            phase.value = RemotePhase.active;
            SocketService().send({
              'type': 'remote:active',
              'sessionId': session.value?.id,
            });
          }
          _log('连接已恢复${isController ? '，你现在可以操作对方电脑' : '，对方可以看到你的屏幕'}');
          break;
        case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
          // 短暂断开（最常由网络抖动触发）：不急着拆，进入退避重连
          if (phase.value == RemotePhase.active ||
              phase.value == RemotePhase.connecting) {
            _scheduleReconnect();
          }
          break;
        case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
          // 失败：若会话仍在建立/进行中就退避重连；否则（比如刚建还没连）
          // 按老逻辑放弃，避免卡在半死不活的状态。
          if (phase.value == RemotePhase.active ||
              phase.value == RemotePhase.connecting) {
            _scheduleReconnect();
          } else {
            _log('连接失败，可能双方不在同一网络且中继不可用');
            unawaited(_teardown(reason: 'failed'));
          }
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
    _hostByFrame = false;
    // 🔴 会话结束必须撤掉屏幕采集的前台服务，否则那条"正在共享屏幕"的常驻通知
    //    会一直挂着 —— 用户会以为被人在背后偷偷录屏。
    //    这一句刻意放在最前面：下面任何一步抛异常都不该把通知留在状态栏上。
    unawaited(RemoteCapture.release());
    // 收尾：清掉退避重连状态，避免定时器在会话结束后还跑
    _reconnecting = false;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _iceRestarts = 0;
    reconnecting.value = false;
    reconnectAttempt.value = 0;
    qualityLevel.value = 0;
    _degrader?.stop();
    _degrader = null;
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
