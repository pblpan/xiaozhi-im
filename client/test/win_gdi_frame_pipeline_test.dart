// 真机全链路：抓屏 → 分片 → 乱序重组 → Skia 解码 → 像素检查
//
// 【为什么需要这一条】
// 手机看电脑黑屏，可能是三处任一：
//   ① 被控端抓出来就是黑帧；② 分片/重组的字节错位；③ 控制端解码失败
// 其中 ① 之前只验过 package:image 自己解自己，② 只验过纯内存单测，
// ③ 从来没验过 —— 因为手机端用的是 **Skia（ui.instantiateImageCodec）**，
// 和 package:image 是两套解码器。这个用例把 ①②③ 一次串起来跑在真机上：
// 真实 GDI 抓屏 → packRemoteFrame 切片 → 故意倒序喂给 RemoteFrameAssembler
// → ui.instantiateImageCodec 解码 → 读回 RGBA 算亮度分布。
//
// 只要这条绿，"抓/切/拼/解" 四环就都是对的，黑屏只剩网络传输或上层渲染。
// 🔴 CI 是 ubuntu，非 Windows 直接跳过。
import 'dart:io' show Platform;
import 'dart:math' show sqrt;
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:xiaozhi_im_client/core/remote_frame_stream.dart';
import 'package:xiaozhi_im_client/core/win_gdi_capture.dart';

void main() {
  if (!Platform.isWindows) return;

  test('抓屏→分片→乱序重组→Skia 解码：字节与像素都对', () async {
    final cap = WinGdiCapture(); // 与线上一致：只抓主显示器
    expect(cap.open(), isTrue, reason: '采集器打不开：${cap.lastError}');
    try {
      // 线上默认档位就是 960 宽
      final f = cap.captureJpeg(maxWidth: 960, quality: 65);
      expect(f, isNotNull, reason: '抓屏失败：${cap.lastError}');
      final frame0 = f!;
      expect(frame0.width, lessThanOrEqualTo(960));
      expect(frame0.width & 1, 0);
      expect(frame0.jpeg.length, greaterThan(2000),
          reason: 'JPEG 太小，很可能是纯色/黑帧');

      // ── 分片，然后**故意倒序**喂：重组器必须靠 idx 摆回原位
      final parts = packRemoteFrame(
        seq: 7,
        width: frame0.width,
        height: frame0.height,
        jpeg: frame0.jpeg,
      );
      expect(parts.length, greaterThan(1), reason: '960 宽的一帧应该不止一片');

      final asm = RemoteFrameAssembler();
      RemoteFrame? done;
      for (final p in parts.reversed) {
        done = asm.feed(p) ?? done;
      }
      expect(done, isNotNull, reason: '分片没拼齐');
      expect(done!.width, frame0.width);
      expect(done.height, frame0.height);

      // ── 拼回来的字节必须和原 JPEG 一模一样（不是"差不多"）
      expect(done.jpeg.length, frame0.jpeg.length);
      for (var i = 0; i < done.jpeg.length; i++) {
        if (done.jpeg[i] != frame0.jpeg[i]) {
          fail('重组后第 $i 字节不一致：${done.jpeg[i]} != ${frame0.jpeg[i]}');
        }
      }

      // ── 关键一枪：用 Skia 解（手机端走的就是这条路，不是 package:image）
      final codec = await ui.instantiateImageCodec(done.jpeg);
      final decoded = await codec.getNextFrame();
      codec.dispose();
      final img = decoded.image;
      expect(img.width, frame0.width);
      expect(img.height, frame0.height);

      // ── 读回像素：全黑/全白都意味着抓屏或编码有问题
      final bytes = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
      expect(bytes, isNotNull);
      final px = bytes!.buffer.asUint8List();
      var sum = 0.0;
      var sumSq = 0.0;
      var n = 0;
      final stride = img.width * 4;
      for (var y = 0; y < img.height; y += 9) {
        for (var x = 0; x < img.width; x += 9) {
          final o = y * stride + x * 4;
          final lum = 0.299 * px[o] + 0.587 * px[o + 1] + 0.114 * px[o + 2];
          sum += lum;
          sumSq += lum * lum;
          n++;
        }
      }
      final mean = sum / n;
      final variance = sumSq / n - mean * mean;
      final stddev = sqrt(variance < 0 ? 0 : variance);
      // 打印出来，跑一次就知道这台机器现在抓到的是什么
      // ignore: avoid_print
      print('[全链路] ${frame0.width}x${frame0.height} '
          '${(frame0.jpeg.length / 1024).toStringAsFixed(1)}KB '
          '分 ${parts.length} 片 · 亮度均值 ${mean.toStringAsFixed(1)} '
          '标准差 ${stddev.toStringAsFixed(1)}');
      expect(mean, greaterThan(4), reason: '整屏全黑（均值 $mean）');
      expect(stddev, greaterThan(3), reason: '画面接近纯色（标准差 $stddev）');
      img.dispose();
    } finally {
      cap.dispose();
    }
  });
}
