// 库房减货单的**纯规则层**：一条扫码能不能入账、减货数量合不合法。
// 一行数据库代码都没有 —— 和 inventory_rules.dart 同一个理由：
// 判定写在 SQL 里或写在 `if (Platform.isAndroid)` 后面，测试就跑不到，
// 而"存进去了但规则判错了"恰恰是这类单据最大的风险。
//
// ── 规则是从哪来的 ────────────────────────────────────────────
// PG App 实测文案（`docs/盘点复刻与开放接口方案-v1.md` §P3 缺口 13）：
//     库房减货 / 减货数量 / 确定减货 / 减货列表已存在，请处理后重新扫码
// 这四句把流程钉死了：**扫条码 → 输减货数量 → 确定减货**，
// 且同一条码在一张单里**只能有一行** —— 重复扫到时它的做法是"拒绝 +
// 让你先处理掉那一行"，而不是默默累加，也不是并成两行。
//
// 🔴 为什么"重复"必须拦：
//    减货是**减库存**的动作。同一条码出现两行，减货总量就凭空翻倍，
//    而且两行长得一模一样、看起来都像正常的，事后对账根本看不出哪行是多的。
//    宁可让员工先删掉旧那行（有明确的一次覆盖动作），也不要静默累计。

import 'inventory_rules.dart';

/// 一笔扫码能不能进减货单。
enum DeductVerdict {
  /// 可以入账。
  ok,

  /// 该条码在**这张单里已经有了一行** → 拒绝，让员工先处理那一行。
  duplicate,

  /// 本单条数到达上限 → 先提交再继续。
  limit,

  /// 单据已提交/已上传 → 本地就锁死，不再接受写入。
  sheetLocked,
}

/// 判定结果 + 给员工看的话。
///
/// [message] 直接就是界面要显示的中文：判定和文案放在一起，
/// 免得界面各处自己拼一句不一样的话（同一个错有两种说法最让人困惑）。
class DeductDecision {
  const DeductDecision(this.verdict, {this.message});

  final DeductVerdict verdict;
  final String? message;

  bool get accepted => verdict == DeductVerdict.ok;

  /// 被拒时应该把扫码枪的提示音放成"错音" —— 声音是现场唯一来得及的反馈。
  bool get isError => verdict != DeductVerdict.ok;

  @override
  String toString() => 'DeductDecision($verdict${message == null ? '' : ', $message'})';
}

class DeductRules {
  DeductRules._();

  /// 单张减货单的条数上限。
  ///
  /// 和盘点同一个口径（[InventoryRules.maxRowsPerPhase] = 500），
  /// 同样是被手机内存和"一次提交几千行上传必超时"逼出来的：
  /// 不拦的话员工能一直扫到手机先趴下，而那时数据还没提交。
  static const int maxRowsPerSheet = 500;

  /// 一条扫码的准入判定。
  ///
  /// [existingBarcodes] 是**这张单里已有的条码**（不是历史所有单）——
  /// 减货单之间互不影响，昨天的单里有这个码不影响今天。
  ///
  /// [maxRows] 生产用默认值（[maxRowsPerSheet]）；**测试可以调小**
  /// （调到 2 就能验上限拦截，不用真灌 500 条）。
  static DeductDecision decide({
    required String barcode,
    required Iterable<String> existingBarcodes,
    required int sheetStatus,
    required int rowCount,
    int maxRows = maxRowsPerSheet,
  }) {
    // 顺序有讲究：
    //   ① 先判锁 —— 单子已经提交了，说什么都晚了，别给"重复了"这种误导性理由；
    //   ② 再判重复 —— 不管条数满没满，重复都要先处理那一行（这正是 PG 的做法）；
    //   ③ 最后判上限 —— 已经存在的条码**不算新行**，不该被上限拦掉。
    if (!InvSheetStatus.editable(sheetStatus)) {
      return const DeductDecision(DeductVerdict.sheetLocked,
          message: '本单已提交，不能再改');
    }

    final code = barcode.trim();
    if (code.isEmpty) {
      return const DeductDecision(DeductVerdict.duplicate,
          message: '没读到条码，请重新扫');
    }

    if (existingBarcodes.contains(code)) {
      return const DeductDecision(DeductVerdict.duplicate,
          message: '减货列表已存在，请处理后重新扫码');
    }

    if (rowCount >= maxRows) {
      return const DeductDecision(DeductVerdict.limit,
          message: '本单已达条数上限，请先提交');
    }

    return const DeductDecision(DeductVerdict.ok);
  }

  /// 减货数量合不合法。返回 null = 合法，否则返回给员工看的理由。
  ///
  /// 与盘点数量不同：盘点的数量**允许为 0**（"这个货架上一个都没有"是有信息量的），
  /// 而减货是主动的减库存动作，**0 和负数没有意义** —— 那是"没减"，
  /// 让它进单只会在汇总里多出一行什么都没减的记录。
  static String? qtyError(String raw) {
    final t = raw.trim();
    if (t.isEmpty) return '请输入减货数量';
    final v = double.tryParse(t);
    if (v == null) return '减货数量只能是数字';
    if (v <= 0) return '减货数量必须大于 0';
    // 上限只是防手滑多打几个 0（比如想输 12 打成 120000），不是业务限制。
    if (v > 100000) return '减货数量过大，请确认';
    return null;
  }

  /// 一单减货的汇总（界面上要显示"共减 N 种 / 合计 M 件"）。
  static DeductTally tally(Iterable<DeductRow> rows) {
    var kinds = 0;
    var total = 0.0;
    for (final r in rows) {
      kinds++;
      total += r.qty;
    }
    return DeductTally(kinds: kinds, totalQty: total);
  }
}

/// 汇总表的一行输入（给 [DeductRules.tally] 用）。
class DeductRow {
  const DeductRow({required this.barcode, required this.qty});

  final String barcode;
  final double qty;
}

class DeductTally {
  const DeductTally({required this.kinds, required this.totalQty});

  /// 品种数（= 明细行数）。
  final int kinds;

  /// 合计减货数量。
  final double totalQty;

  /// 合计的显示写法：整数不带小数点（"3 件" 而不是 "3.0 件"）。
  String get totalText =>
      totalQty == totalQty.roundToDouble() ? totalQty.toInt().toString() : totalQty.toString();
}
