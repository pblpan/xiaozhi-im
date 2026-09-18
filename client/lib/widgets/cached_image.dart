import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

/// 全 App 图片加载的**唯一出口**。
///
/// 把三个裸 Image.network 调用点共用的缓存能力收在这里，业务 widget 不要各自
/// 配 cache 参数，也不要再直接 new Image.network：
///   - 底层是 CachedNetworkImage，默认就带磁盘缓存（flutter_cache_manager）。
///     这正是为了修掉"聊天图片每次重开 App 都要重新下载"这个老毛病——缓存落在
///     App 私有目录，跨进程重启还在（除非系统清缓存），外网极慢场景下体验立竿见影。
///   - 视觉对齐原先的 Image.network：关闭淡入淡出动画（用户要求不引入新动画），
///     尺寸/裁剪/加载态/出错兜底由调用方按需传，本类不私自加占位 UI。
///
/// 参数名跟 Image.network 不一样，注意别照抄：
///   imageUrl / progressIndicatorBuilder(progress) / errorWidget。
class XzCachedImage extends StatelessWidget {
  final String url;
  final double? width;
  final double? height;
  final BoxFit fit;

  /// 加载中占位（带进度）。不传则加载期间什么都不画（等效于原 Image.network 无
  /// loadingBuilder 的默认行为——空白到加载完）。调用方传它来保持原加载态。
  final Widget Function(BuildContext, String, DownloadProgress)?
      progressIndicatorBuilder;

  /// 加载失败兜底。不传则失败显示默认破图。
  final Widget Function(BuildContext, String, Object)? errorWidget;

  const XzCachedImage({
    super.key,
    required this.url,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.progressIndicatorBuilder,
    this.errorWidget,
  });

  @override
  Widget build(BuildContext context) => CachedNetworkImage(
        imageUrl: url,
        width: width,
        height: height,
        fit: fit,
        // 视觉保持原样：不要 CachedNetworkImage 自带的淡入淡出。
        fadeOutDuration: Duration.zero,
        fadeInDuration: Duration.zero,
        progressIndicatorBuilder: progressIndicatorBuilder,
        errorWidget: errorWidget == null
            ? null
            : (c, u, e) => errorWidget!(c, u, e),
      );
}
