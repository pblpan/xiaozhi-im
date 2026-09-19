import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show HapticFeedback, rootBundle;
import 'package:shared_preferences/shared_preferences.dart';

/// 扫码反馈：**声音 + 触感**。
///
/// ── 为什么要这个东西 ────────────────────────────────────────
/// 扫码是"盲操作"：员工抬头看的是货架上的条码，不是手机屏幕。
/// 商品挡着手、光线暗、手上戴着手套 —— 屏幕底部那行提示他根本看不见。
/// 所以"记上了没有"这件事**必须靠耳朵和手感确认**，光有视觉反馈不够。
/// 少了它，现场表现就是"扫了半天不知道扫上没有，只好每件都低头看一眼"，
/// 一个货架盘下来慢一倍。
///
/// ── 成功音和失败音必须一听就能分 ────────────────────────────
/// 成功 = 极短促高音「嘀」（2093Hz / 70ms）
/// 失败 = 两声低音「嗡-嗡」（196Hz）
/// 音色差距刻意拉大：现场是"听见了就下一件"，没人盯着屏幕核对。
/// 两个音听着差不多的话，**失败会被当成成功**，错误数据就混进去了。
///
/// 音源文件由 `tools/gen_sounds.py` 纯数学合成（不依赖任何外部素材），
/// 用 [BytesSource] 播放：Windows 走 SHCreateMemStream、Android 走字节流，
/// 两端行为一致，不受 asset 路径在桌面端解析差异的影响。
///
/// ⚠️ 类名带 Service 后缀是为了和 `scan_sink.dart` 里的 `ScanFeedback`
///    （"落一笔的结果"）**区分开** —— 两个东西都叫"反馈"，
///    同名会让 import 直接打架。
class ScanFeedbackService {
  ScanFeedbackService._();

  static final ScanFeedbackService I = ScanFeedbackService._();

  static const _kSound = 'xz_scan_sound';
  static const _kHaptic = 'xz_scan_haptic';

  static const String _okPath = 'assets/sounds/scan_ok.wav';
  static const String _failPath = 'assets/sounds/scan_fail.wav';

  /// 声音开关。默认开。
  bool sound = true;

  /// 触感开关。默认开：门店里最吵的地方（冷柜旁边）声音会被盖掉，
  /// 震动是那时候唯一的反馈。
  bool haptic = true;

  final AudioPlayer _player = AudioPlayer();

  Uint8List? _okBytes;
  Uint8List? _failBytes;
  bool _loaded = false;

  /// 启动调用：读开关 + 后台预加载音频字节。
  ///
  /// ⚠️ 预加载必须做：AudioPlayer 第一次播 asset 要走一轮 rootBundle 解码，
  /// 实测有 100~300ms 延迟 —— 扫码是连贯动作，第一枪慢半拍会让员工以为
  /// "没扫上"，然后重复扫（件数就这么虚高了）。
  Future<void> init() async {
    try {
      final p = await SharedPreferences.getInstance();
      sound = p.getBool(_kSound) ?? true;
      haptic = p.getBool(_kHaptic) ?? true;
    } catch (_) {}
    unawaited(_preload());
  }

  Future<void> _preload() async {
    if (_loaded) return;
    try {
      final r = await Future.wait(<Future<ByteData>>[
        rootBundle.load(_okPath),
        rootBundle.load(_failPath),
      ]);
      _okBytes = r[0].buffer.asUint8List();
      _failBytes = r[1].buffer.asUint8List();
      _loaded = true;
    } catch (e) {
      debugPrint('[scanfb] 音频加载失败: $e');
    }
  }

  Future<void> setSound(bool v) async {
    sound = v;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool(_kSound, v);
    } catch (_) {}
  }

  Future<void> setHaptic(bool v) async {
    haptic = v;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool(_kHaptic, v);
    } catch (_) {}
  }

  /// 记上了 → 「嘀」+ 轻震
  Future<void> ok() => _fire(ScanTone.ok);

  /// 没记上 → 「嗡-嗡」+ 重震
  Future<void> fail() => _fire(ScanTone.fail);

  Future<void> play(ScanTone t) => t == ScanTone.ok ? ok() : fail();

  /// 🔴 **这是界面唯一该调用的出口**，不要自己写 `accepted ? ok() : fail()`。
  ///
  /// 理由不是"少写几行"：那个三元表达式写反了**不崩、不报错**，
  /// 只会让"没记上"也响成功音 —— 而现场是听见了就扫下一件，
  /// 根本不会回头核对。走这一个出口，映射就只有 [scanToneFor] 一处，
  /// 也被单测钉住了。
  Future<void> forResult({required bool accepted}) =>
      play(scanToneFor(accepted: accepted));

  Future<void> _fire(ScanTone t) async {
    // 触感先走：它不依赖 IO，延迟最低 —— 耳朵还没听到，手已经感觉到了。
    if (haptic) {
      try {
        await (t == ScanTone.ok
            ? HapticFeedback.mediumImpact()
            : HapticFeedback.heavyImpact());
      } catch (_) {
        // 桌面端没有震动马达，平台通道会抛 —— 不是错误，忽略即可。
      }
    }
    if (!sound) return;
    await _play(t == ScanTone.ok ? _okBytes : _failBytes,
        t == ScanTone.ok ? _okPath : _failPath);
  }

  Future<void> _play(Uint8List? cached, String path) async {
    var bytes = cached;
    if (bytes == null) {
      await _preload();
      bytes = cached;
      if (bytes == null) return;
    }
    try {
      await _player.stop();
      await _player.setReleaseMode(ReleaseMode.release);
      // 现场吵，音量拉满。
      await _player.setVolume(1.0);
      await _player.play(BytesSource(bytes));
    } catch (e) {
      debugPrint('[scanfb] 播放失败 $path: $e');
    }
  }
}

/// 提示音类型。
enum ScanTone { ok, fail }

/// 应该响哪个音。**抽成纯函数是为了能在单测里钉住这个映射** ——
/// 反了的话不崩、不报错，只会让员工把"没记上"当成"记上了"。
ScanTone scanToneFor({required bool accepted}) =>
    accepted ? ScanTone.ok : ScanTone.fail;
