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
  }

  @override
  void dispose() {
    _c.phase.removeListener(_onPhase);
    super.dispose();
  }

  void _onPhase() {
    // 通话彻底结束（idle）时自己关掉页面，CallService 不用管导航栈
    if (_c.phase.value == CallPhase.idle && !_closed) {
      _closed = true;
      if (mounted) Navigator.of(context).pop();
    }
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

  Widget _incomingBody(CallSession s) => SafeArea(
        child: Column(
          children: [
            const Spacer(flex: 3),
            UserAvatar(name: s.peerName, size: 108, radius: 32),
            const SizedBox(height: 22),
            Text(
              s.peerName,
              style: const TextStyle(
                  fontSize: 22, fontWeight: FontWeight.w600, color: Colors.white),
            ),
            const SizedBox(height: 10),
            ValueListenableBuilder<String>(
              valueListenable: _c.status,
              builder: (_, v, __) => Text(
                v,
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
                  icon: s.video
                      ? Icons.videocam_rounded
                      : Icons.phone_rounded,
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

  /// 远端画面：视频模式且对方已出画面时铺满，否则退回头像 + 状态
  Widget _remoteArea(CallSession s) => ValueListenableBuilder<bool>(
        valueListenable: _c.remoteVideoOn,
        builder: (_, hasVideo, __) {
          if (s.video && hasVideo) {
            return RTCVideoView(
              _c.remoteRenderer,
              objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
            );
          }
          return Container(
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
                UserAvatar(name: s.peerName, size: 96, radius: 30),
                const SizedBox(height: 18),
                Text(
                  s.peerName,
                  style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                      color: Colors.white),
                ),
              ],
            ),
          );
        },
      );

  /// 本地画中画小窗
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
                // 长按对方名字 → 看远端接收诊断（排障用，正常通话碰不到）
                onLongPress: () => _showDiag(s),
                child: Text(
                  s.peerName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                      color: Colors.white),
                ),
              ),
              const SizedBox(height: 6),
              ValueListenableBuilder<int>(
                valueListenable: _c.seconds,
                builder: (_, sec, __) {
                  final active = _c.phase.value == CallPhase.active;
                  return ValueListenableBuilder<String>(
                    valueListenable: _c.status,
                    builder: (_, st, __) => Text(
                      active && sec > 0 ? _fmt(sec) : st,
                      style: TextStyle(
                        fontSize: 13.5,
                        color: active && sec > 0
                            ? Colors.white
                            : Colors.white70,
                        fontWeight:
                            active && sec > 0 ? FontWeight.w600 : FontWeight.w400,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
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
                  icon: on
                      ? Icons.volume_up_rounded
                      : Icons.volume_down_rounded,
                  label: on ? '免提' : '听筒',
                  active: on,
                  onTap: _c.toggleSpeaker,
                ),
              ),
            _ctrlBtn(
              icon: Icons.call_end_rounded,
              label: started ? '挂断' : '取消',
              color: AppColors.danger,
              onTap: _c.hangup,
            ),
          ],
        ),
      ),
    );
  }

  /// 接收诊断（长按对方名字触发）。
  ///
  /// 桌面端和手机端的 WebRTC 行为差异不小，线上出问题时用户看不到日志，
  /// 把轨道到达过程直接显示出来，截图就能定位问题。
  void _showDiag(CallSession s) {
    final diag = _c.remoteDiag.value;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('接收诊断'),
        content: SingleChildScrollView(
          child: SelectableText(
            '阶段：${_c.phase.value.name}\n'
            '远端出画面：${_c.remoteVideoOn.value}\n'
            '通话模式：${s.video ? '视频' : '语音'}\n'
            '本机摄像头：${_c.camOn.value}   麦克风：${_c.micOn.value}\n'
            '平台：${Platform.operatingSystem}\n'
            '──── 轨道事件 ────\n'
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
