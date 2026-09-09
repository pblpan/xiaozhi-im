import 'package:flutter/material.dart';
import 'package:xiaozhi_im_client/core/theme.dart';

/// 名称首字母头像：按名字哈希取渐变色，同一个人颜色稳定。
class UserAvatar extends StatelessWidget {
  final String name;
  final double size;
  final bool showOnlineDot;
  final double radius;

  const UserAvatar({
    super.key,
    required this.name,
    this.size = 46,
    this.showOnlineDot = false,
    this.radius = 14,
  });

  /// 6 组柔和渐变，避免和文字对比度打架
  static const List<List<Color>> _palette = [
    [Color(0xFF5B74F5), Color(0xFF8B5CF6)],
    [Color(0xFF2DD4BF), Color(0xFF3B82F6)],
    [Color(0xFFF59E0B), Color(0xFFEF4444)],
    [Color(0xFFEC4899), Color(0xFF8B5CF6)],
    [Color(0xFF10B981), Color(0xFF3DDC97)],
    [Color(0xFF0EA5E9), Color(0xFF6366F1)],
  ];

  List<Color> get _colors {
    final s = name.trim().isEmpty ? '?' : name.trim();
    var h = 0;
    for (final c in s.codeUnits) {
      h = (h * 31 + c) & 0x7fffffff;
    }
    return _palette[h % _palette.length];
  }

  /// 中文取首字，英文取首字母大写
  String get _initial {
    final s = name.trim();
    if (s.isEmpty) return '?';
    final first = s.characters.first;
    return first.toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final colors = _colors;
    final dot = size * 0.26;
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(radius),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: colors,
              ),
              boxShadow: [
                BoxShadow(
                  color: colors.last.withValues(alpha: 0.28),
                  blurRadius: 10,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
            alignment: Alignment.center,
            child: Text(
              _initial,
              style: TextStyle(
                color: Colors.white,
                fontSize: size * 0.42,
                fontWeight: FontWeight.w600,
                height: 1.1,
              ),
            ),
          ),
          if (showOnlineDot)
            Positioned(
              right: -1,
              bottom: -1,
              child: Container(
                width: dot,
                height: dot,
                decoration: BoxDecoration(
                  color: AppColors.online,
                  shape: BoxShape.circle,
                  border: Border.all(color: AppColors.bg, width: 2),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 品牌 Logo（登录页 / 空状态用）
class BrandLogo extends StatelessWidget {
  final double size;
  final IconData icon;
  const BrandLogo({super.key, this.size = 72, this.icon = Icons.forum_rounded});

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(size * 0.3),
          gradient: AppTheme.brandGradient,
          boxShadow: [
            BoxShadow(
              color: AppColors.brand2.withValues(alpha: 0.35),
              blurRadius: 24,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Icon(icon, color: Colors.white, size: size * 0.52),
      );
}
