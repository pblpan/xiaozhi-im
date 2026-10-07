import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

/// 应用内在线更新（龙哥 2026-10 需求）：
/// - Android：下载 APK → 调起系统安装器（需 REQUEST_INSTALL_PACKAGES）
/// - Windows：下载 exe → 调起安装（安装器自身处理 UAC / 运行中进程）
/// - iOS / 其他：直接打开链接（App Store / 下载页）
///
/// [url] 必须是绝对地址或相对 baseUrl 的地址（调用方先用 RemoteConfig._resolveUrl 拼好）。
class AppUpdater {
  /// 当前平台是否支持「下载后直接调起安装」
  static bool get supportsDirectInstall => Platform.isAndroid || Platform.isWindows;

  /// 触发一次更新：下载（如需）并调起安装 / 打开链接。
  static Future<void> startUpdate(BuildContext context, String url) async {
    // iOS / 其他平台：直接打开链接
    if (!supportsDirectInstall) {
      await _openLink(url);
      return;
    }
    final filePath = await _downloadWithProgress(context, url);
    if (filePath == null) return; // 用户取消或下载失败（已提示）
    await _install(filePath);
  }

  static Future<void> _install(String filePath) async {
    // open_filex 在安卓会调起系统安装器；在 Windows 会启动 exe。
    final res = await OpenFilex.open(filePath);
    if (res.type != ResultType.done) {
      // 调起失败（如安卓未授权「安装未知应用」）→ 退回浏览器打开
      await _openLink(filePath);
    }
  }

  static Future<void> _openLink(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  /// 带进度条的下载；返回落盘路径，失败/取消返回 null。
  static Future<String?> _downloadWithProgress(BuildContext context, String url) async {
    final progress = ValueNotifier<double?>(null);
    final status = ValueNotifier<String>('准备中…');
    final error = ValueNotifier<String?>(null);
    final cancelled = ValueNotifier<bool>(false);
    final done = Completer<String?>();

    unawaited(showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('正在下载更新'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ValueListenableBuilder<double?>(
              valueListenable: progress,
              builder: (_, v, __) => LinearProgressIndicator(value: v),
            ),
            const SizedBox(height: 10),
            ValueListenableBuilder<String>(
              valueListenable: status,
              builder: (_, s, __) => Text(s, style: const TextStyle(fontSize: 13)),
            ),
            ValueListenableBuilder<String?>(
              valueListenable: error,
              builder: (_, e, __) => e == null
                  ? const SizedBox.shrink()
                  : Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(e, style: const TextStyle(fontSize: 12, color: Colors.red)),
                    ),
            ),
          ],
        ),
        actions: [
          ValueListenableBuilder<bool>(
            valueListenable: cancelled,
            builder: (_, c, __) => TextButton(
              onPressed: c
                  ? null
                  : () {
                      cancelled.value = true;
                      if (!done.isCompleted) done.complete(null);
                    },
              child: const Text('取消'),
            ),
          ),
        ],
      ),
    ));

    String? filePath;
    try {
      final tmp = await getTemporaryDirectory();
      final fname = p.basename(Uri.parse(url).path);
      final ext = p.extension(fname).isNotEmpty ? p.extension(fname) : '.tmp';
      final target = File('${tmp.path}/xz_update$ext');

      final client = http.Client();
      final resp = await client.send(http.Request('GET', Uri.parse(url)));
      if (resp.statusCode != 200) {
        error.value = '下载失败（HTTP ${resp.statusCode}）';
      } else {
        final total = resp.contentLength;
        final out = target.openWrite();
        var received = 0;
        await for (final chunk in resp.stream) {
          if (cancelled.value) {
            await out.close();
            break;
          }
          out.add(chunk);
          received += chunk.length;
          if (total != null && total > 0) {
            progress.value = received / total;
            status.value =
                '${(received / 1024 / 1024).toStringAsFixed(1)} / ${(total / 1024 / 1024).toStringAsFixed(1)} MB';
          }
        }
        await out.close();
        client.close();
        if (cancelled.value) {
          try {
            await target.delete();
          } catch (_) {}
        } else {
          filePath = target.path;
        }
      }
    } catch (e) {
      error.value = '下载出错：$e';
    }

    // 关掉进度框（如果还开着）
    if (Navigator.of(context, rootNavigator: true).canPop()) {
      Navigator.of(context, rootNavigator: true).pop();
    }
    if (!done.isCompleted) done.complete(filePath);
    return done.future;
  }
}
