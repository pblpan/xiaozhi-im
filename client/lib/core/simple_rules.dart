/// 简易盘点（`simple_stocktake`）的**纯规则层**：场景、阶段标签、扫码准入判定、
/// CSV 清单解析。这个文件里**一行 Flutter、一行数据库、一行 IO 都没有**。
///
/// ── 为什么判定必须抠成纯函数 ─────────────────────────────────
/// 这条通道最容易做歪的不是"存不进去"，而是**"存进去了但口径判错了"**：
///   · 把清单外的商品拦下来 → 现场直接干不了活（口径是**放行**，导出作第三段）；
///   · 第 3 趟没按差异集限制 → 员工把对上的又盘一遍，差异复盘失去意义；
///   · 同码扫两次没累加 → 一个商品的数被记成 1，导出少货；
///   · CSV 解析把重复条码/空条码悄悄吞掉不报数 → 导错了没人知道。
/// 这些判定如果写在 SQL 里、或者写在页面的 `onPressed` 里，**测试跑不到**。
/// 抠成纯函数后每条分支都能在单测里点名验证。
///
/// 对应方案：`docs/简易盘点通道方案-v1.md`（§0 的 11 条口径是龙哥定的，别自己改）。
///
/// ── 和「盘点」的关系 ─────────────────────────────────────────
/// **独立通道，不共用点位 / 货架位 / 商档。** 本文件**不 import** `stock_master`
/// 那一套的任何东西，读表也不读它 —— 商品名称只从导入的 CSV 来。
library;

import 'dart:convert';

import 'inventory_rules.dart';

/// 场景标识：任务上必须带，**仓库和卖场各自独立**（互不串数）。
///
/// 🔴 为什么不是"只有卖场才走三趟"：龙哥 2026-09-25 定的口径里，仓库**也走**
///    完整的初盘-复盘-差异复盘，两个场景只是**分开的两批数据**，不是简化版。
class SimpleScene {
  SimpleScene._();

  /// 卖场（门店）。
  static const String store = 'store';

  /// 仓库。
  static const String warehouse = 'warehouse';

  static const List<String> all = <String>[store, warehouse];

  static bool isValid(String s) => all.contains(s);

  static String label(String s) {
    switch (s) {
      case store:
        return '卖场';
      case warehouse:
        return '仓库';
      default:
        return '未知场景';
    }
  }

  /// 落库前的归一：认不出的一律当**卖场**（默认值，也是最常见的场景），
  /// 而不是抛异常 —— 员工在界面上根本没有机会传出别的值。
  static String normalize(String? s) {
    final t = (s ?? '').trim();
    return isValid(t) ? t : store;
  }
}

/// 节点（＝一趟）的阶段。
///
/// 🔴 **数值与「盘点」的 [InvPhase] 共用 1/2/3，但标签不同**：
///    盘点是"初盘 / 复盘 / 抽盘"，这里是"初盘 / 复盘 / **差异复盘**"。
///    含义也略不同：抽盘是主管抽查，差异复盘是补盘 + 核准。
///    所以这里**不去改共用的 `InvPhase.label`**（改了会让盘点页显示错名字），
///    两个通道各自给自己的标签。
///
/// 数值直接引用 [InvPhase] 的常量而不是各写一遍 1/2/3：两边是同一列
/// （`scan_record.phase`），写成两份字面量迟早会飘。
class SimplePhase {
  SimplePhase._();

  /// 第 1 趟：初盘，全量扫。
  static const int first = InvPhase.first;

  /// 第 2 趟：复盘，**不受任何限制**（全量再扫一遍）。
  static const int second = InvPhase.second;

  /// 第 3 趟：差异复盘，**只能扫差异集**。
  static const int third = InvPhase.third;

  static const List<int> all = <int>[first, second, third];

  static bool isValid(int p) => all.contains(p);

  /// 第几趟（1 起）。给界面显示"第 2 趟"用。
  static int tripNo(int phase) => all.indexOf(phase) + 1;

  static String label(int phase) {
    switch (phase) {
      case first:
        return '初盘';
      case second:
        return '复盘';
      case third:
        return '差异复盘';
      default:
        return '第 $phase 趟';
    }
  }

  /// 界面上那句"第 2 趟 · 复盘"。
  static String tripLabel(int phase) => isValid(phase)
      ? '第 ${tripNo(phase)} 趟 · ${label(phase)}'
      : label(phase);

  /// 🔴 这一趟是不是**只许扫差异集**。
  ///
  /// 只有差异复盘（第 3 趟）要，**复盘不要**：
  ///   · 复盘的价值就在于"不知道哪里会错"，先按差异集限制它，等于默认初盘是对的，
  ///     复盘就成了走过场；
  ///   · 差异复盘才是"只核准前两趟对不上的那些"。
  static bool onlyDiffSet(int phase) => phase == third;

  static int? prev(int phase) {
    final i = all.indexOf(phase);
    return i <= 0 ? null : all[i - 1];
  }

  static int? next(int phase) {
    final i = all.indexOf(phase);
    if (i < 0 || i >= all.length - 1) return null;
    return all[i + 1];
  }
}

/// 一笔扫码的判定结果。
enum SimpleScanVerdict {
  /// 正常入账（商品在导入清单里）。
  ok,

  /// 入账，但**不在导入的清单里** —— 界面给个黄条提醒（不是错误）。
  ///
  /// 方案 §0 第 7 条：**不拦**，导出时作第三段「未录入盘点计划商品」。
  /// 拦下来的话现场就没法干活了：清单是提前导的，货架上多出来的东西
  /// 也是这一轮真实盘到的，丢掉它等于导出的数和实际对不上。
  okOffList,

  /// 差异复盘这一趟扫到了不在差异集里的商品。
  notInDiffSet,

  /// 本趟条数到达上限，必须先完成本趟。
  phaseLimit,

  /// 本趟已完成（提交），不能再写。
  sheetLocked,
}

/// 判定结果 + 给员工看的话。
///
/// [message] 直接就是界面要显示的中文 —— 判定和文案放在一起，
/// 免得界面各处自己拼一句不一样的话。
class SimpleScanDecision {
  const SimpleScanDecision(this.verdict, {this.message});

  final SimpleScanVerdict verdict;
  final String? message;

  /// 是否允许写入。
  bool get accepted =>
      verdict == SimpleScanVerdict.ok || verdict == SimpleScanVerdict.okOffList;

  /// 是否需要给黄条提醒（入了账，但有话要说）。
  bool get warned => verdict == SimpleScanVerdict.okOffList;

  static const SimpleScanDecision ok = SimpleScanDecision(SimpleScanVerdict.ok);

  static const SimpleScanDecision okOffList = SimpleScanDecision(
      SimpleScanVerdict.okOffList,
      message: '该商品不在导入的清单里，已记入（导出时作「未录入盘点计划商品」）');

  static const SimpleScanDecision sheetLocked = SimpleScanDecision(
      SimpleScanVerdict.sheetLocked,
      message: '本趟已完成，如需修改请先撤销');

  static const SimpleScanDecision phaseLimit = SimpleScanDecision(
      SimpleScanVerdict.phaseLimit,
      message: '本趟已达条数上限，请先「完成本趟」再继续！');

  static const SimpleScanDecision notInDiffSet = SimpleScanDecision(
      SimpleScanVerdict.notInDiffSet,
      message: '本趟只盘前两趟对不上的商品，该商品不在差异集内');
}

/// 简易盘点的纯规则集合。
class SimpleRules {
  SimpleRules._();

  /// 单个节点（一趟）的条数上限。
  ///
  /// 达到上限必须先「完成本趟」：一次扫几千条，界面每次都要重算明细，
  /// 手机在货架中间内存吃紧会直接被杀，那一趟就白干了。
  ///
  /// 同码在**本趟内**累加**不受**这个上限约束（见 [decide] 的判定顺序）——
  /// 否则扫第 500 个商品的第二件会被以"上限"为由拒掉，员工完全懵。
  static const int maxRowsPerNode = 500;

  /// 一笔扫码能不能入账（纯判定，不碰数据库）。
  ///
  /// 判定顺序**很重要**，别随手调换：
  ///   1. 本趟状态（已完成就什么都不用说，直接拒）
  ///   2. 条数上限（**已在本趟里的条码不算新行**，累加不受上限限制）
  ///   3. 差异集（只有差异复盘这一趟看它）
  ///   4. 在不在导入清单里（**在不在都放行**，只是给不给黄条的区别）
  ///
  /// [allowedBarcodes] 只有差异复盘那一趟才传（非空 = 只许扫这些）。
  /// 传 null = 不限制 —— 初盘与复盘都是全量扫。
  /// **判定里再卡一道 [SimplePhase.onlyDiffSet]**：即使调用方给复盘传了集合，
  /// 也不许限制它。这条是方案 §2 规矩 4 明确点名的坑，不能只靠调用方自觉。
  ///
  /// [alreadyInNode] 传"这个条码本趟已经扫过了吗"。用于把"累加"和"新增一行"
  /// 区分开 —— 上限算的是**行数**，不是扫码次数。
  static SimpleScanDecision decide({
    required int phase,
    required String barcode,
    required bool sheetEditable,
    required int currentRows,
    bool alreadyInNode = false,
    Set<String>? allowedBarcodes,
    bool inImportedList = true,
    int maxRows = maxRowsPerNode,
  }) {
    if (!sheetEditable) return SimpleScanDecision.sheetLocked;

    if (!alreadyInNode && currentRows >= maxRows) {
      return SimpleScanDecision.phaseLimit;
    }

    if (SimplePhase.onlyDiffSet(phase) &&
        allowedBarcodes != null &&
        !allowedBarcodes.contains(barcode.trim())) {
      return SimpleScanDecision.notInDiffSet;
    }

    // 🔴 清单外**不拦**，只换个提醒文案。见 [SimpleScanVerdict.okOffList]。
    return inImportedList ? SimpleScanDecision.ok : SimpleScanDecision.okOffList;
  }

  /// 数量文本 → double。合法返回数值，不合法返回 null。
  ///
  /// 称重商品按公斤走小数（如 `1.25`），散装按整数。**0 和负数都不合法**：
  /// 数量为 0 的行没有意义（要撤就删这一行），负数更是没这个业务。
  static double? parseQty(String raw) {
    final t = raw.trim();
    if (t.isEmpty) return null;
    final d = double.tryParse(t);
    if (d == null || !d.isFinite || d <= 0) return null;
    return d;
  }

  /// 数量文本的问题描述（合法返回 null）。界面直接显示这句话。
  static String? qtyError(String raw) {
    final t = raw.trim();
    if (t.isEmpty) return '请填数量';
    final d = double.tryParse(t);
    if (d == null) return '数量要填数字（称重的可以带小数，如 1.25）';
    if (!d.isFinite) return '这个数量不合法';
    if (d <= 0) return '数量要大于 0（要撤掉这一行请点删除）';
    return null;
  }

  // ============================================================
  // CSV 清单解析
  // ============================================================
  //
  // 现场没人愿意照着模板改文件头，所以解析必须**容错优先**：
  //   · 有表头：认「条码 / 商品条码 / barcode」「名称 / 商品名称 / name」「规格」，
  //     列的**顺序随便**；
  //   · 没表头：按第 1 列条码、第 2 列名称读；
  //   · 条码去空格、去 Excel 留下的 `="` 包裹；空行跳过；同条码重复只留一行。
  //
  // 🔴 而且要**报数**（导入 N 条 / 跳过重复 M / 跳过没条码 K）。
  //    不报数的话，导错了（比如把一整列读歪了）没人知道，
  //    等到盘完导出发现"少了 200 个商品"时已经白干一轮。

  /// 清单文件的字节 → 文本。**编码不对就明确拒绝，绝不硬读成乱码。**
  ///
  /// ── 为什么这一步必须单独存在 ──────────────────────────────────
  /// 中文 Windows 的 Excel 里"另存为 → CSV(逗号分隔)"存出来的是 **GBK**，
  /// 不是 UTF-8。而凑巧的是：**条码是纯 ASCII，GBK 和 UTF-8 对它完全一样** ——
  /// 所以直接 `utf8.decode(allowMalformed: true)` 会"导入成功"，
  /// 1000 个条码全对、1000 个商品名全是 `���`。
  /// 这种结果最危险：行数对得上、条码对得上，导出的对账单看着完全正常，
  /// 只有商品名是坏的，而**坏在最后一列最不容易被当场发现**。
  ///
  /// 所以这里用**严格** UTF-8 解码，解不开就如实报错，并直接告诉人怎么改。
  ///
  /// Dart 核心库没有 GBK 编解码（要引第三方包 + 平台通道），而正确做法本来就
  /// 不是"猜编码"——是让导出方按 UTF-8 存。给一句可执行的话，比猜错一遍强。
  static SimpleDecodedFile decodeCsvBytes(List<int> bytes) {
    if (bytes.isEmpty) return const SimpleDecodedFile.text('');
    try {
      // `utf8.decode` 的默认 `allowMalformed` 就是 **false**（严格）——
      // 这一条很关键，别顺手写成 `allowMalformed: true`：那会把坏字节悄悄换成
      // `U+FFFD`，于是又回到"乱码但导入成功"那条路上去了。
      if (bytes.length >= 3 &&
          bytes[0] == 0xEF &&
          bytes[1] == 0xBB &&
          bytes[2] == 0xBF) {
        // 带 BOM = 一定是 UTF-8（我们自己导出的文件就长这样）。
        return SimpleDecodedFile.text(utf8.decode(bytes.sublist(3)));
      }
      return SimpleDecodedFile.text(utf8.decode(bytes));
    } on FormatException {
      // UTF-16 的两种 BOM 单独给一句更准的话 —— 那是"另存为 → Unicode 文本"，
      // 和 GBK 是两回事，让人分得清该改哪一步。
      final utf16 = bytes.length >= 2 &&
          ((bytes[0] == 0xFF && bytes[1] == 0xFE) ||
              (bytes[0] == 0xFE && bytes[1] == 0xFF));
      return SimpleDecodedFile.error(utf16
          ? '这个清单是 UTF-16 编码（Excel 的「Unicode 文本」格式）。'
              '请在 Excel 里另存为「CSV UTF-8(逗号分隔)」再导一次。'
          : '这个清单不是 UTF-8 编码（多半是 Excel 默认存的 GBK）。'
              '直接在 Excel 里另存为「CSV UTF-8(逗号分隔)」就能导了 —— '
              '否则条码能读进来、商品名会全是乱码。');
    }
  }

  /// 解析 CSV 文本成待盘清单。
  ///
  /// 输入是**文件全文**（不是按行切好的）—— 因为商品名里可能带逗号甚至换行，
  /// 按 `\n` 硬切会把一个商品切成两行、还多出一个假条码。
  ///
  /// ⚠️ 传进来之前必须先过 [decodeCsvBytes]：编码不对的话，中文商品名会变成
  ///    乱码，而**条码是 ASCII、照样读得进来** —— 于是表现为"导入成功、
  ///    名字全是问号"，是最像成功的那种坏结果。
  static SimpleImportResult parseCsv(String text) {
    final rows = parseCsvRows(text);

    // 表头识别：第一行里出现"条码类"的列名就当表头。
    var iBarcode = 0, iName = 1, iSpec = 2;
    var start = 0;
    if (rows.isNotEmpty && _looksLikeHeader(rows.first)) {
      start = 1;
      iBarcode = _indexOfAny(rows.first, _barcodeAliases);
      iName = _indexOfAny(rows.first, _nameAliases);
      iSpec = _indexOfAny(rows.first, _specAliases);
      if (iBarcode < 0) iBarcode = 0;
    }

    final out = <SimpleImportRow>[];
    final seen = <String>{};
    var dup = 0, noBarcode = 0, read = 0;

    for (var r = start; r < rows.length; r++) {
      final cells = rows[r];
      if (cells.isEmpty || cells.every((c) => c.trim().isEmpty)) continue;
      read++;

      final code = cleanBarcode(_cell(cells, iBarcode));
      if (code.isEmpty) {
        noBarcode++;
        continue;
      }
      if (!seen.add(code)) {
        dup++;
        continue;
      }
      out.add(SimpleImportRow(
        barcode: code,
        name: cleanCell(iName >= 0 ? _cell(cells, iName) : ''),
        spec: cleanCell(iSpec >= 0 ? _cell(cells, iSpec) : ''),
        seq: out.length + 1,
      ));
    }

    return SimpleImportResult(
      rows: out,
      readLines: read,
      dupSkipped: dup,
      noBarcodeSkipped: noBarcode,
    );
  }

  static const List<String> _barcodeAliases = <String>[
    '条码', '商品条码', '条形码', '商品条形码', 'barcode', 'code', 'ean',
  ];
  static const List<String> _nameAliases = <String>[
    '名称', '商品名称', '品名', '商品', 'name', 'goods_name', 'item_name',
  ];
  static const List<String> _specAliases = <String>[
    '规格', '规格型号', 'spec',
  ];

  static bool _looksLikeHeader(List<String> cells) {
    for (final c in cells) {
      final t = cleanCell(c).toLowerCase().replaceAll(' ', '');
      if (t.isEmpty) continue;
      if (_barcodeAliases.contains(t)) return true;
    }
    return false;
  }

  static int _indexOfAny(List<String> cells, List<String> aliases) {
    for (var i = 0; i < cells.length; i++) {
      final t = cleanCell(cells[i]).toLowerCase().replaceAll(' ', '');
      if (aliases.contains(t)) return i;
    }
    return -1;
  }

  static String _cell(List<String> cells, int i) =>
      (i >= 0 && i < cells.length) ? cells[i] : '';

  /// 条码列的清洗。
  ///
  /// 三件事，每件都有具体的现场来源：
  ///   · **去掉所有空白**：从微信/网页复制条码经常带空格（`690 1234 567890`），
  ///     带空格的条码扫不出来也对不上；
  ///   · **剥掉 Excel 的文本公式**：我们自己导出的 CSV 里长条码写成 `="690..."`，
  ///     别人拿那份文件改一改再导回来，读到的就是 `="690..."` 这个串；
  ///   · **剥掉前导单引号**：Excel 里手输长数字时另一种"当文本"的写法。
  static String cleanBarcode(String raw) {
    var s = raw.trim();
    if (s.startsWith('=')) s = s.substring(1).trim();
    s = s.replaceAll('"', '');
    while (s.startsWith("'")) {
      s = s.substring(1).trim();
    }
    return s.replaceAll(RegExp(r'\s'), '');
  }

  /// 普通文本列（商品名 / 规格）的清洗：剥 Excel 包裹、去首尾空白。
  ///
  /// ⚠️ **这里不去掉中间的空格** —— "农夫山泉 550ml" 里的空格是有意义的。
  static String cleanCell(String raw) {
    var s = raw.trim();
    if (s.startsWith('=')) s = s.substring(1).trim();
    if (s.length >= 2 && s.startsWith('"') && s.endsWith('"')) {
      s = s.substring(1, s.length - 1).trim();
    }
    return s;
  }

  /// CSV 文本 → 二维单元格（RFC4180：支持引号包裹、引号翻倍、字段内换行）。
  ///
  /// 🔴 不能按 `\n` 切了再按 `,` 切：商品名里带逗号（`苹果,红富士`）是真实存在的，
  ///    那样切会把一个商品变成"条码 + 半截名字 + 一个假条码"，而且**看不出错**。
  ///
  /// 完全空白的行直接丢掉（Excel 存出来的 CSV 末尾经常有一堆）。
  static List<List<String>> parseCsvRows(String text) {
    var s = text;
    // BOM：`fetch().text()` 会吞掉 U+FEFF，但读文件字节再解码时它会留下。
    if (s.isNotEmpty && s.codeUnitAt(0) == 0xFEFF) s = s.substring(1);

    final rows = <List<String>>[];
    var cur = <String>[];
    final field = StringBuffer();
    var inQuotes = false;

    void endField() {
      cur.add(field.toString());
      field.clear();
    }

    void endRow() {
      endField();
      rows.add(cur);
      cur = <String>[];
    }

    for (var i = 0; i < s.length; i++) {
      final ch = s[i];
      if (inQuotes) {
        if (ch == '"') {
          if (i + 1 < s.length && s[i + 1] == '"') {
            field.write('"');
            i++;
          } else {
            inQuotes = false;
          }
        } else {
          field.write(ch);
        }
        continue;
      }
      if (ch == '"') {
        inQuotes = true;
      } else if (ch == ',') {
        endField();
      } else if (ch == '\r') {
        if (i + 1 < s.length && s[i + 1] == '\n') i++;
        endRow();
      } else if (ch == '\n') {
        endRow();
      } else {
        field.write(ch);
      }
    }
    // 最后一行没有换行符结尾时要补上；但"以换行结尾"的文件会多出一个空字段。
    if (field.isNotEmpty || cur.isNotEmpty) endRow();

    return rows
        .where((r) => r.any((c) => c.trim().isNotEmpty))
        .toList(growable: false);
  }
}

/// 清单文件解码的结果：要么拿到文本，要么拿到一句**可执行**的错误。
///
/// 不用"抛异常"来表达失败：这不是程序出错，是**用户拿错了文件**，
/// 界面必须能把这句话原样显示出来（异常信息带着堆栈和类名，给现场看没有意义）。
class SimpleDecodedFile {
  const SimpleDecodedFile.text(this.text) : error = null;
  const SimpleDecodedFile.error(this.error) : text = null;

  /// 解码后的全文（失败时为 null）。
  final String? text;

  /// 给人看的失败原因（成功时为 null）。
  final String? error;

  bool get ok => text != null;
}

/// 导入清单里的一行。
class SimpleImportRow {
  const SimpleImportRow({
    required this.barcode,
    required this.name,
    required this.spec,
    required this.seq,
  });

  final String barcode;
  final String name;
  final String spec;

  /// 导入顺序（1 起）。导出照这个排，员工好对数。
  final int seq;

  Map<String, Object?> toDb(String taskNo) => <String, Object?>{
        'task_no': taskNo,
        'barcode': barcode,
        'name': name.isEmpty ? null : name,
        'spec': spec.isEmpty ? null : spec,
        'seq': seq,
      };
}

/// 一次导入的结果（**必须能报数**）。
class SimpleImportResult {
  const SimpleImportResult({
    required this.rows,
    required this.readLines,
    required this.dupSkipped,
    required this.noBarcodeSkipped,
  });

  /// 真正导入的（已去重、已剔空条码）。
  final List<SimpleImportRow> rows;

  /// 读到的**有效数据行数**（已排除空行，含后面被跳掉的）。
  final int readLines;

  final int dupSkipped;
  final int noBarcodeSkipped;

  bool get isEmpty => rows.isEmpty;

  int get kept => rows.length;

  /// 报数文案。界面导入完直接显示这句。
  ///
  /// 把"读到多少行"和"导入多少条"**都写出来**：只报一个数的话，
  /// 员工没法判断"少了的那几条是本来就没有，还是被吃掉了"。
  /// 三个数满足 `kept + dupSkipped + noBarcodeSkipped == readLines`。
  String get report => '读到 $readLines 行，导入 $kept 条'
      '${dupSkipped > 0 ? '，跳过重复 $dupSkipped 条' : ''}'
      '${noBarcodeSkipped > 0 ? '，跳过没条码 $noBarcodeSkipped 条' : ''}';

  /// 一个都没导进来时的原因（给界面说人话用）。
  String? get emptyReason {
    if (!isEmpty) return null;
    if (readLines == 0) return '这个文件里没有读到数据行，确认一下导出的格式（CSV）';
    if (noBarcodeSkipped == readLines) {
      return '读到的 $readLines 行都没有条码，确认一下是不是选错了列';
    }
    return '这个文件里没有可用的商品（读到 $readLines 行）';
  }
}
