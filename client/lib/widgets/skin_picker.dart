import 'package:flutter/material.dart';

import '../core/theme.dart';

/// 皮肤选择面板（手机：底部弹窗 / 桌面：居中对话框）。
///
/// 为什么每一张卡片都**用那套皮肤自己的色值**画一个迷你聊天窗口，
/// 而不是写"深色 / 浅色"：两个词描述不了实际观感，六套更没法用文字区分。
/// 自己画预览之后，人在深色皮肤下也能一眼看清浅色皮肤长什么样 ——
/// 这是整个面板存在的意义，省掉它就得靠"切过去看看再切回来"。
///
/// 点一张立刻换，不设"确定"：换肤本质是"看了才知道好不好"，
/// 先选后确认等于让人盲选。不喜欢再点回原来那张，一秒的事。
class SkinPickerSheet extends StatelessWidget {
  const SkinPickerSheet({super.key});

  /// 弹出面板。
  ///
  /// 桌面（宽屏）走居中对话框 —— 宽屏上底部弹窗又远又别扭，
  /// 而 PC 正是本轮的主战场（龙哥 2026-10-17："把 PC 端的皮肤一起加进去"）。
  /// 窄屏沿用原来的底部弹窗，手机单手够得着。
  static Future<void> show(BuildContext context) async {
    final wide = MediaQuery.sizeOf(context).width > 720;
    if (wide) {
      await showDialog<void>(
        context: context,
        builder: (_) => Dialog(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 540),
            child: const SkinPickerSheet(),
          ),
        ),
      );
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.bgElevated,
      shape: const RoundedRectangleBorder(
        borderRadius:
            BorderRadius.vertical(top: Radius.circular(AppRadii.xl)),
      ),
      builder: (_) => const SafeArea(child: SkinPickerSheet()),
    );
  }

  @override
  Widget build(BuildContext context) {
    // 监听 changed：换肤后整棵树重建，这里要跟着刷新"当前选中"的勾。
    // 面板自身也在这次重建范围内，所以预览与标题色都是新的。
    return ValueListenableBuilder<AppPalette>(
      valueListenable: AppSkin.changed,
      builder: (context, cur, _) => Padding(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(Icons.palette_outlined, size: 19, color: AppColors.text),
              const SizedBox(width: 8),
              Text('皮肤',
                  style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: AppColors.text)),
              const Spacer(),
              Text('共 ${AppPalette.all.length} 套',
                  style:
                      TextStyle(fontSize: 12, color: AppColors.textWeak)),
            ]),
            const SizedBox(height: 4),
            Text('点一下就换，不喜欢随时换回来',
                style: TextStyle(fontSize: 12, color: AppColors.textWeak)),
            const SizedBox(height: 14),
            LayoutBuilder(builder: (c, box) {
              // 桌面对话框给到 540 宽 → 3 列；手机底部弹窗 ~360 → 2 列。
              final n = box.maxWidth >= 420 ? 3 : 2;
              return GridView.count(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                crossAxisCount: n,
                mainAxisSpacing: 10,
                crossAxisSpacing: 10,
                childAspectRatio: 1.1,
                children: [
                  for (final p in AppPalette.all)
                    _SkinCard(
                      palette: p,
                      selected: identical(p, cur),
                      onTap: () {
                        AppSkin.set(p);
                      },
                    ),
                ],
              );
            }),
          ],
        ),
      ),
    );
  }
}

class _SkinCard extends StatelessWidget {
  const _SkinCard({
    required this.palette,
    required this.selected,
    required this.onTap,
  });

  final AppPalette palette;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadii.md),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: palette.surface,
            borderRadius: BorderRadius.circular(AppRadii.md),
            border: Border.all(
              color: selected ? palette.brand : palette.border,
              width: selected ? 2 : 1,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: _preview(palette)),
              Container(
                color: palette.bgElevated,
                padding: const EdgeInsets.fromLTRB(8, 6, 6, 6),
                child: Row(children: [
                  Expanded(
                    child: Text(palette.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            color: palette.text)),
                  ),
                  if (selected)
                    Icon(Icons.check_circle_rounded,
                        size: 15, color: palette.brand),
                ]),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 迷你聊天窗口预览：顶栏 + 对方气泡 + 自己气泡（品牌渐变）+ 输入条 + 语义色点。
/// 把语义色（在线/警示/危险）也画出来，是因为它们各套皮肤之间差异最大，
/// 只露背景色的话"极夜青"和"午夜蓝"在缩略图上几乎分不出来。
Widget _preview(AppPalette p) => Container(
      color: p.bg,
      padding: const EdgeInsets.fromLTRB(8, 7, 8, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
              height: 5,
              decoration: BoxDecoration(
                  color: p.bgElevated,
                  borderRadius: BorderRadius.circular(2))),
          const SizedBox(height: 6),
          Align(
            alignment: Alignment.centerLeft,
            child: Container(
                height: 8,
                width: 34,
                decoration: BoxDecoration(
                    color: p.bubbleOther,
                    borderRadius: BorderRadius.circular(3))),
          ),
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerRight,
            child: Container(
                height: 8,
                width: 26,
                decoration: BoxDecoration(
                    gradient: LinearGradient(colors: [p.brand, p.brand2]),
                    borderRadius: BorderRadius.circular(3))),
          ),
          const Spacer(),
          Container(
              height: 7,
              decoration: BoxDecoration(
                  color: p.surfaceHi,
                  borderRadius: BorderRadius.circular(3))),
          const SizedBox(height: 5),
          Row(children: [
            _dot(p.online),
            const SizedBox(width: 4),
            _dot(p.warn),
            const SizedBox(width: 4),
            _dot(p.danger),
            const Spacer(),
            Container(
                width: 14,
                height: 5,
                decoration: BoxDecoration(
                    color: p.textSub.withValues(alpha: 0.45),
                    borderRadius: BorderRadius.circular(2))),
          ]),
        ],
      ),
    );

Widget _dot(Color c) =>
    Container(width: 5, height: 5, decoration: BoxDecoration(color: c, shape: BoxShape.circle));
