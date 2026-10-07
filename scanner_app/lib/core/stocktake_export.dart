import 'csv_fmt.dart';

/// 扫码枪出数：把一张扫码单算成"老板要看的那几个数"，并导出成**通用文件**。
///
/// ── 为什么导出 CSV 而不是"泰格导入模板" ──────────────────────
/// 这套扫码出数不只接泰格。现场扫的可能是泰格、可能是超盘这类盘点软件、
/// 也可能是别的进销存 —— 它们的导入格式各不相同，而且会变。
/// 把导出格式焊死在某一家的模板上，等于每次换系统都要改代码。
/// 所以这里只出**一份干净的 CSV**：条码/品名/实盘/账面/差异/差异金额，
/// 谁都能打开、谁都能再加工（要导入泰格就另存模板，要导入别的就另存）。
/// 一份通用中间格式 + 各家自己的导入动作，比 N 份专用格式好维护。
///
/// ── 关于 UTF-8 BOM ──────────────────────────────────────────
/// Windows 上的 Excel 打开没有 BOM 的 UTF-8 会**按本地编码解**，
/// 中文整片变乱码。这不是小事：老板打开一张全是"锟斤拷"的表，
/// 第一反应是"系统坏了"，而不是"编码问题"。所以导出的字节流开头
/// 必须带 `\uFEFF`。这条由测试钉着。
class StocktakeExport {
  /// 表头顺序。改这里要同步改 toCsv 与测试。
  static const List<String> headers = <String>[
    '条码',
    '品名',
    '规格',
    '单位',
    '单价',
    '账面数',
    '实盘数',
    '差异数量',
    '差异金额',
    '备注',
  ];

  /// 汇总一张单。入参是 `StocktakeRepo.listWithMaster()` 的结果。
  ///
  /// 口径（**盘盈为正、盘亏为正数的"亏损额"**，别混着用符号）：
  ///   diff = 实盘 - 账面
  ///   diff > 0 → 盘盈（实际比账面多）
  ///   diff < 0 → 盘亏（实际比账面少）
  ///   金额一律取**正数**表示"盈了多少 / 亏了多少"，净额再相减。
  ///   混用符号的话，"亏了 300" 会被显示成 "-300"，跟"盈了 300"的
  ///   报表行放一起时极易看反 —— 这是盈亏报表最典型的误读。
  ///
  /// 账面缺失（account_qty 为 null）的行**不计入盈亏统计**，
  /// 只单独计数：不知道账面多少，就不能说它盈了还是亏了。
  /// 把它按 0 算，会让"商档没同步好"表现成"大面积盘盈"。
  static Map<String, dynamic> summarize(List<Map<String, dynamic>> rows) {
    double gainAmt = 0;
    double lossAmt = 0;
    double gainQty = 0;
    double lossQty = 0;
    int gainKinds = 0;
    int lossKinds = 0;
    int flatKinds = 0;
    int noAccount = 0;
    int unknown = 0;
    double totalQty = 0;
    double amountKnown = 0; // 有单价的那部分差异金额（净额只对这部分负责）

    for (final r in rows) {
      final qty = _d(r['qty']);
      totalQty += qty;

      final name = (r['name'] ?? '').toString();
      if (name.isEmpty) unknown++;

      final account = r['account_qty'] == null ? null : _d(r['account_qty']);
      if (account == null) {
        noAccount++;
        continue; // 不知道账面 → 不参与盈亏
      }
      final diff = qty - account;
      final price = r['unit_price'] == null ? null : _d(r['unit_price']);
      final amt = price == null ? null : diff * price;

      if (diff > 0) {
        gainKinds++;
        gainQty += diff;
        if (amt != null) gainAmt += amt;
      } else if (diff < 0) {
        lossKinds++;
        lossQty += -diff;
        if (amt != null) lossAmt += -amt;
      } else {
        flatKinds++;
      }
      if (amt != null) amountKnown += amt;
    }

    return <String, dynamic>{
      'kinds': rows.length,
      'total_qty': totalQty,
      'gain_kinds': gainKinds,
      'gain_qty': gainQty,
      'gain_amt': gainAmt,
      'loss_kinds': lossKinds,
      'loss_qty': lossQty,
      'loss_amt': lossAmt,
      'flat_kinds': flatKinds,
      'net_amt': amountKnown,
      'no_account': noAccount,
      'unknown': unknown,
    };
  }

  /// 导出 CSV 文本。**开头带 UTF-8 BOM**，Excel 双击不乱码。
  static String toCsv(List<Map<String, dynamic>> rows) {
    final sb = StringBuffer('\uFEFF'); // BOM：Excel 认它是 UTF-8
    sb.writeln(headers.map(csvEsc).join(','));
    for (final r in rows) {
      final qty = _d(r['qty']);
      final account = r['account_qty'] == null ? null : _d(r['account_qty']);
      final price = r['unit_price'] == null ? null : _d(r['unit_price']);
      final diff = account == null ? null : qty - account;
      final amt = (diff == null || price == null) ? null : diff * price;

      sb.writeln(<Object?>[
        barcodeCsvCell(r['barcode']),
        r['name'] ?? '',
        r['spec'] ?? '',
        r['unit'] ?? '',
        price == null ? '' : _num(price),
        account == null ? '' : _num(account),
        _num(qty),
        diff == null ? '' : _num(diff),
        amt == null ? '' : _num(amt),
        r['note'] ?? '',
      ].map((v) => csvEsc(v.toString())).join(','));
    }
    return sb.toString();
  }

  /// 明细筛选模式。序号与界面上的筛选条一一对应。
  static const int filterAll = 0;
  static const int filterDiff = 1;
  static const int filterLoss = 2;
  static const int filterGain = 3;
  static const int filterNoAccount = 4;

  /// 差异数量 = 实盘 - 账面。账面缺失时为 **null**（"不知道差多少"不是"差 0"）。
  static double? diffOf(Map<String, dynamic> r) {
    final account = r['account_qty'];
    if (account == null) return null;
    return _d(r['qty']) - _d(account);
  }

  /// 差异金额 = 差异数量 × 单价。缺账面或缺单价时为 null。
  static double? amtOf(Map<String, dynamic> r) {
    final diff = diffOf(r);
    final price = r['unit_price'];
    if (diff == null || price == null) return null;
    return diff * _d(price);
  }

  /// 按筛选模式挑行。
  ///
  /// 有差异/盘亏/盘盈三档按**差异金额绝对值**从大到小排：
  /// 老板真正要看的是"差得最多的那几个"，不是扫码先后顺序。
  /// 没有单价时退回按差异数量排 —— 否则一堆金额全为 null 的行会乱序堆在一起。
  /// 抽成纯函数是为了能测：这段排序写错了不会崩，只会把"亏得最狠的"排在
  /// 第 20 行没人看见，属于**错了不报错**的那类。
  static List<Map<String, dynamic>> filter(
      List<Map<String, dynamic>> rows, int mode) {
    final out = rows.where((r) {
      final d = diffOf(r);
      switch (mode) {
        case filterDiff:
          return d != null && d != 0;
        case filterLoss:
          return d != null && d < 0;
        case filterGain:
          return d != null && d > 0;
        case filterNoAccount:
          return d == null;
        default:
          return true;
      }
    }).toList();

    if (mode >= filterDiff && mode <= filterGain) {
      out.sort((a, b) {
        final c = (amtOf(b) ?? 0).abs().compareTo((amtOf(a) ?? 0).abs());
        if (c != 0) return c;
        return (diffOf(b) ?? 0).abs().compareTo((diffOf(a) ?? 0).abs());
      });
    }
    return out;
  }

  /// 导出文件名：扫码_单号.csv
  /// 🔴 [name] = 单据名（龙哥 2026-10-06）：起了名的单，导出/转发文件名就用名字，
  /// 不能再退回单号 —— 之前就是栽在"转发出去的文件名还是 PD+时间戳"上。
  /// 名字空/没起过才兜底用单号。下面三个命名函数同一条规则。
  static String fileName(String sheetNo, [String? name]) =>
      '扫码_${_label(sheetNo, name)}.csv';

  // ── 扫码明细导出（采集页底部「导出」用） ─────────────────────────
  //
  // 采集页的列表就是员工扫进来的原始账：序号/条码/数量/商品名称。
  // 和盈亏表那一份（含账面/差异/金额）是**两份不同的东西**：
  //   · 盈亏表给老板看结果 → 文件名「扫码_单号.csv」
  //   · 扫码明细给录单/对账用 → 文件名「扫码明细_单号.csv / .txt」
  // 文件名故意错开，免得两份文件在微信里发来发去后搞混。

  /// 明细表头。改这里要同步改 toScanCsv 与测试。
  static const List<String> scanHeaders = <String>[
    '序号',
    '条码',
    '数量',
    '商品名称',
  ];

  /// 没扫到名称时统一用这个占位值（界面与导出一致，别一处"未知"一处空）。
  static String scanNameOf(Map<String, dynamic> r) {
    final n = (r['name'] ?? '').toString().trim();
    return n.isEmpty ? '未知条码' : n;
  }

  /// 扫码明细 CSV。开头带 UTF-8 BOM（同 toCsv，Excel 双击不乱码）。
  static String toScanCsv(List<Map<String, dynamic>> rows) {
    final sb = StringBuffer('\uFEFF');
    sb.writeln(scanHeaders.map(csvEsc).join(','));
    for (var i = 0; i < rows.length; i++) {
      final r = rows[i];
      sb.writeln(<Object?>[
        i + 1,
        barcodeCsvCell(r['barcode']),
        _num(_d(r['qty'])),
        scanNameOf(r),
      ].map((v) => csvEsc(v.toString())).join(','));
    }
    return sb.toString();
  }

  /// 扫码明细文本文档（.txt）。🔴 龙哥 2026-10-06 定版：
  /// 每行就三个字段、**空格分隔** —— 「条码 数量 商品名」，其他一律不带
  /// （没有表头/序号/单号/时间/统计行 —— 发微信就是一张干净清单）。
  /// 名字放最后一列：条码和数量本身不含空格，粘到别处按前两列取就行。
  /// 开头带 UTF-8 BOM（不可见）：老版 WPS/记事本不按 UTF-8 猜就不会乱码。
  ///
  /// 🔴 2026-10-08 修「没有回车键、连成一行」：换行必须显式用 `\r\n`（CRLF）。
  /// Dart 的 `writeln` 只输出 `\n`（LF），Windows 老版记事本不认单独的 LF，
  /// 整文件会被显示成一行 —— 龙哥说的"没有回车键"就是这个。CRLF 在所有
  /// Windows 文本查看器（含老版记事本）里都能正常换行，而内容字段不变。
  static String toScanDoc(List<Map<String, dynamic>> rows,
      {String sheetNo = ''}) {
    final sb = StringBuffer('\uFEFF');
    for (final r in rows) {
      sb.write(
          '${r['barcode'] ?? ''} ${_num(_d(r['qty']))} ${scanNameOf(r)}\r\n');
    }
    return sb.toString();
  }

  /// 扫码明细文件名（与盈亏表的 fileName 故意错开，见上）。
  static String scanCsvName(String sheetNo, [String? name]) =>
      '扫码明细_${_label(sheetNo, name)}.csv';
  static String scanDocName(String sheetNo, [String? name]) =>
      '扫码明细_${_label(sheetNo, name)}.txt';

  /// 文件名里的"单据标识"：有名字用名字，没名字用单号。
  static String _label(String sheetNo, String? name) {
    final n = (name ?? '').trim();
    return n.isEmpty ? sheetNo : n;
  }

  /// 数量/金额的显示格式（整数不带 .0，小数最多 3 位）。
  ///
  /// CSV 和界面共用这一个出口：两边各写一套的话，迟早出现
  /// "表里是 3、屏幕上是 3.0"，老板对着两张数对不上。
  static String fmtNum(Object? v) => _num(_d(v));

  static double _d(Object? v) =>
      v is num ? v.toDouble() : double.tryParse((v ?? '').toString()) ?? 0;

  /// 数量/金额：整数不带 .0，其余最多 3 位小数并去掉尾随 0
  static String _num(double d) {
    if (d == d.roundToDouble()) return d.toStringAsFixed(0);
    return d
        .toStringAsFixed(3)
        .replaceAll(RegExp(r'0+$'), '')
        .replaceAll(RegExp(r'\.$'), '');
  }
}
