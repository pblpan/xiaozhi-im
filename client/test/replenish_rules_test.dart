import 'package:flutter_test/flutter_test.dart';
import 'package:xiaozhi_im_client/core/replenish_rules.dart';

/// 补货判定层的测试（纯函数，不碰数据库）。
///
/// 这一层盯的是**单位口径**，那是这个模块唯一容易静默出错的地方：
/// 数量记错单位不会报错，只会让"合计"变成一个看着正常、其实没法用的数。
///   · 生鲜 = 公斤，杂百 = 最小单位，**不做第三套**；
///   · 「转换公斤」只折杂百（生鲜的主单位已经是公斤，再乘换算率会得到离谱的数）；
///   · 规格里读不出克重时**留空**，绝不猜一个 1 出来。
void main() {
  group('场景与单位', () {
    test('两套单位：生鲜公斤 / 杂百最小单位', () {
      expect(ReplenishUnit.ofScene(ReplenishScene.fresh), ReplenishUnit.kg);
      expect(ReplenishUnit.ofScene(ReplenishScene.dry), ReplenishUnit.piece);
    });

    test('认不出的场景落到杂百（按最保守的最小单位记，而不是什么都记不了）', () {
      expect(ReplenishScene.normalize(''), ReplenishScene.dry);
      expect(ReplenishScene.normalize('啥也不是'), ReplenishScene.dry);
      expect(ReplenishUnit.ofScene('啥也不是'), ReplenishUnit.piece);
    });
  });

  group('数量校验', () {
    test('0 和负数都不合法', () {
      expect(ReplenishRules.parseQty('0'), isNull);
      expect(ReplenishRules.parseQty('-1'), isNull);
      expect(ReplenishRules.qtyError('0'), isNotNull);
      expect(ReplenishRules.qtyError('-3'), isNotNull);
    });

    test('小数合法（称重商品按公斤走小数）', () {
      expect(ReplenishRules.parseQty('1.25'), 1.25);
      expect(ReplenishRules.qtyError('1.25'), isNull);
    });

    test('空串和非数字被拒', () {
      expect(ReplenishRules.qtyError(''), isNotNull);
      expect(ReplenishRules.qtyError('abc'), isNotNull);
    });
  });

  group('🔴 规格 → 每件多少公斤', () {
    test('常见写法都能读出来', () {
      expect(ReplenishRules.specWeightKg('500g'), 0.5);
      expect(ReplenishRules.specWeightKg('500克'), 0.5);
      expect(ReplenishRules.specWeightKg('1.25kg'), 1.25);
      expect(ReplenishRules.specWeightKg('2斤'), 1.0);
      expect(ReplenishRules.specWeightKg('1公斤'), 1.0);
    });

    test('🔴 读不出来返回 null，**不猜 1**', () {
      // 猜 1 的话公斤合计会变得毫无意义，而且完全看不出来（没有报错）
      expect(ReplenishRules.specWeightKg(''), isNull);
      expect(ReplenishRules.specWeightKg('整箱'), isNull);
      expect(ReplenishRules.specWeightKg(null), isNull);
    });

    test('0 和负数不算合法克重', () {
      expect(ReplenishRules.specWeightKg('0g'), isNull);
    });
  });

  group('转换公斤', () {
    test('杂百：最小单位 × 每件公斤', () {
      const r = ReplenishRow(barcode: 'A', qty: 4, unitWeightKg: 0.5);
      expect(r.convertedKg, 2.0);
    });

    test('没有换算率 → null（留空，不填 0）', () {
      const r = ReplenishRow(barcode: 'A', qty: 4);
      expect(r.convertedKg, isNull);
    });
  });

  group('汇总 tally', () {
    test('生鲜：主单位就是公斤，公斤合计 = 数量合计', () {
      final t = ReplenishRules.tally(
        [
          const ReplenishRow(barcode: 'A', qty: 2, unitWeightKg: 0.5),
          const ReplenishRow(barcode: 'B', qty: 1.5),
        ],
        scene: ReplenishScene.fresh,
      );
      expect(t.kinds, 2);
      expect(t.totalQty, 3.5);
      expect(t.totalKg, 3.5, reason: '生鲜的数量本来就是公斤，不该再乘换算率');
      expect(t.unknownWeight, 0, reason: '生鲜不需要换算率，不该报"折不出"');
    });

    test('杂百：按规格折算，折不出的单独数出来', () {
      final t = ReplenishRules.tally(
        [
          const ReplenishRow(barcode: 'A', qty: 4, unitWeightKg: 0.5), // 2kg
          const ReplenishRow(barcode: 'B', qty: 3), // 没克重
        ],
        scene: ReplenishScene.dry,
      );
      expect(t.totalQty, 7.0);
      expect(t.totalKg, 2.0);
      expect(t.unknownWeight, 1,
          reason: '折不出的行数要告诉界面，否则"公斤合计偏小"会被当成算错了');
    });
  });

  group('每分钟补货', () {
    test('不到 1 分钟不给数（拿 20 秒去除会得到虚高的数）', () {
      const t = ReplenishTally(
          kinds: 3, totalQty: 30, totalKg: 0, unknownWeight: 0);
      expect(t.perMinute(20000), isNull);
    });

    test('满 1 分钟才给', () {
      const t = ReplenishTally(
          kinds: 3, totalQty: 30, totalKg: 0, unknownWeight: 0);
      expect(t.perMinute(120000), 15.0); // 30 件 / 2 分钟
    });
  });

  group('入账判定', () {
    test('同码重复 → 明确拒绝（静默覆盖会让员工以为没扫上、再扫一次）', () {
      final d = ReplenishRules.decide(
        sheetEditable: true,
        alreadyInSheet: true,
        rowCount: 1,
      );
      expect(d.accepted, isFalse);
      expect(d.verdict, ReplenishVerdict.duplicate);
    });

    test('超上限 → 拒绝', () {
      final d = ReplenishRules.decide(
        sheetEditable: true,
        alreadyInSheet: false,
        rowCount: 500,
      );
      expect(d.verdict, ReplenishVerdict.limit);
    });

    test('已提交的单 → 拒绝', () {
      final d = ReplenishRules.decide(
        sheetEditable: false,
        alreadyInSheet: false,
        rowCount: 0,
      );
      expect(d.accepted, isFalse);
    });

    test('正常情况放行', () {
      final d = ReplenishRules.decide(
        sheetEditable: true,
        alreadyInSheet: false,
        rowCount: 0,
      );
      expect(d.accepted, isTrue);
    });
  });
}
