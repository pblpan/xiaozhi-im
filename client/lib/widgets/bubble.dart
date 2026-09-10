import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xiaozhi_im_client/core/theme.dart';
import 'package:xiaozhi_im_client/core/time.dart';
import 'package:xiaozhi_im_client/core/voice.dart';
import 'package:xiaozhi_im_client/models.dart';
import 'package:xiaozhi_im_client/widgets/avatar.dart';

class MessageBubble extends StatelessWidget {
  final Message msg;
  final bool mine;
  final String? senderName;
  final String baseUrl;
  final bool showTime;

  /// 长按气泡（由聊天页弹「复制 / 编辑 / 撤回」菜单）
  final VoidCallback? onLongPress;

  /// 已读回执标签：'已读' / '未读' / null（不显示）
  final String? readLabel;

  const MessageBubble({
    super.key,
    required this.msg,
    required this.mine,
    this.senderName,
    this.baseUrl = '',
    this.showTime = false,
    this.onLongPress,
    this.readLabel,
  });

  String get _displayName {
    final raw = msg.fileName ?? msg.content ?? '文件';
    final i = raw.lastIndexOf('/');
    return i < 0 ? raw : raw.substring(i + 1);
  }

  void _copy(BuildContext context) {
    final text = msg.content;
    if (text == null || text.isEmpty) return;
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已复制'), duration: Duration(seconds: 1)),
    );
  }

  /// 撤回提示：不显示气泡，只在中间显示一行灰字
  Widget _recalled() => Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 4),
            decoration: BoxDecoration(
              color: AppColors.surfaceHi.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(AppRadii.pill),
            ),
            child: Text(
              mine ? '你撤回了一条消息' : '${senderName ?? '对方'} 撤回了一条消息',
              style: const TextStyle(
                  fontSize: 11.5,
                  color: AppColors.textWeak,
                  fontStyle: FontStyle.italic),
            ),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    if (msg.deleted) return _recalled();

    final name = senderName ?? '对方';
    final imgPath = msg.imagePath;

    final Widget body;
    if (imgPath != null) {
      body = _image(context, '$baseUrl$imgPath');
    } else if (msg.kind == 'audio') {
      body = _voiceBubble(context);
    } else if (msg.kind == 'file') {
      body = _fileCard(context);
    } else {
      body = _textBubble(context);
    }

    final hasMeta = showTime || msg.edited || readLabel != null;

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Column(
        children: [
          Row(
            mainAxisAlignment:
                mine ? MainAxisAlignment.end : MainAxisAlignment.start,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (!mine) ...[
                UserAvatar(name: name, size: 34, radius: 12),
                const SizedBox(width: 8),
              ],
              Flexible(
                child: Column(
                  crossAxisAlignment: mine
                      ? CrossAxisAlignment.end
                      : CrossAxisAlignment.start,
                  children: [
                    if (!mine && senderName != null)
                      Padding(
                        padding: const EdgeInsets.only(left: 2, bottom: 4),
                        child: Text(senderName!,
                            style: const TextStyle(
                                fontSize: 11.5, color: AppColors.textWeak)),
                      ),
                    body,
                  ],
                ),
              ),
              if (mine) ...[
                const SizedBox(width: 8),
                const UserAvatar(name: '我', size: 34, radius: 12),
              ],
            ],
          ),
          if (hasMeta)
            Padding(
              padding: EdgeInsets.only(
                  top: 5, left: mine ? 0 : 42, right: mine ? 42 : 0),
              child: Row(
                mainAxisAlignment:
                    mine ? MainAxisAlignment.end : MainAxisAlignment.start,
                children: [
                  if (msg.edited) ...[
                    const Text('已编辑',
                        style: TextStyle(
                            fontSize: 11, color: AppColors.textWeak)),
                    const SizedBox(width: 6),
                  ],
                  if (readLabel != null) ...[
                    Text(
                      readLabel!,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: readLabel == '已读'
                            ? FontWeight.w600
                            : FontWeight.w400,
                        color: readLabel == '已读'
                            ? AppColors.brand
                            : AppColors.textWeak,
                      ),
                    ),
                    const SizedBox(width: 6),
                  ],
                  if (showTime)
                    Text(TimeFmt.hhmm(msg.createdAt),
                        style: const TextStyle(
                            fontSize: 11, color: AppColors.textWeak)),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _textBubble(BuildContext context) {
    final text = msg.content ?? '';
    return GestureDetector(
      onLongPress: onLongPress ?? () => _copy(context),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: BoxDecoration(
          gradient: mine ? AppTheme.brandGradient : null,
          color: mine ? null : AppColors.bubbleOther,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft: Radius.circular(mine ? 16 : 5),
            bottomRight: Radius.circular(mine ? 5 : 16),
          ),
        ),
        child: Text(
          text,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 15,
            height: 1.4,
          ),
        ),
      ),
    );
  }

  Widget _image(BuildContext context, String url) => GestureDetector(
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => FullScreenImage(url: url)),
        ),
        onLongPress: onLongPress ?? () => _copy(context),
        child: Hero(
          tag: url,
          child: ClipRRect(
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(16),
              topRight: Radius.circular(16),
              bottomLeft: Radius.circular(16),
              bottomRight: Radius.circular(16),
            ),
            child: Container(
              color: AppColors.surfaceHi,
              child: Image.network(
                url,
                width: 210,
                fit: BoxFit.cover,
                loadingBuilder: (c, child, progress) {
                  if (progress == null) return child;
                  return const SizedBox(
                    width: 210,
                    height: 150,
                    child: Center(
                        child: SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2))),
                  );
                },
                errorBuilder: (_, __, ___) => const SizedBox(
                  width: 210,
                  height: 130,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.broken_image_outlined,
                          color: AppColors.textWeak, size: 30),
                      SizedBox(height: 6),
                      Text('图片加载失败',
                          style: TextStyle(
                              color: AppColors.textWeak, fontSize: 12)),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );

  /// 语音气泡：时长决定宽度，播放时波形跳动
  Widget _voiceBubble(BuildContext context) {
    final secs = msg.audioSeconds ?? 1;
    final path = msg.audioPath;
    final key = Voice.keyOf(msg.conversationId, msg.id);
    final width =
        76.0 + (secs.clamp(1, Voice.maxSeconds) / Voice.maxSeconds) * 102.0;

    return GestureDetector(
      onTap: () {
        if (path == null || baseUrl.isEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('语音文件缺失'),
            duration: Duration(seconds: 1),
          ));
          return;
        }
        Voice.toggle(key, '$baseUrl$path');
      },
      onLongPress: onLongPress ?? () => _copy(context),
      child: StreamBuilder<String?>(
        stream: Voice.playingStream,
        initialData: Voice.playingKey,
        builder: (c, snap) {
          final playing = snap.data == key;
          return Container(
            width: width,
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 10),
            decoration: BoxDecoration(
              gradient: mine ? AppTheme.brandGradient : null,
              color: mine ? null : AppColors.bubbleOther,
              border: mine ? null : Border.all(color: AppColors.border),
              borderRadius: BorderRadius.only(
                topLeft: const Radius.circular(16),
                topRight: const Radius.circular(16),
                bottomLeft: Radius.circular(mine ? 16 : 5),
                bottomRight: Radius.circular(mine ? 5 : 16),
              ),
            ),
            child: Row(
              children: [
                Icon(
                  playing
                      ? Icons.pause_circle_filled_rounded
                      : Icons.play_circle_fill_rounded,
                  size: 24,
                  color: mine ? Colors.white : AppColors.brand,
                ),
                const SizedBox(width: 7),
                Expanded(child: _VoiceWave(playing: playing, mine: mine)),
                const SizedBox(width: 6),
                Text(
                  "$secs''",
                  style: TextStyle(
                    fontSize: 11.5,
                    color: mine ? Colors.white70 : AppColors.textWeak,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _fileCard(BuildContext context) {
    final size = msg.fileSize == null ? '' : TimeFmt.size(msg.fileSize!);
    return GestureDetector(
      onLongPress: onLongPress ?? () => _copy(context),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: AppColors.bubbleOther,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: AppColors.brand.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.insert_drive_file_rounded,
                  color: AppColors.brand, size: 20),
            ),
            const SizedBox(width: 10),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _displayName,
                    style: const TextStyle(fontSize: 14, color: AppColors.text),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 2,
                  ),
                  if (size.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(size,
                        style: const TextStyle(
                            fontSize: 11.5, color: AppColors.textWeak)),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 语音波形：静置时是一条起伏的声波，播放时逐条跳动
class _VoiceWave extends StatefulWidget {
  final bool playing;
  final bool mine;
  const _VoiceWave({required this.playing, required this.mine});

  @override
  State<_VoiceWave> createState() => _VoiceWaveState();
}

class _VoiceWaveState extends State<_VoiceWave>
    with SingleTickerProviderStateMixin {
  static const _bars = 12;

  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 850),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.mine ? Colors.white : AppColors.brand;
    return AnimatedBuilder(
      animation: _c,
      builder: (c, _) => Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: List.generate(_bars, (i) {
          // 固定伪随机起伏 —— 同一条消息每次渲染波形一致
          final base = 0.32 + 0.68 * (((i * 37) % 11) / 10.0);
          double h = base;
          if (widget.playing) {
            final phase = _c.value * 2 * math.pi + i * 0.75;
            h = base * 0.45 + 0.55 * (0.5 + 0.5 * math.sin(phase));
          }
          return Container(
            width: 2.6,
            height: 4 + h * 13,
            decoration: BoxDecoration(
              color: color.withValues(alpha: widget.playing ? 0.95 : 0.7),
              borderRadius: BorderRadius.circular(2),
            ),
          );
        }),
      ),
    );
  }
}

/// 聊天记录里的日期分隔（今天 / 昨天 / 9月9日）
class DayDivider extends StatelessWidget {
  final int ts;
  const DayDivider({super.key, required this.ts});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            decoration: BoxDecoration(
              color: AppColors.surfaceHi.withValues(alpha: 0.7),
              borderRadius: BorderRadius.circular(AppRadii.pill),
            ),
            child: Text(
              TimeFmt.dayLabel(ts),
              style: const TextStyle(
                  fontSize: 11.5, color: AppColors.textWeak),
            ),
          ),
        ),
      );
}

/// 全屏看图（双指缩放）
class FullScreenImage extends StatelessWidget {
  final String url;
  const FullScreenImage({super.key, required this.url});

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          surfaceTintColor: Colors.transparent,
          iconTheme: const IconThemeData(color: Colors.white),
        ),
        body: Center(
          child: Hero(
            tag: url,
            child: InteractiveViewer(
              maxScale: 6,
              child: Image.network(
                url,
                fit: BoxFit.contain,
                errorBuilder: (_, __, ___) => const Center(
                  child: Text('图片加载失败',
                      style: TextStyle(color: Colors.white70)),
                ),
              ),
            ),
          ),
        ),
      );
}
