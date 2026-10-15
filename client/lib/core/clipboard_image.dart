import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:image/image.dart' as img;

/// Windows 剪贴板里的图片（Ctrl+V 直接发图，龙哥 2026-10-10 需求④）。
///
/// 取图顺序：
///   ① 注册格式 "PNG" —— 截图工具 / 浏览器复制图片时都会放一份无损 PNG；
///   ② CF_DIB 位图 —— 兜底，兼容性最广，但要自己处理底朝上、行对齐、BGR 顺序。
/// 非 Windows、剪贴板没图、或读不出来 → 返回 null，调用方按"没有图"处理
/// （Ctrl+V 继续走系统默认的文本粘贴）。
///
/// 🔴 这里用**裸 FFI**（自己声明 user32/kernel32 签名），不走 win32 包：
///    就这七个 API，手写比适配 win32 6.x 的强类型句柄包装更短更稳。
Uint8List? readClipboardImage() {
  if (!Platform.isWindows) return null;
  try {
    return _read();
  } catch (_) {
    return null; // 剪贴板是各程序抢的公共资源，任何异常都按"没图"处理
  }
}

/// 剪贴板里**复制的文件/文件夹路径**（Windows 资源管理器 Ctrl+C 走 CF_HDROP）。
///
/// 🔴 为什么必须单独支持它：Ctrl+V 在聊天里"能贴图"不等于"能贴文件"。
///    在资源管理器里选中三个文件按 Ctrl+C，剪贴板里放的是 CF_HDROP(=15)，
///    **里面一张位图都没有** —— 只认 CF_DIB/PNG 的旧实现会当成"没内容"放行，
///    于是 Ctrl+V 变成把文件名（如果有的话）粘进输入框，文件本身永远发不出去。
///
/// 只返回**真正存在的文件**（文件夹跳过，目录不可作为消息附件发送）。
/// 非 Windows / 剪贴板里没有文件 / 读不出来 → 返回空列表。
List<String> readClipboardFiles() {
  if (!Platform.isWindows) return const <String>[];
  try {
    return _readFiles();
  } catch (_) {
    return const <String>[];
  }
}

List<String> _readFiles() {
  if (_openClipboard(0) == 0) return const <String>[];
  try {
    if (_isAvailable(15 /* CF_HDROP */) == 0) return const <String>[];
    final raw = _globalBytes(_getData(15));
    if (raw == null || raw.length < 20) return const <String>[];

    // DROPFILES: DWORD pFiles; POINT pt(8); BOOL fNC(4); BOOL fWide(4);
    // —— fWide 在偏移 16：非 0 表示后面是 UTF-16 文件名，0 表示本地代码页。
    //    简体中文机上的 CF_HDROP 几乎都是宽字符，窄字符那一路按空处理掉。
    final bd = ByteData.sublistView(raw);
    final offset = bd.getUint32(0, Endian.little);
    final wide = bd.getInt32(16, Endian.little) != 0;
    if (offset <= 0 || offset >= raw.length || !wide) return const <String>[];

    // 文件名列表是**连续**的 UTF-16 串，两串之间一个 \0，结尾两个 \0。
    // 逐个读码元，遇到 \0 就收一个名字，连着两个 \0 就结束。
    final names = <String>[];
    final buf = StringBuffer();
    var end = offset;
    var blanks = 0;
    while (end + 1 < raw.length) {
      final code = bd.getUint16(end, Endian.little);
      end += 2;
      if (code == 0) {
        if (buf.isNotEmpty) names.add(buf.toString());
        buf.clear();
        if (++blanks >= 2) break;
      } else {
        blanks = 0;
        buf.writeCharCode(code);
      }
    }
    if (buf.isNotEmpty) names.add(buf.toString());

    return names.where((p) => p.trim().isNotEmpty).where(FileSystemEntity.isFileSync).toList();
  } finally {
    _closeClipboard();
  }
}

/// 把 PNG 字节写进 Windows 剪贴板（截图编辑器的「复制」用，对标 QQ 截图）。
///
/// 注册格式 "PNG" 而不是 CF_DIB：截图工具/浏览器都认这个，粘贴出去是无损的。
/// 返回 false 时调用方提示用户（常见原因是剪贴板被别的程序占着）。
bool writeClipboardPng(Uint8List png) {
  if (!Platform.isWindows) return false;
  if (png.isEmpty) return false;
  try {
    return _write(png);
  } catch (_) {
    return false;
  }
}

bool _write(Uint8List png) {
  // 申请可移动的全局内存，把 PNG 字节拷进去。剪贴板要求句柄可移动，
  // 用 GlobalAlloc 而不是 malloc —— 交给系统后由系统负责释放。
  final hMem = _globalAlloc(0x2000 /* GMEM_MOVEABLE */, png.length);
  if (hMem == 0) return false;
  final hp = Pointer<Void>.fromAddress(hMem);
  final locked = _globalLock(hp);
  if (locked == nullptr) {
    _globalFree(hp);
    return false;
  }
  locked.asTypedList(png.length).setRange(0, png.length, png);
  _globalUnlock(hp);

  // 剪贴板必须最终由本线程打开：打不开就是被别的程序占着，直接失败
  if (_openClipboard(0) == 0) {
    _globalFree(hp);
    return false;
  }
  try {
    _emptyClipboard();
    // 失败时句柄归系统所有（SetClipboardData 成功即转移所有权，
    // 失败要我们自己释放，否则泄漏一块全局内存）
    if (_setClipboardData(_regFormat('PNG'), hMem) == 0) {
      _globalFree(hp);
      return false;
    }
    return true;
  } finally {
    _closeClipboard();
  }
}

Uint8List? _read() {
  // OpenClipboard(NULL)：关联到调用线程；被别的程序占着会失败 → 当没图
  if (_openClipboard(0) == 0) return null;
  try {
    // ① "PNG" 注册格式优先（无损）
    final pngFmt = _regFormat('PNG');
    if (pngFmt != 0 && _isAvailable(pngFmt) != 0) {
      final bytes = _globalBytes(_getData(pngFmt));
      if (bytes != null && _isPng(bytes)) return bytes;
    }
    // ② CF_DIB（= 8）
    if (_isAvailable(8) != 0) {
      final dib = _globalBytes(_getData(8));
      if (dib != null) return _dibToPng(dib);
    }
    return null;
  } finally {
    _closeClipboard();
  }
}

bool _isPng(Uint8List b) =>
    b.length > 8 && b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47;

// ── Win32 绑定（user32 / kernel32）──

final DynamicLibrary _user32 = DynamicLibrary.open('user32.dll');
final DynamicLibrary _kernel32 = DynamicLibrary.open('kernel32.dll');

final int Function(int) _openClipboard = _user32
    .lookupFunction<Int32 Function(IntPtr), int Function(int)>('OpenClipboard');
final int Function() _closeClipboard =
    _user32.lookupFunction<Int32 Function(), int Function()>('CloseClipboard');
// —— 写剪贴板用（截图编辑器「复制」）——
final int Function() _emptyClipboard =
    _user32.lookupFunction<Int32 Function(), int Function()>('EmptyClipboard');
final int Function(int, int) _setClipboardData = _user32.lookupFunction<
    IntPtr Function(Uint32, IntPtr), int Function(int, int)>('SetClipboardData');
final int Function(int, int) _globalAlloc = _kernel32.lookupFunction<
    IntPtr Function(Uint32, IntPtr), int Function(int, int)>('GlobalAlloc');
final int Function(Pointer<Void>) _globalFree = _kernel32
    .lookupFunction<IntPtr Function(Pointer<Void>), int Function(Pointer<Void>)>(
        'GlobalFree');
final int Function(int) _isAvailable = _user32.lookupFunction<
    Int32 Function(Uint32), int Function(int)>('IsClipboardFormatAvailable');
final int Function(int) _getData = _user32.lookupFunction<
    UintPtr Function(Uint32), int Function(int)>('GetClipboardData');
final int Function(Pointer<Uint16>) _registerFormat = _user32.lookupFunction<
    Uint32 Function(Pointer<Uint16>), int Function(Pointer<Uint16>)>(
    'RegisterClipboardFormatW');
final Pointer<Uint8> Function(Pointer<Void>) _globalLock = _kernel32
    .lookupFunction<Pointer<Uint8> Function(Pointer<Void>),
        Pointer<Uint8> Function(Pointer<Void>)>('GlobalLock');
final int Function(Pointer<Void>) _globalUnlock = _kernel32.lookupFunction<
    Int32 Function(Pointer<Void>), int Function(Pointer<Void>)>('GlobalUnlock');
final int Function(Pointer<Void>) _globalSize = _kernel32.lookupFunction<
    Size Function(Pointer<Void>), int Function(Pointer<Void>)>('GlobalSize');

/// 把全局内存句柄的内容读成字节（读完立刻解锁）
Uint8List? _globalBytes(int h) {
  if (h == 0) return null;
  final hp = Pointer<Void>.fromAddress(h);
  final p = _globalLock(hp);
  if (p == nullptr) return null;
  try {
    final n = _globalSize(hp);
    if (n <= 0) return null;
    return Uint8List.fromList(p.asTypedList(n));
  } finally {
    _globalUnlock(hp);
  }
}

/// 把字符串注册成剪贴板格式名（"PNG" 这个名字是业界约定，系统启动后 id 恒定）
int _regFormat(String name) {
  final ws = name.toNativeUtf16();
  try {
    return _registerFormat(ws.cast<Uint16>());
  } finally {
    calloc.free(ws);
  }
}

// ── DIB → PNG ──

/// BITMAPINFOHEADER → PNG。
/// 只处理 24/32 位真彩（剪贴板里的图基本都是这两类）；调色板格式直接放弃。
Uint8List? _dibToPng(Uint8List d) {
  if (d.length < 40) return null;
  final bd = ByteData.sublistView(d);
  final headerSize = bd.getUint32(0, Endian.little);
  final width = bd.getInt32(4, Endian.little);
  final height = bd.getInt32(8, Endian.little);
  final bpp = bd.getUint16(14, Endian.little);
  final compression = bd.getUint32(16, Endian.little);
  if (width <= 0 || width > 20000 || height == 0 || height.abs() > 20000) return null;
  if ((bpp != 24 && bpp != 32) || (compression != 0 && compression != 3)) return null;

  final topDown = height < 0; // biHeight 为负 = 行序从上到下（少见但存在）
  final hpx = height.abs();
  final stride = ((width * bpp + 31) >> 5) << 2; // 行按 4 字节对齐
  final pxOffset = headerSize + (bpp <= 8 ? (1 << bpp) * 4 : 0);
  if (d.length < pxOffset + stride * hpx) return null;

  final out = img.Image(width: width, height: hpx);
  for (var y = 0; y < hpx; y++) {
    final srcRow = pxOffset + (topDown ? y : (hpx - 1 - y)) * stride;
    for (var x = 0; x < width; x++) {
      final o = srcRow + x * (bpp >> 3);
      // DIB 像素序是 BGR(A)
      final b = d[o], g = d[o + 1], r = d[o + 2];
      final a = bpp == 32 ? d[o + 3] : 255;
      // 很多程序的 DIB alpha 字节是没清的 0：全当不透明，不然截图出来全透明
      out.setPixelRgba(x, y, r, g, b, a == 0 ? 255 : a);
    }
  }
  return Uint8List.fromList(img.encodePng(out));
}
