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

  /// 「对方可以操作你的___」这句话里填的东西。
  /// 电脑上填"鼠标键盘"，手机上填"手机" ——
  /// 一句话套在所有平台上会说出"操作你的鼠标键盘"这种手机上的怪话。
  String get controlObject => '本机';

  /// 把鼠标移到归一化位置 (0..1)
  void moveAbsolute(double nx, double ny);

  /// 告诉注入器：本端画面**只包含主显示器**。
  ///
  /// 🔴 归一化坐标的换算前提就是"画面覆盖了哪块屏"，所以这句话必须由
  ///    **采集侧**告诉注入侧，两边用的是同一个事实：
  ///      · 画面是整个虚拟桌面（多屏拼起来）→ 坐标按整个虚拟桌面摊开；
  ///      · 画面只有主显示器               → 坐标按主显示器摊开。
  ///    搞反了的表象是"画面完全正确、但点哪儿都偏一点"，肉眼极难定位
  ///    （曾经就在这里踩过：副屏摆在主屏左侧时算出负坐标，审核看不出来）。
  ///    只有 Windows 有这个概念，其余平台默认空实现即可。
  void usePrimaryOnlyCapture(bool primaryOnly) {}

  // ── 窗口模式（参考 TwinDesk「Apps 面板」）────────────────────
  // 控制端选中被控端的某一个窗口后，注入侧要把鼠标坐标从"窗口内归一化"
  // 换算成"桌面绝对像素"，还要保证键盘输入送到那个窗口（键盘只去前台
  // 窗口，所以选中时可能需要还原最小化 + 抢一次前台）。
  // 只有 Windows 有"顶层窗口"这个概念，其余平台默认空实现。

  /// 锁定注入目标到 [hwnd]（句柄地址值，见 WinWindowInfo.hwnd）。
  /// 传 0 等价于 [clearWindowTarget]。
  void setWindowTarget(int hwnd) {}

  /// 退出窗口模式，回到整屏注入。
  void clearWindowTarget() {}

  /// 当前窗口目标的句柄地址值；0 = 不在窗口模式。
  int get windowTargetHwnd => 0;

  /// 当前窗口目标的实时矩形（被控端屏幕物理坐标）；null = 不在窗口模式
  /// 或窗口暂时不可用（已关闭/最小化中）。
  ({int left, int top, int width, int height})? get windowTargetRect => null;

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

  /// 重新探测"本端到底能不能被控"。
  ///
  /// 只有 Android 需要问（无障碍开关用户可以随时在系统设置里改）；
  /// 其余平台默认就是"能"或"永远不能"，问了也不会变。
  /// 放在基类给一个默认实现，调用方就不必先判平台再决定要不要问。
  Future<void> refreshAbility() async {}

  /// 拉起系统无障碍设置页（仅 Android 有意义）。
  /// 返回是否真的把页面拉起来了 —— 拉不起来的 ROM 必须让 UI 改口提示。
  Future<bool> openAccessibilitySettings() async => false;
}

// ---------------------------------------------------------------- Android

/// Android 注入实现：把"鼠标语义"翻译成"手指手势"。
///
/// ─────────────────────────────────────────────────────────────
/// 为什么必须走无障碍服务
/// ─────────────────────────────────────────────────────────────
/// Android 明确禁止普通 App 伪造触摸事件（否则恶意 App 能自我点广告、
/// 也能替用户点下"确认付款"）。唯一合法的通路是面向辅助功能开放的
/// `AccessibilityService#dispatchGesture`。用户会先在系统设置里看到
/// "是否允许这个辅助功能"的开关 —— 那是 Android 有意设的关卡，
/// 这个能力本来就应当由用户亲手交出来。
///
/// ─────────────────────────────────────────────────────────────
/// 这一层真正干的活：鼠标 → 手指
/// ─────────────────────────────────────────────────────────────
/// 控制端（一台电脑）发过来的是**鼠标语义**：移动、按下、抬起、滚轮。
/// 而手机上没有鼠标，只有手势：点一下、划一道、按久一点。
/// 这两套语义必须对得上，否则：
///   · 直接把"按下"翻译成"点一下" → 拖动（按下→移动→抬起）会变成
///     在起点点一下、然后什么都没发生，"拖得动才怪"；
///   · 把"抬起"也翻译成一次点击 → 每次拖动都额外点两下。
///
/// 所以这里按"按下时记起点、抬起时看有没有移动"来判定：
///   没移动 = 单击（右键 → 长按，这是手机上右键的通行等价物）
///   移动了 = 一道从起点划到终点的手势（时长取真实按住的时长）
/// 手指位置跟着"移动"指令走，但**按下期间不发声** ——
/// 手指按下后系统本来就只能收到一条完整路径。
class AndroidInputInjector extends InputInjector {
  /// 原生侧：MainActivity 里同名的通道（见 RemoteInputService.kt）
  static const MethodChannel channel = MethodChannel('xiaozhi/remote_input');

  /// 无障碍服务是否已开启。**这是异步探测的真实结果**，不是按平台猜的。
  ///
  /// 🔴 曾经这里按 `Platform.isAndroid` 恒报 true —— 用户会在
  ///    「对方正在控制我」的提示下对着一个毫无反应的屏幕反复点击。
  ///    假装能控比直接说不支持糟糕得多。
  ///
  /// 🔴 这两个状态必须是 **static**：请求弹窗、连接页自检卡、真正执行输入的
  ///    RemoteAssistService 各自 new 了一个实例，若是实例字段，
  ///    弹窗探测的结果只落在弹窗那个实例上，服务手里的还是 false，
  ///    于是所有输入指令被静默丢弃 —— 表现是"对方明明同意了、点了却没反应"。
  static bool _enabled = false;

  static bool _probing = false;

  /// 手指当前停在哪个位置（归一化）。按下时记下的起点另存一份，
  /// 抬起时靠它俩判定是"点"还是"划"。
  double _fx = 0.5;
  double _fy = 0.5;
  bool _down = false;
  double _downX = 0.5;
  double _downY = 0.5;
  RemoteMouseButton _downBtn = RemoteMouseButton.left;
  DateTime? _downAt;

  /// 同一条指令并发去调通道会把手势队列堆爆（网络卡时尤其明显），
  /// 所以这里刻意"丢弃"而不是"排队"：远控要的是最新位置，不是补齐历史。
  int _inflight = 0;

  @override
  bool get supported => _enabled;

  @override
  String get controlObject => '手机';

  @override
  String get hint => '这台手机还没开启「小智IM 远程协助」无障碍服务 —— '
      '开启后对方才能操作你的手机，不开启则只能看画面';

  /// 重新探测一次服务开关。
  ///
  /// 这个开关只有用户能在系统设置里动，App 没有资格代开 ——
  /// 所以只能问，不能设。用户从设置页返回后要再问一次才知道结果。
  Future<void> refreshAbility() => ensureProbed();

  /// 所有实例共享的一次探测（重复调用有闸门，不会并发打爆通道）。
  static Future<void> ensureProbed() async {
    if (_probing) return;
    _probing = true;
    try {
      final v = await channel.invokeMethod<bool>('isEnabled');
      _enabled = v == true;
    } catch (e) {
      // 通道没接上（比如跑在桌面上）→ 就是不支持，不假装
      _enabled = false;
    } finally {
      _probing = false;
    }
  }

  /// 拉起系统无障碍设置页。返回是否真的跳过去了 ——
  /// 有的 ROM 没有这个页面，那时必须让 UI 提示"请手动到设置里开"，
  /// 而不是让用户以为点了一下什么都没发生。
  Future<bool> openAccessibilitySettings() => _callBool('openSettings');

  @override
  void moveAbsolute(double nx, double ny) {
    _fx = nx.clamp(0.0, 1.0);
    _fy = ny.clamp(0.0, 1.0);
    // 按下期间只更新位置，不发声。手指一旦按下就只能走一条完整路径。
  }

  @override
  void mouseButton(RemoteMouseButton button, bool down) {
    if (down) {
      if (_down) return; // 已经按着了（可能同时来了第二枚按键）
      _down = true;
      _downBtn = button;
      _downX = _fx;
      _downY = _fy;
      _downAt = DateTime.now();
      return;
    }
    if (!_down) return;
    _down = false;
    final held = DateTime.now().difference(_downAt ?? DateTime.now());
    final moved = (_fx - _downX).abs() > 0.008 || (_fy - _downY).abs() > 0.008;
    if (!moved) {
      // 手机上"右键"没有等价物，通行做法就是长按（长按 = 弹出上下文菜单）
      if (_downBtn == RemoteMouseButton.right) {
        _call('longPress', <String, dynamic>{'x': _fx, 'y': _fy});
      } else {
        _call('tap', <String, dynamic>{'x': _fx, 'y': _fy});
      }
      return;
    }
    // 拖动：时长按真实按住的时间，太短系统不认（<50ms 会被当成空手势丢弃）
    _call('drag', <String, dynamic>{
      'x1': _downX,
      'y1': _downY,
      'x2': _fx,
      'y2': _fy,
      'ms': held.inMilliseconds.clamp(120, 1200),
    });
  }

  @override
  void scroll(int delta) {
    // 浏览器/触控板一格通常是 100 上下，这里折成 1 格
    _call('scroll', <String, dynamic>{
      'x': _fx,
      'y': _fy,
      'delta': delta > 0 ? 1 : -1,
    });
  }

  @override
  void keyDown(RemoteKey key) {
    final c = key.char;
    if (c != null && c.isNotEmpty) {
      final unit = c.codeUnitAt(0);
      if (unit == 0x08) {
        _call('backspace', const <String, dynamic>{});
        return;
      }
      if (unit >= 0x20) {
        _call('type', <String, dynamic>{'text': c});
      }
      return;
    }
    switch (key.vk) {
      case Vk.backspace:
        _call('backspace', const <String, dynamic>{});
      case Vk.enter:
        // 回车在手机上是"提交/换行"，交给 IME 处理最稳
        _call('enter', const <String, dynamic>{});
      case Vk.escape:
        // 手机上没有 Esc，最接近的就是返回键
        _call('back', const <String, dynamic>{});
      case Vk.delete:
        _call('backspace', const <String, dynamic>{});
      default:
        // 方向键 / 功能键 / 组合键在 Android 上没有通用等价物，
        // 静默丢弃比"按了没反应"好：至少不会让人以为卡住了
        break;
    }
  }

  @override
  void keyUp(RemoteKey key) {
    // 文字在 keyDown 时就发出去了（手机没有"按住某键"这回事），
    // 抬起不需要补动作。刻意留空而不是复用 keyDown，
    // 否则每个字会被打两遍。
  }

  void _call(String method, Map<String, dynamic> args) {
    if (!_enabled) return;
    if (_inflight >= 4) return; // 队列堆了就丢最新的，远控要实时性
    _inflight++;
    channel.invokeMethod<bool>(method, args).whenComplete(() => _inflight--);
  }

  Future<bool> _callBool(String method) async {
    try {
      return await channel.invokeMethod<bool>(method) ?? false;
    } catch (_) {
      return false;
    }
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
