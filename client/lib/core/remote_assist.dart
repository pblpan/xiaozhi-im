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
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../api.dart';
import '../socket.dart';
import 'input_inject.dart';
import 'remote_capture.dart';
import 'remote_frame_stream.dart';
import 'remote_history_store.dart';
import 'remote_models.dart';
import 'rtc_video_degrader.dart';
import 'sound_service.dart';
import 'win_gdi_frame_worker.dart';
import 'win_window_list.dart';

/// 自研画面通道的画质档位表：档位 → (目标最大宽度, JPEG 质量)。
///
/// 序号沿用控制端 UI 的 0..4（原画/高清/标清/流畅/极速，文案见 remote.dart）。
/// ⚠️ 这里的"原画"封顶在 1280 宽，不是屏幕原始分辨率 —— 原因是硬的：
/// 抓屏 + JPEG 编码是同步的几十毫秒，宽度越大帧率掉得越快（本机实测
/// 1280 宽约 4~5fps、960 宽约 8~13fps）。把 1536 宽也叫"原画"，
/// 用户选到的是一张每秒动两次的图 —— 那是骗人，不是画质。
const List<({int width, int quality})> kRemoteFrameLevels = <({
  int width,
  int quality
})>[
  (width: 1280, quality: 70),
  (width: 1152, quality: 68),
  (width: 960, quality: 65),
  (width: 800, quality: 60),
  (width: 640, quality: 55),
];

/// 自研画面通道的默认档位（标清）。控制端没手动选过时用这个：
/// 960 宽在本机实测约 8~13fps、约 30KB/帧（0.24MB/s），
/// 是"看得清桌面小字"和"画面跟得上手"之间的平衡点。
const int kRemoteFrameDefaultLevel = 2;

/// 自研画面通道把最新一帧推给控制端的最小间隔。
/// 发一帧只要几百微秒，这个值只是给发送侧一个上限，实际速度由采集端决定。
const Duration kRemoteFrameSendInterval = Duration(milliseconds: 60);

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

/// 画质档位指令（UU-c 手动锁定）。level=null 表示恢复自动。
///
/// 为什么走控制通道而不是 socket：这条指令只在**这一次会话**里有效，
/// 且方向天然是"控制端 → 被控端（发送端）"，跟键鼠指令同一条路，
/// 复用它的有序可靠投递，不用再开一路信令。
final class QualityAction extends RemoteInputAction {
  QualityAction(this.level);
  final int? level;
}

// ── 窗口模式（参考 TwinDesk「Apps 面板」）─────────────────────────
//
// 控制端不只看整屏，还能列出被控端"开着的那些窗口"，选中一个就只投射它。
// 全部走**现有的控制 DataChannel**（服务端零改动）：
//   controller → host：wl 要列表 / ws 选窗口(hwnd) / we 退出窗口模式
//   host → controller：wn 列表(JSON) / wsok 已进入(带矩形) / wst 状态变化 /
//                        wg 窗口被关闭
// 窗口枚举只发生在被控端本机（win_window_list.dart），句柄以**地址值**
// 过通道 —— 对端拿到的只是数字，注入/采集时在本进程用
// Pointer<Void>.fromAddress(hwnd) 还原。

/// 请求窗口列表（controller→host）。
final class WindowListRequestAction extends RemoteInputAction {}

/// 选择窗口（controller→host）。[hwnd] 是 WinWindowInfo.hwnd 那种地址值。
final class WindowSelectAction extends RemoteInputAction {
  WindowSelectAction(this.hwnd);
  final int hwnd;
}

/// 退出窗口模式（controller→host），回到整屏投射。
final class WindowExitAction extends RemoteInputAction {}

/// 画面回执（controller→host）：控制端已拼出多少完整帧。
///
/// 【为什么要这条】
/// 被控端的「已发 N 帧」只证明**把字节交给了 DataChannel**，不等于对端收到了 ——
/// 原生 `RTCDataChannel::Send()` 的返回值在 flutter_webrtc 里被丢掉，
/// 通道未就绪/超限时是**静默失败**。所以黑屏排查必须先分清：
///   · 已发涨、对端已收为 0  → 没送到（传输/通道问题）
///   · 已发涨、对端已收也在涨 → 送到了，问题在控制端解码/渲染
/// 这个回执就是那条分界线。每秒一条，几十字节。
final class FrameAckAction extends RemoteInputAction {
  FrameAckAction(this.framesIn);

  /// 控制端累计拼出的完整帧数（不是"收到多少片"）。
  final int framesIn;
}

/// 控制端手里的一个窗口条目（纯数据，**不含任何 FFI 类型** ——
/// 它可能跑在 Android 上，而 hwndPtr 只在被控端进程里有意义）。
class RemoteWindowInfo {
  const RemoteWindowInfo({
    required this.hwnd,
    required this.title,
    required this.process,
    required this.left,
    required this.top,
    required this.width,
    required this.height,
    required this.minimized,
  });

  factory RemoteWindowInfo.fromJson(Map<String, dynamic> m) =>
      RemoteWindowInfo(
        hwnd: asInt(m['hwnd']) ?? 0,
        title: m['title']?.toString() ?? '',
        process: m['process']?.toString() ?? '',
        left: asInt(m['left']) ?? 0,
        top: asInt(m['top']) ?? 0,
        width: asInt(m['width']) ?? 0,
        height: asInt(m['height']) ?? 0,
        minimized: m['min'] == true,
      );

  /// 句柄地址值（只在被控端进程内可还原成指针）。
  final int hwnd;
  final String title;
  final String process;

  /// 窗口矩形（被控端屏幕物理坐标）。
  final int left;
  final int top;
  final int width;
  final int height;

  /// 是否最小化（选了之后第一次输入会先还原）。
  final bool minimized;

  /// 列表副标题：进程名 + 尺寸；最小化时明说。
  String get subtitle => minimized
      ? '${process.isEmpty ? '未知进程' : process} · 已最小化'
      : '${process.isEmpty ? '未知进程' : process} · ${width}x$height';
}

/// 被控端 → 控制端的窗口协议报文（host→controller 方向）。
///
/// 与 [RemoteInputAction] 分开两个家族：方向不同、字段不同，
/// 混在一起解析会让"谁在执行谁"变糊。
sealed class WindowHostMessage {}

/// wn：窗口列表。[ok]=false 时 [why] 说明原因（非 Windows 被控端 /
/// 自研画面通道不可用），[windows] 为空。
final class WindowListMessage extends WindowHostMessage {
  WindowListMessage(this.ok, this.why, this.windows);
  final bool ok;
  final String why;
  final List<RemoteWindowInfo> windows;
}

/// wsok：已进入窗口模式，附当前窗口的实时矩形。
final class WindowSelectedMessage extends WindowHostMessage {
  WindowSelectedMessage(this.info);
  final RemoteWindowInfo info;
}

/// wg：目标窗口已被关闭（看门狗/采集线程发现）。
final class WindowGoneMessage extends WindowHostMessage {
  WindowGoneMessage(this.hwnd);
  final int hwnd;
}

/// wst：窗口状态变化。state ∈ 'ok' | 'min' | 'off'（含义见
/// WinGdiCapture.windowState 注释）。
final class WindowStateMessage extends WindowHostMessage {
  WindowStateMessage(this.state);
  final String state;
}

/// 解析 host→controller 的窗口协议报文；不是这类报文返回 null。
WindowHostMessage? parseWindowHostMessage(String text) {
  if (text.isEmpty || text.length > 64 * 1024) return null;
  Map<String, dynamic> m;
  try {
    final d = jsonDecode(text);
    if (d is! Map) return null;
    m = Map<String, dynamic>.from(d);
  } catch (_) {
    return null;
  }
  if (m['v'] != 1) return null;
  switch (m['t']?.toString()) {
    case 'wn':
      if (m['ok'] != true) {
        return WindowListMessage(false, m['why']?.toString() ?? '被控端不支持窗口模式', const []);
      }
      final raw = m['win'];
      if (raw is! List) {
        return WindowListMessage(false, '窗口列表格式不对', const []);
      }
      return WindowListMessage(
        true,
        '',
        raw
            .whereType<Map>()
            .map((e) => RemoteWindowInfo.fromJson(Map<String, dynamic>.from(e)))
            .toList(growable: false),
      );
    case 'wsok':
      final info = m['w'];
      if (info is! Map) return null;
      return WindowSelectedMessage(
          RemoteWindowInfo.fromJson(Map<String, dynamic>.from(info)));
    case 'wg':
      final h = asInt(m['hwnd']);
      if (h == null) return null;
      return WindowGoneMessage(h);
    case 'wst':
      final s = m['state']?.toString();
      if (s == null) return null;
      return WindowStateMessage(s);
    default:
      return null;
  }
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
    case 'ql': // 画质档位（UU-c 手动锁定）；lv 缺省 = 恢复自动
      final lv = m['lv'];
      return QualityAction(lv is num ? lv.toInt() : null);
    case 'wl': // 窗口模式：要窗口列表
      return WindowListRequestAction();
    case 'ws': // 窗口模式：选窗口（hwnd 必须为正）
      final h = asInt(m['hwnd']);
      if (h == null || h <= 0) return null;
      return WindowSelectAction(h);
    case 'we': // 窗口模式：退出，回整屏
      return WindowExitAction();
    case 'fa': // 画面回执：控制端已拼出多少完整帧（0 也照发，用于"确实没收到"）
      final n = asInt(m['n']);
      if (n == null || n < 0) return null;
      return FrameAckAction(n);
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

  /// UU-c：控制端手动选的档位（null=自动）。teardown 时重置。
  /// 和 qualityLevel 分开存：后者是"实际生效值"（可能被网络自动改），
  /// 前者是"用户选了什么"（菜单打勾用）。混在一起的话，
  /// 自动降级一次，用户菜单里的勾就跑到别的档位上去了。
  final ValueNotifier<int?> qualityPick = ValueNotifier<int?>(null);

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

  // ---------------------------------------------------- 自研画面通道（Windows）
  // 背景见 win_gdi_capture.dart 头注：Windows 上 WebRTC 的桌面采集恒黑，
  // 所以被控端在 Windows 上改用自研 GDI 抓屏 → JPEG → DataChannel。
  // 信令、鉴权、ICE、控制指令通道**全部沿用原样**，只换"画面像素从哪来"。

  /// 控制端：收到的最新一帧（JPEG 字节）。null=还没收到过。
  ///
  /// remote.dart 据它决定贴图还是用 RTCVideoView —— 这个 notifier 为 null
  /// 就说明对端没用自研通道（比如手机当被控端），一切照旧。
  final ValueNotifier<Uint8List?> frameJpeg = ValueNotifier<Uint8List?>(null);

  /// 控制端：最新一帧的像素尺寸。首帧到达前为 null。
  final ValueNotifier<({int w, int h})?> frameSize =
      ValueNotifier<({int w, int h})?>(null);

  /// 控制端：已收到的完整帧数（诊断/黑屏判定用）。
  int framesIn = 0;

  /// 被控端：自研采集线程。
  GdiFrameHub? _gdiHub;

  /// 被控端：承载画面的数据通道。
  RTCDataChannel? _frameDc;

  /// 被控端：把"手上最新一帧"推出去的定时器。
  Timer? _frameSendTimer;

  /// 被控端：待发送的最新一帧（只留最新的一帧，旧的直接丢）。
  ({int w, int h, Uint8List jpeg})? _pendingFrame;

  /// 被控端：帧序号。
  int _frameSeq = 0;

  /// 控制端：分片重组器。
  final RemoteFrameAssembler _assembler = RemoteFrameAssembler();

  /// 被控端：因对端消费不过来而主动丢掉的帧数（诊断用）。
  int framesDropped = 0;

  /// 被控端：已发出的帧数（诊断用）。
  int framesOut = 0;

  /// 被控端：采集线程实际产出的帧数。
  /// 和 [framesOut] 对照就能分辨"没抓到"还是"抓到了没发出去"。
  int framesProduced = 0;

  /// 被控端：累计发出的字节数（含每片的头部）。用来抓"帧计数涨、字节不涨"
  /// 这种空帧假象。
  int framesBytesOut = 0;

  /// 被控端：`dc.send` 抛异常的次数（原生静默失败看不到，只能看这个 + 对端回执）。
  int framesSendError = 0;

  /// 被控端：对端回执"已拼出多少帧"。null = 还没收到过回执。
  int? peerFramesIn;

  /// 被控端：画面通道状态（none / open / closed…），给诊断条看。
  String frameSendDcState = 'none';

  /// 控制端：收到的 frames 通道状态。'none' = 通道压根没来。
  String frameRecvDcState = 'none';

  /// 控制端：喂进重组器的**分片**数（不是完整帧数）。
  ///
  /// 🔴 这是黑屏判读的核心一对数：分片在涨、完整帧 0 → 分片在传输层被丢
  ///    （PR-SCTP 静默丢弃，2026-10-25 已改成可靠通道）；两个都是 0 →
  ///    通道压根没建起来。只看"帧"数分不出这两种完全不同的病。
  int framesFragIn = 0;

  /// 控制端：Skia 解码成功 / 失败的帧数。
  /// 失败在这里通常是收到半张图或编码坏了，和"没收到"是完全不同的问题。
  int framesDecoded = 0;
  int framesDecodeFail = 0;

  /// 控制端：重组器因缺片 / 被更新的一帧顶掉而丢掉的帧数（诊断用）。
  int get framesAsmDropped => _assembler.dropped;

  /// 控制端：给被控端发画面回执的定时器。
  Timer? _ackTimer;

  /// 控制端：记录一次解码结果（由 RemoteFrameView 回调）。
  void noteDecode(bool ok) {
    if (ok) {
      framesDecoded++;
    } else {
      framesDecodeFail++;
    }
  }

  late final InputInjector _injector = createInputInjector();

  // ── 窗口模式（参考 TwinDesk「Apps 面板」）──────────────────────
  // 控制端侧状态：列表 / 当前窗口 / 异常提示。被控端侧只有 _winHwnd
  // （当前窗口目标）和看门狗定时器。

  /// 控制端：被控端返回的窗口列表（null=还没请求过）。
  final ValueNotifier<List<RemoteWindowInfo>?> windowList =
      ValueNotifier<List<RemoteWindowInfo>?>(null);

  /// 控制端：拉列表失败的原因（null=无）。非 Windows 被控端会带原因回来，
  /// UI 要如实显示，不能给个空列表让用户以为"对方没开窗口"。
  final ValueNotifier<String?> windowListError = ValueNotifier<String?>(null);

  /// 控制端：是否处于窗口模式（选中了某个窗口、正在单窗投射）。
  final ValueNotifier<bool> windowMode = ValueNotifier<bool>(false);

  /// 控制端：当前投射的窗口（wsok 带回的实时信息）。
  final ValueNotifier<RemoteWindowInfo?> currentWindow =
      ValueNotifier<RemoteWindowInfo?>(null);

  /// 控制端：窗口异常状态文案（''=正常）。'min'→已最小化，
  /// 'off'→窗口不在采集区。gone 不走这里（见 WindowGoneMessage）。
  final ValueNotifier<String> windowStateText = ValueNotifier<String>('');

  /// 被控端：当前窗口目标句柄（0=整屏模式）。
  int _winHwnd = 0;

  /// 被控端：最近一次枚举的窗口列表（wsok 回报里补标题/进程名用）。
  List<WinWindowInfo> _windowCache = const [];

  /// 被控端：窗口看门狗（本地用户把窗口关了，要及时通知控制端）。
  Timer? _winWatchdog;

  /// 控制端：窗口列表请求的超时兜底定时器（见 requestWindowList）。
  Timer? _winListTimer;

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

  /// 最近一次 redeem 用的访问码。只在本机内存里过渡一下：连接真正建立时
  /// （remote:active / Connected）连同会话信息一起写进本地历史，之后即弃。
  /// 无人值守的"一键重连"全靠它 —— 不记的话下次得重新翻那个 9 位码。
  String _lastRedeemCode = '';

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
        unawaited(_recordHistory());
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

  // ------------------------------------------------------------ 本地历史

  /// 连接真正建立时记一笔本地历史（龙哥 2026-10-16：「远程协助增加手机端的
  /// 历史记录和收藏夹，方便下次发起连接」）。
  ///
  /// 为什么记在 active 而不是"点了发起/连接"：没连上的尝试记了也是白记，
  /// 列表里躺一堆连不上的对象反而碍事。而 active 时 session 帧已落地，
  /// 对方名字、是否无人值守都拿得到。
  ///
  /// 只记**我发起的**（isController）：被控来的连接服务端审计里有，
  /// 且"下次一键发起"对那个方向没有意义。controllerId 拉不到（_me=0）时
  /// 判不出来就不记 —— 宁可少一条历史，也不能把别人连我的记录塞进我的
  /// 快捷列表。
  Future<void> _recordHistory() async {
    final s = session.value;
    if (s == null || !isController) return;
    final isCode = s.unattended;
    await RemoteHistoryStore.I.record(
      peerId: s.hostId,
      peerName: s.hostName,
      code: isCode ? _lastRedeemCode : '',
      kind: isCode ? 'code' : 'friend',
    );
  }

  // ------------------------------------------------------------ 控制端动作

  /// 向某人发起远程协助
  Future<String?> requestFrom(int hostId) async {
    if (SocketService().state.value != ConnState.online) {
      return '未连接到服务器，无法发起远程协助';
    }
    if (hostId == SoundService().myId) return '不能远程协助自己';
    // 同 redeem()：上一场没干净收尾就先清掉，别拿死连接去建新会话
    await _resetForNewSession();
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
  ///
  /// 🔴 2026-10-25 修：开头先 `_resetForNewSession()`。
  ///    上一场会话没干净收尾时（重连卡死、被控端放弃、异常退出），
  ///    `_pc` 还留着一条死连接、phase 还停在 active/connecting。
  ///    不复用逻辑会拿那条死 pc 去 setRemoteDescription → 必失败 →
  ///    用户看到的就是"点连接一点反应都没有"（龙哥 2026-10-25 真机）。
  Future<String?> redeem(String code) async {
    if (SocketService().state.value != ConnState.online) {
      return '未连接到服务器，无法连接';
    }
    await _resetForNewSession();
    await _ensureMyId();
    _lastRedeemCode = code.trim();
    SocketService().send({'type': 'remote:redeem', 'code': code.trim()});
    if (phase.value == RemotePhase.idle || phase.value == RemotePhase.ended) {
      phase.value = RemotePhase.requesting;
    }
    return null;
  }

  /// 开新会话前的硬复位：把上一场留下的死连接/定时器/计数全部清掉。
  ///
  /// 与 [_teardown] 的差别只有一个：**不给对端发 remote:end**。
  /// 对端可能早就走了（PC 都关了），再发一条结束帧只会刷一条没用的错误；
  /// 而本地该清的（pc、DataChannel、采集、计数、相位）一样都不能少。
  Future<void> _resetForNewSession() async {
    final live = phase.value == RemotePhase.active ||
        phase.value == RemotePhase.connecting ||
        _pc != null;
    if (!live) return;
    debugPrint('[remote] 开新会话前清掉上一场残留（phase=${phase.value}）');
    _reconnecting = false;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _iceRestarts = 0;
    reconnecting.value = false;
    reconnectAttempt.value = 0;
    _ackTimer?.cancel();
    _ackTimer = null;
    _stopFrameSendLoop();
    _pendingFrame = null;
    try {
      _frameDc?.close();
    } catch (_) {}
    _frameDc = null;
    try {
      _dc?.close();
    } catch (_) {}
    _dc = null;
    final pc = _pc;
    _pc = null;
    if (pc != null) {
      try {
        await pc.close();
      } catch (_) {}
    }
    final hub = _gdiHub;
    _gdiHub = null;
    if (hub != null) unawaited(hub.stop());
    _assembler.reset();
    frameJpeg.value = null;
    frameSize.value = null;
    framesIn = 0;
    framesOut = 0;
    framesFragIn = 0;
    framesDecoded = 0;
    framesDecodeFail = 0;
    frameRecvDcState = 'none';
    frameSendDcState = 'none';
    session.value = null;
    phase.value = RemotePhase.idle;
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

      // ① Windows 被控端优先走**自研画面通道**（GDI 抓屏 → JPEG → DataChannel）。
      //    打不开就静默回落到原来的 WebRTC 采集：宁可帧率一般、画面普通，
      //    也不能因为自研这条路出问题就变成"完全没法协助"。
      //
      //    为什么非换不可：libwebrtc 的桌面采集在本机（就是被控的那台电脑）
      //    **恒出黑帧** —— 不报错、不抛异常，就是黑的。同机 GDI 抓屏实测
      //    完全正常。详细推理见 win_gdi_capture.dart 的头注。
      final hub = await _tryStartGdi();
      if (hub != null) {
        await _startFrameHost(hub);
        return;
      }

      // ② 原路径：WebRTC 桌面采集（安卓被控端 / Windows 上自研通道不可用）
      await _startVideoHost();
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

  /// 原路径：WebRTC 桌面采集（手机当被控端时走这里，也是 Windows 的兜底）。
  Future<void> _startVideoHost() async {
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
  }

  // ------------------------------------------------ 自研画面通道（被控端侧）

  /// 尝试拉起自研采集线程。返回 null = 这条路走不通，调用方回落。
  ///
  /// 🔴 **必须先真抓一帧再决定**：采集器能 open 不等于抓得到（远程会话断开、
  ///    屏被独占时 BitBlt 会失败）。如果等 PeerConnection 建好、控制端连上
  ///    之后才发现抓不到，用户看到的就是"连上了但一片黑" —— 那正是我们要
  ///    消灭的现象。所以这里先抓一帧当体检，抓不到就干脆别用这条路。
  Future<GdiFrameHub?> _tryStartGdi() async {
    if (!Platform.isWindows) return null;
    final hub = await GdiFrameHub.start();
    if (hub == null) {
      _log('自研画面通道不可用，改用系统屏幕共享');
      return null;
    }
    hub.onInfo = (s) => _log(s);
    // 窗口模式状态（最小化/不在采集区/恢复）转发给控制端。
    // 'gone' 由 worker 侧先发现，这里补一刀：退出窗口模式并通告，
    // 让控制端别对着一帧永不变化的画面以为网络卡了。
    hub.onWindowState = (st) {
      switch (st) {
        case 'gone':
          // 看门狗可能已经发现并通告过了（两边都会发现窗口消失），
          // _winHwnd 已清零就说明处理过了，别再重复通告。
          if (_winHwnd == 0) return;
          _send(<String, dynamic>{'t': 'wg', 'hwnd': _winHwnd});
          _log('采集线程报告目标窗口已关闭，退出窗口模式');
          _hostExitWindowMode();
        case 'min':
        case 'off':
        case 'ok':
          if (_winHwnd != 0) _send(<String, dynamic>{'t': 'wst', 'state': st});
      }
    };

    final first = Completer<bool>();
    hub.onFrame = (w, h, jpeg) {
      framesProduced++;
      _pendingFrame = (w: w, h: h, jpeg: jpeg);
      if (!first.isCompleted) first.complete(true);
    };
    hub.setTarget(
      maxWidth: kRemoteFrameLevels[kRemoteFrameDefaultLevel].width,
      quality: kRemoteFrameLevels[kRemoteFrameDefaultLevel].quality,
    );
    final got = await first.future
        .timeout(const Duration(seconds: 6), onTimeout: () => false);
    if (!got) {
      await hub.stop();
      _log('自研画面通道首帧超时，改用系统屏幕共享');
      return null;
    }
    return hub;
  }

  /// 自研画面通道：只协商数据通道，不协商视频轨。
  Future<void> _startFrameHost(GdiFrameHub hub) async {
    _gdiHub = hub;
    qualityLevel.value = kRemoteFrameDefaultLevel;
    qualityPick.value = null;
    // 🔴 成对改动，拆开任何一半都会"画面正确但点哪儿都偏"：
    //    画面只含主显示器，注入坐标就必须按主显示器换算。
    _injector.usePrimaryOnlyCapture(true);
    _log('自研画面通道已启用：${hub.info}');

    final pc = await _ensurePc();

    // 控制通道：可靠有序（键鼠指令少点一下，比画面旧一帧严重得多）
    final ctl = await pc.createDataChannel(
      'control',
      RTCDataChannelInit()
        ..ordered = true
        ..maxRetransmits = -1,
    );
    _bindControlChannel(ctl);

    // 画面通道：无序 + 完全可靠。
    //
    // 🔴🔴 2026-10-25 修正（黑屏根因）：这里原来是 unordered + maxRetransmits:1，
    //     也就是 SCTP 的"部分可靠"（PR-SCTP）。PR-SCTP 的语义是
    //     **重传一次还送不到，就由 SCTP 栈静默丢弃** —— 不回调、不报错、
    //     Dart 侧零感知（flutter_webrtc 连 Send() 的返回值都直接丢掉，
    //     见 common/cpp/src/flutter_data_channel.cc 的 DataChannelSend）。
    //     而我们的帧协议是"丢一片 → 整帧作废"：RemoteFrameAssembler 只保一帧
    //     在飞，缺一片就永远拼不齐，下一帧的第一片到达时又把它整个丢掉。
    //     两者相乘的结果是：**Wi-Fi 上丢一个碎块 = 永久拼不齐 = 手机一片黑**，
    //     而被控端"已发 N 帧"照涨 —— 正是龙哥看到的现象。
    //
    //     改成"无序 + 可靠"：SCTP 负责重传到送达为止，重组器本来就吃得下任意
    //     顺序（乱序/重复/迟到/跨帧交错全有单测）；无序投递让后面的帧能越过
    //     缺口先到，不会队头阻塞。代价只是丢片那一帧晚一两个 RTT，下一帧即恢复。
    //
    //     踩过的坑一并记下：maxRetransmits = 0 **不能**写 —— webrtc_interface 的
    //     RTCDataChannelInit.toMap() 里是 `if (maxRetransmits > 0)`，传 0 会被
    //     静默丢掉，通道反而悄悄变回完全可靠。想表达"不可靠"必须写正数，
    //     而我们最终的选择是：这条路**根本就不要不可靠**。
    final frames = await pc.createDataChannel(
      kRemoteFrameChannelLabel,
      RTCDataChannelInit()
        ..ordered = false
        ..maxRetransmits = -1
        ..maxRetransmitTime = -1,
    );
    _bindFrameSender(frames);

    final offer = await pc.createOffer();
    await pc.setLocalDescription(offer);
    SocketService().send({
      'type': 'remote:offer',
      'sessionId': session.value?.id,
      'data': offer.toMap(),
    });
    _log('已发送共享offer（自研画面通道），等待对方接入');
  }

  /// 被控端：绑定画面发送通道，通道一开就按节奏推帧。
  void _bindFrameSender(RTCDataChannel dc) {
    _frameDc = dc;
    frameSendDcState = dc.state?.toString() ?? 'unknown';
    dc.onDataChannelState = (st) {
      frameSendDcState = st.toString();
      switch (st) {
        case RTCDataChannelState.RTCDataChannelOpen:
          _startFrameSendLoop();
        case RTCDataChannelState.RTCDataChannelClosed:
        case RTCDataChannelState.RTCDataChannelClosing:
          _stopFrameSendLoop();
        case RTCDataChannelState.RTCDataChannelConnecting:
          break;
      }
    };
  }

  void _startFrameSendLoop() {
    if (_frameSendTimer != null) return;
    _frameSendTimer =
        Timer.periodic(kRemoteFrameSendInterval, (_) => _sendLatestFrame());
  }

  void _stopFrameSendLoop() {
    _frameSendTimer?.cancel();
    _frameSendTimer = null;
  }

  /// 推"手上最新的一帧"。没新帧、通道没就绪、对端吃不消 —— 都直接跳过。
  ///
  /// 这一段跑在主 isolate 上，必须是微秒级：只看一眼 bufferedAmount，
  /// 然后把几十 KB 丢给 native 就返回（真正的重活都在采集线程里）。
  void _sendLatestFrame() {
    final dc = _frameDc;
    final f = _pendingFrame;
    if (dc == null || f == null) return;
    _pendingFrame = null;

    // 对端消费不过来就丢掉这一帧 —— 画面要的是最新，不是完整。
    // 阈值取 512KB：约 10 帧的余量，够吸收一次网络抖动，又不至于积压成延迟。
    if (dc.bufferedAmount != null && dc.bufferedAmount! > 512 * 1024) {
      framesDropped++;
      return;
    }
    final parts = packRemoteFrame(
      seq: ++_frameSeq,
      width: f.w,
      height: f.h,
      jpeg: f.jpeg,
    );
    try {
      var sent = 0;
      for (final p in parts) {
        dc.send(RTCDataChannelMessage.fromBinary(p));
        sent += p.lengthInBytes;
      }
      framesOut++;
      framesBytesOut += sent;
    } catch (e) {
      framesSendError++;
      _log('画面发送失败：$e');
    }
  }

  /// 被控端画面采集状态的一行人话，给被控端警示条显示。
  ///
  /// 🔴 被控端也需要看得见的诊断（原来只有控制端画布页底部的 _DiagBar）：
  ///    远程协助出问题时，坐在电脑前的人和拿着手机的人看到的现象完全不同。
  ///    "画面黑"这件事只有被控端能说清是"没抓到"还是"抓到了没发出去"。
  ///    2026-10-16 排查黑屏时，电脑端一个可看的字都没有，只能靠猜 ——
  ///    这一行就是补上那个"看一眼就知道卡在哪"的位置。
  String get captureStatus {
    final hub = _gdiHub;
    if (hub != null) {
      final lv = qualityLevel.value.clamp(0, kRemoteFrameLevels.length - 1);
      final cfg = kRemoteFrameLevels[lv];
      final buf = <String>[
        '画面：${hub.info} → ${cfg.width}宽',
        '采集 $framesProduced · 发送 $framesOut',
        // 🔴 黑屏排查的核心一行：发出去的字节有没有在对面变成完整帧。
        //    "已发涨、对端 0" = 传输/通道问题；"对端也在涨" = 控制端解码/渲染问题。
        peerFramesIn == null ? '对端回执：无' : '对端已收 $peerFramesIn 帧',
        '${(framesBytesOut / 1024).toStringAsFixed(0)}KB · 通道 $frameSendDcState',
      ];
      if (framesDropped > 0) buf.add('丢弃 $framesDropped');
      if (framesSendError > 0) buf.add('发送失败 $framesSendError');
      if (hub.lastError.isNotEmpty) buf.add('错误：${hub.lastError}');
      return buf.join(' · ');
    }
    if (phase.value == RemotePhase.active) return '画面：系统屏幕共享（WebRTC）';
    return '';
  }

  /// 控制端：绑定画面接收通道。
  void _bindFrameChannel(RTCDataChannel dc) {
    frameRecvDcState = dc.state?.toString() ?? 'unknown';
    dc.onDataChannelState = (st) => frameRecvDcState = st.toString();
    // 每秒给被控端回一条"我拼出多少帧" —— 黑屏时这是唯一能分清
    // "没送到"和"送到了没解出来"的信号。通道没了就自然停（send 抛异常被吞）。
    _ackTimer?.cancel();
    _ackTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _send(<String, dynamic>{'t': 'fa', 'n': framesIn});
    });
    dc.onMessage = (RTCDataChannelMessage msg) {
      if (!msg.isBinary) return;
      if (phase.value == RemotePhase.ended) return;
      framesFragIn++;
      RemoteFrame? done;
      try {
        done = _assembler.feed(msg.binary);
      } catch (e) {
        // 网络来的字节，畸形是常态，绝不能把异常抛到事件循环上
        debugPrint('[remote] 画面分片解析失败：$e');
        return;
      }
      if (done == null) return;
      framesIn++;
      final size = _assembler.width;
      final hgt = _assembler.height;
      if (size != null && hgt != null) {
        final prev = frameSize.value;
        if (prev == null || prev.w != size || prev.h != hgt) {
          frameSize.value = (w: size, h: hgt);
        }
      }
      frameJpeg.value = done.jpeg;
    };
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
  ///
  /// 🔴🔴 2026-10-25 修（龙哥真机："重连中"卡死、画面通道 Closed、
  ///     再点连接一点反应都没有）：**只有被控端能发起 ICE 重启。**
  ///
  ///     被控端是 offer 方（DataChannel 由它建、采集轨由它出），天然该由它
  ///     restartIce() + createOffer()。控制端是 answerer，它也去 createOffer
  ///     就会和被控端的重连 offer **撞车**：双方同时拿着一个 pending local
  ///     offer 去 setRemoteDescription(offer)，WebRTC 栈两边都报
  ///     "wrong state" 然后被 catch 吞掉 —— 连接永远恢复不过来。
  ///
  ///     现场现象完全对得上：手机（控制端）上显示"已发送重连 offer（第 2 次）"
  ///     然后卡死，frames 通道一路 RTCDataChannelClosed，画面停在最后一帧；
  ///     被控端重试满 5 次后 _teardown 把 PC 关了，控制端却因为 _pc 还留着
  ///     一条死连接，下次点"连接"复用它 → setRemoteDescription 必失败 →
  ///     用户看到的就是"一点反应都没有"。
  ///
  ///     控制端该做的是**等**：被控端的 offer 一到，_onRemoteOffer 自然接上。
  ///     这里只把 UI 切成"等待对方重连"，绝不发 offer。
  void _scheduleReconnect() {
    if (!isHost) {
      if (!_reconnecting) {
        _reconnecting = true;
        reconnecting.value = true;
        reconnectAttempt.value = 0;
        _log('连接中断，等待对方重连…');
        // 控制端不能自己修连接，但也不能无限等：被控端最多退避 1+2+4+8=15s，
        // 加上它放弃前的余量，25s 还没回来就当场收摊，让用户能重新点"连接"。
        _reconnectTimer?.cancel();
        _reconnectTimer = Timer(const Duration(seconds: 25), () {
          if (!_reconnecting) return;
          _log('对方没有回来，连接已断开');
          _reconnecting = false;
          reconnecting.value = false;
          _reconnectTimer = null;
          unawaited(_teardown(reason: 'timeout'));
        });
      }
      return;
    }
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
      // 数据通道都由**被控端**创建，这里只是接收端。
      // 🔴 必须按 label 分流：自研画面通道会额外建一条 frames 通道，
      //    如果一律当成控制通道，后到的那条会把 _dc 覆盖掉 ——
      //    表现是"鼠标键盘全失灵，画面却是好的"，最容易被误判成网络抖动。
      if (dc.label == kRemoteFrameChannelLabel) {
        _bindFrameChannel(dc);
      } else {
        _bindControlChannel(dc);
      }
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
            // 本地历史只在这一处和 remote:active 帧两处落笔 —— 两条路都覆盖，
            // 且 isController 判定保证被控端不会写进控制端的快捷列表
            unawaited(_recordHistory());
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
          // 🔴 2026-10-25 修：对端把连接关了（被控端重试满 5 次放弃、
          //    或对方主动结束），控制端必须跟着收摊。
          //    不收的危害：_pc 留着一条死连接，下次 redeem() 复用它去
          //    setRemoteDescription 必失败 → 用户点"连接"一点反应都没有。
          if (phase.value != RemotePhase.idle &&
              phase.value != RemotePhase.ended) {
            unawaited(_teardown(reason: 'closed'));
          }
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
      if (!isHost) {
        // 控制端：只接收窗口协议回报（wn/wsok/wg/wst），其余忽略。
        // 键鼠指令的方向是反的，控制端不执行任何输入。
        _handleHostMessage(msg.text);
        return;
      }
      // ⚠️ 红线 1：只有**被控端**且会话已生效时才能执行输入指令。
      // 这是"点了同意之前不能被控"的最后一道保险 —— 服务端已经拦了一层，
      // 但服务端被绕过/实现有 bug 时不该导致用户被悄悄控住。
      if (phase.value != RemotePhase.active) {
        debugPrint('[remote] 忽略未生效会话的控制指令');
        return;
      }
      _execRemoteInput(msg.text);
    };
  }

  /// 控制端侧：处理被控端回来的窗口协议报文。
  void _handleHostMessage(String text) {
    switch (parseWindowHostMessage(text)) {
      case WindowListMessage(:final ok, :final why, :final windows):
        _winListTimer?.cancel();
        _winListTimer = null;
        windowList.value = ok ? windows : const [];
        windowListError.value = ok ? null : why;
      case WindowSelectedMessage(:final info):
        windowMode.value = true;
        currentWindow.value = info;
        windowStateText.value = info.minimized
            ? '窗口已最小化，发送输入会自动还原'
            : '';
      case WindowGoneMessage():
        // 窗口没了：退出窗口模式，UI 提示后可以重新选
        windowMode.value = false;
        currentWindow.value = null;
        windowStateText.value = '目标窗口已关闭';
      case WindowStateMessage(:final state):
        switch (state) {
          case 'min':
            windowStateText.value = '目标窗口已最小化，还原后自动恢复画面';
          case 'off':
            windowStateText.value = '目标窗口不在被控端采集区（搬到了别的屏幕？）';
          case 'ok':
            windowStateText.value = '';
        }
      case null:
        break; // 不是窗口协议报文（比如老版本的画质回报），忽略
    }
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
      case QualityAction(:final level):
        // 画质锁定（UU-c）。被控端是发送端，档位只有在这边能落地；
        // qualityLevel notifier 同步一下，被控端自己的状态条也跟着变。
        final hub = _gdiHub;
        if (hub != null) {
          // 自研画面通道：档位 → (目标宽度, JPEG 质量)，直接下给采集线程。
          // level 为 null 表示"恢复自动"，在没有网络自适应的自研通道里
          // 就等同于回到默认档。
          final lv = (level ?? kRemoteFrameDefaultLevel)
              .clamp(0, kRemoteFrameLevels.length - 1);
          final cfg = kRemoteFrameLevels[lv];
          hub.setTarget(maxWidth: cfg.width, quality: cfg.quality);
          qualityLevel.value = lv;
          _log('画质档位：$lv（${cfg.width}宽 · 质量${cfg.quality}）');
          return;
        }
        unawaited(_degrader?.lock(level));
      case WindowListRequestAction():
        _hostSendWindowList();
      case WindowSelectAction(:final hwnd):
        _hostSelectWindow(hwnd);
      case WindowExitAction():
        _hostExitWindowMode();
      case FrameAckAction(:final framesIn):
        peerFramesIn = framesIn;
    }
  }

  // ------------------------------------------------------------ 窗口模式（被控端）

  /// 响应窗口列表请求。非 Windows / 没有自研画面通道时带回原因 ——
  /// 控制端要能显示"为什么不支持"，而不是一个空列表。
  void _hostSendWindowList() {
    if (!Platform.isWindows) {
      _send(<String, dynamic>{
        't': 'wn',
        'ok': false,
        'why': '被控端不是 Windows 电脑，没有"窗口"可列',
      });
      return;
    }
    final hub = _gdiHub;
    if (hub == null) {
      _send(<String, dynamic>{
        't': 'wn',
        'ok': false,
        'why': '被控端未启用自研画面通道，暂不支持窗口模式',
      });
      return;
    }
    final wins = enumerateWindows();
    if (wins.isEmpty) {
      final why = lastWindowEnumError();
      _send(<String, dynamic>{
        't': 'wn',
        'ok': false,
        'why': why.isEmpty ? '没有找到可投射的窗口' : why,
      });
      return;
    }
    _send(<String, dynamic>{
      't': 'wn',
      'ok': true,
      'win': wins.map((w) => w.toJson()).toList(growable: false),
    });
    _windowCache = wins;
    _log('窗口列表：${wins.length} 个');
  }

  /// 进入窗口模式：采集线程只抓这个窗口，注入坐标按窗口内归一化换算。
  void _hostSelectWindow(int hwnd) {
    final hub = _gdiHub;
    if (hub == null) {
      _send(<String, dynamic>{
        't': 'wn',
        'ok': false,
        'why': '被控端未启用自研画面通道，暂不支持窗口模式',
      });
      return;
    }
    hub.setWindow(hwnd);
    // 注入侧：选中即激活（最小化会先还原），坐标换算跟着切到窗口模式
    _injector.setWindowTarget(hwnd);
    _winHwnd = hwnd;
    _startWindowWatchdog();

    // 立即回报当前矩形（wsok）。取不到就报"窗口异常"，让控制端别干等。
    final rect = _injector.windowTargetRect;
    if (rect == null) {
      _send(<String, dynamic>{
        't': 'wn',
        'ok': false,
        'why': '选中的窗口状态异常（已关闭或正在最小化），请重试',
      });
      _hostExitWindowMode();
      return;
    }
    _send(<String, dynamic>{
      't': 'wsok',
      'w': <String, dynamic>{
        'hwnd': hwnd,
        'title': _windowTitleOf(hwnd),
        'process': _windowProcessOf(hwnd),
        'left': rect.left,
        'top': rect.top,
        'width': rect.width,
        'height': rect.height,
        'min': false,
      },
    });
    _log('窗口模式：hwnd=$hwnd ${rect.width}x${rect.height}');
  }

  /// 退出窗口模式（控制端主动 / 窗口消失 / 异常），回到整屏投射。
  void _hostExitWindowMode() {
    _stopWindowWatchdog();
    _winHwnd = 0;
    _gdiHub?.clearWindow();
    _injector.clearWindowTarget();
  }

  /// 从窗口列表缓存里找标题/进程名（wsok 回报用）。找不到返回空串，
  /// 控制端显示"未知窗口"即可 —— 标题只是展示，不影响功能。
  String _windowTitleOf(int hwnd) {
    for (final w in _windowCache) {
      if (w.hwnd == hwnd) return w.title;
    }
    return '';
  }

  String _windowProcessOf(int hwnd) {
    for (final w in _windowCache) {
      if (w.hwnd == hwnd) return w.process;
    }
    return '';
  }

  /// 窗口看门狗：本地用户把目标窗口关了，控制端要立刻知道
  /// （否则那边看到一个再也不变的最后一帧，以为卡了）。
  void _startWindowWatchdog() {
    _stopWindowWatchdog();
    _winWatchdog = Timer.periodic(const Duration(seconds: 2), (_) {
      final h = _winHwnd;
      if (h == 0) return;
      if (!isWindowAlive(h)) {
        _send(<String, dynamic>{'t': 'wg', 'hwnd': h});
        _log('窗口已关闭（hwnd=$h），退出窗口模式');
        _hostExitWindowMode();
      }
    });
  }

  void _stopWindowWatchdog() {
    _winWatchdog?.cancel();
    _winWatchdog = null;
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
  /// 画质锁定（UU-c）。level=null 恢复自动。
  void sendQuality(int? level) =>
      _send(<String, dynamic>{'t': 'ql', if (level != null) 'lv': level});

  // ---- 窗口模式（控制端 UI 调用）----

  /// 向被控端要窗口列表。结果进 [windowList] / [windowListError]。
  ///
  /// 两个兜底：① 会话还没生效时被控端根本不执行控制指令（红线 1），
  /// 所以这里先挡一道，别让选择器干转；② 老版本被控端不认识 wl，
  /// 永远不回话 —— 8 秒没动静就明说"对方没回应"，不让用户对着一个
  /// 转圈的面板猜是不是自己网络坏了。
  void requestWindowList() {
    windowListError.value = null;
    if (phase.value != RemotePhase.active) {
      windowList.value = null;
      windowListError.value = '会话正在建立，稍等几秒再试';
      return;
    }
    _send(<String, dynamic>{'t': 'wl'});
    _winListTimer?.cancel();
    _winListTimer = Timer(const Duration(seconds: 8), () {
      if (windowList.value == null && windowListError.value == null) {
        windowListError.value = '被控端没有回应（对方可能是旧版本，不支持窗口模式）';
      }
    });
  }

  /// 选中一个窗口开始单窗投射。[hwnd] 来自 [windowList] 里的条目。
  void selectWindow(int hwnd) => _send(<String, dynamic>{'t': 'ws', 'hwnd': hwnd});

  /// 退出窗口模式，回到整屏投射。
  void exitWindowMode() => _send(<String, dynamic>{'t': 'we'});

  // ------------------------------------------------------------ 收尾

  Future<void> _teardown({String reason = ''}) async {
    _hostByFrame = false;
    _lastRedeemCode = '';
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
    // 手动选的档位跟着会话走：不清的话下次进远程页，
    // 菜单勾号还停在上一次会话的选择上，而实际档位早回了自动。
    qualityPick.value = null;
    _degrader?.stop();
    _degrader = null;

    // 自研画面通道收尾：停推帧、关采集线程、清掉控制端手上的最后一帧。
    // 采集线程**必须**显式停 —— 它一直握着屏幕 DC 在抓屏，忘了停就是
    // "会话结束了摄像头还亮着"，用户会怀疑被偷录。
    _stopFrameSendLoop();
    _pendingFrame = null;
    final hub = _gdiHub;
    _gdiHub = null;
    if (hub != null) unawaited(hub.stop());
    // "画面只含主显示器"是自研通道的前提，随会话一起失效 ——
    // 下次可能是手机当被控端（画面=整块屏），留着会让鼠标点偏。
    _injector.usePrimaryOnlyCapture(false);
    // 窗口模式收尾：看门狗、注入目标、控制端状态全部复位。
    // 不清的危害：下次会话控制端 UI 还停在"窗口模式"上，而注入目标
    // 早就换了个人 —— 点哪儿都偏。
    _hostExitWindowMode();
    windowMode.value = false;
    currentWindow.value = null;
    windowList.value = null;
    windowListError.value = null;
    windowStateText.value = '';
    try {
      _frameDc?.close();
    } catch (_) {}
    _frameDc = null;
    _assembler.reset();
    framesIn = 0;
    framesOut = 0;
    framesDropped = 0;
    framesProduced = 0;
    framesBytesOut = 0;
    framesSendError = 0;
    peerFramesIn = null;
    frameSendDcState = 'none';
    frameRecvDcState = 'none';
    framesFragIn = 0;
    framesDecoded = 0;
    framesDecodeFail = 0;
    _ackTimer?.cancel();
    _ackTimer = null;
    frameJpeg.value = null;
    frameSize.value = null;

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
