import 'package:flutter/material.dart';
import 'package:xiaozhi_im_client/api.dart';
import 'package:xiaozhi_im_client/core/theme.dart';

/// 群投票卡片：按 pollId 现拉详情与计票（消息 content 里只有 id，
/// 计票以服务端为准 —— 卡片上放一份数据就成了"两处真相"，改票后对不上）。
///
/// 交互口径（QQ 群投票）：
/// · 单选：点一个选项即投票；再点别的选项 = 改票（服务端清旧票）
/// · 多选：勾若干项，点底部「提交」才生效；取消勾选已投的项再提交 = 改票
/// · 匿名投票只显示票数不显示人；非匿名点开能看到每项投了谁
/// · 结束后（closed）只读展示结果，不能再投
class PollBubble extends StatefulWidget {
  final int groupId;
  final int pollId;
  final bool canManage; // 群主/管理员可以替人结束投票
  final VoidCallback? onChanged; // 投票/改票后让外层刷新（列表预览等）

  const PollBubble({
    super.key,
    required this.groupId,
    required this.pollId,
    this.canManage = false,
    this.onChanged,
  });

  @override
  State<PollBubble> createState() => _PollBubbleState();
}

class _PollBubbleState extends State<PollBubble> {
  Map<String, dynamic>? _poll;
  String? _error;
  /// 多选模式下本地勾选态（点提交才发给服务端）
  Set<int> _draftPicks = {};
  bool _voting = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d = await ImApi().pollDetail(widget.groupId, widget.pollId);
      if (!mounted) return;
      final p = (d['poll'] ?? const {}) as Map<String, dynamic>;
      setState(() {
        _poll = p;
        _draftPicks = ((p['myVotes'] as List?) ?? const [])
            .map((e) => e as int)
            .toSet();
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    }
  }

  void _toast(String s) => ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(s), duration: const Duration(seconds: 2)));

  Future<void> _vote(List<int> picks) async {
    if (_voting) return;
    setState(() => _voting = true);
    try {
      final d = await ImApi().votePoll(widget.groupId, widget.pollId, picks);
      if (!mounted) return;
      final p = (d['poll'] ?? const {}) as Map<String, dynamic>;
      setState(() {
        _poll = p;
        _draftPicks = ((p['myVotes'] as List?) ?? const [])
            .map((e) => e as int)
            .toSet();
      });
      widget.onChanged?.call();
    } catch (e) {
      _toast(e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _voting = false);
    }
  }

  Future<void> _close() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('结束投票'),
        content: const Text('结束后不能再投票，结果保留可查看。确定结束吗？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('结束')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ImApi().closePoll(widget.groupId, widget.pollId);
      await _load();
      widget.onChanged?.call();
    } catch (e) {
      _toast(e.toString().replaceFirst('Exception: ', ''));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Container(
        padding: const EdgeInsets.all(12),
        constraints: const BoxConstraints(maxWidth: 260),
        decoration: BoxDecoration(
          color: AppColors.bgElevated,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text('[投票] 加载失败：$_error',
            style: TextStyle(fontSize: 13, color: AppColors.textWeak)),
      );
    }
    final p = _poll;
    if (p == null) {
      return Container(
        padding: const EdgeInsets.all(14),
        constraints: const BoxConstraints(maxWidth: 260),
        decoration: BoxDecoration(
          color: AppColors.bgElevated,
          borderRadius: BorderRadius.circular(12),
        ),
        child: const SizedBox(
            width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }

    final title = (p['title'] ?? '') as String;
    final options = ((p['options'] as List?) ?? const []).cast<String>();
    final counts = ((p['counts'] as List?) ?? const []).map((e) => (e as num).toInt()).toList();
    final myVotes = ((p['myVotes'] as List?) ?? const []).map((e) => e as int).toSet();
    final multi = p['multi'] == true;
    final anonymous = p['anonymous'] == true;
    final closed = p['closed'] == true;
    final total = (p['total'] ?? 0) as num;
    final voters = p['voters'] is List
        ? (p['voters'] as List)
            .map((l) => ((l as List?) ?? const []).map((e) => (e as num).toInt()).toList())
            .toList()
        : null;
    final canClose = widget.canManage || p['mine'] == true;
    // 点击一个选项的行为：closed 不给点；单选点了立即投票；多选只改草稿
    void onTapOption(int i) {
      if (closed || _voting) return;
      if (!multi) {
        _vote([i]);
      } else {
        setState(() {
          if (_draftPicks.contains(i)) {
            _draftPicks.remove(i);
          } else {
            _draftPicks.add(i);
          }
        });
      }
    }

    return Container(
      width: 280,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
      decoration: BoxDecoration(
        color: AppColors.bgElevated,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.divider, width: 0.8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.how_to_vote_outlined, size: 16, color: AppColors.brand),
              const SizedBox(width: 6),
              Expanded(
                child: Text(title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 14.5, fontWeight: FontWeight.w600)),
              ),
              if (multi)
                 Text('多选',
                    style: TextStyle(fontSize: 10.5, color: AppColors.textWeak)),
            ],
          ),
          const SizedBox(height: 8),
          for (var i = 0; i < options.length; i++) _optionRow(i, options[i],
              counts.length > i ? counts[i] : 0, myVotes.contains(i),
              total == 0 ? null : (counts.length > i ? counts[i] / total.toDouble() : 0.0),
              anonymous, (voters != null && voters.length > i) ? voters[i] : null,
              () => onTapOption(i)),
          const SizedBox(height: 6),
          Row(
            children: [
              Text('$total 人参与',
                  style: TextStyle(fontSize: 11.5, color: AppColors.textWeak)),
              const Spacer(),
              if (closed)
                 Text('已结束',
                    style: TextStyle(fontSize: 11.5, color: AppColors.textWeak))
              else ...[
                if (multi && _draftPicks.isNotEmpty)
                  TextButton(
                    style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        minimumSize: const Size(0, 30)),
                    onPressed: _voting
                        ? null
                        : () => _vote(_draftPicks.toList()),
                    child: Text(_voting ? '提交中…' : '提交(${_draftPicks.length})',
                        style: const TextStyle(fontSize: 12.5)),
                  ),
                if (canClose)
                  TextButton(
                    style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        minimumSize: const Size(0, 30)),
                    onPressed: _close,
                    child:  Text('结束投票',
                        style: TextStyle(fontSize: 12.5, color: AppColors.textWeak)),
                  ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  /// 单个选项行：条形计票 + 勾选态。匿名不显示头像堆叠，非匿名显示投票人 id 数。
  Widget _optionRow(int i, String label, int count, bool mine, double? pct,
      bool anonymous, List<int>? voters, VoidCallback? onTap) {
    final pctText = (pct != null && count > 0) ? '${(pct * 100).round()}%' : '';
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(
            color: mine
                ? AppColors.brand.withValues(alpha: 0.12)
                : AppColors.bg.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: mine ? AppColors.brand.withValues(alpha: 0.6) : AppColors.divider,
              width: 0.8,
            ),
          ),
          child: Row(
            children: [
              // 勾选指示：单选圆点 / 多选方框，都用"我投过"的绿色实心态
              Icon(
                mine
                    ? (voters != null && !anonymous
                        ? Icons.check_box_rounded
                        : Icons.check_circle_rounded)
                    : (voters != null && !anonymous
                        ? Icons.check_box_outline_blank_rounded
                        : Icons.radio_button_unchecked_rounded),
                size: 16,
                color: mine ? AppColors.brand : AppColors.textWeak,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 13,
                        color: mine ? AppColors.brand : AppColors.text)),
              ),
              if (!anonymous && voters != null && voters.isNotEmpty) ...[
                const SizedBox(width: 4),
                // 头像堆叠最多 3 个 + 人数
                Text('${voters.length} 人',
                    style: TextStyle(fontSize: 11, color: AppColors.textWeak)),
              ],
              const SizedBox(width: 6),
              SizedBox(
                width: 34,
                child: Text('$count$pctText',
                    textAlign: TextAlign.right,
                    style: TextStyle(fontSize: 11.5, color: AppColors.textSub)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
