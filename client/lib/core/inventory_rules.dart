// 盘点（inventory 模块）的**纯规则层**：阶段定义、扫码准入判定、差异判定、
// 失误笔数计算。这里一行数据库代码都没有 —— 全是纯函数。
//
// ── 为什么要把判定从仓库层抠出来 ─────────────────────────────
// 盘点的核心风险不是"存不进去"，而是**"存进去了但规则判错了"**：
//   · 复盘时把不该扫的商品放进来 → 差异集被污染，账越盘越乱；
//   · 抽盘漏了差异集校验 → 抽盘等于重扫一遍，白干；
//   · 条数上限没拦 → 一次盘几千条，提交时手机先趴下。
// 这些判定如果写在 SQL 里、或者写在 `if (Platform.isAndroid)` 后面，
// **测试跑不到**（测试机没有那种数据、也没有那种平台）。
// 抠成纯函数后，每条分支都能在单测里点名验证，包括"什么坏情况能让它失败"。
//
// 对应方案：`docs/盘点复刻与开放接口方案-v1.md` §P1。

/// 盘点阶段。用常量而不是 enum，是为了能直接落库（INTEGER）不来回转换。
class InvPhase {
  InvPhase._();

  /// 初盘：全量扫。
  static const int first = 1;

  /// 复盘：这一片**重新全盘一遍**，不限制差异集。
  static const int second = 2;

  /// 抽盘：主管抽查，**只扫上一阶段数量对不上的**（含漏盘）。
  static const int third = 3;

  static const List<int> all = <int>[first, second, third];

  static String label(int phase) {
    switch (phase) {
      case first:
        return '初盘';
      case second:
        return '复盘';
      case third:
        return '抽盘';
      default:
        return '阶段$phase';
    }
  }

  /// 阶段合法性。传进来 0 / 4 / null 一律判非法 ——
  /// 不判的话 `label()` 会显示"阶段0"，然后落库，谁也说不清那是什么。
  static bool isValid(int phase) => all.contains(phase);

  /// 上一阶段（初盘没有上一阶段，返回 null）。
  static int? prev(int phase) {
    final i = all.indexOf(phase);
    if (i <= 0) return null;
    return all[i - 1];
  }

  /// 下一阶段（抽盘没有下一阶段）。
  static int? next(int phase) {
    final i = all.indexOf(phase);
    if (i < 0 || i >= all.length - 1) return null;
    return all[i + 1];
  }

  /// 该阶段是否要求"只能扫上一阶段的差异集"。
  ///
  /// 🔴 只**抽盘**要，复盘不要：
  ///    · 复盘是"把这一片重新扫一遍"，它的价值就在于不知道哪里会错；
  ///      先按差异集限制它，等于默认初盘是对的，复盘就成了走过场。
  ///    · 抽盘才是"只复核有问题的那些" —— 数量对不上、或者上一轮根本没扫到的
  ///      （漏盘，见 [InventoryRules.missingVsPrev]），主管盯这些就够了。
  static bool requiresDiffSetOnly(int phase) => phase == third;
}

/// 盘点单状态。
class InvSheetStatus {
  InvSheetStatus._();

  /// 进行中，可以继续扫、可以改数量。
  static const int open = 0;

  /// 已提交：**本地就锁死**，不再接受任何写入。
  static const int submitted = 1;

  /// 已上传服务端。
  static const int uploaded = 2;

  static String label(int s) {
    switch (s) {
      case open:
        return '进行中';
      case submitted:
        return '已提交';
      case uploaded:
        return '已上传';
      default:
        return '未知';
    }
  }

  /// 还能不能改数据。已提交/已上传都不行 ——
  /// 提交后还能改，等于"盘点结果可以事后修饰"，那这套制度就没意义了。
  static bool editable(int s) => s == open;
}

/// 一笔扫码的判定结果。
enum ScanVerdict {
  /// 正常入账。
  ok,

  /// 入账，但这条码没绑过货架位 —— 界面要给个黄条提醒（不是错误）。
  okUnbound,

  /// 该商品绑在**别的**盘点位，本点位不该出现它。
  otherZone,

  /// 复盘阶段扫到了不在差异集里的商品。
  notInDiffSet,

  /// 本阶段条数到达上限，必须先提交。
  phaseLimit,

  /// 单据已提交/已上传，不能再写。
  sheetLocked,
}

/// 判定结果 + 给员工看的话。
///
/// [message] 直接就是界面要显示的中文 —— 判定和文案放在一起，
/// 免得界面各处自己拼一句不一样的话（同一个错有三种说法最让人困惑）。
class ScanDecision {
  const ScanDecision(this.verdict, {this.message});

  final ScanVerdict verdict;
  final String? message;

  /// 是否允许写入。
  bool get accepted =>
      verdict == ScanVerdict.ok || verdict == ScanVerdict.okUnbound;

  static const ScanDecision ok = ScanDecision(ScanVerdict.ok);
  static const ScanDecision okUnbound =
      ScanDecision(ScanVerdict.okUnbound, message: '该商品未绑定货架位，已按本点位记入');
  static const ScanDecision sheetLocked =
      ScanDecision(ScanVerdict.sheetLocked, message: '本单已提交，如需修改请先撤销提交');
  static const ScanDecision phaseLimit = ScanDecision(ScanVerdict.phaseLimit,
      message: '本阶段已达条数上限，请提交后继续盘点！');
  static const ScanDecision otherZone = ScanDecision(ScanVerdict.otherZone,
      message: '当前盘点位不包含该商品');
  static const ScanDecision notInDiffSet = ScanDecision(ScanVerdict.notInDiffSet,
      message: '本阶段只盘上一轮的差异商品，该商品不在差异集内');
}

/// 盘点纯规则集合。
class InventoryRules {
  InventoryRules._();

  /// 单个盘点位、单个阶段的条数上限。
  ///
  /// 达到上限必须**拦住并让先提交**（对齐 PG 的"请提交后继续盘点！"）。
  /// 为什么要拦：一次盘几千条，提交时整单一次性算差异 + 回传，
  /// 手机在货架中间内存吃紧会直接被杀，那一轮就白干了。
  /// 分几次提交，每次都是完整的一笔。
  static const int maxRowsPerPhase = 500;

  /// 一笔扫码能不能入账（纯判定，不碰数据库）。
  ///
  /// 判定顺序**很重要**，别随手调换：
  ///   1. 单据状态（提交了就什么都不用说，直接拒）
  ///   2. 条数上限（**已在本单里的条码不算新行**，累加不受上限限制 ——
  ///      否则扫第 500 个商品的第二件会被以"上限"为由拒掉，员工完全懵）
  ///   3. 点位归属（初盘/抽盘）
  ///   4. 差异集（复盘）
  static ScanDecision decide({
    required int phase,
    required String barcode,
    required String zoneCode,
    required bool sheetEditable,
    required bool alreadyInSheet,
    required int currentRows,
    required Set<String> boundZones,
    required Set<String> diffBarcodes,
    int maxRows = maxRowsPerPhase,
  }) {
    if (!sheetEditable) return ScanDecision.sheetLocked;

    if (!alreadyInSheet && currentRows >= maxRows) {
      return ScanDecision.phaseLimit;
    }

    // 复盘：只允许扫差异集里的商品。
    if (InvPhase.requiresDiffSetOnly(phase) && !diffBarcodes.contains(barcode)) {
      return ScanDecision.notInDiffSet;
    }

    // 点位归属：只在"该条码绑了别的点位、且一个都没绑在本点位"时才算越位。
    //
    // 🔴 没绑过任何货架位的条码**放行**（给个提醒，不当错误）。
    //    理由：上线第一天不可能有全店商品的货架位档案，如果没绑定就拒绝，
    //    整个盘点当场没法用。宁可让它进差异集（账面有、货架位档案没有），
    //    后面靠"绑定"这件事慢慢补 —— 拦死是错的，放行 + 可见的提醒才对。
    if (boundZones.isNotEmpty && !boundZones.contains(zoneCode)) {
      return ScanDecision.otherZone;
    }

    if (boundZones.isEmpty) return ScanDecision.okUnbound;
    return ScanDecision.ok;
  }

  /// 给汇总行补上"上一阶段数量"和"差异"，返回新的行列表。
  ///
  /// 🔴 差异 = `本阶段 qty - 上一阶段 qty`（两边都按条码汇总过），**不比账面**：
  ///    门店系统里没有可用的库存账面（泰格库所有库存表都是空表），比账面会
  ///    得到"差异集 = 全部商品"，三遍制退化成把同一个货架扫三遍。
  ///    这也正是比优特 PG 的口径：初盘 / 复盘 / 抽盘三个**平行数量**互相比。
  ///
  /// [prev] 为空（初盘没有上一阶段）时 `prev_qty` 是 null ——
  /// 意思是"没有可比的对象"，**不等于有差异**。
  static List<Map<String, dynamic>> attachPrevDiff(
    List<Map<String, dynamic>> rows,
    Map<String, double> prev,
  ) {
    return rows.map((r) {
      final code = (r['barcode'] ?? '').toString().trim();
      final q = asNum(r['qty']);
      final p = prev[code];
      final out = <String, dynamic>{...r};
      out['prev_qty'] = p;
      out['diff_qty'] = (q == null || p == null) ? null : q - p;
      return out;
    }).toList();
  }

  /// 一行是不是差异（**和上一阶段比对**，数量变了）。
  ///
  /// 🔴 没有上一阶段可比时（`prev_qty == null`）**不算差异** —— 初盘这一轮
  ///    本来就没有参照。原来判的是"实盘 ≠ 账面"（账面缺失也算差异），
  ///    换了基准之后，"没有参照"必须从差异集里剔除，否则初盘自己就是一个
  ///    等于全部商品的差异集，后面的复盘 / 抽盘全被它带偏。
  ///
  /// 注意这是**逐行**谓词：真正的"漏盘"（上一轮有、这一轮没扫）在本阶段
  /// 连行都没有，判断不出来 —— 那种要靠把上一阶段的行喂给
  /// [diffBarcodesOf]（它会并上 [missingVsPrev]）。
  static bool isDiffRow(Map<String, dynamic> row) {
    final prev = asNum(row['prev_qty']);
    if (prev == null) return false;
    final diff = asNum(row['diff_qty']);
    if (diff == null) return true; // 兜底：只给了参照值没给差值的构造行，按"对不上"处理
    return diff != 0;
  }

  /// 从补过 [attachPrevDiff] 的行集里取出差异集条码。
  ///
  /// 🔴 必须把**漏盘**并进来（靠 [prevRows]）：一条上一轮盘过、这一轮根本没扫到的
  ///    条码，在本阶段的行集里**没有对应的行** —— 只在 `rows` 里挑是永远挑不出来的。
  ///    曾经这里收了 `prevRows` 却没并 [missingVsPrev]，结果差异集少算漏盘；
  ///    而"少一行"在明细里根本看不出来，不合格的货架就这么被绕过去了。
  static Set<String> diffBarcodesOf(
    Iterable<Map<String, dynamic>> rows, {
    Iterable<Map<String, dynamic>> prevRows = const <Map<String, dynamic>>[],
  }) {
    final out = <String>{};
    for (final r in rows) {
      final code = (r['barcode'] ?? '').toString().trim();
      if (code.isEmpty) continue;
      if (isDiffRow(r)) out.add(code);
    }
    out.addAll(missingVsPrev(prevRows, rows));
    return out;
  }

  /// 上一轮盘过、这一轮**没扫到**的条码（漏盘）。
  ///
  /// 抽盘必须把它们一并放进来：员工最容易干的活就是绕开不好盘的货架，
  /// 而"少一行"在明细里**看不出来** —— 不像数量错了那么显眼。
  static Set<String> missingVsPrev(
    Iterable<Map<String, dynamic>> prevRows,
    Iterable<Map<String, dynamic>> curRows,
  ) {
    final cur = <String>{};
    for (final r in curRows) {
      final c = (r['barcode'] ?? '').toString().trim();
      if (c.isNotEmpty) cur.add(c);
    }
    final out = <String>{};
    for (final r in prevRows) {
      final c = (r['barcode'] ?? '').toString().trim();
      if (c.isNotEmpty && !cur.contains(c)) out.add(c);
    }
    return out;
  }


  /// 失误笔数：上一阶段扫过、本阶段被改成**不同数量**的条码数。
  ///
  /// 口径（对齐 PG 的"初盘失误笔数/复盘失误笔数"）：
  ///   · 两阶段都有、数量不同 → 算 1 笔失误
  ///   · 两阶段都有、数量相同 → 不算
  ///   · 本阶段没再扫这条（数量 0 或没出现）→ **不算失误**，那是"差异未复核"，
  ///     另一栏单独看（混在一起会让失误笔数虚高，主管没法用这个数考核）
  static int mistakeCount(
    Iterable<Map<String, dynamic>> prevRows,
    Iterable<Map<String, dynamic>> curRows,
  ) {
    final prev = <String, double>{};
    for (final r in prevRows) {
      final c = (r['barcode'] ?? '').toString().trim();
      final q = asNum(r['qty']);
      if (c.isEmpty || q == null) continue;
      prev[c] = q;
    }

    var n = 0;
    for (final r in curRows) {
      final c = (r['barcode'] ?? '').toString().trim();
      final q = asNum(r['qty']);
      if (c.isEmpty || q == null) continue;
      final p = prev[c];
      if (p == null) continue; // 本阶段新扫出来的，不算"失误"
      if (p != q) n++;
    }
    return n;
  }

  /// 把任意输入揉成 double?（SQLite 的 REAL 有时回 int，有时回 String，别硬转）。
  ///
  /// 名字叫 asNum 不叫 num：`num` 是 Dart 的类型名，用它当方法名会把类里的
  /// 类型标注搞得没法读。
  static double? asNum(Object? v) {
    if (v == null) return null;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString());
  }

  // ============================================================
  // 复核清单（抽盘用）
  // ============================================================

  /// 复核清单的条码集合：**前两遍（初盘 vs 复盘）对不上**的那些商品。
  ///
  /// 🔴 为什么抽盘的差异表要用它，而不是"抽盘 − 复盘"：
  ///    抽盘是"改完复核"，员工把数量改成跟复盘一致之后，`抽盘 − 复盘` 就成了 0 ——
  ///    那一行会**直接从差异表里消失**。可主管最终核对要看的恰恰是
  ///    "**前两遍就对不上的那批商品**"，改对了不等于该商品就没有疑问。
  ///    用"抽盘 − 复盘"当行集，等于"越认真复核、表越短"，最后只剩没改完的，
  ///    核对台账反而丢了。
  ///
  /// 这批集合和抽盘的**准入集合**是同一个东西（见 [InvPhase.requiresDiffSetOnly]），
  /// 所以"只能扫这些"和"表上显示这些"天然自洽。
  ///
  /// 三个方向都要算，缺一个就漏商品：
  ///   · 两遍都有、数量不同  → 数量对不上
  ///   · 初盘有、复盘没有    → 复盘漏盘
  ///   · 复盘有、初盘没有    → 复盘新扫出来的（没有参照，一样是疑问项）
  static Set<String> reviewBarcodesOf(
    Map<String, double> firstQty,
    Map<String, double> secondQty,
  ) {
    final out = <String>{};
    for (final e in firstQty.entries) {
      final q2 = secondQty[e.key];
      if (q2 == null || q2 != e.value) out.add(e.key);
    }
    for (final c in secondQty.keys) {
      if (!firstQty.containsKey(c)) out.add(c);
    }
    return out;
  }

  /// 复核结论：本遍（抽盘）扫出来的数跟上一遍（复盘）比是什么结果。
  ///
  /// 四种状态，**别压缩成"对上/没对上"两种** —— "上一遍压根没盘过"和
  /// "盘过但数不一样"的责任完全不同（前者是复盘漏了，后者才可能是抽盘又改）。
  static const String reviewAligned = 'aligned'; // 本遍 = 上一遍
  static const String reviewChanged = 'changed'; // 两边都有数，但不一致
  static const String reviewFilled = 'filled'; // 上一遍没有、本遍补上了
  static const String reviewPending = 'pending'; // 本遍还没扫

  static String reviewVerdict({double? curQty, double? prevQty}) {
    if (curQty == null) return reviewPending;
    if (prevQty == null) return reviewFilled;
    return curQty == prevQty ? reviewAligned : reviewChanged;
  }

  static String reviewVerdictLabel(String v) {
    switch (v) {
      case reviewAligned:
        return '已对上';
      case reviewChanged:
        return '复核后又改';
      case reviewFilled:
        return '补盘（上一遍没这数）';
      case reviewPending:
        return '未复核';
      default:
        return v;
    }
  }

  /// 复核清单的计数（界面统计条 / 导出抬头 / 测试判据共用一份，
  /// 免得三处各算一套、数字对不上）。
  static ReviewTally tallyReview(Iterable<Map<String, dynamic>> rows) {
    var total = 0, aligned = 0, changed = 0, filled = 0, pending = 0, missed = 0;
    for (final r in rows) {
      total++;
      switch ((r['review'] ?? '').toString()) {
        case reviewAligned:
          aligned++;
          break;
        case reviewChanged:
          changed++;
          break;
        case reviewFilled:
          filled++;
          break;
        default:
          pending++;
      }
      // 前两遍的漏盘（初盘盘过、复盘没扫到）—— 复核清单里最该看的一类
      if (r['base_missing'] == true) missed++;
    }
    return ReviewTally(
      total: total,
      aligned: aligned,
      changed: changed,
      filled: filled,
      pending: pending,
      baseMissing: missed,
    );
  }
}

/// 复核清单的计数结果。
class ReviewTally {
  const ReviewTally({
    required this.total,
    required this.aligned,
    required this.changed,
    required this.filled,
    required this.pending,
    required this.baseMissing,
  });

  /// 复核清单条数（= 前两遍对不上的商品数）。
  final int total;

  /// 复核结果与复盘一致。
  final int aligned;

  /// 两边都有数、但不一致。
  final int changed;

  /// 复盘没盘过、抽盘补上了。
  final int filled;

  /// 还没复核（抽盘这一遍没扫到）。
  final int pending;

  /// 前两遍的漏盘：初盘盘过、复盘没扫到。
  final int baseMissing;

  /// 已复核 = 三种"有结论"的合计。
  int get reviewed => aligned + changed + filled;

  /// 复核结果与复盘一致的比例（未复核的**不计入分母**；分母为 0 时返回 null，
  /// **不要返回 0** —— "没有可复核的"和"复核了全不一致"是两件事）。
  double? get alignedRatio {
    final d = reviewed;
    if (d == 0) return null;
    return aligned / d;
  }
}
