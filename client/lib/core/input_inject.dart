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
// ⚠️ 这里**不 import 任何平台专属 Dart 包**（尤其不 import package:win32）。
// 原因：Dart 的 import 是编译期解析的。win32 只在 Windows 有实现，
// 只要主文件里出现这一行，在 Mac 上编译 iOS 目标就会直接失败 ——
// 条件导入救不了（dart.library.io 在所有原生平台都为真），
// pubspec 也没法按平台剔除依赖（dart-lang/pub#2785）。
//
// 解法：Windows 实现拆到 input_inject_win.dart，里面**只用 dart:ffi**
// 自己声明 Win32 结构体、运行期从 user32.dll 取 SendInput。
// 那个文件因此不含任何平台专属包，iOS/macOS 上编译也是干净的。
// 详见该文件的头部说明。
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'input_inject_win.dart';

// 对外仍然从本文件导出 Windows 实现与键码表，
// 这样调用方（remote_assist.dart / remote.dart / 测试）不用改 import 路径。
export 'input_inject_win.dart' show WindowsInputInjector, Vk, absoluteMousePos;

enum RemoteMouseButton { left, middle, right }

// 注：`absoluteMousePos()` 与 `Vk` 键码表已移到 input_inject_win.dart
// （它们只对 Windows 有意义），本文件通过上面的 export 重新对外提供，
// 调用方与测试的 import 路径不变。

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
