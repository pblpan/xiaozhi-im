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

  /// 复盘：**只允许扫上一阶段的差异集**。
  static const int second = 2;

  /// 抽盘：主管抽查，扫完出"抽盘差异数据"。
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
  /// 只有复盘要。抽盘是主管随机抽查，可能抽到没差异的商品（那正是目的），
  /// 所以抽盘**不能**沿用复盘的差异集限制 —— 只是抽盘要另行校权（M2 的 P2）。
  static bool requiresDiffSetOnly(int phase) => phase == second;
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

  /// 一行是不是差异（实盘 - 账面 != 0）。
  ///
  /// 🔴 **账面缺失（未知条码）必须算差异** —— 货就在货架上、账上却没这个商品，
  ///     这是最严重的一类差异，绝不能被当成"没差异"跳过。
  ///     SQL 里写 `where qty - account_qty != 0` 会**静默丢掉这批行**
  ///     （NULL 参与比较的结果是 NULL，不是 TRUE），所以这条判定放在 Dart 里做。
  static bool isDiffRow(Map<String, dynamic> row) {
    final diff = _num(row['diff_qty']);
    if (diff == null) return true;
    return diff != 0;
  }

  /// 从带 `diff_qty` 的行集里取出差异集条码。
  static Set<String> diffBarcodesOf(Iterable<Map<String, dynamic>> rows) {
    final out = <String>{};
    for (final r in rows) {
      final code = (r['barcode'] ?? '').toString().trim();
      if (code.isEmpty) continue;
      if (isDiffRow(r)) out.add(code);
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
      final q = _num(r['qty']);
      if (c.isEmpty || q == null) continue;
      prev[c] = q;
    }

    var n = 0;
    for (final r in curRows) {
      final c = (r['barcode'] ?? '').toString().trim();
      final q = _num(r['qty']);
      if (c.isEmpty || q == null) continue;
      final p = prev[c];
      if (p == null) continue; // 本阶段新扫出来的，不算"失误"
      if (p != q) n++;
    }
    return n;
  }

  /// 把任意输入揉成 num?（SQLite 的 REAL 有时回 int，有时回 String，别硬转）。
  static double? _num(Object? v) {
    if (v == null) return null;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString());
  }
}
