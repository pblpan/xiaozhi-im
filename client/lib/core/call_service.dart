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
  connecting, // 至少一人已接听，正在交换 SDP / ICE
  active, // 通话中
  ended, // 已结束（界面展示结束原因后自动关闭）
}

/// 通话中的一个人（1v1 时只有一个，群通话时多个）
class CallPeer {
  final int userId;
  final String name;
  final String? avatar;

  /// 远端是否已出画面（视频模式下用它决定渲染 RTCVideoView 还是头像占位）
  final ValueNotifier<bool> videoOn = ValueNotifier<bool>(false);

  /// 该路的连接状态诊断（排障时按人查看，比一条全局日志清楚）
  String diag = '';

  CallPeer({required this.userId, required this.name, this.avatar});
}

/// 一次通话的上下文
///
/// 【多人化改造】原来只有 `peerId / peerName / peerAvatar` 三个单值字段，
/// 现在改成 `peers` 列表。1v1 就是只有一个元素的列表 —— 上层界面按人数
/// 走不同布局，不用再区分"这是群通话还是单聊通话"。
class CallSession {
  String callId;
  final int conversationId;

  /// 通话中除自己以外的所有人。发起时会话里先放一份"预期名单"，
  /// 对方真正接听后由服务端下发的 participants 覆盖（真实在线名单）。
  List<CallPeer> peers;

  /// 是否自己发起的（界面文案与按钮不同）
  final bool outgoing;
  bool video;

  /// 群通话：界面标题显示会话名，而不是某个人名
  final bool group;
  final String? groupName;

  CallSession({
    required this.callId,
    required this.conversationId,
    required this.peers,
    required this.outgoing,
    required this.video,
    this.group = false,
    this.groupName,
  });

  /// 通话界面顶栏标题
  String get title {
    if (group) return groupName ?? '群通话';
    return peers.isNotEmpty ? peers.first.name : '通话';
  }

  /// 1v1 时的对方（群通话返回 null）
  CallPeer? get solePeer => (!group && peers.length == 1) ? peers.first : null;

  CallPeer? peerOf(int userId) {
    for (final p in peers) {
      if (p.userId == userId) return p;
    }
    return null;
  }
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

/// 单条 peer 连接的封装。
///
/// 【为什么需要这个类】1v1 时代全服务只有一份 `_pc / _remote / _pendingIce /
/// _remoteSet`，多人之后每个人都要独立一套 —— 三个人通话会有 2 条连接，
/// 各自有独立的 SDP 协商进度、独立的 ICE 队列、独立的渲染器。用状态机把
/// 它们各自隔离，避免"B 的 ICE 塞进了 C 的连接"这类串线问题。
class _PeerLink {
  final int userId;

  /// 远端是否已出画面（界面订阅它，用于决定该格子渲染视频还是头像）
  final ValueNotifier<bool> videoOn;

  RTCPeerConnection? pc;
  MediaStream? remote;
  final RTCVideoRenderer renderer = RTCVideoRenderer();

  /// 远端描述还没设置就到的 ICE candidate 先攒着，设置完再补进去
  final List<RTCIceCandidate> pendingIce = [];
  bool remoteSet = false;
  bool rendererReady = false;

  _PeerLink({required this.userId, required this.videoOn});

  /// 是否有远端视频在推（决定界面渲染视频还是头像）
  bool get hasVideo => videoOn.value;

  Future<void> dispose() async {
    try {
      await pc?.close();
    } catch (_) {
      /* 忽略 */
    }
    pc = null;
    try {
      renderer.srcObject = null;
    } catch (_) {
      /* 忽略 */
    }
    try {
      await renderer.dispose();
    } catch (_) {
      /* 忽略 */
    }
    remote = null;
    videoOn.dispose();
  }
}

/// 通话引擎（单例）
///
/// 只做三件事：① 通过 WebSocket 与服务端换信令；② 驱动 flutter_webrtc 建连；
/// ③ 把状态暴露成 ValueNotifier 给界面。媒体是 P2P mesh 的，不经过服务端。
///
/// 【mesh 拓扑约定，必须与服务端 call.js 一致】
///   1. **已在房间里的人向新加入者发 offer**。后加入者只接收，不主动发。
///      固定这一条是为了避免双方同时发 offer 撞车（glare）。
///      判断依据是服务端下发的 `call:peer-joined`：收到它就说明"我该向这个人
///      发 offer"，而 `call:joined` 的 `peers` 列表说明"这些人会来连我"。
///   2. 所有 offer / answer / ice 都必须带 `to`，否则服务端会广播给所有人。
///   3. 1v1 时代主叫靠 `call:accepted` 触发发 offer，这条路径仍然保留
///      （老协议兼容），群通话里主叫改为靠 `call:peer-joined` 触发。
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

  /// 当前在线的远端人数（界面显示"通话中 3 人"）
  final peerCount = ValueNotifier<int>(0);

  final seconds = ValueNotifier<int>(0);

  final micOn = ValueNotifier<bool>(true);
  final camOn = ValueNotifier<bool>(true);
  final speakerOn = ValueNotifier<bool>(true);

  /// 远端接收诊断信息（长按通话页对方名字可查看）。
  /// 只为排障：不同平台 onTrack / 接收器的行为差异很大，把过程记下来，
  /// 出问题时不用重开 debug 构建去抓日志。
  final remoteDiag = ValueNotifier<String>('');

  final localRenderer = RTCVideoRenderer();

  /// userId -> 该路的媒体连接。**键就是远端用户 id**，这是防串线的根本。
  final Map<int, _PeerLink> _links = {};

  /// userId -> 在连接建立之前就到达的 ICE 候选。
  ///
  /// mesh 里 ICE 常常先于 offer 抵达（尤其对端已经在推候选了，而本地还没
  /// 收到 offer 建连）。丢掉这些候选会显著拖慢甚至破坏连通性，所以按人缓存，
  /// 建连时一次性补进去。
  final Map<int, List<RTCIceCandidate>> _orphanIce = {};

  StreamSubscription<dynamic>? _sub;
  bool _attached = false;
  bool _localRendererReady = false;

  MediaStream? _local;

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

  /// 发起 1v1 通话。返回 null 表示已发起，否则返回失败原因（直接展示给用户）。
  Future<String?> startCall({
    required int conversationId,
    required int peerId,
    required String peerName,
    String? peerAvatar,
    required bool video,
  }) =>
      startGroupCall(
        conversationId: conversationId,
        video: video,
        peers: [CallPeer(userId: peerId, name: peerName, avatar: peerAvatar)],
      );

  /// 发起通话（1v1 或群通话）。
  ///
  /// [peers] 是"预期参会名单"，用于发起的那一刻就把界面画出来（否则要等
  /// 服务端回帧才有人名可显示）。真正的在线名单由服务端 participants 覆盖。
  /// 群通话里可以只传空列表 —— 此时服务端会邀请群内所有其他成员。
  Future<String?> startGroupCall({
    required int conversationId,
    required bool video,
    List<CallPeer> peers = const [],
    bool group = false,
    String? groupName,
  }) async {
    if (phase.value != CallPhase.idle) return '你正在通话中，请先挂断';
    if (SocketService().state.value != ConnState.online) return '未连接到服务器，无法呼叫';

    final s = CallSession(
      callId: '',
      conversationId: conversationId,
      peers: List<CallPeer>.from(peers),
      outgoing: true,
      video: video,
      group: group,
      groupName: groupName,
    );
    session.value = s;
    peerCount.value = 0;
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
    // 群通话不传 calleeId/calleeIds → 服务端邀请群内全体其他成员
    SocketService().send({
      'type': 'call:invite',
      'conversationId': conversationId,
      if (!group && peers.isNotEmpty) 'calleeId': peers.first.userId,
      'mode': video ? 'video' : 'audio',
    });
    return null;
  }

  /// 加入一通正在进行中的群通话（群里"我也进去"）。
  Future<String?> joinOngoing({
    required String callId,
    required int conversationId,
    required bool video,
    String? groupName,
  }) async {
    if (phase.value != CallPhase.idle) return '你正在通话中，请先挂断';
    if (SocketService().state.value != ConnState.online) return '未连接到服务器，无法加入';

    session.value = CallSession(
      callId: callId,
      conversationId: conversationId,
      peers: [],
      outgoing: false,
      video: video,
      group: true,
      groupName: groupName,
    );
    peerCount.value = 0;
    phase.value = CallPhase.connecting;
    status.value = '正在加入…';

    final err = await _prepareLocal(video);
    if (err != null) {
      phase.value = CallPhase.idle;
      session.value = null;
      return err;
    }
    _pushScreen();
    SocketService().send({'type': 'call:join', 'callId': callId});
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

  /// 挂断 / 取消呼叫 / 退出群通话
  ///
  /// 群通话里这是"我退出"，其余人继续 —— 服务端负责这个语义，客户端只管发。
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

  /// 取某一路远端的渲染器，供通话页的网格格子挂 RTCVideoView。
  ///
  /// 界面必须拿**这一路自己的** renderer —— 多人时如果所有格子都指向同一个
  /// renderer，会出现"每个格子都在放同一个人"的错觉，实际是最后一路把前面
  /// 全部顶掉了。连接还没建起来时返回 null，格子会自动退回头像占位。
  RTCVideoRenderer? rendererFor(int userId) => _links[userId]?.renderer;

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
        case 'call:joined':
          _onJoined(raw);
          break;
        case 'call:peer-joined':
          _onPeerJoined(raw);
          break;
        case 'call:peer-left':
          _onPeerLeft(raw);
          break;
        case 'call:updated':
          _onUpdated(raw);
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
          // silent=true 是群通话里"某个人忙线没叫到"的提示，不该整通失败
          if (raw['silent'] == true) {
            _diag('有人忙线未加入');
            break;
          }
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

  /// 从服务端帧里解析参与者名单，覆盖本地 peers
  List<CallPeer> _peersFrom(Map raw, {int? exclude}) {
    final list = raw['participants'];
    if (list is! List) return [];
    final out = <CallPeer>[];
    for (final e in list) {
      if (e is! Map) continue;
      final uid = (e['userId'] as num?)?.toInt();
      if (uid == null || uid == exclude) continue;
      out.add(CallPeer(
        userId: uid,
        name: '${e['name'] ?? '对方'}',
        avatar: e['avatar'] as String?,
      ));
    }
    return out;
  }

  /// 按"保留已有 CallPeer 对象"的方式合并名单。
  ///
  /// ⚠️ 不能直接 `session.peers = 新列表`。CallPeer 上的 `videoOn` 是
  /// ValueNotifier，界面用它订阅"这一路出画面了没"；每次重建对象就等于
  /// 把订阅全扔掉，画面会闪一下就黑掉。所以按 userId 复用已有对象。
  void _mergePeers(List<CallPeer> incoming) {
    final s = session.value;
    if (s == null) return;
    final oldByUid = {for (final p in s.peers) p.userId: p};
    final merged = <CallPeer>[];
    for (final p in incoming) {
      merged.add(oldByUid[p.userId] ?? p);
    }
    s.peers = merged;
    session.value = s;
    peerCount.value = merged.length;
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
    final isGroup = raw['group'] == true;
    // 来电时把发起人也算进 peers，这样界面立刻有人名可显示
    final callerId = (raw['callerId'] as num?)?.toInt() ?? 0;
    final list = _peersFrom(raw);
    if (!list.any((p) => p.userId == callerId) && callerId != 0) {
      list.insert(0, CallPeer(
        userId: callerId,
        name: '${raw['callerName'] ?? '对方'}',
        avatar: raw['callerAvatar'] as String?,
      ));
    }

    session.value = CallSession(
      callId: '${raw['callId']}',
      conversationId: (raw['conversationId'] as num?)?.toInt() ?? 0,
      peers: list,
      outgoing: false,
      video: video,
      group: isGroup,
      groupName: isGroup ? '${raw['groupName'] ?? '群通话'}' : null,
    );
    peerCount.value = list.length;
    phase.value = CallPhase.incoming;
    if (isGroup) {
      final n = list.length;
      status.value = video ? '邀请你加入群视频（$n 人）' : '邀请你加入群语音（$n 人）';
    } else {
      status.value = video ? '邀请你视频通话' : '邀请你语音通话';
    }
    camOn.value = video;
    _buzz();
    _pushScreen();
  }

  void _onRinging(Map raw) {
    final s = session.value;
    if (s == null || !s.outgoing) return;
    s.callId = '${raw['callId']}';
    // 服务端把真实参与者名单发回来了，刷新界面上的"待接通"名单
    final list = _peersFrom(raw);
    if (list.isNotEmpty) _mergePeers(list);
  }

  /// 被叫的其他设备收到「已在本机接听」→ 收起来电界面
  void _onHandled(Map raw) {
    if (phase.value != CallPhase.incoming) return;
    final s = session.value;
    if (s == null || s.callId != '${raw['callId']}') return;
    _finish('已在其他设备接听');
  }

  /// 自己成功进入房间（接听 / 中途加入）
  void _onJoined(Map raw) {
    final s = session.value;
    if (s == null || s.callId != '${raw['callId']}') return;

    // 服务端只把"已接听的人"放进 peers。
    // 中途加入时这就是"已经在房间里的所有人"，他们会来连我 —— 我等 offer。
    // 首发接听时列表里只有主叫一个人，主叫会发 offer 给我。
    final list = _peersFrom(raw);
    _mergePeers(list);

    if (phase.value == CallPhase.incoming || phase.value == CallPhase.connecting) {
      phase.value = CallPhase.connecting;
      status.value = '正在连接…';
      _answeredAt ??= DateTime.now();
      _startTick();
    }
    _diag('已加入通话，房间内 ${list.length} 人');
  }

  /// 有人加入了我所在的房间 → **由我向这个人发 offer**。
  ///
  /// 这是 mesh 建连的唯一触发点（除了 1v1 老协议的 call:accepted）。
  /// 规则固定为"已在房间里的人发"，避免双方同时发 offer。
  Future<void> _onPeerJoined(Map raw) async {
    final s = session.value;
    if (s == null || s.callId != '${raw['callId']}') return;
    final peer = raw['peer'];
    if (peer is! Map) return;
    final uid = (peer['userId'] as num?)?.toInt();
    if (uid == null) return;
    // 自己加入时也会收到（服务端只发给别人，这里双保险）
    if (uid == _myUserId) return;

    final list = _peersFrom(raw);
    if (list.isNotEmpty) _mergePeers(list);

    _diag('$uid 加入 → 由我发 offer');
    await _createOfferTo(uid);
  }

  /// 有人离开了房间 → 拆掉这一路连接
  void _onPeerLeft(Map raw) {
    final s = session.value;
    if (s == null || s.callId != '${raw['callId']}') return;
    final uid = (raw['peerId'] as num?)?.toInt();
    if (uid == null) return;

    unawaited(_dropLink(uid));
    _diag('$uid 已离开');

    // 房间里没人了（除自己）：群通话里最后一个走的人触发收尾
    final left = s.peers.where((p) => p.userId != uid).toList();
    _mergePeers(left);
    if (left.isEmpty && phase.value == CallPhase.active) {
      _finish('通话已结束');
    }
  }

  /// 成员名单变化：只更新 UI，不动连接
  void _onUpdated(Map raw) {
    final s = session.value;
    if (s == null || s.callId != '${raw['callId']}') return;
    final list = _peersFrom(raw);
    if (list.isEmpty && !s.group) return;
    if (list.isNotEmpty) _mergePeers(list);
  }

  /// 主叫收到「有人接听」。
  ///
  /// 1v1 老协议：主叫负责发 offer。
  /// 群通话：这条帧也会发（发起人收到了），但**不能**在这里发 offer ——
  /// 群里的 offer 由 `call:peer-joined` 统一触发，否则会重复协商。
  Future<void> _onAccepted(Map raw) async {
    final s = session.value;
    if (s == null || !s.outgoing) return;
    phase.value = CallPhase.connecting;
    status.value = '正在连接…';
    _answeredAt ??= DateTime.now();
    _startTick();

    final by = (raw['by'] as num?)?.toInt();
    if (by == null) return;
    // 群通话时会话里可能已经多人，各自由 peer-joined 处理；1v1 走这里
    if (s.group) {
      _diag('$by 接听（群通话，offer 由 peer-joined 触发）');
      return;
    }
    await _createOfferTo(by);
  }

  Future<void> _onOffer(Map raw) async {
    final s = session.value;
    if (s == null) return;
    final from = (raw['from'] as num?)?.toInt();
    if (from == null) return;

    final link = await _ensureLink(from);
    if (link == null) return;
    final pc = link.pc!;

    final d = (raw['data'] as Map?) ?? const {};
    await pc.setRemoteDescription(
        RTCSessionDescription('${d['sdp']}', '${d['type']}'));
    link.remoteSet = true;
    await _flushIce(link);

    final answer = await pc.createAnswer();
    await pc.setLocalDescription(answer);
    _sendTo('answer', from, answer.toMap());
    _answeredAt ??= DateTime.now();
    _startTick();
  }

  Future<void> _onAnswer(Map raw) async {
    final from = (raw['from'] as num?)?.toInt();
    if (from == null) return;
    final link = _links[from];
    if (link?.pc == null) return;
    final d = (raw['data'] as Map?) ?? const {};
    await link!.pc!.setRemoteDescription(
        RTCSessionDescription('${d['sdp']}', '${d['type']}'));
    link.remoteSet = true;
    await _flushIce(link);
  }

  Future<void> _onIce(Map raw) async {
    final from = (raw['from'] as num?)?.toInt();
    if (from == null) return;
    final d = (raw['data'] as Map?) ?? const {};
    final cand = RTCIceCandidate(
      d['candidate'] as String?,
      d['sdpMid'] as String?,
      (d['sdpMLineIndex'] as num?)?.toInt(),
    );
    if (cand.candidate == null || cand.candidate!.isEmpty) return;

    final link = _links[from];
    // link 还没建（ICE 早于 offer 到达，mesh 里很常见）：先扔进孤儿队列，
    // 等 _ensureLink 建好这条连接时再补进去。直接丢掉的话，那几条候选就
    // 永远没了，跨网场景下很容易表现为"卡在 connecting 打不通"。
    if (link == null) {
      _orphanIce.putIfAbsent(from, () => []).add(cand);
      _diag('收到 $from 的 ICE 但连接未建，暂存');
      return;
    }
    if (link.pc == null || !link.remoteSet) {
      link.pendingIce.add(cand);
      return;
    }
    try {
      await link.pc!.addCandidate(cand);
    } catch (e) {
      debugPrint('[call] addCandidate 失败(from=$from): $e');
    }
  }

  Future<void> _flushIce(_PeerLink link) async {
    final pc = link.pc;
    if (pc == null) return;
    final list = List<RTCIceCandidate>.from(link.pendingIce);
    link.pendingIce.clear();
    for (final c in list) {
      try {
        await pc.addCandidate(c);
      } catch (_) {
        /* 单个候选失败不影响其它 */
      }
    }
  }

  void _onRejected(Map raw) {
    final s = session.value;
    // 群通话里单个人拒接不该结束整通（服务端也不发这条帧）
    if (s != null && s.group) {
      _diag('有人拒接');
      return;
    }
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

  /// 当前用户 id。
  ///
  /// 复用 SoundService 的 myId（登录后由会话列表页写入），避免再引一个全局状态。
  /// 只用于"过滤掉自己"这类判断，拿不到时返回 0 —— 调用方都做了 `!= 0` 保护。
  int get _myUserId => SoundService().myId;

  /// 建立（或复用）到某个远端的连接，并把本地轨道推过去。
  Future<_PeerLink?> _ensureLink(int userId) async {
    final exist = _links[userId];
    if (exist?.pc != null) return exist;
    await _ensureRenderers();

    final peer = session.value?.peerOf(userId);
    final link = exist ??
        _PeerLink(
          userId: userId,
          videoOn: ValueNotifier<bool>(false),
        );
    _links[userId] = link;

    if (!link.rendererReady) {
      try {
        await link.renderer.initialize();
        link.rendererReady = true;
        // 第一帧真正渲染出来才算"这一路出画面"
        link.renderer.onFirstFrameRendered = () {
          _diag('远端首帧已渲染($userId)');
          link.videoOn.value = true;
        };
      } catch (e) {
        _diag('渲染器初始化失败($userId): $e');
      }
    }

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
      // 带上 to，别把候选发给了别的远端
      _sendTo('ice', userId, cand.toMap());
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
        link.remote = event.streams.first;
        if (event.track.kind == 'video') link.videoOn.value = true;
        link.renderer.srcObject = link.remote;
        _diag('轨道到达(${event.track.kind}/$userId)：带 stream，直接用');
        return;
      }
      _diag('轨道到达(${event.track.kind}/$userId)：无 stream，按轨道自建');
      _attachRemoteTrack(link, event.track);
    };

    pc.onConnectionState = (st) {
      switch (st) {
        case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
          _diag('连接已建立($userId)');
          // 兜底：万一平台没触发 onTrack，这里主动把已到达的轨道捞回来渲染
          unawaited(_sweepReceivers(link));
          if (phase.value != CallPhase.active) {
            phase.value = CallPhase.active;
            status.value = '通话中';
            _answeredAt ??= DateTime.now();
            _startTick();
          }
          break;
        case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
          // 群通话里某一路失败不该掐掉整通；1v1 就是整通失败
          if (session.value?.group == true) {
            _diag('$userId 连接失败');
          } else {
            _finish('连接失败，可能不在同一网络');
          }
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

    link.pc = pc;
    _diag('已为 $userId 建连${peer != null ? '（${peer.name}）' : ''}');

    // 把这个人在建连之前就发来的 ICE 候选补进队列（见 _orphanIce 的说明）
    final orphans = _orphanIce.remove(userId);
    if (orphans != null && orphans.isNotEmpty) {
      link.pendingIce.addAll(orphans);
      _diag('补入 $userId 的 ${orphans.length} 条早期 ICE');
    }
    return link;
  }

  /// 主动向某人发 offer（mesh 建连的入口）
  Future<void> _createOfferTo(int userId) async {
    final link = await _ensureLink(userId);
    if (link?.pc == null) return;
    try {
      final offer = await link!.pc!.createOffer();
      await link.pc!.setLocalDescription(offer);
      _sendTo('offer', userId, offer.toMap());
    } catch (e) {
      _diag('向 $userId 发 offer 失败: $e');
    }
  }

  /// 拆掉某一路连接（对方离开 / 通话结束）
  Future<void> _dropLink(int userId) async {
    _orphanIce.remove(userId);
    final link = _links.remove(userId);
    if (link == null) return;
    await link.dispose();
  }

  void _sendTo(String kind, int to, Map<String, dynamic> data) {
    final s = session.value;
    if (s == null || s.callId.isEmpty) return;
    SocketService().send({
      'type': 'call:$kind',
      'callId': s.callId,
      'to': to,
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

  /// 把一条远端轨道挂到该路的渲染器上。
  ///
  /// 桌面端 onTrack 不带 streams，必须自己组装 MediaStream。注意同一路媒体的
  /// 音频轨和视频轨是分两次到达的，所以**复用同一个流**，否则后到的会把先到的顶掉
  /// （典型症状：挂了视频就没声音，或反之）。
  Future<void> _attachRemoteTrack(_PeerLink link, MediaStreamTrack track) async {
    var stream = link.remote;
    if (stream == null) {
      try {
        stream = await createLocalMediaStream('remote-${link.userId}');
        link.remote = stream;
      } catch (e) {
        _diag('自建远端流失败(${link.userId}): $e');
        return;
      }
    }
    final exists = stream.getTracks().any((t) => t.id == track.id);
    if (!exists) {
      try {
        await stream.addTrack(track);
      } catch (e) {
        _diag('挂载 ${track.kind} 轨道失败(${link.userId}): $e');
      }
    }
    if (track.kind == 'video') link.videoOn.value = true;
    link.renderer.srcObject = stream;
    _diag('已挂载 ${track.kind}(${link.userId}，共 ${stream.getTracks().length} 轨)');
  }

  /// 兜底扫描：个别平台/版本不触发 onTrack，连接建立后主动去接收器里捞轨道。
  Future<void> _sweepReceivers(_PeerLink link) async {
    final pc = link.pc;
    if (pc == null) return;
    try {
      final rs = await pc.getReceivers();
      for (final r in rs) {
        final t = r.track;
        if (t != null) await _attachRemoteTrack(link, t);
      }
      _diag('接收器扫描(${link.userId})：共 ${rs.length} 个');
    } catch (e) {
      _diag('接收器扫描失败(${link.userId}): $e');
    }
  }

  Future<void> _ensureRenderers() async {
    if (_localRendererReady) return;
    _localRendererReady = true;
    try {
      await localRenderer.initialize();
    } catch (e) {
      debugPrint('[call] localRenderer 初始化失败: $e');
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

    // 拆掉所有远端连接（群通话可能有多条）
    final links = _links.values.toList();
    _links.clear();
    _orphanIce.clear();
    for (final l in links) {
      await l.dispose();
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

    try {
      localRenderer.srcObject = null;
    } catch (_) {
      /* 渲染器可能已释放 */
    }
    remoteDiag.value = '';
    seconds.value = 0;
    peerCount.value = 0;
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
