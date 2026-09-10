import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:xiaozhi_im_client/core/emoji.dart';
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

  /// 这条消息 @了我（且不是我自己发的）→ 气泡加高亮描边
  final bool mentionHighlight;

  /// 文件消息：点卡片 = 用系统默认程序打开
  final VoidCallback? onFileOpen;

  /// 文件消息：另存为
  final VoidCallback? onFileSaveAs;

  /// 文件消息：下载进度 0~1（非 null 表示正在下载，卡片上显示进度）
  final double? fileProgress;

  const MessageBubble({
    super.key,
    required this.msg,
    required this.mine,
    this.senderName,
    this.baseUrl = '',
    this.showTime = false,
    this.onLongPress,
    this.readLabel,
    this.mentionHighlight = false,
    this.onFileOpen,
    this.onFileSaveAs,
    this.fileProgress,
  });

  String get _displayName => msg.displayFileName;

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
    } else if (msg.kind == 'card') {
      body = _cardBubble(context);
    } else if (msg.kind == 'call') {
      body = _callBubble(context);
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
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(senderName!,
                                style: const TextStyle(
                                    fontSize: 11.5, color: AppColors.textWeak)),
                            // 机器人标签：让群成员一眼看出这条是系统推的，不是真人说的
                            if (msg.senderIsBot) ...[
                              const SizedBox(width: 5),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 5, vertical: 1),
                                decoration: BoxDecoration(
                                  color: AppColors.brand.withValues(alpha: 0.16),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: const Text('机器人',
                                    style: TextStyle(
                                        fontSize: 9.5,
                                        height: 1.3,
                                        fontWeight: FontWeight.w700,
                                        color: AppColors.brand)),
                              ),
                            ],
                          ],
                        ),
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

  /// 卡片消息：外部系统（工厂 V2 / OA / 脚本）推的日报、预警
  ///
  /// 布局刻意做成"系统通知"的观感而不是聊天气泡——顶部一条语义色条区分紧急度，
  /// 字段区支持两列并排，底部可挂一个跳转按钮。宽度固定，长文本自动换行。
  Widget _cardBubble(BuildContext context) {
    final card = msg.card;
    // 脏数据（老库/异常 JSON）降级成纯文本，绝不让用户看到一坨 JSON
    if (card == null || card.isEmpty) return _textBubble(context);

    final accent = _cardColor(card.color);

    return GestureDetector(
      onLongPress: onLongPress ?? () => _copy(context),
      child: Container(
        width: 272,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: AppColors.surfaceHi,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 语义色条：红=预警、橙=提醒、绿=正常、蓝=信息
            Container(height: 4, color: accent),
            Padding(
              padding: const EdgeInsets.fromLTRB(13, 11, 13, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (card.title.isNotEmpty)
                    Text(
                      card.title,
                      style: const TextStyle(
                        fontSize: 14.5,
                        height: 1.3,
                        fontWeight: FontWeight.w700,
                        color: AppColors.text,
                      ),
                    ),
                  if (card.text.isNotEmpty) ...[
                    if (card.title.isNotEmpty) const SizedBox(height: 6),
                    Text(
                      card.text,
                      style: const TextStyle(
                        fontSize: 13.5,
                        height: 1.45,
                        color: AppColors.textSub,
                      ),
                    ),
                  ],
                  if (card.fields.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Container(height: 1, color: AppColors.divider),
                    const SizedBox(height: 9),
                    ..._cardFields(card),
                  ],
                  if (card.footer.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Text(
                      card.footer,
                      style: const TextStyle(
                          fontSize: 11, height: 1.3, color: AppColors.textWeak),
                    ),
                  ],
                  if (card.url.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    _cardLink(context, card.url, accent),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 字段排布：连续的 short 字段两两并排，其余各占一行
  List<Widget> _cardFields(CardData card) {
    final rows = <Widget>[];
    var i = 0;
    while (i < card.fields.length) {
      final f = card.fields[i];
      final next = i + 1 < card.fields.length ? card.fields[i + 1] : null;
      if (f.short && next != null && next.short) {
        rows.add(Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: _cardField(f)),
            const SizedBox(width: 12),
            Expanded(child: _cardField(next)),
          ],
        ));
        i += 2;
      } else {
        rows.add(_cardField(f));
        i += 1;
      }
    }
    return [
      for (var k = 0; k < rows.length; k++) ...[
        if (k > 0) const SizedBox(height: 8),
        rows[k],
      ],
    ];
  }

  Widget _cardField(CardField f) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (f.label.isNotEmpty)
            Text(f.label,
                style: const TextStyle(
                    fontSize: 11, height: 1.25, color: AppColors.textWeak)),
          if (f.value.isNotEmpty)
            Padding(
              padding: EdgeInsets.only(top: f.label.isEmpty ? 0 : 2),
              child: Text(
                f.value,
                style: const TextStyle(
                  fontSize: 13,
                  height: 1.35,
                  fontWeight: FontWeight.w600,
                  color: AppColors.text,
                ),
              ),
            ),
        ],
      );

  Widget _cardLink(BuildContext context, String url, Color accent) => InkWell(
        onTap: () => _openUrl(context, url),
        borderRadius: BorderRadius.circular(9),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: accent.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(9),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.open_in_new_rounded, size: 14, color: accent),
              const SizedBox(width: 5),
              Text('查看详情',
                  style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: accent)),
            ],
          ),
        ),
      );

  Future<void> _openUrl(BuildContext context, String url) async {
    final messenger = ScaffoldMessenger.of(context);
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    try {
      final done = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!done) throw Exception('no handler');
    } catch (_) {
      // 打不开（没装浏览器/被系统拦）就退化成复制链接，至少不丢信息
      await Clipboard.setData(ClipboardData(text: url));
      messenger.showSnackBar(const SnackBar(
        content: Text('链接已复制到剪贴板'),
        duration: Duration(seconds: 2),
      ));
    }
  }

  /// 语义色 → 具体色值。换肤时只改这里，对接方仍只传 'red' 这类名字。
  Color _cardColor(String name) {
    switch (name) {
      case 'green':
        return const Color(0xFF10B981);
      case 'orange':
        return const Color(0xFFF59E0B);
      case 'red':
        return const Color(0xFFEF4444);
      case 'purple':
        return const Color(0xFF8B5CF6);
      case 'gray':
        return const Color(0xFF94A3B8);
      default:
        return const Color(0xFF3B82F6);
    }
  }

  /// 通话记录气泡：一行「图标 + 文案」。
  /// 正常结束用品牌绿，未接听/被拒/中断用警示色——一眼能看出这通电话有没有接通。
  Widget _callBubble(BuildContext context) {
    final c = msg.call;
    final missed = c?.isMissed ?? false;
    final accent = missed ? AppColors.danger : AppColors.brand;
    final icon = (c?.isVideo ?? false)
        ? Icons.videocam_rounded
        : Icons.call_rounded;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: mine
            ? AppColors.brand.withValues(alpha: 0.13)
            : AppColors.bubbleOther,
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(16),
          topRight: const Radius.circular(16),
          bottomLeft: Radius.circular(mine ? 16 : 5),
          bottomRight: Radius.circular(mine ? 5 : 16),
        ),
        border: Border.all(color: accent.withValues(alpha: 0.34)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 17, color: accent),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              c?.label ?? '通话',
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w500,
                color: missed ? AppColors.textSub : AppColors.text,
              ),
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
          border: mentionHighlight
              ? Border.all(color: AppColors.brand, width: 1.4)
              : null,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft: Radius.circular(mine ? 16 : 5),
            bottomRight: Radius.circular(mine ? 5 : 16),
          ),
        ),
        child: _richText(text, mine: mine),
      ),
    );
  }

  /// 把 @提及 片段渲染成高亮色，其余按正文色。
  /// @所有人 / @all 用橙色单独强调（比普通 @ 更需要一眼看到）。
  /// 整条只有 1~3 个表情时放大显示（微信也是这个观感）。
  Widget _richText(String text, {required bool mine}) {
    final emojiOnly = EmojiData.isEmojiOnly(text);
    final base = TextStyle(
      color: Colors.white,
      fontSize: emojiOnly ? 26 : 15,
      height: emojiOnly ? 1.3 : 1.4,
    );
    if (!text.contains('@')) return Text(text, style: base);

    final mentionColor = mine ? const Color(0xFFFFE082) : AppColors.brand;
    final spans = <TextSpan>[];
    final re = RegExp(r'@[^\s@]+');
    int last = 0;
    for (final m in re.allMatches(text)) {
      if (m.start > last) {
        spans.add(TextSpan(text: text.substring(last, m.start), style: base));
      }
      final seg = m.group(0)!;
      final isAll = seg == '@所有人' || seg.toLowerCase() == '@all';
      spans.add(TextSpan(
        text: seg,
        style: base.copyWith(
          color: isAll ? const Color(0xFFFFB74D) : mentionColor,
          fontWeight: FontWeight.w700,
        ),
      ));
      last = m.end;
    }
    if (last < text.length) {
      spans.add(TextSpan(text: text.substring(last), style: base));
    }
    return RichText(text: TextSpan(children: spans));
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

  /// 文件消息卡片
  ///
  /// 交互：**点卡片 = 用系统默认程序打开**，右侧「另存为」图标 = 选目录保存。
  /// 首次打开会先下载，期间图标位换成进度环，文件名下方显示百分比。
  Widget _fileCard(BuildContext context) {
    final size = msg.fileSize == null ? '' : TimeFmt.size(msg.fileSize!);
    final p = fileProgress;
    final downloading = p != null;
    final pct = ((p ?? 0) * 100).clamp(0, 100).toStringAsFixed(0);

    return GestureDetector(
      onTap: downloading ? null : onFileOpen,
      onLongPress: onLongPress ?? () => _copy(context),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
        decoration: BoxDecoration(
          color: AppColors.bubbleOther,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 38,
              height: 38,
              child: downloading
                  ? Center(
                      child: SizedBox(
                        width: 26,
                        height: 26,
                        child: CircularProgressIndicator(
                          value: p > 0 ? p : null,
                          strokeWidth: 2.4,
                          color: AppColors.brand,
                          backgroundColor: AppColors.brand.withValues(alpha: 0.18),
                        ),
                      ),
                    )
                  : Container(
                      decoration: BoxDecoration(
                        color: AppColors.brand.withValues(alpha: 0.16),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(Icons.insert_drive_file_rounded,
                          color: AppColors.brand, size: 20),
                    ),
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
                  const SizedBox(height: 2),
                  Text(
                    downloading
                        ? '下载中 $pct%'
                        : (size.isEmpty ? '点击打开' : '$size · 点击打开'),
                    style: const TextStyle(
                        fontSize: 11.5, color: AppColors.textWeak),
                  ),
                ],
              ),
            ),
            if (onFileSaveAs != null && !downloading) ...[
              const SizedBox(width: 4),
              Tooltip(
                message: '另存为',
                child: InkWell(
                  borderRadius: BorderRadius.circular(9),
                  onTap: onFileSaveAs,
                  child: const Padding(
                    padding: EdgeInsets.all(7),
                    child: Icon(Icons.save_alt_rounded,
                        size: 19, color: AppColors.textSub),
                  ),
                ),
              ),
            ],
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
