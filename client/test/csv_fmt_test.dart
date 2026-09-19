import 'package:flutter_test/flutter_test.dart';
import 'package:xiaozhi_im_client/core/csv_fmt.dart';

/// CSV 落盘格式的单测（扫码枪与盘点共用同一份）。
///
/// 重点是**条码列**：龙哥 2026-09-19 报"导出来的条码栏是乱码"。
/// 真因不是编码 —— BOM 一直在 —— 是 Excel 把 13 位数字条码当成了数值，
/// 显示成科学计数法 `6.92182E+12`（看着就是乱码），超过 15 位还会把末尾置零。
void main() {
  group('barcodeCsvCell：长数字条码要写成 Excel 认得的文本', () {
    test('13 位 EAN-13 → ="条码"', () {
      expect(barcodeCsvCell('6921817824327'), '="6921817824327"');
    });

    test('12 位 UPC-A 也要保护', () {
      expect(barcodeCsvCell('092117800680'), '="092117800680"',
          reason: '前导零开头的最容易被当数值，0 还会被吃掉');
    });

    test('🔴 边界：11 位（含）以上才保护', () {
      expect(barcodeCsvCell('12345678901'), '="12345678901"',
          reason: '11 位是 Excel 开始转科学计数法的量级');
      expect(barcodeCsvCell('1234567890'), '1234567890',
          reason: '10 位及以下会正常显示，加了公式反而平白变脏');
    });

    test('含字母的条码不加公式（Excel 本来就不会当数值）', () {
      expect(barcodeCsvCell('AB-6901'), 'AB-6901');
      expect(barcodeCsvCell('6901x'), '6901x');
    });

    test('空值 / null 不炸，给空串', () {
      expect(barcodeCsvCell(null), '');
      expect(barcodeCsvCell(''), '');
    });

    test('数字类型（不是字符串）也认得出来', () {
      expect(barcodeCsvCell(6921817824327), '="6921817824327"');
    });
  });

  group('csvEsc：转义', () {
    test('含逗号 → 整体加引号', () {
      expect(csvEsc('苹果,红富士'), '"苹果,红富士"');
    });

    test('含引号 → 加引号且内部引号翻倍', () {
      expect(csvEsc('牛奶"特惠"'), '"牛奶""特惠"""');
    });

    test('含换行 → 加引号', () {
      expect(csvEsc('a\nb'), '"a\nb"');
    });

    test('普通值不动', () {
      expect(csvEsc('矿泉水'), '矿泉水');
      expect(csvEsc(12), '12');
    });
  });

  group('两个函数叠起来（调用顺序：先 barcodeCsvCell 再 csvEsc）', () {
    test('长数字条码落进 CSV 后的**真实字节**', () {
      final cell = csvEsc(barcodeCsvCell('6921817824327'));
      expect(cell, '"=""6921817824327"""',
          reason: 'Excel 读到这一格会求值成文本 6921817824327');
    });

    test('🔴 加了公式就必须再转义 —— 否则 CSV 里出现裸引号', () {
      final raw = barcodeCsvCell('6921817824327');
      expect(raw.contains('"'), isTrue, reason: '公式本身带引号');
      // 裸着写进 CSV 的话，这一格以 `=` 开头又带引号，
      // 各家的 CSV 解析器行为不一致（有的当公式、有的当普通文本），
      // 唯一各家一致的就是标准转义写法。
      expect(csvEsc(raw).startsWith('"'), isTrue,
          reason: '转义后必须是被引号包起来的字段');
    });
  });
}
