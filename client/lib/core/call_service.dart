import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../screens/call.dart';
import '../socket.dart';

/// 通话阶段
enum CallPhase {
  idle, // 空闲
  outgoing, // 已呼出，等待对方接听
  incoming, // 收到来电，等待本机接听
  connecting, // 对方已接听，正在交换 SDP / ICE
  active, // 通话中
  ended, // 已结束（界面展示结束原因后自动关闭）
}

/// 一次通话的上下文
class CallSession {
  String callId;
  final int conversationId;
  final int peerId;
  final String peerName;
  final String? peerAvatar;
  final bool outgoing;
  bool video;

  CallSession({
    required this.callId,
    required this.conversationId,
    required this.peerId,
    required this.peerName,
    required this.outgoing,
    required this.video,
    this.peerAvatar,
  });
}

/// ICE 服务器。
///
/// 同网段靠 host candidate 直连，本来不需要 STUN；这里挂一个国内可达的 STUN
/// 是为了覆盖「同网不同段 / 有 NAT 但不严格」的情况。跨公网需要 TURN 中转，
/// 届时把自建 coturn 地址加进这个列表即可，客户端其余代码不用动。
const List<Map<String, dynamic>> kIceServers = [
  {'urls': 'stun:stun.qq.com:3478'},
];

/// 通话引擎（单例）
///
/// 只做三件事：① 通过 WebSocket 与服务端换信令；② 驱动 flutter_webrtc 建连；
/// ③ 把状态暴露成 ValueNotifier 给界面。媒体是 P2P 的，不经过服务端。
class CallService {
  CallService._();
  static final CallService _i = CallService._();
  factory CallService() => _i;

  /// 全局导航 key（main.dart 注入）——来电时可能身处任意页面，靠它推开通话页
  GlobalKey<NavigatorState>? navKey;

  final phase = ValueNotifier<CallPhase>(CallPhase.idle);
  final session = ValueNotifier<CallSession?>(null);

  /// 界面上的实时状态文案（正在呼叫… / 正在连接… / 对方已拒绝 …）
  final status = ValueNotifier<String>('');
  final seconds = ValueNotifier<int>(0);

  final micOn = ValueNotifier<bool>(true);
  final camOn = ValueNotifier<bool>(true);
  final speakerOn = ValueNotifier<bool>(true);

  /// 远端是否已出画面（没出画面时界面显示对方头像占位）
  final remoteVideoOn = ValueNotifier<bool>(false);

  final localRenderer = RTCVideoRenderer();
  final remoteRenderer = RTCVideoRenderer();

  StreamSubscription<dynamic>? _sub;
  bool _attached = false;
  bool _renderersReady = false;

  RTCPeerConnection? _pc;
  MediaStream? _local;
  MediaStream? _remote;

  /// 远端描述还没设置就到的 ICE candidate 先攒着，设置完再补进去
  final List<RTCIceCandidate> _pendingIce = [];
  bool _remoteSet = false;

  Timer? _tick;
  DateTime? _answeredAt;
  bool _ending = false;

  /// 是否已经推过通话页（避免重复 push）
  bool _pushed = false;

  // ---------------------------------------------------------------- 生命周期

  /// App 启动时调一次：订阅实时帧，开始接听来电
  Future<void> attach() async {
    if (_attached) return;
    _attached = true;
    _sub = SocketService().stream.listen(_onFrame);
    SocketService().state.addListener(_onConnState);
  }

  /// 退出登录 / 切换服务器时调用：挂断并复位
  Future<void> resetAll() async {
    await _teardown();
    phase.value = CallPhase.idle;
    session.value = null;
    status.value = '';
  }

  Future<void> dispose() async {
    _sub?.cancel();
    _sub = null;
    _attached = false;
    SocketService().state.removeListener(_onConnState);
    await _teardown();
  }

  void _onConnState() {
    // WebSocket 断了，服务端已经把通话拆了（另一端会收到 call:ended）。
    // 本地必须跟着结束，否则界面会一直停在"通话中"。
    if (SocketService().state.value == ConnState.offline &&
        phase.value != CallPhase.idle &&
        phase.value != CallPhase.ended) {
      _finish('网络已断开');
    }
  }

  // ------------------------------------------------------------------ 发起方

  /// 发起通话。返回 null 表示已发起，否则返回失败原因（直接展示给用户）。
  Future<String?> startCall({
    required int conversationId,
    required int peerId,
    required String peerName,
    String? peerAvatar,
    required bool video,
  }) async {
    if (phase.value != CallPhase.idle) return '你正在通话中，请先挂断';
    if (SocketService().state.value != ConnState.online) return '未连接到服务器，无法呼叫';

    final s = CallSession(
      callId: '',
      conversationId: conversationId,
      peerId: peerId,
      peerName: peerName,
      peerAvatar: peerAvatar,
      outgoing: true,
      video: video,
    );
    session.value = s;
    phase.value = CallPhase.outgoing;
    status.value = '正在呼叫…';

    // 先取本地媒体：一来对方接听后能立刻出画面，二来把摄像头/麦克风权限
    // 的弹窗提前到"点按钮"这一刻，权限被拒也能马上告诉用户。
    final err = await _prepareLocal(video);
    if (err != null) {
      phase.value = CallPhase.idle;
      session.value = null;
      return err;
    }

    _pushScreen();
    SocketService().send({
      'type': 'call:invite',
      'conversationId': conversationId,
      'calleeId': peerId,
      'mode': video ? 'video' : 'audio',
    });
    return null;
  }

  // ------------------------------------------------------------------ 接听方

  /// 接听来电
  Future<void> accept() async {
    final s = session.value;
    if (s == null || phase.value != CallPhase.incoming) return;
    phase.value = CallPhase.connecting;
    status.value = '正在连接…';

    final err = await _prepareLocal(s.video);
    if (err != null) {
      SocketService().send({'type': 'call:reject', 'callId': s.callId, 'reason': 'media'});
      _finish(err);
      return;
    }
    SocketService().send({'type': 'call:accept', 'callId': s.callId});
  }

  /// 拒接来电
  void reject() {
    final s = session.value;
    if (s == null) return;
    SocketService().send({'type': 'call:reject', 'callId': s.callId});
    _finish('已拒绝');
  }

  /// 挂断 / 取消呼叫
  void hangup() {
    final s = session.value;
    if (s == null) return;
    if (phase.value == CallPhase.outgoing) {
      SocketService().send({'type': 'call:cancel', 'callId': s.callId});
      _finish('已取消');
    } else {
      SocketService().send({'type': 'call:end', 'callId': s.callId});
      _finish('通话已结束');
    }
  }

  // -------------------------------------------------------------------- 控制

  void toggleMic() {
    final tracks = _local?.getAudioTracks() ?? const [];
    if (tracks.isEmpty) return;
    micOn.value = !micOn.value;
    for (final t in tracks) {
      t.enabled = micOn.value;
    }
  }

  void toggleCam() {
    final tracks = _local?.getVideoTracks() ?? const [];
    if (tracks.isEmpty) return;
    camOn.value = !camOn.value;
    for (final t in tracks) {
      t.enabled = camOn.value;
    }
  }

  Future<void> switchCamera() async {
    final tracks = _local?.getVideoTracks() ?? const [];
    if (tracks.isEmpty) return;
    try {
      await Helper.switchCamera(tracks.first);
    } catch (_) {
      /* 桌面端/单摄像头设备不支持翻转，忽略 */
    }
  }

  Future<void> toggleSpeaker() async {
    if (!Platform.isAndroid && !Platform.isIOS) return;
    speakerOn.value = !speakerOn.value;
    try {
      await Helper.setSpeakerphoneOn(speakerOn.value);
    } catch (_) {
      /* 忽略 */
    }
  }

  // ------------------------------------------------------------ 信令帧处理

  void _onFrame(dynamic raw) {
    if (raw is! Map) return;
    final type = raw['type'];
    if (type is! String || !type.startsWith('call:')) return;
    try {
      switch (type) {
        case 'call:incoming':
          _onIncoming(raw);
          break;
        case 'call:ringing':
          _onRinging(raw);
          break;
        case 'call:accepted':
          _onAccepted(raw);
          break;
        case 'call:handled':
          _onHandled(raw);
          break;
        case 'call:offer':
          _onOffer(raw);
          break;
        case 'call:answer':
          _onAnswer(raw);
          break;
        case 'call:ice':
          _onIce(raw);
          break;
        case 'call:rejected':
          _onRejected(raw);
          break;
        case 'call:canceled':
          _onCanceled(raw);
          break;
        case 'call:timeout':
          _onTimeout(raw);
          break;
        case 'call:busy':
          _finish('对方正在通话中');
          break;
        case 'call:ended':
          _onEnded(raw);
          break;
      }
    } catch (e) {
      debugPrint('[call] 处理 $type 失败: $e');
    }
  }

  void _onIncoming(Map raw) {
    // 已经在通话里：直接回绝，别让对方一直等
    if (phase.value != CallPhase.idle) {
      SocketService().send({
        'type': 'call:reject',
        'callId': raw['callId'],
        'reason': 'busy',
      });
      return;
    }
    final video = raw['mode'] != 'audio';
    session.value = CallSession(
      callId: '${raw['callId']}',
      conversationId: (raw['conversationId'] as num?)?.toInt() ?? 0,
      peerId: (raw['callerId'] as num?)?.toInt() ?? 0,
      peerName: '${raw['callerName'] ?? '对方'}',
      peerAvatar: raw['callerAvatar'] as String?,
      outgoing: false,
      video: video,
    );
    phase.value = CallPhase.incoming;
    status.value = video ? '邀请你视频通话' : '邀请你语音通话';
    camOn.value = video;
    _buzz();
    _pushScreen();
  }

  void _onRinging(Map raw) {
    final s = session.value;
    if (s == null || !s.outgoing) return;
    s.callId = '${raw['callId']}';
  }

  /// 被叫的其他设备收到「已在本机接听」→ 收起来电界面
  void _onHandled(Map raw) {
    if (phase.value != CallPhase.incoming) return;
    final s = session.value;
    if (s == null || s.callId != '${raw['callId']}') return;
    _finish('已在其他设备接听');
  }

  Future<void> _onAccepted(Map raw) async {
    final s = session.value;
    if (s == null || !s.outgoing) return;
    phase.value = CallPhase.connecting;
    status.value = '正在连接…';
    _answeredAt = DateTime.now();
    _startTick();

    // 主叫负责发 offer
    final pc = await _ensurePeer();
    if (pc == null) return;
    final offer = await pc.createOffer();
    await pc.setLocalDescription(offer);
    _send('offer', offer.toMap());
  }

  Future<void> _onOffer(Map raw) async {
    final s = session.value;
    if (s == null || s.outgoing) return;
    final pc = await _ensurePeer();
    if (pc == null) return;

    final d = (raw['data'] as Map?) ?? const {};
    await pc.setRemoteDescription(
        RTCSessionDescription('${d['sdp']}', '${d['type']}'));
    _remoteSet = true;
    await _flushIce();

    final answer = await pc.createAnswer();
    await pc.setLocalDescription(answer);
    _send('answer', answer.toMap());
    _answeredAt ??= DateTime.now();
    _startTick();
  }

  Future<void> _onAnswer(Map raw) async {
    final pc = _pc;
    if (pc == null) return;
    final d = (raw['data'] as Map?) ?? const {};
    await pc.setRemoteDescription(
        RTCSessionDescription('${d['sdp']}', '${d['type']}'));
    _remoteSet = true;
    await _flushIce();
  }

  Future<void> _onIce(Map raw) async {
    final d = (raw['data'] as Map?) ?? const {};
    final cand = RTCIceCandidate(
      d['candidate'] as String?,
      d['sdpMid'] as String?,
      (d['sdpMLineIndex'] as num?)?.toInt(),
    );
    if (cand.candidate == null || cand.candidate!.isEmpty) return;
    final pc = _pc;
    if (pc == null || !_remoteSet) {
      _pendingIce.add(cand);
      return;
    }
    try {
      await pc.addCandidate(cand);
    } catch (e) {
      debugPrint('[call] addCandidate 失败: $e');
    }
  }

  Future<void> _flushIce() async {
    final pc = _pc;
    if (pc == null) return;
    final list = List<RTCIceCandidate>.from(_pendingIce);
    _pendingIce.clear();
    for (final c in list) {
      try {
        await pc.addCandidate(c);
      } catch (_) {
        /* 单个候选失败不影响其它 */
      }
    }
  }

  void _onRejected(Map raw) {
    _finish(raw['reason'] == 'busy' ? '对方忙线中' : '对方已拒绝');
  }

  void _onCanceled(Map raw) {
    _finish(raw['reason'] == 'timeout' ? '无人接听' : '对方已取消');
  }

  void _onTimeout(Map raw) => _finish('无人接听');

  void _onEnded(Map raw) {
    final reason = raw['reason'];
    final text = switch (reason) {
      'unreachable' => '对方不在线',
      'peer-offline' => '对方已断开',
      'timeout' => '通话超时结束',
      _ => '通话已结束',
    };
    _finish(text);
  }

  // -------------------------------------------------------------- WebRTC

  Future<RTCPeerConnection?> _ensurePeer() async {
    if (_pc != null) return _pc;
    await _ensureRenderers();

    final pc = await createPeerConnection({
      'iceServers': kIceServers,
      'sdpSemantics': 'unified-plan',
    });

    // 本地轨道推进连接
    for (final t in _local?.getTracks() ?? const []) {
      await pc.addTrack(t, _local!);
    }

    pc.onIceCandidate = (cand) {
      if (cand.candidate == null || cand.candidate!.isEmpty) return;
      _send('ice', cand.toMap());
    };

    pc.onTrack = (event) {
      if (event.streams.isNotEmpty) {
        _remote = event.streams.first;
        remoteRenderer.srcObject = _remote;
        if (event.track.kind == 'video') remoteVideoOn.value = true;
      }
    };

    pc.onConnectionState = (st) {
      switch (st) {
        case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
          if (phase.value != CallPhase.active) {
            phase.value = CallPhase.active;
            status.value = '通话中';
            _answeredAt ??= DateTime.now();
            _startTick();
          }
          break;
        case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
          _finish('连接失败，可能不在同一网络');
          break;
        case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
          if (phase.value == CallPhase.active) status.value = '连接不稳定…';
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

  void _send(String kind, Map<String, dynamic> data) {
    final s = session.value;
    if (s == null || s.callId.isEmpty) return;
    SocketService().send({
      'type': 'call:$kind',
      'callId': s.callId,
      'data': data,
    });
  }

  Future<void> _ensureRenderers() async {
    if (_renderersReady) return;
    _renderersReady = true;
    try {
      await localRenderer.initialize();
    } catch (e) {
      debugPrint('[call] localRenderer 初始化失败: $e');
    }
    try {
      await remoteRenderer.initialize();
    } catch (e) {
      debugPrint('[call] remoteRenderer 初始化失败: $e');
    }
  }

  /// 取本地音视频。返回 null = 成功，否则返回失败原因。
  /// 视频取不到（没摄像头 / 被别的程序占着）时自动降级成语音，不让通话直接失败。
  Future<String?> _prepareLocal(bool video) async {
    await _ensureRenderers();
    if (_local != null) {
      localRenderer.srcObject = _local;
      return null;
    }
    try {
      _local = await navigator.mediaDevices.getUserMedia({
        'audio': true,
        'video': video
            ? {
                'facingMode': 'user',
                'width': {'ideal': 1280},
                'height': {'ideal': 720},
                'frameRate': {'ideal': 24},
              }
            : false,
      });
    } catch (e) {
      if (!video) {
        return '无法访问麦克风，请检查权限';
      }
      // 摄像头不可用 → 降级语音
      try {
        _local = await navigator.mediaDevices
            .getUserMedia({'audio': true, 'video': false});
        final s = session.value;
        if (s != null) {
          s.video = false;
          camOn.value = false;
        }
      } catch (_) {
        return '无法访问摄像头和麦克风，请检查权限';
      }
    }
    localRenderer.srcObject = _local;
    if (video && (_local?.getVideoTracks().isEmpty ?? true)) {
      final s = session.value;
      if (s != null) {
        s.video = false;
        camOn.value = false;
      }
    }
    return null;
  }

  // ------------------------------------------------------------------ 收尾

  void _startTick() {
    _tick?.cancel();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      final at = _answeredAt;
      if (at == null) return;
      seconds.value = DateTime.now().difference(at).inSeconds;
    });
  }

  void _buzz() {
    // 来电震动提醒（Android 有效，桌面端静默忽略）
    if (!Platform.isAndroid) return;
    var n = 0;
    Timer.periodic(const Duration(milliseconds: 900), (t) {
      if (phase.value != CallPhase.incoming) {
        t.cancel();
        return;
      }
      if (n++ > 30) {
        t.cancel();
        return;
      }
      HapticFeedback.vibrate();
    });
  }

  void _finish(String reason) {
    if (_ending) return;
    _ending = true;
    status.value = reason;
    phase.value = CallPhase.ended;
    _teardown().then((_) {
      // 界面留 1.2 秒展示结束原因，再自动关闭
      Timer(const Duration(milliseconds: 1200), () {
        phase.value = CallPhase.idle;
        session.value = null;
        _ending = false;
      });
    });
  }

  Future<void> _teardown() async {
    _tick?.cancel();
    _tick = null;
    _answeredAt = null;
    _remoteSet = false;
    _pendingIce.clear();

    final pc = _pc;
    _pc = null;
    if (pc != null) {
      try {
        await pc.close();
      } catch (_) {
        /* 忽略 */
      }
    }

    final local = _local;
    _local = null;
    if (local != null) {
      for (final t in local.getTracks()) {
        try {
          await t.stop();
        } catch (_) {
          /* 忽略 */
        }
      }
      try {
        await local.dispose();
      } catch (_) {
        /* 忽略 */
      }
    }

    _remote = null;
    try {
      remoteRenderer.srcObject = null;
      localRenderer.srcObject = null;
    } catch (_) {
      /* 渲染器可能已释放 */
    }
    remoteVideoOn.value = false;
    seconds.value = 0;
    micOn.value = true;
    camOn.value = true;
  }

  void _pushScreen() {
    if (_pushed) return;
    final nav = navKey?.currentState;
    if (nav == null) return;
    _pushed = true;
    nav
        .push(MaterialPageRoute(
          fullscreenDialog: true,
          builder: (_) => const CallScreen(),
        ))
        .then((_) => _pushed = false);
  }
}
