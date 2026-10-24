// Windows 键鼠注入实现 —— **只用 dart:ffi，不依赖任何平台专属 Dart 包**。
//
// 【为什么不 import package:win32（重要，别改回去）】
// 原来这里 `import 'package:win32/win32.dart'`。问题：Dart 的 import 是
// **编译期**解析的，而 win32 这个包只在 Windows 平台有实现。
// 后果是**在 Mac 上编译 iOS 目标时直接报「找不到 win32」**，
// 哪怕这段代码在 iOS 上永远不会被执行 —— 编译不过就是编译不过。
//
// 试过条件导入（`import 'stub.dart' if (dart.library.io) 'win.dart'`）：
// **行不通**。Dart 团队明确表示 conditional import 无法区分
// mobile 与 desktop —— `dart.library.io` 在 Windows / iOS / macOS / Android
// 上**全部为真**（见 dart-lang/pub#2785 与 StackOverflow 相关讨论）。
// 也试过在 pubspec 里给 win32 加平台限定：pub 不支持按平台剔除依赖，
// win32 会一直留在依赖树里。
//
// 所以正解是：**绕开 win32 包，直接用 dart:ffi**。
//   · 自己声明 INPUT / MOUSEINPUT / KEYBDINPUT 结构体（纯 FFI 类型，全平台可编译）
//   · 运行期 `DynamicLibrary.open('user32.dll')` 取 SendInput
// iOS/macOS 上这个文件根本不会被编译（见 input_inject.dart 的选择逻辑），
// 而且它不再引用任何平台专属包，编译单元是干净的。
//
// 【结构体布局是 ABI 契约，不能凭感觉写】
// 下面三个结构体的字段/宽度/顺序抄自 win32 6.4.0 的 structs.g.dart
// （Windows 官方 SDK 定义）。⚠️ x64 上有对齐填充：
//   MOUSEINPUT  4+4+4+4+4+(4 填充)+8 = 32 字节
//   KEYBDINPUT  2+2+4+4+(4 填充)+8   = 24 字节
//   INPUT       4+(4 填充)+32        = 40 字节
// 用 @IntPtr() 而不是 @Int64() 是为了同时适配 32/64 位目标。
// 布局写错的表象是「SendInput 返回 0 但没报错，鼠标一动不动」—— 极难排查。
import 'dart:ffi' as ffi;
import 'dart:io' show Platform;

import 'package:ffi/ffi.dart' as ffi_pkg;

import 'input_inject.dart';

// Win32 常量与结构体**刻意沿用 Windows SDK 的命名**（全大写下划线），
// 便于对照 winuser.h / structs.g.dart 核对数值 —— 这类常量抄错的表象是
// "调用了但行为不对"（滚轮方向反了、绝对定位算错），
// 保留原名能让人一眼看出对应哪一条官方文档。因此豁免命名 lint（仅本文件）。
// ignore_for_file: constant_identifier_names, camel_case_types

// ------------------------------------------------------------ Win32 常量
// 抄自 Windows SDK（winuser.h）。名字与 SDK 一致（见文件头 ignore 说明）。
const int _INPUT_MOUSE = 0;
const int _INPUT_KEYBOARD = 1;

const int _MOUSEEVENTF_MOVE = 0x0001;
const int _MOUSEEVENTF_LEFTDOWN = 0x0002;
const int _MOUSEEVENTF_LEFTUP = 0x0004;
const int _MOUSEEVENTF_RIGHTDOWN = 0x0008;
const int _MOUSEEVENTF_RIGHTUP = 0x0010;
const int _MOUSEEVENTF_MIDDLEDOWN = 0x0020;
const int _MOUSEEVENTF_MIDDLEUP = 0x0040;
const int _MOUSEEVENTF_WHEEL = 0x0800;
const int _MOUSEEVENTF_ABSOLUTE = 0x8000;
const int _MOUSEEVENTF_VIRTUALDESK = 0x4000;

const int _KEYEVENTF_EXTENDEDKEY = 0x0001;
const int _KEYEVENTF_KEYUP = 0x0002;
const int _KEYEVENTF_UNICODE = 0x0004;

/// SW_RESTORE：ShowWindow 的命令，还原最小化/最大化的窗口并激活。
const int _SW_RESTORE = 9;

/// GetSystemMetrics 的索引：主显示器宽/高、虚拟桌面总尺寸。
/// 窗口模式换算坐标要用（窗口矩形是虚拟桌面坐标，归一化基准要看
/// usePrimaryOnlyCapture 选哪套）。
///
/// 注意这里**没有** SM_XVIRTUALSCREEN / SM_YVIRTUALSCREEN（虚拟桌面原点）：
/// VIRTUALDESK 归一化的 0..65535 就是按"从虚拟桌面左上角起算"摊开的，
/// 而 GetWindowRect 给的坐标同一坐标系，直接除总宽高即可，不需要再减原点
/// （曾经在整屏模式下先加原点再除总宽，副屏在左侧时算出负坐标 —— 见
/// absoluteMousePos 的注释，别再引入同一个 bug）。
const int _SM_CXSCREEN = 0;
const int _SM_CYSCREEN = 1;
const int _SM_CXVIRTUALSCREEN = 78;
const int _SM_CYVIRTUALSCREEN = 79;

/// 最小化窗口 GetWindowRect 的哨兵坐标（Windows 把最小化窗口藏到屏幕外）。
const int _MINIMIZED_SENTINEL = -32000;

/// RECT：窗口矩形（虚拟桌面物理坐标）。与 win_window_list.dart /
/// win_gdi_capture.dart 各有一份孪生声明 —— ABI 早已冻结，不共享是有意的
/// （三个文件各自独立可用，不互相牵导入）。
final class _RECT extends ffi.Struct {
  @ffi.Int32()
  external int left;

  @ffi.Int32()
  external int top;

  @ffi.Int32()
  external int right;

  @ffi.Int32()
  external int bottom;
}

// ------------------------------------------------------ 结构体（ABI 契约）
// ⚠️ 布局见文件头说明，改动前先核对 Windows SDK。

final class _MOUSEINPUT extends ffi.Struct {
  @ffi.Int32()
  external int dx;

  @ffi.Int32()
  external int dy;

  @ffi.Uint32()
  external int mouseData;

  @ffi.Uint32()
  external int dwFlags;

  @ffi.Uint32()
  external int time;

  @ffi.IntPtr()
  external int dwExtraInfo;
}

final class _KEYBDINPUT extends ffi.Struct {
  @ffi.Uint16()
  external int wVk;

  @ffi.Uint16()
  external int wScan;

  @ffi.Uint32()
  external int dwFlags;

  @ffi.Uint32()
  external int time;

  @ffi.IntPtr()
  external int dwExtraInfo;
}

/// INPUT 的匿名联合体。
///
/// 真实的 INPUT 是 `type + union { MOUSEINPUT, KEYBDINPUT, HARDWAREINPUT }`。
/// 我们只用前两个成员，所以这里按**较大的那个**（MOUSEINPUT，32 字节）
/// 来给联合体占位 —— 这是关键：联合体大小必须等于最大成员，
/// 少了后面字段会越界写。
///
/// 用 `ffi.Union` 声明（Dart 2.17+ 支持），字段通过 `mi` / `ki` 访问。
final class _INPUT_UNION extends ffi.Union {
  external _MOUSEINPUT mi;
  external _KEYBDINPUT ki;
}

final class _INPUT extends ffi.Struct {
  @ffi.Uint32()
  external int type;

  // ⚠️ x64 对齐：union 含 IntPtr（8 字节对齐），所以这里编译器会自动插入
  //    4 字节填充。Dart FFI 会自动处理，不需要手写 padding 字段。
  external _INPUT_UNION u;
}

// ------------------------------------------------------------ SendInput 绑定
typedef _SendInputNative = ffi.Uint32 Function(
    ffi.Uint32, ffi.Pointer<_INPUT>, ffi.Int32);
typedef _SendInputDart = int Function(int, ffi.Pointer<_INPUT>, int);

// ------------------------------------------------ 窗口模式绑定（激活+几何）
typedef _GetSystemMetricsNative = ffi.Int32 Function(ffi.Int32);
typedef _GetSystemMetricsDart = int Function(int);

typedef _IsWindowNative = ffi.Int32 Function(ffi.Pointer<ffi.Void>);
typedef _IsWindowDart = int Function(ffi.Pointer<ffi.Void>);

typedef _IsIconicNative = ffi.Int32 Function(ffi.Pointer<ffi.Void>);
typedef _IsIconicDart = int Function(ffi.Pointer<ffi.Void>);

typedef _GetWindowRectNative =
    ffi.Int32 Function(ffi.Pointer<ffi.Void>, ffi.Pointer<_RECT>);
typedef _GetWindowRectDart =
    int Function(ffi.Pointer<ffi.Void>, ffi.Pointer<_RECT>);

typedef _ShowWindowNative =
    ffi.Int32 Function(ffi.Pointer<ffi.Void>, ffi.Int32);
typedef _ShowWindowDart = int Function(ffi.Pointer<ffi.Void>, int);

typedef _GetForegroundWindowNative = ffi.Pointer<ffi.Void> Function();
typedef _GetForegroundWindowDart = ffi.Pointer<ffi.Void> Function();

typedef _GetWindowThreadProcessIdNative = ffi.Uint32 Function(
    ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Uint32>);
typedef _GetWindowThreadProcessIdDart = int Function(
    ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Uint32>);

typedef _AttachThreadInputNative = ffi.Int32 Function(
    ffi.Uint32, ffi.Uint32, ffi.Int32);
typedef _AttachThreadInputDart = int Function(int, int, int);

typedef _SetForegroundWindowNative = ffi.Int32 Function(ffi.Pointer<ffi.Void>);
typedef _SetForegroundWindowDart = int Function(ffi.Pointer<ffi.Void>);

/// 惰性打开的 user32 句柄 + 函数指针表。
///
/// ⚠️ **必须惰性**：非 Windows 平台没有 user32.dll，在顶层直接 open 会抛异常。
/// 只在真正要注入时才解析，而且只在 Windows 上才会走到。
///
/// 另外：本文件在 iOS/macOS 上不会被编译进产物（input_inject.dart 的选择
/// 逻辑不选它），所以这里的 open 在任何平台上都不会因为"平台不对"而炸。
class _User32 {
  static ffi.DynamicLibrary? _lib;
  static _SendInputDart? _sendInput;

  /// 惰性打开 user32.dll。**所有**函数指针都从这走，保证先开库再查符号
  /// （直接 `_lib!.lookup` 在 sendInput 没被访问过时会 NPE）。
  static ffi.DynamicLibrary get _dll => _lib ??= ffi.DynamicLibrary.open('user32.dll');

  static _SendInputDart get sendInput {
    if (_sendInput != null) return _sendInput!;
    _sendInput = _dll
        .lookupFunction<_SendInputNative, _SendInputDart>('SendInput');
    return _sendInput!;
  }

  static _GetSystemMetricsDart? _getSystemMetrics;
  static _GetSystemMetricsDart get getSystemMetrics => _getSystemMetrics ??=
      _dll.lookupFunction<_GetSystemMetricsNative,
          _GetSystemMetricsDart>('GetSystemMetrics');

  static _IsWindowDart? _isWindow;
  static _IsWindowDart get isWindow =>
      _isWindow ??= _dll
          .lookupFunction<_IsWindowNative, _IsWindowDart>('IsWindow');

  static _IsIconicDart? _isIconic;
  static _IsIconicDart get isIconic =>
      _isIconic ??= _dll
          .lookupFunction<_IsIconicNative, _IsIconicDart>('IsIconic');

  static _GetWindowRectDart? _getWindowRect;
  static _GetWindowRectDart get getWindowRect => _getWindowRect ??=
      _dll.lookupFunction<_GetWindowRectNative,
          _GetWindowRectDart>('GetWindowRect');

  static _ShowWindowDart? _showWindow;
  static _ShowWindowDart get showWindow =>
      _showWindow ??= _dll
          .lookupFunction<_ShowWindowNative, _ShowWindowDart>('ShowWindow');

  static _GetForegroundWindowDart? _getForegroundWindow;
  static _GetForegroundWindowDart get getForegroundWindow =>
      _getForegroundWindow ??= _dll.lookupFunction<
          _GetForegroundWindowNative,
          _GetForegroundWindowDart>('GetForegroundWindow');

  static _GetWindowThreadProcessIdDart? _getWindowThreadProcessId;
  static _GetWindowThreadProcessIdDart get getWindowThreadProcessId =>
      _getWindowThreadProcessId ??= _dll.lookupFunction<
          _GetWindowThreadProcessIdNative,
          _GetWindowThreadProcessIdDart>('GetWindowThreadProcessId');

  static _AttachThreadInputDart? _attachThreadInput;
  static _AttachThreadInputDart get attachThreadInput =>
      _attachThreadInput ??= _dll.lookupFunction<_AttachThreadInputNative,
          _AttachThreadInputDart>('AttachThreadInput');

  static _SetForegroundWindowDart? _setForegroundWindow;
  static _SetForegroundWindowDart get setForegroundWindow =>
      _setForegroundWindow ??= _dll.lookupFunction<_SetForegroundWindowNative,
          _SetForegroundWindowDart>('SetForegroundWindow');
}

/// 归一化坐标 → Win32 绝对鼠标坐标（0..65535）。
///
/// 抽成顶层纯函数是为了**能单测**：这里算错的表象是"鼠标点了但点偏一点点"，
/// 靠肉眼几乎不可能定位。之所以要特意强调：曾经这里先加虚拟屏原点、再除屏幕
/// 总宽，结果副屏摆在主屏左侧时审核不出问题、实测却算出负坐标。
///
/// ⚠️ NaN 的处理：`clamp` 对 NaN 返回 NaN，`round()` 会抛
/// `UnsupportedError`。测试里专门覆盖了这一点（见 remote_input_test.dart）。
({int x, int y}) absoluteMousePos(double nx, double ny) =>
    (x: (nx.clamp(0.0, 1.0) * 65535).round(), y: (ny.clamp(0.0, 1.0) * 65535).round());

/// Windows 注入实现：Win32 `SendInput`。
///
/// 【为什么不用已被标记废弃的 mouse_event / keybd_event】
/// 它们现在还能跑，但官方已明确建议迁移；更实际的是 SendInput 支持
/// "一次投递多条输入由系统按队列处理"，行为与真实输入一致，延迟也更低。
class WindowsInputInjector extends InputInjector {
  @override
  bool get supported => Platform.isWindows;

  @override
  String get controlObject => '鼠标键盘';

  @override
  String get hint => 'Windows 端可直接远程控制';

  /// 画面是否只含主显示器。见 [usePrimaryOnlyCapture] 的说明。
  ///
  /// ⚠️ 这个开关和"采集哪块屏"必须由同一个地方决定（现在是
  ///    RemoteAssistService._startFrameHost / _teardown 成对设置），
  ///    任何一边单独改都会变成"画面对、点不准"。
  bool _primaryOnly = false;

  @override
  void usePrimaryOnlyCapture(bool primaryOnly) {
    _primaryOnly = primaryOnly;
  }

  // ── 窗口模式（参考 TwinDesk「Apps 面板」）──────────────────────
  //
  // 控制端选中的是"窗口内归一化坐标"（画面里那个窗口占满视图），
  // 而被控端要的是"桌面绝对像素"。所以这里做两步换算：
  //   ① 窗口归一化 → 窗口矩形内的绝对像素（left + nx*width）
  //   ② 绝对像素   → 归一化基准（主屏 or 虚拟桌面，同 usePrimaryOnlyCapture）
  // 键盘另外要保证目标窗口在前台（键盘只去前台窗口），见 _key。

  /// 目标窗口句柄地址值；0 = 不在窗口模式。
  int _winHwnd = 0;

  /// 目标窗口矩形（虚拟桌面物理坐标）。每次用之前现刷 —— 窗口可能被
  /// 本地用户拖动/缩放，缓存必然过期。
  int _winLeft = 0;
  int _winTop = 0;
  int _winW = 0;
  int _winH = 0;

  @override
  void setWindowTarget(int hwnd) {
    if (!Platform.isWindows || hwnd == 0) return;
    _winHwnd = hwnd;
    _winLeft = _winTop = _winW = _winH = 0;
    // 选中即激活：窗口可能最小化或在后台，不还原的话连画面都没有
    // （最小化时 GetWindowRect 给的是 (-32000,-32000) 哨兵坐标）。
    _activateWindow();
    _refreshWindowRect();
  }

  @override
  void clearWindowTarget() {
    _winHwnd = 0;
    _winLeft = _winTop = _winW = _winH = 0;
  }

  @override
  int get windowTargetHwnd => _winHwnd;

  @override
  ({int left, int top, int width, int height})? get windowTargetRect =>
      (_winHwnd != 0 && _winW > 0 && _winH > 0)
          ? (left: _winLeft, top: _winTop, width: _winW, height: _winH)
          : null;

  /// 把目标窗口带到前台：最小化先还原，再用 AttachThreadInput 绕过
  /// SetForegroundWindow 的前台限制（本进程不是前台进程时直接调会失败）。
  void _activateWindow() {
    if (_winHwnd == 0) return;
    final hwnd = ffi.Pointer<ffi.Void>.fromAddress(_winHwnd);
    if (_User32.isWindow(hwnd) == 0) return;
    if (_User32.isIconic(hwnd) != 0) {
      _User32.showWindow(hwnd, _SW_RESTORE);
    }
    final fg = _User32.getForegroundWindow();
    if (fg == hwnd) return; // 已经在前台，不用抢
    final targetThread = _User32.getWindowThreadProcessId(hwnd, ffi.nullptr);
    final fgThread =
        fg == ffi.nullptr ? 0 : _User32.getWindowThreadProcessId(fg, ffi.nullptr);
    if (targetThread != 0 && fgThread != 0 && targetThread != fgThread) {
      // 临时把两个线程的输入队列"绑"在一起，本进程就获得了设置前台的资格；
      // 用完立刻解绑。这是绕过前台锁的标准做法。
      _User32.attachThreadInput(targetThread, fgThread, 1);
      _User32.setForegroundWindow(hwnd);
      _User32.attachThreadInput(targetThread, fgThread, 0);
    } else {
      _User32.setForegroundWindow(hwnd);
    }
  }

  /// 现算目标窗口矩形。最小化（哨兵坐标）时保留旧值不清零 ——
  /// 那种情况下本来也没有像素可点，由调用方判 _winW/_winH。
  void _refreshWindowRect() {
    if (_winHwnd == 0) return;
    final rect = ffi_pkg.calloc<_RECT>();
    try {
      if (_User32.getWindowRect(
              ffi.Pointer<ffi.Void>.fromAddress(_winHwnd), rect) !=
          0) {
        final r = rect.ref;
        if (r.left > _MINIMIZED_SENTINEL) {
          _winLeft = r.left;
          _winTop = r.top;
          _winW = r.right - r.left;
          _winH = r.bottom - r.top;
          if (_winW < 0) _winW = 0;
          if (_winH < 0) _winH = 0;
        }
      }
    } finally {
      ffi_pkg.calloc.free(rect);
    }
  }

  /// 窗口模式下、发送坐标类输入前的准备：窗口没了/最小化了就还原，
  /// 矩形刷新到最新。返回 false 表示这一跳输入只能丢弃（没有可点的窗口）。
  bool _ensureWindowReady() {
    if (_winHwnd == 0) return true; // 非窗口模式，无需准备
    final hwnd = ffi.Pointer<ffi.Void>.fromAddress(_winHwnd);
    if (_User32.isWindow(hwnd) == 0) return false;
    if (_User32.isIconic(hwnd) != 0) _activateWindow();
    _refreshWindowRect();
    return _winW > 0 && _winH > 0;
  }

  @override
  void moveAbsolute(double nx, double ny) {
    if (_winHwnd != 0) {
      // 窗口模式：先保证窗口可用且矩形最新，再把"窗口内归一化"换算成
      // 桌面绝对像素，最后换算成归一化基准（与整屏模式同一套标志位）。
      if (!_ensureWindowReady()) return;
      final cx = nx.clamp(0.0, 1.0);
      final cy = ny.clamp(0.0, 1.0);
      final absX = _winLeft + cx * _winW;
      final absY = _winTop + cy * _winH;
      double fnx;
      double fny;
      if (_primaryOnly) {
        final cw = _User32.getSystemMetrics(_SM_CXSCREEN);
        final ch = _User32.getSystemMetrics(_SM_CYSCREEN);
        if (cw <= 0 || ch <= 0) return;
        fnx = absX / cw;
        fny = absY / ch;
      } else {
        // VIRTUALDESK 归一化的原点就是虚拟桌面左上角，而 GetWindowRect
        // 给的也是同一坐标系，直接除总宽高即可（不需要再减原点）。
        final vw = _User32.getSystemMetrics(_SM_CXVIRTUALSCREEN);
        final vh = _User32.getSystemMetrics(_SM_CYVIRTUALSCREEN);
        if (vw <= 0 || vh <= 0) return;
        fnx = absX / vw;
        fny = absY / vh;
      }
      final p = absoluteMousePos(fnx, fny);
      final flags = _MOUSEEVENTF_MOVE |
          _MOUSEEVENTF_ABSOLUTE |
          (_primaryOnly ? 0 : _MOUSEEVENTF_VIRTUALDESK);
      _mouse(flags, p.x, p.y, 0);
      return;
    }

    final p = absoluteMousePos(nx, ny);
    // MOUSEEVENTF_ABSOLUTE 的归一化基准由 VIRTUALDESK 决定：
    //   带 VIRTUALDESK → 0..65535 摊在整个虚拟桌面（多屏拼起来）上；
    //   不带          → 摊在**主显示器**上。
    // 自研画面通道只抓主屏，所以那时必须去掉这个标志；沿用原来的
    // WebRTC 屏幕采集（抓的是整块屏）时保持带标志。
    final flags = _MOUSEEVENTF_MOVE |
        _MOUSEEVENTF_ABSOLUTE |
        (_primaryOnly ? 0 : _MOUSEEVENTF_VIRTUALDESK);
    _mouse(flags, p.x, p.y, 0);
  }

  @override
  void mouseButton(RemoteMouseButton button, bool down) {
    final int flag;
    switch (button) {
      case RemoteMouseButton.left:
        flag = down ? _MOUSEEVENTF_LEFTDOWN : _MOUSEEVENTF_LEFTUP;
      case RemoteMouseButton.middle:
        flag = down ? _MOUSEEVENTF_MIDDLEDOWN : _MOUSEEVENTF_MIDDLEUP;
      case RemoteMouseButton.right:
        flag = down ? _MOUSEEVENTF_RIGHTDOWN : _MOUSEEVENTF_RIGHTUP;
    }
    _mouse(flag, 0, 0, 0);
  }

  @override
  void scroll(int delta) => _mouse(_MOUSEEVENTF_WHEEL, 0, 0, delta);

  @override
  void keyDown(RemoteKey key) => _key(key, up: false);

  @override
  void keyUp(RemoteKey key) => _key(key, up: true);
  /// 投递一条鼠标输入。
  void _mouse(int flags, int dx, int dy, int data) {
    final p = ffi_pkg.calloc<_INPUT>();
    try {
      p.ref.type = _INPUT_MOUSE;
      p.ref.u.mi.dx = dx;
      p.ref.u.mi.dy = dy;
      p.ref.u.mi.mouseData = data;
      p.ref.u.mi.dwFlags = flags;
      p.ref.u.mi.time = 0;
      p.ref.u.mi.dwExtraInfo = 0;
      _User32.sendInput(1, p, ffi.sizeOf<_INPUT>());
    } finally {
      ffi_pkg.calloc.free(p);
    }
  }

  /// 投递键盘输入。
  ///
  /// 【两条路径，别合并】
  /// ① 有 `char` → **Unicode 注入**，且**按 UTF-16 码元逐个发**：
  ///    一个"字符"可能是代理对（emoji、部分生僻字）占两个码元，
  ///    整串塞进 wScan 是错的（wScan 是 16 位，只放得下一个码元）。
  ///    逐码元发还能不受被控端当前输入法/键盘布局影响 —— 中文 Windows 上
  ///    也不会按错键。
  /// ② 没有 `char` → 用虚拟键码发（方向键、Ctrl+C 这类本来就不是字符的）。
  ///
  /// ⚠️ `vk == null` 且 `char == null` 时**必须直接返回**，不能带着 0 往下走 ——
  ///    那会注入一个"无意义的键"。
  ///
  /// 窗口模式下还要先保证目标窗口是前台：**键盘输入只去前台窗口**，
  /// 本地用户中途点了别的窗口，我们的按键就打到别人身上去了。
  void _key(RemoteKey k, {required bool up}) {
    if (_winHwnd != 0) {
      final hwnd = ffi.Pointer<ffi.Void>.fromAddress(_winHwnd);
      if (_User32.isWindow(hwnd) != 0 &&
          _User32.getForegroundWindow() != hwnd) {
        _activateWindow();
      }
    }
    final p = ffi_pkg.calloc<_INPUT>();
    try {
      p.ref.type = _INPUT_KEYBOARD;
      final upFlag = up ? _KEYEVENTF_KEYUP : 0;

      if (k.char != null && k.char!.isNotEmpty) {
        for (final unit in k.char!.codeUnits) {
          p.ref.u.ki.wVk = 0;           // Unicode 模式下 wVk 必须为 0
          p.ref.u.ki.wScan = unit;
          p.ref.u.ki.dwFlags = _KEYEVENTF_UNICODE | upFlag;
          p.ref.u.ki.time = 0;
          p.ref.u.ki.dwExtraInfo = 0;
          _User32.sendInput(1, p, ffi.sizeOf<_INPUT>());
        }
        return;
      }

      final vk = k.vk;
      if (vk == null) return;
      var flags = upFlag;
      if (k.extended) flags |= _KEYEVENTF_EXTENDEDKEY;
      p.ref.u.ki.wVk = vk;
      p.ref.u.ki.wScan = 0;
      p.ref.u.ki.dwFlags = flags;
      p.ref.u.ki.time = 0;
      p.ref.u.ki.dwExtraInfo = 0;
      _User32.sendInput(1, p, ffi.sizeOf<_INPUT>());
    } finally {
      ffi_pkg.calloc.free(p);
    }
  }
}

/// 常用的 Windows 虚拟键码。
///
/// 只列远程协助真正用得到的 —— 键盘上一百多个键全抄一遍既没意义又容易抄错。
class Vk {
  static const int backspace = 0x08;
  static const int tab = 0x09;
  static const int enter = 0x0D;
  static const int shift = 0x10;
  static const int control = 0x11;
  static const int alt = 0x12;
  static const int escape = 0x1B;
  static const int space = 0x20;
  static const int pageUp = 0x21;
  static const int pageDown = 0x22;
  static const int end = 0x23;
  static const int home = 0x24;
  static const int left = 0x25;
  static const int up = 0x26;
  static const int right = 0x27;
  static const int down = 0x28;
  static const int insert = 0x2D;
  static const int delete = 0x2E;
  static const int meta = 0x5B;      // 左 Win
  static const int f1 = 0x70;        // F1..F12 = f1 + (n-1)
  static const int f12 = 0x7B;
}
