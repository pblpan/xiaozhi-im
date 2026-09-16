import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'media.dart';

/// 一份从系统分享进来、**已经落成本地文件**的附件。
///
/// path 是真实文件路径（原生侧把 content:// 拷进缓存目录后才给的），
/// 所以上传链路可以直接当普通文件用，和 file_picker 选出来的一模一样。
class SharedFile {
  const SharedFile({
    required this.path,
    required this.name,
    this.mime = '',
    this.size = 0,
  });

  final String path;
  final String name;
  final String mime;
  final int size;

  static SharedFile? fromMap(Map m) {
    final p = (m['path'] ?? '').toString();
    if (p.isEmpty) return null;
    return SharedFile(
      path: p,
      name: (m['name'] ?? '').toString(),
      mime: (m['mime'] ?? '').toString(),
      size: (m['size'] as num?)?.toInt() ?? 0,
    );
  }

  /// 是否按图片消息发（决定聊天里显示成缩略图还是一张文件卡）。
  /// 三个来源都看一遍：服务端给的 mime、原始名、落地名 —— 有 App 分享时不给 mime。
  bool get isImage =>
      mime.startsWith('image') ||
      Media.isImagePath(name) ||
      Media.isImagePath(path);
}

/// 这次分享进来的全部内容：若干附件 + 可选的文字。
class SharedPayload {
  const SharedPayload({required this.files, this.text = ''});

  final List<SharedFile> files;
  final String text;

  /// 原生回传的原始结构 → 对象。全空（既没文件也没文字）时返回 null：
  /// 那种情况没什么可发的，弹页面只会让人困惑。
  static SharedPayload? from(dynamic raw) {
    if (raw is! Map) return null;
    final files = <SharedFile>[];
    for (final e in (raw['files'] as List? ?? const [])) {
      if (e is Map) {
        final f = SharedFile.fromMap(e);
        if (f != null) files.add(f);
      }
    }
    final text = (raw['text'] ?? '').toString().trim();
    if (files.isEmpty && text.isEmpty) return null;
    return SharedPayload(files: files, text: text);
  }

  int get totalBytes => files.fold<int>(0, (s, f) => s + f.size);

  /// 删掉落地在缓存目录的临时文件。
  ///
  /// 必须清：每分享一次就在手机上留一份副本，几张几十 MB 的原图攒两三次，
  /// "其他"占用就肉眼可见地涨上去了。发送完成、或用户放弃返回时都调一次。
  void disposeFiles() {
    for (final f in files) {
      try {
        final file = File(f.path);
        if (file.existsSync()) file.deleteSync();
      } catch (_) {
        // 删不掉就算了（缓存目录本来也会被系统回收），不能因为清理失败影响主流程
      }
    }
  }
}

/// 系统「分享到小智」的入口（仅 Android 有原生实现）。
///
/// 为什么用 ValueNotifier 而不是回调：**分享有可能比登录先到**。
/// 用户没登录时收到分享，回调派发出去没人接，这次分享就丢了；
/// 存成 pending 之后，等首页起来自己来消费，顺序就不再敏感。
class ShareIntake {
  ShareIntake._();

  /// 与 MainActivity.kt 里的 CHANNEL 必须逐字一致
  static const MethodChannel _ch = MethodChannel('xiaozhi/share');

  /// 待处理的分享（null = 没有）。首页外壳负责消费。
  static final ValueNotifier<SharedPayload?> pending = ValueNotifier(null);

  static bool _inited = false;

  static Future<void> init() async {
    // 桌面端没有也不需要有这个入口：Windows 上 Platform.isAndroid 为 false，
    // 直接跳过，避免去调一个不存在的原生通道。
    if (_inited || !Platform.isAndroid) return;
    _inited = true;

    // 热启动：App 已经在跑，用户又分享了一次 → 原生主动推过来
    _ch.setMethodCallHandler((call) async {
      if (call.method == 'onShare') _accept(call.arguments);
    });

    try {
      // 冷启动：App 是被这次分享拉起来的。原生只在"intent 确实是分享"时才回数据，
      // 正常点图标启动会回 null。
      final r = await _ch.invokeMethod('getInitialShare');
      _accept(r);
    } catch (_) {
      // 分享读不出来不该拦着 App 正常启动
    }
  }

  static void _accept(dynamic raw) {
    final p = SharedPayload.from(raw);
    if (p == null) return;
    pending.value = p;
  }

  /// 消费掉当前这份（首页弹出页面后调用），避免返回时又弹一次。
  static void consume() => pending.value = null;
}
