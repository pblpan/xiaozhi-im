import 'dart:async';
import 'dart:io';
import 'package:audioplayers/audioplayers.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

/// 一段录好的语音
class VoiceClip {
  final File file;
  final int seconds;
  const VoiceClip({required this.file, required this.seconds});
}

/// 语音录制与播放。
///
/// 录制：AAC-LC / 16kHz / 单声道 32kbps —— 1 分钟约 240KB，外网也传得动。
/// 播放：全局单例播放器，同一时刻只播一条；播放状态用 Stream 广播，
///       让所有气泡都能收到"当前哪条在播"，用于切动画。
///
/// 注意：录制的停止叫 `stopRecording()`，播放的停止叫 `stopPlayback()`，
/// 刻意区分开，避免调用方混淆"停止录音"和"停止播放"。
class Voice {
  Voice._();

  /// 最长录音 60 秒（到点自动发送）
  static const int maxSeconds = 60;

  /// 最短有效录音（秒）——低于这个视为误触，直接丢弃
  static const double minValidSeconds = 0.8;

  static final AudioRecorder _rec = AudioRecorder();
  static final AudioPlayer _player = AudioPlayer();

  static DateTime? _startedAt;

  static String? _playingKey;
  static final StreamController<String?> _playCtrl =
      StreamController<String?>.broadcast();

  /// 正在播放的消息 key（null = 没在播）
  static Stream<String?> get playingStream => _playCtrl.stream;
  static String? get playingKey => _playingKey;

  /// 消息的唯一 key（跨会话也唯一）
  static String keyOf(int conversationId, int messageId) =>
      '$conversationId:$messageId';

  // ============================================================
  // 录制
  // ============================================================

  /// 是否有麦克风权限（会弹系统授权框）
  static Future<bool> hasPermission() async {
    try {
      return await _rec.hasPermission();
    } catch (_) {
      return false;
    }
  }

  static bool get isRecordingNow => _startedAt != null;

  /// 开始录音；返回 false 表示无权限或启动失败
  static Future<bool> start() async {
    try {
      if (!await _rec.hasPermission()) return false;
      final dir = await getTemporaryDirectory();
      final path = '${dir.path}${Platform.pathSeparator}'
          'xz_voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
      await _rec.start(
        const RecordConfig(
          encoder: AudioEncoder.aacLc,
          bitRate: 32000,
          sampleRate: 16000,
          numChannels: 1,
        ),
        path: path,
      );
      _startedAt = DateTime.now();
      return true;
    } catch (_) {
      _startedAt = null;
      return false;
    }
  }

  /// 已录制秒数（UI 计时用）
  static int get elapsedSeconds {
    final s = _startedAt;
    if (s == null) return 0;
    return DateTime.now().difference(s).inSeconds;
  }

  /// 停止录音并返回音频；太短或文件不存在返回 null（调用方提示"太短"）
  static Future<VoiceClip?> stopRecording() async {
    final started = _startedAt;
    _startedAt = null;
    String? path;
    try {
      path = await _rec.stop();
    } catch (_) {
      path = null;
    }
    if (path == null || started == null) return null;

    final seconds = DateTime.now().difference(started).inMilliseconds / 1000.0;
    final f = File(path);
    if (!await f.exists()) return null;
    if (seconds < minValidSeconds) {
      try {
        await f.delete();
      } catch (_) {/* 删不掉也无所谓，系统临时目录会回收 */}
      return null;
    }
    return VoiceClip(
      file: f,
      seconds: seconds.round().clamp(1, maxSeconds),
    );
  }

  /// 取消录音（上滑取消 / 页面退出），删掉半截文件
  static Future<void> cancelRecording() async {
    _startedAt = null;
    String? path;
    try {
      path = await _rec.stop();
    } catch (_) {
      path = null;
    }
    if (path != null) {
      try {
        final f = File(path);
        if (await f.exists()) await f.delete();
      } catch (_) {/* ignore */}
    }
  }

  // ============================================================
  // 播放
  // ============================================================

  /// 点击气泡：同一条=停止，另一条=切过去播
  static Future<void> toggle(String key, String url) async {
    if (_playingKey == key) {
      await stopPlayback();
      return;
    }
    await _player.stop();
    _setPlaying(key);
    // 播完自动复位；若期间切了别的，key 对不上就不动
    _player.onPlayerComplete.first.then((_) {
      if (_playingKey == key) _setPlaying(null);
    }).catchError((_) {});
    try {
      await _player.play(UrlSource(url));
    } catch (_) {
      _setPlaying(null);
    }
  }

  static Future<void> stopPlayback() async {
    try {
      await _player.stop();
    } catch (_) {/* ignore */}
    _setPlaying(null);
  }

  static void _setPlaying(String? key) {
    _playingKey = key;
    if (!_playCtrl.isClosed) _playCtrl.add(key);
  }

  /// 退出登录 / 销毁时调用
  static Future<void> disposeAll() async {
    await stopPlayback();
    try {
      await _rec.dispose();
    } catch (_) {/* ignore */}
    try {
      await _player.dispose();
    } catch (_) {/* ignore */}
  }
}
