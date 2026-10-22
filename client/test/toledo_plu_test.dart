import 'package:flutter_test/flutter_test.dart';
import 'package:xiaozhi_im_client/core/toledo_plu.dart';

/// 托利多 RL00 格式的单测。
///
/// 重点盯三类错误，它们都是"不报错但数据是错的"那一类：
///   ① 字段数/顺序错 → SPCT 直接判无效记录或把价格读成品名；
///   ② 斤价没换算成千克价 → 顾客按一半价格结账（单价单位是元/千克！）；
///   ③ 编码不是 GBK → 导入成功但商品名全是乱码。
void main() {
  group('字段布局：14 个逗号分隔字段 + 行尾逗号 + CRLF', () {
    test('规格示例同构：一条记录的精确字节形状', () {
      final b = ToledoPlu.build([
        const ToledoRow(barcode: '6921817824327', name: '金沙猪扒', price: 21.60, unit: '斤'),
      ], variant: 'txt');
      // PLU=1(seq) 货号=条码 组=0 单价=43.20(斤价×2=元/千克) 皮=0 成分=0 税=0
      // 保质=0 推荐=0 固定重量=0.000 计价=0(斤=计重) 改价=0 打折=0 名称 行尾逗号
      expect(b.rowCount, 1);
      expect(b.text, '1,6921817824327,0,43.20,0,0,0,0,0,0.000,0,0,0,金沙猪扒,\r\n');
    });

    test('计数商品：计价方式=1、单价不换算', () {
      final b = ToledoPlu.build([
        const ToledoRow(barcode: '6901234567890', name: '可口可乐', price: 3.50, unit: '瓶'),
      ], variant: 'txt');
      expect(b.text, '1,6901234567890,0,3.50,0,0,0,0,0,0.000,1,0,0,可口可乐,\r\n');
    });

    test('.plu 变体首行是魔数；.txt 变体没有', () {
      const rows = [ToledoRow(barcode: '1', name: '甲', price: 1, unit: '个')];
      final plu = ToledoPlu.build(rows, variant: 'plu');
      final txt = ToledoPlu.build(rows, variant: 'txt');
      expect(plu.text.startsWith('MTCN_RL00_4.1_ETH_PLU\r\n'), isTrue);
      expect(txt.text.startsWith('MTCN_RL00_4.1_ETH_PLU'), isFalse);
    });

    test('每条记录都以 CRLF 结尾（Windows/SPCT 生态的换行）', () {
      final b = ToledoPlu.build(const [
        ToledoRow(barcode: '1', name: '甲', price: 1, unit: '个'),
        ToledoRow(barcode: '2', name: '乙', price: 1, unit: '个'),
      ], variant: 'txt');
      expect(b.text.split('\r\n').length - 1, 2, reason: '两条记录 = 两个 CRLF');
      expect(b.text.contains('\n\n'), isFalse, reason: '不许出现孤 LF');
    });
  });

  group('PLU 号', () {
    test('seq 模式：按有效记录从 1 连续编号', () {
      final b = ToledoPlu.build(const [
        ToledoRow(barcode: 'a', name: '甲', price: 1),
        ToledoRow(barcode: 'b', name: '乙', price: 1),
      ], variant: 'txt');
      expect(b.text.split('\r\n')[0].split(',')[0], '1');
      expect(b.text.split('\r\n')[1].split(',')[0], '2');
    });

    test('barcode_tail 模式：取条码后 6 位', () {
      final b = ToledoPlu.build(const [
        ToledoRow(barcode: '9900891', name: '金沙猪扒', price: 21.60),
      ], variant: 'txt', params: const ToledoParams(pluMode: 'barcode_tail'));
      expect(b.text.split(',')[0], '900891');
    });

    test('barcode_tail 兜底：非数字/太短/尾 6 位为 0 → 回落 seq', () {
      final b = ToledoPlu.build(const [
        ToledoRow(barcode: 'AB-12', name: '甲', price: 1),
        ToledoRow(barcode: '000000', name: '乙', price: 1),
      ], variant: 'txt', params: const ToledoParams(pluMode: 'barcode_tail'));
      final lines = b.text.split('\r\n')..removeLast();
      expect(lines[0].split(',')[0], '1');
      expect(lines[1].split(',')[0], '2');
    });
  });

  group('货号（≤13 位）', () {
    test('13 位 EAN 原样搬', () {
      final b = ToledoPlu.build(const [
        ToledoRow(barcode: '6921817824327', name: 'x', price: 1),
      ], variant: 'txt');
      expect(b.text.split(',')[1], '6921817824327');
    });

    test('超 13 位取后 13 位；非数字给 0', () {
      final b = ToledoPlu.build(const [
        ToledoRow(barcode: '123456789012345678', name: 'x', price: 1),
        ToledoRow(barcode: 'ABC', name: 'y', price: 1),
      ], variant: 'txt');
      final lines = b.text.split('\r\n')..removeLast();
      expect(lines[0].split(',')[1], '6789012345678',
          reason: '18 位条码取后 13 位');
      expect(lines[1].split(',')[1], '0');
    });
  });

  group('单价：元/千克口径', () {
    test('斤价自动 ×2（否则顾客按半价结账）', () {
      for (final u in ['斤', '500g', '500克', '两']) {
        final b = ToledoPlu.build([
          ToledoRow(barcode: '1', name: 'x', price: 10.00, unit: u),
        ], variant: 'txt');
        expect(b.text.split(',')[3], '20.00', reason: '单位 $u 应按 500 克报价');
      }
    });

    test('千克家族不换算', () {
      for (final u in ['千克', '公斤', 'kg', 'KG', 'g', '克']) {
        final b = ToledoPlu.build([
          ToledoRow(barcode: '1', name: 'x', price: 10.00, unit: u),
        ], variant: 'txt');
        expect(b.text.split(',')[3], '10.00', reason: '单位 $u 已是千克口径');
      }
    });

    test('负价归 0；超 9999.99 截断；两位小数', () {
      final b = ToledoPlu.build(const [
        ToledoRow(barcode: '1', name: 'x', price: -5),
        ToledoRow(barcode: '2', name: 'y', price: 12345.678),
        ToledoRow(barcode: '3', name: 'z', price: 3),
      ], variant: 'txt');
      final lines = b.text.split('\r\n')..removeLast();
      expect(lines[0].split(',')[3], '0.00');
      expect(lines[1].split(',')[3], '9999.99');
      expect(lines[2].split(',')[3], '3.00');
    });
  });

  group('计价方式（必有字段）', () {
    test('auto：计数单位 → 1，其余 → 0，空单位 → 0', () {
      final b = ToledoPlu.build(const [
        ToledoRow(barcode: '1', name: 'a', price: 1, unit: '个'),
        ToledoRow(barcode: '2', name: 'b', price: 1, unit: '瓶'),
        ToledoRow(barcode: '3', name: 'c', price: 1, unit: '斤'),
        ToledoRow(barcode: '4', name: 'd', price: 1, unit: ''),
      ], variant: 'txt');
      final lines = b.text.split('\r\n')..removeLast();
      expect(lines.map((l) => l.split(',')[10]).toList(), ['1', '1', '0', '0']);
    });

    test('weight/count 强制覆盖单位判断', () {
      const rows = [ToledoRow(barcode: '1', name: 'a', price: 1, unit: '个')];
      expect(ToledoPlu.build(rows, variant: 'txt', params: const ToledoParams(priceMode: 'weight')).text.split(',')[10], '0');
      expect(ToledoPlu.build(rows, variant: 'txt', params: const ToledoParams(priceMode: 'count')).text.split(',')[10], '1');
    });
  });

  group('商品名称（必有字段）', () {
    test('含逗号会撕裂格式 → 换全角', () {
      final b = ToledoPlu.build(const [
        ToledoRow(barcode: '1', name: '苹果,红富士', price: 1),
      ], variant: 'txt');
      expect(b.text.split(',').length, 15, reason: '14 字段 + 行尾逗号 = 15 段');
      expect(b.text.contains('苹果，红富士'), isTrue);
    });

    test('超 14 个 rune 截断', () {
      final b = ToledoPlu.build(const [
        ToledoRow(barcode: '1', name: '一二三四五六七八九十壹贰叁肆伍', price: 1),
      ], variant: 'txt');
      final name = b.text.split('\r\n')[0].split(',').sublist(13, 14)[0];
      expect(name.runes.length, 14);
    });

    test('空名用条码兜底；连条码也空 → 跳过且不计入行数', () {
      final b = ToledoPlu.build(const [
        ToledoRow(barcode: '6901234', name: '', price: 1),
        ToledoRow(barcode: '', name: '', price: 1),
      ], variant: 'txt');
      expect(b.rowCount, 1);
      expect(b.text.contains('6901234,'), isTrue);
    });
  });

  group('GBK 编码（不是 UTF-8）', () {
    test('中 → D6 D0（GBK 码位，UTF-8 会是 E4 B8 AD）', () {
      final b = ToledoPlu.build(const [
        ToledoRow(barcode: '1', name: '中', price: 1),
      ], variant: 'txt');
      expect(b.bytes.contains(0xD6) && b.bytes.contains(0xD0), isTrue);
      expect(b.bytes.contains(0xE4), isFalse, reason: '绝不允许出现 UTF-8 的字节');
    });

    test('编不出的字符记进 missedNames，字节里落 ?（0x3F）', () {
      final b = ToledoPlu.build(const [
        ToledoRow(barcode: '1', name: '测试😀字符', price: 1),
      ], variant: 'txt');
      expect(b.missedNames, 1);
      expect(b.bytes.contains(0x3F), isTrue);
    });

    test('无 BOM（GBK 文件带头 BOM 反而会让 SPCT 读错首字段）', () {
      final b = ToledoPlu.build(const [
        ToledoRow(barcode: '1', name: '甲', price: 1),
      ], variant: 'plu');
      expect(b.bytes.take(3).toList(), isNot([0xEF, 0xBB, 0xBF]));
      expect(b.bytes.take(4).toList(), 'MTCN'.codeUnits);
    });
  });

  group('参数解析（服务端下发 / 本地存储还原）', () {
    test('null / 脏值回落默认', () {
      expect(ToledoParams.fromJson(null).pluMode, 'seq');
      final dirty = ToledoParams.fromJson({
        'pluMode': 'magic', 'group': 99, 'tax': -3, 'priceMode': 'magic',
      });
      expect(dirty.pluMode, 'seq');
      expect(dirty.group, 20, reason: '超上限截断到合法最大值');
      expect(dirty.tax, 0);
      expect(dirty.priceMode, 'auto');
    });

    test('合法值全量往返（不携带 variant：它由格式 id 决定）', () {
      const p = ToledoParams(
        pluMode: 'barcode_tail', group: 3, tare: 2, tax: 1,
        shelfLife: 30, recommendLife: 7, priceMode: 'count',
        allowReprice: 1, allowDiscount: 1,
      );
      expect(ToledoParams.fromJson(p.toJson()).toJson(), p.toJson());
      expect(p.toJson().containsKey('variant'), isFalse);
    });
  });

  group('文件名', () {
    test('场景 + 单号 + 托利多 + 扩展名随 variant', () {
      expect(ToledoPlu.fileName('门店盘点', 'PD-001', variant: 'plu'),
          '门店盘点_PD-001_托利多.plu');
      expect(ToledoPlu.fileName('门店盘点', 'PD-001', variant: 'txt'),
          '门店盘点_PD-001_托利多.txt');
    });

    test('非法文件名字符被替换；空场景/单号不出现多余下划线', () {
      expect(ToledoPlu.fileName('a/b:c', '', variant: 'plu'), 'a_b_c_托利多.plu');
      expect(ToledoPlu.fileName('', '', variant: 'plu'), '托利多.plu');
    });
  });
}
