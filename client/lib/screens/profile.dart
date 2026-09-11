import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xiaozhi_im_client/api.dart';
import 'package:xiaozhi_im_client/core/media.dart';
import 'package:xiaozhi_im_client/core/theme.dart';
import 'package:xiaozhi_im_client/models.dart';
import 'package:xiaozhi_im_client/widgets/avatar.dart';

/// 个人信息面板。
///
/// - `userId == null`：看自己的资料，字段全部可编辑，**改一项存一项**
/// - 传了 `userId`：看他人资料，只读（供好友资料卡复用）
///
/// 页面不返回「是否改动过」：调用方在页面关闭后无脑刷新一次即可，
/// 省掉一套容易漏标的 dirty 状态（多一次列表请求，代价可以忽略）。
class ProfileScreen extends StatefulWidget {
  final int? userId;

  const ProfileScreen({super.key, this.userId});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  User? _u;
  bool _loading = true;
  String? _error;
  int _myId = 0;
  bool _busy = false; // 上传头像等耗时操作期间禁用重入

  bool get _isMe => widget.userId == null || widget.userId == _myId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final me = await ImApi().me();
      _myId = ((me['user'] ?? const {})['id'] ?? 0) as int;
      final target = widget.userId ?? _myId;
      final Map<String, dynamic> data = target == _myId
          ? (me['user'] as Map<String, dynamic>)
          : await ImApi().userProfile(target);
      if (!mounted) return;
      setState(() {
        _u = User.fromJson(data);
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

  String _errText(Object e) =>
      e is ApiException ? e.message : e.toString().replaceFirst('Exception: ', '');

  void _toast(String s) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(s), duration: const Duration(seconds: 2)));
  }

  /// 保存单项字段。
  /// 只传这一个 key：服务端语义是「没传的字段不动」，
  /// 避免把整个表单一起提交时，把用户在其他设备上刚改的内容覆盖掉。
  Future<void> _save(String key, dynamic value) async {
    try {
      final d = await ImApi().updateProfile({key: value});
      if (!mounted) return;
      setState(() => _u = User.fromJson(d['user'] as Map<String, dynamic>));
      _toast('已保存');
    } catch (e) {
      _toast('保存失败：${_errText(e)}');
    }
  }

  // ---------------- 各项编辑入口 ----------------

  Future<void> _editText({
    required String title,
    required String key,
    required String? current,
    required String hint,
    required int maxLen,
    bool mustFill = false,
    int maxLines = 1,
  }) async {
    final ctrl = TextEditingController(text: current ?? '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLines: maxLines,
          // 上限和服务端一致，提前拦住，不让用户输完一大段再被拒
          maxLength: maxLen,
          decoration: InputDecoration(hintText: hint, counterText: ''),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('保存')),
        ],
      ),
    );
    if (ok != true) return;
    final v = ctrl.text.trim();
    if (mustFill && v.isEmpty) {
      _toast('$title不能为空');
      return;
    }
    if (v == (current ?? '')) return; // 没改动就别打一次请求
    await _save(key, v);
  }

  Future<void> _editGender() async {
    const options = <String, String>{
      'male': '男',
      'female': '女',
      'other': '保密',
      '': '不显示',
    };
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadii.lg)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 10),
            const Text('选择性别',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            for (final e in options.entries)
              ListTile(
                title: Text(e.value),
                trailing: (_u?.gender ?? '') == e.key
                    ? const Icon(Icons.check_rounded, color: AppColors.brand)
                    : null,
                onTap: () => Navigator.pop(ctx, e.key),
              ),
            const SizedBox(height: 6),
          ],
        ),
      ),
    );
    if (picked == null || picked == (_u?.gender ?? '')) return;
    await _save('gender', picked);
  }

  Future<void> _editBirthday() async {
    final cur = _u?.birthday;
    DateTime initial = DateTime(2000, 1, 1);
    if (cur != null && cur.isNotEmpty) {
      final p = DateTime.tryParse(cur);
      if (p != null) initial = p;
    }
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(1900),
      lastDate: DateTime.now(),
      helpText: '选择生日',
      cancelText: '取消',
      confirmText: '确定',
    );
    if (picked == null) return;
    final v = '${picked.year.toString().padLeft(4, '0')}-'
        '${picked.month.toString().padLeft(2, '0')}-'
        '${picked.day.toString().padLeft(2, '0')}';
    if (v == cur) return;
    await _save('birthday', v);
  }

  Future<void> _clearBirthday() async {
    if ((_u?.birthday ?? '').isEmpty) return;
    await _save('birthday', '');
  }

  Future<void> _changeAvatar() async {
    if (_busy) return;
    final files = await FilePicker.pickFiles(type: FileType.image);
    if (files.isEmpty) return;
    final path = files.first.path;
    if (path == null) return;
    setState(() => _busy = true);
    try {
      final toUpload = await Media.prepareForUpload(File(path));
      final up = await ImApi().upload(toUpload);
      final url = (up['url'] ?? '').toString();
      if (url.isEmpty) throw const ApiException('上传失败：服务端未返回地址');
      await _save('avatar', url);
    } catch (e) {
      _toast('头像上传失败：${_errText(e)}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _copy(String label, String value) {
    Clipboard.setData(ClipboardData(text: value));
    _toast('已复制$label');
  }

  // ---------------- 界面 ----------------

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(_isMe ? '个人信息' : '个人资料')),
        body: _loading
            ? const Center(
                child: SizedBox(
                    width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)))
            : _error != null
                ? _errorView()
                : _body(),
      );

  Widget _errorView() => Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 40),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline_rounded, size: 44, color: AppColors.textWeak),
              const SizedBox(height: 12),
              Text(_error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 13.5, color: AppColors.textSub)),
              const SizedBox(height: 10),
              FilledButton(onPressed: _load, child: const Text('重试')),
            ],
          ),
        ),
      );

  Widget _body() {
    final u = _u!;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 30),
      children: [
        _header(u),
        const SizedBox(height: 20),
        _group('资料', [
          _row('昵称', u.nickname ?? u.username,
              onTap: _isMe
                  ? () => _editText(
                        title: '昵称',
                        key: 'nickname',
                        current: u.nickname,
                        hint: '输入昵称',
                        maxLen: 24,
                        mustFill: true,
                      )
                  : null),
          _row('个性签名', (u.signature ?? '').isEmpty ? '未设置' : u.signature!,
              weak: (u.signature ?? '').isEmpty,
              onTap: _isMe
                  ? () => _editText(
                        title: '个性签名',
                        key: 'signature',
                        current: u.signature,
                        hint: '写一句话介绍自己',
                        maxLen: 60,
                        maxLines: 3,
                      )
                  : null),
          _row('性别', u.genderLabel ?? '未设置',
              weak: u.genderLabel == null, onTap: _isMe ? _editGender : null),
          _row('地区', (u.region ?? '').isEmpty ? '未设置' : u.region!,
              weak: (u.region ?? '').isEmpty,
              onTap: _isMe
                  ? () => _editText(
                        title: '地区',
                        key: 'region',
                        current: u.region,
                        hint: '如：黑龙江 海伦',
                        maxLen: 20,
                      )
                  : null),
          _row('生日', (u.birthday ?? '').isEmpty ? '未设置' : u.birthday!,
              weak: (u.birthday ?? '').isEmpty,
              onTap: _isMe ? _editBirthday : null,
              trailingAction: _isMe && (u.birthday ?? '').isNotEmpty
                  ? IconButton(
                      tooltip: '清除生日',
                      icon: const Icon(Icons.close_rounded, size: 17),
                      onPressed: _clearBirthday,
                    )
                  : null),
        ]),
        const SizedBox(height: 14),
        _group('账号', [
          _row('账号', u.username,
              trailingAction: IconButton(
                tooltip: '复制账号',
                icon: const Icon(Icons.copy_rounded, size: 16),
                onPressed: () => _copy('账号', u.username),
              )),
          _row('ID', '${u.id}',
              trailingAction: IconButton(
                tooltip: '复制 ID',
                icon: const Icon(Icons.copy_rounded, size: 16),
                onPressed: () => _copy('ID', '${u.id}'),
              )),
        ]),
        const SizedBox(height: 10),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 4),
          child: Text('账号与 ID 由系统分配，不可修改；已发送的消息不支持修改，只能撤回。',
              style: TextStyle(fontSize: 11.5, color: AppColors.textWeak, height: 1.5)),
        ),
      ],
    );
  }

  Widget _header(User u) => Column(
        children: [
          GestureDetector(
            onTap: _isMe ? _changeAvatar : null,
            child: Stack(
              children: [
                UserAvatar(name: u.display, size: 86, radius: 26, imageUrl: u.avatar),
                if (_isMe)
                  Positioned(
                    right: -2,
                    bottom: -2,
                    child: Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        gradient: AppTheme.brandGradient,
                        shape: BoxShape.circle,
                        border: Border.all(color: AppColors.bg, width: 2),
                      ),
                      child: _busy
                          ? const Padding(
                              padding: EdgeInsets.all(7),
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white),
                            )
                          : const Icon(Icons.photo_camera_rounded,
                              size: 14, color: Colors.white),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Text(u.display,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          const SizedBox(height: 3),
          Text('@${u.username}',
              style: const TextStyle(fontSize: 12.5, color: AppColors.textWeak)),
          if (_isMe) ...[
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: _changeAvatar,
              icon: const Icon(Icons.photo_camera_rounded, size: 16),
              label: const Text('更换头像'),
            ),
          ],
        ],
      );

  Widget _group(String title, List<Widget> children) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 8),
            child: Text(title,
                style: const TextStyle(
                    fontSize: 12, color: AppColors.textWeak, fontWeight: FontWeight.w600)),
          ),
          Container(
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(AppRadii.md),
              border: Border.all(color: AppColors.divider),
            ),
            child: Column(
              children: [
                for (var i = 0; i < children.length; i++) ...[
                  children[i],
                  if (i != children.length - 1)
                    const Divider(height: 1, indent: 14, endIndent: 14, color: AppColors.divider),
                ],
              ],
            ),
          ),
        ],
      );

  Widget _row(
    String label,
    String value, {
    VoidCallback? onTap,
    bool weak = false,
    Widget? trailingAction,
  }) =>
      InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
          child: Row(
            children: [
              Text(label, style: const TextStyle(fontSize: 14.5)),
              const Spacer(),
              Flexible(
                child: Text(
                  value,
                  textAlign: TextAlign.right,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14, color: weak ? AppColors.textWeak : AppColors.textSub),
                ),
              ),
              if (trailingAction != null) trailingAction,
              if (onTap != null) ...[
                const SizedBox(width: 4),
                const Icon(Icons.chevron_right_rounded,
                    size: 19, color: AppColors.textWeak),
              ],
            ],
          ),
        ),
      );
}
