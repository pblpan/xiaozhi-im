// 补货单的导出格式化（纯函数，不碰文件也不碰界面）。
//
// 列和减货不一样的地方只有一列 —— **转换公斤**。
// 它存在的理由：杂百按最小单位记（件/个/瓶），而对账的人和物流口径常用公斤。
// 折不出的行这一列**留空**而不是填 0：填 0 会让人以为"这件货没有重量"，
// 其实是"商档的规格里没写克重"。
//
// 🔴 CSV 必须带 UTF-8 BOM（同减货/盘点），不然 Excel 打开中文全是乱码。
// 🔴 不往 CSV 末尾塞合计行：塞了它就不再是纯数据文件。

import 'inventory_export.dart';
import 'replenish_rules.dart';

class ReplenishExport {
  ReplenishExport._();

  static const List<String> headers = <String>[
    '条码',
    '商品名',
    '规格',
    '补货数量',
    '单位',
    '转换公斤',
    '扫码时间',
  ];

  /// 明细 → CSV（带 BOM）。
  ///
  /// [scene] 决定主单位写什么、以及"转换公斤"怎么算 ——
  /// 生鲜的主单位**就是**公斤，那种行的转换公斤直接等于补货数量（不是折算）。
  static String toCsv(List<Map<String, dynamic>> rows, {required String scene}) {
    final sc = ReplenishScene.normalize(scene);
    final isKg = ReplenishUnit.ofScene(sc) == ReplenishUnit.kg;
    final b = StringBuffer('\uFEFF');
    b.writeln(headers.map(InventoryExport.csvEsc).join(','));
    for (final r in rows) {
      final qty = (r['qty'] as num? ?? 0).toDouble();
      final spec = (r['spec'] ?? '').toString();
      final kg = isKg ? qty : ReplenishRules.specWeightKg(spec) == null
          ? null
          : qty * ReplenishRules.specWeightKg(spec)!;
      b.writeln(<String>[
        InventoryExport.csvEsc(_barcodeCell(r['barcode'])),
        InventoryExport.csvEsc(InventoryExport.nameOf(r)),
        InventoryExport.csvEsc(spec),
        InventoryExport.csvEsc(fmtQty(qty)),
        InventoryExport.csvEsc(ReplenishUnit.label(ReplenishUnit.ofScene(sc))),
        InventoryExport.csvEsc(kg == null ? '' : kg.toStringAsFixed(3)),
        InventoryExport.csvEsc(_timeText(r['scanned_at'])),
      ].join(','));
    }
    return b.toString();
  }

  /// 条码列写成 Excel 文本公式：13 位条码会被当数字变成科学计数法，
  /// 打印出来是一个看着像样、其实错的条码。
  static String _barcodeCell(Object? v) {
    final s = (v ?? '').toString().trim();
    if (s.isEmpty) return '';
    final needText = s.length >= 12 || RegExp(r'^0\d').hasMatch(s);
    return needText ? '="$s"' : s;
  }

  /// 整数不带小数点（"3" 而不是 "3.0"）。
  static String fmtQty(Object? v) {
    if (v == null) return '';
    final d = v is num ? v.toDouble() : double.tryParse(v.toString());
    if (d == null) return v.toString();
    return d == d.roundToDouble() ? d.toInt().toString() : d.toString();
  }

  static String _timeText(Object? v) {
    if (v == null) return '';
    final n = v is num ? v.toInt() : int.tryParse(v.toString());
    if (n == null || n <= 0) return '';
    final d = DateTime.fromMillisecondsSinceEpoch(n);
    String two(int x) => x.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} '
        '${two(d.hour)}:${two(d.minute)}:${two(d.second)}';
  }

  static String csvName(String sheetNo) => '补货_$sheetNo.csv';

  static String safeSheetNo(String sheetNo) =>
      sheetNo.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');

  /// 给界面用的一句话摘要。
  static String summaryText(ReplenishTally t, String scene) {
    final unit = ReplenishUnit.label(ReplenishUnit.ofScene(scene));
    final s = '共 ${t.kinds} 种，合计 ${fmtQty(t.totalQty)} $unit';
    if (t.unknownWeight > 0) {
      return '$s（其中 ${t.unknownWeight} 种规格里没写克重，折不出公斤）';
    }
    return '$s，折合 ${t.totalKg.toStringAsFixed(3)} 公斤';
  }
}
