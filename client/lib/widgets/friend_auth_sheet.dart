import 'package:flutter/material.dart';
import 'package:xiaozhi_im_client/api.dart';
import 'package:xiaozhi_im_client/core/theme.dart';
import 'package:xiaozhi_im_client/models.dart';
import 'package:xiaozhi_im_client/widgets/avatar.dart';

/// 好友验证弹窗：写认证附言 + 常用模板一键填入。
///
/// 返回用户确认的附言文本；返回 `null` 表示取消。
/// 附言可以为空（对方会看到「对方没有填写验证信息」）。
Future<String?> showFriendAuthSheet(
  BuildContext context, {
  required int userId,
  required String peerName,
  String? peerAvatar,
}) =>
    showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadii.lg)),
      ),
      builder: (_) => FriendAuthSheet(
        userId: userId,
        peerName: peerName,
        peerAvatar: peerAvatar,
      ),
    );

class FriendAuthSheet extends StatefulWidget {
  final int userId;
  final String peerName;
  final String? peerAvatar;

  const FriendAuthSheet({
    super.key,
    required this.userId,
    required this.peerName,
    this.peerAvatar,
  });

  @override
  State<FriendAuthSheet> createState() => _FriendAuthSheetState();
}

class _FriendAuthSheetState extends State<FriendAuthSheet> {
  final _ctrl = TextEditingController();
  List<FriendTemplate> _tpls = [];

  @override
  void initState() {
    super.initState();
    _prefill();
    _loadTemplates();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  /// 默认填「我是 xxx」——对方在申请列表里一眼知道是谁，
  /// 比留空白框让用户自己想措辞更省事。
  Future<void> _prefill() async {
    try {
      final me = await ImApi().me();
      final n = ((me['user'] ?? const {})['nickname'] ?? '').toString();
      if (!mounted || n.isEmpty || _ctrl.text.isNotEmpty) return;
      setState(() => _ctrl.text = '我是$n');
    } catch (_) {
      // 拿不到昵称就不预填，不影响手动写
    }
  }

  Future<void> _loadTemplates() async {
    try {
      final list = await ImApi().friendTemplates();
      if (!mounted) return;
      setState(() =>
          _tpls = list.map((e) => FriendTemplate.fromJson(e)).toList());
    } catch (_) {
      // 模板拉不到依旧可以手写附言，不打断主流程
    }
  }

  Future<void> _saveAsTemplate() async {
    final text = _ctrl.text.trim();
    if (text.isEmpty) {
      _toast('先写一句附言，再存为模板');
      return;
    }
    try {
      await ImApi().addFriendTemplate(text);
      await _loadTemplates();
      _toast('已存为模板');
    } catch (e) {
      _toast(e is ApiException ? e.message : '存模板失败');
    }
  }

  void _toast(String s) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(s), duration: const Duration(seconds: 2)));
  }

  @override
  Widget build(BuildContext context) => Padding(
        // 键盘弹起时把内容顶上去，否则输入框被挡住
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: AppColors.border,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    UserAvatar(
                        name: widget.peerName,
                        size: 42,
                        imageUrl: widget.peerAvatar),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('好友验证',
                              style: TextStyle(
                                  fontSize: 15.5, fontWeight: FontWeight.w700)),
                          const SizedBox(height: 2),
                          Text('发送给 ${widget.peerName}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontSize: 12.5, color: AppColors.textWeak)),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: _ctrl,
                  maxLength: 100,
                  maxLines: 3,
                  minLines: 2,
                  textInputAction: TextInputAction.newline,
                  decoration: InputDecoration(
                    hintText: '说一句话，让对方知道你是谁',
                    counterText: '',
                    filled: true,
                    fillColor: AppColors.bgElevated,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(AppRadii.sm),
                      borderSide: const BorderSide(color: AppColors.border),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(AppRadii.sm),
                      borderSide: const BorderSide(color: AppColors.border),
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                if (_tpls.isNotEmpty) ...[
                  const Padding(
                    padding: EdgeInsets.only(left: 2, bottom: 6),
                    child: Text('常用模板（点一下填入）',
                        style: TextStyle(fontSize: 11.5, color: AppColors.textWeak)),
                  ),
                  Wrap(
                    spacing: 7,
                    runSpacing: 7,
                    children: [
                      for (final t in _tpls)
                        InkWell(
                          borderRadius: BorderRadius.circular(AppRadii.pill),
                          onTap: () => setState(() => _ctrl.text = t.content),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 11, vertical: 6),
                            constraints: const BoxConstraints(maxWidth: 300),
                            decoration: BoxDecoration(
                              color: AppColors.bgElevated,
                              borderRadius: BorderRadius.circular(AppRadii.pill),
                              border: Border.all(color: AppColors.border),
                            ),
                            child: Text(
                              t.content,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontSize: 12.5, color: AppColors.textSub),
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 10),
                ],
                Row(
                  children: [
                    TextButton.icon(
                      onPressed: _saveAsTemplate,
                      icon: const Icon(Icons.bookmark_add_outlined, size: 17),
                      label: const Text('存为模板', style: TextStyle(fontSize: 13)),
                    ),
                    const Spacer(),
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('取消'),
                    ),
                    const SizedBox(width: 6),
                    FilledButton(
                      onPressed: () => Navigator.pop(context, _ctrl.text.trim()),
                      child: const Text('发送申请'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
}
