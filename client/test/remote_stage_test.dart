// 远程控制端画布：坐标换算（纯函数，零 Flutter 渲染依赖也能跑）
//
// 【为什么这里这么较真】
// 远程控制里最阴的一类 bug 就是坐标：算错一格，用户看到的是"点了没反应"，
// 代码里看不出任何异常 —— 没有崩溃、没有日志、画面照常在动。
// 2026-10-16 之前真实发生过的就是这种：坐标按**整个容器**换算，
// 而画面只是中间一条（16:9 的电脑屏装进竖屏手机），
// 点在黑边上算出来照样是 0..1，于是"点标题栏"实际落到屏幕正中。
// 下面每一条用例都对应一种真实会出现的手机姿态。

import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:xiaozhi_im_client/screens/remote.dart';

void main() {
  group('remoteVideoRect：contain 矩形', () {
    test('16:9 画面装进竖屏手机：上下留黑边、左右贴满', () {
      // 400 x 800 的竖屏，16:9 的画面 → 高只有 225，上下各留 287.5
      final r = remoteVideoRect(const Size(400, 800), const Size(1920, 1080));
      expect(r.width, 400);
      expect(r.height, closeTo(225, 0.01));
      expect(r.top, closeTo((800 - 225) / 2, 0.01));
      expect(r.left, 0);
    });

    test('首帧未到（videoSize 为 null）按 16:9 兜底，不抛异常', () {
      final r = remoteVideoRect(const Size(400, 800), null);
      expect(r.width, 400);
      expect(r.height, closeTo(225, 0.01));
    });

    test('画面尺寸异常（0 或负）也走兜底，不除零', () {
      final a = remoteVideoRect(const Size(400, 800), const Size(0, 0));
      final b = remoteVideoRect(const Size(400, 800), const Size(-1, 1080));
      expect(a.width, 400);
      expect(b.width, 400);
    });

    test('同比例时正好铺满（不留黑边）', () {
      final r = remoteVideoRect(const Size(800, 450), const Size(1600, 900));
      expect(r.left, 0);
      expect(r.top, 0);
      expect(r.width, 800);
      expect(r.height, 450);
    });
  });

  group('remoteNormFromStage：1 倍（不缩放）', () {
    const box = Size(400, 800);
    final rect = remoteVideoRect(box, const Size(1920, 1080));

    test('画面矩形中心 = 屏幕正中', () {
      final n = remoteNormFromStage(
          rect.center, rect, 1.0, Offset.zero)!;
      expect(n.dx, closeTo(0.5, 1e-9));
      expect(n.dy, closeTo(0.5, 1e-9));
    });

    test('画面矩形左上角 = 屏幕左上角（0,0）', () {
      final n = remoteNormFromStage(rect.topLeft, rect, 1.0, Offset.zero)!;
      expect(n.dx, closeTo(0, 1e-9));
      expect(n.dy, closeTo(0, 1e-9));
    });

    test('🔴 黑边上的点必须返回 null（这是"点了没反应"的根）', () {
      // 容器正中偏上 —— 在画面矩形上方那条黑边里
      final inLetterbox = Offset(200, rect.top / 2);
      expect(
        remoteNormFromStage(inLetterbox, rect, 1.0, Offset.zero),
        isNull,
      );
      // 容器最底部（画面矩形下面那条黑边）
      expect(
        remoteNormFromStage(const Offset(200, 799), rect, 1.0, Offset.zero),
        isNull,
      );
    });
  });

  group('remoteNormFromStage：放大 + 平移', () {
    const box = Size(400, 800);
    final rect = remoteVideoRect(box, const Size(1920, 1080));

    test('放大 2 倍后，屏幕坐标仍能正确换算（不随缩放漂移）', () {
      // 以画面中心放大 2 倍：t = f - s*f
      const s = 2.0;
      final f = rect.center;
      final pan = Offset(f.dx - s * f.dx, f.dy - s * f.dy);
      // 画面中心在放大前后都对应屏幕正中
      final n = remoteNormFromStage(f, rect, s, pan)!;
      expect(n.dx, closeTo(0.5, 1e-9));
      expect(n.dy, closeTo(0.5, 1e-9));

      // 往右挪 50 像素（放大后）→ 归一化横坐标应增加 50 / (rect.width*s)
      final p2 = f + const Offset(50, 0);
      final n2 = remoteNormFromStage(p2, rect, s, pan)!;
      expect(n2.dx, closeTo(0.5 + 50 / (rect.width * s), 1e-9));
      expect(n2.dy, closeTo(0.5, 1e-9));
    });

    test('放大 8 倍（最大档）也不出界', () {
      const s = 8.0;
      final f = rect.center;
      final pan = Offset(f.dx - s * f.dx, f.dy - s * f.dy);
      final n = remoteNormFromStage(f, rect, s, pan)!;
      expect(n.dx, closeTo(0.5, 1e-9));
      expect(n.dy, closeTo(0.5, 1e-9));
    });

    test('缩放为 0（异常状态）返回 null，不除零', () {
      expect(
        remoteNormFromStage(Offset.zero, rect, 0.0, Offset.zero),
        isNull,
      );
    });
  });

  group('回归：旧实现会算错的那些点', () {
    test('🔴 点竖屏顶部黑边：旧实现给 0.25，正确答案是 null', () {
      const box = Size(400, 800);
      final rect = remoteVideoRect(box, const Size(1920, 1080));
      // 旧实现：y = 200 / 800 = 0.25 —— 会真的点下去（错）
      expect(200 / box.height, closeTo(0.25, 1e-9));
      // 新实现：这个点在画面矩形上方，是黑边 → 丢弃
      final p = Offset(200, 200);
      expect(p.dy < rect.top, isTrue, reason: '前提：这个点确实在黑边里');
      expect(
        remoteNormFromStage(p, rect, 1.0, Offset.zero),
        isNull,
      );
    });
  });
}
