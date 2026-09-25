import 'package:flutter_test/flutter_test.dart';
import 'package:xiaozhi_im_client/core/simple_export.dart';
import 'package:xiaozhi_im_client/core/simple_rules.dart';

/// 简易盘点「导出层」的测试。
///
/// 这份文件的接收人是对账的人：他手上有一份"这一轮要盘什么"的清单，
/// 逐行对导出文件里的数量。所以判据不是"好不好看"，而是：
///   · **一行都不能少**（段1+段2 = 清单行数，这是硬判据）；
///   · 没盘到的写 **0** 不是留空（留空他分不清"是 0 还是没读到"）；
///   · 排序照**导入顺序**（他就是按手上那份单子的顺序往下看的）；
///   · 长条码不能被 Excel 变成 `6.9E+12`（那样打印出来找不到货）。
void main() {
  /// 造 N 条清单行。
  List<Map<String, dynamic>> items(int n) => List<Map<String, dynamic>>.generate(
        n,
        (i) => <String, dynamic>{
          'barcode': '6901234${(567890 + i).toString().padLeft(6, '0')}',
          'name': '商品$i',
          'spec': null,
          'seq': i + 1,
        },
      );

  group('验收出口（方案 §6 S1）', () {
    test('🔴 导 1000 条 → 盘 50 个 → 导出正好 1000 行（50 有数 / 950 是 0）', () {
      final list = items(1000);
      final qty = <String, double>{};
      for (var i = 0; i < 50; i++) {
        qty[list[i]['barcode'] as String] = 1;
      }
      final s = SimpleExport.build(items: list, qty: qty);

      expect(s.data.length, 50);
      expect(s.missing.length, 950);
      expect(s.extra.length, 0);
      expect(s.totalRows, 1000);
      expect(s.importedCount, 1000);
      // 🔴 硬判据：段1 + 段2 = 导入清单的行数（防"悄悄少了几行"）
      expect(s.data.length + s.missing.length, 1000);
      expect(s.accounted, isTrue, reason: '有商品被丢掉了');

      // 从**拼好的 CSV 里读回来**再数一遍：只有这样才能证明"文件里"没少行
      final csv = SimpleExport.toCsv(s);
      final counts = SimpleExport.countRowsBySegment(csv);
      expect(counts[SimpleExport.titleData], 50);
      expect(counts[SimpleExport.titleMissing], 950);
      expect(counts[SimpleExport.titleExtra], 0);
      expect(
        (counts[SimpleExport.titleData] ?? 0) +
            (counts[SimpleExport.titleMissing] ?? 0) +
            (counts[SimpleExport.titleExtra] ?? 0),
        1000,
      );
    });

    test('CSV 带 BOM（Excel 双击不乱码）', () {
      final csv = SimpleExport.toCsv(
          SimpleExport.build(items: items(1), qty: <String, double>{}));
      expect(csv.startsWith('\uFEFF'), isTrue);
    });
  });

  group('三段归属', () {
    final list = <Map<String, dynamic>>[
      <String, dynamic>{'barcode': 'A1', 'name': '甲', 'seq': 1},
      <String, dynamic>{'barcode': 'A2', 'name': '乙', 'seq': 2},
      <String, dynamic>{'barcode': 'A3', 'name': '丙', 'seq': 3},
    ];

    test('清单内且有数 → 段1；没数 → 段2（写 0）；清单外 → 段3（实盘数）', () {
      final s = SimpleExport.build(
        items: list,
        qty: <String, double>{'A1': 5, 'A3': 2, 'Z9': 7},
      );
      expect(s.data.rows.map((r) => r.barcode).toList(), <String>['A1', 'A3']);
      expect(s.missing.rows.map((r) => r.barcode).toList(), <String>['A2']);
      expect(s.missing.rows.first.qty, 0.0,
          reason: '🔴 没盘到的写 0，留空的话对账的人分不清"是 0 还是没读到"');
      expect(s.extra.rows.map((r) => r.barcode).toList(), <String>['Z9']);
      expect(s.extra.rows.first.qty, 7.0);
      expect(s.extra.rows.first.name, SimpleExport.unknownName,
          reason: '清单外查不到名字，给占位而不是空串');
      expect(s.accounted, isTrue);
    });

    test('🔴 段1/段2 都按导入顺序（未盘到的**不**单独排最后）', () {
      // 对账的人是按手上那张单子一行行往下对的，把没盘到的挪到最后
      // 会让他对不上号。
      final s = SimpleExport.build(
        items: list,
        qty: <String, double>{'A1': 1, 'A3': 1},
      );
      expect(s.missing.rows.map((r) => r.barcode).toList(), <String>['A2']);
      // 再造一个"第一行就没盘到"的，确认它待在原位、不跑到段2的末尾顺序之外
      final list2 = <Map<String, dynamic>>[
        <String, dynamic>{'barcode': 'B1', 'name': '一', 'seq': 1},
        <String, dynamic>{'barcode': 'B2', 'name': '二', 'seq': 2},
        <String, dynamic>{'barcode': 'B3', 'name': '三', 'seq': 3},
      ];
      final s2 = SimpleExport.build(
        items: list2,
        qty: <String, double>{'B1': 1, 'B3': 1},
      );
      expect(s2.missing.rows.single.barcode, 'B2');
    });

    test('段3 按条码升序（它们没有导入顺序）', () {
      final s = SimpleExport.build(
        items: list,
        qty: <String, double>{'A1': 1, 'Z9': 1, 'Y8': 1, 'X7': 1},
      );
      expect(s.extra.rows.map((r) => r.barcode).toList(),
          <String>['X7', 'Y8', 'Z9']);
    });

    test('清单外但数量 0 → 不进段3（它本来就没扫到）', () {
      final s = SimpleExport.build(
        items: list,
        qty: <String, double>{'A1': 1, 'ZZ': 0},
      );
      expect(s.extra, isEmpty);
      expect(s.accounted, isTrue, reason: '清单内的都落位了');
    });

    test('清单里有 0 的数 → 当"没盘到"处理，不会同时出现在段1', () {
      final s = SimpleExport.build(items: list, qty: <String, double>{'A1': 0});
      expect(s.data, isEmpty);
      expect(s.missing.rows.single.barcode, 'A1');
      expect(s.accounted, isTrue);
    });

    test('清单行名字为空 → 给占位', () {
      final s = SimpleExport.build(
        items: <Map<String, dynamic>>[
          <String, dynamic>{'barcode': 'A1', 'name': '  ', 'seq': 1},
        ],
        qty: <String, double>{'A1': 1},
      );
      expect(s.data.rows.single.name, SimpleExport.unknownName);
    });
  });

  group('差异待复核（第 4 段；S1 恒为空，S2 用）', () {
    final list = <Map<String, dynamic>>[
      <String, dynamic>{'barcode': 'A1', 'name': '甲', 'seq': 1},
      <String, dynamic>{'barcode': 'A2', 'name': '乙', 'seq': 2},
      <String, dynamic>{'barcode': 'A3', 'name': '丙', 'seq': 3},
    ];

    test('🔴 对不上又没复核的：既不进段1（数没定）、也不进段2（它明明盘到了）', () {
      // 方案 §4：**绝不允许把它们悄悄丢掉** —— 数据丢了比格式不好看严重得多。
      final s = SimpleExport.build(
        items: list,
        qty: <String, double>{'A1': 5, 'A2': 3},
        pending: <String>{'A2'},
      );
      expect(s.data.rows.single.barcode, 'A1');
      expect(s.missing.rows.single.barcode, 'A3', reason: '真没盘到的是 A3');
      expect(s.pending.rows.single.barcode, 'A2');
      expect(s.pending.rows.first.qty, isNull,
          reason: '数量列留空 —— 替盘点员挑一个数就是替他签字');
      expect(s.totalRows, 3, reason: '一条都不能丢');
      expect(s.accounted, isTrue, reason: 'accounted 要把待复核也算上');
    });

    test('第 4 段要渲染在文件里，数量列是空的', () {
      final csv = SimpleExport.toCsv(SimpleExport.build(
        items: list,
        qty: <String, double>{'A1': 5, 'A2': 3},
        pending: <String>{'A2'},
      ));
      expect(csv, contains(SimpleExport.titlePending));
      expect(csv, contains('A2,,乙'));
      final counts = SimpleExport.countRowsBySegment(csv);
      expect(counts[SimpleExport.titlePending], 1);
    });

    test('没有待复核时，文件里**不出现**第 4 段的抬头', () {
      // 正常流程走完就该是干净的三段；冒出一个"差异待复核"会让人以为还有事没做完。
      final csv = SimpleExport.toCsv(SimpleExport.build(
        items: list,
        qty: <String, double>{'A1': 5, 'A2': 3, 'A3': 1},
      ));
      expect(csv, isNot(contains(SimpleExport.titlePending)));
      expect(
        SimpleExport.countRowsBySegment(csv).values.fold<int>(0, (a, b) => a + b),
        3,
      );
    });
  });

  group('CSV 细节', () {
    final list = <Map<String, dynamic>>[
      <String, dynamic>{
        'barcode': '6901234567890',
        'name': '农夫山泉 550ml',
        'seq': 1
      },
      <String, dynamic>{'barcode': '007', 'name': '苹果,红富士', 'seq': 2},
    ];

    test('抬头与列名：三段的三列都照龙哥说的顺序', () {
      final csv = SimpleExport.toCsv(SimpleExport.build(
        items: list,
        qty: <String, double>{'6901234567890': 2, '007': 1},
      ));
      final rows = SimpleRules.parseCsvRows(csv);
      expect(rows.first.first, SimpleExport.titleData);
      expect(rows[1].join(','), '商品条码,商品盘点数量,商品名称');
    });

    test('🔴 长条码写成 Excel 文本公式（防科学计数法 / 末尾变 0）', () {
      final csv = SimpleExport.toCsv(SimpleExport.build(
        items: list,
        qty: <String, double>{'6901234567890': 2, '007': 1},
      ));
      final rows = SimpleRules.parseCsvRows(csv);
      // CSV 读回来是 ="690..."；Excel 打开时求值成文本 6901234567890
      expect(rows[2].first, '="6901234567890"');
      expect(rows[2][1], '2', reason: '整数不带小数点');
      expect(rows[2][2], '农夫山泉 550ml');
      // 短条码/带前导零的内部码不套 ="" （套了平白变成公式）
      expect(rows[3].first, isNot(contains('=')));
      expect(rows[3][1], '1');
      // 带逗号的商品名转义后仍是一列
      expect(rows[3].length, 3);
      expect(rows[3][2], '苹果,红富士');
    });

    test('三段抬头按 1→2→3 顺序出现，且文件里没有空行', () {
      // 造出"三段都有内容"的分布：1 个盘到、2 个没盘到、0 个清单外
      // （段 3 空着也会渲染抬头，所以这里照样能验顺序）。
      final csv = SimpleExport.toCsv(SimpleExport.build(
          items: items(3), qty: <String, double>{'6901234567890': 1}));
      final t1 = csv.indexOf(SimpleExport.titleData);
      final t2 = csv.indexOf(SimpleExport.titleMissing);
      final t3 = csv.indexOf(SimpleExport.titleExtra);
      expect(t1, greaterThanOrEqualTo(0));
      expect(t1, lessThan(t2));
      expect(t2, lessThan(t3));
      // 空行会让"数行数"这条判据失真（多出来的空行算不算？没法说清）
      expect(csv.contains('\n\n'), isFalse);
      expect(csv.contains('\r\n\r\n'), isFalse);
    });

    test('段 2 全空（全盘到了）时，抬头与列名**照样**渲染', () {
      // 缺了这一段会让人怀疑"是不是没导出全"。
      final s = SimpleExport.build(
        items: items(2),
        qty: <String, double>{
          '6901234567890': 1,
          '6901234567891': 1,
        },
      );
      expect(s.missing, isEmpty);
      final csv = SimpleExport.toCsv(s);
      expect(csv, contains(SimpleExport.titleMissing));
      expect(SimpleExport.countRowsBySegment(csv)[SimpleExport.titleMissing], 0);
    });

    test('文件名带场景与任务号（仓库/卖场两轮不会混）', () {
      expect(SimpleExport.csvName('卖场', 'SMP-20260925-120000'),
          '简易盘点_卖场_SMP-20260925-120000.csv');
      // 场景标签是人给的，带 `/` 会把文件写成子目录 —— 必须消毒
      expect(SimpleExport.csvName('卖场/1', 'X').contains('/'), isFalse);
    });

    test('导出的文件能被自己的解析器读回来（行数与条码都对）', () {
      // 这是"别人拿那份文件改一改再导回来"的场景：我们自己的导出→导入
      // 必须自洽（长条码的 =" 包裹正好被 cleanBarcode 剥掉）。
      final s = SimpleExport.build(
        items: items(3),
        qty: <String, double>{
          '6901234567890': 2,
          '6901234567891': 1,
          '6901234567892': 5,
        },
      );
      final csv = SimpleExport.toCsv(s);
      final rows = SimpleRules.parseCsvRows(csv);
      // 找出"盘点数据"段下的数据行，把条码列剥一遍，应与清单一致
      final codes = <String>[];
      for (final r in rows) {
        if (r.length >= 3 && r.first.startsWith('="')) {
          codes.add(SimpleRules.cleanBarcode(r.first));
        }
      }
      expect(codes, <String>[
        '6901234567890',
        '6901234567891',
        '6901234567892',
      ]);
    });
  });
}
