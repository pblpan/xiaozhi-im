import 'package:flutter_test/flutter_test.dart';
import 'package:xiaozhi_im_client/core/stocktake_export.dart';

/// 扫码枪出数的测试。
///
/// 这里钉死的三件事，都是**错了不报错、但数字会骗人**的那类：
///   ① CSV 开头必须有 BOM（没有的话 Excel 打开全是乱码，老板以为系统坏了）；
///   ② 盘盈/盘亏金额一律取正数（混用符号必然看反）；
///   ③ 账面缺失的行不计入盈亏（按 0 算会把"商档没同步"伪装成"大面积盘盈"）。
void main() {
  Map<String, dynamic> row({
    String barcode = '6901028000001',
    String name = '矿泉水',
    String spec = '550ml',
    String unit = '瓶',
    Object? price = 2.5,
    Object? account = 10,
    Object? qty = 12,
    String? note,
  }) =>
      <String, dynamic>{
        'id': 1,
        'barcode': barcode,
        'name': name,
        'spec': spec,
        'unit': unit,
        'unit_price': price,
        'account_qty': account,
        'qty': qty,
        'diff_qty': account == null ? null : (qty as num).toDouble() -
            (account is num ? account.toDouble() : 0),
        if (note != null) 'note': note,
      };

  group('toCsv', () {
    test('开头带 UTF-8 BOM，否则 Excel 双击是乱码', () {
      final csv = StocktakeExport.toCsv([row()]);
      expect(csv.startsWith('\uFEFF'), isTrue);
      // BOM 之后紧接着就是表头，中间不能多出空行
      expect(csv.substring(1).startsWith('条码,'), isTrue);
    });

    test('空数据也输出表头，不是空文件', () {
      final csv = StocktakeExport.toCsv(const []);
      expect(csv.startsWith('\uFEFF'), isTrue);
      final lines = csv.split('\n').where((l) => l.trim().isNotEmpty).toList();
      expect(lines.length, 1);
      expect(lines.first.trim(), contains('差异金额'));
    });

    test('表头 10 列，顺序与 headers 一致', () {
      final csv = StocktakeExport.toCsv([row()]);
      final head = csv.split('\n')[0].replaceFirst('\uFEFF', '').trim();
      expect(head.split(',').length, StocktakeExport.headers.length);
      expect(head.startsWith('条码,品名,规格,单位,单价,账面数,实盘数'), isTrue);
    });

    test('商品名带逗号要加引号，否则列会被冲掉', () {
      final csv = StocktakeExport.toCsv([row(name: '苹果,红富士')]);
      expect(csv, contains('"苹果,红富士"'));
    });

    test('商品名带双引号要翻倍', () {
      final csv = StocktakeExport.toCsv([row(name: '3"装')]);
      expect(csv, contains('"3""装"'));
    });

    test('整数不带 .0，小数保留有效位', () {
      final csv = StocktakeExport.toCsv([row(qty: 12, account: 10, price: 2.5)]);
      expect(csv, contains(',10,12,2,5,'));
    });

    test('账面缺失时账面/差异/差异金额留空，实盘数照写', () {
      final csv = StocktakeExport.toCsv([row(account: null, qty: 7)]);
      final line = csv.split('\n')[1];
      // 单价,账面数,实盘数,差异数量,差异金额,备注
      expect(line.endsWith(',7,,,') || line.endsWith(',7,,'), isTrue);
      expect(line, contains(',7,'));
    });

    test('泰格价格是字符串 "83.00"，要能算成数字', () {
      final csv = StocktakeExport.toCsv([row(price: '83.00', account: 10, qty: 9)]);
      // diff = -1 → 金额 -83
      expect(csv, contains('-83'));
      expect(csv, contains('83,')); // 单价列
    });

    test('备注列原样输出', () {
      final csv = StocktakeExport.toCsv([row(note: 'A 货架第二层')]);
      expect(csv.trim().endsWith('A 货架第二层'), isTrue);
    });
  });

  group('summarize', () {
    test('盘盈：实盘多于账面，数量为 +2、金额为正', () {
      final s = StocktakeExport.summarize([row(account: 10, qty: 12, price: 3)]);
      expect(s['gain_kinds'], 1);
      expect(s['gain_qty'], 2);
      expect(s['gain_amt'], 6);
      expect(s['loss_kinds'], 0);
      expect(s['loss_amt'], 0);
      expect(s['net_amt'], 6);
    });

    test('盘亏：金额取正数表示"亏了多少"，不是负数', () {
      final s = StocktakeExport.summarize([row(account: 10, qty: 7, price: 3)]);
      expect(s['loss_kinds'], 1);
      expect(s['loss_qty'], 3);
      expect(s['loss_amt'], 9); // 不是 -9
      expect(s['gain_amt'], 0);
      expect(s['net_amt'], -9);
    });

    test('盈亏相抵：净额 = 盈 - 亏', () {
      final s = StocktakeExport.summarize([
        row(barcode: 'A', account: 10, qty: 12, price: 5), // 盈 10
        row(barcode: 'B', account: 10, qty: 8, price: 5), // 亏 10
      ]);
      expect(s['gain_amt'], 10);
      expect(s['loss_amt'], 10);
      expect(s['net_amt'], 0);
    });

    test('持平单独计数，不进盈也不进亏', () {
      final s = StocktakeExport.summarize([row(account: 10, qty: 10)]);
      expect(s['flat_kinds'], 1);
      expect(s['gain_kinds'], 0);
      expect(s['loss_kinds'], 0);
    });

    test('账面缺失不计入盈亏 —— 否则商档没同步会假装成大面积盘盈', () {
      final s = StocktakeExport.summarize([
        row(barcode: 'A', account: null, qty: 99),
        row(barcode: 'B', account: null, qty: 1),
      ]);
      expect(s['no_account'], 2);
      expect(s['gain_kinds'], 0);
      expect(s['loss_kinds'], 0);
      expect(s['gain_amt'], 0);
      expect(s['net_amt'], 0);
      // 但品种数和实盘总数仍然要算（扫了多少是事实）
      expect(s['kinds'], 2);
      expect(s['total_qty'], 100);
    });

    test('未知条码（品名为空）单独计数', () {
      final s = StocktakeExport.summarize([
        row(name: '', account: null, qty: 3),
        row(barcode: 'B', name: '矿泉水', account: 5, qty: 5),
      ]);
      expect(s['unknown'], 1);
      expect(s['flat_kinds'], 1);
    });

    test('缺单价只算数量不算金额，不把 null 当 0 掺进金额', () {
      final s = StocktakeExport.summarize([
        row(account: 10, qty: 12, price: null),
      ]);
      expect(s['gain_qty'], 2);
      expect(s['gain_amt'], 0);
      expect(s['net_amt'], 0);
    });

    test('泰格字符串数字也能参与计算', () {
      final s = StocktakeExport.summarize([
        row(price: '83.00', account: '10', qty: 9),
      ]);
      expect(s['loss_qty'], 1);
      expect(s['loss_amt'], 83);
    });

    test('空单不炸，全是 0', () {
      final s = StocktakeExport.summarize(const []);
      expect(s['kinds'], 0);
      expect(s['total_qty'], 0);
      expect(s['net_amt'], 0);
      expect(s['no_account'], 0);
    });
  });

  group('diffOf / amtOf', () {
    test('账面缺失返回 null，不是 0', () {
      expect(StocktakeExport.diffOf(row(account: null, qty: 5)), isNull);
    });

    test('差异 = 实盘 - 账面，可正可负', () {
      expect(StocktakeExport.diffOf(row(account: 10, qty: 12)), 2);
      expect(StocktakeExport.diffOf(row(account: 10, qty: 8)), -2);
    });

    test('缺单价时差异金额为 null（不是 0）', () {
      expect(StocktakeExport.amtOf(row(account: 10, qty: 12, price: null)), isNull);
    });

    test('泰格的字符串价格也能算出金额', () {
      expect(StocktakeExport.amtOf(row(price: '2.50', account: 10, qty: 12)), 5);
    });
  });

  group('filter', () {
    final rows = <Map<String, dynamic>>[
      row(barcode: 'A', account: 10, qty: 10, price: 5), // 持平
      row(barcode: 'B', account: 10, qty: 12, price: 5), // 盈 10
      row(barcode: 'C', account: 10, qty: 5, price: 5), // 亏 25
      row(barcode: 'D', account: 10, qty: 8, price: 3), // 亏 6
      row(barcode: 'E', account: null, qty: 3), // 无账面
    ];

    test('全部：原顺序返回，一行不少', () {
      final out = StocktakeExport.filter(rows, StocktakeExport.filterAll);
      expect(out.length, 5);
      expect(out.first['barcode'], 'A');
    });

    test('有差异：排除持平与无账面', () {
      final out = StocktakeExport.filter(rows, StocktakeExport.filterDiff);
      expect(out.map((r) => r['barcode']).toList(), ['C', 'B', 'D']);
    });

    test('有差异按差异金额绝对值从大到小 —— 亏得最狠的排最前', () {
      final out = StocktakeExport.filter(rows, StocktakeExport.filterDiff);
      // C 亏 25 > B 盈 10 > D 亏 6
      expect(out.map((r) => r['barcode']).toList(), ['C', 'B', 'D']);
    });

    test('盘亏 / 盘盈 各自只留一边', () {
      expect(
        StocktakeExport.filter(rows, StocktakeExport.filterLoss)
            .map((r) => r['barcode'])
            .toList(),
        ['C', 'D'],
      );
      expect(
        StocktakeExport.filter(rows, StocktakeExport.filterGain)
            .map((r) => r['barcode'])
            .toList(),
        ['B'],
      );
    });

    test('无账面：只剩档案里查不到的码', () {
      final out = StocktakeExport.filter(rows, StocktakeExport.filterNoAccount);
      expect(out.map((r) => r['barcode']).toList(), ['E']);
    });

    test('都没有单价时退回按差异数量排，不把一堆 0 金额乱堆', () {
      final noPrice = <Map<String, dynamic>>[
        row(barcode: 'X', account: 10, qty: 11, price: null),
        row(barcode: 'Y', account: 10, qty: 4, price: null),
      ];
      final out = StocktakeExport.filter(noPrice, StocktakeExport.filterDiff);
      expect(out.map((r) => r['barcode']).toList(), ['Y', 'X']); // |−6| > |+1|
    });

    test('未知模式当全部处理，不返回空', () {
      expect(StocktakeExport.filter(rows, 99).length, 5);
    });
  });

  group('fileName', () {
    test('扫码_单号.csv', () {
      expect(StocktakeExport.fileName('PD20260919220000'),
          '扫码_PD20260919220000.csv');
    });
  });

  group('与 listWithMaster 的真实行配合', () {
    test('未识别条码 diff_qty 为 null 时汇总不出错', () {
      final rows = <Map<String, dynamic>>[
        {
          'id': 1,
          'barcode': '999999',
          'qty': 4,
          'name': null,
          'spec': null,
          'unit': null,
          'unit_price': null,
          'account_qty': null,
          'diff_qty': null,
        },
      ];
      final s = StocktakeExport.summarize(rows);
      expect(s['unknown'], 1);
      expect(s['no_account'], 1);
      final csv = StocktakeExport.toCsv(rows);
      expect(csv, contains('999999'));
      expect(() => StocktakeExport.toCsv(rows), returnsNormally);
    });
  });

  group('扫码明细导出（采集页底部「导出」）', () {
    test('CSV 开头带 UTF-8 BOM，表头 4 列', () {
      final csv = StocktakeExport.toScanCsv([
        {'id': 1, 'barcode': '6901028000001', 'qty': 3, 'name': '矿泉水'},
      ]);
      expect(csv.startsWith('\uFEFF'), isTrue);
      final head =
          csv.split('\n')[0].replaceFirst('\uFEFF', '').trim();
      expect(head, '序号,条码,数量,商品名称');
      expect(
          head.split(',').length, StocktakeExport.scanHeaders.length);
    });

    test('序号从 1 连续编号，数量与界面同一格式化出口', () {
      final csv = StocktakeExport.toScanCsv([
        {'id': 1, 'barcode': 'A001', 'qty': 2, 'name': '甲'},
        {'id': 2, 'barcode': 'A002', 'qty': 12.0, 'name': '乙'},
      ]);
      final lines =
          csv.split('\n').where((l) => l.trim().isNotEmpty).toList();
      expect(lines.length, 3);
      expect(lines[1], '1,A001,2,甲');
      // 整数不带 .0（fmtNum / _num 同一出口）
      expect(lines[2], '2,A002,12,乙');
    });

    test('没有名称的行用预留值「未知条码」，界面与导出一致', () {
      final csv = StocktakeExport.toScanCsv([
        {'id': 1, 'barcode': '999999', 'qty': 1, 'name': null},
      ]);
      expect(csv, contains('未知条码'));
      expect(StocktakeExport.scanNameOf({'name': '  '}), '未知条码');
      expect(StocktakeExport.scanNameOf({'name': '矿泉水'}), '矿泉水');
    });

    test('名称带逗号/引号正常转义，不冲掉列', () {
      final csv = StocktakeExport.toScanCsv([
        {'id': 1, 'barcode': 'A001', 'qty': 1, 'name': '苹果,红富士"大"'},
      ]);
      expect(csv, contains('"苹果,红富士""大"""'));
    });

    test('文本文档带单号/时间/合计，行号连续', () {
      final doc = StocktakeExport.toScanDoc([
        {'id': 1, 'barcode': 'A001', 'qty': 2, 'name': '甲'},
        {'id': 2, 'barcode': '999999', 'qty': 3, 'name': ''},
      ], sheetNo: 'PD20260919120000');
      expect(doc, contains('扫码单号：PD20260919120000'));
      expect(doc, contains('品种 2'));
      expect(doc, contains('合计数量 5'));
      expect(doc, contains('1. 条码 A001'));
      expect(doc, contains('2. 条码 999999'));
      expect(doc, contains('名称：未知条码'));
      expect(doc, contains('共 2 行'));
    });

    test('明细文件名与盈亏表文件名错开，不会互相覆盖', () {
      expect(StocktakeExport.scanCsvName('PD1'), '扫码明细_PD1.csv');
      expect(StocktakeExport.scanDocName('PD1'), '扫码明细_PD1.txt');
      expect(StocktakeExport.fileName('PD1'), '扫码_PD1.csv');
    });

    // ── 龙哥 2026-09-19 报的"条码栏是乱码" ──────────────────────
    // 真因不是编码（BOM 一直在），是 Excel 把 13 位数字条码当**数值**：
    // 显示成 6.92182E+12，超过 15 位还会把末尾置零。
    // 下面两条**必须成对**：只测"有 =" 不测"裸串不见了"，
    // 万一哪天函数改了但导出没接上，前者会假绿。
    test('🔴 13 位条码落进 CSV 是 ="..." 形式（Excel 打开按文本显示）', () {
      final csv = StocktakeExport.toScanCsv([
        {'id': 1, 'barcode': '6921817824327', 'qty': 1, 'name': '矿泉水'},
      ]);
      expect(csv, contains('"=""6921817824327"""'));
    });

    test('🔴 反向：CSV 里不能出现裸的长数字条码', () {
      final csv = StocktakeExport.toScanCsv([
        {'id': 1, 'barcode': '6921817824327', 'qty': 1, 'name': '矿泉水'},
      ]);
      expect(csv, isNot(contains(',6921817824327,')),
          reason: '裸着写出去，Excel 会显示成 6.92182E+12 —— 就是龙哥说的乱码');
    });

    test('短码 / 带字母的码不做处理（加了反而平白变成公式）', () {
      final csv = StocktakeExport.toScanCsv([
        {'id': 1, 'barcode': '6901', 'qty': 1, 'name': '甲'},
        {'id': 2, 'barcode': 'AB-001', 'qty': 1, 'name': '乙'},
      ]);
      expect(csv, contains(',6901,'));
      expect(csv, contains(',AB-001,'));
      expect(csv, isNot(contains('="')));
    });

    test('盈亏表那份 CSV 的条码列同样要保护（别只改了明细）', () {
      final csv = StocktakeExport.toCsv([
        {
          'barcode': '6921817824327',
          'name': '矿泉水',
          'qty': 1,
          'account_qty': 2,
          'unit_price': 3,
        },
      ]);
      expect(csv, contains('"=""6921817824327"""'));
      expect(csv, isNot(contains(',6921817824327,')));
    });
  });
}
