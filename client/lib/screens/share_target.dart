import 'dart:io';

import 'package:flutter/material.dart';
import 'package:xiaozhi_im_client/api.dart';
import 'package:xiaozhi_im_client/core/media.dart';
import 'package:xiaozhi_im_client/core/share_intake.dart';
import 'package:xiaozhi_im_client/core/theme.dart';
import 'package:xiaozhi_im_client/core/time.dart';
import 'package:xiaozhi_im_client/models.dart';
import 'package:xiaozhi_im_client/widgets/avatar.dart';

/// 「发送到小智」：从系统分享面板进来后，选一个会话把文件发出去。
///
/// 为什么不跳进聊天页让用户自己点发送：分享场景下用户**已经选过一次**了
/// （在系统面板里选了小智），再让他点两三次才发得出去，比原生 App 差一截。
/// 这里一次选完直接发；想说两句就填附言，不想就直接发。
class ShareTargetScreen extends StatefulWidget {
  const ShareTargetScreen({super.key, required this.payload});

  final SharedPayload payload;

  @override
  State<ShareTargetScreen> createState() => _ShareTargetScreenState();
}

class _ShareTargetScreenState extends State<ShareTargetScreen> {
  /// 附言：纯文字分享时预填系统给的那段文字
  late final TextEditingController _note =
      TextEditingController(text: widget.payload.text);

  late List<SharedFile> _files = List.of(widget.payload.files);
  List<Conversation> _convs = [];
  int? _pickedId;
  bool _loading = true;
  bool _sending = false;
  String _progress = '';
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _note.dispose();
    // 清掉还留在缓存目录的临时副本。已经发走的那些在发送时就删了，这里兜住剩下的
    // （失败的 / 用户没发的）。不清的话每分享一次就在手机上留一份，攒几次就看得见。
    widget.payload.disposeFiles();
    super.dispose();
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
      setState(() {
        _loading = false;
        _error = '会话列表加载失败：${_msg(e)}';
      });
    }
  }

  String _msg(Object e) => e.toString().replaceFirst('Exception: ', '');

  void _toast(String s) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(s), duration: const Duration(seconds: 2)));

  /// 当前选中的会话。不用 where(...).firstOrNull —— 那是 package:collection 的扩展，
  /// 可用性随版本变化，显式循环没有任何依赖风险。
  Conversation? get _picked {
    for (final c in _convs) {
      if (c.id == _pickedId) return c;
    }
    return null;
  }

  void _deleteQuietly(String path) {
    try {
      final f = File(path);
      if (f.existsSync()) f.deleteSync();
    } catch (_) {
      // 清理失败不影响发送结果
    }
  }

  Future<void> _send() async {
    final conv = _picked;
    if (conv == null || _sending) return;

    setState(() {
      _sending = true;
      _error = null;
      _progress = '准备中…';
    });

    final note = _note.text.trim();
    final failed = <String>[];
    final done = <int>[];
    String? firstError;

    // 附言先发：聊天里读起来就是"先说一句、再把文件给你"，顺序反了会显得突兀
    if (note.isNotEmpty) {
      try {
        await ImApi().sendMessage(conv.id, 'text', note);
      } catch (e) {
        failed.add('附言');
        firstError ??= _msg(e);
      }
    }

    for (var i = 0; i < _files.length; i++) {
      final f = _files[i];
      if (!mounted) return;
      setState(() => _progress = '发送中 ${i + 1}/${_files.length}');
      try {
        final orig = File(f.path);
        if (!orig.existsSync()) throw Exception('文件已不存在');

        // 与聊天页**同一条链路**：内网直传原图、外网先压缩。
        // 这里若自己另写一套上传，就会出现"聊天里发是压缩的、分享进来是原图"。
        final toUpload = await Media.prepareForUpload(orig);
        final up = await ImApi().upload(toUpload, filename: f.name);

        final name = (up['name'] ?? f.name).toString();
        // 服务端没给 mime 时按原始名/落地名兜底判断（有 App 分享时不给 mime）
        final isImg = (up['mime'] ?? '').toString().startsWith('image') ||
            Media.isImagePath(name) ||
            f.isImage;
        // 图片消息存访问路径（/files/xxx），文件消息存原始文件名 —— 与聊天页一致
        final content = isImg ? (up['url'] ?? name).toString() : name;

        await ImApi()
            .sendMessage(conv.id, isImg ? 'image' : 'file', content, up['id']);
        done.add(i);
      } catch (e) {
        failed.add(f.name.isEmpty ? '文件' : f.name);
        firstError ??= _msg(e);
      }
    }

    // 已发走的立刻删本地副本；失败的原样留着，用户再点一次只重发剩下的
    for (final i in done) {
      _deleteQuietly(_files[i].path);
    }
    final kept = <SharedFile>[];
    for (var i = 0; i < _files.length; i++) {
      if (!done.contains(i)) kept.add(_files[i]);
    }

    if (!mounted) return;
    if (failed.isEmpty) {
      _toast('已发送给 ${conv.title ?? '对方'}');
      Navigator.pop(context);
      return;
    }
    setState(() {
      _sending = false;
      _files = kept;
      _progress = '';
      _error = '${failed.length} 个没发出去：${failed.join('、')}'
          '${firstError == null ? '' : '（$firstError）'}';
    });
  }

  @override
  Widget build(BuildContext context) {
    final conv = _picked;
    return PopScope(
      // 发送中不给返回：一返回就走到 dispose，把**正在上传的那份临时文件**也清掉了，
      // 上传当场失败，而用户以为自己只是"退出了"。也就几秒钟，等它发完更符合预期。
      // 只挂 canPop —— onPopInvoked 在 Flutter 3.24 前后改过名字，不碰它就没版本风险。
      canPop: !_sending,
      child: Scaffold(
        backgroundColor: AppColors.bg,
        appBar: AppBar(
          title: const Text('发送到小智'),
          backgroundColor: AppColors.bgElevated,
        ),
        body: Column(
          children: [
            if (_files.isNotEmpty) _attachBar(),
            _noteField(),
            if (_error != null) _errorBar(_error!),
            const Divider(height: 1, color: AppColors.divider),
            Expanded(child: _convList()),
            _bottomBar(conv),
          ],
        ),
      ),
    );
  }

  /// 待发附件：横向排开，图片显示缩略图（不然用户不知道选没选对图）
  Widget _attachBar() {
    return Container(
      color: AppColors.bgElevated,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: SizedBox(
        height: 84,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: _files.length,
          separatorBuilder: (_, __) => const SizedBox(width: 8),
          itemBuilder: (c, i) => _fileChip(_files[i], i),
        ),
      ),
    );
  }

  Widget _fileChip(SharedFile f, int i) {
    return Stack(
      children: [
        Container(
          width: 110,
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(AppRadii.md),
            border: Border.all(color: AppColors.divider),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Expanded(
                child: f.isImage
                    ? ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        // cacheWidth 限制解码尺寸：原图动辄 4000px，直接渲染缩略图会吃掉几十 MB 内存
                        child: Image.file(
                          File(f.path),
                          width: double.infinity,
                          fit: BoxFit.cover,
                          cacheWidth: 240,
                          errorBuilder: (_, __, ___) => const Icon(
                              Icons.broken_image_outlined,
                              color: AppColors.textWeak),
                        ),
                      )
                    : const Center(
                        child: Icon(Icons.insert_drive_file_outlined,
                            size: 26, color: AppColors.textSub),
                      ),
              ),
              const SizedBox(height: 4),
              Text(
                f.name.isEmpty ? '文件' : f.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11, color: AppColors.textSub),
              ),
            ],
          ),
        ),
        // 发错了/不想发这张 → 直接删掉，不用返回重来
        Positioned(
          // 放在卡的**内部**右上角，不是挂在外沿：横向 ListView 会裁掉超出的部分，
          // 挂在外面的叉号会被切掉一半（看着像渲染坏了）。
          right: 2,
          top: 2,
          child: GestureDetector(
            onTap: _sending
                ? null
                : () {
                    _deleteQuietly(f.path);
                    setState(() => _files.removeAt(i));
                  },
            child: Container(
              padding: const EdgeInsets.all(2),
              decoration: const BoxDecoration(
                  color: AppColors.danger, shape: BoxShape.circle),
              child: const Icon(Icons.close, size: 14, color: Colors.white),
            ),
          ),
        ),
      ],
    );
  }

  Widget _noteField() {
    return Container(
      color: AppColors.bgElevated,
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      child: TextField(
        controller: _note,
        maxLines: 3,
        minLines: 1,
        style: const TextStyle(fontSize: 14),
        decoration: InputDecoration(
          hintText: _files.isEmpty ? '说点什么' : '说点什么（可不填）',
          hintStyle: const TextStyle(color: AppColors.textWeak, fontSize: 14),
          filled: true,
          fillColor: AppColors.bg,
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AppRadii.md),
            borderSide: BorderSide.none,
          ),
        ),
      ),
    );
  }

  Widget _errorBar(String text) {
    return Container(
      width: double.infinity,
      color: AppColors.danger.withValues(alpha: 0.14),
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
      child: Text(text,
          style: const TextStyle(fontSize: 12.5, color: AppColors.danger)),
    );
  }

  Widget _convList() {
    if (_loading) {
      return const Center(
        child: SizedBox(
            width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    if (_convs.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(28),
          child: Text(
            '还没有可以发送的会话。\n先去「消息」里找同事聊一句，这里就有他了。',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.textSub, height: 1.6),
          ),
        ),
      );
    }
    return ListView.builder(
      itemCount: _convs.length,
      itemBuilder: (c, i) {
        final cv = _convs[i];
        final on = cv.id == _pickedId;
        return ListTile(
          leading: UserAvatar(name: cv.title ?? '?', size: 42, radius: 12),
          title: Text(cv.title ?? '(无标题)',
              maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            cv.type == 'group' ? '群聊' : '单聊',
            style: const TextStyle(fontSize: 12, color: AppColors.textWeak),
          ),
          // 用图标自绘选中态而不是 Radio 组件：Radio 的 API 在新版 Flutter 里
          // 改过（引入 RadioGroup），自绘没有版本兼容风险。
          trailing: Icon(
            on ? Icons.radio_button_checked : Icons.radio_button_unchecked,
            color: on ? AppColors.brand : AppColors.textWeak,
            size: 20,
          ),
          onTap: _sending ? null : () => setState(() => _pickedId = cv.id),
        );
      },
    );
  }

  Widget _bottomBar(Conversation? conv) {
    // 包一层 ValueListenableBuilder：附言改一个字就要让按钮从"灰"变"可点"，
    // 但绝不能为此 setState 整个页面（会话列表没必要跟着重建）。附言只影响这一块。
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: _note,
      builder: (_, v, __) {
        final hasNote = v.text.trim().isNotEmpty;
        final canSend =
            conv != null && !_sending && (_files.isNotEmpty || hasNote);
        final who = conv?.title ?? '对方';
        final label = _sending
            ? (_progress.isEmpty ? '发送中…' : _progress)
            : (conv == null
                ? '请选择发送的对象'
                : (_files.isEmpty
                    ? '发送给「$who」'
                    : '发送 ${_files.length} 个文件给「$who」'));
        return Container(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
          decoration: const BoxDecoration(
            color: AppColors.bgElevated,
            border: Border(top: BorderSide(color: AppColors.divider)),
          ),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_files.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.info_outline,
                            size: 13, color: AppColors.textWeak),
                        const SizedBox(width: 5),
                        Text(
                          '共 ${TimeFmt.size(_files.fold<int>(0, (s, f) => s + f.size))}',
                          style: const TextStyle(
                              fontSize: 11.5, color: AppColors.textWeak),
                        ),
                      ],
                    ),
                  ),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.brand,
                      padding: const EdgeInsets.symmetric(vertical: 13),
                    ),
                    onPressed: canSend ? _send : null,
                    child: Text(label, style: const TextStyle(fontSize: 15)),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
