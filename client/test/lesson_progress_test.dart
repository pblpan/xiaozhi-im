import 'package:flutter_test/flutter_test.dart';
import 'package:xiaozhi_im_client/core/lesson_progress.dart';

/// 真进度的判据测试。
///
/// 🔴 这一组里**必须有反向样本**：只测"看完了 → done"是没用的，
///    因为"打开就记完成"那种假口径同样能过。真正要钉死的是
///    「拖进度条 / 点开就退出」**不能**拿到 done。
void main() {
  /// 模拟"真的在播"：每秒位置 +1 秒。
  void play(LessonWatch w, int seconds, {int rate = 1}) {
    for (var i = 0; i < seconds; i++) {
      w.tick(
        playing: true,
        positionSec: w.positionSec + rate,
        elapsedSec: 1,
      );
    }
  }

  group('真进度：看满才算', () {
    test('看完 90% → done', () {
      final w = LessonWatch(durationSec: 600);
      expect(w.requiredSec, 540);
      expect(w.done, isFalse);
      play(w, 540);
      expect(w.watchedSec, 540);
      expect(w.done, isTrue);
      expect(w.percent, 100);
    });

    test('只看了 89% → 还差一点，不算完成', () {
      final w = LessonWatch(durationSec: 600);
      play(w, 500);
      expect(w.watchedSec, 500);
      expect(w.done, isFalse);
      expect(w.percent, 92);
    });

    // 🔴 反向样本：这是老口径（打开即完成）会通过的那种场景，必须被拦住。
    test('🔴 一拖到底：位置到 95% 但没真看 → 不算完成', () {
      // 场景一：走我们自己的拖动/续播接口（seekTo）后再 tick —— 一秒都不认
      final w = LessonWatch(durationSec: 600);
      w.seekTo(570);
      w.tick(playing: true, positionSec: 570, elapsedSec: 1);
      expect(w.positionSec, 570, reason: '位置确实到了 95%');
      expect(w.watchedSec, 0, reason: '跳过去的时长一秒都不算看过');
      expect(w.done, isFalse, reason: '拖出来的 95% 不能毕业');

      // 场景二：播放器自己把位置跳过去（没经过 seekTo）—— 靠 maxRate 封顶兜住
      final w2 = LessonWatch(durationSec: 600);
      w2.tick(playing: true, positionSec: 570, elapsedSec: 1);
      expect(w2.watchedSec, LessonWatchRules.maxRate,
          reason: '真实只过 1 秒，最多认 1×maxRate 秒，不是 570 秒');
      expect(w2.done, isFalse);
    });

    test('🔴 点开就退出：一秒没播 → 不算完成', () {
      final w = LessonWatch(durationSec: 600);
      w.tick(playing: false, positionSec: 0, elapsedSec: 1);
      w.tick(playing: true, positionSec: 0, elapsedSec: 1);
      expect(w.watchedSec, 0);
      expect(w.done, isFalse);
    });

    test('🔴 时长没标注 → 没有判据，done 恒为假（不许糊弄成"已完成"）', () {
      final w = LessonWatch(durationSec: 0);
      play(w, 999);
      expect(w.requiredSec, 0);
      expect(w.done, isFalse, reason: '判据缺失时宁可不放行，也不能算过');
      // 播放器报上真实时长后，判据就有了
      w.noteDuration(600);
      expect(w.requiredSec, 540);
      expect(w.watchedSec, 999);
      expect(w.done, isTrue);
    });
  });

  group('倍速与暂停', () {
    test('2 倍速：前进量全额计入（倍速不该被惩罚）', () {
      final w = LessonWatch(durationSec: 600);
      play(w, 270, rate: 2); // 270 秒真实时间 × 2 = 540 秒内容
      expect(w.watchedSec, 540);
      expect(w.done, isTrue);
    });

    test('超过倍速上限的部分不认（3 倍速只按 2 倍算）', () {
      final w = LessonWatch(durationSec: 600);
      play(w, 100, rate: 3);
      expect(w.watchedSec, 200, reason: '每秒最多认 maxRate 秒');
    });

    test('暂停时不累加', () {
      final w = LessonWatch(durationSec: 600);
      play(w, 10);
      for (var i = 0; i < 30; i++) {
        w.tick(playing: false, positionSec: w.positionSec, elapsedSec: 1);
      }
      expect(w.watchedSec, 10);
    });

    test('缓冲（位置不动）不计入', () {
      final w = LessonWatch(durationSec: 600);
      play(w, 10);
      for (var i = 0; i < 20; i++) {
        w.tick(playing: true, positionSec: 10, elapsedSec: 1);
      }
      expect(w.watchedSec, 10);
    });
  });

  group('续播', () {
    test('跳过去的片段不算看过', () {
      final w = LessonWatch(durationSec: 600);
      w.seekTo(300); // 续播到 5 分钟处
      play(w, 60);
      expect(w.watchedSec, 60, reason: '续播跳过的 5 分钟不能算已学');
      expect(w.positionSec, 360);
    });

    test('位置单调不回退（往回拖不改判据）', () {
      final w = LessonWatch(durationSec: 600);
      play(w, 100);
      w.tick(playing: true, positionSec: 10, elapsedSec: 1);
      expect(w.positionSec, 100);
    });

    test('快看完时续播从头开始（差最后几秒不该算"看完了"）', () {
      final w = LessonWatch(durationSec: 600, positionSec: 590);
      expect(w.resumeSec, 0, reason: '590/600 = 98%，超过 95% 就从头');
    });

    test('看到一半时续播接着看', () {
      final w = LessonWatch(durationSec: 600, positionSec: 300);
      expect(w.resumeSec, 300);
    });
  });

  group('口径常量', () {
    test('requiredSec 按比例取，时长为 0 时是 0', () {
      expect(LessonWatchRules.requiredSec(600), 540);
      expect(LessonWatchRules.requiredSec(0), 0);
      expect(LessonWatchRules.requiredSec(-5), 0);
    });
  });
}
