// 真机 smoke：窗口模式抓一帧（#472 的坐标换算 + BitBlt/StretchBlt 链路）
//
// 【测什么、为什么】
// 单元测试（remote_window_protocol_test.dart）只覆盖报文解析；而窗口模式真正
// 容易埋雷的是**被控端本机的这段链路**：
//   GetWindowRect → 与采集区求交 → StretchBlt 源矩形 → GetDIBits → JPEG
// 其中「求交」写错半个像素、源矩形左右颠倒、最小化哨兵坐标没排掉，
// 单元测试全都看不见，只会表现为控制端花屏/黑屏/尺寸不对。
// 这个文件在真机上真抓一帧，把上面每一环都钉死：
//   · 选一个真窗口，断言帧尺寸严格等于「窗口矩形 ∩ 采集区 → 缩放」的期望值
//   · 断言 JPEG 头尾完整（SOI/EOI），解码后不是纯色（黑屏立刻红）
//   · 垃圾句柄必须 gone 且抓不到帧（不能崩）
//   · clearWindow 后回到整屏还能抓
//
// 🔴 CI runner 是 ubuntu，没有 user32/gdi32 —— 整个文件在非 Windows 上
//    直接 return，测试记为跳过而不是失败。
import 'dart:io' show Platform;
import 'dart:math' show max, min, sqrt;

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:xiaozhi_im_client/core/win_gdi_capture.dart';
import 'package:xiaozhi_im_client/core/win_window_list.dart';

void main() {
  if (!Platform.isWindows) return;

  group('窗口模式抓屏真机 smoke（仅本机 Windows 跑，CI 自动跳过）', () {
    late WinGdiCapture cap;

    setUp(() {
      cap = WinGdiCapture(); // 只抓主屏：采集区原点 (0,0)
      // open 失败必须带原因红，不能静默走后面（v0.28.5 前最难查的就是这种）
      expect(cap.open(), isTrue, reason: 'GDI 采集器打不开：${cap.lastError}');
    });

    tearDown(() => cap.dispose());

    test('选中一个真窗口：帧尺寸/内容全部符合期望', () {
      // 候选：没最小化、别太小（小窗口缩放后只剩几个像素，断言没意义）。
      // 从大到小试：大窗口内容杂，stddev 检查稳。
      final candidates = enumerateWindows()
          .where((w) => !w.minimized && w.width >= 200 && w.height >= 150)
          .toList()
        ..sort((a, b) =>
            (b.width * b.height).compareTo(a.width * a.height));
      expect(candidates, isNotEmpty, reason: '屏幕上没有够大的可见窗口');

      // 逐个试：窗口可能在枚举后就被关/最小化（gone/min → 抓不到 → 换下一个）。
      // 这不是放过错误，而是把"桌面是活的"这个事实考虑进去。
      GdiFrame? frame;
      WinWindowInfo? picked;
      final trace = <String>[];
      for (final w in candidates) {
        cap.setWindow(w.hwnd);
        frame = cap.captureJpeg(maxWidth: 1280, quality: 65);
        if (frame != null && cap.windowState == 'ok') {
          picked = w;
          break;
        }
        trace.add('${w.process}/${w.title} → ${cap.windowState}');
        frame = null;
      }
      expect(picked, isNotNull,
          reason: '试了 ${candidates.length} 个窗口都抓不到：$trace');
      final w = picked!; // expect 已保证非空，这里收编掉 ? 便于后面用

      // ── 1. JPEG 结构完整（头 SOI / 尾 EOI）
      final jpeg = frame!.jpeg;
      expect(jpeg.length, greaterThan(500));
      expect(jpeg[0], 0xFF);
      expect(jpeg[1], 0xD8, reason: '缺 JPEG SOI 头');
      expect(jpeg[jpeg.length - 2], 0xFF);
      expect(jpeg[jpeg.length - 1], 0xD9, reason: '缺 JPEG EOI 尾');

      // ── 2. 帧尺寸严格等于「窗口矩形 ∩ 采集区 → 等比缩到 maxWidth」的期望值。
      // 公式与 captureJpeg 内部逐行对应；写岔（比如忘了 & ~1、忘了 round、
      // 交集用错角）这里立刻红。
      final sx = max(w.left, 0);
      final sy = max(w.top, 0);
      final sw = min(w.left + w.width, cap.sourceWidth) - sx;
      final sh = min(w.top + w.height, cap.sourceHeight) - sy;
      expect(sw, greaterThan(0));
      expect(sh, greaterThan(0));
      var dw = sw;
      var dh = sh;
      if (sw > 1280) {
        dw = 1280;
        dh = (sh * 1280 / sw).round();
      }
      dw &= ~1; // JPEG 色度下采样按 2x2，宽高必须偶数
      dh &= ~1;
      expect(frame.width, dw,
          reason: '窗口 ${w.width}x${w.height} ∩ 采集区 '
              '${cap.sourceWidth}x${cap.sourceHeight} → 期望 ${dw}x$dh');
      expect(frame.height, dh);
      expect(frame.width & 1, 0);
      expect(frame.height & 1, 0);

      // ── 3. 内容不是纯色。黑屏/白屏都意味着 BitBlt 源矩形或 DC 有问题
      // （尺寸对但内容全黑正是"坐标对了、DC 错了"的典型表现）。
      final decoded = img.decodeImage(jpeg);
      expect(decoded, isNotNull, reason: 'JPEG 解不开，编码链路坏了');
      final im = decoded!;
      var sum = 0.0;
      var sumSq = 0.0;
      var n = 0;
      for (var y = 0; y < im.height; y += 7) {
        for (var x = 0; x < im.width; x += 7) {
          final p = im.getPixel(x, y);
          final lum = 0.299 * p.r.toDouble() +
              0.587 * p.g.toDouble() +
              0.114 * p.b.toDouble();
          sum += lum;
          sumSq += lum * lum;
          n++;
        }
      }
      final mean = sum / n;
      final variance = sumSq / n - mean * mean;
      final stddev = sqrt(variance < 0 ? 0 : variance); // 浮点尾差可能出负
      expect(stddev, greaterThan(3.0),
          reason: '画面接近纯色（黑屏？），亮度均值=$mean 标准差=$stddev');
    });

    test('垃圾句柄：gone 且抓不到帧，不崩', () {
      cap.setWindow(0x7FFFFFF0); // 高位地址，不可能是真窗口
      expect(cap.captureJpeg(), isNull);
      expect(cap.windowState, 'gone');
      expect(cap.lastError, isNotEmpty);
    });

    test('clearWindow 后回到整屏：状态复位，整屏照样能抓', () {
      // 先进一次窗口模式再退出，确保退出路径真的把采集区还给了整屏
      final first = enumerateWindows()
          .firstWhere((w) => !w.minimized && w.width >= 200);
      cap.setWindow(first.hwnd);
      expect(cap.windowMode, isTrue);
      cap.clearWindow();
      expect(cap.windowMode, isFalse);
      expect(cap.windowState, '');
      expect(cap.describe(), startsWith('主显示器'),
          reason: 'describe() 应回到整屏描述，实际：${cap.describe()}');

      final f = cap.captureJpeg(maxWidth: 1280, quality: 65);
      expect(f, isNotNull, reason: '整屏抓不到：${cap.lastError}');
      expect(f!.width, greaterThan(0));
      expect(f.jpeg[1], 0xD8);
    });
  });
}
