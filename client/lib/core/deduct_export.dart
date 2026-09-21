// 库房减货单的导出格式化（纯函数，不碰文件也不碰界面）。
//
// 和盘点的 InventoryExport 分开写，是因为**列不一样**：
// 盘点要账面数/差异/货架位，减货只有"减了多少"。
// 共用的只有底层那几个转义工具（csvEsc / nameOf），那部分直接复用。
//
// 🔴 CSV 必须带 UTF-8 BOM：不带的话 Excel/WPS 会按本地 GBK 打开，
//    中文商品名全是乱码 —— 而这份文件的主要去处就是"发给库房的人用 Excel 打开"。
//    （这条和盘点侧同一个理由，见 InventoryExport.toRowsCsv 的注释。）
//
// 🔴 不往 CSV 末尾塞"合计"行。
//    塞了它就**不再是纯数据文件**：以后谁想拿它二次处理（VLOOKUP、导入别的系统），
//    最后一行会变成一个莫名其妙的商品。合计是界面上要显示的东西，
//    不是数据文件的一部分。

import 'inventory_export.dart';
import 'deduct_rules.dart';

class DeductExport {
  DeductExport._();

  static const List<String> headers = <String>[
    '条码',
    '商品名',
    '规格',
    '单位',
    '减货数量',
    '扫码时间',
  ];

  /// 明细 → CSV（带 BOM）。
  static String toCsv(List<Map<String, dynamic>> rows) {
    final b = StringBuffer('\uFEFF');
    b.writeln(headers.map(InventoryExport.csvEsc).join(','));
    for (final r in rows) {
      b.writeln(<String>[
        InventoryExport.csvEsc(_barcodeCell(r['barcode'])),
        InventoryExport.csvEsc(InventoryExport.nameOf(r)),
        InventoryExport.csvEsc(r['spec']),
        InventoryExport.csvEsc(r['unit']),
        InventoryExport.csvEsc(fmtQty(r['qty'])),
        InventoryExport.csvEsc(_timeText(r['scanned_at'])),
      ].join(','));
    }
    return b.toString();
  }

  /// 条码列写成 Excel 的**文本公式**。
  ///
  /// 13 位条码（6901234567890）在 Excel 里会被当数字：超过 11 位就变科学计数法、
  /// 末尾还可能被抹成 0 —— 打印出来是一个**看起来很像样但其实是错的**条码，
  /// 现场照着它找不到货。带前导零的店内码同理（'007' 会变成 7）。
  static String _barcodeCell(Object? v) {
    final s = (v ?? '').toString().trim();
    if (s.isEmpty) return '';
    final needText = s.length >= 12 || RegExp(r'^0\d').hasMatch(s);
    return needText ? '="$s"' : s;
  }

  /// 数量：整数不带小数点（"3" 而不是 "3.0"），小数保留原始位数。
  static String fmtQty(Object? v) {
    if (v == null) return '';
    final d = v is num ? v.toDouble() : double.tryParse(v.toString());
    if (d == null) return v.toString();
    return d == d.roundToDouble() ? d.toInt().toString() : d.toString();
  }

  /// 时间戳 → `2026-09-21 09:30:15`。空值给空串（不是 "null"）。
  static String _timeText(Object? v) {
    if (v == null) return '';
    final n = v is num ? v.toInt() : int.tryParse(v.toString());
    if (n == null || n <= 0) return '';
    final d = DateTime.fromMillisecondsSinceEpoch(n);
    String two(int x) => x.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} '
        '${two(d.hour)}:${two(d.minute)}:${two(d.second)}';
  }

  static String csvName(String sheetNo) => '减货_$sheetNo.csv';

  /// 文件名里不能带路径分隔符（单号理论上不会有，但导出落盘时挡住更省事）。
  static String safeSheetNo(String sheetNo) =>
      sheetNo.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');

  /// 给界面用的一句话摘要（导出成功提示 / 提交确认都复用它，
  /// 免得两处各拼一句、说法还不一样）。
  static String summaryText(DeductTally t) =>
      '共 ${t.kinds} 种，合计减货 ${t.totalText}';
}
