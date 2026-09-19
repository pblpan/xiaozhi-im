import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:xiaozhi_scanner/core/csv_fmt.dart';
import 'package:xiaozhi_scanner/core/gbk.dart';
import 'package:xiaozhi_scanner/core/stock_master_repo.dart';
import 'package:xiaozhi_scanner/core/stocktake_export.dart';

/// 商档 CSV 导入 + GBK 解码 + 导出条码保护。
///
/// ── 这些测试为什么都盯"具体值"而不是"非空" ──────────────────────
/// 这一段的坏法全都**不报错**：
///   · GBK 表下标错一格 → 解出来是一片看着像中文的错字；
///   · 表头别名没认出来 → 商品名全空，但条码还在（"导入成功了，只是没名字"）；
///   · `="..."` 没剥 → 条码变成一坨，一条都对不上账；
///   · 条码保护漏了 → Excel 打开变科学计数法。
/// 写 `expect(items, isNotEmpty)` 这类断言，上面每一种都能"通过"。
/// 所以这里一律钉具体字符串/具体条数。
void main() {
  group('GBK 解码', () {
    test('码表能把 GBK 字节还原成中文', () {
      // 商品 / 苹果 / 红富士 / 袋 的 GBK 编码（构建本测试时用 Python 算出来的）
      final bytes = <int>[
        0xC9, 0xCC, 0xC6, 0xB7, // 商品
        0xC6, 0xBB, 0xB9, 0xFB, // 苹果
        0xBA, 0xEC, 0xB8, 0xBB, 0xCA, 0xBF, // 红富士
        0xB4, 0xFC, // 袋
      ];
      expect(Gbk.decode(bytes), '商品苹果红富士袋');
    });

    test('ASCII 与中文混排', () {
      // "小智扫码枪" + 空格 + "A1"
      final bytes = <int>[
        0xD0, 0xA1, 0xD6, 0xC7, 0xC9, 0xA8, 0xC2, 0xEB, 0xC7, 0xB9,
        0x20, 0x41, 0x31,
      ];
      expect(Gbk.decode(bytes), '小智扫码枪 A1');
    });

    test('0x7F 不是合法尾字节 —— 把它算进去会让后面整张表错位', () {
      expect(Gbk.isTrail(0x7F), isFalse);
      expect(Gbk.isTrail(0x7E), isTrue);
      expect(Gbk.isTrail(0x80), isTrue);
      // 0xC9 0x7F 不是合法组合：C9 要吐一个替换字符，0x7F 是 ASCII 的 DEL
      expect(Gbk.decode(<int>[0xC9, 0x7F]), '\uFFFD\u007F');
    });

    test('残缺字节不吞、不死循环', () {
      // 结尾只有一个首字节，没有尾字节
      expect(Gbk.decode(<int>[0xC9]), '\uFFFD');
      // 连续两个坏字节 → 两个替换字符（说明每次都前进了）
      expect(Gbk.decode(<int>[0x80, 0x81]), '\uFFFD\uFFFD');
    });

    test('decodeSmart：UTF-8 走 UTF-8，GBK 走 GBK', () {
      const s = '红富士苹果 500g';
      expect(Gbk.decodeSmart(utf8.encode(s)), s);
      // 同一句话的 GBK 字节
      final gbkBytes = <int>[
        0xBA, 0xEC, 0xB8, 0xBB, 0xCA, 0xBF, // 红富士
        0xC6, 0xBB, 0xB9, 0xFB, // 苹果
        0x20, 0x35, 0x30, 0x30, 0x67,
      ];
      expect(Gbk.decodeSmart(gbkBytes), s);
    });
  });

  group('商档 CSV 解析', () {
    test('标准表头 + 全部列', () {
      final r = MasterCsv.parse(
        '条码,品名,规格,单位,售价,账面数\r\n'
        '6921817824327,康师傅冰红茶,500ml,瓶,3.5,48\r\n'
        '6901234567892,红富士苹果,500g,袋,12.5,30\r\n',
      );
      expect(r.items.length, 2);
      expect(r.skipped, 0);
      final a = r.items[0];
      expect(a['barcode'], '6921817824327');
      expect(a['name'], '康师傅冰红茶');
      expect(a['spec'], '500ml');
      expect(a['unit'], '瓶');
      expect(a['unit_price'], 3.5);
      expect(a['account_qty'], 48.0);
    });

    test('表头别名：商品条码 / 商品名称 / 零售价 / 库存', () {
      final r = MasterCsv.parse(
        '商品条码,商品名称,零售价,库存\n'
        '6921817824327,冰红茶,3.5,48\n',
      );
      expect(r.items.length, 1);
      expect(r.items[0]['name'], '冰红茶');
      expect(r.items[0]['unit_price'], 3.5);
      expect(r.items[0]['account_qty'], 48.0);
    });

    test('UTF-8 BOM 不会把第一列名带歪', () {
      final r = MasterCsv.parse(
        '\uFEFF条码,品名\n6921817824327,冰红茶\n',
      );
      // BOM 没剥掉的话，第一个列名是 "\uFEFF条码"，别名认不出 →
      // 条码列整体丢失 → items 为空。这条测试就是钉这个。
      expect(r.items.length, 1);
      expect(r.items[0]['barcode'], '6921817824327');
    });

    test('剥掉 Excel 的 ="..." 文本公式（我们自己导出的条码就是这个形状）', () {
      final r = MasterCsv.parse(
        '条码,品名\n'
        '="6921817824327",冰红茶\n',
      );
      expect(r.items.length, 1);
      expect(r.items[0]['barcode'], '6921817824327');
    });

    test('引号里的逗号不会把列冲掉', () {
      final r = MasterCsv.parse(
        '条码,品名,规格\n'
        '6921817824327,"苹果,红富士",500g\n',
      );
      expect(r.items.length, 1);
      expect(r.items[0]['name'], '苹果,红富士');
      expect(r.items[0]['spec'], '500g');
    });

    test('引号里的换行也不拆行', () {
      final r = MasterCsv.parse(
        '条码,品名\n'
        '6921817824327,"冰红茶\n大瓶装"\n',
      );
      expect(r.items.length, 1);
      expect(r.items[0]['name'], '冰红茶\n大瓶装');
    });

    test('分号分隔（欧版 Excel）自动认', () {
      final r = MasterCsv.parse(
        '条码;品名;售价\n6921817824327;冰红茶;3.5\n',
      );
      expect(r.items.length, 1);
      expect(r.items[0]['name'], '冰红茶');
      expect(r.items[0]['unit_price'], 3.5);
    });

    test('没有表头时按模板列序读', () {
      final r = MasterCsv.parse(
        '6921817824327,冰红茶,500ml,瓶,3.5,48\n',
      );
      expect(r.items.length, 1);
      expect(r.items[0]['name'], '冰红茶');
      expect(r.items[0]['unit'], '瓶');
      expect(r.items[0]['account_qty'], 48.0);
    });

    test('条码为空的行被跳过，并且计数报出来', () {
      final r = MasterCsv.parse(
        '条码,品名\n'
        '6921817824327,冰红茶\n'
        ',没有条码的商品\n'
        '6901234567892,苹果\n',
      );
      expect(r.items.length, 2);
      expect(r.skipped, 1);
      expect(r.total, 3);
    });

    test('末尾空行不会变成一条空商品', () {
      final r = MasterCsv.parse('条码,品名\n6921817824327,冰红茶\n\n');
      expect(r.items.length, 1);
    });

    test('金额带千分位/带空格也能转成数', () {
      final r = MasterCsv.parse(
        '条码,品名,售价,账面数\n'
        '6921817824327,冰红茶,"1,299.50", 12 \n',
      );
      expect(r.items[0]['unit_price'], 1299.5);
      expect(r.items[0]['account_qty'], 12.0);
    });

    test('价格列空着时是 null，不是 NaN', () {
      final r = MasterCsv.parse('条码,品名,售价\n6921817824327,冰红茶,\n');
      expect(r.items[0]['unit_price'], isNull);
    });
  });

  group('商档模板', () {
    test('模板能被自己解析回来（导出→导入 闭环）', () {
      final r = MasterCsv.parse(MasterCsv.template());
      expect(r.items.length, 2);
      expect(r.items[0]['barcode'], '6921817824327');
      expect(r.items[1]['barcode'], '6901234567892');
      expect(r.items.first['name'], '示例商品A');
    });

    test('模板带 BOM（Excel 靠它认 UTF-8）', () {
      expect(MasterCsv.template().codeUnitAt(0), 0xFEFF);
    });

    test('模板内容逐字钉死（交付给测试人员的「商档模板.csv」就是它）', () {
      // 交付目录里那份 商档模板.csv 是照这个函数手工生成的。
      // 把内容钉死，改了模板就会红 —— 否则"给出去的模板"和"App 里生成的模板"
      // 会慢慢长成两份不同的东西，而员工拿到的可能是错的那份。
      expect(MasterCsv.template(), '\uFEFF'
          '条码,品名,规格,单位,售价,账面数\n'
          '6921817824327,示例商品A,500g,袋,12.5,30\n'
          '6901234567892,示例商品B,1L,瓶,8.0,12\n');
    });
  });

  group('导出的条码列必须是 Excel 认的文本', () {
    test('13 位条码写成 ="..." 公式包裹', () {
      expect(barcodeCsvCell('6921817824327'), '="6921817824327"');
    });

    test('短数字不包裹（内部码 123 包了反而变成公式）', () {
      expect(barcodeCsvCell('123'), '123');
    });

    test('含字母的条码不包裹', () {
      expect(barcodeCsvCell('A1B2C3D4E5F6'), 'A1B2C3D4E5F6');
    });

    // ── 这一组断言是按**实测**写死的，不是照理论猜的 ────────────────
    //
    // 2026-09-19 用本机 Excel（COM，Workbooks.Open 打开 .csv）真读过一遍，
    // 条码列四种写法的实际显示结果：
    //
    //   A. `="6921817824327"`（包裹后不再转义）
    //        Text = 6921817824327      Formula = ="6921817824327"     ✅
    //   B. `"=""6921817824327"""`（包裹后又过了一遍 csvEsc ← **本项目在用这个**）
    //        Text = 6921817824327      Formula = ="6921817824327"     ✅
    //   C. `6921817824327`（裸数字，没保护）
    //        Text = 6.92E+12           ← 龙哥报的"条码栏是乱码"就是这个
    //   D. `'6921817824327`（前导单引号）
    //        Text = '6921817824327     ← 那个撇号会**显示出来**，更糟
    //
    // 结论：A 和 B 在 Excel 里都对（B 能对，是因为 Excel 先剥 CSV 引号、
    // 再把 `=...` 当公式求值）。C 就是原故障，D 是常见的错误修法。
    //
    // ⚠️ 所以**不要**看到 `"=""..."` 觉得"多套了一层、肯定是 bug"就顺手改掉：
    //    它和主 App（xiaozhi-im/client）的 csv_fmt_test.dart 是钉死一致的，
    //    单方面改一边，两边导出的条码列就会长得不一样，而差异只在
    //    "Excel 到底先剥引号还是先认公式"这种没人会去查的地方。
    //    真要换 A，得两个工程一起换、一起重出包。
    test('扫码明细 CSV 里，长条码真的带上了 Excel 文本保护（端到端）', () {
      final csv = StocktakeExport.toScanCsv(<Map<String, dynamic>>[
        <String, dynamic>{
          'barcode': '6921817824327',
          'name': '冰红茶',
          'qty': 2.0,
          'unit': '瓶',
        },
      ]);
      // 实际落在文件里的字节序列（barcodeCsvCell 的产物又过了一遍 csvEsc）
      expect(csv.contains('"=""6921817824327"""'), isTrue);
      // 反向断言：只写"含这个串"是不够的 —— 万一哪天导出整体挂掉
      // （列序变了、条码没写进去），上面那条也可能因为别的原因成立。
      expect(csv.contains('冰红茶'), isTrue);
      expect(csv.contains('数量'), isTrue);
    });

    test('没有保护时条码会变成科学计数法（把原故障钉住）', () {
      // 这是"为什么要有 barcodeCsvCell"的反向证据：
      // 不加保护，Excel 认成数值，13 位显示成 6.92E+12。
      expect(csvEsc('6921817824327'), '6921817824327');
      expect(csvEsc('6921817824327'), isNot(contains('=')));
    });

    test('自己导出的明细能被自己导回商档（条码不被 ="..." 污染）', () {
      // 闭环：员工把「扫码明细」当商档导回来是常见动作，
      // 而那份文件里的条码列是 `"=""6921817824327"""`。
      // 解析不了的话，导进来的条码会变成一坨 ="" 开头的串，一条都对不上。
      final csv = StocktakeExport.toScanCsv(<Map<String, dynamic>>[
        <String, dynamic>{
          'barcode': '6921817824327',
          'name': '冰红茶',
          'qty': 2.0,
          'unit': '瓶',
        },
        <String, dynamic>{
          'barcode': '6901234567892',
          'name': '红富士苹果',
          'qty': 1.0,
          'unit': '袋',
        },
      ]);
      final r = MasterCsv.parse(csv);
      expect(r.items.length, 2);
      expect(r.items[0]['barcode'], '6921817824327');
      expect(r.items[1]['barcode'], '6901234567892');
      // 名称列（第 4 列）与它有同样的形状，也得原样读出来
      expect(r.items[0]['name'], '冰红茶');
    });
  });
}
