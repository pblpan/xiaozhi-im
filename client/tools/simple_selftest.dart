// 简易盘点「纯逻辑层」的本地自测（**不需要 flutter**，直接 `dart run` 就能跑）。
//
// ── 为什么要有这个文件 ────────────────────────────────────────
// 这台机器上 `flutter test` 起不来（Dart 运行时的进程派生被拦，报
// `CreateFile failed 231`），而 `dart run` 一个纯脚本是好的。
// 简易盘点的风险几乎全在**纯逻辑**上（CSV 解析报数、同码累加、差异集限制、
// 三段行数），所以把这几条在这里先跑一遍，别等 CI 才发现。
//
// ⚠️ 它是**补充**不是替代：真机/CI 的 `test/simple_*.dart` 才是正式判据
//    （那边还覆盖仓库层，需要 sqflite）。这个文件只跑纯函数，所以只能 import
//    不依赖 Flutter 的 core 文件。
//
// 用法（在 client/ 下）：
//   ../../tools/flutter/bin/dart.bat run tools/simple_selftest.dart
import 'dart:convert';
import 'dart:io';

import '../lib/core/inventory_rules.dart';
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

void main() {
  // ============ 场景 ============
  section('场景');
  eq('卖场标签', SimpleScene.label('store'), '卖场');
  eq('仓库标签', SimpleScene.label('warehouse'), '仓库');
  ok('认得出两个合法场景',
      SimpleScene.isValid('store') && SimpleScene.isValid('warehouse'));
  ok('乱七八糟的值不是合法场景', !SimpleScene.isValid('Store') &&
      !SimpleScene.isValid('') &&
      !SimpleScene.isValid('门店'));
  eq('认不出的场景归一成卖场', SimpleScene.normalize('火星'), 'store');
  eq('null 归一成卖场', SimpleScene.normalize(null), 'store');
  eq('仓库归一还是仓库', SimpleScene.normalize('warehouse'), 'warehouse');

  // ============ 阶段 ============
  section('阶段（一趟）');
  eq('第1趟标签是初盘，不是"抽盘"', SimplePhase.label(SimplePhase.first), '初盘');
  eq('第3趟标签是差异复盘', SimplePhase.label(SimplePhase.third), '差异复盘');
  ok('🔴 第3趟标签不等于盘点那边的"抽盘"',
      SimplePhase.label(SimplePhase.third) != InvPhase.label(InvPhase.third));
  eq('第2趟显示"第 2 趟 · 复盘"', SimplePhase.tripLabel(SimplePhase.second),
      '第 2 趟 · 复盘');
  eq('数值与盘点共用', SimplePhase.first, InvPhase.first);
  ok('只有第3趟受差异集限制',
      SimplePhase.onlyDiffSet(3) && !SimplePhase.onlyDiffSet(1) &&
          !SimplePhase.onlyDiffSet(2));
  eq('初盘没有上一趟', SimplePhase.prev(SimplePhase.first), null);
  eq('复盘上一趟是初盘', SimplePhase.prev(SimplePhase.second), 1);
  eq('复盘下一趟是差异复盘', SimplePhase.next(SimplePhase.second), 3);

  // ============ 扫码准入 ============
  section('扫码准入判定');
  SimpleScanDecision d({
    int phase = 1,
    bool editable = true,
    int rows = 0,
    bool already = false,
    Set<String>? allowed,
    bool inList = true,
    int max = SimpleRules.maxRowsPerNode,
    String barcode = '6901234567890',
  }) =>
      SimpleRules.decide(
        phase: phase,
        barcode: barcode,
        sheetEditable: editable,
        currentRows: rows,
        alreadyInNode: already,
        allowedBarcodes: allowed,
        inImportedList: inList,
        maxRows: max,
      );

  ok('本趟已完成 → 拒', !d(editable: false).accepted);
  eq('完成的文案对齐"撤销"口径', d(editable: false).verdict,
      SimpleScanVerdict.sheetLocked);

  ok('到达条数上限 → 拒', !d(rows: 5, max: 5).accepted);
  eq('上限的 verdict', d(rows: 5, max: 5).verdict, SimpleScanVerdict.phaseLimit);
  ok('上限差一个还放行', d(rows: 4, max: 5).accepted);
  // 🔴 反向：同码累加**不算新行**，不能被上限拦掉
  ok('🔴 本趟已扫过的码，即使满了也要放行（累加不算新行）',
      d(rows: 5, max: 5, already: true).accepted);

  // 🔴 差异集：只有第3趟看它
  final diffSet = <String>{'A', 'B'};
  ok('差异复盘扫差异集内 → 放行',
      d(phase: 3, allowed: diffSet, barcode: 'A').accepted);
  ok('差异复盘扫差异集外 → 拒',
      !d(phase: 3, allowed: diffSet, barcode: 'Z').accepted);
  eq('差异集外的 verdict', d(phase: 3, allowed: diffSet, barcode: 'Z').verdict,
      SimpleScanVerdict.notInDiffSet);
  // 🔴 这条是本通道最容易做歪的一处：复盘**不受**差异集限制
  ok('🔴 复盘即使传了差异集也**不许**限制它（否则复盘变走过场）',
      d(phase: 2, allowed: diffSet, barcode: 'Z').accepted);
  ok('初盘传了差异集也不限制', d(phase: 1, allowed: diffSet, barcode: 'Z').accepted);
  ok('差异复盘传 null（不限制）不误拒',
      d(phase: 3, allowed: null, barcode: 'Z').accepted);

  // 清单外不拦
  ok('🔴 清单外的商品**必须放行**（口径：不拦，导出作第三段）',
      d(inList: false).accepted);
  eq('清单外给的是 okOffList', d(inList: false).verdict,
      SimpleScanVerdict.okOffList);
  ok('清单外要挂黄条', d(inList: false).warned);
  ok('清单内不挂黄条', !d(inList: true).warned);
  ok('清单外也带一句人话', (d(inList: false).message ?? '').isNotEmpty);

  // 数量
  section('数量校验');
  eq('1 合法', SimpleRules.parseQty('1'), 1.0);
  eq('1.25 合法（称重）', SimpleRules.parseQty('1.25'), 1.25);
  eq('0 不合法', SimpleRules.parseQty('0'), null);
  eq('负数不合法', SimpleRules.parseQty('-2'), null);
  eq('空不合法', SimpleRules.parseQty('  '), null);
  eq('文字不合法', SimpleRules.parseQty('abc'), null);
  ok('非法数量都给得出一句人话', SimpleRules.qtyError('abc') != null &&
      SimpleRules.qtyError('0') != null &&
      SimpleRules.qtyError('') != null);
  eq('合法数量没有错误话', SimpleRules.qtyError('2'), null);

  // ============ CSV 解析 ============
  section('CSV 解析');
  {
    // 有表头、列顺序被打乱
    const csv = '名称,商品条码,规格\r\n'
        '农夫山泉 550ml,6901234567890,550ml\r\n'
        '可乐,6901234567891,330ml\r\n';
    final r = SimpleRules.parseCsv(csv);
    eq('读到 2 行', r.readLines, 2);
    eq('导入 2 条', r.kept, 2);
    eq('列顺序乱也能认对条码', r.rows.first.barcode, '6901234567890');
    eq('列顺序乱也能认对名称', r.rows.first.name, '农夫山泉 550ml');
    eq('规格也认了', r.rows.first.spec, '550ml');
    eq('seq 从 1 开始', r.rows.first.seq, 1);
    eq('seq 递增', r.rows[1].seq, 2);
  }
  {
    // 无表头：第 1 列条码、第 2 列名称
    const csv = '6901234567890,农夫山泉\n6901234567891,可乐\n';
    final r = SimpleRules.parseCsv(csv);
    eq('无表头导入 2 条', r.kept, 2);
    eq('无表头第 1 列是条码', r.rows.first.barcode, '6901234567890');
    eq('无表头第 2 列是名称', r.rows.first.name, '农夫山泉');
  }
  {
    // BOM + Excel 文本公式 + 空格 + 空行 + 重复 + 空条码
    const csv = '\uFEFF商品条码,商品名称\n'
        '="6901234567890",农夫山泉\n'
        '690 1234 567891,可乐\n'
        '\n'
        '6901234567890,农夫山泉（重复行）\n'
        ',没有条码的行\n'
        '   \n'
        "'6901234567892,带单引号\n";
    final r = SimpleRules.parseCsv(csv);
    eq('BOM 不影响表头识别', r.kept, 3);
    eq('🔴 读到的行数 = 导入 + 重复 + 没条码（这条是硬判据）',
        r.readLines, r.kept + r.dupSkipped + r.noBarcodeSkipped);
    // 7 个物理行里，1 个表头 + 2 个空白行不算 → 5 个有效数据行。
    // ⚠️ "读到多少行"报的是**有效数据行**，不是物理行 —— 空白行（Excel 存出来的
    //    CSV 末尾常有一堆）不该混进这个数，否则员工拿 1000 行的文件导进来
    //    看到"读到 1003 行"会以为文件不对。
    eq('读到 5 行（表头与空白行都不算）', r.readLines, 5);
    eq('重复 1 条', r.dupSkipped, 1);
    eq('没条码 1 条', r.noBarcodeSkipped, 1);
    eq('剥掉 Excel 的 =" 包裹', r.rows[0].barcode, '6901234567890');
    eq('条码里的空格被去掉', r.rows[1].barcode, '6901234567891');
    eq('剥掉前导单引号', r.rows[2].barcode, '6901234567892');
    eq('重复只留第一次那个（不是后面的）', r.rows[0].name, '农夫山泉');
    ok('报数文案带上了三个数', r.report.contains('5 行') &&
        r.report.contains('导入 3 条') &&
        r.report.contains('重复 1') &&
        r.report.contains('没条码 1'),
        '实际报告：${r.report}');
  }
  {
    // 引号包裹 + 字段内逗号（真实商品名里就有逗号）
    const csv = '条码,名称\n6901234567890,"苹果,红富士"\n';
    final r = SimpleRules.parseCsv(csv);
    eq('带逗号的商品名不被切成两列', r.rows.first.name, '苹果,红富士');
    eq('还是 1 条', r.kept, 1);
  }
  {
    // 引号翻倍
    const csv = '条码,名称\n6901234567890,"5""寸碗"\n';
    final r = SimpleRules.parseCsv(csv);
    eq('引号翻倍还原成 5"寸碗', r.rows.first.name, '5"寸碗');
  }
  {
    // 字段内换行（最阴的一种）
    const csv = '条码,名称\n6901234567890,"多行\n商品名"\n6901234567891,正常\n';
    final r = SimpleRules.parseCsv(csv);
    eq('字段内换行不会多出假条码', r.kept, 2);
    eq('字段内的换行被保留', r.rows.first.name, '多行\n商品名');
    eq('下一个条码正常', r.rows[1].barcode, '6901234567891');
  }
  {
    // 全空
    final r = SimpleRules.parseCsv('\n\n  \n');
    ok('全空文件导不进东西', r.isEmpty);
    eq('全空报 0 行', r.readLines, 0);
    ok('全空给得出原因', (r.emptyReason ?? '').isNotEmpty);
  }
  {
    // 有行但条码列全空
    const csv = '条码,名称\n,甲\n,乙\n';
    final r = SimpleRules.parseCsv(csv);
    ok('全都没条码 → 空', r.isEmpty);
    eq('两条都算没条码', r.noBarcodeSkipped, 2);
    ok('给的原因指向"是不是选错了列"',
        (r.emptyReason ?? '').contains('列'));
  }
  {
    // 只有表头的文件
    const csv = '商品条码,商品名称\n';
    final r = SimpleRules.parseCsv(csv);
    ok('只有表头 = 空', r.isEmpty);
    eq('只有表头读到 0 行', r.readLines, 0);
  }

  // ============ 文件编码闸门 ============
  section('编码闸门（整个导入最容易"看起来成功"的一处）');
  {
    // 纯 ASCII：UTF-8 与 GBK 完全一致，照常放行
    final ascii = SimpleRules.decodeCsvBytes(
        'barcode,name\n6901234567890,abc\n'.codeUnits);
    ok('纯 ASCII 的文件能读', ascii.ok);
    ok('纯 ASCII 读出来内容对', (ascii.text ?? '').contains('6901234567890'));

    // 正常 UTF-8（我们自己导出的文件：带 BOM）
    // ⚠️ 必须用 utf8.encode 造字节，不能用 `String.codeUnits` —— 后者给的是
    //    **UTF-16 码元**，中文 (>127) 直接拼进去就不是合法 UTF-8 了。
    //    （第一版就是这么错的，结果闸门把正确的文件也拒了。）
    final bom = <int>[
      0xEF, 0xBB, 0xBF,
      ...utf8.encode('商品条码,商品名称\n6901234567890,农夫山泉\n'),
    ];
    final r1 = SimpleRules.decodeCsvBytes(bom);
    ok('带 BOM 的 UTF-8 能读', r1.ok, '错误=${r1.error}');
    ok('BOM 被剥掉（否则表头认不出来）',
        (r1.text ?? '').isNotEmpty && !(r1.text!).startsWith('\uFEFF'),
        '首字符码=${(r1.text ?? 'x').codeUnitAt(0)}');
    final parsed = SimpleRules.parseCsv(r1.text ?? '');
    eq('带 BOM 的文件表头能认出来', parsed.rows.first.name, '农夫山泉');

    // 🔴 真 GBK 字节："中文" 在 GBK 里是 D6 D0 CE C4
    final gbk = <int>[
      ...'6901234567890,'.codeUnits,
      0xD6, 0xD0, 0xCE, 0xC4, // 中文（GBK）
    ];
    final r2 = SimpleRules.decodeCsvBytes(gbk);
    ok('🔴 GBK 文件必须被拒绝（不能硬读成乱码）', !r2.ok);
    ok('拒绝时给的是可执行的话（指明另存为 CSV UTF-8）',
        (r2.error ?? '').contains('UTF-8') && (r2.error ?? '').contains('另存为'),
        '实际：${r2.error}');
    // 反向：如果拿宽松解码，"中文"会变成两个替换字符 —— 这就是我们要挡掉的结果
    final loose = String.fromCharCodes(gbk);
    ok('（对照）宽松解码下这些字节确实是坏的', loose.contains('\uFFFD') ||
        !loose.contains('中文'));

    // UTF-16（Excel 的"Unicode 文本"）单独一句更准的话
    final u16 = <int>[0xFF, 0xFE, 0x31, 0x00, 0x32, 0x00];
    final r3 = SimpleRules.decodeCsvBytes(u16);
    ok('UTF-16 也被拒', !r3.ok);
    ok('UTF-16 的话不一样（指明是「Unicode 文本」）',
        (r3.error ?? '').contains('UTF-16'), '实际：${r3.error}');

    ok('空文件不崩', SimpleRules.decodeCsvBytes(<int>[]).ok);
  }

  // ============ 汇总 ============
  stdout.writeln('\n──────────────────────────────');
  if (_fail.isEmpty) {
    stdout.writeln('✅ 纯逻辑自测全过：$_pass 项');
  } else {
    stdout.writeln('❌ $_pass 项通过，${_fail.length} 项失败：');
    for (final f in _fail) {
      stdout.writeln('   · $f');
    }
  }
  exit(_fail.isEmpty ? 0 : 1);
}
