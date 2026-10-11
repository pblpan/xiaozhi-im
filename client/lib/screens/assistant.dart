import 'package:flutter/material.dart';
import 'package:xiaozhi_im_client/api.dart';
import 'package:xiaozhi_im_client/core/theme.dart';
/// 智能助手（#314 龙哥：智能助手接管帮助 + 接入智能体）。
///
/// 一页对话式问答：问"系统怎么用"，服务端用内置帮助知识库（可选 LLM）回答。
/// 服务端降级链兜底（LLM 挂了回知识库），这里只管把问答过程呈现好：
///   · 回答来源打标签（AI / 内置帮助库）——让用户知道这句话是"谁"说的；
///   · related 相关问法可点击，一点接着问；
///   · 发送失败在气泡里明说，不留"点了没反应"。
class AssistantScreen extends StatefulWidget {
  const AssistantScreen({super.key});

  @override
  State<AssistantScreen> createState() => _AssistantScreenState();
}

/// 一轮问答。isUser=true 是用户问的；false 是助手答的。
class _Turn {
  _Turn.user(this.text)
      : isUser = true,
        source = null,
        note = null,
        related = const [];
  _Turn.assistant(this.text, this.source, this.note, this.related)
      : isUser = false;
  final String text;
  final bool isUser;
  final String? source; // 'llm' | 'kb' | 'fallback'
  final String? note;
  final List<String> related;
}

class _AssistantScreenState extends State<AssistantScreen> {
  final _ctrl = TextEditingController();
  final _scroll = ScrollController();
  final List<_Turn> _turns = [];
  bool _busy = false;

  static const _samples = [
    '怎么打卡？',
    '怎么加好友？',
    '手机和电脑怎么传文件？',
    '电脑端怎么截图？',
    '补卡怎么申请？',
    '工资怎么算的？',
    '怎么建群？',
    '忘记密码了怎么办？',
  ];

  @override
  void dispose() {
    _ctrl.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _ask(String q) async {
    final text = q.trim();
    if (text.isEmpty || _busy) return;
    setState(() {
      _turns.add(_Turn.user(text));
      _busy = true;
    });
    _ctrl.clear();
    _scrollDown();
    try {
      final d = await ImApi().askAssistant(text);
      if (!mounted) return;
      setState(() {
        _turns.add(_Turn.assistant(
          (d['answer'] ?? '').toString(),
          d['source'] as String?,
          d['note'] as String?,
          ((d['related'] as List?) ?? [])
              .map((e) => e.toString())
              .toList(),
        ));
        _busy = false;
      });
      _scrollDown();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _turns.add(_Turn.assistant(
          '提问失败：${e.toString().replaceFirst('Exception: ', '')}\n'
          '请检查网络后重试；持续失败请联系管理员。',
          null, null, const []));
        _busy = false;
      });
      _scrollDown();
    }
  }

  void _scrollDown() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    });
  }

  String _sourceLabel(String? s) {
    switch (s) {
      case 'llm':
        return 'AI';
      case 'kb':
        return '内置帮助库';
      default:
        return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('智能助手')),
      body: Column(
        children: [
          Expanded(
            child: _turns.isEmpty
                ? _buildEmpty(theme)
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.all(12),
                    itemCount: _turns.length + (_busy ? 1 : 0),
                    itemBuilder: (context, i) {
                      if (i >= _turns.length) return _buildThinking(theme);
                      return _buildTurn(_turns[i], theme);
                    },
                  ),
          ),
          _buildInput(theme),
        ],
      ),
    );
  }

  /// 空态：一句定位说明 + 示例问题（点一下就问）
  Widget _buildEmpty(ThemeData theme) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.smart_toy_outlined, size: 64,
                color: theme.colorScheme.primary),
            const SizedBox(height: 12),
            Text('有什么使用问题，直接问',
                style: theme.textTheme.titleMedium),
            const SizedBox(height: 6),
            Text('怎么打卡、怎么建群、工资怎么算……\n答不上来的会提示你找管理员。',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: AppColors.textSub)),
            const SizedBox(height: 20),
            Wrap(
              spacing: 8, runSpacing: 8,
              alignment: WrapAlignment.center,
              children: _samples
                  .map((s) => ActionChip(
                        label: Text(s),
                        onPressed: () => _ask(s),
                      ))
                  .toList(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildThinking(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(children: [
        const SizedBox(width: 12),
        Icon(Icons.smart_toy_outlined, size: 20, color: theme.colorScheme.primary),
        const SizedBox(width: 8),
        Text('正在想…', style: theme.textTheme.bodySmall),
      ]),
    );
  }

  Widget _buildTurn(_Turn t, ThemeData theme) {
    final label = _sourceLabel(t.source);
    return Align(
      alignment: t.isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.78),
        decoration: BoxDecoration(
          color: t.isUser
              ? theme.colorScheme.primary
              : theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(14),
            topRight: const Radius.circular(14),
            bottomLeft: Radius.circular(t.isUser ? 14 : 4),
            bottomRight: Radius.circular(t.isUser ? 4 : 14),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(t.text,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: t.isUser
                      ? theme.colorScheme.onPrimary
                      : theme.colorScheme.onSurface,
                  height: 1.45,
                )),
            if (label.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text('来源：$label',
                    style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant)),
              ),
            if (t.note != null && t.note!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(t.note!,
                    style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.error)),
              ),
            if (t.related.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Wrap(
                  spacing: 6, runSpacing: 6,
                  children: t.related
                      .map((rq) => ActionChip(
                            visualDensity: VisualDensity.compact,
                            label: Text(rq,
                                style: theme.textTheme.labelSmall),
                            onPressed: () => _ask(rq),
                          ))
                      .toList(),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildInput(ThemeData theme) {
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          border: Border(top: BorderSide(color: theme.dividerColor)),
        ),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _ctrl,
                enabled: !_busy,
                textInputAction: TextInputAction.send,
                onSubmitted: _ask,
                decoration: const InputDecoration(
                  hintText: '输入你的问题，如：怎么打卡？',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              onPressed: _busy ? null : () => _ask(_ctrl.text),
              icon: _busy
                  ? const SizedBox(
                      width: 18, height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.send_rounded),
            ),
          ],
        ),
      ),
    );
  }
}
