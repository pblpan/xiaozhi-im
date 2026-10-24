// 真机 smoke：窗口模式输入坐标换算（#473 的两级换算 + 光标落点验证）
//
// 【测什么、为什么】
// 窗口模式下控制端送来的是"窗口内归一化坐标"（画面里窗口占满视图），
// 被控端要换算成桌面绝对像素再走 SendInput：
//   ① 窗口归一化 → 窗口矩形绝对像素（left + nx*width）
//   ② 绝对像素   → 归一化基准（主屏 or 虚拟桌面，同 usePrimaryOnlyCapture）
// 这两步写反/写漏（比如忘了加 left、除了错的屏幕尺寸、基准选错），
// 现象是"画面上看着点的是 A，实际点在 B"——纯协议单测完全看不见，
// 只能真机验证。这个测试真发鼠标移动（**不点击**，无副作用），
// 再把光标位置读回来和期望值比。
//
// 🔴 CI 是 ubuntu，没有 user32.dll —— 非 Windows 直接跳过。
import 'dart:ffi' as ffi;
import 'dart:io' show Platform, sleep;

import 'package:ffi/ffi.dart' as ffi_pkg;
import 'package:flutter_test/flutter_test.dart';
import 'package:xiaozhi_im_client/core/input_inject.dart';
import 'package:xiaozhi_im_client/core/win_window_list.dart';

// ── 测试自用的最小 user32 绑定（生产代码没导出读光标/读前台这几个） ──
// 写法与 lib/core/input_inject_win.dart 的 _User32 保持一致（老分析器只认
// 这个 lookupFunction 双类型参数形态，别改成新版统一函数指针）。
// ABI 类型（Struct/Int32/Pointer）走 dart:ffi，calloc 走 package:ffi。

final class _POINT extends ffi.Struct {
  @ffi.Int32()
  external int x;

  @ffi.Int32()
  external int y;
}

typedef _GetCursorPosNative = ffi.Int32 Function(ffi.Pointer<_POINT>);
typedef _GetCursorPosDart = int Function(ffi.Pointer<_POINT>);
typedef _GetForegroundWindowNative = ffi.IntPtr Function();
typedef _GetForegroundWindowDart = int Function();
typedef _GetSystemMetricsNative = ffi.Int32 Function(ffi.Int32);
typedef _GetSystemMetricsDart = int Function(int);

final _u32 = ffi.DynamicLibrary.open('user32.dll');
final _getCursorPos =
    _u32.lookupFunction<_GetCursorPosNative, _GetCursorPosDart>('GetCursorPos');
final _getForegroundWindow = _u32.lookupFunction<
    _GetForegroundWindowNative, _GetForegroundWindowDart>('GetForegroundWindow');
final _getSystemMetrics =
    _u32.lookupFunction<_GetSystemMetricsNative, _GetSystemMetricsDart>(
        'GetSystemMetrics');

({int x, int y}) _cursorPos() {
  final p = ffi_pkg.calloc<_POINT>();
  try {
    if (_getCursorPos(p) == 0) return (x: -1, y: -1); // 极少见：读失败
    return (x: p.ref.x, y: p.ref.y);
  } finally {
    ffi_pkg.calloc.free(p);
  }
}

void main() {
  if (!Platform.isWindows) return;

  group('窗口模式输入坐标真机 smoke（仅本机 Windows 跑，CI 自动跳过）', () {
    test('moveAbsolute：光标落在窗口内的期望位置（±2px）', () {
      final inj = createInputInjector();
      expect(inj.supported, isTrue);
      // 与"只抓主屏"的采集设置成对 —— 单边改就会"画面对、点不准"
      inj.usePrimaryOnlyCapture(true);

      final primW = _getSystemMetrics(0); // SM_CXSCREEN
      final primH = _getSystemMetrics(1); // SM_CYSCREEN
      expect(primW, greaterThan(0));
      expect(primH, greaterThan(0));

      // 候选：没最小化、别太小、**整个在主屏内**（跨屏摆放时 primaryOnly
      // 基准下归一化会超过 1，那是另一套语义，不在这条用例里混）。
      final candidates = enumerateWindows()
          .where((w) =>
              !w.minimized &&
              w.width >= 200 &&
              w.height >= 150 &&
              w.left >= 0 &&
              w.top >= 0 &&
              w.left + w.width <= primW &&
              w.top + w.height <= primH)
          .toList();
      expect(candidates, isNotEmpty, reason: '主屏上没有够大的完整可见窗口');

      // 优先拿**前台窗口**：setWindowTarget 会激活目标，激活一个已经在前台的
      // 窗口等于无感，不打扰正在跑测试的人；找不到才退而求其次选最大的。
      final fg = _getForegroundWindow();
      final target = candidates.firstWhere((w) => w.hwnd == fg,
          orElse: () => candidates.first);

      inj.setWindowTarget(target.hwnd);
      final rect = inj.windowTargetRect;
      expect(rect, isNotNull,
          reason: 'setWindowTarget 之后必须能拿到窗口矩形');
      expect(rect!.width, target.width);
      expect(rect.height, target.height);

      // 三个采样点：中心 / 偏下 / 偏右上。只移动、**不点击**。
      const points = [
        [0.5, 0.5],
        [0.25, 0.75],
        [0.9, 0.1],
      ];
      for (final p in points) {
        final nx = p[0];
        final ny = p[1];
        inj.moveAbsolute(nx, ny);
        // SendInput 是异步入队的，光标落位要等一个极短的窗口期
        sleep(const Duration(milliseconds: 80));
        final cur = _cursorPos();
        final ex = rect.left + nx * rect.width;
        final ey = rect.top + ny * rect.height;
        expect(cur.x, closeTo(ex, 2),
            reason: '窗口(${rect.left},${rect.top} ${rect.width}x${rect.height}) '
                'nx=$nx → 期望 x≈${ex.toStringAsFixed(1)}，实际 ${cur.x}');
        expect(cur.y, closeTo(ey, 2),
            reason: 'ny=$ny → 期望 y≈${ey.toStringAsFixed(1)}，实际 ${cur.y}');
      }

      inj.clearWindowTarget();
      expect(inj.windowTargetHwnd, 0);
      expect(inj.windowTargetRect, isNull);
    });

    test('max/min 边界：nx/ny 越界时夹到窗口边缘，不会飞到窗外', () {
      final inj = createInputInjector();
      inj.usePrimaryOnlyCapture(true);
      final primW = _getSystemMetrics(0);
      final primH = _getSystemMetrics(1);
      final candidates = enumerateWindows()
          .where((w) =>
              !w.minimized &&
              w.width >= 200 &&
              w.height >= 150 &&
              w.left >= 0 &&
              w.top >= 0 &&
              w.left + w.width <= primW &&
              w.top + w.height <= primH)
          .toList();
      expect(candidates, isNotEmpty);
      final target = candidates.first;

      inj.setWindowTarget(target.hwnd);
      final rect = inj.windowTargetRect!;

      inj.moveAbsolute(-0.5, 2.5); // 双双越界：应夹到窗口左上 → 右下
      sleep(const Duration(milliseconds: 80));
      final cur = _cursorPos();
      // 夹紧发生在"窗口内归一化"这一层（clamp(0,1) 后再乘窗口尺寸），
      // 所以落点必须是窗口左上角 → 右下角；
      // 若换算顺序写反（拿桌面归一化去夹）会飞到屏幕角 (0,0)→(primW,primH)。
      expect(cur.x, closeTo(rect.left, 2));
      expect(cur.y, closeTo(rect.top + rect.height, 2));

      inj.clearWindowTarget();
    });
  });
}
