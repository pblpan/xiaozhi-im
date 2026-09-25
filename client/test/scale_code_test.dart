import 'package:flutter_test/flutter_test.dart';
import 'package:xiaozhi_im_client/core/scale_code.dart';

/// 电子秤码解析的测试。
///
/// 这一层盯的是**参数化**这件事本身：商品码位数各家软件不一样
/// （龙哥说泰格是 5 位、写在类别属性里），写死必然出错，
/// 而错的表现是"扫出来像正常条码、其实解成了别的商品"，全程不报错。
void main() {
  // 13 位 = 1 标识 + 5 商品码 + 5 重量 + 1 校验
  const code13 = '2012340125003'; // 商品码 01234，重量 01250 = 1.25 公斤

  group('形状判断', () {
    test('泰格 5 位：13 位、2 开头 → 像秤码', () {
      expect(ScaleCode.looksLike(code13), isTrue);
    });

    test('长度不对 → 不是', () {
      expect(ScaleCode.looksLike('201234012500'), isFalse); // 12 位
      expect(ScaleCode.looksLike('20123401250033'), isFalse); // 14 位
    });

    test('不是 2 开头 → 不是（那是普通商品码）', () {
      expect(ScaleCode.looksLike('3012340125003'), isFalse);
    });

    test('含非数字 → 不是', () {
      expect(ScaleCode.looksLike('20123401250a3'), isFalse);
    });

    test('🔴 位数是可配的：配 6 位就认 14 位', () {
      expect(ScaleCode.looksLike(code13, codeLen: 6), isFalse);
      expect(ScaleCode.looksLike('20123450125003', codeLen: 6), isTrue);
    });
  });

  group('解析', () {
    test('解出商品码与重量（克 → 公斤）', () {
      final r = ScaleCode.parse(code13);
      expect(r, isNotNull);
      expect(r!.plu, '01234');
      expect(r.value, 1250); // 克
      expect(r.kg, 1.25);
      expect(r.raw, code13, reason: '原始条码要留着，界面上要显示"扫到的是这个"');
    });

    test('🔴 不校验校验位（各家算法不同，硬校会把别家门店的合法码判成坏码）', () {
      final a = ScaleCode.parse('2012340125003');
      final b = ScaleCode.parse('2012340125009'); // 只改最后一位
      expect(b, isNotNull);
      expect(b!.plu, a!.plu);
      expect(b.kg, a.kg);
    });

    test('认不出来返回 null —— 不把原条码当普通商品码继续用', () {
      expect(ScaleCode.parse('6901234567890'), isNull); // 普通 13 位条码
      expect(ScaleCode.parse('abc'), isNull);
      expect(ScaleCode.parse(''), isNull);
    });

    test('位数配错 → 解不出来（而不是解出一个错的）', () {
      // 这正是"写死 5 位"会踩的坑：换了一套软件之后静默认错
      expect(ScaleCode.parse(code13, codeLen: 6), isNull);
    });

    test('金额码：不折算公斤（拿金额除单价去算是猜，猜出来的数看着也正常）', () {
      final r = ScaleCode.parse(code13, mode: ScaleCodeMode.amount);
      expect(r!.value, 1250); // 分 = 12.50 元
      expect(r.kg, isNull);
    });

    test('总长 = 位数 + 7', () {
      expect(ScaleCode.totalLen(5), 13);
      expect(ScaleCode.totalLen(6), 14);
      expect(ScaleCode.totalLen(4), 12);
    });
  });
}
