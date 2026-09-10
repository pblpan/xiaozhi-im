import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xiaozhi_im_client/api.dart';
import 'package:xiaozhi_im_client/core/theme.dart';
import 'package:xiaozhi_im_client/core/time.dart';
import 'package:xiaozhi_im_client/models.dart';
import 'package:xiaozhi_im_client/screens/chat.dart';
import 'package:xiaozhi_im_client/widgets/avatar.dart';

/// 我的收藏：跨会话汇总我收藏过的消息，点击可跳回原会话。
class FavoritesScreen extends StatefulWidget {
  final int myId;

  const FavoritesScreen({super.key, required this.myId});

  @override
  State<FavoritesScreen> createState() => _FavoritesScreenState();
}

class _FavoritesScreenState extends State<FavoritesScreen> {
  List<FavoriteHit> _items = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d = await ImApi().favorites();
      if (!mounted) return;
      setState(() {
        _items = ((d['items'] as List?) ?? [])
            .map((e) => FavoriteHit.fromJson(e))
            .toList();
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

  Future<void> _remove(FavoriteHit h) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('取消收藏'),
        content: const Text('确定从收藏夹移除这条消息吗？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('移除')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ImApi().removeFavorite(h.msg.id);
      if (!mounted) return;
      setState(() => _items.removeWhere((x) => x.msg.id == h.msg.id));
      _toast('已移除');
    } catch (e) {
      if (mounted) _toast('移除失败: ${e.toString().replaceFirst('Exception: ', '')}');
    }
  }

  void _open(FavoriteHit h) {
    final conv = Conversation(
      id: h.msg.conversationId,
      type: h.convType ?? 'dm',
      title: h.convTitle,
      peer: null,
    );
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ChatScreen(
          conv: conv,
          myId: widget.myId,
          peerName: h.convType == 'group' ? null : h.convTitle,
        ),
      ),
    );
  }

  /// 收藏内容的单行预览（媒体类显示类型标签）
  String _preview(Message m) {
    switch (m.kind) {
      case 'text':
        return m.content ?? '';
      case 'image':
        return '[图片]';
      case 'audio':
        return '[语音] ${m.audioSeconds ?? 1}"';
      case 'file':
        return '[文件] ${m.fileName ?? m.content ?? ''}';
      case 'emoji':
        return '[表情] ${m.content ?? ''}';
      default:
        return m.content ?? '';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        title: Text(_items.isEmpty ? '我的收藏' : '我的收藏 (${_items.length})'),
        backgroundColor: AppColors.bgElevated,
      ),
      body: _loading
          ? const Center(
              child: SizedBox(
                  width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)))
          : RefreshIndicator(
              color: AppColors.brand,
              onRefresh: _load,
              child: _items.isEmpty
                  ? ListView(
                      children: const [
                        SizedBox(height: 140),
                        Center(
                          child: Column(
                            children: [
                              Icon(Icons.star_border_rounded,
                                  size: 46, color: AppColors.textWeak),
                              SizedBox(height: 12),
                              Text('还没有收藏的消息',
                                  style: TextStyle(color: AppColors.textSub, fontSize: 14)),
                              SizedBox(height: 6),
                              Text('长按任意消息 → 收藏，即可在这里找到',
                                  style: TextStyle(color: AppColors.textWeak, fontSize: 12)),
                            ],
                          ),
                        ),
                      ],
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      itemCount: _items.length,
                      separatorBuilder: (_, __) =>
                          const Divider(height: 1, color: AppColors.divider),
                      itemBuilder: (c, i) {
                        final h = _items[i];
                        return ListTile(
                          leading: UserAvatar(name: h.convTitle ?? '?', size: 40, radius: 11),
                          title: Row(
                            children: [
                              Flexible(
                                child: Text(
                                  h.convTitle ?? '(会话)',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      fontSize: 14.5, fontWeight: FontWeight.w600),
                                ),
                              ),
                              if (h.convType == 'group')
                                const Padding(
                                  padding: EdgeInsets.only(left: 6),
                                  child: Icon(Icons.group_rounded,
                                      size: 13, color: AppColors.textWeak),
                                ),
                            ],
                          ),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const SizedBox(height: 3),
                              Text(
                                _preview(h.msg),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontSize: 13, color: AppColors.textSub, height: 1.35),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                '${h.mine ? "我" : (h.senderName ?? "对方")} · '
                                '${h.favoritedAt != null ? TimeFmt.hhmm(h.favoritedAt!) : ""}',
                                style: const TextStyle(
                                    fontSize: 11, color: AppColors.textWeak),
                              ),
                            ],
                          ),
                          trailing: IconButton(
                            tooltip: '取消收藏',
                            icon: const Icon(Icons.star_rounded,
                                size: 20, color: Color(0xFFF5B942)),
                            onPressed: () => _remove(h),
                          ),
                          onTap: () => _open(h),
                          onLongPress: () {
                            Clipboard.setData(ClipboardData(text: _preview(h.msg)));
                            _toast('已复制');
                          },
                        );
                      },
                    ),
            ),
    );
  }
}
