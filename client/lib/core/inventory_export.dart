import 'csv_fmt.dart';
import 'inventory_rules.dart';
import 'qty_fmt.dart';

/// 盘点导出的排版层（**纯函数**，一行 IO 都没有）。
///
/// 导出的东西有两份，用途完全不同，别混：
///   · 采集明细 —— 这一张单扫了什么，用来核对"我到底扫了没扫"
///   · 阶段差异 —— 该点位某阶段"和**上一次盘的数量**对不上"的差异集
///     （含上一遍盘过、这一遍没扫到的"漏盘"）+ 失误笔数，
///     这才是要发给主管/老板的那份。
///
/// 文件名前缀一律 `盘点_`，和扫码枪（`扫码_`）区分开 ——
/// 两个模块共用本地流水表，导出文件再同名的话，收到的同事根本分不清哪份是哪份。
class InventoryExport {
  InventoryExport._();

  /// 采集明细的列
  static const List<String> rowHeaders = <String>[
    '条码',
    '商品名称',
    '规格',
    '单位',
    '实盘数量',
    '账面数量',
    '差异数量',
    '货架位',
  ];

  /// 阶段差异表的列。
  ///
  /// 🔴 差异是**跟上一次盘的数量比**算出来的，不是跟账面比 ——
  ///    所以必有一列是"上一阶段"。账面数只作参考列（门店的系统里
  ///    没有可用的库存账面，拿它当基准会得到一个等于全部商品的差异集）。
  ///    `备注` 列专门标"漏盘"：上一遍盘过、这一遍没扫到，
  ///    这种行数量是 0、看着像"盘得挺准"，不标出来就等于没有。
  static const List<String> diffHeaders = <String>[
    '条码',
    '商品名称',
    '规格',
    '单位',
    '实盘数量',
    '上一阶段数量',
    '差异数量',
    '差异金额',
    '账面数量',
    '备注',
  ];

  /// 采集明细 → CSV（带 UTF-8 BOM）。
  ///
  /// 🔴 BOM 必须带：不带的话 Excel/WPS 会按本地 GBK 打开，
  ///    中文商品名全是乱码 —— 现场第一反应是"导出的文件坏了"。
  static String toRowsCsv(List<Map<String, dynamic>> rows) {
    final b = StringBuffer('\uFEFF');
    b.writeln(rowHeaders.map(csvEsc).join(','));
    for (final r in rows) {
      b.writeln(<String>[
        csvEsc(barcodeCsvCell(r['barcode'])),
        csvEsc(nameOf(r)),
        csvEsc(r['spec']),
        csvEsc(r['unit']),
        csvEsc(fmtQty(r['qty'])),
        r['account_qty'] == null ? '' : csvEsc(fmtQty(r['account_qty'])),
        r['diff_qty'] == null ? '' : csvEsc(fmtQty(r['diff_qty'])),
        csvEsc(r['loc_code']),
      ].join(','));
    }
    return b.toString();
  }

  /// 采集明细 → 文本文档（微信里点开就能看，不用装 Excel）
  static String toRowsDoc(
    List<Map<String, dynamic>> rows, {
    required String sheetNo,
    required String zoneName,
    required String phaseLabel,
  }) {
    final b = StringBuffer()
      ..writeln('盘点明细 · $phaseLabel')
      ..writeln('盘点单号：$sheetNo')
      ..writeln('盘点位：$zoneName')
      ..writeln('导出时间：${_now()}')
      ..writeln('品种数：${rows.length}')
      ..writeln('─' * 30);
    var i = 0;
    for (final r in rows) {
      i++;
      final diff = r['diff_qty'];
      b.writeln('$i. ${nameOf(r)}');
      b.writeln('   条码：${r['barcode']}');
      b.writeln('   实盘：${fmtQty(r['qty'])}${_unit(r)}'
          '${r['account_qty'] == null ? '　账面：无此商品' : '　账面：${fmtQty(r['account_qty'])}'}');
      if (diff != null && (diff as num).toDouble() != 0) {
        b.writeln('   差异：${fmtQty(diff)}');
      }
      if ((r['loc_code'] ?? '').toString().isNotEmpty) {
        b.writeln('   货架位：${r['loc_code']}');
      }
    }
    return b.toString();
  }

  /// 阶段差异表 → CSV（带 BOM）
  static String toDiffCsv(List<Map<String, dynamic>> rows) {
    final b = StringBuffer('\uFEFF');
    b.writeln(diffHeaders.map(csvEsc).join(','));
    for (final r in rows) {
      b.writeln(<String>[
        csvEsc(barcodeCsvCell(r['barcode'])),
        csvEsc(nameOf(r)),
        csvEsc(r['spec']),
        csvEsc(r['unit']),
        csvEsc(fmtQty(r['qty'])),
        r['prev_qty'] == null ? '' : csvEsc(fmtQty(r['prev_qty'])),
        r['diff_qty'] == null ? '' : csvEsc(fmtQty(r['diff_qty'])),
        amtOf(r) == null ? '' : csvEsc(amtOf(r)!.toStringAsFixed(2)),
        r['account_qty'] == null ? '' : csvEsc(fmtQty(r['account_qty'])),
        csvEsc(r['missing'] == true ? '漏盘' : ''),
      ].join(','));
    }
    return b.toString();
  }

  /// 阶段差异表 → 文本文档（主管在群里就能看，带失误笔数）
  static String toDiffDoc(
    List<Map<String, dynamic>> rows, {
    required String zoneName,
    required String phaseLabel,
    required int mistakes,
  }) {
    var loss = 0.0;   // 盘亏（这一遍比上一遍少）
    var gain = 0.0;   // 盘盈
    var noAccount = 0; // 账上没有这个商品
    var missed = 0;    // 漏盘：上一遍盘过、这一遍没扫到
    for (final r in rows) {
      if (r['missing'] == true) missed++;
      if (r['account_qty'] == null) {
        noAccount++;
      }
      final a = amtOf(r);
      if (a == null) continue;
      if (a < 0) {
        loss += -a;
      } else {
        gain += a;
      }
    }

    final b = StringBuffer()
      ..writeln('盘点差异表 · $phaseLabel')
      ..writeln('盘点位：$zoneName')
      ..writeln('导出时间：${_now()}')
      ..writeln('─' * 30)
      ..writeln('差异品种：${rows.length}')
      ..writeln('其中漏盘（上一遍有、这一遍没扫到）：$missed')
      ..writeln('盘亏金额：${loss.toStringAsFixed(2)}')
      ..writeln('盘盈金额：${gain.toStringAsFixed(2)}')
      ..writeln('账面缺失（账上没有这商品）：$noAccount')
      ..writeln('本阶段失误笔数：$mistakes')
      ..writeln('─' * 30);

    var i = 0;
    for (final r in rows) {
      i++;
      final acc = r['account_qty'];
      final p = r['prev_qty'];
      final miss = r['missing'] == true;
      b.writeln('$i. ${nameOf(r)}　${r['barcode']}${miss ? '　【漏盘】' : ''}');
      b.writeln('   实盘 ${fmtQty(r['qty'])}${_unit(r)}'
          '　上一遍 ${p == null ? '（没盘过）' : fmtQty(p)}'
          '　差异 ${r['diff_qty'] == null ? '—' : fmtQty(r['diff_qty'])}');
      b.writeln('   账面 ${acc == null ? '（账上没有）' : fmtQty(acc)}');
      final a = amtOf(r);
      if (a != null) b.writeln('   差异金额：${a.toStringAsFixed(2)}');
    }
    return b.toString();
  }

  /// 差异金额 = 差异数量 × 单价。缺单价或差异时返回 null（不是 0 ——
  /// "不知道差多少钱"和"差 0 元"是两回事，写 0 会让合计看着很安心）。
  /// 差异数量是**比上一阶段**算的，所以这个金额是"这一遍和上一遍差的钱"，
  /// 不是"和账面差的钱"（门店没有可用的账面数）。
  static double? amtOf(Map<String, dynamic> r) {
    final d = _d(r['diff_qty']);
    final p = _d(r['unit_price']);
    if (d == null || p == null) return null;
    return d * p;
  }

  // ============================================================
  // 抽盘复核清单（第三遍专用）
  // ============================================================
  //
  // 🔴 抽盘的台账**不是**"抽盘 − 复盘"：复核改对之后那个差就是 0，
  //    行会从表里消失，而主管最终核对要看的正是"前两遍就对不上的那批"。
  //    所以这里导出的是复核清单：行集由**初盘 vs 复盘**决定，抽盘数只作为
  //    "复核结果"的一列。见 InventoryRules.reviewBarcodesOf。

  /// 复核清单的列。三遍数量并排，是给主管做最终核对用的。
  static const List<String> reviewHeaders = <String>[
    '条码',
    '商品名称',
    '规格',
    '单位',
    '初盘数量',
    '复盘数量',
    '抽盘数量',
    '前两遍差异',
    '复核结论',
    '前两遍差异金额',
    '账面数量',
    '备注',
  ];

  /// 复核清单 → CSV（带 BOM）。
  static String toReviewCsv(List<Map<String, dynamic>> rows) {
    final b = StringBuffer('\uFEFF');
    b.writeln(reviewHeaders.map(csvEsc).join(','));
    for (final r in rows) {
      final verdict = (r['review'] ?? '').toString();
      final a = baseAmtOf(r);
      b.writeln(<String>[
        csvEsc(barcodeCsvCell(r['barcode'])),
        csvEsc(nameOf(r)),
        csvEsc(r['spec']),
        csvEsc(r['unit']),
        r['base_qty'] == null ? '' : csvEsc(fmtQty(r['base_qty'])),
        r['prev_qty'] == null ? '' : csvEsc(fmtQty(r['prev_qty'])),
        r['review_missing'] == true ? '' : csvEsc(fmtQty(r['qty'])),
        r['base_diff'] == null ? '' : csvEsc(fmtQty(r['base_diff'])),
        csvEsc(voteLabel(verdict)),
        a == null ? '' : csvEsc(a.toStringAsFixed(2)),
        r['account_qty'] == null ? '' : csvEsc(fmtQty(r['account_qty'])),
        csvEsc(reviewNote(r)),
      ].join(','));
    }
    return b.toString();
  }

  /// 复核清单 → 文本文档（主管在群里就能看）。
  static String toReviewDoc(
    List<Map<String, dynamic>> rows, {
    required String zoneName,
    required int mistakes,
  }) {
    final t = InventoryRules.tallyReview(rows);
    var baseLoss = 0.0; // 前两遍的差异金额（亏）
    var baseGain = 0.0;
    for (final r in rows) {
      final a = baseAmtOf(r);
      if (a == null) continue;
      if (a < 0) {
        baseLoss += -a;
      } else {
        baseGain += a;
      }
    }

    final b = StringBuffer()
      ..writeln('抽盘复核清单')
      ..writeln('盘点位：$zoneName')
      ..writeln('导出时间：${_now()}')
      ..writeln('─' * 30)
      ..writeln('复核项（前两遍对不上的商品）：${t.total}')
      ..writeln('  已复核：${t.reviewed}　'
          '其中【已对上】${t.aligned}、【复核后又改】${t.changed}、【补盘】${t.filled}')
      ..writeln('  未复核：${t.pending}')
      ..writeln('前两遍漏盘（初盘盘过、复盘没扫到）：${t.baseMissing}')
      ..writeln('前两遍差异金额：亏 ${baseLoss.toStringAsFixed(2)}　'
          '盈 ${baseGain.toStringAsFixed(2)}')
      ..writeln('盘点失误笔数：$mistakes')
      ..writeln('─' * 30);

    var i = 0;
    for (final r in rows) {
      i++;
      final a1 = r['base_qty'];
      final a2 = r['prev_qty'];
      final a3 = r['review_missing'] == true ? null : r['qty'];
      final note = reviewNote(r);
      b.writeln('$i. ${nameOf(r)}　${r['barcode']}${note.isEmpty ? '' : '　【$note】'}');
      b.writeln('   初盘 ${a1 == null ? '（没盘过）' : fmtQty(a1)}'
          ' → 复盘 ${a2 == null ? '（没盘过）' : fmtQty(a2)}'
          ' → 抽盘 ${a3 == null ? '（未复核）' : fmtQty(a3)}');
      b.writeln('   前两遍差异 ${r['base_diff'] == null ? '—' : fmtQty(r['base_diff'])}'
          '　复核结论：${voteLabel((r['review'] ?? '').toString())}');
      final a = baseAmtOf(r);
      if (a != null) b.writeln('   前两遍差异金额：${a.toStringAsFixed(2)}');
    }
    return b.toString();
  }

  /// 前两遍（初盘 vs 复盘）的差异金额。
  ///
  /// 🔴 复核清单里这个才是"要核对的账"：`amtOf` 用的是"抽盘 − 复盘"，
  ///    复核改对之后它恒为 0 —— 拿它当金额列，主管看到的会是一堆 0。
  static double? baseAmtOf(Map<String, dynamic> r) {
    final d = _d(r['base_diff']);
    final p = _d(r['unit_price']);
    if (d == null || p == null) return null;
    return d * p;
  }

  /// 复核结论的中文（界面与导出共用一份，免得两处说法不一致）。
  static String voteLabel(String verdict) =>
      InventoryRules.reviewVerdictLabel(verdict);

  /// 复核清单的备注列：把"最该被看见的那件事"挑出来，其余留空。
  ///
  /// 顺序即优先级：未复核 > 复盘漏盘 > 复核后又改。
  /// （未复核排第一，是因为它意味着这一项**还没人看过** —— 比"看过了但结果不理想"
  ///   更需要立刻处理。）
  static String reviewNote(Map<String, dynamic> r) {
    if (r['review_missing'] == true) return '未复核';
    if (r['base_missing'] == true) return '复盘漏盘';
    if ((r['review'] ?? '').toString() == InventoryRules.reviewChanged) {
      return '复核后又改';
    }
    return '';
  }

  /// 表格里显示的商品名。商档里没有的条码用**预留值**而不是空字符串 ——
  /// 空名字在表格里就是一片空白，看着像"这行数据坏了"。
  static String nameOf(Map<String, dynamic> r) {
    final n = (r['name'] ?? '').toString().trim();
    return n.isEmpty ? '未知条码' : n;
  }

  static String csvName(String sheetNo) => '盘点_$sheetNo.csv';
  static String docName(String sheetNo) => '盘点明细_$sheetNo.txt';

  /// 差异表文件名。
  ///
  /// 点位码要**消毒**再拼进文件名：现场的点位码是人起的，写成"生鲜区/3"
  /// 完全可能 —— 而 `/` 在 Android 和 Windows 上都是路径分隔符，
  /// 拼出来就成了"往一个叫 盘点差异_生鲜区 的子目录里写文件"，
  /// 现场表现是导出直接失败，报错还指不到点位码身上。
  static String diffName(String zoneCode, int phase) =>
      '盘点差异_${_safeZone(zoneCode)}_$phase.csv';
  static String diffDocName(String zoneCode, int phase) =>
      '盘点差异_${_safeZone(zoneCode)}_$phase.txt';

  /// 抽盘复核清单的文件名。
  ///
  /// ⚠️ **不要**沿用 `盘点差异_..._3`：复核清单和"差异表"是两种台账，
  ///    同名文件混在一个目录里，主管分不清手上那份是哪一份
  ///    （而且它恰好也在第三遍产生，靠 `_3` 根本区分不出来）。
  static String reviewName(String zoneCode) =>
      '抽盘复核_${_safeZone(zoneCode)}.csv';
  static String reviewDocName(String zoneCode) =>
      '抽盘复核_${_safeZone(zoneCode)}.txt';

  /// 与 `InventoryRepo._sanitizeZone` 同一个口径：只留 `[A-Z0-9_]`。
  static String _safeZone(String zoneCode) {
    final s = zoneCode
        .trim()
        .toUpperCase()
        .replaceAll(RegExp(r'[^A-Z0-9_]'), '_');
    return s.isEmpty ? 'Z' : s;
  }

  static String _unit(Map<String, dynamic> r) {
    final u = (r['unit'] ?? '').toString().trim();
    return u.isEmpty ? '' : u;
  }

  static String _now() {
    final d = DateTime.now();
    String p(int v) => v.toString().padLeft(2, '0');
    return '${d.year}-${p(d.month)}-${p(d.day)} ${p(d.hour)}:${p(d.minute)}';
  }

  /// CSV 转义：含逗号/引号/换行的字段必须包引号并把引号翻倍，
  /// 否则一个带逗号的商品名就能把整张表挤错列。
  static String csvEsc(Object? v) {
    final s = (v ?? '').toString();
    if (s.contains(',') || s.contains('"') || s.contains('\n') || s.contains('\r')) {
      return '"${s.replaceAll('"', '""')}"';
    }
    return s;
  }

  static double? _d(Object? v) {
    if (v == null) return null;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString());
  }
}
