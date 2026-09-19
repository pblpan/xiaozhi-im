import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';

/// 导出文件的落地能力：**打开 / 另存为**。
///
/// ── 从 IM 客户端切出来时砍掉了什么 ────────────────────────────
/// 原文件里还有一整套"聊天文件下载"（`http` 那条 `ensure/download`）
/// 与 Windows 专用的 `WinShell.open`。独立扫码枪两样都用不到：
/// 它**不发任何网络请求**（没有 http 依赖，清单里也没有 INTERNET 权限），
/// 且只出 Android 包（没有 win32 / WinShell）。
/// 留着它们的唯一后果是"依赖变多、装包变大"，所以整段删掉。
///
/// 设计要点（保留下来的部分）：
/// - 落盘目录是应用支持目录下的 `downloads/`（Android 对应 `<pkg>/files/`，
///   正好被 open_filex 与本 App 的 FileProvider 的 `files-path` 覆盖，
///   能直接交给系统打开/分享）；
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

  /// 用系统默认程序打开。返回空串表示成功，否则是给用户看的失败原因。
  static Future<String> open(File f) async {
    if (!await f.exists()) return '文件不存在';
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

  /// 另存为。返回保存位置（Android 是 SAF 的 content:// 标识）；
  /// 用户取消返回 null。
  ///
  /// file_picker 12.x 的 `saveFile` 是**静态方法**，且要求把 bytes 交给它，
  /// 由插件负责真正落盘（Android 走 SAF），返回的是 Uri 不是路径。
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

  /// 挑一个文件（用于导入商档 CSV）。
  ///
  /// ── 为什么只收 .csv 并且只让"单选" ────────────────────────────
  /// 商档导入的语义是**整份替换底表**（见 StockMasterRepo.upsertAll 的
  /// purgeMissing）。一次选两个文件的话"以哪个为准"根本没法解释，
  /// 界面上又看不出选了几个 —— 所以直接禁掉多选。
  ///
  /// ⚠️ `withData: true` 让插件直接把字节带回来：走的是系统 SAF，
  ///    **不需要 READ_EXTERNAL_STORAGE 权限**（那是老的、Android 11+
  ///    已经被分区存储废掉的老路子）。别再回去加那个权限。
  /// 用户取消返回 null（file_picker 12.x 取消时也是 null，不再抛）。
  static Future<FilePickResult?> pickCsv() async {
    // ⚠️ file_picker 12.x 的 API 换过一轮，照抄旧代码会直接编不过：
    //   · `FilePicker.platform.pickFiles(...)` → `FilePicker` 现在是
    //     `abstract final class`，**没有 `platform` 这个 getter**；
    //   · `withData: true` + `f.bytes` 已废弃 → 改成 `await f.readAsBytes()`；
    //   · 单选直接用 `pickFile`（`allowMultiple: false` 也已废弃）。
    final f = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: const ['csv', 'txt'],
    );
    if (f == null) return null; // 用户取消
    final bytes = await f.readAsBytes();
    // 空文件要当场说清楚是"文件本身是空的"，不能让它一路走到商档解析那边
    // 报"没读到任何商品"—— 那两句话指向的是完全不同的两件事：
    // 一句是"你选错文件了/文件没传完"，另一句是"你这表结构不对"。
    // 员工按错的提示去改表头，会白折腾半天。
    if (bytes.isEmpty) {
      throw const FormatException('这个文件是空的（0 字节）。重新选一份，'
          '或先用「导出商档模板」生成一份照着填。');
    }
    return FilePickResult(name: f.name, bytes: bytes);
  }
}

/// 挑回来的一个文件（名字 + 字节）。
///
/// 刻意**不给 path**：SAF 给的是一次性授权，把路径存下来下次再读会失败，
/// 而且那会让调用方误以为"可以晚点再读"。这里一次性把字节带回来。
class FilePickResult {
  const FilePickResult({required this.name, required this.bytes});

  final String name;
  final List<int> bytes;
}
