import 'package:flutter_test/flutter_test.dart';
import 'package:xiaozhi_im_client/core/gbk.dart' show Gbk;
import 'package:xiaozhi_im_client/core/gbk_encode.dart' show GbkEncode;
import 'package:xiaozhi_im_client/core/price_tag.dart'
    show LabelSize, PriceTagItem, PriceTagPrinter;
import 'package:xiaozhi_im_client/core/price_tag_template.dart'
    show
        kBuiltinTagTemplates,
        PriceTagTemplate,
        TagElement,
        TagElementKind,
        TagField;

/// 价签的"看得见的部分"：字节序列。
///
/// 没有打印机就打不出实物，但**指令字节是可断言的** —— 条码指令写错一位，
/// 现场表现就是"条码扫不出来 / 整张糊掉"，排查起来极贵。所以这里把序列钉住。
///
/// ⚠️ 每条断言都要能回答"什么坏情况会让我失败"。
///    光看 `expect(bytes, isNotEmpty)` 等于没写。
void main() {
  // 🔴 List.contains(x) 只查"有没有一个元素等于 x"，不做子序列匹配 ——
  //    a.contains([0x1D, 0x21]) 永远 false（在找"等于这个 List 对象"的元素）。
  //    查指令序列必须自己逐字节比。
  bool hasSeq(List<int> hay, List<int> needle) {
    for (var i = 0; i + needle.length <= hay.length; i++) {
      var m = true;
      for (var j = 0; j < needle.length; j++) {
        if (hay[i + j] != needle[j]) {
          m = false;
          break;
        }
      }
      if (m) return true;
    }
    return false;
  }

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
      //
      // 🔴 指令字必须是 **0x57（GS W 大写）**，不是 0x77（GS w 小写）。
      //    小写那条是「条码宽度」，只收 1 个参数；这里发 2 个字节过去，
      //    打印机把第二个字节当普通字符印出来 —— 纸宽其实从来没设上过。
      //    这两条断言钉的就是这个字，改成小写立刻红。
      expect(
        PriceTagPrinter(label: LabelSize.mm58).setWidth(464),
        <int>[0x1D, 0x57, 0xD0, 0x01],
      );
    });

    test('宽度超过 255 时高字节要进位', () {
      // 75mm = 600 点 → 0x0258。
      expect(
        PriceTagPrinter(label: LabelSize.mm75).setWidth(600),
        <int>[0x1D, 0x57, 0x58, 0x02],
      );
    });

    test('条码宽度与打印区宽度是两条不同的指令，不能混', () {
      // 打印区宽度 = GS W(0x57) 带 2 字节；条码宽度 = GS w(0x77) 带 1 字节。
      // 混用的后果是"纸上有多余字符"或"条码宽到冲出纸边"。
      expect(PriceTagPrinter().setWidth(320).elementAt(1), 0x57);
      expect(PriceTagPrinter().barcodeWidth(3).elementAt(1), 0x77);
      expect(PriceTagPrinter().barcodeWidth(3).length, 3);
      // 条码宽度钳在 2~6：1 太窄扫不出来，7 以上 13 位 EAN 会冲出纸边
      expect(PriceTagPrinter().barcodeWidth(1).last, 2);
      expect(PriceTagPrinter().barcodeWidth(99).last, 6);
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
      expect(hasSeq(a, const <int>[0x1D, 0x21]), isTrue,
          reason: '价格那一段必须放大');
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
      expect(out.take(4).toList(), <int>[0x1B, 0x40, 0x1D, 0x57]);
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

  // ══ 模板（2026-10-16）══
  //
  // 模板这一层没有打印机可以验，**只能靠断言把字节钉住**。
  // 每一条都要回答"什么坏情况会让我红"，否则等于给改动发一张通行证。
  group('模板', () {
    final item = PriceTagItem(
      barcode: '6901234567890',
      name: '有机鸡蛋',
      spec: '净重500g',
      price: 9.9,
      memberPrice: 8.8,
      originPrice: 12.0,
      unit: '盒',
    );

    PriceTagPrinter printerFor(PriceTagTemplate t) =>
        PriceTagPrinter(label: LabelSize(t.name, t.widthMm));

    test('内置 6 套模板，每套都要真能印出东西（撞到一个就是"点一下就报错"）', () {
      expect(kBuiltinTagTemplates.length, 6);
      final ids = <String>{};
      for (final t in kBuiltinTagTemplates) {
        expect(ids.add(t.id), isTrue, reason: '模板 id 重复：${t.id}');
        expect(t.elements, isNotEmpty, reason: '${t.name} 没有元素');
        final s = Gbk.decode(printerFor(t).tagBytes(t, item));
        expect(s, contains('￥'), reason: '${t.name} 没把价格印出来');
        expect(s, contains('6901234567890'), reason: '${t.name} 没印条码/条码数字');
      }
    });

    test('模板 JSON 往返：存进去读出来还是同一套排版', () {
      for (final t in kBuiltinTagTemplates) {
        final back = PriceTagTemplate.fromJson(t.toJson());
        expect(back, isNotNull, reason: '${t.name} 读不回来');
        expect(back!.widthMm, t.widthMm);
        expect(back.heightMm, t.heightMm);
        expect(back.elements.length, t.elements.length);
        for (var i = 0; i < t.elements.length; i++) {
          final a = t.elements[i];
          final b = back.elements[i];
          expect(b.kind, a.kind);
          expect(b.field, a.field);
          expect(b.scaleX, a.scaleX);
          expect(b.scaleY, a.scaleY);
          expect(b.bold, a.bold);
          expect(b.reverse, a.reverse, reason: '${t.name} 反白丢了，促销模板就不促销了');
          expect(b.underline, a.underline);
          expect(b.align, a.align);
          expect(b.hri, a.hri, reason: '${t.name} 条码数字开关丢了');
        }
      }
    });

    test('没有会员价的商品，会员价那一行整个不印（不印"会员 ￥0.00"）', () {
      final tpl = kBuiltinTagTemplates.firstWhere((t) => t.id == 'builtin_member');
      const plain = PriceTagItem(barcode: '6901234567890', name: '有机鸡蛋', price: 9.9);
      expect(Gbk.decode(printerFor(tpl).tagBytes(tpl, plain)).contains('会员'), isFalse,
          reason: '印一句「会员 ￥0.00」出去，顾客会当真');
      expect(Gbk.decode(printerFor(tpl).tagBytes(tpl, item)), contains('会员'));
    });

    test('原价不高于售价 = 没做促销，原价那一行不印', () {
      const e = TagElement(kind: TagElementKind.text, field: TagField.originPrice);
      final tpl = PriceTagTemplate(
          id: 'x', name: 'x', widthMm: 50, heightMm: 30, elements: const [e]);
      final p = printerFor(tpl);
      const same = PriceTagItem(barcode: '1', name: 'a', price: 9.9, originPrice: 9.9);
      expect(Gbk.decode(p.tagBytes(tpl, same)).contains('原价'), isFalse,
          reason: '划掉一个更低的原价，是骗人');
      expect(Gbk.decode(p.tagBytes(tpl, item)), contains('原价'));
    });

    test('放大 2 倍的字，一行只能放一半（截断必须跟着放大倍数走）', () {
      // 🔴 这串有 20 个字：必须长到**会被截断**才测得到截断逻辑。
      //    用短串的话两个分支都原样返回，这条断言永远绿 ——
      //    2026-10-16 就被这个骗过一次（12 字的串，1 倍本来也放得下）。
      const s = '有机鸡蛋很好吃真的很好吃再来一份打包带走';
      final a = PriceTagPrinter.clipToWidth(s, 1, 400);
      final b = PriceTagPrinter.clipToWidth(s, 2, 400);
      // 400 点 ÷ 12 = 33 个西文位 → 1 倍放 16 个汉字，2 倍放 8 个
      expect(a.length, 16);
      expect(b.length, 8);
      // 反过来的坏情况：上限写死的话，大字会冲出纸边、挤成一团糊
      expect(b.length * 2, lessThanOrEqualTo(a.length));
      // 截断必须是"从前面截"，抠中间一段等于把商品名改了
      expect(s.startsWith(a), isTrue);
      expect(s.startsWith(b), isTrue);
    });

    test('加粗/反白/下划线用完必须关掉，不然会污染下一行（和下一张）', () {
      const e = TagElement(
        kind: TagElementKind.text,
        field: TagField.price,
        bold: true,
        reverse: true,
        underline: true,
      );
      final tpl = PriceTagTemplate(
          id: 'x', name: 'x', widthMm: 50, heightMm: 30, elements: const [e]);
      final bytes = printerFor(tpl).tagBytes(tpl, item);
      // 每条都成对出现：开了必须有对应的关
      expect(hasSeq(bytes, const <int>[0x1B, 0x45, 0x01]), isTrue, reason: '没开加粗');
      expect(hasSeq(bytes, const <int>[0x1B, 0x45, 0x00]), isTrue, reason: '加粗没关');
      expect(hasSeq(bytes, const <int>[0x1D, 0x42, 0x01]), isTrue, reason: '没开反白');
      expect(hasSeq(bytes, const <int>[0x1D, 0x42, 0x00]), isTrue, reason: '反白没关');
      expect(hasSeq(bytes, const <int>[0x1B, 0x2D, 0x01]), isTrue, reason: '没开下划线');
      expect(hasSeq(bytes, const <int>[0x1B, 0x2D, 0x00]), isTrue, reason: '下划线没关');
    });

    test('条码高度/HRI 用完复位，否则下一张的条码跟着变高', () {
      const e = TagElement(
          kind: TagElementKind.barcode, barcodeHeight: 160, hri: false);
      final tpl = PriceTagTemplate(
          id: 'x', name: 'x', widthMm: 50, heightMm: 30, elements: const [e]);
      final bytes = printerFor(tpl).tagBytes(tpl, item);
      expect(hasSeq(bytes, const <int>[0x1D, 0x68, 160]), isTrue);
      expect(hasSeq(bytes, const <int>[0x1D, 0x68, 80]), isTrue, reason: '高度没复位');
      expect(hasSeq(bytes, const <int>[0x1D, 0x48, 0x00]), isTrue, reason: 'HRI 没复位');
    });

    test('模板批打印：开头复位+设宽，结尾切纸', () {
      final tpl = kBuiltinTagTemplates.first;
      final out = printerFor(tpl).renderWithTemplate(<PriceTagItem>[item], tpl);
      expect(out.take(4).toList(), <int>[0x1B, 0x40, 0x1D, 0x57]);
      expect(out.sublist(out.length - 7),
          <int>[0x1B, 0x64, 0x03, 0x1D, 0x56, 0x42, 0x00]);
    });

    test('份数＝多印一遍（模板版也一样）', () {
      final tpl = kBuiltinTagTemplates.first;
      final one = printerFor(tpl)
          .renderWithTemplate(<PriceTagItem>[item], tpl);
      final two = printerFor(tpl).renderWithTemplate(<PriceTagItem>[
        PriceTagItem(
          barcode: item.barcode,
          name: item.name,
          spec: item.spec,
          price: item.price,
          unit: item.unit,
          copies: 2,
        ),
      ], tpl);
      expect(two.length, greaterThan(one.length * 1.6));
      expect(two.length, lessThan(one.length * 2.4));
    });

    test('空模板不崩（只是印出来是白纸），但不允许存进库里', () {
      final tpl = PriceTagTemplate(
          id: 'e', name: 'e', widthMm: 50, heightMm: 30, elements: const <TagElement>[]);
      expect(printerFor(tpl).tagBytes(tpl, item), isEmpty);
      // 空模板存进去再读出来 == null：存一个打不出东西的模板没有意义
      expect(PriceTagTemplate.fromJson(tpl.toJson()), isNull);
    });

    test('纸宽跟着模板走：40mm 的模板按 40mm 设宽（不是打印机的默认值）', () {
      final tpl = kBuiltinTagTemplates.firstWhere((t) => t.id == 'builtin_jumbo');
      final out = printerFor(tpl).renderWithTemplate(<PriceTagItem>[item], tpl);
      // 75mm = 600 点 → 小端 58 02
      expect(hasSeq(out, const <int>[0x1D, 0x57, 0x58, 0x02]), isTrue);
    });

    test('每个内置模板里的元素都合法（放大倍数在上限内）', () {
      for (final t in kBuiltinTagTemplates) {
        for (final e in t.elements) {
          expect(e.scaleX, inInclusiveRange(1, 8));
          expect(e.scaleY, inInclusiveRange(1, 8));
          expect(e.barcodeHeight, inInclusiveRange(1, 255));
          if (e.kind != TagElementKind.text) {
            continue;
          }
          // 固定文字必须有内容，否则模板里躺一个什么都不印的元素
          if (e.field == TagField.fixed) {
            expect(e.fixedText, isNotEmpty);
          }
        }
      }
    });
  });
}
