// Windows 顶层窗口枚举 —— 远程协助「窗口模式」（被控端 Windows 专用）。
//
// ─────────────────────────────────────────────────────────────
// 【这是什么、给谁用】
// ─────────────────────────────────────────────────────────────
// 参考 TwinDesk 的「Apps 面板」：控制端能列出被控电脑上**正在运行的窗口**
// （标题 + 所属进程 + 尺寸），选中哪一个就只投射那一个窗口，而不是整个屏幕。
// 本文件只负责「列窗口」，不负责采集（见 win_gdi_capture.dart 的 setWindow）
// 也不负责注入（见 input_inject_win.dart 的 setWindowTarget）。
//
// 三个使用方：
//   ① 被控端 host：响应控制端的 wl 请求，枚举后经 wn 消息回传 JSON；
//   ② 看门狗：窗口被关掉后 IsWindow 会返回假，用它判存活；
//   ③ 诊断条：列不出来的原因要能说出来，不能静默空列表。
//
// ─────────────────────────────────────────────────────────────
// 【为什么不用 package:win32 / window_manager】
// ─────────────────────────────────────────────────────────────
// 同 win_gdi_capture.dart / input_inject_win.dart 的理由：Dart 的 import 是
// **编译期**解析的，平台专属包会让 iOS/macOS 目标直接编译失败
// （条件导入区分不了 mobile 与 desktop）。所以这里同样只用 dart:ffi 自己声明。
//
// ─────────────────────────────────────────────────────────────
// 【枚举规则：列哪些窗口】
// ─────────────────────────────────────────────────────────────
// EnumWindows 给出的是**全部顶层窗口**，其中一大半是不能往控制端送的：
//   · IsWindowVisible == 0          → 隐藏窗口（托盘气泡、后台宿主）
//   · 标题为空                       → 无标题的工作台窗口，选了也没意义
//   · WS_EX_TOOLWINDOW(0x80)        → 工具窗（浮动工具栏、输入法候选）
//   · GW_OWNER != NULL              → 被别的顶层窗口拥有的窗口（模态对话框、
//                                      下拉弹出），它们会盖在主窗口上面，
//                                      单独投射会出现"选了个爹"的混乱
// 过滤后剩下的就是龙哥眼里"电脑上开着的那些程序"。
//
// 最小化窗口**保留**在列表里（带 min 标志）：选它之后第一次输入会先还原
// （见 input_inject_win 的 activateWindow），比直接不列更符合直觉。
// 最小化时 GetWindowRect 返回 (-32000,-32000) 的哨兵值，所以最小化窗口的
// 几何信息一律置零——把垃圾坐标传出去只会让控制端显示一个奇怪的负尺寸。
//
// ─────────────────────────────────────────────────────────────
// 【句柄怎么跨网络传输】
// ─────────────────────────────────────────────────────────────
// HWND 在本进程里是指针，直接塞不进 JSON。协议里传的是它的**地址值**（int），
// 对端拿到的只是一个数字；真正要用时由本进程用
// Pointer<Void>.fromAddress(hwnd) 还原（句柄表按地址值索引）。
// 所以 WinWindowInfo 同时带 int hwnd（协议用）和 Pointer hwndPtr（本进程用）。
import 'dart:ffi' as ffi;
import 'dart:io' show Platform;

import 'package:ffi/ffi.dart' as ffi_pkg;

// Win32 常量/类型刻意沿用 Windows SDK 命名，便于对照官方文档核对数值。
// ignore_for_file: constant_identifier_names, camel_case_types

// ------------------------------------------------------------ Win32 常量
// 抄自 Windows SDK（winuser.h）。

/// GWL_EXSTYLE：GetWindowLongPtr 的索引，取扩展窗口样式。
const int _GWL_EXSTYLE = -20;

/// WS_EX_TOOLWINDOW：工具窗样式位，置位的窗口不进列表。
const int _WS_EX_TOOLWINDOW = 0x00000080;

/// GW_OWNER：GetWindow 的常量，取拥有者窗口。
const int _GW_OWNER = 4;

/// PROCESS_QUERY_LIMITED_INFORMATION：OpenProcess 的访问掩码。
/// 用"受限"版而不是 PROCESS_QUERY_INFORMATION：权限更小，对同完整性级别
/// 的进程足够读全路径，对高完整性进程顶多读不到（返回空串），不会弹 UAC。
const int _PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;

/// QueryFullProcessImageNameW 缓冲长度（宽字符数）。MAX_PATH=260 是旧 API 的
/// 约定，长路径能到 32767，这里按 1024 取，够用且不心疼内存。
const int _PATH_BUF_CHARS = 1024;

// ------------------------------------------------------ 结构体（ABI 契约）
// 抄自 Windows SDK（windef.h / rect.h）。x64 上四个 Int32 紧凑排列无填充。

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

// ------------------------------------------------------------ FFI 函数签名
// 指针参数统一声明成 Pointer<Void>：只把句柄原样传回去，Dart 侧不需要理解
// 它的类型，少一层转换就少一处能写错的地方。
//
// ⚠️ 回调函数指针的老式写法（本机类型检查用的 analyzer 10.x 只认这套）：
//      typedef _ProcFn = Int32 Function(Pointer<Void>, Pointer<Void>);   // Dart 签名
//      Pointer.fromFunction<_ProcFn>(fn)                                  // → Pointer<NativeFunction<_ProcFn>>
//      typedef _Native = Int32 Function(Pointer<NativeFunction<_ProcFn>>, ...);
//    新版 SDK 的"统一函数指针"（直接 typedef 成 Function 当 native 类型用）
//    在这里不认，别改回去。

/// EnumWindows 回调的 Dart 侧签名：返回 TRUE(1) 继续枚举 / FALSE(0) 停止。
typedef _EnumWindowsProcFn =
    ffi.Int32 Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Void>);

typedef _EnumWindowsNative = ffi.Int32 Function(
    ffi.Pointer<ffi.NativeFunction<_EnumWindowsProcFn>>, ffi.Pointer<ffi.Void>);
typedef _EnumWindowsDart = int Function(
    ffi.Pointer<ffi.NativeFunction<_EnumWindowsProcFn>>, ffi.Pointer<ffi.Void>);

typedef _IsWindowVisibleNative = ffi.Int32 Function(ffi.Pointer<ffi.Void>);
typedef _IsWindowVisibleDart = int Function(ffi.Pointer<ffi.Void>);

typedef _IsIconicNative = ffi.Int32 Function(ffi.Pointer<ffi.Void>);
typedef _IsIconicDart = int Function(ffi.Pointer<ffi.Void>);

typedef _IsWindowNative = ffi.Int32 Function(ffi.Pointer<ffi.Void>);
typedef _IsWindowDart = int Function(ffi.Pointer<ffi.Void>);

typedef _GetWindowTextLengthWNative = ffi.Int32 Function(ffi.Pointer<ffi.Void>);
typedef _GetWindowTextLengthWDart = int Function(ffi.Pointer<ffi.Void>);

typedef _GetWindowTextWNative = ffi.Int32 Function(
    ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Uint16>, ffi.Int32);
typedef _GetWindowTextWDart = int Function(
    ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Uint16>, int);

typedef _GetWindowRectNative =
    ffi.Int32 Function(ffi.Pointer<ffi.Void>, ffi.Pointer<_RECT>);
typedef _GetWindowRectDart =
    int Function(ffi.Pointer<ffi.Void>, ffi.Pointer<_RECT>);

typedef _GetWindowLongPtrWNative =
    ffi.IntPtr Function(ffi.Pointer<ffi.Void>, ffi.Int32);
typedef _GetWindowLongPtrWDart =
    int Function(ffi.Pointer<ffi.Void>, int);

typedef _GetWindowNative =
    ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Void>, ffi.Uint32);
typedef _GetWindowDart =
    ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Void>, int);

typedef _GetWindowThreadProcessIdNative = ffi.Uint32 Function(
    ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Uint32>);
typedef _GetWindowThreadProcessIdDart = int Function(
    ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Uint32>);

typedef _OpenProcessNative = ffi.Pointer<ffi.Void> Function(
    ffi.Uint32, ffi.Int32, ffi.Uint32);
typedef _OpenProcessDart =
    ffi.Pointer<ffi.Void> Function(int, int, int);

typedef _QueryFullProcessImageNameWNative = ffi.Int32 Function(
    ffi.Pointer<ffi.Void>, ffi.Uint32, ffi.Pointer<ffi.Uint16>,
    ffi.Pointer<ffi.Uint32>);
typedef _QueryFullProcessImageNameWDart = int Function(
    ffi.Pointer<ffi.Void>, int, ffi.Pointer<ffi.Uint16>,
    ffi.Pointer<ffi.Uint32>);

typedef _CloseHandleNative = ffi.Int32 Function(ffi.Pointer<ffi.Void>);
typedef _CloseHandleDart = int Function(ffi.Pointer<ffi.Void>);

/// user32.dll 绑定（窗口枚举全部走这里）。
///
/// ⚠️ **必须惰性**：非 Windows 平台没有 user32.dll，顶层直接 open 会抛异常。
class _U32 {
  static ffi.DynamicLibrary? _lib;

  static ffi.DynamicLibrary get _dll =>
      _lib ??= ffi.DynamicLibrary.open('user32.dll');

  static _EnumWindowsDart? _enumWindows;
  static _EnumWindowsDart get enumWindows =>
      _enumWindows ??= _dll.lookupFunction<_EnumWindowsNative,
          _EnumWindowsDart>('EnumWindows');

  static _IsWindowVisibleDart? _isWindowVisible;
  static _IsWindowVisibleDart get isWindowVisible => _isWindowVisible ??=
      _dll.lookupFunction<_IsWindowVisibleNative,
          _IsWindowVisibleDart>('IsWindowVisible');

  static _IsIconicDart? _isIconic;
  static _IsIconicDart get isIconic =>
      _isIconic ??= _dll.lookupFunction<_IsIconicNative,
          _IsIconicDart>('IsIconic');

  static _IsWindowDart? _isWindow;
  static _IsWindowDart get isWindow =>
      _isWindow ??= _dll.lookupFunction<_IsWindowNative,
          _IsWindowDart>('IsWindow');

  static _GetWindowTextLengthWDart? _getWindowTextLengthW;
  static _GetWindowTextLengthWDart get getWindowTextLengthW =>
      _getWindowTextLengthW ??= _dll.lookupFunction<
          _GetWindowTextLengthWNative,
          _GetWindowTextLengthWDart>('GetWindowTextLengthW');

  static _GetWindowTextWDart? _getWindowTextW;
  static _GetWindowTextWDart get getWindowTextW => _getWindowTextW ??=
      _dll.lookupFunction<_GetWindowTextWNative,
          _GetWindowTextWDart>('GetWindowTextW');

  static _GetWindowRectDart? _getWindowRect;
  static _GetWindowRectDart get getWindowRect => _getWindowRect ??=
      _dll.lookupFunction<_GetWindowRectNative,
          _GetWindowRectDart>('GetWindowRect');

  static _GetWindowLongPtrWDart? _getWindowLongPtrW;
  static _GetWindowLongPtrWDart get getWindowLongPtrW => _getWindowLongPtrW ??=
      _dll.lookupFunction<_GetWindowLongPtrWNative,
          _GetWindowLongPtrWDart>('GetWindowLongPtrW');

  static _GetWindowDart? _getWindow;
  static _GetWindowDart get getWindow =>
      _getWindow ??= _dll.lookupFunction<_GetWindowNative,
          _GetWindowDart>('GetWindow');

  static _GetWindowThreadProcessIdDart? _getWindowThreadProcessId;
  static _GetWindowThreadProcessIdDart get getWindowThreadProcessId =>
      _getWindowThreadProcessId ??= _dll.lookupFunction<
          _GetWindowThreadProcessIdNative,
          _GetWindowThreadProcessIdDart>('GetWindowThreadProcessId');
}

/// kernel32.dll 绑定（只用来查进程名）。
class _K32 {
  static ffi.DynamicLibrary? _lib;

  static ffi.DynamicLibrary get _dll =>
      _lib ??= ffi.DynamicLibrary.open('kernel32.dll');

  static _OpenProcessDart? _openProcess;
  static _OpenProcessDart get openProcess =>
      _openProcess ??= _dll.lookupFunction<_OpenProcessNative,
          _OpenProcessDart>('OpenProcess');

  static _QueryFullProcessImageNameWDart? _queryFullProcessImageNameW;
  static _QueryFullProcessImageNameWDart get queryFullProcessImageNameW =>
      _queryFullProcessImageNameW ??= _dll.lookupFunction<
          _QueryFullProcessImageNameWNative,
          _QueryFullProcessImageNameWDart>('QueryFullProcessImageNameW');

  static _CloseHandleDart? _closeHandle;
  static _CloseHandleDart get closeHandle =>
      _closeHandle ??= _dll.lookupFunction<_CloseHandleNative,
          _CloseHandleDart>('CloseHandle');
}

// ---------------------------------------------------------------- 数据模型

/// 一个可投射的顶层窗口。
class WinWindowInfo {
  const WinWindowInfo({
    required this.hwnd,
    required this.hwndPtr,
    required this.title,
    required this.process,
    required this.left,
    required this.top,
    required this.width,
    required this.height,
    required this.minimized,
  });

  /// 窗口句柄的**地址值**。协议里传的就是它；需要句柄时对端/本进程都用
  /// `Pointer<Void>.fromAddress(hwnd)` 还原。
  final int hwnd;

  /// 本进程内的句柄指针。仅在枚举它的那个 isolate 里有效，
  /// **不要**把它本身塞进 JSON（跨进程/跨设备无意义）。
  final ffi.Pointer<ffi.Void> hwndPtr;

  /// 窗口标题（可能很长，UI 侧自行截断）。
  final String title;

  /// 所属进程的可执行文件名（不含路径）。高完整性进程读不到时为空串，
  /// UI 显示「未知进程」即可，不影响使用。
  final String process;

  /// 窗口矩形（屏幕物理坐标，与 GDI 采集坐标系一致）。
  /// 最小化时恒为 0（见文件头：最小化时 GetWindowRect 给的是哨兵值）。
  final int left;
  final int top;
  final int width;
  final int height;

  /// 是否处于最小化。选它之后的第一次输入会先还原窗口。
  final bool minimized;

  int get right => left + width;
  int get bottom => top + height;

  /// 序列化成控制通道协议（wn 消息体用）。
  /// 键名压短：窗口列表经 P2P DataChannel 走，能省一个字节是一个。
  Map<String, Object?> toJson() => <String, Object?>{
        'hwnd': hwnd,
        'title': title,
        'process': process,
        'left': left,
        'top': top,
        'width': width,
        'height': height,
        'min': minimized,
      };

  /// 人话描述，进诊断条/日志。
  String describe() => minimized
      ? '$title [${process.isEmpty ? '未知进程' : process}]（已最小化）'
      : '$title [${process.isEmpty ? '未知进程' : process}] ${width}x$height';
}

// ---------------------------------------------------------------- 枚举实现
// EnumWindows 的回调没法直接传 Dart 对象（lParam 只能过指针），所以用库级
// 私有变量当收集桶。EnumWindows 是**同步**调用（回调在同一线程里跑完才返回），
// 不存在交叉写；不同 isolate 各有自己的副本，天然隔离。

/// 枚举回调的收集桶（库私有）。
final List<WinWindowInfo> _enumSink = <WinWindowInfo>[];

/// 最近一次枚举失败的原因（空 = 正常）。给诊断条用。
String _enumLastError = '';

/// EnumWindows 回调。
///
/// ⚠️ 必须是顶层/静态函数：Pointer.fromFunction 不接受闭包。
/// ⚠️ 回调里**绝不能抛异常**：异常会直接穿透到 native 栈，行为未定义。
///    所以逐个窗口的读取全部 try 住，失败的窗口跳过即可。
int _enumWindowsProc(ffi.Pointer<ffi.Void> hwnd, ffi.Pointer<ffi.Void> lParam) {
  try {
    final info = _readWindow(hwnd.address);
    if (info != null) _enumSink.add(info);
  } catch (_) {
    // 跳过这个窗口。宁可少列一个，也不能让 native 栈看到 Dart 异常。
  }
  return 1; // TRUE：继续枚举
}

/// 回调指针。**必须强引用持有**：Pointer.fromFunction 的产物被 GC 回收后
/// 再被 native 调用就是野函数指针。放库级 final 变量里，整个进程生命周期保活。
///
/// 第二参 0（FALSE）是 exceptionalReturn：Dart 回调万一抛了异常，native 侧
/// 收到 FALSE 会**停止枚举**——半份列表也好过带着未定义行为继续跑。
final ffi.Pointer<ffi.NativeFunction<_EnumWindowsProcFn>> _enumCallback =
    ffi.Pointer.fromFunction<_EnumWindowsProcFn>(_enumWindowsProc, 0);

/// 枚举当前可投射的顶层窗口。
///
/// 非 Windows 平台返回空列表（调用方无需再判平台，但 UI 入口仍应按平台隐藏）。
/// 枚举失败时返回已收集到的部分 + [_enumLastError] 说明，绝不静默空列表——
/// 静默空列表正是 v0.28.5 采集黑屏最难查的那类问题。
List<WinWindowInfo> enumerateWindows() {
  _enumLastError = '';
  if (!Platform.isWindows) return const [];
  _enumSink.clear();
  try {
    // 先把函数指针全部解析出来：dll 缺失 / 导出名写错在这里当场抛，
    // 比枚举到一半才崩好定位得多（与 win_gdi_capture.open() 同一策略）。
    _U32.enumWindows;
    _U32.isWindowVisible;
    _U32.isIconic;
    _U32.isWindow;
    _U32.getWindowTextLengthW;
    _U32.getWindowTextW;
    _U32.getWindowRect;
    _U32.getWindowLongPtrW;
    _U32.getWindow;
    _U32.getWindowThreadProcessId;
    _K32.openProcess;
    _K32.queryFullProcessImageNameW;
    _K32.closeHandle;

    _U32.enumWindows(_enumCallback, ffi.nullptr);
  } catch (e) {
    _enumLastError = '窗口枚举失败：$e';
  }
  return List<WinWindowInfo>.unmodifiable(_enumSink);
}

/// 最近一次 [enumerateWindows] 的失败原因；空字符串表示正常。
String lastWindowEnumError() => _enumLastError;

/// 窗口是否还活着（看门狗用：用户在被控端把窗口关了，要及时通知控制端）。
///
/// [hwnd] 是 [WinWindowInfo.hwnd] 那种地址值。句柄被销毁后 IsWindow 返回假。
bool isWindowAlive(int hwnd) {
  if (!Platform.isWindows || hwnd == 0) return false;
  try {
    return _U32.isWindow(ffi.Pointer<ffi.Void>.fromAddress(hwnd)) != 0;
  } catch (_) {
    return false;
  }
}

// ---------------------------------------------------------------- 内部 helpers

/// 读一个窗口，按文件头规则过滤；不该进列表时返回 null。
WinWindowInfo? _readWindow(int hwndAddr) {
  final hwnd = ffi.Pointer<ffi.Void>.fromAddress(hwndAddr);

  // ① 可见性
  if (_U32.isWindowVisible(hwnd) == 0) return null;

  // ② 标题非空（GetWindowTextLengthW 不含结尾 \0）
  final textLen = _U32.getWindowTextLengthW(hwnd);
  if (textLen <= 0) return null;
  final title = _readWindowText(hwnd, textLen);
  if (title.isEmpty) return null; // 防御：个别窗口 length>0 但取回空

  // ③ 排除工具窗
  final exStyle = _U32.getWindowLongPtrW(hwnd, _GWL_EXSTYLE);
  if (exStyle != 0 && (exStyle & _WS_EX_TOOLWINDOW) != 0) return null;

  // ④ 排除被拥有的窗口（模态框/弹出菜单）
  if (_U32.getWindow(hwnd, _GW_OWNER) != ffi.nullptr) return null;

  // 几何 + 最小化
  final rect = ffi_pkg.calloc<_RECT>();
  var left = 0;
  var top = 0;
  var width = 0;
  var height = 0;
  var minimized = false;
  try {
    if (_U32.getWindowRect(hwnd, rect) != 0) {
      minimized = _U32.isIconic(hwnd) != 0;
      if (!minimized) {
        // 最小化时 GetWindowRect 给 (-32000,-32000) 的垃圾坐标，
        // 直接当"无几何信息"处理（见文件头说明）。
        left = rect.ref.left;
        top = rect.ref.top;
        width = rect.ref.right - rect.ref.left;
        height = rect.ref.bottom - rect.ref.top;
        if (width < 0) width = 0;
        if (height < 0) height = 0;
      }
    }
  } finally {
    ffi_pkg.calloc.free(rect);
  }

  final pid = _queryPid(hwnd);
  final process = _queryProcessName(pid);

  return WinWindowInfo(
    hwnd: hwndAddr,
    hwndPtr: hwnd,
    title: title,
    process: process,
    left: left,
    top: top,
    width: width,
    height: height,
    minimized: minimized,
  );
}

/// 取窗口标题（UTF-16 → Dart String）。
String _readWindowText(ffi.Pointer<ffi.Void> hwnd, int textLen) {
  // +1 给结尾 \0。GetWindowTextW 的 nMaxCount 含 \0。
  final buf = ffi_pkg.calloc<ffi.Uint16>(textLen + 1);
  try {
    final n = _U32.getWindowTextW(hwnd, buf, textLen + 1);
    if (n <= 0) return '';
    return String.fromCharCodes(<int>[for (var i = 0; i < n; i++) buf[i]]);
  } finally {
    ffi_pkg.calloc.free(buf);
  }
}

/// 取窗口所属进程 PID。
int _queryPid(ffi.Pointer<ffi.Void> hwnd) {
  final pidBuf = ffi_pkg.calloc<ffi.Uint32>();
  try {
    _U32.getWindowThreadProcessId(hwnd, pidBuf);
    return pidBuf.value;
  } finally {
    ffi_pkg.calloc.free(pidBuf);
  }
}

/// 取进程的可执行文件名（不含路径）。读不到返回空串（调用方显示"未知进程"）。
///
/// 用 PROCESS_QUERY_LIMITED_INFORMATION：对高完整性进程会失败（访问被拒），
/// 这时返回空串即可——标题才是用户认窗口的主要依据，进程名只是辅助。
String _queryProcessName(int pid) {
  if (pid <= 0) return '';
  final hProcess = _K32.openProcess(_PROCESS_QUERY_LIMITED_INFORMATION, 0, pid);
  if (hProcess == ffi.nullptr) return '';
  try {
    final buf = ffi_pkg.calloc<ffi.Uint16>(_PATH_BUF_CHARS);
    try {
      final sizeBuf = ffi_pkg.calloc<ffi.Uint32>();
      try {
        sizeBuf.value = _PATH_BUF_CHARS;
        if (_K32.queryFullProcessImageNameW(hProcess, 0, buf, sizeBuf) == 0) {
          return '';
        }
        final n = sizeBuf.value;
        if (n <= 0) return '';
        final path =
            String.fromCharCodes(<int>[for (var i = 0; i < n; i++) buf[i]]);
        final slash = path.lastIndexOf(r'\');
        return slash >= 0 ? path.substring(slash + 1) : path;
      } finally {
        ffi_pkg.calloc.free(sizeBuf);
      }
    } finally {
      ffi_pkg.calloc.free(buf);
    }
  } finally {
    _K32.closeHandle(hProcess);
  }
}
