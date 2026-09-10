import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:xiaozhi_im_client/core/win_shell.dart';

/// 文件消息的落地能力：**下载到本地 → 打开 / 另存为**。
///
/// 设计要点：
/// - 下载落在应用支持目录的 `downloads/` 下（Android 对应 `<pkg>/files/`，
///   正好被 open_filex 的 FileProvider `files-path` 覆盖，能直接交给系统打开）；
/// - 落地文件名带 `fileId_` 前缀，避免不同会话里的同名文件互相覆盖；
/// - 已存在且非空就直接复用，不重复下载（微信也是这个行为）。
class FileIo {
  static Directory? _dir;

  /// 落盘目录
  static Future<Directory> dir() async {
    if (_dir != null) return _dir!;
    final base = await getApplicationSupportDirectory();
    final d = Directory('${base.path}${Platform.pathSeparator}downloads');
    if (!await d.exists()) await d.create(recursive: true);
    return _dir = d;
  }

  /// 去掉 Windows / Android 都不接受的文件名字符
  static String safeName(String name) {
    var n = name.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '_').trim();
    if (n.isEmpty) n = 'file';
    if (n.length > 120) {
      final dot = n.lastIndexOf('.');
      final ext = (dot > 0 && n.length - dot <= 12) ? n.substring(dot) : '';
      n = n.substring(0, 120 - ext.length) + ext;
    }
    return n;
  }

  /// 这条消息对应的本地文件（不管存不存在）
  static Future<File> localPath(int fileId, String name) async {
    final d = await dir();
    return File(
        '${d.path}${Platform.pathSeparator}${fileId}_${safeName(name)}');
  }

  /// 确保文件已在本地；没有就下载。onProgress 回调 0~1（拿不到总长时不回调）。
  static Future<File> ensure({
    required String url,
    required int fileId,
    required String name,
    void Function(double p)? onProgress,
  }) async {
    final f = await localPath(fileId, name);
    if (await f.exists() && await f.length() > 0) {
      onProgress?.call(1);
      return f;
    }
    return download(url, f, onProgress: onProgress);
  }

  static Future<File> download(String url, File dest,
      {void Function(double p)? onProgress}) async {
    final uri = Uri.tryParse(url);
    if (uri == null) throw Exception('下载地址不正确');
    final client = http.Client();
    try {
      final res = await client.send(http.Request('GET', uri));
      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw Exception('下载失败 HTTP ${res.statusCode}');
      }
      final total = res.contentLength ?? 0;
      final tmp = File('${dest.path}.part');
      final sink = tmp.openWrite();
      var got = 0;
      try {
        await for (final chunk in res.stream) {
          sink.add(chunk);
          got += chunk.length;
          if (total > 0) onProgress?.call(got / total);
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
      // 先写 .part 再改名：中途失败不会留下半截文件被当成"已下载"
      if (await dest.exists()) await dest.delete();
      return await tmp.rename(dest.path);
    } finally {
      client.close();
    }
  }

  /// 用系统默认程序打开。返回空串表示成功，否则是给用户看的失败原因。
  static Future<String> open(File f) async {
    if (!await f.exists()) return '文件不存在';
    // Windows 单独走原生 ShellExecuteW：open_filex 在桌面端是 `cmd /c start`，
    // 会给 GUI 进程弹一个控制台黑框（每次打开文件闪一下）。
    if (Platform.isWindows) {
      try {
        return WinShell.open(f.path)
            ? ''
            : '打开失败：系统里没有关联该文件类型的程序';
      } catch (e) {
        return '打开失败: $e';
      }
    }
    try {
      final r = await OpenFilex.open(f.path);
      switch (r.type) {
        case ResultType.done:
          return '';
        case ResultType.noAppToOpen:
          return '没有能打开该类型文件的应用';
        case ResultType.fileNotFound:
          return '文件不存在';
        case ResultType.permissionDenied:
          return '没有权限打开该文件';
        case ResultType.error:
          return r.message.isEmpty ? '打开失败' : r.message;
      }
    } catch (e) {
      return '打开失败: $e';
    }
  }

  /// 另存为。返回保存位置（桌面是路径，Android 是 SAF 的 content:// 标识）；
  /// 用户取消返回 null。
  ///
  /// file_picker 12.x 的 `saveFile` 是**静态方法**，且要求把 bytes 交给它，
  /// 由插件负责真正落盘（桌面写文件、Android 走 SAF），返回的是 Uri 不是路径。
  static Future<String?> saveAs(File src, String name) async {
    final safe = safeName(name);
    final uri = await FilePicker.saveFile(
      dialogTitle: '另存为',
      fileName: safe,
      bytes: await src.readAsBytes(),
    );
    if (uri == null) return null;
    if (uri.scheme == 'file') {
      try {
        return uri.toFilePath();
      } catch (_) {
        return uri.toString();
      }
    }
    return uri.toString();
  }
}
