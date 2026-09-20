import 'package:flutter/material.dart';

import '../api.dart';

/// 考试答题页。
///
/// ── 🔴 界面上必须明说的两件事 ────────────────────────────────
/// ① **进入考试就已经消耗了一次机会**（服务端在 start 那一刻就落卷）。
///    不写这句话，学员会以为"不交就不算"，随手退出，
///    然后发现考不了了 —— 那时候已经没法补救，只能找管理员。
/// ② **交卷不能改**。所以交卷前要确认，交完直接出成绩和对答案。
///
/// ── 为什么要有答题卡 ────────────────────────────────────────
/// 题目一多，学员需要一眼看到"哪题没答"。没有答题卡的话，
/// 漏答直到出成绩才发现，而机会已经没了。
class TrainingExamPage extends StatefulWidget {
  final int sheetId;
  final String title;
  final Map<String, dynamic> started;

  const TrainingExamPage({
    super.key,
    required this.sheetId,
    required this.title,
    required this.started,
  });

  @override
  State<TrainingExamPage> createState() => _TrainingExamPageState();
}

class _TrainingExamPageState extends State<TrainingExamPage> {
  final ImApi _api = ImApi();
  late final List<Map<String, dynamic>> _questions;
  final Map<int, Set<String>> _chosen = {};
  bool _submitting = false;
  Map<String, dynamic>? _result;

  @override
  void initState() {
    super.initState();
    _questions = (widget.started['questions'] as List? ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList();
  }

  void _pick(int qid, String label, bool multi) {
    setState(() {
      final cur = _chosen[qid] ?? <String>{};
      if (multi) {
        cur.contains(label) ? cur.remove(label) : cur.add(label);
        _chosen[qid] = cur;
      } else {
        _chosen[qid] = {label};
      }
    });
  }

  int get _answered =>
      _questions.where((q) => (_chosen[q['id'] as int] ?? const {}).isNotEmpty).length;

  Future<void> _submit() async {
    final missing = _questions.length - _answered;
    if (missing > 0) {
      final go = await showDialog<bool>(
            context: context,
            builder: (_) => AlertDialog(
              title: const Text('还有题没答'),
              content: Text('还有 $missing 题没作答。交卷后不能修改，确定交吗？'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('继续答')),
                FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('确定交卷')),
              ],
            ),
          ) ??
          false;
      if (!go) return;
    }
    setState(() => _submitting = true);
    try {
      final body = await _api.submitSheet(
        widget.sheetId,
        _questions
            .map((q) => {
                  'questionId': q['id'],
                  'chosen': (_chosen[q['id'] as int] ?? const <String>{})
                      .toList()
                      .join(),
                })
            .toList(),
      );
      if (!mounted) return;
      setState(() {
        _result = body;
        _submitting = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _submitting = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('交卷失败：$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final res = _result;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          if (res == null)
            TextButton.icon(
              key: const Key('training-answer-card'),
              icon: const Icon(Icons.grid_on),
              label: const Text('答题卡'),
              onPressed: _showCard,
            ),
        ],
      ),
      body: res != null
          ? _ResultView(
              result: res,
              questions: _questions,
              chosen: _chosen,
              onBack: () => Navigator.pop(context),
            )
          : Column(
              children: [
                // 🔴 这条横幅不是装饰：机会在进来的那一刻就消耗了，
                //    不告诉学员就是坑他。
                Container(
                  width: double.infinity,
                  color: theme.colorScheme.errorContainer,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  child: Text(
                    '已进入考试，本次机会已开始计算；中途退出不会退回。',
                    style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onErrorContainer),
                  ),
                ),
                Expanded(
                  child: ListView.builder(
                    padding: const EdgeInsets.all(12),
                    itemCount: _questions.length,
                    itemBuilder: (_, i) => _QuestionCard(
                      index: i + 1,
                      q: _questions[i],
                      chosen: _chosen[_questions[i]['id'] as int] ?? const {},
                      right: _rightOf(_questions[i], res),
                      onPick: (label) => _pick(
                          _questions[i]['id'] as int,
                          label,
                          _questions[i]['type'] == 'multi'),
                    ),
                  ),
                ),
                _SubmitBar(
                  answered: _answered,
                  total: _questions.length,
                  busy: _submitting,
                  onSubmit: _submit,
                ),
              ],
            ),
    );
  }

  Set<String> _rightOf(Map<String, dynamic> q, Map<String, dynamic>? res) {
    if (res == null) return const {};
    final d = (res['detail'] as List? ?? const [])
        .whereType<Map<String, dynamic>>()
        .firstWhere((x) => x['questionId'] == q['id'],
            orElse: () => const <String, dynamic>{});
    final s = '${d['rightLabels'] ?? ''}';
    return s.split('').toSet();
  }

  void _showCard() {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('答题卡'),
        content: SizedBox(
          width: double.maxFinite,
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (var i = 0; i < _questions.length; i++)
                GestureDetector(
                  onTap: () => Navigator.pop(context),
                  child: CircleAvatar(
                    backgroundColor:
                        (_chosen[_questions[i]['id'] as int] ?? const {}).isNotEmpty
                            ? Theme.of(context).colorScheme.primaryContainer
                            : Theme.of(context).colorScheme.surfaceContainerHighest,
                    child: Text('${i + 1}'),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text('关闭')),
        ],
      ),
    );
  }
}

class _QuestionCard extends StatelessWidget {
  final int index;
  final Map<String, dynamic> q;
  final Set<String> chosen;
  final Set<String> right;
  final void Function(String) onPick;

  const _QuestionCard({
    required this.index,
    required this.q,
    required this.chosen,
    required this.right,
    required this.onPick,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final type = '${q['type'] ?? 'single'}';
    final opts = (q['options'] as List? ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList();
    final showRight = right.isNotEmpty;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Text('$index.',
                  style: theme.textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.bold)),
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  type == 'multi'
                      ? '多选'
                      : type == 'judge'
                          ? '判断'
                          : '单选',
                  style: theme.textTheme.labelSmall,
                ),
              ),
              const Spacer(),
              Text('${q['score'] ?? 0} 分',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ]),
            const SizedBox(height: 8),
            Text('${q['stem'] ?? ''}'),
            const SizedBox(height: 6),
            for (final o in opts)
              InkWell(
                onTap: showRight ? null : () => onPick('${o['label']}'),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      // 交卷前用勾选框，交卷后直接标对错（这才是"对答案"）
                      if (showRight)
                        Icon(
                          right.contains('${o['label']}')
                              ? Icons.check_circle
                              : (chosen.contains('${o['label']}')
                                  ? Icons.cancel
                                  : Icons.circle_outlined),
                          size: 18,
                          color: right.contains('${o['label']}')
                              ? Colors.green
                              : (chosen.contains('${o['label']}')
                                  ? Colors.red
                                  : null),
                        )
                      else
                        Icon(
                          type == 'multi'
                              ? (chosen.contains('${o['label']}')
                                  ? Icons.check_box
                                  : Icons.check_box_outline_blank)
                              : (chosen.contains('${o['label']}')
                                  ? Icons.radio_button_checked
                                  : Icons.radio_button_unchecked),
                          size: 18,
                        ),
                      const SizedBox(width: 8),
                      Expanded(child: Text('${o['label']}. ${o['content'] ?? ''}')),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _SubmitBar extends StatelessWidget {
  final int answered;
  final int total;
  final bool busy;
  final VoidCallback onSubmit;
  const _SubmitBar(
      {required this.answered,
      required this.total,
      required this.busy,
      required this.onSubmit});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(children: [
          Text('已答 $answered / $total'),
          const Spacer(),
          FilledButton(
            key: const Key('training-submit'),
            onPressed: busy ? null : onSubmit,
            child: busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('交卷'),
          ),
        ]),
      ),
    );
  }
}

class _ResultView extends StatelessWidget {
  final Map<String, dynamic> result;
  final List<Map<String, dynamic>> questions;
  final Map<int, Set<String>> chosen;
  final VoidCallback onBack;

  const _ResultView(
      {required this.result,
      required this.questions,
      required this.chosen,
      required this.onBack});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final score = result['score'] ?? 0;
    final pass = result['pass'] == true;
    final passScore = result['passScore'] ?? 60;
    // 错题只在结果里列出来，不重复整份卷子 —— 正确答案在题目卡片上已经标了
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(children: [
              Icon(pass ? Icons.emoji_events : Icons.error_outline,
                  size: 44, color: pass ? Colors.amber : Colors.redAccent),
              const SizedBox(height: 8),
              Text('$score 分',
                  style: theme.textTheme.headlineMedium
                      ?.copyWith(fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Text(pass ? '通过（及格 $passScore 分）' : '未通过（及格 $passScore 分）'),
            ]),
          ),
        ),
        const SizedBox(height: 12),
        for (final q in questions)
          _QuestionCard(
            index: questions.indexOf(q) + 1,
            q: q,
            chosen: chosen[q['id'] as int] ?? const {},
            right: _rightLabels(result, q['id'] as int),
            onPick: (_) {},
          ),
        const SizedBox(height: 12),
        FilledButton(onPressed: onBack, child: const Text('返回课程')),
      ],
    );
  }

  static Set<String> _rightLabels(Map<String, dynamic> res, int qid) {
    final d = (res['detail'] as List? ?? const [])
        .whereType<Map<String, dynamic>>()
        .firstWhere((x) => x['questionId'] == qid,
            orElse: () => const <String, dynamic>{});
    return '${d['rightLabels'] ?? ''}'.split('').toSet();
  }
}
