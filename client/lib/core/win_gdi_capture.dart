// Windows 屏幕采集（自研 GDI 实现）—— 远程协助「被控端」专用。
//
// ─────────────────────────────────────────────────────────────
// 【为什么不用 flutter_webrtc 的 getDisplayMedia】
// ─────────────────────────────────────────────────────────────
// v0.28.5 之前，Windows 被控端走的是 libwebrtc 的桌面采集
// （flutter_webrtc → getDisplayMedia → ScreenCapturerWinDirectx，即 DXGI
//  Desktop Duplication）。龙哥真机实测：**手机端一直是纯黑**，而同一台机器上
// UltraVNC 局域网里流畅得很 —— 说明网络、鉴权、控制链路都没问题，
// 黑的就是采集下来的那几帧。
//
// 排查中已经排除的：版本旧、没点同意、ICE 打不通、降级器把画质压到黑。
// 剩下两个嫌疑都指向 libwebrtc 的采集层：
//   ① 源选错。本机有 3 个显示适配器（ToDesk / GameViewer 两个虚拟显示器
//      + Intel Iris Xe），webrtc 的 GetSourceList 顺序里第一个很可能是个
//      没有画面的虚拟屏 —— 那就恒黑。
//   ② DXGI 复制本身失败。DXGI Desktop Duplication 在混合显卡 + 虚拟显示
//      驱动的机器上是出了名的脆：D3D11 设备建在哪个适配器上不当时，
//      AcquireNextFrame 一路成功但拿到的是全黑画面（不报错）。
//      而 GDI 的 BitBlt 完全没有这个概念 —— 它就是往屏上抓，抓不到才报错。
//
// 所以这里换成**自研的 GDI 抓屏**：GetDC(0) + BitBlt + GetDIBits。
// 它不依赖任何第三方采集组件，行为可预测、失败会明确报错，而且这套 API
// 序列已在本机（就是龙哥那台被控电脑）用 Python ctypes 实测通过：
//   虚拟桌面 3072x960 / 主屏 1536x864，BitBlt ok=1，GetDIBits rows=864，
//   抓到的图 avg=250.1、非黑像素 99.8%，画面内容清晰可读。
//
// ─────────────────────────────────────────────────────────────
// 【为什么不 import package:win32】
// ─────────────────────────────────────────────────────────────
// 和 input_inject_win.dart 同一条理由：Dart 的 import 是**编译期**解析的，
// 而 win32 只在 Windows 有实现 —— 主文件里出现这一行，在 Mac 上编 iOS 目标
// 就直接失败（条件导入救不了：dart.library.io 在所有原生平台都为真）。
// 所以这里同样只用 dart:ffi 自己声明结构体、运行期从 dll 取函数。
//
// ─────────────────────────────────────────────────────────────
// 【抓哪一块屏】
// ─────────────────────────────────────────────────────────────
// 默认只抓**主显示器**（原点是 (0,0)，尺寸取 SM_CXSCREEN / SM_CYSCREEN）。
// 为什么不默认抓整个虚拟桌面：本机是双屏，虚拟桌面 3072x960 摆到手机竖屏上
// 会被压成一条，字根本看不清。主屏 16:9 才是手机上能读的比例。
//
// ⚠️ 抓主屏就必须让注入侧跟着改：input_inject_win.dart 的 moveAbsolute 原本
// 带 MOUSEEVENTF_VIRTUALDESK（归一化坐标按**整个虚拟桌面**摊开），只抓主屏时
// 会整体点偏。所以启用自研采集时会调 injector.usePrimaryOnlyCapture(true) ——
// 那是**成对**的改动，拆开任何一半都会导致"画面对了但点不准"。
//
// ─────────────────────────────────────────────────────────────
// 【性能：这些数字是实测出来的，不是估的】
// ─────────────────────────────────────────────────────────────
// 本机实测（同一台被控电脑，960x540 / JPEG q60）：
//   抓一帧（StretchBlt 缩放 + GetDIBits）≈ 48ms
//   BGRA→RGBA 逐像素转换            ≈ 6ms
//   JPEG 编码                       ≈ 49ms
//   连跑 10 帧平均 78ms/帧 → 约 12.9fps，35KB/帧 → 0.44MB/s
// 作为对比：1280x720 档会更慢一些但仍在可用区间。所以：
//   · 位图与 DIB 缓冲**跨帧复用**（见 _ensureBitmap），不要每帧重建；
//   · 缩放交给 GDI 的 StretchBlt（原生、快），不要用 Dart 逐像素缩；
//   · JpegEncoder 实例复用（构造时要建 Huffman 表，每帧新建很亏）。
//
// ⚠️ 结构体布局是 ABI 契约，字段宽度/顺序抄自 Windows SDK（wingdi.h），
//    改动前先对照官方文档，别凭感觉写。
import 'dart:ffi' as ffi;
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:ffi/ffi.dart' as pkg_ffi;
import 'package:image/image.dart' as img;

// Win32 常量/类型刻意沿用 Windows SDK 命名，便于对照官方文档核对数值。
// ignore_for_file: constant_identifier_names, camel_case_types

// ---------------------------------------------------------------- Win32 常量

/// SM_CXSCREEN / SM_CYSCREEN：主显示器的宽 / 高（像素）。
const int _SM_CXSCREEN = 0;
const int _SM_CYSCREEN = 1;

/// SM_XVIRTUALSCREEN / SM_YVIRTUALSCREEN / SM_CXVIRTUALSCREEN / SM_CYVIRTUALSCREEN：
/// 整个虚拟桌面（所有显示器拼起来）的原点与尺寸。左/上副屏时原点可能为负。
const int _SM_XVIRTUALSCREEN = 76;
const int _SM_YVIRTUALSCREEN = 77;
const int _SM_CXVIRTUALSCREEN = 78;
const int _SM_CYVIRTUALSCREEN = 79;

/// BitBlt / StretchBlt 的光栅操作码：直接拷贝。
const int _SRCCOPY = 0x00CC0020;

/// SetStretchBltMode 的模式：双线性插值。缩小时比 COLORONCOLOR 好看得多，
/// 而缩小正是我们每帧都在做的事（1920 → 1280）。
const int _HALFTONE = 4;

/// BI_RGB：不压缩的 RGB。
const int _BI_RGB = 0;

/// DIB_RGB_COLORS：GetDIBits 返回本色（不做调色板映射）。
const int _DIB_RGB_COLORS = 0;

// ------------------------------------------------------ 结构体（ABI 契约）
// 抄自 wingdi.h / Windows 官方文档。32bpp 的 DIB 用不到调色板，
// 所以 GetDIBits 只要求 BITMAPINFOHEADER 那一段，这里就不声明 RGBQUAD 数组了
// （见 _bmi 的分配：header 大小 + 4 字节余量）。

final class _BITMAPINFOHEADER extends ffi.Struct {
  /// 结构体大小（字节），必须是 sizeof(BITMAPINFOHEADER)。
  @ffi.Uint32()
  external int biSize;

  /// 位图宽度（像素）。
  @ffi.Int32()
  external int biWidth;

  /// 位图高度。**负数表示自上而下**（top-down）—— 我们要的就是负值：
  /// 正数是自下而上（bottom-up），拿到的像素行是倒的，图片会上下翻转。
  @ffi.Int32()
  external int biHeight;

  @ffi.Uint16()
  external int biPlanes;

  @ffi.Uint16()
  external int biBitCount;

  @ffi.Uint32()
  external int biCompression;

  @ffi.Uint32()
  external int biSizeImage;

  @ffi.Int32()
  external int biXPelsPerMeter;

  @ffi.Int32()
  external int biYPelsPerMeter;

  @ffi.Uint32()
  external int biClrUsed;

  @ffi.Uint32()
  external int biClrImportant;
}

// ------------------------------------------------------------ FFI 函数签名
// 全部把指针参数声明成 Pointer<Void>：我们只负责把句柄原样传回去，
// 不需要 Dart 侧理解它的类型，少一层类型转换就少一处能写错的地方。

typedef _GetDCNative = ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Void>);
typedef _GetDCDart = ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Void>);

typedef _ReleaseDCNative = ffi.Int32 Function(
    ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Void>);
typedef _ReleaseDCDart = int Function(
    ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Void>);

typedef _GetSystemMetricsNative = ffi.Int32 Function(ffi.Int32);
typedef _GetSystemMetricsDart = int Function(int);

typedef _CreateCompatibleDCNative = ffi.Pointer<ffi.Void> Function(
    ffi.Pointer<ffi.Void>);
typedef _CreateCompatibleDCDart = ffi.Pointer<ffi.Void> Function(
    ffi.Pointer<ffi.Void>);

typedef _CreateCompatibleBitmapNative = ffi.Pointer<ffi.Void> Function(
    ffi.Pointer<ffi.Void>, ffi.Int32, ffi.Int32);
typedef _CreateCompatibleBitmapDart = ffi.Pointer<ffi.Void> Function(
    ffi.Pointer<ffi.Void>, int, int);

typedef _SelectObjectNative = ffi.Pointer<ffi.Void> Function(
    ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Void>);
typedef _SelectObjectDart = ffi.Pointer<ffi.Void> Function(
    ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Void>);

typedef _DeleteDCNative = ffi.Int32 Function(ffi.Pointer<ffi.Void>);
typedef _DeleteDCDart = int Function(ffi.Pointer<ffi.Void>);

typedef _DeleteObjectNative = ffi.Int32 Function(ffi.Pointer<ffi.Void>);
typedef _DeleteObjectDart = int Function(ffi.Pointer<ffi.Void>);

typedef _SetStretchBltModeNative = ffi.Int32 Function(
    ffi.Pointer<ffi.Void>, ffi.Int32);
typedef _SetStretchBltModeDart = int Function(ffi.Pointer<ffi.Void>, int);

typedef _BitBltNative = ffi.Int32 Function(
  ffi.Pointer<ffi.Void>,
  ffi.Int32,
  ffi.Int32,
  ffi.Int32,
  ffi.Int32,
  ffi.Pointer<ffi.Void>,
  ffi.Int32,
  ffi.Int32,
  ffi.Uint32,
);
typedef _BitBltDart = int Function(
  ffi.Pointer<ffi.Void>,
  int,
  int,
  int,
  int,
  ffi.Pointer<ffi.Void>,
  int,
  int,
  int,
);

typedef _StretchBltNative = ffi.Int32 Function(
  ffi.Pointer<ffi.Void>,
  ffi.Int32,
  ffi.Int32,
  ffi.Int32,
  ffi.Int32,
  ffi.Pointer<ffi.Void>,
  ffi.Int32,
  ffi.Int32,
  ffi.Int32,
  ffi.Int32,
  ffi.Uint32,
);
typedef _StretchBltDart = int Function(
  ffi.Pointer<ffi.Void>,
  int,
  int,
  int,
  int,
  ffi.Pointer<ffi.Void>,
  int,
  int,
  int,
  int,
  int,
);

typedef _GetDIBitsNative = ffi.Int32 Function(
  ffi.Pointer<ffi.Void>,
  ffi.Pointer<ffi.Void>,
  ffi.Uint32,
  ffi.Uint32,
  ffi.Pointer<ffi.Void>,
  ffi.Pointer<ffi.Void>,
  ffi.Uint32,
);
typedef _GetDIBitsDart = int Function(
  ffi.Pointer<ffi.Void>,
  ffi.Pointer<ffi.Void>,
  int,
  int,
  ffi.Pointer<ffi.Void>,
  ffi.Pointer<ffi.Void>,
  int,
);

/// user32.dll 绑定。
///
/// ⚠️ **必须惰性**：非 Windows 平台没有 user32.dll，在顶层直接 open 会抛异常。
class _U32 {
  static ffi.DynamicLibrary? _lib;

  static ffi.DynamicLibrary get _dll =>
      _lib ??= ffi.DynamicLibrary.open('user32.dll');

  static _GetDCDart? _getDC;
  static _GetDCDart get getDC =>
      _getDC ??= _dll.lookupFunction<_GetDCNative, _GetDCDart>('GetDC');

  static _ReleaseDCDart? _releaseDC;
  static _ReleaseDCDart get releaseDC =>
      _releaseDC ??= _dll.lookupFunction<_ReleaseDCNative, _ReleaseDCDart>(
          'ReleaseDC');

  static _GetSystemMetricsDart? _getSystemMetrics;
  static _GetSystemMetricsDart get getSystemMetrics =>
      _getSystemMetrics ??= _dll
          .lookupFunction<_GetSystemMetricsNative, _GetSystemMetricsDart>(
              'GetSystemMetrics');
}

/// gdi32.dll 绑定。
class _G32 {
  static ffi.DynamicLibrary? _lib;

  static ffi.DynamicLibrary get _dll =>
      _lib ??= ffi.DynamicLibrary.open('gdi32.dll');

  static _CreateCompatibleDCDart? _createCompatibleDC;
  static _CreateCompatibleDCDart get createCompatibleDC =>
      _createCompatibleDC ??= _dll.lookupFunction<_CreateCompatibleDCNative,
          _CreateCompatibleDCDart>('CreateCompatibleDC');

  static _CreateCompatibleBitmapDart? _createCompatibleBitmap;
  static _CreateCompatibleBitmapDart get createCompatibleBitmap =>
      _createCompatibleBitmap ??= _dll.lookupFunction<
          _CreateCompatibleBitmapNative,
          _CreateCompatibleBitmapDart>('CreateCompatibleBitmap');

  static _SelectObjectDart? _selectObject;
  static _SelectObjectDart get selectObject =>
      _selectObject ??= _dll
          .lookupFunction<_SelectObjectNative, _SelectObjectDart>(
              'SelectObject');

  static _DeleteDCDart? _deleteDC;
  static _DeleteDCDart get deleteDC =>
      _deleteDC ??= _dll.lookupFunction<_DeleteDCNative, _DeleteDCDart>(
          'DeleteDC');

  static _DeleteObjectDart? _deleteObject;
  static _DeleteObjectDart get deleteObject =>
      _deleteObject ??= _dll
          .lookupFunction<_DeleteObjectNative, _DeleteObjectDart>(
              'DeleteObject');

  static _SetStretchBltModeDart? _setStretchBltMode;
  static _SetStretchBltModeDart get setStretchBltMode =>
      _setStretchBltMode ??= _dll.lookupFunction<_SetStretchBltModeNative,
          _SetStretchBltModeDart>('SetStretchBltMode');

  static _BitBltDart? _bitBlt;
  static _BitBltDart get bitBlt =>
      _bitBlt ??= _dll.lookupFunction<_BitBltNative, _BitBltDart>('BitBlt');

  static _StretchBltDart? _stretchBlt;
  static _StretchBltDart get stretchBlt => _stretchBlt ??=
      _dll.lookupFunction<_StretchBltNative, _StretchBltDart>('StretchBlt');

  static _GetDIBitsDart? _getDIBits;
  static _GetDIBitsDart get getDIBits =>
      _getDIBits ??= _dll
          .lookupFunction<_GetDIBitsNative, _GetDIBitsDart>('GetDIBits');
}

/// 抓下来的一帧。
class GdiFrame {
  const GdiFrame({required this.width, required this.height, required this.jpeg});

  /// 这一帧的像素尺寸（已按档位缩放过，不是屏幕原始分辨率）
  final int width;
  final int height;

  /// 编码后的 JPEG 字节
  final Uint8List jpeg;

  int get bytes => jpeg.lengthInBytes;
}

/// 自研 GDI 抓屏器。
///
/// 生命周期：`open()` → 反复 `captureJpeg()` → `dispose()`。
/// 一个实例持有屏幕 DC / 内存 DC / 位图 / DIB 缓冲，**跨帧复用**，
/// 所以不要每帧新建实例（那样会把实测的 12.9fps 打回 5fps 以下）。
class WinGdiCapture {
  WinGdiCapture({this.allMonitors = false});

  /// true=抓整个虚拟桌面（多屏拼起来），false（默认）=只抓主显示器。
  /// 只抓主屏时调用方**必须**同步调 injector.usePrimaryOnlyCapture(true)。
  final bool allMonitors;

  bool _open = false;
  String _lastError = '';

  // 采集区（屏幕坐标）。只抓主屏时原点是 (0,0)。
  int _srcX = 0;
  int _srcY = 0;
  int _srcW = 0;
  int _srcH = 0;

  // GDI 句柄
  ffi.Pointer<ffi.Void> _hdcScreen = ffi.nullptr;
  ffi.Pointer<ffi.Void> _hdcMem = ffi.nullptr;
  ffi.Pointer<ffi.Void> _hbm = ffi.nullptr;
  ffi.Pointer<ffi.Void> _hbmOld = ffi.nullptr;

  // 复用缓冲：位图当前尺寸、DIB 缓冲、BITMAPINFOHEADER、RGBA 转换缓冲
  int _bmpW = 0;
  int _bmpH = 0;
  ffi.Pointer<ffi.Uint8> _dib = ffi.nullptr;
  int _dibBytes = 0;
  ffi.Pointer<ffi.Uint8> _bmi = ffi.nullptr;
  Uint8List _rgba = Uint8List(0);

  // JPEG 编码器复用（构造要建 Huffman 表，每帧新建很亏）
  img.JpegEncoder? _encoder;
  int _encoderQuality = -1;

  bool get isOpen => _open;

  /// 打不开 / 抓失败的原因，给诊断条用。
  String get lastError => _lastError;

  int get sourceWidth => _srcW;
  int get sourceHeight => _srcH;

  /// 人话描述，进诊断条。
  String describe() =>
      '${allMonitors ? '全部显示器' : '主显示器'} ${_srcW}x$_srcH';

  /// 打开屏幕 DC 与内存 DC，并把函数指针解析出来。
  ///
  /// 返回 false 时**必须**看 [lastError] —— 上层要把它写进诊断条，
  /// 不能静默回落到黑屏（这正是 v0.28.5 之前最难查的地方）。
  bool open() {
    if (_open) return true;
    if (!Platform.isWindows) {
      _lastError = '仅 Windows 支持自研采集';
      return false;
    }
    try {
      // 先把函数指针解析出来：dll 缺失 / 导出名写错会在这里当场抛，
      // 比调用到一半才崩好定位得多。
      _U32.getDC;
      _U32.releaseDC;
      _U32.getSystemMetrics;
      _G32.createCompatibleDC;
      _G32.createCompatibleBitmap;
      _G32.selectObject;
      _G32.deleteDC;
      _G32.deleteObject;
      _G32.setStretchBltMode;
      _G32.bitBlt;
      _G32.stretchBlt;
      _G32.getDIBits;
    } catch (e) {
      _lastError = 'Win32 接口解析失败：$e';
      return false;
    }

    if (allMonitors) {
      _srcX = _U32.getSystemMetrics(_SM_XVIRTUALSCREEN);
      _srcY = _U32.getSystemMetrics(_SM_YVIRTUALSCREEN);
      _srcW = _U32.getSystemMetrics(_SM_CXVIRTUALSCREEN);
      _srcH = _U32.getSystemMetrics(_SM_CYVIRTUALSCREEN);
    } else {
      // 主显示器原点恒为 (0,0)，这是 Win32 的约定。
      _srcX = 0;
      _srcY = 0;
      _srcW = _U32.getSystemMetrics(_SM_CXSCREEN);
      _srcH = _U32.getSystemMetrics(_SM_CYSCREEN);
    }
    if (_srcW <= 0 || _srcH <= 0) {
      _lastError = '屏幕尺寸无效（$_srcW x $_srcH）';
      return false;
    }

    _hdcScreen = _U32.getDC(ffi.nullptr);
    if (_hdcScreen == ffi.nullptr) {
      _lastError = 'GetDC 失败';
      return false;
    }
    _hdcMem = _G32.createCompatibleDC(_hdcScreen);
    if (_hdcMem == ffi.nullptr) {
      _lastError = 'CreateCompatibleDC 失败';
      _U32.releaseDC(ffi.nullptr, _hdcScreen);
      _hdcScreen = ffi.nullptr;
      return false;
    }
    // BITMAPINFO 的调色板区在 32bpp 下不使用，但结构体声明里留 4 字节余量，
    // 免得某些实现按最大长度读越界。
    _bmi = pkg_ffi.calloc<ffi.Uint8>(ffi.sizeOf<_BITMAPINFOHEADER>() + 4);
    _open = true;
    return true;
  }

  /// 位图尺寸变化时才重建（GDI 对象创建/销毁不便宜，跨帧复用它）。
  bool _ensureBitmap(int w, int h) {
    if (_hbm != ffi.nullptr && _bmpW == w && _bmpH == h) return true;
    if (_hbm != ffi.nullptr) {
      _G32.selectObject(_hdcMem, _hbmOld);
      _G32.deleteObject(_hbm);
      _hbm = ffi.nullptr;
    }
    _hbm = _G32.createCompatibleBitmap(_hdcScreen, w, h);
    if (_hbm == ffi.nullptr) {
      _lastError = 'CreateCompatibleBitmap($w x $h) 失败';
      return false;
    }
    _hbmOld = _G32.selectObject(_hdcMem, _hbm);
    _bmpW = w;
    _bmpH = h;
    return true;
  }

  /// 抓一帧并编码成 JPEG。
  ///
  /// [maxWidth] 目标最大宽度（按屏幕宽等比缩，不会放大）；[quality] JPEG 质量。
  /// 失败返回 null，原因见 [lastError]。
  GdiFrame? captureJpeg({int maxWidth = 1280, int quality = 65}) {
    if (!_open) return null;

    // 目标尺寸：只缩不放；并且取偶数 —— JPEG 的色度下采样按 2x2 走，
    // 奇数宽高会被编码器内部补齐，白多一层开销。
    var dw = _srcW;
    var dh = _srcH;
    if (maxWidth > 0 && _srcW > maxWidth) {
      dw = maxWidth;
      dh = (_srcH * maxWidth / _srcW).round();
    }
    if (dw < 2) dw = 2;
    if (dh < 2) dh = 2;
    dw &= ~1;
    dh &= ~1;

    if (!_ensureBitmap(dw, dh)) return null;

    final int ok;
    if (dw == _srcW && dh == _srcH) {
      ok = _G32.bitBlt(_hdcMem, 0, 0, dw, dh, _hdcScreen, _srcX, _srcY,
          _SRCCOPY);
    } else {
      _G32.setStretchBltMode(_hdcMem, _HALFTONE);
      ok = _G32.stretchBlt(_hdcMem, 0, 0, dw, dh, _hdcScreen, _srcX, _srcY,
          _srcW, _srcH, _SRCCOPY);
    }
    if (ok == 0) {
      _lastError = 'BitBlt/StretchBlt 失败（屏被独占/远程会话断开？）';
      return null;
    }

    final stride = dw * 4;
    final need = stride * dh;
    if (_dib == ffi.nullptr || _dibBytes < need) {
      if (_dib != ffi.nullptr) pkg_ffi.calloc.free(_dib);
      _dib = pkg_ffi.calloc<ffi.Uint8>(need);
      _dibBytes = need;
    }

    final hdr = _bmi.cast<_BITMAPINFOHEADER>();
    hdr.ref
      ..biSize = ffi.sizeOf<_BITMAPINFOHEADER>()
      ..biWidth = dw
      ..biHeight = -dh // 负数 = top-down，否则图会上下颠倒
      ..biPlanes = 1
      ..biBitCount = 32
      ..biCompression = _BI_RGB
      ..biSizeImage = need
      ..biXPelsPerMeter = 0
      ..biYPelsPerMeter = 0
      ..biClrUsed = 0
      ..biClrImportant = 0;

    // ⚠️ GetDIBits 的 hdc 必须是**内存 DC**（位图选进哪个 DC 就传哪个），
    //    传屏幕 DC 会返回 0 行且在屏上留下已选位图的句柄。
    final rows = _G32.getDIBits(
        _hdcMem, _hbm, 0, dh, _dib.cast<ffi.Void>(), _bmi.cast<ffi.Void>(),
        _DIB_RGB_COLORS);
    if (rows == 0 || rows != dh) {
      _lastError = 'GetDIBits 返回 $rows 行（期望 $dh）';
      return null;
    }

    // GDI 给的是 BGRA（内存序 B,G,R,A），image 包按 RGBA 吃，换一下。
    final src = _dib.asTypedList(need);
    if (_rgba.length != need) _rgba = Uint8List(need);
    final rgba = _rgba;
    for (var i = 0; i < need; i += 4) {
      rgba[i] = src[i + 2];
      rgba[i + 1] = src[i + 1];
      rgba[i + 2] = src[i];
      rgba[i + 3] = 255; // GDI 的 32bpp 缓冲第 4 字节是 0，不补全 A 会全透明
    }

    try {
      final im = img.Image.fromBytes(
        width: dw,
        height: dh,
        bytes: rgba.buffer,
        order: img.ChannelOrder.rgba,
      );
      if (_encoder == null || _encoderQuality != quality) {
        _encoder = img.JpegEncoder(quality: quality);
        _encoderQuality = quality;
      }
      // 4:2:0 色度下采样：人眼对亮度远比对色度敏感，桌面截图里色度信息
      // 大多是白底黑字，砍掉 3/4 的色度采样肉眼几乎看不出，编码时间和体积
      // 都明显下降。基线 JPEG 的标准模式，安卓/iOS 解码器全都支持。
      final jpeg = _encoder!.encode(im, chroma: img.JpegChroma.yuv420);
      return GdiFrame(width: dw, height: dh, jpeg: jpeg);
    } catch (e) {
      _lastError = 'JPEG 编码失败：$e';
      return null;
    }
  }

  /// 释放全部 GDI 资源与本地缓冲。可重复调用。
  void dispose() {
    if (_hbm != ffi.nullptr && _hdcMem != ffi.nullptr) {
      // 先摘掉位图再删 —— 位图还选在 DC 里时 DeleteObject 会失败。
      _G32.selectObject(_hdcMem, _hbmOld);
      _G32.deleteObject(_hbm);
    }
    _hbm = ffi.nullptr;
    _hbmOld = ffi.nullptr;
    if (_hdcMem != ffi.nullptr) {
      _G32.deleteDC(_hdcMem);
      _hdcMem = ffi.nullptr;
    }
    if (_hdcScreen != ffi.nullptr) {
      _U32.releaseDC(ffi.nullptr, _hdcScreen);
      _hdcScreen = ffi.nullptr;
    }
    if (_dib != ffi.nullptr) {
      pkg_ffi.calloc.free(_dib);
      _dib = ffi.nullptr;
      _dibBytes = 0;
    }
    if (_bmi != ffi.nullptr) {
      pkg_ffi.calloc.free(_bmi);
      _bmi = ffi.nullptr;
    }
    _encoder = null;
    _encoderQuality = -1;
    _rgba = Uint8List(0);
    _bmpW = 0;
    _bmpH = 0;
    _open = false;
  }
}
