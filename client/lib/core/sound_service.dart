import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:shared_preferences/shared_preferences.dart';

import '../models.dart';
import '../socket.dart';

/// 通话提示音类型
enum CallTone { none, incoming, outgoing }

/// 提示音服务：新消息音、来电振铃、呼出回铃。
///
/// 三个音都是本地合成的 WAV（见 tools/gen_sounds.py），用 [BytesSource] 播放：
/// Windows 插件走 SHCreateMemStream、Android 走字节流，两端行为一致，
/// 不受 asset 路径在桌面端解析差异的影响。
class SoundService {
  static final SoundService _i = SoundService._();
  factory SoundService() => _i;
  SoundService._();

  static const _kEnabled = 'xz_sound_enabled';

  static const _msgPath = 'assets/sounds/message.wav';
  static const _ringPath = 'assets/sounds/ringtone.wav';
  static const _outPath = 'assets/sounds/outgoing.wav';

  /// 提示音总开关（关掉后消息音、铃声都不响）
  bool enabled = true;

  /// 当前登录用户 id，用于过滤「自己发的消息不响」
  int myId = 0;

  final AudioPlayer _msgPlayer = AudioPlayer();
  final AudioPlayer _tonePlayer = AudioPlayer();

  Uint8List? _msgBytes;
  Uint8List? _ringBytes;
  Uint8List? _outBytes;

  CallTone _tone = CallTone.none;
  bool _loaded = false;
  DateTime? _lastMsgAt;
  StreamSubscription? _sub;

  /// 启动调用：读开关 + 后台预加载音频字节
  Future<void> init() async {
    try {
      final p = await SharedPreferences.getInstance();
      enabled = p.getBool(_kEnabled) ?? true;
    } catch (_) {}
    unawaited(_preload());
  }

  Future<void> _preload() async {
    if (_loaded) return;
    try {
      final r = await Future.wait([
        rootBundle.load(_msgPath),
        rootBundle.load(_ringPath),
        rootBundle.load(_outPath),
      ]);
      _msgBytes = r[0].buffer.asUint8List();
      _ringBytes = r[1].buffer.asUint8List();
      _outBytes = r[2].buffer.asUint8List();
      _loaded = true;
    } catch (e) {
      debugPrint('[sound] 音频加载失败: $e');
    }
  }

  Future<void> setEnabled(bool v) async {
    enabled = v;
    if (!v) await stopAll();
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool(_kEnabled, v);
    } catch (_) {}
  }

  /// 订阅全局消息流：收到别人发的新消息就响一声
  void attach() {
    _sub?.cancel();
    _sub = SocketService().stream.listen((e) {
      if (e is! Map) return;
      if (e['type'] != 'message:new') return;
      final raw = e['message'];
      if (raw is! Map) return;
      final m = Message.fromJson(Map<String, dynamic>.from(raw));
      if (myId > 0 && m.senderId == myId) return; // 自己（含自己其他设备）发的不响
      unawaited(playMessage());
    });
  }

  void detach() {
    _sub?.cancel();
    _sub = null;
  }

  /// 新消息提示音。加了节流：群聊刷屏时 400ms 内只响一次，不会糊成一片。
  Future<void> playMessage() async {
    if (!enabled) return;
    final now = DateTime.now();
    if (_lastMsgAt != null && now.difference(_lastMsgAt!).inMilliseconds < 400) {
      return;
    }
    _lastMsgAt = now;
    await _play(_msgPlayer, () => _msgBytes, _msgPath, loop: false);
  }

  /// 切换通话提示音：来电振铃 / 呼出回铃 / 停。相同状态不重启，避免铃声断续。
  Future<void> setTone(CallTone t) async {
    if (_tone == t) return;
    _tone = t;
    if (t == CallTone.none) {
      await _stopQuietly(_tonePlayer);
      return;
    }
    if (!enabled) return;
    final isIn = t == CallTone.incoming;
    await _play(
      _tonePlayer,
      () => isIn ? _ringBytes : _outBytes,
      isIn ? _ringPath : _outPath,
      loop: true,
    );
  }

  Future<void> stopAll() async {
    _tone = CallTone.none;
    await _stopQuietly(_msgPlayer);
    await _stopQuietly(_tonePlayer);
  }

  /// 登出 / 切服务器时调用
  Future<void> reset() async {
    await stopAll();
    myId = 0;
    _lastMsgAt = null;
  }

  Future<void> _play(
    AudioPlayer p,
    Uint8List? Function() cached,
    String path, {
    required bool loop,
  }) async {
    var bytes = cached();
    if (bytes == null) {
      await _preload();
      bytes = cached();
      if (bytes == null) return;
    }
    try {
      await p.stop();
      await p.setReleaseMode(loop ? ReleaseMode.loop : ReleaseMode.release);
      await p.setVolume(loop ? 0.9 : 0.75);
      await p.play(BytesSource(bytes));
    } catch (e) {
      debugPrint('[sound] 播放失败 $path: $e');
    }
  }

  Future<void> _stopQuietly(AudioPlayer p) async {
    try {
      await p.stop();
    } catch (_) {}
  }
}
