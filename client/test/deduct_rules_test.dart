import 'package:flutter_test/flutter_test.dart';
import 'package:xiaozhi_im_client/core/deduct_rules.dart';
import 'package:xiaozhi_im_client/core/inventory_rules.dart';

/// 库房减货单的纯规则层测试。
///
/// 判定本身的对错在这里定，仓库层和界面层只负责"把正确的参数喂进来"。
/// 规则出处：PG 实测文案（`docs/盘点复刻与开放接口方案-v1.md` §P3 缺口 13）。
void main() {
  DeductDecision decide({
    String barcode = '6901234567890',
    List<String> existing = const [],
    int status = InvSheetStatus.open,
    int rowCount = 0,
  }) =>
      DeductRules.decide(
        barcode: barcode,
        existingBarcodes: existing,
        sheetStatus: status,
        rowCount: rowCount,
      );

  // ============================================================
  group('单据类型', () {
    test('只认已登记的两个类型，别的一律非法', () {
      expect(InvSheetType.isValid(InvSheetType.stocktake), isTrue);
      expect(InvSheetType.isValid(InvSheetType.deduct), isTrue);
      // 反向：没做出来的类型不许悄悄通过，否则会落库一个谁也解释不了的值
      expect(InvSheetType.isValid('replenish'), isFalse,
          reason: '补货单还没做，不该被当成已支持的类型');
      expect(InvSheetType.isValid(''), isFalse);
      expect(InvSheetType.label(InvSheetType.deduct), '减货');
    });

    test('盘点的阶段常量没被动过（加类型不该影响既有口径）', () {
      expect(InvPhase.all, <int>[1, 2, 3]);
      expect(InvPhase.label(2), '复盘');
    });
  });

  // ============================================================
  group('准入判定 decide()', () {
    test('新条码 + 进行中 + 没满 → 入账，且不给任何提示', () {
      final d = decide();
      expect(d.accepted, isTrue);
      expect(d.isError, isFalse);
      // 反向：成功路径不许顺手挂句话，否则每次扫码都糊一条提示
      expect(d.message, isNull);
    });

    test('🔴 同一条码已在单内 → 拒绝，且用的是 PG 原文', () {
      final d = decide(existing: ['6901', '6901234567890']);
      expect(d.verdict, DeductVerdict.duplicate);
      expect(d.message, '减货列表已存在，请处理后重新扫码');
      expect(d.isError, isTrue);
    });

    test('条码前后带空白 → 按去掉空白后比对（扫码枪偶尔带位）', () {
      final d = decide(barcode: ' 6901234567890 ', existing: ['6901234567890']);
      expect(d.verdict, DeductVerdict.duplicate);
    });

    test('空白条码 → 当成读不到，不是"新条码可以入账"', () {
      final d = decide(barcode: '   ');
      expect(d.accepted, isFalse);
      expect(d.message, '没读到条码，请重新扫');
    });

    test('别张单里有这个码不影响本单（existingBarcodes 只给本单的）', () {
      final d = decide(barcode: 'OTHER', existing: ['6901234567890']);
      expect(d.accepted, isTrue);
    });

    test('🔴 已存在的条码不受条数上限影响（满单时重复仍报"重复"不是"超限"）', () {
      // 顺序有讲究：上限拦的是"新行"。已经存在的条码不该被上限吃掉，
      // 否则员工看到的是"上限"而不知道该去处理那一行 —— 指向了错误的动作。
      final d = decide(
        existing: ['6901234567890'],
        rowCount: DeductRules.maxRowsPerSheet,
      );
      expect(d.verdict, DeductVerdict.duplicate,
          reason: '已存在的条码不算新行，不该报"已达上限"');
    });

    test('满单 + 新条码 → 先提交', () {
      final d = decide(rowCount: DeductRules.maxRowsPerSheet);
      expect(d.verdict, DeductVerdict.limit);
      expect(d.message, '本单已达条数上限，请先提交');
    });

    test('差一行没满时仍可入账（边界）', () {
      final d = decide(rowCount: DeductRules.maxRowsPerSheet - 1);
      expect(d.accepted, isTrue);
    });

    test('已提交 / 已上传 → 锁死，且理由不能是"重复"', () {
      for (final s in [InvSheetStatus.submitted, InvSheetStatus.uploaded]) {
        final d = decide(
          existing: ['6901234567890'], // 同时命中"重复"，但锁的优先级更高
          status: s,
        );
        expect(d.verdict, DeductVerdict.sheetLocked,
            reason: '单据锁了就该说锁了，给"重复"是把人往错的方向指');
        expect(d.message, '本单已提交，不能再改');
      }
    });
  });

  // ============================================================
  group('减货数量校验 qtyError()', () {
    test('合法值一律 null', () {
      for (final v in ['1', '12', '0.5', ' 3 ', '100000']) {
        expect(DeductRules.qtyError(v), isNull, reason: '"$v" 应该合法');
      }
    });

    test('空 / 非数字 / 0 / 负数 / 过大 都要给出理由', () {
      expect(DeductRules.qtyError(''), '请输入减货数量');
      expect(DeductRules.qtyError('   '), '请输入减货数量');
      expect(DeductRules.qtyError('abc'), '减货数量只能是数字');
      expect(DeductRules.qtyError('1.2.3'), '减货数量只能是数字');
      expect(DeductRules.qtyError('0'), '减货数量必须大于 0');
      expect(DeductRules.qtyError('-3'), '减货数量必须大于 0');
      expect(DeductRules.qtyError('100001'), '减货数量过大，请确认');
    });

    test('🔴 0 不合法是刻意的：盘点的 0 有信息量，减货的 0 只是"没减"', () {
      // 盘点允许 0（"这个货架上一个都没有"本身是信息）；
      // 减货是主动的减库存动作，0 进单只会多出一行什么都没减的记录。
      // 这里只钉减货这一侧的口径 —— 不去断言盘点侧，因为那属于另一个测试文件的职责。
      expect(DeductRules.qtyError('0'), isNotNull);
      expect(DeductRules.qtyError('0.0'), isNotNull, reason: '0.0 也是没减');
    });
  });

  // ============================================================
  group('汇总 tally()', () {
    test('品种数与合计', () {
      final t = DeductRules.tally(const [
        DeductRow(barcode: 'a', qty: 2),
        DeductRow(barcode: 'b', qty: 3.5),
      ]);
      expect(t.kinds, 2);
      expect(t.totalQty, 5.5);
      expect(t.totalText, '5.5');
    });

    test('合计是整数时不带小数点', () {
      final t = DeductRules.tally(const [
        DeductRow(barcode: 'a', qty: 2),
        DeductRow(barcode: 'b', qty: 3),
      ]);
      expect(t.totalText, '5', reason: '"5.0 件" 在现场看着像出了错');
    });

    test('空单：0 种 0 件（不是 null，界面要显示得出来）', () {
      final t = DeductRules.tally(const []);
      expect(t.kinds, 0);
      expect(t.totalQty, 0);
      expect(t.totalText, '0');
    });
  });
}
