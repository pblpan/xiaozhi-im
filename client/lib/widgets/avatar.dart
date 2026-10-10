import 'package:flutter/material.dart';
import 'package:xiaozhi_im_client/core/config.dart';
import 'package:xiaozhi_im_client/core/theme.dart';
import 'package:xiaozhi_im_client/models.dart';
import 'package:xiaozhi_im_client/widgets/cached_image.dart';

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
                : XzCachedImage(
                    url: url,
                    width: size,
                    height: size,
                    fit: BoxFit.cover,
                    // 加载中先铺首字母：头像在列表里高频出现，
                    // 留白会闪出一片空格子，比慢一点更难看
                    progressIndicatorBuilder: (c, u, p) => _initialBox(),
                    errorWidget: (c, e, s) => _initialBox(),
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

/// 群头像：用成员头像拼出来的九宫格（微信/QQ 那一套）。
///
/// 为什么不用「群资料里上传一张图」当群头像：
///   · 绝大多数群没人会去专门上传一张图，结果就是所有群都长一个默认图标，
///     列表里一排灰方块 —— 这正是龙哥说的"个人聊天和群聊不好区分"。
///   · 用成员头像拼，群一建起来就有辨识度，成员进出还会自己更新。
/// 群主/管理员由服务端排在前面（见 routes/messages.js），所以第一格基本是群主。
///
/// 拼法（与微信一致）：
///   1 人 → 整张；2~4 人 → 2 列；5 人及以上 → 3 列（最多 9 格）
/// 最后一格不满时**居中**，否则 3 人会变成"上两个、左下角空一块"的歪斜观感。
class GroupAvatar extends StatelessWidget {
  final List<AvatarSeed> members;
  final double size;
  final double radius;

  /// 右下角要不要挂一个「群」的小徽标。
  /// 只有 1 个成员的群（或拉取失败的兜底）拼出来跟单聊头像一模一样，
  /// 没有这个角标就彻底分不出来了。
  final bool showGroupBadge;

  const GroupAvatar({
    super.key,
    required this.members,
    this.size = 46,
    this.radius = 14,
    this.showGroupBadge = true,
  });

  static const double _gap = 1.5;

  @override
  Widget build(BuildContext context) {
    // 没有素材（老服务端 / 刚建群还没拉到成员）时退回普通头像，不留空白
    if (members.isEmpty) {
      return UserAvatar(name: '群', size: size, radius: radius);
    }

    final n = members.length.clamp(1, 9);
    final cols = n == 1 ? 1 : (n <= 4 ? 2 : 3);
    final rows = (n / cols).ceil();
    final cell = (size - _gap * (cols - 1)) / cols;

    final gridRows = <Widget>[];
    for (var r = 0; r < rows; r++) {
      final start = r * cols;
      final end = (start + cols).clamp(0, n);
      gridRows.add(Row(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = start; i < end; i++)
            Padding(
              padding: EdgeInsets.only(
                left: i > start ? _gap : 0,
                top: r > 0 ? _gap : 0,
              ),
              child: SizedBox(
                width: cell,
                height: cell,
                // 直接复用 UserAvatar：真实头像图、加载失败的哈希渐变首字
                // 兜底都在它里面，不重写一遍就不会出现"两种头像两套兜底"
                child: UserAvatar(
                  name: members[i].name,
                  size: cell,
                  radius: cell * 0.24,
                  imageUrl: members[i].imageUrl,
                ),
              ),
            ),
        ],
      ));
    }

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
              // 格子之间的缝隙要能看出底色，否则九宫格会糊成一整块
              color: AppColors.surfaceHi,
            ),
            alignment: Alignment.center,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: gridRows,
            ),
          ),
          if (showGroupBadge)
            Positioned(
              right: -2,
              bottom: -2,
              child: Container(
                width: size * 0.34,
                height: size * 0.34,
                decoration: BoxDecoration(
                  color: AppColors.brand,
                  shape: BoxShape.circle,
                  border: Border.all(color: AppColors.bg, width: 1.6),
                ),
                child: Icon(
                  Icons.groups_rounded,
                  color: Colors.white,
                  size: size * 0.2,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 「文件助手」头像。
///
/// 它是个功能入口而不是一个人，所以刻意做得跟人头像不一样：
/// 圆角方块（人头像更圆）+ 文件夹图标 + 琥珀色（与人头像的青绿/暖色渐变区分开）。
/// 列表里扫一眼就知道"这个是传文件用的"，不会跟某个同事搞混。
class FileHelperAvatar extends StatelessWidget {
  final double size;
  final double radius;

  const FileHelperAvatar({super.key, this.size = 46, this.radius = 14});

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(radius),
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFFFBBF24), Color(0xFFF59E0B)],
          ),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFFF59E0B).withValues(alpha: 0.3),
              blurRadius: 10,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Icon(
          Icons.folder_copy_rounded,
          color: Colors.white,
          size: size * 0.52,
        ),
      );
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
