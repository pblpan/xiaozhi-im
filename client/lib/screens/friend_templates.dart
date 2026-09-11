import 'package:flutter/material.dart';
import 'package:xiaozhi_im_client/api.dart';
import 'package:xiaozhi_im_client/core/theme.dart';
import 'package:xiaozhi_im_client/models.dart';

/// 好友申请附言模板管理：增 / 改 / 删。
///
/// 上限与服务端一致（10 条）。到顶时提前给出明确提示，
/// 而不是等用户输完一大段再被服务端拒掉。
class FriendTemplatesScreen extends StatefulWidget {
  const FriendTemplatesScreen({super.key});

  @override
  State<FriendTemplatesScreen> createState() => _FriendTemplatesScreenState();
}

const int kMaxFriendTemplates = 10;
const int kMaxTemplateLen = 100;

class _FriendTemplatesScreenState extends State<FriendTemplatesScreen> {
  List<FriendTemplate> _list = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  String _errText(Object e) => e is ApiException
      ? e.message
      : e.toString().replaceFirst('Exception: ', '');

  void _toast(String s) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(s), duration: const Duration(seconds: 2)));
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await ImApi().friendTemplates();
      if (!mounted) return;
      setState(() {
        _list = list.map((e) => FriendTemplate.fromJson(e)).toList();
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = _errText(e);
      });
    }
  }

  Future<String?> _prompt({String title = '新增模板', String? initial}) async {
    final ctrl = TextEditingController(text: initial ?? '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLength: kMaxTemplateLen,
          maxLines: 3,
          minLines: 1,
          decoration: const InputDecoration(
            hintText: '如：我是海伦盛京优特的，加个好友',
            counterText: '',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('保存')),
        ],
      ),
    );
    if (ok != true) return null;
    return ctrl.text.trim();
  }

  Future<void> _add() async {
    if (_list.length >= kMaxFriendTemplates) {
      _toast('最多只能存 $kMaxFriendTemplates 条模板，先删一条吧');
      return;
    }
    final text = await _prompt();
    if (text == null) return;
    if (text.isEmpty) {
      _toast('模板内容不能为空');
      return;
    }
    try {
      await ImApi().addFriendTemplate(text);
      await _load();
    } catch (e) {
      _toast(_errText(e));
    }
  }

  Future<void> _edit(FriendTemplate t) async {
    final text = await _prompt(title: '修改模板', initial: t.content);
    if (text == null) return;
    if (text.isEmpty) {
      _toast('模板内容不能为空');
      return;
    }
    if (text == t.content) return;
    try {
      await ImApi().updateFriendTemplate(t.id, text);
      await _load();
    } catch (e) {
      _toast(_errText(e));
    }
  }

  Future<void> _remove(FriendTemplate t) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除模板'),
        content: Text('确定删除「${t.content}」吗？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ImApi().deleteFriendTemplate(t.id);
      await _load();
    } catch (e) {
      _toast(_errText(e));
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: const Text('认证消息模板'),
          actions: [
            IconButton(
              tooltip: '新增模板',
              onPressed: _add,
              icon: const Icon(Icons.add_rounded),
            ),
          ],
        ),
        body: _loading
            ? const Center(
                child: SizedBox(
                    width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)))
            : _error != null
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(_error!,
                            style: const TextStyle(color: AppColors.textSub)),
                        const SizedBox(height: 10),
                        FilledButton(onPressed: _load, child: const Text('重试')),
                      ],
                    ),
                  )
                : _list.isEmpty
                    ? const Center(
                        child: Text('还没有模板，点右上角「+」加一条',
                            style: TextStyle(color: AppColors.textWeak, fontSize: 13)))
                    : ListView.separated(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        itemCount: _list.length + 1,
                        separatorBuilder: (_, __) => const Divider(
                            height: 1, indent: 16, endIndent: 16, color: AppColors.divider),
                        itemBuilder: (_, i) {
                          if (i == _list.length) {
                            return Padding(
                              padding: const EdgeInsets.fromLTRB(16, 14, 16, 20),
                              child: Text(
                                '共 ${_list.length}/$kMaxFriendTemplates 条。'
                                '加好友时点一下模板即可填入附言。',
                                style: const TextStyle(
                                    fontSize: 11.5,
                                    color: AppColors.textWeak,
                                    height: 1.5),
                              ),
                            );
                          }
                          final t = _list[i];
                          return ListTile(
                            title: Text(t.content,
                                style: const TextStyle(fontSize: 14.5, height: 1.4)),
                            trailing: IconButton(
                              tooltip: '删除',
                              icon: const Icon(Icons.delete_outline_rounded,
                                  size: 19, color: AppColors.danger),
                              onPressed: () => _remove(t),
                            ),
                            onTap: () => _edit(t),
                          );
                        },
                      ),
      );
}
