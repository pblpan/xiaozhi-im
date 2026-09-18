import 'package:flutter_test/flutter_test.dart';
import 'package:xiaozhi_im_client/core/scan_dedup.dart';

/// 摄像头扫码去重判据的单测。
///
/// 这段逻辑的失败方式是**静默**的：判错只会让件数多算或少算，
/// 界面上不报任何错，只有盘完对账才发现对不上。所以这里逐条钉死。
///
/// 特别关注两组用例：
///   · 「连扫同一商品 3 件」—— `DetectionSpeed.noDuplicates` 会在这里做错。
///     它的官方语义是"同一个码扫过一次后，**直到扫到别的码**才能再算"，
///     结果第 2、3 件被静默吞掉。我们的判据必须让它们都算上。
///   · 「对着同一个码不动」—— 这是**相机扫码的固有缺陷**，我们消不掉，
///     只能把它限制在"冷却时间之内不重复"，并把真实行为写进断言里，
///     免得以后有人以为它是完美的。
void main() {
  /// 把一串 (码, 时间) 喂进去，返回**被接受**的那些码 —— 等价于"实际计进去的件数"。
  List<String> accept(List<(String, int)> events, {int? cooldown}) {
    final cd = cooldown ?? kSameCodeCooldownMs;
    String? lastCode;
    var lastAt = 0;
    final accepted = <String>[];
    for (final (code, t) in events) {
      if (shouldAcceptScan(
        code: code,
        lastCode: lastCode,
        lastAcceptAt: lastAt,
        now: t,
        cooldownMs: cd,
      )) {
        accepted.add(code);
        lastCode = code;
        lastAt = t;
      }
    }
    return accepted;
  }

  group('基本判据', () {
    test('第一次扫任何码都算数', () {
      expect(
        shouldAcceptScan(
            code: '6901234567890', lastCode: null, lastAcceptAt: 0, now: 100),
        isTrue,
      );
    });

    test('空码一律不算（相机偶尔会吐出空串）', () {
      expect(
        shouldAcceptScan(code: '', lastCode: null, lastAcceptAt: 0, now: 100),
        isFalse,
      );
      expect(
        shouldAcceptScan(code: '', lastCode: '', lastAcceptAt: 0, now: 99999),
        isFalse,
      );
    });

    test('换一个码，就算刚扫完上一个也立刻算数', () {
      expect(
        shouldAcceptScan(
          code: 'B',
          lastCode: 'A',
          lastAcceptAt: 1000,
          now: 1001, // 只过了 1ms
        ),
        isTrue,
        reason: '换货就该马上进，不能被上一个码的冷却拖住',
      );
    });
  });

  group('同一个码：相机还对着同一件 → 冷却期内不重复计', () {
    test('冷却期内紧跟一次 → 忽略', () {
      expect(
        shouldAcceptScan(
            code: 'A', lastCode: 'A', lastAcceptAt: 1000, now: 1200),
        isFalse,
      );
    });

    test('差 1ms 才到冷却窗口 → 仍然忽略', () {
      expect(
        shouldAcceptScan(
            code: 'A', lastCode: 'A', lastAcceptAt: 1000, now: 2199),
        isFalse,
      );
    });

    test('正好到冷却窗口 → 算数（边界取 >=）', () {
      expect(
        shouldAcceptScan(
            code: 'A', lastCode: 'A', lastAcceptAt: 1000, now: 2200),
        isTrue,
      );
    });

    test('过了冷却窗口 → 算数（这就是第二件、第三件）', () {
      expect(
        shouldAcceptScan(
            code: 'A', lastCode: 'A', lastAcceptAt: 1000, now: 3000),
        isTrue,
      );
    });
  });

  group('真实动作序列', () {
    test('连扫同一个商品的 3 件（间隔足够）→ 算 3 件', () {
      final events = <(String, int)>[
        ('A', 0), // 第 1 件
        ('A', 300), // 相机还没移开 → 忽略
        ('A', 1500), // 第 2 件
        ('A', 1700), // 忽略
        ('A', 2900), // 第 3 件
      ];
      expect(accept(events), ['A', 'A', 'A'],
          reason: '连扫同一商品的第 2、3 件必须都计进去 —— '
              'noDuplicates 在这里会只算 1 件');
    });

    test('扫 A 之后马上扫 B，两件都要算（A 的新鲜度不该影响 B）', () {
      final events = <(String, int)>[
        ('A', 0),
        ('B', 50), // 换货了，立刻算
        ('A', 100), // 又换回来 —— 上次接受的是 B，所以 A 也该算
      ];
      expect(accept(events), ['A', 'B', 'A']);
    });

    test('混着来：连停 + 换货 + 回头再扫', () {
      final events = <(String, int)>[
        ('A', 0), // A ✓
        ('A', 300), // 忽略
        ('A', 900), // 忽略
        ('B', 1000), // B ✓（换码立刻算）
        ('B', 1100), // 忽略
        ('A', 1200), // A ✓（上次接受的是 B，所以立刻算）
        ('A', 1500), // 忽略（距上次接受 300ms）
        ('A', 2500), // ✓（距上次接受 1300ms >= 1200）
      ];
      expect(accept(events), ['A', 'B', 'A', 'A']);
    });
  });

  group('已知限制：对着同一个码不动，会被按冷却周期重复计', () {
    test('对着一个码连停 3 秒 → 大约每 1.2 秒被算一次，不是只算 1 次', () {
      // 这条**不是在测试"正确行为"**，而是在把"固有缺陷"钉成可观测的事实。
      // 相机无法区分"同一个码还在画面里"和"换了一件同款"（识别结果一模一样），
      // 所以只要对着不动超过冷却时间，就会被再算一次。
      // 真正的缓解在界面上：扫中闪绿框 + 「再记 1 件」按钮 + 明确提示文案。
      final events = [for (var t = 0; t <= 3000; t += 100) ('A', t)];
      final got = accept(events);
      expect(got, ['A', 'A', 'A'],
          reason: 't=0 / 1200 / 2400 各算一次。'
              '如果哪天这条变成了 1 次，说明去重被改成了"同一个码只算一次"—— '
              '那会反过来把连扫同款第 2 件吞掉，不是改进。');
    });

    test('冷却窗口可配：设成 100ms 时同一段连停会算更多次', () {
      // 反向测试 —— 证明 cooldownMs 参数真的在起作用，
      // 而不是这个函数写了一堆条件最后恒定返回某个值。
      final events = <(String, int)>[
        ('A', 0),
        ('A', 300),
        ('A', 600),
      ];
      expect(accept(events, cooldown: 100), hasLength(3));
      expect(accept(events, cooldown: 1200), hasLength(1));
    });
  });

  group('常量取值', () {
    test('默认冷却窗口是 1200ms（改这个值要连带改上面用例的期望）', () {
      expect(kSameCodeCooldownMs, 1200);
    });

    test('不传 cooldownMs 时用的是默认值', () {
      expect(
        shouldAcceptScan(
            code: 'A', lastCode: 'A', lastAcceptAt: 0, now: 1199),
        isFalse,
      );
      expect(
        shouldAcceptScan(
            code: 'A', lastCode: 'A', lastAcceptAt: 0, now: 1200),
        isTrue,
      );
    });
  });
}
