import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../api.dart';
import '../screens/call.dart';
import '../socket.dart';
import 'sound_service.dart';

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

/// ICE 服务器**兜底**列表。
///
/// 正常情况下用服务端下发的配置（见 [_resolveIceServers]），这里只是
/// 拉不到配置时的保险。注意 `stun.qq.com` 已经被剔除 —— 2026-09 实测在
/// 黑龙江电信会被直接 RST，留着只会白白拖慢候选收集。
const List<Map<String, dynamic>> kIceServers = [
  {'urls': 'stun:stun.miwifi.com:3478'},
  {'urls': 'stun:stun.chat.bilibili.com:3478'},
  {'urls': 'stun:stun.hitv.com:3478'},
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

  /// 远端接收诊断信息（长按通话页对方名字可查看）。
  /// 只为排障：不同平台 onTrack / 接收器的行为差异很大，把过程记下来，
  /// 出问题时不用重开 debug 构建去抓日志。
  final remoteDiag = ValueNotifier<String>('');

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
  Timer? _graceTimer;
  Timer? _endTimer;
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
    // 铃声跟着通话阶段走：来电=振铃、呼出=回铃、其余（接通/结束/空闲）立刻停。
    // 放在监听里而不是各个业务分支里，避免漏掉某条结束路径导致铃声一直响。
    phase.addListener(_syncTone);
    // 相位跃迁也记进诊断面板：线上（release 包）看不到 debugPrint，
    // 出问题时"phase 到底走到哪一步"是第一个要问的问题。
    phase.addListener(_diagPhase);
  }

  /// 记一条相位跃迁。诊断面板里能看到 `incoming → connecting → active` 的完整时间线，
  /// 一眼就能判断是"卡在来电没往下走"还是"接通了但没画面"。
  void _diagPhase() => _diag('阶段 → ${phase.value.name}');

  void _syncTone() {
    switch (phase.value) {
      case CallPhase.incoming:
        unawaited(SoundService().setTone(CallTone.incoming));
        break;
      case CallPhase.outgoing:
        unawaited(SoundService().setTone(CallTone.outgoing));
        break;
      default:
        unawaited(SoundService().setTone(CallTone.none));
    }
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
    // 顺手摘掉 phase 监听：attach/dispose 可反复调用，不摘会叠加重复监听
    phase.removeListener(_syncTone);
    phase.removeListener(_diagPhase);
    await _teardown();
  }

  void _onConnState() {
    // WebSocket 断了，服务端已经把通话拆了（另一端会收到 call:ended）。
    // 本地必须跟着结束，否则界面会一直停在"通话中"。
    //
    // 但**还没接通的阶段**（来电响铃 / 呼出等待）要网开一面：外网下 WS
    // 抖动是常态，一断就掐掉来电界面，用户压根来不及接。给 20 秒宽限期，
    // 期间重连成功会由服务端补推 call:incoming 把界面接回来
    // （服务端振铃超时 45 秒，且掉线判定也有 20 秒宽限，所以这里是安全的）。
    if (SocketService().state.value == ConnState.online) {
      _graceTimer?.cancel();
      return;
    }
    if (phase.value == CallPhase.idle || phase.value == CallPhase.ended) return;

    final notYetConnected = phase.value == CallPhase.incoming ||
        phase.value == CallPhase.outgoing;
    if (!notYetConnected) {
      _finish('网络已断开');
      return;
    }

    status.value = '网络不稳，正在重连…';
    _graceTimer?.cancel();
    _graceTimer = Timer(const Duration(seconds: 20), () {
      if (SocketService().state.value != ConnState.online &&
          (phase.value == CallPhase.incoming ||
              phase.value == CallPhase.outgoing)) {
        _finish('网络已断开');
      }
    });
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
    // 已经在通话里：直接回绝，别让对方一直等。
    //
    // 例外：`ended` 只是"上一通刚结束、界面还在展示原因"的 1.2 秒过渡态，
    // 此时完全可以接新来电。放行它对"外网断线重连后服务端补推来电"很关键 ——
    // 补推往往就落在上一通被判定断线后的那一两秒内，卡在这里就白补了。
    if (phase.value != CallPhase.idle && phase.value != CallPhase.ended) {
      SocketService().send({
        'type': 'call:reject',
        'callId': raw['callId'],
        'reason': 'busy',
      });
      return;
    }
    // 取消上一通的收尾定时器，否则它 1.2 秒后会把 session 清空，
    // 来电界面会变成一片空白。
    _endTimer?.cancel();
    _ending = false;

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

  /// 服务端下发的 ICE 配置缓存
  List<Map<String, dynamic>>? _iceCache;
  DateTime? _iceCachedAt;

  /// 解析本次通话要用的 ICE 服务器列表。
  ///
  /// 优先用服务端下发的（`GET /api/call/ice`）—— 服务端配了 coturn 中继时，
  /// 对称 NAT / 手机流量这类打不通洞的场景才有兜底。拉不到就用内置 STUN。
  /// 结果缓存 5 分钟，避免每通电话都多一次往返。
  Future<List<Map<String, dynamic>>> _resolveIceServers() async {
    final at = _iceCachedAt;
    if (_iceCache != null &&
        at != null &&
        DateTime.now().difference(at) < const Duration(minutes: 5)) {
      return _iceCache!;
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
          _iceCache = list;
          _iceCachedAt = DateTime.now();
          final turn = d['turnConfigured'] == true;
          _diag('ICE 配置已下发：${list.length} 项'
              '${turn ? '，含 TURN 中继' : '，仅 STUN 无中继'}');
          return list;
        }
      }
      _diag('服务端 ICE 配置为空，改用内置 STUN');
    } catch (e) {
      _diag('拉取 ICE 配置失败（$e），改用内置 STUN');
    }
    _iceCache = kIceServers;
    _iceCachedAt = DateTime.now();
    return kIceServers;
  }

  Future<RTCPeerConnection?> _ensurePeer() async {
    if (_pc != null) return _pc;
    await _ensureRenderers();

    final pc = await createPeerConnection({
      'iceServers': await _resolveIceServers(),
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

    // 远端轨道到达。
    //
    // ⚠️ 平台差异（必踩）：Android / iOS 的 onTrack 事件里 `streams` 是有值的，
    // 而 Windows 桌面端（flutter_webrtc 的桌面实现）**经常返回空列表**。
    // 老代码只在 streams 非空时才 setState 渲染器，于是 Windows 端：
    //   srcObject 永远是 null（画面全黑） + remoteVideoOn 永远 false（连
    //   RTCVideoView 都不挂载）→ 表现就是"手机端正常、电脑端黑屏"。
    // 所以这里统一按轨道兜底：没有 stream 就自己建一个装进去。
    pc.onTrack = (event) {
      if (event.streams.isNotEmpty) {
        _remote = event.streams.first;
        if (event.track.kind == 'video') remoteVideoOn.value = true;
        remoteRenderer.srcObject = _remote;
        _diag('轨道到达(${event.track.kind})：带 stream，直接用');
        return;
      }
      _diag('轨道到达(${event.track.kind})：无 stream，按轨道自建');
      _attachRemoteTrack(event.track);
    };

    pc.onConnectionState = (st) {
      switch (st) {
        case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
          _diag('连接已建立（connected）');
          // 兜底：万一平台没触发 onTrack，这里主动把已到达的轨道捞回来渲染
          unawaited(_sweepReceivers());
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

  /// 记一条接收诊断（同时打到日志，release 包也能靠界面查看）
  void _diag(String line) {
    debugPrint('[call] $line');
    final ts = DateTime.now().toIso8601String().substring(11, 19);
    final old = remoteDiag.value;
    remoteDiag.value = old.isEmpty ? '$ts $line' : '$old\n$ts $line';
  }

  /// 把一条远端轨道挂到远端渲染器上。
  ///
  /// 桌面端 onTrack 不带 streams，必须自己组装 MediaStream。注意同一路媒体的
  /// 音频轨和视频轨是分两次到达的，所以**复用同一个流**，否则后到的会把先到的顶掉
  /// （典型症状：挂了视频就没声音，或反之）。
  Future<void> _attachRemoteTrack(MediaStreamTrack track) async {
    var stream = _remote;
    if (stream == null) {
      try {
        stream = await createLocalMediaStream('remote');
        _remote = stream;
      } catch (e) {
        _diag('自建远端流失败: $e');
        return;
      }
    }
    final exists = stream.getTracks().any((t) => t.id == track.id);
    if (!exists) {
      try {
        await stream.addTrack(track);
      } catch (e) {
        _diag('挂载 ${track.kind} 轨道失败: $e');
      }
    }
    if (track.kind == 'video') remoteVideoOn.value = true;
    remoteRenderer.srcObject = stream;
    _diag('已挂载 ${track.kind}（当前共 ${stream.getTracks().length} 轨）');
  }

  /// 兜底扫描：个别平台/版本不触发 onTrack，连接建立后主动去接收器里捞轨道。
  Future<void> _sweepReceivers() async {
    final pc = _pc;
    if (pc == null) return;
    try {
      final rs = await pc.getReceivers();
      for (final r in rs) {
        final t = r.track;
        if (t != null) await _attachRemoteTrack(t);
      }
      _diag('接收器扫描：共 ${rs.length} 个');
    } catch (e) {
      _diag('接收器扫描失败: $e');
    }
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
    // 第一帧真正渲染出来才算"对方出画面"——比"收到轨道"更准，
    // 有的平台轨道到了却迟迟解不出画面。两个信号都置 true，取或，双保险。
    try {
      remoteRenderer.onFirstFrameRendered = () {
        _diag('远端首帧已渲染');
        remoteVideoOn.value = true;
      };
    } catch (e) {
      debugPrint('[call] onFirstFrameRendered 挂载失败: $e');
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
      _endTimer?.cancel();
      _endTimer = Timer(const Duration(milliseconds: 1200), () {
        // 期间若来了新来电，_onIncoming 会复位 _ending 并取消这个定时器，
        // 这里就不会误清 session（否则来电界面会变成空白）。
        if (!_ending) return;
        phase.value = CallPhase.idle;
        session.value = null;
        _ending = false;
      });
    });
  }

  Future<void> _teardown() async {
    _tick?.cancel();
    _tick = null;
    _graceTimer?.cancel();
    _graceTimer = null;
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
    remoteDiag.value = '';
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
