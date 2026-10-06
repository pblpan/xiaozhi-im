/// 简易盘点导出「全量盘点数据单」的排版层（**纯函数，零 IO、零 Flutter**）。
///
/// ── 这份文件是给谁看的 ────────────────────────────────────────
/// 给**对数的人**：他手上有一份"这一轮要盘什么"的清单，逐行对导出文件里的数量。
/// 所以判据不是"好不好看"，而是：
///   · **一行都不能少** —— 少一行他也没法发现（这正是要三段的原因）；
///   · 没盘到的**写 0 不是留空** —— 留空他分不清"是 0 还是没读到"；
///   · 排序照**导入顺序** —— 他就是按手上那份单子的顺序往下看的。
///
/// 方案：`docs/简易盘点通道方案-v1.md` §4。
///
/// 🔴 **一个 CSV，三段**（龙哥定的形式）：
///   | 段 | 抬头 | 内容 | 数量列 |
///   |---|---|---|---|
///   | 1 | 盘点数据 | 已确定的商品 | 最终数 |
///   | 2 | 未盘到商品 | 清单里有、整个流程一个数都没有 | **0** |
///   | 3 | 未录入盘点计划商品 | 扫到了、但不在导入清单里 | 实盘数 |
///   第 4 段「差异待复核」只在**有对不上又还没做差异复盘**时才有（S2），
///   正常流程走完它自然为空 —— 所以不影响"三段"这个形式。
///
/// 🔴 **绝不悄悄丢数据**：分不进取 1/2/3 段之外的商品（＝对不上又没复核的）
///    必须出现在第 4 段里，数量列留空。丢数据比格式不好看严重得多。
library;

import 'csv_fmt.dart';
import 'qty_fmt.dart';
import 'simple_rules.dart';

/// 一段的抬头 + 行。
class SimpleExportSegment {
  const SimpleExportSegment(this.title, this.rows);

  final String title;
  final List<SimpleExportRow> rows;

  int get length => rows.length;
  bool get isEmpty => rows.isEmpty;
}

/// 导出行。
class SimpleExportRow {
  const SimpleExportRow({
    required this.barcode,
    required this.qty,
    required this.name,
  });

  final String barcode;

  /// 数量。`null` = **这一格留空**（只用于「差异待复核」段 —— 那一段的数还没定，
  /// 写 0 会被当成"盘了 0 个"，写别的数是替盘点员签字）。
  final double? qty;

  final String name;
}

/// 三段（＋可选的第四段）拼好的结果。
class SimpleExportSegments {
  const SimpleExportSegments({
    required this.data,
    required this.missing,
    required this.extra,
    required this.pending,
    required this.importedCount,
  });

  /// 段 1 盘点数据（已确定）。
  final SimpleExportSegment data;

  /// 段 2 未盘到商品（数量 0）。
  final SimpleExportSegment missing;

  /// 段 3 未录入盘点计划商品。
  final SimpleExportSegment extra;

  /// 段 4 差异待复核（数量列留空）。没有待复核时它是空的。
  final SimpleExportSegment pending;

  /// 导入清单的行数（用来对账，不是导出内容的一部分）。
  final int importedCount;

  /// 导出的**数据行**总数（不含抬头与列名）。
  int get totalRows => data.length + missing.length + extra.length + pending.length;

  /// 🔴 硬判据：清单里的每一条都必须**有下落** ——
  /// 落在"已确定"里、或落在"未盘到"里、或落在"差异待复核"里，三者必居其一。
  ///
  /// 这条一旦不成立，就是**有商品被悄悄丢掉了**（员工盘了它、导出里却没有）。
  /// 界面在导出前查它，测试也查它 —— 一个判据两处用，不会各说各话。
  bool get accounted =>
      data.length + missing.length + pending.length == importedCount;

  /// 一句话摘要（导出成功提示与界面统计条共用）。
  String get summary => '盘点数据 ${data.length} 行 · '
      '未盘到 ${missing.length} 行 · '
      '未录入计划 ${extra.length} 行'
      '${pending.isEmpty ? '' : ' · 差异待复核 ${pending.length} 行'}';
}

class SimpleExport {
  SimpleExport._();

  /// 每段三列，顺序照龙哥说的来（**商品条码 / 商品盘点数量 / 商品名称**）。
  static const List<String> headers = <String>[
    '商品条码',
    '商品盘点数量',
    '商品名称',
  ];

  static const String titleData = '盘点数据';
  static const String titleMissing = '未盘到商品';
  static const String titleExtra = '未录入盘点计划商品';
  static const String titlePending = '差异待复核';

  /// 清单外、又查不到名字时的占位（与「减货」「盘点」两个导出口径一致）。
  ///
  /// 写成占位而不是空串：空的名称列在表格里就是一片空白，看着像"这行坏了"；
  /// 而"我们确实不知道它叫什么"本身就是一条真实的信息。
  static const String unknownName = '未知条码';

  /// 把清单 + 数量表拼成三段。
  ///
  /// [items] 是导入的清单（`simple_item` 的行，按 `seq` 升序）。
  /// [qty] 是"条码 → 最终数量"（S1 就是初盘那一趟的汇总）。
  /// [pending] 是"有差异、还没做差异复盘"的条码（S2 才有；S1 传空即可）。
  ///
  /// 分段的判据只有一条：**这个条码有没有一个已确定的数**。
  ///   · 清单里 + 有数        → 段 1
  ///   · 清单里 + 没数（或数=0）→ 段 2（写 0）
  ///   · 清单里 + 在待复核集里  → 段 4（留空，**优先于段 1**）
  ///   · 清单外 + 有数        → 段 3
  ///   · 清单外 + 没数        → 丢掉（没扫到又不在清单里，它不存在）
  ///
  /// [extraNames] 给段 3 兜名字用（龙哥 2026-10-06）：清单外的码多半在
  /// 商档里有名字（界面列表已经兜底显示了），导出来却是"未知条码"很难对账。
  /// 调用方从商档查到多少给多少；没给的仍然落占位。
  static SimpleExportSegments build({
    required List<Map<String, dynamic>> items,
    required Map<String, double> qty,
    Set<String> pending = const <String>{},
    Map<String, String> extraNames = const <String, String>{},
  }) {
    final data = <SimpleExportRow>[];
    final missing = <SimpleExportRow>[];
    final extra = <SimpleExportRow>[];
    final pendingRows = <SimpleExportRow>[];

    // 清单里的行：**按导入顺序排**（未盘到的不单独排到最后 ——
    // 对数的人是按手上那张单子一行行往下对的）。
    final inList = <String>{};
    for (final it in items) {
      final code = (it['barcode'] ?? '').toString().trim();
      if (code.isEmpty) continue;
      inList.add(code);
      final name = _nameOf(it);
      final q = qty[code];

      // 待复核**优先**：它既不在段 1（数还没定）、也不该进段 2
      // （它明明盘到了，写 0 是错的）。
      if (pending.contains(code)) {
        pendingRows.add(SimpleExportRow(barcode: code, qty: null, name: name));
        continue;
      }
      if (q == null || q == 0) {
        // 🔴 没盘到写 **0**，不是留空。留空对数的人分不清
        //    "是 0 还是这一格没读到"。
        missing.add(SimpleExportRow(barcode: code, qty: 0, name: name));
      } else {
        data.add(SimpleExportRow(barcode: code, qty: q, name: name));
      }
    }

    // 清单外的：扫到了但不在清单里。**按条码排**（它们没有导入顺序）。
    final extraCodes = qty.keys
        .where((c) => c.trim().isNotEmpty && !inList.contains(c.trim()))
        .map((c) => c.trim())
        .toSet()
        .toList()
      ..sort();
    for (final code in extraCodes) {
      final q = qty[code];
      if (q == null || q == 0) continue; // 没扫到又不在清单里 → 它不存在
      // 名字：优先用调用方给的（商档里查到的），查不到落占位 ——
      // 和界面上"未知条码"的表现对齐，不假装知道它叫什么。
      final name =
          (extraNames[code] ?? '').toString().trim().isEmpty
              ? unknownName
              : extraNames[code]!.trim();
      extra.add(SimpleExportRow(barcode: code, qty: q, name: name));
    }

    return SimpleExportSegments(
      data: SimpleExportSegment(titleData, data),
      missing: SimpleExportSegment(titleMissing, missing),
      extra: SimpleExportSegment(titleExtra, extra),
      pending: SimpleExportSegment(titlePending, pendingRows),
      importedCount: inList.length,
    );
  }

  /// 拼好的三段 → CSV（带 UTF-8 BOM）。
  ///
  /// 🔴 BOM 必须带：不带的话 Excel/WPS 会按本地 GBK 打开，中文商品名全是乱码。
  ///
  /// ⚠️ **段与段之间不放空行**：放了以后"整个文件的行数"就没法机械地对上
  ///    "段1 + 段2 + 段3"了（验收第 7 条就是靠数行数防"悄悄少了几行"）。
  ///    每段自带抬头 + 列名，读起来照样分得清。
  static String toCsv(SimpleExportSegments s) {
    final b = StringBuffer('\uFEFF');
    for (final seg in <SimpleExportSegment>[
      s.data,
      s.missing,
      s.extra,
      // 空段不渲染：正常流程走完不会有第四段，文件里也不该冒出一个
      // "差异待复核"的抬头（那会让人以为还有事没做完）。
      if (!s.pending.isEmpty) s.pending,
    ]) {
      // 空段照样渲染抬头与列名：段 2 全空（全盘到了）时，缺了这一段会让人
      // 怀疑"是不是没导出全"。
      b.writeln(seg.title);
      b.writeln(headers.map(csvEsc).join(','));
      for (final r in seg.rows) {
        b.writeln(<String>[
          csvEsc(barcodeCsvCell(r.barcode)),
          r.qty == null ? '' : csvEsc(fmtQty(r.qty)),
          csvEsc(r.name),
        ].join(','));
      }
    }
    return b.toString();
  }

  /// 把导出的 CSV **读回来**，数出每段的数据行数。
  ///
  /// 这是验收第 7 条（"整个 CSV 的行数 = 段1 + 段2 + 段3，且段1 + 段2 = 清单行数"）
  /// 唯一能机械核对的做法 —— 靠肉眼看 1000 行是看不出少没少的。
  /// 返回：抬头 → 数据行数。没见过的抬头忽略。
  ///
  /// ⚠️ 分行**复用 [SimpleRules.parseCsvRows]**，不自己再写一份：
  ///    两份 CSV 分行器一旦漂移，就会出现"导出是对的、数行数的是错的"
  ///    这种最难查的组合（判据说没问题，其实判据自己坏了）。
  static Map<String, int> countRowsBySegment(String csv) {
    final rows = SimpleRules.parseCsvRows(csv);
    final out = <String, int>{};
    String? cur;
    for (final cells in rows) {
      final first = cells.isNotEmpty ? cells.first.trim() : '';
      if (first.isEmpty) continue;
      if (first == titleData ||
          first == titleMissing ||
          first == titleExtra ||
          first == titlePending) {
        cur = first;
        out.putIfAbsent(cur, () => 0);
        continue;
      }
      if (cur == null) continue;
      if (first == headers.first) continue; // 列名行
      out[cur] = out[cur]! + 1;
    }
    return out;
  }

  /// 导出文件名：`简易盘点_<场景>_<任务号>.csv`。
  ///
  /// 场景进文件名是有用的：仓库和卖场两个任务会**同时存在**（口径允许），
  /// 都叫"简易盘点_SMP-xxx.csv"的话，发到群里谁也分不清哪份是哪份。
  static String csvName(String sceneLabel, String taskNo) =>
      '简易盘点_${_safe(sceneLabel)}_${_safe(taskNo)}.csv';

  /// 文件名消毒：换成 Windows / Android 都不接受的字符。
  ///
  /// 场景标签与任务号是**人起的 / 拼出来的**，直接塞进文件名可能带 `/`，
  /// 那在 Android 上就成了"往一个子目录里写" —— 表现是导出直接失败。
  static String _safe(String s) {
    final t = s.trim().replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '_');
    return t.isEmpty ? 'X' : t;
  }

  /// 清单行的名称：空则给占位（与导出口径一致，界面/导出不会一处空一处有）。
  static String _nameOf(Map<String, dynamic> r) {
    final n = (r['name'] ?? '').toString().trim();
    return n.isEmpty ? unknownName : n;
  }
}
