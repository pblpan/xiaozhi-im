import 'dart:io';

import 'package:flutter/services.dart';

/// 导出后"把文件发出去"的三条路。
enum ShareChannel {
  /// 系统分享面板（Android / iOS）：微信、企微、钉钉直接列在里面
  systemShare,

  /// 打开所在文件夹，让用户拖进微信（Windows 的常规做法）
  openFolder,

  /// 两条都没有：**不给按钮**。点了没反应比没这个按钮更糟。
  none,
}

/// 出站分享：把本地文件**直接交给系统分享面板**（微信 / 企微 / 钉钉 / 本 App…），
/// 而不是"先另存为、再自己去文件管理器里找回来发"。
///
/// ── 为什么要走原生，不用纯 Dart ────────────────────────────────
/// Android 7.0（API 24）起，把 `file://` 路径交给别的 App 会直接抛
/// `FileUriExposedException` —— 系统不允许外部进程拿到我们的私有路径。
/// 必须由原生侧用 `FileProvider` 把自己的文件转成 `content://` 再交出去，
/// 且只授一次性读权限。Dart 层拿不到 `FileProvider`，所以这件事只能原生做。
///
/// ── 平台差异（这条很重要，别指望一套代码两边都对）────────────
/// · **Android**：系统分享面板是真东西，微信/企微都列在里面 → 直接分享。
/// · **Windows**：没有"系统分享面板"这个统一入口（Windows 的文件分享是
///   UWP 那套，桌面应用拿不到）。硬凑只会做出一个"点了没反应"的按钮。
///   所以桌面端 [canShareToOthers] 返回 false，界面**换一个词**给出口：
///   "打开所在文件夹"，让用户把文件拖进微信 —— 这是桌面上真实的做法。
///
/// ── 约定 ───────────────────────────────────────────────────────
/// 和 `FileIo.open()` 一致：返回**空串表示成功**，非空是给用户看的失败原因。
/// 两套返回值约定混用会让调用方写错判断，这里刻意对齐。
class FileShare {
  /// 与 MainActivity 的 CHANNEL 常量必须逐字一致（写错 = 点了分享毫无反应）
  static const MethodChannel _ch = MethodChannel('xiaozhi/share');

  /// 这台设备有没有"系统分享面板"这条路。
  static bool get canShareToOthers => Platform.isAndroid || Platform.isIOS;

  /// 这条路怎么走。
  ///
  /// 🔴 抽成**纯函数**（不直接读 `Platform`）是有意的：界面里写死
  /// `Platform.isAndroid` 的话，测试跑在 Windows 上就永远只走桌面分支 ——
  /// 手机那条路（也是现场唯一在用的那条）**一次都没被验证过**，
  /// 恰恰是最容易写错、又最晚才被发现的地方。
  /// 参数化之后两条分支都能在测试里过一遍。
  static ShareChannel channelFor({
    required bool canShare,
    required bool isWindows,
  }) {
    if (canShare) return ShareChannel.systemShare;
    if (isWindows) return ShareChannel.openFolder;
    return ShareChannel.none;
  }

  /// 当前设备的实际选择。
  static ShareChannel get channel =>
      channelFor(canShare: canShareToOthers, isWindows: Platform.isWindows);

  /// 按扩展名猜 MIME。
  ///
  /// 猜错的后果不是报错，而是**分享面板里少了微信/企微**（它们按 MIME 过滤），
  /// 用户看到的是"能分享，但目标 App 不在列表里"，非常难查。
  /// 所以宁可退到 `*/*`：多列几个 App 无害，少列才是 bug。
  static String mimeOf(String nameOrPath) {
    final p = nameOrPath.toLowerCase();
    if (p.endsWith('.csv')) return 'text/csv';
    if (p.endsWith('.txt')) return 'text/plain';
    if (p.endsWith('.xlsx')) {
      return 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
    }
    if (p.endsWith('.pdf')) return 'application/pdf';
    if (p.endsWith('.jpg') || p.endsWith('.jpeg')) return 'image/jpeg';
    if (p.endsWith('.png')) return 'image/png';
    if (p.endsWith('.zip')) return 'application/zip';
    return '*/*';
  }

  /// 把 [f] 交给系统分享面板。[subject] 作为标题（邮件/部分 App 会显示）。
  /// 返回空串 = 已拉起分享面板；非空 = 失败原因。
  static Future<String> toOthers(File f, {String? subject}) async {
    if (!await f.exists()) return '文件不存在';
    if (!canShareToOthers) return '当前平台没有系统分享面板';
    try {
      final r = await _ch.invokeMethod<String>('shareFile', <String, dynamic>{
        'path': f.path,
        'mime': mimeOf(f.path),
        'subject': subject ?? f.uri.pathSegments.last,
      });
      return r ?? '';
    } on MissingPluginException {
      // 通道没注册（例如跑在旧安装包上）：不能静默吞掉，否则用户看到"点了没反应"
      return '当前版本不支持直接分享，请改用「另存为」';
    } catch (e) {
      return '分享失败：$e';
    }
  }
}
