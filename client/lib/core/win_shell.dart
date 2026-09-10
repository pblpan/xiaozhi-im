import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// Windows 原生「用默认程序打开文件」。
///
/// 为什么不用 open_filex 在 Windows 上的实现？它在桌面端走的是
/// `Process.start('cmd', ['/c','start','',path])`，而 Flutter GUI 进程没有控制台，
/// Windows 会给这个 cmd 子进程**新分配一个控制台窗口**——每次打开文件都闪一下黑框。
/// Dart 的 Process.start 不暴露 CREATE_NO_WINDOW，绕不开。
///
/// 直接调 shell32 的 `ShellExecuteW` 就等价于在资源管理器里双击，
/// 既没有黑框，也能正确走文件关联（.xlsx 交给 Excel、.pdf 交给默认阅读器等）。
class WinShell {
  static final DynamicLibrary _shell32 = DynamicLibrary.open('shell32.dll');

  static final int Function(int, Pointer<Utf16>, Pointer<Utf16>,
      Pointer<Utf16>, Pointer<Utf16>, int) _shellExecuteW = _shell32
      .lookupFunction<
          IntPtr Function(IntPtr, Pointer<Utf16>, Pointer<Utf16>,
              Pointer<Utf16>, Pointer<Utf16>, Int32),
          int Function(int, Pointer<Utf16>, Pointer<Utf16>, Pointer<Utf16>,
              Pointer<Utf16>, int)>('ShellExecuteW');

  /// SW_SHOWNORMAL
  static const int _swShowNormal = 1;

  /// 用系统默认程序打开。返回 true 表示已交给系统。
  static bool open(String path) {
    final op = 'open'.toNativeUtf16();
    final file = path.toNativeUtf16();
    try {
      // ShellExecuteW 的返回值 > 32 才算成功（<=32 是各种错误码）
      final r = _shellExecuteW(
          0, op, file, nullptr, nullptr, _swShowNormal);
      return r > 32;
    } finally {
      calloc.free(op);
      calloc.free(file);
    }
  }

  /// 在资源管理器里定位到该文件（选中它）。失败返回 false。
  static bool revealInExplorer(String path) {
    try {
      // explorer /select,"C:\path\to\file" —— 路径必须带引号且不能有额外空格
      Process.start('explorer.exe', ['/select,', path],
          mode: ProcessStartMode.detached);
      return true;
    } catch (_) {
      return false;
    }
  }
}
