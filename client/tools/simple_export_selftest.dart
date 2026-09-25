// 简易盘点「导出层」的本地自测（纯 Dart，`dart run` 可跑）。
// 见 tools/run_pure_tests.sh 的说明：这台机器上 flutter test 起不来，
// 所以纯逻辑先在这里跑，正式判据仍是 CI 上的 test/simple_export_test.dart。
import 'dart:io';

import '../lib/core/simple_export.dart';
import '../lib/core/simple_rules.dart';

int _pass = 0;
final List<String> _fail = <String>[];

void ok(String name, bool cond, [String? extra]) {
  if (cond) {
    _pass++;
  } else {
    _fail.add(extra == null ? name : '$name  ← $extra');
    stdout.writeln('  ✗ $name${extra == null ? '' : '  ← $extra'}');
  }
}

void eq(String name, Object? actual, Object? expected) =>
    ok(name, actual == expected, '实际=$actual 期望=$expected');

void section(String s) => stdout.writeln('\n── $s ──');

/// 造一批清单行。
List<Map<String, dynamic>> items(int n) => List<Map<String, dynamic>>.generate(
      n,
      (i) => <String, dynamic>{
        'barcode': '6901234${(567890 + i).toString().padLeft(6, '0')}',
        'name': '商品$i',
        'spec': null,
        'seq': i + 1,
      },
    );

void main() {
  // ============ 验收出口：导 1000 条 → 盘 50 个 → 导出 ============
  section('验收出口（方案 §6 S1）');
  {
    final list = items(1000);
    final qty = <String, double>{};
    for (var i = 0; i < 50; i++) {
      qty[list[i]['barcode'] as String] = 1;
    }
    final s = SimpleExport.build(items: list, qty: qty);
    eq('段1 = 盘到的 50', s.data.length, 50);
    eq('段2 = 没盘到的 950', s.missing.length, 950);
    eq('段3 = 0（没有清单外的）', s.extra.length, 0);
    eq('数据行合计 = 1000', s.totalRows, 1000);
    ok('🔴 硬判据：段1+段2 = 清单行数', s.data.length + s.missing.length == 1000);
    ok('accounted（没有商品被丢掉）', s.accounted);
    eq('importedCount = 1000', s.importedCount, 1000);

    final csv = SimpleExport.toCsv(s);
    final counts = SimpleExport.countRowsBySegment(csv);
    eq('从 CSV 读回来的段1', counts[SimpleExport.titleData], 50);
    eq('从 CSV 读回来的段2', counts[SimpleExport.titleMissing], 950);
    eq('从 CSV 读回来的段3', counts[SimpleExport.titleExtra], 0);
    ok('🔴 验收第7条：文件里的行数 = 段1+段2+段3',
        (counts[SimpleExport.titleData] ?? 0) +
                (counts[SimpleExport.titleMissing] ?? 0) +
                (counts[SimpleExport.titleExtra] ?? 0) ==
            1000);
    ok('CSV 带 BOM（Excel 双击不乱码）', csv.startsWith('\uFEFF'));
  }

  // ============ 三段的归属 ============
  section('三段归属');
  {
    final list = <Map<String, dynamic>>[
      <String, dynamic>{'barcode': 'A1', 'name': '甲', 'seq': 1},
      <String, dynamic>{'barcode': 'A2', 'name': '乙', 'seq': 2},
      <String, dynamic>{'barcode': 'A3', 'name': '丙', 'seq': 3},
    ];
    final s = SimpleExport.build(
      items: list,
      qty: <String, double>{'A1': 5, 'A3': 2, 'Z9': 7},
    );
    eq('清单内且有数 → 段1', s.data.length, 2);
    eq('清单内没数 → 段2', s.missing.length, 1);
    eq('段2 是那个没扫的', s.missing.rows.first.barcode, 'A2');
    eq('🔴 没盘到的数量写 0，不是留空', s.missing.rows.first.qty, 0.0);
    eq('清单外扫到的 → 段3', s.extra.length, 1);
    eq('段3 是那个清单外的', s.extra.rows.first.barcode, 'Z9');
    eq('段3 带实盘数', s.extra.rows.first.qty, 7.0);
    eq('段3 查不到名字给占位', s.extra.rows.first.name, SimpleExport.unknownName);
    ok('accounted', s.accounted);

    // 排序：段1、段2 都按导入顺序（未盘到的不排到最后）
    final list2 = <Map<String, dynamic>>[
      <String, dynamic>{'barcode': 'B1', 'name': '一', 'seq': 1},
      <String, dynamic>{'barcode': 'B2', 'name': '二', 'seq': 2},
      <String, dynamic>{'barcode': 'B3', 'name': '三', 'seq': 3},
    ];
    final s2 = SimpleExport.build(
      items: list2,
      qty: <String, double>{'B1': 1, 'B3': 1},
    );
    eq('段2 里那个没盘到的在它原来的位置（B2）', s2.missing.rows.first.barcode, 'B2');
    eq('段2 只有 1 行（B2 不排到最后也不会跑到段1）', s2.missing.length, 1);

    // 段3 按条码排
    final s3 = SimpleExport.build(
      items: list,
      qty: <String, double>{'A1': 1, 'Z9': 1, 'Y8': 1, 'X7': 1},
    );
    eq('段3 按条码升序',
        s3.extra.rows.map((r) => r.barcode).join(','), 'X7,Y8,Z9');
  }

  // ============ 差异待复核（S2 会用到；S1 恒为空） ============
  section('差异待复核（第4段）');
  {
    final list = <Map<String, dynamic>>[
      <String, dynamic>{'barcode': 'A1', 'name': '甲', 'seq': 1},
      <String, dynamic>{'barcode': 'A2', 'name': '乙', 'seq': 2},
      <String, dynamic>{'barcode': 'A3', 'name': '丙', 'seq': 3},
    ];
    final s = SimpleExport.build(
      items: list,
      qty: <String, double>{'A1': 5, 'A2': 3},
      pending: <String>{'A2'},
    );
    eq('待复核的**不**进段1', s.data.length, 1);
    eq('待复核的**也**不进段2（它明明盘到了）', s.missing.length, 1);
    eq('段2 是那个真没盘到的 A3', s.missing.rows.first.barcode, 'A3');
    eq('🔴 待复核的进第4段', s.pending.length, 1);
    eq('第4段数量列留空（不能替盘点员挑一个数）', s.pending.rows.first.qty, null);
    ok('🔴 accounted 把待复核也算上（三者必居其一）', s.accounted);
    eq('行数合计 = 清单行数（一条都没丢）', s.totalRows, 3);

    final csv = SimpleExport.toCsv(s);
    final counts = SimpleExport.countRowsBySegment(csv);
    eq('CSV 里有第4段', counts[SimpleExport.titlePending], 1);
    ok('第4段的抬头在文件里', csv.contains(SimpleExport.titlePending));
    ok('第4段那行数量列是空的（两个连续的逗号分隔）',
        csv.contains('A2,,乙') || csv.contains('"A2",,"乙"'));

    // 没有待复核时，第4段**不该**出现在文件里
    final clean = SimpleExport.toCsv(SimpleExport.build(
      items: list,
      qty: <String, double>{'A1': 5, 'A2': 3, 'A3': 1},
    ));
    ok('没有待复核时文件里没有第4段抬头',
        !clean.contains(SimpleExport.titlePending));
    eq('正常三段的行数合计 = 3',
        SimpleExport.countRowsBySegment(clean)
            .values
            .fold<int>(0, (a, b) => a + b),
        3);
  }

  // ============ 清单外的边界 ============
  section('清单外的边界');
  {
    final list = <Map<String, dynamic>>[
      <String, dynamic>{'barcode': 'A1', 'name': '甲', 'seq': 1},
    ];
    final s = SimpleExport.build(
      items: list,
      qty: <String, double>{'A1': 1, 'ZZ': 0},
    );
    eq('清单外但数量 0 → 不进段3（它本来就没扫到）', s.extra.length, 0);
    ok('accounted 只算清单内的', s.accounted);

    // 清单里数量 0 的行：按"没盘到"处理
    final s2 = SimpleExport.build(
      items: list,
      qty: <String, double>{'A1': 0},
    );
    eq('清单里有 0 的数 → 当没盘到（写 0）', s2.missing.length, 1);
    eq('不会同时出现在段1', s2.data.length, 0);
  }

  // ============ CSV 细节 ============
  section('CSV 细节');
  {
    final list = <Map<String, dynamic>>[
      <String, dynamic>{'barcode': '6901234567890', 'name': '农夫山泉 550ml', 'seq': 1},
      <String, dynamic>{'barcode': '007', 'name': '苹果,红富士', 'seq': 2},
    ];
    final csv = SimpleExport.toCsv(
      SimpleExport.build(items: list, qty: <String, double>{'6901234567890': 2, '007': 1}),
    );
    final rows = SimpleRules.parseCsvRows(csv);

    ok('抬头「盘点数据」在第一个有效行', rows.first.first == SimpleExport.titleData);
    ok('列名三列照龙哥说的顺序',
        rows[1].join(',') == '商品条码,商品盘点数量,商品名称',
        '实际=${rows[1].join(',')}');

    // 长条码：CSV 读回来是 ="690..."，Excel 打开后求值成文本条码
    ok('🔴 长条码写成 Excel 文本公式（防科学计数法）',
        rows[2].first == '="6901234567890"', '实际=${rows[2].first}');
    eq('数量是整数不带小数点', rows[2][1], '2');
    eq('商品名原样', rows[2][2], '农夫山泉 550ml');

    // 短数字条码不加 ="" （加了平白变成公式）
    ok('短条码不套 ="" ', !rows[3].first.contains('='), '实际=${rows[3].first}');
    eq('带逗号的商品名被正确转义后仍是一列', rows[3][2], '苹果,红富士');
    eq('带逗号的行没被切成 4 列', rows[3].length, 3);

    // 三个抬头都在，且按顺序
    final t1 = csv.indexOf(SimpleExport.titleData);
    final t2 = csv.indexOf(SimpleExport.titleMissing);
    final t3 = csv.indexOf(SimpleExport.titleExtra);
    ok('三段抬头都在且按 1→2→3 顺序', t1 >= 0 && t1 < t2 && t2 < t3,
        '位置=$t1,$t2,$t3');
    ok('没有空行（空行会让"数行数"这条判据失真）',
        !csv.contains('\n\n') && !csv.contains('\r\n\r\n'));

    // 文件名
    eq('文件名带场景与任务号',
        SimpleExport.csvName('卖场', 'SMP-20260925-120000'),
        '简易盘点_卖场_SMP-20260925-120000.csv');
    ok('文件名消毒：场景里带斜杠也不会写出子目录',
        !SimpleExport.csvName('卖场/1', 'X').contains('/'));
  }

  // ============ 汇总 ============
  stdout.writeln('\n──────────────────────────────');
  if (_fail.isEmpty) {
    stdout.writeln('✅ 导出层自测全过：$_pass 项');
  } else {
    stdout.writeln('❌ $_pass 项通过，${_fail.length} 项失败：');
    for (final f in _fail) {
      stdout.writeln('   · $f');
    }
  }
  exit(_fail.isEmpty ? 0 : 1);
}
