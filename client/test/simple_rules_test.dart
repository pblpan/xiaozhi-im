import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:xiaozhi_im_client/core/inventory_rules.dart';
import 'package:xiaozhi_im_client/core/simple_rules.dart';

/// 简易盘点「纯规则层」的测试：场景、阶段标签、扫码准入、CSV 清单解析、编码闸门。
///
/// 这一层是最该被钉死的地方 —— 口径判错了不会报错，只会**安静地算错数**：
///   · 把清单外的商品拦掉 → 现场干不了活；
///   · 复盘也被差异集限制 → 复盘变成走过场；
///   · CSV 把重复/空条码悄悄吞掉不报数 → 导错了没人知道；
///   · GBK 文件硬读成乱码 → "导入成功、名字全是问号"。
///
/// ⚠️ 本机另有一份 `tools/simple_selftest.dart`（同样的断言、纯 Dart 可跑）——
///    那台机器 `flutter test` 起不来（Dart 进程派生被拦，CreateFile failed 231），
///    所以那份是**预检**，正式判据是本文件。
void main() {
  group('场景', () {
    test('两个合法场景与它们的标签', () {
      expect(SimpleScene.label('store'), '卖场');
      expect(SimpleScene.label('warehouse'), '仓库');
      expect(SimpleScene.isValid('store'), isTrue);
      expect(SimpleScene.isValid('warehouse'), isTrue);
    });

    test('认不出的场景不算合法（大小写、空、中文都不行）', () {
      expect(SimpleScene.isValid('Store'), isFalse);
      expect(SimpleScene.isValid(''), isFalse);
      expect(SimpleScene.isValid('门店'), isFalse);
    });

    test('落库前归一：认不出的当卖场，而不是抛异常', () {
      // 员工在界面上根本没有机会传出别的值；真传进来了也不能让整条链路崩。
      expect(SimpleScene.normalize('火星'), SimpleScene.store);
      expect(SimpleScene.normalize(null), SimpleScene.store);
      expect(SimpleScene.normalize('  '), SimpleScene.store);
      expect(SimpleScene.normalize('warehouse'), SimpleScene.warehouse);
    });
  });

  group('阶段（一趟）', () {
    test('数值与「盘点」共用 1/2/3（同一列 scan_record.phase）', () {
      expect(SimplePhase.first, InvPhase.first);
      expect(SimplePhase.second, InvPhase.second);
      expect(SimplePhase.third, InvPhase.third);
    });

    test('🔴 标签**不同**于盘点：第 3 趟这里是"差异复盘"，不是"抽盘"', () {
      // 共用一个 InvPhase.label 会让本页显示"抽盘"——那是主管抽查的意思，
      // 与"前两趟对不上的再核准一遍"完全不是一回事。
      expect(SimplePhase.label(SimplePhase.first), '初盘');
      expect(SimplePhase.label(SimplePhase.second), '复盘');
      expect(SimplePhase.label(SimplePhase.third), '差异复盘');
      expect(SimplePhase.label(SimplePhase.third),
          isNot(InvPhase.label(InvPhase.third)));
    });

    test('趟次编号与显示', () {
      expect(SimplePhase.tripNo(SimplePhase.first), 1);
      expect(SimplePhase.tripNo(SimplePhase.third), 3);
      expect(SimplePhase.tripLabel(SimplePhase.second), '第 2 趟 · 复盘');
    });

    test('🔴 只有第 3 趟受差异集限制（复盘不受）', () {
      expect(SimplePhase.onlyDiffSet(SimplePhase.third), isTrue);
      expect(SimplePhase.onlyDiffSet(SimplePhase.second), isFalse,
          reason: '复盘受限 = 默认初盘是对的 = 复盘走过场');
      expect(SimplePhase.onlyDiffSet(SimplePhase.first), isFalse);
    });

    test('上一趟 / 下一趟', () {
      expect(SimplePhase.prev(SimplePhase.first), isNull);
      expect(SimplePhase.prev(SimplePhase.second), SimplePhase.first);
      expect(SimplePhase.next(SimplePhase.second), SimplePhase.third);
      expect(SimplePhase.next(SimplePhase.third), isNull);
    });
  });

  group('扫码准入判定', () {
    SimpleScanDecision d({
      int phase = SimplePhase.first,
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

    test('本趟已完成 → 拒，并提示去撤销', () {
      final r = d(editable: false);
      expect(r.accepted, isFalse);
      expect(r.verdict, SimpleScanVerdict.sheetLocked);
      expect(r.message, contains('撤销'));
    });

    test('到达条数上限 → 拒，提示先完成本趟', () {
      final r = d(rows: 5, max: 5);
      expect(r.accepted, isFalse);
      expect(r.verdict, SimpleScanVerdict.phaseLimit);
      expect(r.message, isNotEmpty);
      expect(d(rows: 4, max: 5).accepted, isTrue, reason: '差一个还放行');
    });

    test('🔴 同码累加**不算新行**：即使满了也要放行', () {
      // 否则扫第 500 个商品的第二件会被以"上限"为由拒掉，员工完全懵。
      expect(d(rows: 5, max: 5, already: true).accepted, isTrue);
      expect(d(rows: 99, max: 5, already: true, phase: SimplePhase.second)
          .accepted, isTrue);
    });

    test('差异复盘（第 3 趟）：只许扫差异集', () {
      final diff = <String>{'A', 'B'};
      expect(d(phase: SimplePhase.third, allowed: diff, barcode: 'A').accepted,
          isTrue);
      final r = d(phase: SimplePhase.third, allowed: diff, barcode: 'Z');
      expect(r.accepted, isFalse);
      expect(r.verdict, SimpleScanVerdict.notInDiffSet);
      expect(r.message, contains('差异'));
    });

    test('🔴 复盘（第 2 趟）即使被传了差异集也**不许**限制它', () {
      // 判定层自己再卡一道 onlyDiffSet，不能只靠调用方自觉 ——
      // 这条是方案 §2 规矩 4 明确点名的坑。
      final diff = <String>{'A'};
      expect(d(phase: SimplePhase.second, allowed: diff, barcode: 'Z').accepted,
          isTrue);
      expect(d(phase: SimplePhase.first, allowed: diff, barcode: 'Z').accepted,
          isTrue);
    });

    test('差异复盘传 null（不限制）不误拒', () {
      expect(d(phase: SimplePhase.third, allowed: null, barcode: 'Z').accepted,
          isTrue);
    });

    test('🔴 清单外的商品**必须放行**（口径：不拦，导出作第三段）', () {
      final r = d(inList: false);
      expect(r.accepted, isTrue);
      expect(r.verdict, SimpleScanVerdict.okOffList);
      expect(r.warned, isTrue);
      expect(r.message, isNotEmpty);
      // 反向：清单内的不该挂黄条（否则"提醒"天天响，就没人看了）
      expect(d(inList: true).warned, isFalse);
      expect(d(inList: true).verdict, SimpleScanVerdict.ok);
    });

    test('判定顺序：单据锁死优先于上限与差异集', () {
      final r = d(
          editable: false, rows: 99, max: 1, phase: SimplePhase.third,
          allowed: const <String>{}, barcode: 'Z');
      expect(r.verdict, SimpleScanVerdict.sheetLocked);
    });
  });

  group('数量校验', () {
    test('合法：整数与小数（称重按公斤）', () {
      expect(SimpleRules.parseQty('1'), 1.0);
      expect(SimpleRules.parseQty('1.25'), 1.25);
      expect(SimpleRules.parseQty(' 3 '), 3.0);
      expect(SimpleRules.qtyError('2'), isNull);
    });

    test('不合法：空 / 0 / 负数 / 文字 / 非有限', () {
      for (final bad in <String>['', '  ', '0', '-2', 'abc', 'NaN', 'Infinity']) {
        expect(SimpleRules.parseQty(bad), isNull, reason: bad);
        expect(SimpleRules.qtyError(bad), isNotNull, reason: bad);
      }
    });
  });

  group('CSV 清单解析', () {
    test('有表头：列顺序随便都能认对', () {
      const csv = '名称,商品条码,规格\r\n'
          '农夫山泉 550ml,6901234567890,550ml\r\n'
          '可乐,6901234567891,330ml\r\n';
      final r = SimpleRules.parseCsv(csv);
      expect(r.readLines, 2);
      expect(r.kept, 2);
      expect(r.rows.first.barcode, '6901234567890');
      expect(r.rows.first.name, '农夫山泉 550ml');
      expect(r.rows.first.spec, '550ml');
      expect(r.rows[0].seq, 1);
      expect(r.rows[1].seq, 2);
    });

    test('表头别名：条形码 / barcode / 品名', () {
      for (final head in <String>['条码', '商品条码', '条形码', 'barcode']) {
        final r = SimpleRules.parseCsv('$head,名称\n6901234567890,甲\n');
        expect(r.rows.first.barcode, '6901234567890', reason: head);
        expect(r.rows.first.name, '甲', reason: head);
      }
    });

    test('没表头：第 1 列条码、第 2 列名称', () {
      final r = SimpleRules.parseCsv('6901234567890,农夫山泉\n6901234567891,可乐\n');
      expect(r.kept, 2);
      expect(r.rows.first.barcode, '6901234567890');
      expect(r.rows.first.name, '农夫山泉');
    });

    test('🔴 读到的行数 = 导入 + 跳过重复 + 跳过没条码（硬判据）', () {
      // 不成立就说明有行被悄悄吃掉了 —— 而员工拿 1000 行的文件导入，
      // 只会看到"导入 998 条"，剩下 2 条去哪了没人知道。
      const csv = '\uFEFF商品条码,商品名称\n'
          '="6901234567890",农夫山泉\n'
          '690 1234 567891,可乐\n'
          '\n'
          '6901234567890,重复行\n'
          ',没有条码的行\n'
          '   \n'
          "'6901234567892,带单引号\n";
      final r = SimpleRules.parseCsv(csv);
      expect(r.readLines, r.kept + r.dupSkipped + r.noBarcodeSkipped);
      expect(r.readLines, 5, reason: '表头与空白行都不算');
      expect(r.kept, 3);
      expect(r.dupSkipped, 1);
      expect(r.noBarcodeSkipped, 1);
    });

    test('条码清洗：Excel 的 =" 包裹 / 空格 / 前导单引号', () {
      final r = SimpleRules.parseCsv('商品条码,商品名称\n'
          '="6901234567890",甲\n'
          '690 1234 567891,乙\n'
          "'6901234567892,丙\n");
      expect(r.rows[0].barcode, '6901234567890');
      expect(r.rows[1].barcode, '6901234567891');
      expect(r.rows[2].barcode, '6901234567892');
    });

    test('重复条码只留**第一条**（不是最后一条）', () {
      final r = SimpleRules.parseCsv(
          '条码,名称\n6901234567890,第一次\n6901234567890,第二次\n');
      expect(r.kept, 1);
      expect(r.dupSkipped, 1);
      expect(r.rows.first.name, '第一次');
    });

    test('报数文案把三个数都写出来', () {
      final r = SimpleRules.parseCsv('条码,名称\n6901234567890,甲\n,乙\n');
      expect(r.report, contains('2 行'));
      expect(r.report, contains('导入 1 条'));
      expect(r.report, contains('没条码 1'));
    });

    test('🔴 引号包裹 + 字段内逗号：商品名不被冲成两列', () {
      // "苹果,红富士" 是真实存在的商品名；不按 RFC4180 解析的话，
      // 一个商品会变成"条码 + 半截名 + 一个假条码"，而且**看不出错**。
      final r = SimpleRules.parseCsv('条码,名称\n6901234567890,"苹果,红富士"\n');
      expect(r.kept, 1);
      expect(r.rows.first.name, '苹果,红富士');
    });

    test('引号翻倍还原', () {
      final r = SimpleRules.parseCsv('条码,名称\n6901234567890,"5""寸碗"\n');
      expect(r.rows.first.name, '5"寸碗');
    });

    test('🔴 字段内换行不会多出假条码', () {
      final r = SimpleRules.parseCsv(
          '条码,名称\n6901234567890,"多行\n商品名"\n6901234567891,正常\n');
      expect(r.kept, 2);
      expect(r.rows.first.name, '多行\n商品名');
      expect(r.rows[1].barcode, '6901234567891');
    });

    test('空文件 / 只有表头 / 全都没条码：都判空并给得出原因', () {
      for (final csv in <String>['\n\n  \n', '商品条码,商品名称\n', '条码,名称\n,甲\n,乙\n']) {
        final r = SimpleRules.parseCsv(csv);
        expect(r.isEmpty, isTrue, reason: csv);
        expect(r.emptyReason, isNotNull);
      }
      // "全都没条码"要指到"是不是选错了列"上 —— 这是最常见的用户错误
      expect(SimpleRules.parseCsv('条码,名称\n,甲\n').emptyReason, contains('列'));
    });
  });

  group('文件编码闸门', () {
    test('UTF-8（带 BOM，我们自己导出的那种）能读，且 BOM 被剥掉', () {
      final bytes = <int>[
        0xEF, 0xBB, 0xBF,
        ...utf8.encode('商品条码,商品名称\n6901234567890,农夫山泉\n'),
      ];
      final r = SimpleRules.decodeCsvBytes(bytes);
      expect(r.ok, isTrue, reason: r.error);
      expect(r.text!.startsWith('\uFEFF'), isFalse,
          reason: 'BOM 不清掉的话第一列表头就认不出来');
      expect(SimpleRules.parseCsv(r.text!).rows.first.name, '农夫山泉');
    });

    test('纯 ASCII 的文件能读（GBK 与 UTF-8 在 ASCII 上完全一致）', () {
      final r = SimpleRules.decodeCsvBytes(
          utf8.encode('barcode,name\n6901234567890,abc\n'));
      expect(r.ok, isTrue);
    });

    test('🔴 GBK 文件必须被拒绝，且给的话要可执行', () {
      // 中文 Windows 的 Excel 存"CSV(逗号分隔)"就是 GBK。
      // 条码是 ASCII、照读不误 —— 硬读下去会得到"条码全对、名字全是 �"，
      // 这是最像成功的一种坏结果（行数对得上、只有最后一列是坏的）。
      final gbk = <int>[
        ...utf8.encode('6901234567890,'),
        0xD6, 0xD0, 0xCE, 0xC4, // "中文" 的 GBK 字节
      ];
      final r = SimpleRules.decodeCsvBytes(gbk);
      expect(r.ok, isFalse);
      expect(r.error, contains('UTF-8'));
      expect(r.error, contains('另存为'));
    });

    test('UTF-16（Excel 的「Unicode 文本」）也给一句准确的话', () {
      final r = SimpleRules.decodeCsvBytes(
          <int>[0xFF, 0xFE, 0x31, 0x00, 0x32, 0x00]);
      expect(r.ok, isFalse);
      expect(r.error, contains('UTF-16'));
    });

    test('空文件不崩', () {
      expect(SimpleRules.decodeCsvBytes(<int>[]).ok, isTrue);
    });
  });
}
