// 键鼠注入抽象层（远程协助「被控端」专用）
//
// 【为什么要抽象一层】
// Windows 可以直接注入（Win32 SendInput）；Android 做不到 —— 系统不允许普通 App
// 凭空产生触摸事件，必须走**无障碍服务**这条路。两边能力差别很大，但又必须
// 给上层同一个操作界面，所以这里抽一个统一接口，具体实现按平台分。
//
// 【坐标为什么用归一化 0..1】
// 控制端看到的画面尺寸 ≠ 被控端实际分辨率（中间还可能隔着缩放 / 多屏）。
// 传像素值必然错位；传比例再由**被控端**按自己的真实桌面换算，才是准的 ——
// 这个换算必须发生在被控端，因为只有它知道自己屏幕到底多大。

// ⚠️ `dart:ffi` 必须**显式 import**（哪怕只用 `sizeOf` 和一个 `Allocator`）。
// 原因：`sizeOf` 是 dart:ffi 的顶层函数；而 `calloc<T>()` 依赖的 `Allocator.call`
// 是 dart:ffi 里声明的**扩展方法** —— 扩展的可见性取决于"哪个库被 import"，
// 光靠 package:ffi 再导出类型是不够的。不 import 会报很难懂的
// "expression doesn't evaluate to a function"。
import 'dart:ffi' as dffi;
import 'dart:io' show Platform;

import 'package:ffi/ffi.dart' as ffi;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:win32/win32.dart' as win;

enum RemoteMouseButton { left, middle, right }

/// 归一化坐标 → Win32 绝对鼠标坐标（0..65535）。
///
/// 抽成顶层纯函数是为了**能单测**：这里算错的表象是"鼠标点了但点偏一点点"，
/// 靠肉眼几乎不可能定位。之所以要特意强调：曾经这里先加虚拟屏原点、再除屏幕
/// 总宽，结果副屏摆在主屏左侧时审核不出问题、实测却算出负坐标。
({int x, int y}) absoluteMousePos(double nx, double ny) =>
    (x: (nx.clamp(0.0, 1.0) * 65535).round(), y: (ny.clamp(0.0, 1.0) * 65535).round());

/// 一次键盘动作的"原始素材"。
///
/// 之所以同时带 vk 和 char：普通可打印字符用 **Unicode 注入**（不受被控端当前
/// 输入法/键盘布局影响，中文 Windows 上也不会按错键）；方向键、Ctrl+C 这类
/// 本来就不是字符，只能通过虚拟键码表达。两者互斥，优先用 char。
///
/// ⚠️ 这里**没有 shift/ctrl/alt 这些修饰位**，是刻意的。
/// Ctrl+C 不是"一次按键"，而是"Ctrl 按下 → C 按下 → C 抬起 → Ctrl 抬起"
/// 这条序列；控制端把每个键的按下/抬起如实发过来，被控端按原顺序注入，
/// 组合键自然就成立了。在 RemoteKey 上挂修饰位反而会诱导写成"一次性发送
/// Ctrl+C"，而那种写法在真实的 Win32 注入里并不能正确释放按键状态。
class RemoteKey {
  const RemoteKey({
    this.vk,
    this.char,
    this.extended = false,
  });

  /// Windows 虚拟键码（Vk.*），控制类按键与组合键用
  final int? vk;

  /// 要注入的字符，可打印字符用
  final String? char;

  /// 扩展键（方向键、右 Ctrl 等在某些场景需要，用来区分小键盘与方向键）
  final bool extended;
}

abstract class InputInjector {
  /// 当前平台是否支持注入。不支持时上层要如实告诉用户，
  /// 而不是假装"正在控制" —— 那比直接失败更糟。
  bool get supported;

  /// 不支持时给用户的解释（具体到要做什么操作）
  String get hint;

  /// 把鼠标移到归一化位置 (0..1)
  void moveAbsolute(double nx, double ny);

  void mouseButton(RemoteMouseButton button, bool down);

  /// 滚轮。delta 为正表示向上滚。
  void scroll(int delta);

  void keyDown(RemoteKey key);

  void keyUp(RemoteKey key);

  /// 一次性按下并抬起（打字这类短促操作）
  void tapKey(RemoteKey key) {
    keyDown(key);
    keyUp(key);
  }
}

// ---------------------------------------------------------------- Windows

/// Windows 注入实现：Win32 `SendInput`。
///
/// 【为什么不用已被标记废弃的 mouse_event / keybd_event】
/// 它们现在还能跑，但官方已明确建议迁移；更实际的是 SendInput 支持
/// "一次投递多条输入由系统按队列处理"，行为与真实输入一致，延迟也更低。
class WindowsInputInjector extends InputInjector {
  @override
  bool get supported => Platform.isWindows;

  @override
  String get hint => 'Windows 端可直接远程控制';

  /// ⚠️ 归一化 → 绝对坐标的换算，**不能**减虚拟屏原点。
  ///
  /// `MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK` 的语义就是：dx/dy 是覆盖
  /// **整个虚拟桌面**的 0..65535 定点数。所以 0..1 的比例乘 65535 就是答案，
  /// 不需要（也不应该）先用 GetSystemMetrics 拿虚拟屏尺寸再折算 ——
  /// 一旦副屏摆在主屏左侧，虚拟屏原点 _vx 是负数，先加原点再除总宽会算出负坐标。
  ///
  /// ⚠️ 已知限制：若被控端有多块显示器而共享的只是其中一块，控制端画面里的
  /// 0..1 会映射到整块虚拟桌面而非那块被共享的屏。要用 gloss 去区分的话得先让
  /// 采集侧回报"共享的是哪一块屏"，目前 getDisplayMedia 拿不到，先按桌面整体处理。
  @override
  void moveAbsolute(double nx, double ny) {
    final p = absoluteMousePos(nx, ny);
    _sendMouse(
      win.MOUSEEVENTF_MOVE |
          win.MOUSEEVENTF_ABSOLUTE |
          win.MOUSEEVENTF_VIRTUALDESK,
      p.x,
      p.y,
      0,
    );
  }

  @override
  void mouseButton(RemoteMouseButton button, bool down) {
    // down/up 事件自带上一个 moveAbsolute 的位置 —— 上层保证"先移动再点击"的顺序
    final win.MOUSE_EVENT_FLAGS f;
    switch (button) {
      case RemoteMouseButton.left:
        f = down ? win.MOUSEEVENTF_LEFTDOWN : win.MOUSEEVENTF_LEFTUP;
        break;
      case RemoteMouseButton.middle:
        f = down ? win.MOUSEEVENTF_MIDDLEDOWN : win.MOUSEEVENTF_MIDDLEUP;
        break;
      case RemoteMouseButton.right:
        f = down ? win.MOUSEEVENTF_RIGHTDOWN : win.MOUSEEVENTF_RIGHTUP;
        break;
    }
    _sendMouse(f, 0, 0, 0);
  }

  @override
  void scroll(int delta) {
    // WHEEL_DELTA = 120 是"一格"的标准量；符号按直觉取反（向上滚为正）
    _sendMouse(win.MOUSEEVENTF_WHEEL, 0, 0, -delta * 120);
  }

  void _sendMouse(win.MOUSE_EVENT_FLAGS flags, int dx, int dy, int data) {
    final p = ffi.calloc<win.INPUT>();
    try {
      p.ref.type = win.INPUT_MOUSE;
      p.ref.mi.dx = dx;
      p.ref.mi.dy = dy;
      p.ref.mi.mouseData = data;
      p.ref.mi.dwFlags = flags;
      p.ref.mi.time = 0;
      p.ref.mi.dwExtraInfo = 0;
      win.SendInput(1, p, dffi.sizeOf<win.INPUT>());
    } finally {
      ffi.calloc.free(p);
    }
  }

  @override
  void keyDown(RemoteKey key) => _key(key, true);

  @override
  void keyUp(RemoteKey key) => _key(key, false);

  void _key(RemoteKey k, bool down) {
    final p = ffi.calloc<win.INPUT>();
    try {
      p.ref.type = win.INPUT_KEYBOARD;
      final up = down ? const win.KEYBD_EVENT_FLAGS(0) : win.KEYEVENTF_KEYUP;

      if (k.char != null && k.char!.isNotEmpty) {
        // Unicode 注入：一个 UTF-16 码元一次。中文/符号都能原样打出，
        // 不受被控端输入法状态影响。
        for (final unit in k.char!.codeUnits) {
          p.ref.ki.wVk = const win.VIRTUAL_KEY(0);
          p.ref.ki.wScan = unit;
          p.ref.ki.dwFlags = win.KEYEVENTF_UNICODE | up;
          p.ref.ki.time = 0;
          p.ref.ki.dwExtraInfo = 0;
          win.SendInput(1, p, dffi.sizeOf<win.INPUT>());
        }
        return;
      }

      final vk = k.vk;
      if (vk == null) return;
      var flags = up;
      if (k.extended) flags = flags | win.KEYEVENTF_EXTENDEDKEY;
      p.ref.ki.wVk = win.VIRTUAL_KEY(vk);
      p.ref.ki.wScan = 0;
      p.ref.ki.dwFlags = flags;
      p.ref.ki.time = 0;
      p.ref.ki.dwExtraInfo = 0;
      win.SendInput(1, p, dffi.sizeOf<win.INPUT>());
    } finally {
      ffi.calloc.free(p);
    }
  }
}

// ---------------------------------------------------------------- Android

/// Android 注入实现（**当前尚未可用**）。
///
/// 【为什么 Android 必须走无障碍服务】
/// Android 从设计上禁止普通 App 伪造触摸事件（防止恶意 App 自我点击、
/// 或诱导用户开启后自动付款）。唯一合法的口子是面向"辅助功能"开放的
/// `AccessibilityService#dispatchGesture`。所以真要做的话，用户连线前会看到
/// 系统级的"是否允许该辅助功能"开关 —— 那不是我们绕不过去，是系统有意设的关卡。
///
/// 【为什么不直接实现算了】
/// 原生侧（MainActivity 的 MethodChannel + 一个 AccessibilityService + 手势
/// 派发）还没写。在它落地之前，`supported` 必须如实返回 false：
/// 若按 `Platform.isAndroid` 报 true，用户会在「对方正在控制我」的提示下
/// 对着一个毫无反应的屏幕反复点击 —— **假装能控比直接说不支持糟糕得多**。
/// 等原生侧补齐（走到 MethodChannel 真的有响应），再把 supported 换成
/// 异步探测结果即可，本类的其余实现已经就位。
class AndroidInputInjector extends InputInjector {
  /// 原生侧实现后要走这个通道（见 Android/app/src/main/kotlin 侧 TODO）
  static const MethodChannel channel = MethodChannel('xiaozhi/remote_input');

  @override
  bool get supported => false;

  @override
  String get hint =>
      'Android 端暂时不能被远程控制，对方只能观看本机屏幕（原生无障碍服务尚未实现）';

  /// 无障碍服务是否已开启。原生侧还没实现，所以恒定 false ——
  /// 这里刻意不去 optimistic 地猜，猜错就是"点了没反应"。
  Future<bool> get isServiceEnabled async => false;

  /// 拉起系统无障碍设置页。原生侧未实现时**必须静默**，不能抛。
  Future<void> openAccessibilitySettings() async {}

  @override
  void moveAbsolute(double nx, double ny) => _unsupported('move');

  @override
  void mouseButton(RemoteMouseButton button, bool down) => _unsupported('tap');

  @override
  void scroll(int delta) => _unsupported('scroll');

  @override
  void keyDown(RemoteKey key) => _unsupported('keyDown');

  @override
  void keyUp(RemoteKey key) => _unsupported('keyUp');

  void _unsupported(String op) {
    debugPrint('[remote-input] Android 注入尚未实现，忽略 $op');
  }
}

// ---------------------------------------------------------------- 兜底

class UnsupportedInputInjector extends InputInjector {
  UnsupportedInputInjector(this._hint);
  final String _hint;

  @override
  bool get supported => false;

  @override
  String get hint => _hint;

  @override
  void moveAbsolute(double nx, double ny) {}

  @override
  void mouseButton(RemoteMouseButton button, bool down) {}

  @override
  void scroll(int delta) {}

  @override
  void keyDown(RemoteKey key) {}

  @override
  void keyUp(RemoteKey key) {}
}

InputInjector createInputInjector() {
  if (Platform.isWindows) return WindowsInputInjector();
  if (Platform.isAndroid) return AndroidInputInjector();
  return UnsupportedInputInjector('当前平台不支持远程控制，只能观看对方屏幕');
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
