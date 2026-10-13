import 'package:wakelock_plus/wakelock_plus.dart';

/// 下载期间的屏幕常亮开关（龙哥 2026-10-13 报的问题）：
///
/// 症状是「更新系统 / 下载商档，息屏就中断」—— Android 息屏后进 Doze，
/// CPU 与网络都被挂起，正在跑的 HTTP 流必断。修法 = 下载期间把屏幕钉住
/// （`FLAG_KEEP_SCREEN_ON`，**不需要任何 Android 权限**，回锁后台也自动失效）；
/// Windows 端走 `SetThreadExecutionState`，桌面下载大包同样受益。
///
/// 🔴 **全部静默兜底**：测试环境（没有平台通道）/ 未来不支持的平台，
///    enable/disable 抛什么都吞掉 —— 保活失败顶多下载慢点，
///    绝不能把业务功能本身炸掉（syncFromServer 的测试注入链一点都不能碰）。
class WakeLock {
  /// 下载开始时调用：屏幕保持常亮直到 [disable]。
  static Future<void> enable() async {
    try {
      await WakelockPlus.enable();
    } catch (_) {}
  }

  /// 下载结束（成功/失败/取消）必须调用：把控制权还给系统。
  /// 🔴 放 finally 里，不能只写在成功路径。
  static Future<void> disable() async {
    try {
      await WakelockPlus.disable();
    } catch (_) {}
  }
}
