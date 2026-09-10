import 'package:flutter/material.dart';

/// 表情分组（面板底部分类 tab）
class EmojiGroup {
  final String label;
  final IconData icon;
  final List<String> emojis;

  const EmojiGroup({
    required this.label,
    required this.icon,
    required this.emojis,
  });
}

/// 表情面板数据源。
///
/// 全部用 **Unicode emoji**：Windows（Segoe UI Emoji）和 Android（Noto Color Emoji）
/// 系统自带彩色字形，直接渲染即可——不需要打包任何图片素材，也就没有素材来源问题。
/// 分组的选取参照微信表情面板的习惯（常用 / 笑脸 / 手势 / 爱心 / 动物 / 食物 / 活动 / 符号）。
class EmojiData {
  /// 每行几个
  static const int perRow = 8;

  /// 「常用」最多记多少个
  static const int maxRecent = 16;

  static const List<EmojiGroup> groups = [
    EmojiGroup(
      label: '笑脸',
      icon: Icons.sentiment_satisfied_alt_rounded,
      emojis: [
        '😀', '😃', '😄', '😁', '😆', '😅', '😂', '🤣',
        '😊', '😇', '🙂', '🙃', '😉', '😌', '😍', '🥰',
        '😘', '😗', '😋', '😛', '😝', '😜', '🤪', '🤨',
        '🧐', '🤓', '😎', '🥳', '😏', '😒', '😞', '😔',
        '😟', '😕', '🙁', '😣', '😖', '😫', '😩', '🥺',
        '😢', '😭', '😤', '😠', '😡', '🤬', '🤯', '😳',
        '🥵', '🥶', '😱', '😨', '😰', '😥', '😓', '🤗',
        '🤔', '🤭', '🤫', '😶', '😐', '😑', '😬', '🙄',
        '😯', '😲', '🥱', '😴', '🤤', '😪', '😵', '🤐',
        '🥴', '🤢', '🤮', '🤧', '😷', '🤒', '🤕', '😈',
        '👿', '👻', '💀', '👽', '🤖', '💩', '😺', '😸',
      ],
    ),
    EmojiGroup(
      label: '手势',
      icon: Icons.pan_tool_alt_rounded,
      emojis: [
        '👍', '👎', '👌', '✌️', '🤞', '🤟', '🤘', '🤙',
        '👈', '👉', '👆', '👇', '☝️', '✋', '🤚', '🖐️',
        '🖖', '👋', '🤝', '🙏', '💪', '✊', '👊', '🤛',
        '🤜', '👏', '🙌', '👐', '🤲', '💅', '🫰', '🫶',
        '🫡', '👀', '👁️', '👂', '👃', '👄', '👅', '🧠',
      ],
    ),
    EmojiGroup(
      label: '爱心',
      icon: Icons.favorite_rounded,
      emojis: [
        '❤️', '🧡', '💛', '💚', '💙', '💜', '🖤', '🤍',
        '🤎', '💔', '❣️', '💕', '💞', '💓', '💗', '💖',
        '💘', '💝', '💟', '♥️', '💌', '💋', '💐', '🌹',
      ],
    ),
    EmojiGroup(
      label: '动物',
      icon: Icons.pets_rounded,
      emojis: [
        '🐶', '🐱', '🐭', '🐹', '🐰', '🦊', '🐻', '🐼',
        '🐨', '🐯', '🦁', '🐮', '🐷', '🐸', '🐵', '🐔',
        '🐧', '🐦', '🐤', '🦆', '🦅', '🦉', '🐺', '🐗',
        '🐴', '🦄', '🐝', '🐛', '🦋', '🐌', '🐞', '🐢',
        '🐍', '🦖', '🐙', '🦑', '🦐', '🦀', '🐠', '🐟',
        '🐬', '🐳', '🌸', '🌻', '🌷', '🌱', '🌲', '🍀',
      ],
    ),
    EmojiGroup(
      label: '食物',
      icon: Icons.restaurant_rounded,
      emojis: [
        '🍎', '🍊', '🍋', '🍌', '🍉', '🍇', '🍓', '🍒',
        '🍑', '🥭', '🍍', '🥥', '🥝', '🍅', '🥑', '🥦',
        '🥕', '🌽', '🌶️', '🥒', '🥬', '🍄', '🥜', '🍞',
        '🥐', '🥖', '🧀', '🥚', '🍳', '🥞', '🍔', '🍟',
        '🍕', '🌭', '🥪', '🌮', '🍜', '🍲', '🍛', '🍣',
        '🍱', '🥟', '🍤', '🍦', '🍰', '🎂', '🍫', '🍬',
        '🍭', '🍯', '🍺', '🍻', '🥂', '🍷', '🥤', '☕',
      ],
    ),
    EmojiGroup(
      label: '活动',
      icon: Icons.sports_soccer_rounded,
      emojis: [
        '⚽', '🏀', '🏈', '⚾', '🎾', '🏐', '🏉', '🎱',
        '🏓', '🏸', '🏆', '🥇', '🥈', '🥉', '🎯', '🎮',
        '🕹️', '🎲', '🧩', '🎨', '🎬', '🎤', '🎧', '🎼',
        '🎹', '🥁', '🎸', '🎺', '🎻', '🚗', '🚕', '🚌',
        '🏎️', '🚓', '🚑', '🚒', '🚲', '🏍️', '✈️', '🚀',
        '🛸', '🚁', '⛵', '🏠', '🏢', '🏥', '🏦', '🏭',
        '⛰️', '🌋', '🏕️', '🏖️', '🌈', '☀️', '🌙', '⭐',
        '🌟', '✨', '⚡', '🔥', '💧', '🌊', '🎉', '🎊',
      ],
    ),
    EmojiGroup(
      label: '符号',
      icon: Icons.tag_rounded,
      emojis: [
        '✅', '❌', '⭕', '❗', '❓', '💯', '🔔', '🔕',
        '📌', '📍', '🎈', '🎁', '🏅', '💡', '🔍', '📱',
        '💻', '⌨️', '🖥️', '📷', '🎥', '📞', '📧', '✉️',
        '📦', '📝', '📄', '📊', '📈', '📉', '🗓️', '⏰',
        '⏳', '🔒', '🔓', '🔑', '💰', '💳', '💎', '🎵',
        '🎶', '♻️', '⚠️', '🚫', '✔️', '➕', '➖', '✖️',
        '💤', '💬', '👑', '🆗', '🆒', '🔞', '©️', '®️',
      ],
    ),
  ];

  /// 面板里所有 emoji 的扁平集合（用于判断"整条消息是不是纯表情"）
  static final Set<String> _all = {
    for (final g in groups) ...g.emojis,
  };

  static bool isEmoji(String s) => _all.contains(s);

  /// 纯表情消息：去掉空白后，整条由 1~3 个 emoji 组成。
  /// 用于把「😄😄😄」渲染成大号表情而不是普通文字。
  ///
  /// 必须按**字素**（characters）遍历：emoji 常由多个码位组成
  /// （如 ❤️ = U+2764 + 变体选择符），按 code unit 切会切出半个字符。
  static bool isEmojiOnly(String text) {
    final t = text.replaceAll(RegExp(r'\s'), '');
    if (t.isEmpty) return false;
    var count = 0;
    for (final g in t.characters) {
      if (_all.contains(g)) {
        count++;
      } else {
        // 不在面板里、但落在 emoji 码段的单码位字符（如 🦩）也算
        final r = g.runes;
        if (r.length == 1 && r.first >= 0x1F300 && r.first <= 0x1FAFF) {
          count++;
        } else {
          return false; // 出现任何非表情字符（含中文、标点）就不是纯表情
        }
      }
      if (count > 3) return false; // 太长就按普通文字排，避免气泡被撑爆
    }
    return count > 0;
  }
}
