// 远程协助「被控端」的屏幕采集前台服务开关（仅 Android 需要）
//
// ─────────────────────────────────────────────────────────────
// 为什么必须有这个桥
// ─────────────────────────────────────────────────────────────
// Android 10（API 29）起 MediaProjection 要求调用方处于前台；
// Android 14（API 34）起写死了一条：没有正在运行的 mediaProjection 类型
// 前台服务，`getMediaProjection()` **直接抛 SecurityException**。
// 而 flutter_webrtc 自己不带这个服务（它的 AndroidManifest 是空的），
// 必须由宿主 App 在调用 getDisplayMedia 之前先把服务拉起来。
//
// 少了这一步的现象非常像"功能没做"：点「开始共享」，权限框弹了、也同意了，
// 然后画面永远是黑的 —— Dart 侧只拿到一个 SecurityException，
// 光看它根本猜不到是缺了一个前台服务。
//
// 桌面端不需要：Windows 的桌面采集走 Desktop Duplication API，
// 没有"必须在前台"这回事。所以这里在非 Android 上一切调用都是空操作。

import 'dart:io' show Platform;

import 'package:flutter/services.dart';

class RemoteCapture {
  RemoteCapture._();

  static const MethodChannel _ch = MethodChannel('xiaozhi/remote_capture');

  static bool _running = false;

  /// 在 getDisplayMedia 之前调用。非 Android 上直接跳过。
  ///
  /// 刻意**不 await 结果之外的任何东西**：起服务要几百毫秒，
  /// 但真正决定成败的是后面的 getMediaProjection ——
  /// 这里失败也不该拦住流程（老机型 <29 本来就不需要它）。
  static Future<void> ensure() async {
    if (!Platform.isAndroid || _running) return;
    try {
      await _ch.invokeMethod<void>('start');
      _running = true;
    } catch (e) {
      // 起不来就照原样继续：让 getDisplayMedia 自己去报真正的错
      _running = false;
    }
  }

  /// 会话结束时停掉。不要省这一步 —— 那条常驻通知是"有人正在录屏"的提示，
  /// 会话都结束了还挂着，用户会以为被偷偷录屏。
  static Future<void> release() async {
    if (!Platform.isAndroid || !_running) return;
    _running = false;
    try {
      await _ch.invokeMethod<void>('stop');
    } catch (_) {
      // 停不掉就算了：进程被杀时系统会连通知一起收走
    }
  }
}
