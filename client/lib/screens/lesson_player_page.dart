import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../api.dart';
import '../core/lesson_player.dart';
import '../core/lesson_progress.dart';

/// 课件内嵌播放页。
///
/// ── 它存在的唯一理由：拿到"真看了多少秒" ──────────────────────
/// 之前课件是"下载 → 交系统播放器 → 打开成功就记完成"，
/// 于是**点开就退出也算学完**，完成率是假的，门禁（学到 X% 才能考试）等于没设。
/// 内嵌播放之后，秒数是自己数的（见 core/lesson_progress.dart）：
/// 拖进度条跳过去的不算，暂停/缓冲的不算，倍速的照算。
///
/// ── 为什么播**本地文件**而不是网络地址 ────────────────────────
/// 课件接口要带 Bearer token（api.dart:lessonMediaUrl 的注释写了），
/// 而播放器走网络地址时 header 能不能带上、会不会被缓存，各平台表现不一致。
/// 复用 `FileIo.ensure` 下好的本地文件则完全绕开鉴权，
/// 还顺带得到"断网也能接着看"。
class LessonPlayerPage extends StatefulWidget {
  final int lessonId;
  final String title;
  final String filePath;

  /// 管理台标注的时长；没标注是 0，此时用播放器报的实际时长补。
  final int serverDurationSec;

  /// 上次看到哪（续播起点）。
  final int startSec;

  /// 便于测试注入。
  final ImApi? api;

  const LessonPlayerPage({
    super.key,
    required this.lessonId,
    required this.title,
    required this.filePath,
    this.serverDurationSec = 0,
    this.startSec = 0,
    this.api,
  });

  @override
  State<LessonPlayerPage> createState() => _LessonPlayerPageState();
}

class _LessonPlayerPageState extends State<LessonPlayerPage> {
  VideoPlayerController? _c;
  late LessonWatch _watch;
  Timer? _ticker;
  String? _fatal;
  bool _reportedDone = false;
  int _secsSinceReport = 0;

  ImApi get _api => widget.api ?? ImApi();

  @override
  void initState() {
    super.initState();
    _watch = LessonWatch(
      durationSec: widget.serverDurationSec,
      positionSec: widget.startSec,
    );
    _boot();
  }

  Future<void> _boot() async {
    if (!LessonPlayer.supported) {
      if (!mounted) return;
      setState(() => _fatal = LessonPlayer.unsupportedReason);
      return;
    }
    final c = VideoPlayerController.file(File(widget.filePath));
    _c = c;
    try {
      await c.initialize();
    } catch (e) {
      // 文件不是视频 / 编码不支持 / 插件没注册，都落到这里。
      // 说清楚是"这个文件播不了"，别写成"网络错误"——那会把人往错的方向带。
      if (!mounted) return;
      setState(() => _fatal = '这个文件播不了：$e');
      return;
    }
    if (!mounted) return;
    _watch.noteDuration(c.value.duration.inSeconds);
    final resume = _watch.resumeSec;
    if (resume > 0) {
      await c.seekTo(Duration(seconds: resume));
      _watch.seekTo(resume); // 🔴 跳过去的那段不算看过
    }
    c.addListener(_onValue);
    await c.play();
    if (!mounted) return;
    setState(() {});
    _ticker = Timer.periodic(const Duration(seconds: 1), _onSecond);
  }

  void _onValue() {
    if (mounted) setState(() {});
  }

  void _onSecond(Timer _) {
    final c = _c;
    if (c == null || !c.value.isInitialized) return;
    _watch.tick(
      playing: c.value.isPlaying,
      positionSec: c.value.position.inSeconds,
      elapsedSec: 1,
    );
    if (mounted) setState(() {});

    if (_watch.done && !_reportedDone) {
      _reportedDone = true;
      unawaited(_report(done: true));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已看完本课时，进度已上报')),
        );
      }
      return;
    }
    // 每 15 秒回传一次，弱网下丢一两次也没关系：退出时还会再报一次。
    if (++_secsSinceReport >= 15) {
      _secsSinceReport = 0;
      unawaited(_report());
    }
  }

  Future<void> _report({bool done = false}) async {
    try {
      await _api.reportLessonProgress(
        widget.lessonId,
        positionSec: _watch.positionSec,
        watchedSec: _watch.watchedSec,
        done: done || _watch.done,
      );
    } catch (_) {
      // 上报失败不打断观看：下一次周期上报 / 退出时那次会补上。
      // 服务端是 UPSERT，重复报只会覆盖，不会变成两行。
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _c?.removeListener(_onValue);
    final c = _c;
    if (c != null) {
      unawaited(c.pause());
      unawaited(c.dispose());
    }
    unawaited(_report()); // 退出时兜底上报（此时 await 不了，dispose 是同步的）
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = _c;
    final ready = c != null && c.value.isInitialized && _fatal == null;

    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: _fatal != null
          ? _Fatal(msg: _fatal!)
          : (!ready
              ? const Center(child: CircularProgressIndicator())
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    AspectRatio(
                      aspectRatio: c.value.size.width == 0 ||
                              c.value.size.height == 0
                          ? 16 / 9
                          : c.value.size.width / c.value.size.height,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          VideoPlayer(c),
                          _PlayPause(c: c),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
                      child: VideoProgressIndicator(c, allowScrubbing: true),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(children: [
                            Expanded(
                              child: Text(
                                '已看 ${_watch.percent}%（需看满 ${(LessonWatchRules.doneRatio * 100).round()}% 才算完成）',
                                style: theme.textTheme.bodyMedium,
                              ),
                            ),
                            Text(
                              '${_mmss(c.value.position.inSeconds)} / ${_mmss(_watch.durationSec)}',
                              style: theme.textTheme.bodySmall,
                            ),
                          ]),
                          const SizedBox(height: 6),
                          // 真看了多少秒 —— 这一行是"完成率到底真不真"的凭据，
                          // 学员自己也能看见：拖进度条不会让它涨。
                          Text(
                            '真看了 ${_mmss(_watch.watchedSec)}，需 ${_mmss(_watch.requiredSec)}'
                            '${_watch.done ? ' · ✅ 已完成' : ''}',
                            style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant),
                          ),
                          if (_watch.requiredSec == 0)
                            Padding(
                              padding: const EdgeInsets.only(top: 6),
                              child: Text(
                                '这个课时拿不到时长，暂时没法判"看没看完" —— 请管理员在课时上填时长。',
                                style: theme.textTheme.bodySmall?.copyWith(
                                    color: theme.colorScheme.error),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                )),
    );
  }

  static String _mmss(int seconds) {
    final s = seconds < 0 ? 0 : seconds;
    final m = s ~/ 60;
    final r = s % 60;
    return '${m.toString().padLeft(2, '0')}:${r.toString().padLeft(2, '0')}';
  }
}

class _PlayPause extends StatelessWidget {
  final VideoPlayerController c;
  const _PlayPause({required this.c});

  @override
  Widget build(BuildContext context) {
    return IconButton.filledTonal(
      key: const Key('lesson-playpause'),
      iconSize: 40,
      icon: Icon(c.value.isPlaying ? Icons.pause : Icons.play_arrow),
      onPressed: () {
        if (c.value.isPlaying) {
          unawaited(c.pause());
        } else {
          unawaited(c.play());
        }
      },
    );
  }
}

class _Fatal extends StatelessWidget {
  final String msg;
  const _Fatal({required this.msg});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(msg, textAlign: TextAlign.center),
      ),
    );
  }
}
