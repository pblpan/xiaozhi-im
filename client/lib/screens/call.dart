import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../core/call_service.dart';
import '../core/theme.dart';
import '../widgets/avatar.dart';

/// 全屏通话页。
///
/// 一个页面同时承担「来电接听」和「通话中」两种形态——它们的背景、
/// 头像、状态文案完全一致，只是底部按钮不同，拆成两个页面反而要来回跳。
///
/// 【多人化改造】远端区域从"单路全屏 + 画中画"改成**自适应网格**：
///   1 人 → 全屏（等价于原来的样子）
///   2 人 → 上下各一半
///   3-4 人 → 2×2
///   5-6 人 → 3×2
/// 自己的画面统一作为右下角的小画中画浮层，不再占用网格格子 ——
/// 否则 3 人通话（自己 + 2 人）会变成"2×2 里空一格"的难看布局。
class CallScreen extends StatefulWidget {
  const CallScreen({super.key});

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  final _c = CallService();
  bool _closed = false;

  @override
  void initState() {
    super.initState();
    _c.phase.addListener(_onPhase);
    _c.session.addListener(_onSession);
    _c.peerCount.addListener(_onSession);
  }

  @override
  void dispose() {
    _c.phase.removeListener(_onPhase);
    _c.session.removeListener(_onSession);
    _c.peerCount.removeListener(_onSession);
    super.dispose();
  }

  /// ⚠️ 必须 setState。
  ///
  /// [build] 里读 `_c.phase.value` 决定渲染「来电形态」还是「通话形态」，
  /// 这是**非响应式读取**——不主动重建的话，被叫端接听后 phase 已经从
  /// `incoming` 走到 `connecting/active`，界面却永远停来电页（拒绝/接听按钮
  /// 一直在），而承载 `RTCVideoView` 的通话形态从未挂载 → 画面全黑。
  /// 两个症状（黑屏 + 已接听仍显示未接通）其实是同一个根因。
  void _onPhase() {
    // 通话彻底结束（idle）时自己关掉页面，CallService 不用管导航栈
    if (_c.phase.value == CallPhase.idle) {
      if (_closed) return;
      _closed = true;
      if (mounted) Navigator.of(context).pop();
      return;
    }
    if (mounted) setState(() {});
  }

  /// 会话对象是可变引用（如摄像头不可用时会被降级成语音），也要跟着重建。
  /// 群通话里参会人数变化（有人进出）走的也是这条。
  void _onSession() {
    if (mounted) setState(() {});
  }

  static String _fmt(int s) {
    final m = s ~/ 60;
    final sec = s % 60;
    return '${m.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final s = _c.session.value;
    if (s == null) return const Scaffold(backgroundColor: Colors.black);
    final isIncoming = _c.phase.value == CallPhase.incoming;

    return PopScope(
      canPop: false, // 通话中屏蔽返回键，必须显式挂断
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          children: [
            Positioned.fill(
              child: isIncoming ? _incomingBody(s) : _callBody(s),
            ),
            if (!isIncoming && _c.phase.value == CallPhase.ended)
              Positioned.fill(child: _endedVeil()),
          ],
        ),
      ),
    );
  }

  // -------------------------------------------------------------- 来电形态

  Widget _incomingBody(CallSession s) {
    final isGroup = s.group;
    final first = s.peers.isNotEmpty ? s.peers.first : null;
    return SafeArea(
      child: Column(
        children: [
          const Spacer(flex: 3),
          // 群通话显示牵头人的头像 + 一排小头像，1v1 就是单人头像
          if (isGroup && s.peers.length > 1)
            _incomingAvatarStack(s)
          else
            UserAvatar(name: first?.name ?? s.title, size: 108, radius: 32),
          const SizedBox(height: 22),
          Text(
            s.title,
            textAlign: TextAlign.center,
            style: const TextStyle(
                fontSize: 22, fontWeight: FontWeight.w600, color: Colors.white),
          ),
          const SizedBox(height: 10),
          ValueListenableBuilder<String>(
            valueListenable: _c.status,
            builder: (_, v, __) => Text(
              v,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 14, color: Colors.white70),
            ),
          ),
          const Spacer(flex: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _roundBtn(
                icon: Icons.call_end_rounded,
                color: AppColors.danger,
                label: '拒绝',
                onTap: _c.reject,
              ),
              _roundBtn(
                icon: s.video ? Icons.videocam_rounded : Icons.phone_rounded,
                color: AppColors.brand,
                label: '接听',
                onTap: _c.accept,
              ),
            ],
          ),
          const SizedBox(height: 48),
        ],
      ),
    );
  }

  /// 群来电：主讲人头像居中，其余人用小头像横排挂着
  Widget _incomingAvatarStack(CallSession s) {
    final lead = s.peers.first;
    final rest = s.peers.skip(1).take(5).toList();
    return Column(
      children: [
        UserAvatar(name: lead.name, size: 100, radius: 30),
        const SizedBox(height: 16),
        SizedBox(
          height: 40,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (final p in rest)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: UserAvatar(name: p.name, size: 36, radius: 12),
                ),
              if (s.peers.length > 6)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Text(
                    '+${s.peers.length - 6}',
                    style: const TextStyle(
                        fontSize: 13, color: Colors.white70),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  // -------------------------------------------------------------- 通话形态

  Widget _callBody(CallSession s) => Stack(
        children: [
          Positioned.fill(child: _remoteArea(s)),
          Positioned(top: 0, left: 0, right: 0, child: _topBar(s)),
          if (s.video)
            Positioned(
              top: 92,
              right: 14,
              // 摄像头开关只影响画中画内容，单独订阅避免整页重建
              child: ValueListenableBuilder<bool>(
                valueListenable: _c.camOn,
                builder: (_, on, __) => _localPip(s, on),
              ),
            ),
          Positioned(left: 0, right: 0, bottom: 0, child: _controls(s)),
        ],
      );

  /// 远端区域。
  ///
  /// 没人接通（还在等待）时退回"头像 + 名字"的等待页；
  /// 有人了就走网格；只有 1 人且没有视频时也用大头像页（和原来 1v1 一致）。
  Widget _remoteArea(CallSession s) {
    final peers = s.peers;
    if (peers.isEmpty) return _waitingArea(s);

    // 只有一路且对方没出画面 → 用大头像（保持 1v1 的观感，别显示一个空框）
    if (peers.length == 1 && !peers.first.videoOn.value) {
      return _waitingArea(s, only: peers.first);
    }

    final n = peers.length;
    if (n == 1) {
      return _tile(peers.first, s);
    }
    if (n == 2) {
      return Column(
        children: [
          Expanded(child: _tile(peers[0], s)),
          const SizedBox(height: 2),
          Expanded(child: _tile(peers[1], s)),
        ],
      );
    }
    if (n <= 4) {
      return _grid(peers, s, columns: 2);
    }
    return _grid(peers, s, columns: 3);
  }

  Widget _grid(List<CallPeer> peers, CallSession s, {required int columns}) {
    final rows = <Widget>[];
    for (var i = 0; i < peers.length; i += columns) {
      final slice = peers.sublist(i, (i + columns).clamp(0, peers.length));
      rows.add(Expanded(
        child: Row(
          children: [
            for (var j = 0; j < columns; j++) ...[
              if (j > 0) const SizedBox(width: 2),
              Expanded(
                child: j < slice.length
                    ? _tile(slice[j], s)
                    : const SizedBox.shrink(),
              ),
            ],
          ],
        ),
      ));
      if (i + columns < peers.length) rows.add(const SizedBox(height: 2));
    }
    return Column(children: rows);
  }

  /// 一个参会者的格子：有画面就渲染视频，没有就显示头像 + 名字
  Widget _tile(CallPeer p, CallSession s) => ValueListenableBuilder<bool>(
        valueListenable: p.videoOn,
        builder: (_, hasVideo, __) {
          if (s.video && hasVideo) {
            final link = _c.rendererFor(p.userId);
            if (link != null) {
              return Stack(
                fit: StackFit.expand,
                children: [
                  RTCVideoView(
                    link,
                    objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                  ),
                  Positioned(left: 8, bottom: 8, child: _nameTag(p)),
                ],
              );
            }
          }
          return Container(
            color: const Color(0xFF14181F),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                UserAvatar(
                  name: p.name,
                  size: s.peers.length > 2 ? 48 : 72,
                  radius: s.peers.length > 2 ? 16 : 24,
                ),
                const SizedBox(height: 10),
                Text(
                  p.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: s.peers.length > 2 ? 12.5 : 16,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
              ],
            ),
          );
        },
      );

  Widget _nameTag(CallPeer p) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.45),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          p.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 11.5, color: Colors.white),
        ),
      );

  /// 还没有人接通的等待页（也是 1v1 语音通话时的主视觉）
  Widget _waitingArea(CallSession s, {CallPeer? only}) => Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF14181F), Color(0xFF07080B)],
          ),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            UserAvatar(name: (only ?? (s.peers.isNotEmpty ? s.peers.first : null))?.name ?? s.title, size: 96, radius: 30),
            const SizedBox(height: 18),
            Text(
              s.title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                  fontSize: 20, fontWeight: FontWeight.w600, color: Colors.white),
            ),
            if (s.group) ...[
              const SizedBox(height: 12),
              // 还没人进来（peers 为空）时才提示"等待"。
              // 已经有人在等画面出图时不必再刷这行字，否则和"正在连接…"重复。
              Text(
                s.peers.isEmpty ? '等待对方接听…' : '正在连接…',
                style: TextStyle(
                    fontSize: 13, color: Colors.white.withValues(alpha: 0.6)),
              ),
            ],
          ],
        ),
      );

  /// 本地画中画小窗（自己）。塔尖在右下角悬浮，不占网格格子。
  Widget _localPip(CallSession s, bool camOn) => GestureDetector(
        onTap: _c.switchCamera,
        child: Container(
          width: 104,
          height: 148,
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(AppRadii.md),
            border: Border.all(color: Colors.white24, width: 1),
            boxShadow: const [
              BoxShadow(color: Colors.black54, blurRadius: 12, offset: Offset(0, 4)),
            ],
          ),
          clipBehavior: Clip.antiAlias,
          child: camOn
              ? RTCVideoView(
                  _c.localRenderer,
                  objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                  mirror: true,
                )
              : const Center(
                  child: Icon(Icons.videocam_off_rounded,
                      color: Colors.white54, size: 26),
                ),
        ),
      );

  Widget _topBar(CallSession s) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
          child: Column(
            children: [
              GestureDetector(
                // 长按名字 → 看远端接收诊断（排障用，正常通话碰不到）
                onLongPress: () => _showDiag(s),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (s.group) ...[
                      const Icon(Icons.groups_rounded,
                          size: 17, color: Colors.white),
                      const SizedBox(width: 6),
                    ],
                    Flexible(
                      child: Text(
                        s.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w600,
                            color: Colors.white),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 6),
              ValueListenableBuilder<int>(
                valueListenable: _c.seconds,
                builder: (_, sec, __) {
                  final active = _c.phase.value == CallPhase.active;
                  return ValueListenableBuilder<String>(
                    valueListenable: _c.status,
                    builder: (_, st, __) => Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // 群通话额外显示"x 人在线"
                        if (s.group && _c.peerCount.value > 0) ...[
                          Text(
                            '${_c.peerCount.value + 1} 人在线',
                            style: TextStyle(
                              fontSize: 12.5,
                              color: Colors.white.withValues(alpha: 0.65),
                            ),
                          ),
                          Text(
                            '  ·  ',
                            style: TextStyle(
                              fontSize: 12.5,
                              color: Colors.white.withValues(alpha: 0.35),
                            ),
                          ),
                        ],
                        Text(
                          active && sec > 0 ? _fmt(sec) : st,
                          style: TextStyle(
                            fontSize: 13.5,
                            color: active && sec > 0
                                ? Colors.white
                                : Colors.white70,
                            fontWeight: active && sec > 0
                                ? FontWeight.w600
                                : FontWeight.w400,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      );

  Widget _controls(CallSession s) {
    final isMobile = Platform.isAndroid || Platform.isIOS;
    final started = _c.phase.value == CallPhase.active ||
        _c.phase.value == CallPhase.connecting;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.only(bottom: 26, top: 10),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            ValueListenableBuilder<bool>(
              valueListenable: _c.micOn,
              builder: (_, on, __) => _ctrlBtn(
                icon: on ? Icons.mic_rounded : Icons.mic_off_rounded,
                label: on ? '静音' : '已静音',
                active: !on,
                onTap: _c.toggleMic,
              ),
            ),
            if (s.video)
              ValueListenableBuilder<bool>(
                valueListenable: _c.camOn,
                builder: (_, on, __) => _ctrlBtn(
                  icon: on ? Icons.videocam_rounded : Icons.videocam_off_rounded,
                  label: on ? '摄像头' : '已关闭',
                  active: !on,
                  onTap: _c.toggleCam,
                ),
              ),
            if (s.video && isMobile)
              _ctrlBtn(
                icon: Icons.cameraswitch_rounded,
                label: '翻转',
                onTap: _c.switchCamera,
              ),
            if (isMobile)
              ValueListenableBuilder<bool>(
                valueListenable: _c.speakerOn,
                builder: (_, on, __) => _ctrlBtn(
                  icon: on ? Icons.volume_up_rounded : Icons.volume_down_rounded,
                  label: on ? '免提' : '听筒',
                  active: on,
                  onTap: _c.toggleSpeaker,
                ),
              ),
            _ctrlBtn(
              icon: Icons.call_end_rounded,
              // 群通话里是"退出"，不是"挂断"—— 语义不同，别让用户以为会终止整通
              label: started ? (s.group ? '退出' : '挂断') : '取消',
              color: AppColors.danger,
              onTap: _c.hangup,
            ),
          ],
        ),
      ),
    );
  }

  /// 接收诊断（长按名字触发）。
  ///
  /// 桌面端和手机端的 WebRTC 行为差异不小，线上出问题时用户看不到日志，
  /// 把轨道到达过程直接显示出来，截图就能定位问题。
  void _showDiag(CallSession s) {
    final diag = _c.remoteDiag.value;
    final peerLines = s.peers
        .map((p) => '  ${p.name}(#${p.userId})  出画面=${p.videoOn.value}')
        .join('\n');
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('接收诊断'),
        content: SingleChildScrollView(
          child: SelectableText(
            '阶段：${_c.phase.value.name}\n'
            '通话模式：${s.video ? '视频' : '语音'}${s.group ? '（群通话）' : ''}\n'
            '远端人数：${s.peers.length}\n'
            '本机摄像头：${_c.camOn.value}   麦克风：${_c.micOn.value}\n'
            '平台：${Platform.operatingSystem}\n'
            '──── 各路画面 ────\n'
            '${peerLines.isEmpty ? '（暂无）' : peerLines}\n'
            '──── 连接事件 ────\n'
            '${diag.isEmpty ? '（暂无）' : diag}',
            style: const TextStyle(fontSize: 12, height: 1.5),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Widget _endedVeil() => Container(
        color: Colors.black.withValues(alpha: 0.72),
        alignment: Alignment.center,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.call_end_rounded, color: Colors.white54, size: 40),
            const SizedBox(height: 14),
            ValueListenableBuilder<String>(
              valueListenable: _c.status,
              builder: (_, v, __) => Text(
                v,
                style: const TextStyle(fontSize: 16, color: Colors.white),
              ),
            ),
          ],
        ),
      );

  // -------------------------------------------------------------- 小控件

  Widget _ctrlBtn({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    Color? color,
    bool active = false,
  }) =>
      Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            onTap: onTap,
            customBorder: const CircleBorder(),
            child: Container(
              width: 58,
              height: 58,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: color ??
                    (active ? Colors.white : Colors.white.withValues(alpha: 0.16)),
              ),
              child: Icon(
                icon,
                size: 26,
                color: color != null
                    ? Colors.white
                    : (active ? Colors.black87 : Colors.white),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(label,
              style: const TextStyle(fontSize: 11.5, color: Colors.white70)),
        ],
      );

  Widget _roundBtn({
    required IconData icon,
    required Color color,
    required String label,
    required VoidCallback onTap,
  }) =>
      Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            onTap: onTap,
            customBorder: const CircleBorder(),
            child: Container(
              width: 68,
              height: 68,
              decoration: BoxDecoration(shape: BoxShape.circle, color: color),
              child: Icon(icon, size: 30, color: Colors.white),
            ),
          ),
          const SizedBox(height: 10),
          Text(label,
              style: const TextStyle(fontSize: 12.5, color: Colors.white70)),
        ],
      );
}
