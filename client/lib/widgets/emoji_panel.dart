import 'package:flutter/material.dart';
import 'package:xiaozhi_im_client/core/emoji.dart';
import 'package:xiaozhi_im_client/core/storage.dart';
import 'package:xiaozhi_im_client/core/theme.dart';

/// 表情面板（仿微信键盘的形态）
///
/// 结构：上方 8 列表情网格，下方一行分类 tab + 退格键。
/// 第 0 个 tab 是「常用」（最近点过的，存在本地）。
/// 点表情 → onPick；点退格 → onBackspace（删输入框最后一个字符）。
class EmojiPanel extends StatefulWidget {
  final void Function(String emoji) onPick;
  final VoidCallback onBackspace;

  /// 面板高度（外层用来做展开动画）
  static const double height = 262;

  const EmojiPanel({
    super.key,
    required this.onPick,
    required this.onBackspace,
  });

  @override
  State<EmojiPanel> createState() => EmojiPanelState();
}

class EmojiPanelState extends State<EmojiPanel> {
  /// 首次使用时的「常用」兜底：一上来就是空白面板会让人以为坏了
  static const _seed = [
    '👍', '😄', '❤️', '😂', '😊', '🎉', '🙏', '👌',
    '🤝', '💪', '🥰', '😭', '🤣', '😅', '✨', '🔥',
  ];

  int _tab = 0; // 0 = 常用，1..n = EmojiData.groups[i-1]
  List<String> _recent = const [];

  @override
  void initState() {
    super.initState();
    _loadRecent();
  }

  Future<void> _loadRecent() async {
    final r = await Storage.getRecentEmoji();
    if (!mounted) return;
    setState(() => _recent = r);
  }

  /// 供外部（chat 页插入表情后）刷新「常用」
  Future<void> refreshRecent() => _loadRecent();

  /// 「常用」= 最近用过的在前，不够长时用预置表情补齐（去重）
  List<String> get _recentFilled {
    final out = <String>[..._recent];
    for (final s in _seed) {
      if (out.length >= EmojiData.maxRecent) break;
      if (!out.contains(s)) out.add(s);
    }
    return out;
  }

  List<String> get _current =>
      _tab == 0 ? _recentFilled : EmojiData.groups[_tab - 1].emojis;

  void _pick(String e) {
    widget.onPick(e);
    // 本地先乐观更新，避免每次点都等异步返回
    setState(() {
      _recent = [e, ..._recent.where((x) => x != e)];
      if (_recent.length > EmojiData.maxRecent) {
        _recent = _recent.sublist(0, EmojiData.maxRecent);
      }
    });
    Storage.addRecentEmoji(e, max: EmojiData.maxRecent);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: EmojiPanel.height,
      decoration: const BoxDecoration(
        color: AppColors.bgElevated,
        border: Border(top: BorderSide(color: AppColors.divider)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          children: [
            Expanded(child: _grid()),
            _tabs(),
          ],
        ),
      ),
    );
  }

  Widget _grid() {
    final list = _current;
    if (list.isEmpty) {
      return const Center(
        child: Text('还没有用过的表情',
            style: TextStyle(fontSize: 12.5, color: AppColors.textWeak)),
      );
    }
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(6, 10, 6, 4),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: EmojiData.perRow,
        mainAxisSpacing: 2,
        crossAxisSpacing: 2,
      ),
      itemCount: list.length,
      itemBuilder: (c, i) {
        final e = list[i];
        return InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => _pick(e),
          child: Center(
            child: Text(e, style: const TextStyle(fontSize: 23, height: 1.2)),
          ),
        );
      },
    );
  }

  Widget _tabs() {
    return Container(
      height: 42,
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: AppColors.divider)),
      ),
      child: Row(
        children: [
          Expanded(
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 4),
              children: [
                _tabBtn(
                  0,
                  Icons.access_time_rounded,
                  '常用',
                ),
                for (var i = 0; i < EmojiData.groups.length; i++)
                  _tabBtn(i + 1, EmojiData.groups[i].icon,
                      EmojiData.groups[i].label),
              ],
            ),
          ),
          // 退格：删掉输入框里最后一个字符（emoji 也是多个码位，按"字素"删）
          InkWell(
            onTap: widget.onBackspace,
            borderRadius: BorderRadius.circular(8),
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Icon(Icons.backspace_outlined,
                  size: 20, color: AppColors.textSub),
            ),
          ),
          const SizedBox(width: 4),
        ],
      ),
    );
  }

  Widget _tabBtn(int index, IconData icon, String label) {
    final on = _tab == index;
    return Tooltip(
      message: label,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => setState(() => _tab = index),
        child: Container(
          width: 44,
          margin: const EdgeInsets.symmetric(horizontal: 1, vertical: 5),
          decoration: BoxDecoration(
            color: on ? AppColors.surfaceHi : null,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(
            icon,
            size: 20,
            color: on ? AppColors.brand : AppColors.textWeak,
          ),
        ),
      ),
    );
  }
}
