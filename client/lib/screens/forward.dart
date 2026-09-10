import 'package:flutter/material.dart';
import 'package:xiaozhi_im_client/api.dart';
import 'package:xiaozhi_im_client/core/theme.dart';
import 'package:xiaozhi_im_client/models.dart';
import 'package:xiaozhi_im_client/widgets/avatar.dart';

/// 转发消息：勾选要发往的会话（可多选），确认后一次性转发。
class ForwardScreen extends StatefulWidget {
  final int messageId;

  const ForwardScreen({super.key, required this.messageId});

  @override
  State<ForwardScreen> createState() => _ForwardScreenState();
}

class _ForwardScreenState extends State<ForwardScreen> {
  List<Conversation> _convs = [];
  final Set<int> _picked = {};
  bool _loading = true;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d = await ImApi().conversations();
      if (!mounted) return;
      setState(() {
        _convs = d.map((e) => Conversation.fromJson(e)).toList();
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _toast('加载失败: ${e.toString().replaceFirst('Exception: ', '')}');
    }
  }

  void _toast(String s) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(s), duration: const Duration(seconds: 2)));

  Future<void> _submit() async {
    if (_picked.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      final r = await ImApi().forwardMessage(widget.messageId, _picked.toList());
      if (!mounted) return;
      final n = r['count'] ?? _picked.length;
      Navigator.pop(context, true);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已转发到 $n 个会话'), duration: const Duration(seconds: 2)),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _sending = false);
      _toast('转发失败: ${e.toString().replaceFirst('Exception: ', '')}');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        title: const Text('转发给'),
        backgroundColor: AppColors.bgElevated,
      ),
      body: _loading
          ? const Center(
              child: SizedBox(
                  width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)))
          : Column(
              children: [
                Expanded(
                  child: _convs.isEmpty
                      ? const Center(
                          child: Text('还没有会话',
                              style: TextStyle(color: AppColors.textSub)))
                      : ListView.builder(
                          itemCount: _convs.length,
                          itemBuilder: (c, i) {
                            final cv = _convs[i];
                            final checked = _picked.contains(cv.id);
                            return ListTile(
                              leading: UserAvatar(
                                name: cv.title ?? '?',
                                size: 42,
                                radius: 12,
                              ),
                              title: Text(cv.title ?? '(无标题)',
                                  maxLines: 1, overflow: TextOverflow.ellipsis),
                              subtitle: Text(
                                cv.type == 'group' ? '群聊' : '单聊',
                                style: const TextStyle(
                                    fontSize: 12, color: AppColors.textWeak),
                              ),
                              trailing: Checkbox(
                                value: checked,
                                activeColor: AppColors.brand,
                                onChanged: (_) => setState(() {
                                  if (checked) {
                                    _picked.remove(cv.id);
                                  } else {
                                    _picked.add(cv.id);
                                  }
                                }),
                              ),
                              onTap: () => setState(() {
                                if (checked) {
                                  _picked.remove(cv.id);
                                } else {
                                  _picked.add(cv.id);
                                }
                              }),
                            );
                          },
                        ),
                ),
                Container(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
                  decoration: const BoxDecoration(
                    color: AppColors.bgElevated,
                    border: Border(top: BorderSide(color: AppColors.divider)),
                  ),
                  child: SafeArea(
                    top: false,
                    child: SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        style: FilledButton.styleFrom(
                          backgroundColor: AppColors.brand,
                          padding: const EdgeInsets.symmetric(vertical: 13),
                        ),
                        onPressed: _picked.isEmpty || _sending ? null : _submit,
                        child: Text(
                          _sending
                              ? '转发中…'
                              : (_picked.isEmpty ? '请选择会话' : '转发到 ${_picked.length} 个会话'),
                          style: const TextStyle(fontSize: 15),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}
