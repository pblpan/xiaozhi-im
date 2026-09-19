/// 数量的显示口径（**纯 Dart，不依赖 Flutter**）。
///
/// ── 为什么单独一个文件 ──────────────────────────────────────────
/// 这个函数本来是写在 `widgets/qty_edit.dart`（那个对话框组件）里的。
/// 但导出层（`core/inventory_export.dart`）也要用它 ——
/// 而导出层是**纯函数、零 IO、零 Flutter** 的，就为了一个数字格式化
/// 把整个 material 拖进来，等于把"可以脱离界面测试"这件事丢掉了。
///
/// 更重要的是：**界面上数量怎么显示，导出文件里必须一模一样**。
/// 同一批数据在屏幕上是 `12`、在 CSV 里是 `12.0`，收货的人会怀疑
/// 导出的到底是不是屏幕上那份。所以这个口径只能有一处。
library;

/// 整数不拖小数点（12 而不是 12.0），小数保留原样（称重商品按公斤）。
String fmtQty(Object? v) {
  final d = v is num ? v.toDouble() : double.tryParse('${v ?? 0}') ?? 0;
  if (d == d.roundToDouble()) return d.toInt().toString();
  return d.toString();
}
