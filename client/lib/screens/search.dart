import 'dart:async';
import 'package:flutter/material.dart';
import 'package:xiaozhi_im_client/api.dart';
import 'package:xiaozhi_im_client/core/theme.dart';
import 'package:xiaozhi_im_client/core/time.dart';
import 'package:xiaozhi_im_client/models.dart';
import 'package:xiaozhi_im_client/widgets/avatar.dart';

/// 全局搜索页：两个 Tab ——「聊天记录」与「好友」。
///
/// · 聊天记录：跨会话搜「我参与的」文字消息（沿用服务端 /conversations/search）。
/// · 好友：在**我的好友列表**里按昵称 / 账号 / 备注过滤，点一下直接打开与该好友的会话。
///
/// 点击任一结果都 `Navigator.pop(context, conversationId)`，
/// 由会话列表页负责打开对应会话（它持有 Conversation 对象与 myId）。
class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen>
    with SingleTickerProviderStateMixin {
  final _ctrl = TextEditingController();
  final _focus = FocusNode();

  /// 0 = 聊天记录，1 = 好友
  late final TabController _tab;

  Timer? _debounce;
  bool _loading = false;
  String _kw = '';
  List<SearchHit> _hits = [];
  int _total = 0;
  String? _error;

  // 好友 Tab 状态
  List<Map<String, dynamic>> _allFriends = [];
  bool _friendsLoaded = false;
  bool _friendsLoading = false;
  List<Map<String, dynamic>> _friendHits = [];
  String? _friendError;
  int? _opening; // 正在为其打开会话的好友 id（显示进度）

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 2, vsync: this);
    _tab.addListener(_onTab);
    _ctrl.addListener(_onChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _ctrl.dispose();
    _focus.dispose();
    _tab.dispose();
    super.dispose();
  }

  void _onTab() {
    // 切 Tab 时若已有搜索词，立刻按新 Tab 重新搜
    if (_kw.isNotEmpty) _run(_kw);
  }

  void _onChanged() {
    final v = _ctrl.text.trim();
    if (v == _kw) return;
    _debounce?.cancel();
    if (v.isEmpty) {
      setState(() {
        _kw = '';
        _hits = [];
        _total = 0;
        _loading = false;
        _error = null;
        _friendHits = [];
        _friendError = null;
        _friendsLoading = false;
      });
      return;
    }
    // 防抖：连续输入时只在停顿后请求一次
    _debounce = Timer(const Duration(milliseconds: 320), () => _run(v));
  }

  Future<void> _run(String kw) async {
    setState(() {
      _kw = kw;
      _error = null;
      _friendError = null;
    });
    if (_tab.index == 0) {
      await _runMessages(kw);
    } else {
      await _runFriends(kw);
    }
  }

  Future<void> _runMessages(String kw) async {
    setState(() {
      _loading = true;
    });
    try {
      final d = await ImApi().searchMessages(kw, limit: 100);
      if (!mounted) return;
      // 输入框内容已变（用户又打字了），丢弃这次结果
      if (_ctrl.text.trim() != kw) return;
      setState(() {
        _hits = (d['items'] as List? ?? [])
            .map((e) => SearchHit.fromJson(e))
            .toList();
        _total = (d['total'] as int?) ?? _hits.length;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  Future<void> _runFriends(String kw) async {
    // 首次进入好友 Tab 才拉一次全量好友；之后只在本地过滤，省流量也快
    if (!_friendsLoaded) {
      setState(() => _friendsLoading = true);
      try {
        final d = await ImApi().friends();
        if (!mounted) return;
        if (_ctrl.text.trim() != kw) return;
        _allFriends = (d['friends'] as List? ?? [])
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
        _friendsLoaded = true;
      } catch (e) {
        if (!mounted) return;
        setState(() {
          _friendsLoading = false;
          _friendError = e.toString().replaceFirst('Exception: ', '');
        });
        return;
      }
      setState(() => _friendsLoading = false);
    }
    final k = kw.toLowerCase();
    setState(() {
      _friendHits = _allFriends.where((f) {
        final name =
            (f['nickname'] ?? f['username'] ?? '').toString().toLowerCase();
        final user = (f['username'] ?? '').toString().toLowerCase();
        final remark = (f['remark'] ?? '').toString().toLowerCase();
        return name.contains(k) || user.contains(k) || remark.contains(k);
      }).toList();
    });
  }

  void _toast(String s) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));

  /// 点好友 → 打开与该好友的单聊。复用会话列表页的「按 conversationId 打开」逻辑。
  Future<void> _openFriend(Map<String, dynamic> f) async {
    final id = (f['id'] as num?)?.toInt();
    if (id == null) return;
    setState(() => _opening = id);
    try {
      final r = await ImApi().dm(id);
      if (!mounted) return;
      final cid = (r['conversationId'] as num?)?.toInt();
      if (cid == null) {
        _toast('未找到与该好友的会话');
        return;
      }
      Navigator.pop(context, cid);
    } catch (e) {
      if (!mounted) return;
      _toast(e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _opening = null);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          titleSpacing: 0,
          title: Container(
            height: 38,
            margin: const EdgeInsets.only(right: 12),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(19),
              border: Border.all(color: AppColors.border),
            ),
            child: TextField(
              controller: _ctrl,
              focusNode: _focus,
              textInputAction: TextInputAction.search,
              style: const TextStyle(fontSize: 14.5),
              decoration: InputDecoration(
                hintText: '搜索好友或聊天记录…',
                isDense: true,
                filled: false,
                prefixIcon: const Icon(Icons.search_rounded, size: 19),
                prefixIconConstraints:
                    const BoxConstraints(minWidth: 38, minHeight: 38),
                suffixIcon: _ctrl.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close_rounded, size: 17),
                        onPressed: () => _ctrl.clear(),
                      ),
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(vertical: 10),
              ),
            ),
          ),
          bottom: TabBar(
            controller: _tab,
            tabs: const [
              Tab(text: '聊天记录'),
              Tab(text: '好友'),
            ],
          ),
        ),
        body: TabBarView(
          controller: _tab,
          children: [_messagesBody(), _friendsBody()],
        ),
      );

  // ---------------------------------------------------------- 聊天记录 Tab

  Widget _messagesBody() {
    if (_error != null) {
      return _center(
        Icons.error_outline_rounded,
        '搜索失败',
        _error,
        action: TextButton(onPressed: () => _run(_kw), child: const Text('重试')),
      );
    }
    if (_kw.isEmpty) {
      return _center(Icons.manage_search_rounded, '搜索聊天记录',
          '输入关键词，跨会话查找你参与过的消息');
    }
    if (_loading && _hits.isEmpty) {
      return const Center(
        child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    if (_hits.isEmpty) {
      return _center(Icons.search_off_rounded, '没有找到「$_kw」',
          '换个关键词试试，或确认消息未被撤回');
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
          child: Row(
            children: [
              Text(
                _total > _hits.length
                    ? '找到 $_total 条，显示前 ${_hits.length} 条'
                    : '找到 $_total 条',
                style: const TextStyle(fontSize: 12, color: AppColors.textWeak),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.separated(
            itemCount: _hits.length,
            separatorBuilder: (_, __) => const Divider(
                height: 1, indent: 66, color: AppColors.divider),
            itemBuilder: (_, i) => _tile(_hits[i]),
          ),
        ),
      ],
    );
  }

  Widget _tile(SearchHit h) {
    final m = h.msg;
    final title = h.convTitle ?? '会话';
    final prefix = h.mine ? '我：' : (h.senderName != null ? '${h.senderName}：' : '');
    return InkWell(
      onTap: () => Navigator.pop(context, m.conversationId),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            UserAvatar(name: title, size: 40, radius: 13),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 14, fontWeight: FontWeight.w600),
                        ),
                      ),
                      if (h.convType == 'group') ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 5, vertical: 1),
                          decoration: BoxDecoration(
                            color: AppColors.brand.withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: const Text('群',
                              style: TextStyle(
                                  fontSize: 9.5,
                                  color: AppColors.brand,
                                  fontWeight: FontWeight.w600)),
                        ),
                      ],
                      const Spacer(),
                      Text(TimeFmt.listStamp(m.createdAt),
                          style: const TextStyle(
                              fontSize: 11, color: AppColors.textWeak)),
                    ],
                  ),
                  const SizedBox(height: 3),
                  _highlighted('$prefix${m.content ?? ''}', _kw),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // -------------------------------------------------------------- 好友 Tab

  Widget _friendsBody() {
    if (_friendError != null) {
      return _center(
        Icons.error_outline_rounded,
        '加载好友失败',
        _friendError,
        action: TextButton(onPressed: () => _run(_kw), child: const Text('重试')),
      );
    }
    if (_kw.isEmpty) {
      return _center(Icons.people_alt_rounded, '搜索好友',
          '输入关键词，从你的好友里查找');
    }
    if (_friendsLoading) {
      return const Center(
        child: SizedBox(
            width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    if (_friendHits.isEmpty) {
      return _center(Icons.search_off_rounded, '没有找到「$_kw」的好友',
          '换个关键词试试');
    }
    return ListView.separated(
      padding: const EdgeInsets.only(top: 6, bottom: 12),
      itemCount: _friendHits.length,
      separatorBuilder: (_, __) => const Divider(
          height: 1, indent: 66, color: AppColors.divider),
      itemBuilder: (_, i) => _friendTile(_friendHits[i]),
    );
  }

  Widget _friendTile(Map<String, dynamic> f) {
    final id = (f['id'] as num?)?.toInt();
    final name = (f['nickname'] ?? f['username'] ?? '用户').toString();
    final username = (f['username'] ?? '').toString();
    final avatar = f['avatar'] as String?;
    final opening = _opening == id;
    return InkWell(
      onTap: opening ? null : () => _openFriend(f),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        child: Row(
          children: [
            UserAvatar(name: name, size: 42, radius: 14, imageUrl: avatar),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 3),
                  Text('@$username',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 12.5, color: AppColors.textWeak)),
                ],
              ),
            ),
            if (opening)
              const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2))
            else
              const Icon(Icons.chevron_right_rounded, color: AppColors.textWeak),
          ],
        ),
      ),
    );
  }

  // --------------------------------------------------------------- 公共部件

  /// 把命中的关键词标成品牌色加粗
  Widget _highlighted(String text, String kw) {
    const base = TextStyle(
        fontSize: 13.5, color: AppColors.textSub, height: 1.35);
    if (kw.isEmpty) {
      return Text(text,
          maxLines: 2, overflow: TextOverflow.ellipsis, style: base);
    }
    final spans = <TextSpan>[];
    final lower = text.toLowerCase();
    final target = kw.toLowerCase();
    var start = 0;
    while (true) {
      final i = lower.indexOf(target, start);
      if (i < 0) {
        spans.add(TextSpan(text: text.substring(start)));
        break;
      }
      if (i > start) spans.add(TextSpan(text: text.substring(start, i)));
      spans.add(TextSpan(
        text: text.substring(i, i + kw.length),
        style: const TextStyle(
            color: AppColors.brand, fontWeight: FontWeight.w700),
      ));
      start = i + kw.length;
    }
    return Text.rich(
      TextSpan(style: base, children: spans),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    );
  }

  Widget _center(IconData icon, String title, String? sub,
          {Widget? action}) =>
      Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 40),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon,
                  size: 46, color: AppColors.textWeak.withValues(alpha: 0.55)),
              const SizedBox(height: 12),
              Text(title,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textSub)),
              if (sub != null) ...[
                const SizedBox(height: 6),
                Text(sub,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        fontSize: 12.5, color: AppColors.textWeak)),
              ],
              if (action != null) ...[const SizedBox(height: 10), action],
            ],
          ),
        ),
      );
}
