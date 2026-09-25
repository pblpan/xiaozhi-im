// 补货单的判定层（纯函数，不碰数据库、不碰界面）。
//
// ── 单位口径（龙哥 2026-09-25 定，只有**两套**，不做第三套）─────────────
//   · 非称重商品（杂百）：数量一律以**最小单位**为单位（件 / 个 / 瓶…）；
//   · 称重商品（生鲜）　：数量以**公斤**为单位；
//   · 「转换公斤」= 把最小单位的数量折算成公斤（要商档给得出"每件多重"）。
//
// 🔴 这两套单位是**按场景**分的，不是按商品一个个选的：
//    生鲜区的人手上拿的就是秤，让他输"件数"再换算等于多一道手；
//    杂百区的人按箱按瓶补，让他输公斤同样别扭。
//    真有"生鲜里也有按件补的"那种例外，靠商档的换算率在第二列显示公斤，
//    **不改主单位** —— 那正是"转换公斤"这一列的用处。
//
// ── 为什么数量和减货是反的 ─────────────────────────────────
// 减货是把货从库房减掉（出库），补货是把货补到货架上（上架）。
// 两者都是"扫一个码、给一个数量"，但**方向相反**，对账时符号相反 ——
// 所以是两张单、两个 sheet_type，不合并。

/// 补货场景。
class ReplenishScene {
  ReplenishScene._();

  /// 生鲜：**称重**，数量以公斤为单位。
  static const String fresh = 'fresh';

  /// 杂百：非称重，数量以最小单位（件 / 个）为单位。
  static const String dry = 'dry';

  static const List<String> all = <String>[fresh, dry];

  static bool isValid(String s) => all.contains(s);

  /// 空串或认不出的值一律落到「杂百」。
  ///
  /// 🔴 不返回 null、也不抛错：场景只是"这批货怎么记单位"的开关，
  ///    认不出来时**按最保守的那种（最小单位）记**比什么都记不了强 ——
  ///    员工不会因为在生鲜区补了一批货、界面认不出场景就没法干活。
  static String normalize(String? s) => isValid((s ?? '').trim()) ? (s ?? '').trim() : dry;

  static String label(String s) => normalize(s) == fresh ? '生鲜补货' : '杂百补货';

  /// 这个场景的主单位（显示用）。
  static String unit(String s) => normalize(s) == fresh ? '公斤' : '最小单位';
}

/// 补货数量单位（与场景一一对应，见 [ReplenishScene]）。
class ReplenishUnit {
  ReplenishUnit._();

  /// 公斤（生鲜 / 称重商品）。
  static const String kg = 'kg';

  /// 最小单位：件 / 个 / 瓶…（杂百 / 非称重商品）。
  static const String piece = 'piece';

  static String ofScene(String scene) =>
      ReplenishScene.normalize(scene) == ReplenishScene.fresh ? kg : piece;

  static String label(String u) => u == kg ? '公斤' : '最小单位';
}

class ReplenishVerdict {
  const ReplenishVerdict(this.name);

  final String name;

  static const ReplenishVerdict ok = ReplenishVerdict('ok');
  static const ReplenishVerdict duplicate = ReplenishVerdict('duplicate');
  static const ReplenishVerdict badQty = ReplenishVerdict('badQty');
  static const ReplenishVerdict limit = ReplenishVerdict('limit');

  @override
  String toString() => name;
}

class ReplenishDecision {
  const ReplenishDecision(this.verdict, {this.message});

  final ReplenishVerdict verdict;
  final String? message;

  bool get accepted => verdict == ReplenishVerdict.ok;

  static const ReplenishDecision ok = ReplenishDecision(ReplenishVerdict.ok);
}

/// 补货明细的一行（汇总与导出用）。
class ReplenishRow {
  const ReplenishRow({
    required this.barcode,
    required this.qty,
    this.unitWeightKg,
  });

  final String barcode;

  /// 主单位的数量（生鲜=公斤，杂百=最小单位）。
  final double qty;

  /// 商档给的"每个最小单位多少公斤"。null = 商档没给，折算不出。
  final double? unitWeightKg;

  /// **转换公斤**：最小单位折公斤。
  ///
  /// 🔴 秤上称出来的（生鲜，主单位就是公斤）**不折算** —— 它已经是公斤了，
  ///    再乘一个换算率会得到离谱的数（而且不报错，看着还是个正常数字）。
  ///    只有以最小单位计的杂百才折。
  // `!` 是安全的：左边刚判过 null。写成 `unitWeightKg` 编译不过 ——
  // 它是**字段**，Dart 不对字段做类型提升（三元表达式另一支里仍算 nullable）。
  double? get convertedKg =>
      unitWeightKg == null ? null : qty * unitWeightKg!;
}

/// 补货汇总：品种数、主单位合计、**折算后的公斤合计**、效率。
class ReplenishTally {
  const ReplenishTally({
    required this.kinds,
    required this.totalQty,
    required this.totalKg,
    required this.unknownWeight,
  });

  final int kinds;

  /// 主单位合计量。
  final double totalQty;

  /// 折算公斤合计（只算折得出的那些；一条都折不出时为 0）。
  final double totalKg;

  /// 折不出公斤的行数（商档没给"每件多重"）。
  final int unknownWeight;

  /// 「每分钟补货」：效率指标，PG 那版有这一列。
  ///
  /// 分母是**开单到现在的分钟数**，不是"扫码耗时"——
  /// 现场用它回答"这一车货补得快不快"，中间歇一会儿也要算进去，
  /// 否则这个数永远好看、也就永远没用。
  ///
  /// 不到 1 分钟时返回 null：拿 20 秒去除会得到一个虚高的数，
  /// 而它会被当成"这个人补得真快"看。
  double? perMinute(int elapsedMs) {
    if (elapsedMs < 60000) return null;
    return totalQty / (elapsedMs / 60000);
  }
}

class ReplenishRules {
  ReplenishRules._();

  /// 一张补货单的条数上限（与减货一致）。
  static const int maxRowsPerSheet = 500;

  /// 数量文本 → double。**0 和负数都不合法**。
  static double? parseQty(String raw) {
    final t = raw.trim();
    if (t.isEmpty) return null;
    final d = double.tryParse(t);
    if (d == null || !d.isFinite || d <= 0) return null;
    return d;
  }

  static String? qtyError(String raw) {
    final t = raw.trim();
    if (t.isEmpty) return '请填数量';
    if (parseQty(t) == null) {
      return '数量要填大于 0 的数字'
          '${double.tryParse(t) != null ? '（0 和负数都不行）' : ''}';
    }
    return null;
  }

  /// 入账判定。和减货同一套规矩：同码一张单只允许一行，
  /// 重复扫码要**明确拒绝**而不是静默覆盖（覆盖会让员工以为没扫上、再扫一次）。
  static ReplenishDecision decide({
    required bool sheetEditable,
    required bool alreadyInSheet,
    required int rowCount,
    int maxRows = maxRowsPerSheet,
  }) {
    if (!sheetEditable) {
      return const ReplenishDecision(ReplenishVerdict.duplicate,
          message: '这一单已经提交，不能再改（要改请先撤销提交）');
    }
    if (alreadyInSheet) {
      return const ReplenishDecision(ReplenishVerdict.duplicate,
          message: '这一单里已经有这个条码了，要改数量请在列表里改');
    }
    if (rowCount >= maxRows) {
      return ReplenishDecision(ReplenishVerdict.limit,
          message: '一张补货单最多 $maxRows 行，先提交再开一单');
    }
    return ReplenishDecision.ok;
  }

  /// 从**规格文本**里解析"每件多少公斤"。解析不出返回 null。
  ///
  /// 为什么靠解析而不是给商档加一列：商档是管理台整份导入的
  /// （格式 `序号,条码,商品名字,数量`），为了一个换算率去改导入格式、
  /// 再让所有门店重导一遍档案，代价太大。规格里**本来**就写着克重
  /// （`500g` / `1.25kg` / `500克` / `2斤`），解析它就够用。
  ///
  /// 🔴 解析不出来必须返回 null，**不要猜一个 1 出来** ——
  ///    "每件 1 公斤"的猜测会让公斤合计变得毫无意义，
  ///    而且看起来完全正常（没有任何报错）。
  ///    折不出的行由 [ReplenishTally.unknownWeight] 数出来告诉界面。
  static double? specWeightKg(String? spec) {
    final s = (spec ?? '').trim().toLowerCase();
    if (s.isEmpty) return null;
    final m = RegExp(r'(\d+(?:\.\d+)?)\s*(kg|公斤|千克|g|克|gram|斤|市斤)')
        .firstMatch(s);
    if (m == null) return null;
    final v = double.tryParse(m.group(1)!);
    if (v == null || v <= 0) return null;
    switch (m.group(2)) {
      case 'kg':
      case '公斤':
      case '千克':
        return v;
      case 'g':
      case '克':
      case 'gram':
        return v / 1000;
      case '斤':
      case '市斤':
        return v / 2;
    }
    return null;
  }

  /// 汇总。
  ///
  /// [unitWeightOf] 返回该条码"每个最小单位多少公斤"（来自商档），
  /// 折不出时返回 null —— 那种行不进公斤合计，但要**数出来**告诉界面，
  /// 否则"公斤合计偏小"会被当成算错了。
  static ReplenishTally tally(
    Iterable<ReplenishRow> rows, {
    required String scene,
  }) {
    var kinds = 0;
    var totalQty = 0.0;
    var totalKg = 0.0;
    var unknownWeight = 0;

    for (final r in rows) {
      kinds++;
      totalQty += r.qty;
      if (ReplenishUnit.ofScene(scene) == ReplenishUnit.kg) {
        // 生鲜：主单位就是公斤，直接计
        totalKg += r.qty;
      } else {
        final kg = r.convertedKg;
        if (kg == null) {
          unknownWeight++;
        } else {
          totalKg += kg;
        }
      }
    }
    return ReplenishTally(
      kinds: kinds,
      totalQty: totalQty,
      totalKg: totalKg,
      unknownWeight: unknownWeight,
    );
  }
}
