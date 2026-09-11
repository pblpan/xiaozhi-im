import 'package:flutter/material.dart';
import 'package:xiaozhi_im_client/core/config.dart';
import 'package:xiaozhi_im_client/core/theme.dart';

/// 用户头像。
///
/// 有 `imageUrl` 就显示真实头像图；没有（或加载失败）回落到
/// 「名字首字 + 哈希渐变」—— 保证任何用户在任何场景都有稳定、可辨识的外观，
/// 不会出现空白方块或问号。
class UserAvatar extends StatelessWidget {
  final String name;
  final double size;
  final bool showOnlineDot;
  final double radius;

  /// 头像图片地址：站内相对路径（`/files/xxx.png`）或 http(s) 绝对地址。
  final String? imageUrl;

  const UserAvatar({
    super.key,
    required this.name,
    this.size = 46,
    this.showOnlineDot = false,
    this.radius = 14,
    this.imageUrl,
  });

  /// 6 组柔和渐变，避免和文字对比度打架
  static const List<List<Color>> _palette = [
    [Color(0xFF10B981), Color(0xFF06B6D4)], // 青绿→青蓝（品牌主色系）
    [Color(0xFFF59E0B), Color(0xFFEF4444)], // 琥珀→珊瑚红
    [Color(0xFFEC4899), Color(0xFF8B5CF6)], // 玫粉→紫罗兰
    [Color(0xFFF97316), Color(0xFFEAB308)], // 橙→金黄
    [Color(0xFF84CC16), Color(0xFF14B8A6)], // 柠檬→翠青
    [Color(0xFF0EA5E9), Color(0xFF6366F1)], // 青→靛蓝
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

  /// 把 avatar 字段解析成可用的图片 URL。
  /// 服务端存的是 `/files/xxx.png` 相对路径（跨内网/外网都能用，
  /// 因为域名前缀由客户端当前选中的服务器决定）；也兼容历史数据里的绝对地址。
  String? get _resolvedUrl {
    final u = imageUrl?.trim();
    if (u == null || u.isEmpty) return null;
    if (u.startsWith('http://') || u.startsWith('https://')) return u;
    if (u.startsWith('/')) return '${Config.baseUrl}$u';
    return null; // 相对路径之外的一律不认，避免拼出诡异 URL
  }

  Widget _initialBox() => Center(
        child: Text(
          _initial,
          style: TextStyle(
            color: Colors.white,
            fontSize: size * 0.42,
            fontWeight: FontWeight.w600,
            height: 1.1,
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final colors = _colors;
    final dot = size * 0.26;
    final url = _resolvedUrl;
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: size,
            height: size,
            clipBehavior: Clip.antiAlias,
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
            child: url == null
                ? _initialBox()
                : Image.network(
                    url,
                    width: size,
                    height: size,
                    fit: BoxFit.cover,
                    // 加载中先铺首字母：头像在列表里高频出现，
                    // 留白会闪出一片空格子，比慢一点更难看
                    loadingBuilder: (c, child, p) =>
                        p == null ? child : _initialBox(),
                    errorBuilder: (c, e, s) => _initialBox(),
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
