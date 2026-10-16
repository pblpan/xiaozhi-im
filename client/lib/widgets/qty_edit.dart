import 'package:flutter/material.dart';

import '../core/qty_fmt.dart';
import '../core/theme.dart';

// fmtQty 本体搬到了 core/qty_fmt.dart（纯 Dart）—— 导出层也要用它，
// 而导出层不该为一个数字格式化依赖 Flutter。这里转出去，
// 原来 `import 'qty_edit.dart'` 的地方（采集页等）不用改。
export '../core/qty_fmt.dart' show fmtQty;

/// 「改数量」对话框 + 校验 + "改成 0 先确认"。
///
/// 为什么抽成公共组件（而不是每个采集页各写一份）：
/// 这段里有一处**极难倒查的 bug**，抽出来只修一次、只守一次 ——
/// 抄第二份就等于给它留了第二条复活的路。详见下面 [_QtyDialog] 的注释。
///
/// 调用方（扫码枪采集页、盘点采集页）只管"拿新数量去落库"。

/// 弹出改数量对话框，返回**校验通过的新数量**。
///
/// 返回 `null` 表示"什么都没改"，三种情况：
///   · 用户点了取消 / 点对话框外面关掉；
///   · 输入的不是数字（通过 [onMessage] 告诉用户，别静默什么都不做 ——
///     员工会以为"改了没生效"，然后反复改）；
///   · 输入负数；
///   · 输入 0 但在"确定删除吗"那一步取消了。
///
/// 🔴 0 必须二次确认：手滑多按一个 0 就静默删行，是员工第二天才发现的那种错。
Future<double?> askQty(
  BuildContext context, {
  required String subtitle,
  required double current,
  String? confirmText,
  void Function(String msg)? onMessage,
}) async {
  final v = await showDialog<String>(
    context: context,
    builder: (ctx) => _QtyDialog(subtitle: subtitle, initial: fmtQty(current)),
  );
  if (v == null) return null;
  if (!context.mounted) return null;

  final n = double.tryParse(v.trim());
  if (n == null) {
    onMessage?.call('「${v.trim()}」不是数字，没改');
    return null;
  }
  if (n < 0) {
    onMessage?.call('数量不能是负数');
    return null;
  }
  if (n == 0) {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.bgElevated,
        title:  Text('改成 0 = 删掉这一行',
            style: TextStyle(color: AppColors.text, fontSize: 16)),
        content: Text(confirmText ?? '确定删除这一行？',
            style: TextStyle(color: AppColors.textSub)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child:
                  Text('删除', style: TextStyle(color: AppColors.danger))),
        ],
      ),
    );
    if (ok != true) return null;
    return 0;
  }
  return n;
}

/// 「改数量」对话框。
///
/// 🔴 **为什么必须是独立的 StatefulWidget，而不是在调用处 new 一个
///    TextEditingController、`await showDialog(...)` 回来就 `dispose()`：**
///
/// `await showDialog(...)` 在 `Navigator.pop` 那一刻就返回了，可这时对话框
/// **还在播退场动画**，`TextField` 这 200ms 里还在重建、还在向控制器注册监听。
/// 提前 dispose 会直接抛 `A TextEditingController was used after being disposed`，
/// 并连带把焦点树和布局搞乱 —— 实测报 `RenderFlex overflowed by 99634 pixels`，
/// 报错指向的是"布局溢出"，跟真凶（控制器生命周期）看着毫无关系，极难倒查。
///
/// 交给对话框自己持有 → 它的 `State.dispose()` 在**路由真正被移除时**才跑，
/// 时序天然正确；而且"用户点对话框外面关掉"那条路径也自动覆盖到了
/// （在调用处手动 dispose 的话，很容易只处理 保存/取消 两条路）。
class _QtyDialog extends StatefulWidget {
  const _QtyDialog({required this.subtitle, required this.initial});

  /// 副标题：商品名 + 条码，让人确认改的是哪一行
  final String subtitle;
  final String initial;

  @override
  State<_QtyDialog> createState() => _QtyDialogState();
}

class _QtyDialogState extends State<_QtyDialog> {
  late final TextEditingController _ctrl =
      TextEditingController(text: widget.initial);

  @override
  void initState() {
    super.initState();
    // 全选：员工要的是"直接覆盖"，不是先删掉原来那串再输
    _ctrl.selection =
        TextSelection(baseOffset: 0, extentOffset: _ctrl.text.length);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.bgElevated,
      title:  Text('改数量',
          style: TextStyle(color: AppColors.text, fontSize: 16)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.subtitle,
            style: TextStyle(color: AppColors.textWeak, fontSize: 12),
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _ctrl,
            autofocus: true,
            // 数量可能是小数（称重商品按公斤），所以允许小数点
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            style: TextStyle(color: AppColors.text, fontSize: 16),
            textInputAction: TextInputAction.done,
            onSubmitted: (s) => Navigator.pop(context, s),
            decoration: InputDecoration(
              hintText: '数量',
              hintStyle: TextStyle(color: AppColors.textWeak),
              filled: true,
              fillColor: AppColors.surface,
              isDense: true,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide.none,
              ),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context), child: const Text('取消')),
        TextButton(
          onPressed: () => Navigator.pop(context, _ctrl.text),
          child:  Text('保存',
              style:
                  TextStyle(color: AppColors.brand, fontWeight: FontWeight.w600)),
        ),
      ],
    );
  }
}
