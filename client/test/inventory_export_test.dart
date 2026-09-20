import 'package:flutter_test/flutter_test.dart';
import 'package:xiaozhi_im_client/core/inventory_export.dart';

/// 盘点导出层（纯函数、零 IO、零 Flutter）。
///
/// 这一层错了不会崩、也不会报错 —— 只会给出一份"看着挺像那么回事"的
/// 错表，然后被发给主管。所以每条断言都盯着一个具体的错法：
///   · 少 BOM      → Excel 打开中文全是乱码，现场结论是"导出的文件坏了"
///   · 少转义      → 一个带逗号的商品名把整张表挤错列
///   · 账面缺失当 0 → "不知道差多少"被显示成"差 0 元"，合计看着很安心
///   · 文件名没消毒 → 点位码里的 `/` 被当路径分隔符，导出直接失败
/// 一个**独立实现**的 CSV 行切分：尊重引号包裹、`""` 还原成一个 `"`。
///
/// 存在的意义就是"不复用被测代码" —— 用它解析导出结果、再跟原始数据比，
/// 才能证明转义是可逆的（而不是"两种写法恰好都自洽"）。
List<String> _splitCsv(String line) {
  final out = <String>[];
  final buf = StringBuffer();
  var inQuotes = false;
  for (var i = 0; i < line.length; i++) {
    final ch = line[i];
    if (inQuotes) {
      if (ch == '"') {
        if (i + 1 < line.length && line[i + 1] == '"') {
          buf.write('"');
          i++;
        } else {
          inQuotes = false;
        }
      } else {
        buf.write(ch);
      }
    } else if (ch == '"') {
      inQuotes = true;
    } else if (ch == ',') {
      out.add(buf.toString());
      buf.clear();
    } else {
      buf.write(ch);
    }
  }
  out.add(buf.toString());
  return out;
}

void main() {
  Map<String, dynamic> row({
    String barcode = 'A',
    String? name = '矿泉水',
    double qty = 8,
    double? accountQty = 10,
    double? unitPrice = 5,
    double? prevQty,
    bool missing = false,
  }) {
    // 与服务端/仓库层同一个口径：**差异 = qty − 上一阶段数量**，不是比账面
    //（门店的泰格库里所有库存表都是空的，拿账面当基准会得到一个等于
    //  全部商品的差异集）。不关心这条差异的用例可以只给 accountQty，
    // 那两列会取同一个值，数字照样自洽。
    final prev = prevQty ?? accountQty;
    return <String, dynamic>{
      'barcode': barcode,
      'name': name,
      'spec': '550ml',
      'unit': '瓶',
      'qty': qty,
      'account_qty': accountQty,
      'unit_price': unitPrice,
      'prev_qty': prev,
      'diff_qty': prev == null ? null : qty - prev,
      if (missing) 'missing': true,
    };
  }

  group('采集明细 CSV', () {
    test('带 UTF-8 BOM，否则 Excel/WPS 按 GBK 打开全是乱码', () {
      final csv = InventoryExport.toRowsCsv(<Map<String, dynamic>>[row()]);
      expect(csv.startsWith('\uFEFF'), isTrue,
          reason: '没带 BOM：中文商品名在 Excel 里会变乱码，现场会以为文件坏了');
    });

    test('表头与列顺序（列错了比少列更难发现 —— 数字看着都对）', () {
      final csv = InventoryExport.toRowsCsv(<Map<String, dynamic>>[row()]);
      final head = csv.replaceFirst('\uFEFF', '').split('\n').first;
      expect(head, '条码,商品名称,规格,单位,实盘数量,账面数量,差异数量,货架位');
    });

    test('商品名里有逗号和引号 → 必须转义，不能把表挤错列', () {
      const name = '牛奶,大盒"特惠"';
      final csv = InventoryExport.toRowsCsv(<Map<String, dynamic>>[
        row(name: name),
      ]);
      // 正确结果：整个字段被引号包起来，内部引号翻倍
      expect(csv.contains('"牛奶,大盒""特惠"""'), isTrue);

      final lines = csv.replaceFirst('\uFEFF', '').split('\n');
      final data = lines[1];

      // ① 反向：**不做转义处理**地按逗号切，一定会被那个逗号切成 9 段
      //    （正确是 8 段）—— 这就是"一个商品名把整张表挤错列"的样子。
      expect(data.split(',').length, 9,
          reason: '商品名没被引号包住：里面的逗号会被当成列分隔符');

      // ② 用**独立实现**的 CSV 解析器切，必须回到 8 段，
      //    而且商品名要能**原样还原** —— 这才叫转义对了。
      //    故意不调导出层的任何函数：拿被测量的实现去验它自己，等于什么都没验。
      final cols = _splitCsv(data);
      expect(cols.length, 8, reason: '转义之后列数必须正常');
      expect(cols[1], name, reason: '转义要可逆，别把商品名改坏了');
    });

    test('账面缺失（未知条码）→ 留空，不能写 0', () {
      final csv = InventoryExport.toRowsCsv(<Map<String, dynamic>>[
        row(barcode: 'X', name: null, accountQty: null),
      ]);
      final data = csv.replaceFirst('\uFEFF', '').split('\n')[1];
      expect(data.split(',')[1], '未知条码',
          reason: '空名字在表里就是一片空白，看着像"这行数据坏了"');
      expect(data.split(',')[5], '',
          reason: '账面写 0 会被当成"账上有 0 件"，而不是"账上没这个商品"');
      expect(data.split(',')[6], '');
    });

    test('整数不拖小数点（12 而不是 12.0），小数保留（称重商品）', () {
      final csv = InventoryExport.toRowsCsv(<Map<String, dynamic>>[
        row(qty: 12),
        row(barcode: 'B', qty: 1.25),
      ]);
      final lines = csv.replaceFirst('\uFEFF', '').split('\n');
      expect(lines[1].contains(',12,'), isTrue);
      expect(lines[2].contains(',1.25,'), isTrue);
    });
  });

  group('差异金额', () {
    test('差异金额 = 差异数量 × 单价', () {
      expect(InventoryExport.amtOf(row(qty: 8, accountQty: 10, unitPrice: 5)), -10);
      expect(InventoryExport.amtOf(row(qty: 13, accountQty: 10, unitPrice: 2)), 6);
    });

    test('🔴 缺单价 → null，**不是 0**', () {
      expect(InventoryExport.amtOf(row(unitPrice: null)), isNull,
          reason: '"不知道差多少钱"和"差 0 元"是两回事：写 0 会让合计看着很安心');
    });

    test('差异表 CSV：有「上一阶段」列、有「差异金额」列，漏盘在备注里点名', () {
      final csv = InventoryExport.toDiffCsv(<Map<String, dynamic>>[
        row(qty: 8, prevQty: 10, accountQty: 10, unitPrice: 5),
        row(barcode: 'B', unitPrice: null),
        row(barcode: 'C', qty: 0, prevQty: 4, accountQty: 4, unitPrice: 5,
            missing: true),
      ]);
      final lines = csv.replaceFirst('\uFEFF', '').trimRight().split('\n');
      expect(lines[0].endsWith('账面数量,备注'), isTrue);
      expect(lines[0].contains('上一阶段数量'), isTrue,
          reason: '差异是跟"上一次盘的数量"比出来的，表里必须有一列写清参照是什么，'
              '只给一个"账面数量"会让人以为那是差异的基准');

      final c1 = _splitCsv(lines[1]);
      expect(c1[5], '10', reason: '上一阶段数量');
      expect(c1[6], '-2', reason: '差异数量 = 8 − 10');
      expect(c1[7], '-10.00', reason: '差异金额 = 差异数量 × 单价');
      expect(c1[9], '');

      // 缺单价 → 金额留空（不是 0）
      expect(_splitCsv(lines[2])[7], '');

      // 漏盘：数量是 0，看着像"盘得很准"，必须在备注里点名
      final c3 = _splitCsv(lines[3]);
      expect(c3[5], '4');
      expect(c3[6], '-4', reason: '上一遍 4、这一遍没扫到 → 差异 −4');
      expect(c3[9], '漏盘',
          reason: '漏盘行不标出来 = 最严重的一类差异没人看得见（明细里"少一行"看不出来）');
    });
  });

  group('差异表文档（发给主管的那份）', () {
    test('盘亏/盘盈/账面缺失/失误笔数 四个数都对', () {
      final doc = InventoryExport.toDiffDoc(
        <Map<String, dynamic>>[
          row(qty: 8, accountQty: 10, unitPrice: 5), // 差 -2 → 盘亏 10
          row(barcode: 'B', qty: 13, accountQty: 10, unitPrice: 2), // 差 +3 → 盘盈 6
          row(barcode: 'C', qty: 1, accountQty: null, unitPrice: 3), // 账上没这商品
        ],
        zoneName: '生鲜区',
        phaseLabel: '初盘',
        mistakes: 3,
      );
      expect(doc.contains('盘点位：生鲜区'), isTrue);
      expect(doc.contains('差异品种：3'), isTrue);
      expect(doc.contains('盘亏金额：10.00'), isTrue);
      expect(doc.contains('盘盈金额：6.00'), isTrue);
      expect(doc.contains('账面缺失（账上没有这商品）：1'), isTrue);
      expect(doc.contains('本阶段失误笔数：3'), isTrue);
    });

    test('🔴 漏盘要单独计数 + 那一行要点名 —— 否则数量 0 看着像"盘得挺准"', () {
      final doc = InventoryExport.toDiffDoc(
        <Map<String, dynamic>>[
          row(qty: 8, prevQty: 10, accountQty: 10, unitPrice: 5), // 差 -2
          row(barcode: 'C', qty: 0, prevQty: 4, accountQty: 4, unitPrice: 5,
              missing: true), // 漏盘
        ],
        zoneName: '生鲜区',
        phaseLabel: '复盘',
        mistakes: 0,
      );
      expect(doc.contains('差异品种：2'), isTrue);
      expect(doc.contains('其中漏盘（上一遍有、这一遍没扫到）：1'), isTrue,
          reason: '漏盘数不单独列出来，主管在总数里根本看不出有几条是"没扫到"');
      expect(doc.contains('【漏盘】'), isTrue,
          reason: '漏盘那一行不点名：数量 0 混在差异表里，看着像"这件盘得很准"');
      expect(doc.contains('上一遍 4'), isTrue,
          reason: '要说清它是"上一遍盘过 4 件、这一遍一件没扫到"，'
              '不然主管不知道该去货架上找什么');
    });

    test('盘盈盘亏不能算反（差 -2 是亏不是盈）', () {
      // 反向断言：只有盘亏没有盘盈时，盘盈必须是 0.00。
      // 算反了的话，一个净亏的门店会显示成"盘盈 10 元"，主管当场就不会信这份表了。
      final doc = InventoryExport.toDiffDoc(
        <Map<String, dynamic>>[row(qty: 8, accountQty: 10, unitPrice: 5)],
        zoneName: 'Z',
        phaseLabel: '初盘',
        mistakes: 0,
      );
      expect(doc.contains('盘亏金额：10.00'), isTrue);
      expect(doc.contains('盘盈金额：0.00'), isTrue);
    });

    test('没有差异时数字全 0，不崩也不输出莫名其妙的负数', () {
      final doc = InventoryExport.toDiffDoc(
        const <Map<String, dynamic>>[],
        zoneName: 'Z',
        phaseLabel: '复盘',
        mistakes: 0,
      );
      expect(doc.contains('差异品种：0'), isTrue);
      expect(doc.contains('盘亏金额：0.00'), isTrue);
    });
  });

  group('文件名', () {
    test('点位码带中文/斜杠必须消毒 —— 否则 Android 上导出直接失败', () {
      final csv = InventoryExport.diffName('生鲜区/3', 1);
      final txt = InventoryExport.diffDocName('生鲜区/3', 2);
      expect(csv.contains('/'), isFalse,
          reason: '斜杠在 Android/Windows 上都是路径分隔符：'
              '拼进文件名会变成"往一个叫 盘点差异_生鲜区 的子目录里写文件"');
      expect(txt.contains('/'), isFalse);
      expect(csv, startsWith('盘点差异_'));
      expect(csv, endsWith('.csv'));
      expect(txt, endsWith('.txt'));
    });

    test('纯英文点位码原样保留（别把 A01 消毒没了）', () {
      expect(InventoryExport.diffName('A01', 3), '盘点差异_A01_3.csv');
    });

    test('盘点前缀是「盘点_」，与扫码枪的「扫码_」分开', () {
      expect(InventoryExport.csvName('INV-Z01-1-20260919'), startsWith('盘点_'));
      expect(InventoryExport.csvName('INV-Z01-1-20260919'), isNot(startsWith('扫码_')));
    });
  });
}
