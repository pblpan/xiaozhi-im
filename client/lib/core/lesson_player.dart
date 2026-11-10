import 'package:flutter/foundation.dart';

/// 课件**内嵌播放器**在这台设备上能不能用。
///
/// ── 为什么要有这一层 ──────────────────────────────────────────
/// `video_player` 只有 Android / iOS / macOS / Web 的实现，**桌面端（Windows/Linux）都没有**。
/// 在桌面上硬 `new` 一个 VideoPlayerController，抛的是
/// `MissingPluginException` —— 而"抛异常"和"设备上真的不能播"是两回事：
/// 真机上装了播放器插件却因为某个解码器缺失而失败，也是同一个异常。
///
/// 所以判定**只看平台**，不看 try/catch。理由：
///   · 按平台判断，"桌面端走系统播放器"是**设计**，不是"出错后的兜底"；
///   · 用 try/catch 兜的话，哪天 Android 上插件没注册进去，也会被静默兜成
///     "系统播放器打开 → 标记完成"，进度又变回假的，而且看不出变假了。
/// 换句话说：宁可明确说"这台设备不支持"，也不要假装支持。
///
/// 🔴 **必须用白名单（谁有实现谁算支持），不能用 `!isWindows` 这种反写**：
///    2026-11 加 Linux 版时就踩了这一脚 —— 反写会把 Linux/macOS 之外的桌面端
///    一律判成"支持"，一进培训页就 MissingPluginException。新平台默认"不支持"，
///    确认有实现再往白名单里加。
class LessonPlayer {
  /// 测试注入口（真机别设）。
  static bool? debugOverride;

  /// 能不能内嵌播放。
  static bool get supported {
    final o = debugOverride;
    if (o != null) return o;
    if (kIsWeb) return false; // 目前客户端不跑 Web；写清楚免得以后有人顺手加
    return defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.macOS;
  }

  /// 不支持时给人看的一句话（别写"出错了"，那会让人以为是我们坏了）。
  static String get unsupportedReason =>
      '这台设备（桌面端）没有内嵌播放器，会用系统播放器打开。';
}
