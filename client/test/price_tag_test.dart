import 'package:flutter_test/flutter_test.dart';
import 'package:xiaozhi_im_client/core/gbk.dart' show Gbk;
import 'package:xiaozhi_im_client/core/gbk_encode.dart' show GbkEncode;
import 'package:xiaozhi_im_client/core/price_tag.dart'
    show LabelSize, PriceTagItem, PriceTagPrinter;

/// 价签的"看得见的部分"：字节序列。
///
/// 没有打印机就打不出实物，但**指令字节是可断言的** —— 条码指令写错一位，
/// 现场表现就是"条码扫不出来 / 整张糊掉"，排查起来极贵。所以这里把序列钉住。
///
/// ⚠️ 每条断言都要能回答"什么坏情况会让我失败"。
///    光看 `expect(bytes, isNotEmpty)` 等于没写。
void main() {
  group('GBK 编码', () {
    test('中文按 GBK 双字节出，不是把一个汉字拆成两个问号', () {
      // 「中」= 0xD6D0、「文」= 0xCEC4 —— 这是 GBK 标准码，也是打印机的期待。
      expect(GbkEncode.encode('中文'), <int>[0xD6, 0xD0, 0xCE, 0xC4]);
    });

    test('数字和符号保持单字节 ASCII', () {
      expect(GbkEncode.encode('12.90'), <int>[0x31, 0x32, 0x2E, 0x39, 0x30]);
    });

    test('价格符号是给它编码而不是直接跳过的', () {
      // fmtPrice 出来的 "￥12.90"：￥ 在 GBK 里是双字节 0xA3A4。
      expect(
        GbkEncode.encode(PriceTagPrinter.fmtPrice(12.9)),
        <int>[0xA3, 0xA4, 0x31, 0x32, 0x2E, 0x39, 0x30],
      );
    });

    test('编出来的字节能被 GBK 解码器原样读回（编码表不能长歪）', () {
      const s = '有机鸡蛋 净重500g ￥9.90';
      final back = Gbk.decode(GbkEncode.encode(s));
      expect(back, s);
    });

    test('反向：编不进去的字符报 miss，且被换成问号而不是丢掉', () {
      // U+E000 是私用区，GBK 表里没有。
      expect(GbkEncode.canEncode('中'), isTrue);
      expect(GbkEncode.canEncode('中㌀'), isFalse);
      expect(GbkEncode.missCount('中㌀'), 1);
      expect(GbkEncode.encode('中㌀').length, 3); // 2 + 1 个 0x3F
      expect(GbkEncode.encode('中㌀').last, 0x3F);
    });
  });

  group('ESC/POS 指令', () {
    test('初始化复位打印机', () {
      expect(PriceTagPrinter().init(), <int>[0x1B, 0x40]);
    });

    test('58mm 的纸必须显式设宽度，否则右边打不出来', () {
      // 58 × 8 点/mm = 464 → 小端两字节 D0 01。
      expect(
        PriceTagPrinter(label: LabelSize.mm58).setWidth(464),
        <int>[0x1D, 0x77, 0xD0, 0x01],
      );
    });

    test('宽度超过 255 时高字节要进位', () {
      // 75mm = 600 点 → 0x0258。
      expect(
        PriceTagPrinter(label: LabelSize.mm75).setWidth(600),
        <int>[0x1D, 0x77, 0x58, 0x02],
      );
    });

    test('放大倍数的 x 在低 4 位、y 在高 4 位', () {
      final p = PriceTagPrinter();
      // x=2, y=3 → 1 | (2 << 4) = 0x21
      expect(p.scale(x: 2, y: 3), <int>[0x1D, 0x21, 0x21]);
      // x=3, y=2 → 2 | (1 << 4) = 0x12
      expect(p.scale(x: 3, y: 2), <int>[0x1D, 0x21, 0x12]);
    });

    test('切纸：先走纸再切', () {
      expect(
        PriceTagPrinter().cut(),
        <int>[0x1B, 0x64, 0x03, 0x1D, 0x56, 0x42, 0x00],
      );
    });

    test('条码指令的长度 n 不含控制头（这里没带头）', () {
      const code = '6901234567890';
      final b = PriceTagPrinter().barcode(code);
      expect(b.sublist(0, 4), <int>[0x1D, 0x6B, 73, code.length]);
      expect(b.length, 4 + code.length + 1); // 指令头 + 数据 + NUL
      expect(b.last, 0); // 必须以 NUL 收尾
    });

    test('切纸之前不能少走纸（少了就切在半张上）', () {
      final p = PriceTagPrinter();
      // 走纸 3 个单位 = ESC d 3，必须出现在 GS V 之前。
      final bytes = <int>[...p.feed(1), ...p.cut()];
      final feedAt = bytes.indexOf(0x64);
      expect(feedAt, greaterThanOrEqualTo(0));
      expect(bytes.indexOf(0x56), greaterThan(feedAt));
    });
  });

  group('排版', () {
    final item = PriceTagItem(
      barcode: '6901234567890',
      name: '有机鸡蛋',
      spec: '净重500g',
      price: 9.9,
      unit: '元',
    );

    test('一张标签：名称 → 规格 → 放大价格 → 条码 → 条码号', () {
      final p = PriceTagPrinter(label: LabelSize.mm58);
      final a = p.renderTag(
        code: item.barcode,
        name: item.name,
        price: item.price,
        spec: item.spec,
        unit: item.unit,
      );
      // 🔴 不能用 String.fromCharCodes：那是把每个 GBK 字节当一个字符看，
      //    中文永远拼不回来 —— 必须先用 Gbk.decode 解回文本再断言。
      final s = Gbk.decode(a);
      // 顺序钉住：谁把"条码"排到"价格"前面，这条立刻红。
      expect(s.indexOf('有机鸡蛋'), greaterThan(-1),
          reason: '商品名必须真的在字节流里（GBK 解得回来）');
      expect(s.indexOf('有机鸡蛋'), lessThan(s.indexOf('￥9.90')));
      expect(s.indexOf('￥9.90'), lessThan(s.indexOf('6901234567890', 10)));
      expect(a.contains(<int>[0x1D, 0x21]), isTrue, reason: '价格那一段必须放大');
    });

    test('放大完必须复位，否则条码也被放大', () {
      final p = PriceTagPrinter();
      final a = p.renderTag(
        code: '6901234567890',
        name: 'x',
        price: 1,
      );
      // 放大指令出现 1 次、复位指令出现 1 次（GS ! 1 即 n=0x00 复位）。
      expect(a.where((b) => b == 0x21).length, 2,
          reason: '一次放大 + 一次复位');
    });

    test('一整批：开头复位+设宽，结尾切纸', () {
      final p = PriceTagPrinter(label: LabelSize.mm58);
      final out = p.render(<PriceTagItem>[item]);
      expect(out.sublist(0, 3), <int>[0x1B, 0x40, 0x1D]);
      expect(out.take(4).toList(), <int>[0x1B, 0x40, 0x1D, 0x77]);
      expect(out.sublist(out.length - 7), <int>[0x1B, 0x64, 0x03, 0x1D, 0x56, 0x42, 0x00]);
    });

    test('多份＝多印一遍，不是在一张里重复', () {
      final one = PriceTagPrinter().render(<PriceTagItem>[item]);
      final two = PriceTagPrinter().render(<PriceTagItem>[
        PriceTagItem(
          barcode: item.barcode,
          name: item.name,
          spec: item.spec,
          price: item.price,
          unit: item.unit,
          copies: 2,
        ),
      ]);
      // 两份的字节数 ≈ 单份 × 2（只多一个结束符之差，所以给个宽松但非恒真的上下界）。
      expect(two.length, greaterThan(one.length * 1.8));
      expect(two.length, lessThan(one.length * 2.2));
    });

    test('没有规格时，称重商品把单位顶上去（不能什么都不印）', () {
      final p = PriceTagPrinter();
      final a = p.renderTag(
        code: '6900000000001',
        name: '五花肉',
        price: 23.5,
        spec: '',
        unit: 'kg',
      );
      expect(String.fromCharCodes(a), contains('kg'));
    });

    test('单位是「元」时不重复印单位', () {
      final p = PriceTagPrinter();
      final a = p.renderTag(
        code: '6900000000002',
        name: '矿泉水',
        price: 2,
        spec: '',
        unit: '元',
      );
      // 🔴 先解回文本再断言 —— 对 GBK 字节流直接 indexOf 中文恒为 -1，
      //    那是"永远绿"的假断言，什么坏情况都抓不到。
      final s = Gbk.decode(a);
      expect(s.indexOf('元'), -1, reason: '价格已经带 ￥，再来一个「元」是废字');
    });

    test('价格不做四舍五入，分位照打', () {
      expect(PriceTagPrinter.fmtPrice(9.9), '￥9.90');
      expect(PriceTagPrinter.fmtPrice(12), '￥12.00');
      expect(PriceTagPrinter.fmtPrice(0.05), '￥0.05');
    });
  });

  group('预览', () {
    test('屏幕上的样子要跟纸上的对得上（规格/条码/价格都进得了预览）', () {
      final p = PriceTagPrinter();
      final pv = p.preview(<PriceTagItem>[
        PriceTagItem(
          barcode: '6901234567890',
          name: '有机鸡蛋',
          spec: '净重500g',
          price: 9.9,
        ),
      ], header: '今日特价');
      expect(pv, contains('今日特价'));
      expect(pv, contains('有机鸡蛋'));
      expect(pv, contains('净重500g'));
      expect(pv, contains('6901234567890'));
      expect(pv, contains('￥9.90'));
    });
  });
}
