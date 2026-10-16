// 远程协助 UI（入口 / 控制端画布 / 被控端警示条 / 请求确认）
//
// 【设计原则：安全感优先】
// 远程协助会把自己的屏幕给出去、让别人动自己的键鼠。所以界面上凡是涉及
// "正在被控"的状态，必须是**醒目的、无法忽略的、随时能一键断开的**。
// 宁可丑一点，也不要让用户在"不知道自己正在被控"的状态下做事。

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/gestures.dart'; // 指针事件（Pointer* / kSecondaryButton）
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; // 键盘事件（Key*Event / LogicalKeyboardKey）
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../api.dart';
import '../core/input_inject.dart';
import '../core/remote_assist.dart';
import '../core/remote_history_store.dart';
import '../core/remote_models.dart';
import '../core/theme.dart';
import '../widgets/remote_frame_view.dart';

// ============================================================ 入口页

/// 远程协助首页：发起协助 / 用码连接 / 访问码管理 / 会话记录 / 本地历史收藏
class RemoteHubScreen extends StatefulWidget {
  const RemoteHubScreen({super.key});

  @override
  State<RemoteHubScreen> createState() => _RemoteHubScreenState();
}

class _RemoteHubScreenState extends State<RemoteHubScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 3, vsync: this);
  final _svc = RemoteAssistService.instance;

  @override
  void initState() {
    super.initState();
    _svc.start();
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bgElevated,
        title: const Text('远程协助'),
        bottom: TabBar(
          controller: _tabs,
          labelColor: AppColors.brand,
          unselectedLabelColor: AppColors.textSub,
          indicatorColor: AppColors.brand,
          tabs: const [
            Tab(text: '发起 / 连接'),
            Tab(text: '我的访问码'),
            Tab(text: '协助记录'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: const [_ConnectTab(), _CodesTab(), _HistoryTab()],
      ),
    );
  }
}

// ---------------------------------------------------------------- 连接

class _ConnectTab extends StatefulWidget {
  const _ConnectTab();

  @override
  State<_ConnectTab> createState() => _ConnectTabState();
}

/// 好友显示名：**备注 > 昵称 > 账号**。
/// 通讯录里我给同事起的备注才是"我叫得出口的名字"，昵称次之。
String friendDisplayName(Map<String, dynamic> f) {
  final remark = (f['remark'] ?? '').toString().trim();
  if (remark.isNotEmpty) return remark;
  final nick = (f['nickname'] ?? '').toString().trim();
  if (nick.isNotEmpty) return nick;
  return (f['username'] ?? '').toString();
}

/// 「这台手机能不能被远程操作」的自检卡。
///
/// Android 上远程控制必须开无障碍服务（系统出于安全考虑不给 App 别的口子），
/// 而这个开关只有用户能在系统设置里拨 —— 所以这里不做任何"代开"的企图，
/// 只负责：① 说清现在是开是关；② 给一条直达设置页的路。
///
/// 桌面端不显示：Windows 的注入是 App 自带能力，不需要用户做任何事。
class _HostAbilityCard extends StatelessWidget {
  const _HostAbilityCard({
    required this.ready,
    required this.loading,
    required this.onOpen,
  });

  final bool ready;
  final bool loading;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      // 左侧竖条用颜色区分状态（绿=可用 / 黄=还没开），
      // 不挤 _Card 的通用形状 —— 那个组件被好几处共用，不该为这一处加参数
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(10),
        ),
        clipBehavior: Clip.antiAlias,
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(width: 3, color: ready ? AppColors.online : AppColors.warn),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        Icon(
                          ready
                              ? Icons.check_circle_rounded
                              : Icons.settings_accessibility_rounded,
                          size: 18,
                          color: ready ? AppColors.online : AppColors.warn,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          ready ? '本机可被远程操作' : '本机还不能被人远程操作',
                          style: const TextStyle(
                              fontSize: 14, fontWeight: FontWeight.w600),
                        ),
                        const Spacer(),
                        if (loading)
                          const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                      ]),
                      const SizedBox(height: 8),
                      Text(
                        ready
                            ? '别人协助你时可以直接操作这台手机的屏幕（点击、滑动、打字、按返回键）。'
                            : '手机系统不允许 App 自己制造触摸事件，只能用系统提供的无障碍能力。'
                                '开一次就好，之后不用再管；不开启则别人只能看画面、操作不了。',
                        style:  TextStyle(
                            fontSize: 12.5,
                            color: AppColors.textSub,
                            height: 1.5),
                      ),
                      if (!ready) ...[
                        const SizedBox(height: 10),
                        OutlinedButton.icon(
                          onPressed: onOpen,
                          icon: const Icon(Icons.settings_rounded, size: 17),
                          label: const Text('去开启（设置 → 无障碍）'),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ConnectTabState extends State<_ConnectTab> with WidgetsBindingObserver {
  final _code = TextEditingController();
  final _target = TextEditingController();
  String? _msg;
  bool _busy = false;

  /// 本机"能不能被远程操作"的能力探针（只有 Android 需要真的问一次）
  final InputInjector _injector = createInputInjector();
  bool _hostReady = false;
  bool _hostReadyLoading = true;

  /// 远程协助服务单例（历史/收藏要听 phase 变化，会话一结束就刷新列表）。
  final RemoteAssistService _svc = RemoteAssistService.instance;

  /// 通讯录好友（选人来发起协助）。
  ///
  /// 🔴 之前这一页只能手填**数字账号 ID** —— 而 ID 在界面上根本不显示，
  ///    员工得先去别处查出自己的 ID 再回来敲，等于"功能有、没人用得起"。
  ///    工作模式下同事本来就已经互为好友，直接从通讯录里点一个人就够了。
  List<Map<String, dynamic>> _friends = const [];
  bool _friendsLoading = false;
  String? _friendsErr;
  int? _pickedId;
  String? _pickedName;

  /// 本地历史 + 收藏（龙哥 2026-10-16：「历史记录和收藏夹，方便下次发起连接」）。
  /// 只记我发起的连接；点一下直接按原方式再发起（同事→邀请，码→兑换）。
  List<RemoteHistoryItem> _hist = const [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadFriends();
    _loadHostAbility();
    _loadHistory();
    // 会话一结束就刷新历史：刚连过的那次要立刻出现在"最近连接"里，
    // 否则用户回首页看到的还是旧列表，会以为"根本没记上"。
    _svc.phase.addListener(_onPhaseChanged);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _svc.phase.removeListener(_onPhaseChanged);
    _code.dispose();
    _target.dispose();
    super.dispose();
  }

  void _onPhaseChanged() {
    final p = _svc.phase.value;
    if (p == RemotePhase.idle || p == RemotePhase.ended) _loadHistory();
  }

  /// 从系统设置页切回来时再问一次：用户可能在那里刚把开关拨开，
  /// 不问的话这一页会一直显示"还没开"，得杀进程重进才刷新。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_loadHostAbility());
  }

  Future<void> _loadHostAbility() async {
    if (WebRTC.platformIsDesktop) {
      // Windows 的注入能力是自带的（Win32 SendInput），不需要用户开任何开关
      if (mounted) setState(() { _hostReady = true; _hostReadyLoading = false; });
      return;
    }
    await _injector.refreshAbility();
    if (!mounted) return;
    setState(() {
      _hostReady = _injector.supported;
      _hostReadyLoading = false;
    });
  }

  Future<void> _openHostSettings() async {
    final ok = await _injector.openAccessibilitySettings();
    if (!mounted || ok) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('这台手机没法直接打开无障碍设置页，请到「设置 → 无障碍」'
            '里找到「小智IM 远程协助」手动开启'),
      ),
    );
  }

  Future<void> _loadFriends() async {
    setState(() {
      _friendsLoading = true;
      _friendsErr = null;
    });
    try {
      final r = await ImApi().friends();
      final list = (r['friends'] as List? ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      if (!mounted) return;
      setState(() {
        _friends = list;
        _friendsLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _friendsLoading = false;
        _friendsErr = e.toString();
      });
    }
  }

  Future<void> _pickFriend() async {
    if (_friends.isEmpty && !_friendsLoading) await _loadFriends();
    if (!mounted) return;
    final picked = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.bgElevated,
      builder: (ctx) => _FriendPickerSheet(friends: _friends),
    );
    if (!mounted || picked == null) return;
    setState(() {
      _pickedId = (picked['id'] is int) ? picked['id'] as int : int.tryParse('${picked['id']}');
      _pickedName = friendDisplayName(picked);
      _target.clear(); // 选了人就别再留着旧的手动 ID，避免"到底发给谁"说不清
      _msg = null;
    });
  }

  Future<void> _redeem() async {
    final c = _code.text.trim();
    if (c.isEmpty) {
      setState(() => _msg = '请输入对方给你的 9 位访问码');
      return;
    }
    setState(() { _busy = true; _msg = null; });
    final err = await RemoteAssistService.instance.redeem(c);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (err != null) _msg = err;
    });
    if (err == null && mounted) await _openControl();
  }

  Future<void> _invite() async {
    // 选了人就以选的为准；没选才退回手填 ID（管理员连非好友的机器时用）
    final id = _pickedId ?? int.tryParse(_target.text.trim());
    if (id == null) {
      setState(() => _msg = '先从通讯录里选一位同事（或填写对方账号 ID）');
      return;
    }
    final err = await RemoteAssistService.instance.requestFrom(id);
    if (!mounted) return;
    if (err != null) {
      setState(() => _msg = err);
      return;
    }
    setState(() => _msg = '已发起请求，等待 ${_pickedName ?? '对方'} 同意…');
  }

  Future<void> _openControl() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const RemoteControlScreen()),
    );
  }

  // ---- 本地历史 + 收藏 ----

  Future<void> _loadHistory() async {
    final list = await RemoteHistoryStore.I.list();
    if (!mounted) return;
    setState(() => _hist = list);
  }

  /// 一键重连：同事走邀请、访问码走兑换，和手动操作的链路完全一致
  /// （不另开一条"快捷连接"的旁路 —— 旁路迟早和主链路漂移）。
  Future<void> _reconnectHistory(RemoteHistoryItem h) async {
    if (h.isCode) {
      _code.text = h.code;
      await _redeem();
      return;
    }
    if (h.peerId <= 0) {
      setState(() => _msg = '这条记录没有对方账号，请从通讯录重新选人');
      return;
    }
    setState(() {
      _pickedId = h.peerId;
      _pickedName = h.title;
      _target.clear();
      _msg = null;
    });
    await _invite();
  }

  Future<void> _toggleFavHistory(RemoteHistoryItem h) async {
    await RemoteHistoryStore.I.setFav(h.id, !h.fav);
    await _loadHistory();
  }

  /// 「添加收藏」—— 手动收一个对象，不需要先连过一次。
  ///
  /// 校验刻意做在校验**之后**才落库：访问码服务端固定 9 位（server/src/remote.js
  /// 的 CODE_LEN），长度不对就是输错了。存进去了也连不上，不如当场说清楚。
  Future<void> _addFavorite() async {
    final r = await showDialog<({String name, String id, String code})>(
      context: context,
      builder: (_) => const _AddFavoriteDialog(),
    );
    if (r == null || !mounted) return;

    final name = r.name.trim();
    final code = r.code.trim();
    final isCode = code.isNotEmpty;
    final peerId = isCode ? 0 : (int.tryParse(r.id.trim()) ?? 0);

    if (isCode) {
      if (code.length != 9) {
        setState(() => _msg = '访问码是 9 位数字，请检查后再收藏');
        return;
      }
    } else if (peerId <= 0) {
      setState(() => _msg = '账号 ID 必须是数字；无人值守的机器请改选「无人值守访问码」');
      return;
    }

    final ok = await RemoteHistoryStore.I.addFavorite(
      peerId: peerId,
      peerName: name.isNotEmpty ? name : (isCode ? '无人值守机器' : '同事 $peerId'),
      code: isCode ? code : '',
      kind: isCode ? 'code' : 'friend',
    );
    await _loadHistory();
    if (!mounted) return;
    setState(() => _msg = ok ? '已加入收藏，点一下就能发起' : '加入收藏失败（本机存储不可用）');
  }

  Future<void> _deleteHistory(RemoteHistoryItem h) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.bgElevated,
        title: const Text('删除这条记录？'),
        content: Text(
          '只删本机这条历史，不影响服务端的协助记录。'
          '${h.fav ? '这条是收藏，删了要重新加回来。' : ''}',
          style: TextStyle(fontSize: 13.5, color: AppColors.textSub, height: 1.5),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('删除', style: TextStyle(color: AppColors.danger)),
          ),
        ],
      ),
    );
    if (yes != true) return;
    await RemoteHistoryStore.I.remove(h.id);
    await _loadHistory();
  }

  Future<void> _clearHistory() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.bgElevated,
        title: const Text('清空历史记录？'),
        content: Text(
          '普通记录全部清掉，收藏的会保留。'
          '只影响本机，服务端的协助记录不受影响。',
          style: TextStyle(fontSize: 13.5, color: AppColors.textSub, height: 1.5),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('清空', style: TextStyle(color: AppColors.danger)),
          ),
        ],
      ),
    );
    if (yes != true) return;
    await RemoteHistoryStore.I.clear();
    await _loadHistory();
  }

  @override
  Widget build(BuildContext context) {
    final svc = RemoteAssistService.instance;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // 被控能力自检。
        // 🔴 这一块必须摆在**最上面**：以前只有别人发起请求时才会提到它，
        //    而那一刻往往已经在连线流程里了 —— 用户要么手忙脚乱地去设置里翻，
        //    要么干脆拒绝掉这次协助。提前摆出来，他可以在没人找他的时候就开好。
        if (!WebRTC.platformIsDesktop)
          _HostAbilityCard(
            ready: _hostReady,
            loading: _hostReadyLoading,
            onOpen: _openHostSettings,
          ),
        _Card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('用访问码连接', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
               Text(
                '对方离线也能连（无人值守）。连上后对方仍有 10 秒可以拒绝，'
                '不会在你不知道的情况下直接被控。',
                style: TextStyle(fontSize: 12.5, color: AppColors.textSub, height: 1.5),
              ),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(
                  child: TextField(
                    controller: _code,
                    keyboardType: TextInputType.number,
                    maxLength: 9,
                    style: const TextStyle(letterSpacing: 3, fontSize: 17),
                    decoration: const InputDecoration(
                      hintText: '9 位数字',
                      counterText: '',
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                FilledButton(
                  onPressed: _busy ? null : _redeem,
                  child: _busy ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('连接'),
                ),
              ]),
            ],
          ),
        ),
        const SizedBox(height: 12),
        _Card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('请求对方协助', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
               Text(
                '从通讯录里选一位同事，对方点「同意」就开始。适合临时帮同事处理问题。',
                style: TextStyle(fontSize: 12.5, color: AppColors.textSub, height: 1.5),
              ),
              const SizedBox(height: 12),
              // 选人：点一下弹通讯录，选完这里显示名字
              InkWell(
                onTap: _pickFriend,
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                  decoration: BoxDecoration(
                    border: Border.all(color: AppColors.border),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Icon(_pickedId == null
                          ? Icons.person_add_alt_1_rounded
                          : Icons.person_rounded,
                          size: 20, color: AppColors.textSub),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          _pickedName ?? '从通讯录选择同事…',
                          style: TextStyle(
                            fontSize: 15,
                            color: _pickedName == null
                                ? AppColors.textWeak
                                : AppColors.text,
                          ),
                        ),
                      ),
                      if (_friendsLoading)
                        const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      else
                         Icon(Icons.chevron_right_rounded,
                            size: 20, color: AppColors.textWeak),
                    ],
                  ),
                ),
              ),
              if (_friendsErr != null) ...[
                const SizedBox(height: 6),
                Row(children: [
                  Expanded(
                    child: Text('通讯录加载失败：$_friendsErr',
                        style:  TextStyle(
                            fontSize: 11.5, color: AppColors.danger)),
                  ),
                  TextButton(onPressed: _loadFriends, child: const Text('重试')),
                ]),
              ],
              const SizedBox(height: 10),
              Row(children: [
                Expanded(
                  child: TextField(
                    controller: _target,
                    keyboardType: TextInputType.number,
                    style: const TextStyle(fontSize: 15),
                    decoration: const InputDecoration(
                        hintText: '或直接填账号 ID（非好友时用）', isDense: true),
                  ),
                ),
                const SizedBox(width: 10),
                FilledButton(onPressed: _invite, child: const Text('发起')),
              ]),
              const SizedBox(height: 8),
               Text(
                '对方必须在线，并在弹出提示里点「同意」才会开始 —— 不会在你不知道的情况下被控。',
                style: TextStyle(fontSize: 11.5, color: AppColors.textWeak),
              ),
            ],
          ),
        ),
        // 收藏：**始终渲染**（空的时候给一句提示 + 一个「添加」按钮）。
        // 理由见 _FavoritesSection 的注释 —— 收藏不能依赖"连过一次"。
        const SizedBox(height: 16),
        _FavoritesSection(
          items: _hist.where((h) => h.fav).toList(),
          onReconnect: _reconnectHistory,
          onToggleFav: _toggleFavHistory,
          onDelete: _deleteHistory,
          onAdd: _addFavorite,
        ),
        // 本地最近连接（收藏的已经在上面列过了，这里不重复）：
        // 空列表时整块不渲染 —— 新用户不该一进来先看一块"你没有历史"。
        if (_hist.any((h) => !h.fav)) ...[
          const SizedBox(height: 16),
          _HistorySection(
            items: _hist.where((h) => !h.fav).toList(),
            onReconnect: _reconnectHistory,
            onToggleFav: _toggleFavHistory,
            onDelete: _deleteHistory,
            onClear: _clearHistory,
          ),
        ],
        if (_msg != null) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(_msg!, style: TextStyle(fontSize: 12.5, color: AppColors.brand2)),
          ),
        ],
        const SizedBox(height: 16),
        // 会话进行中时给个入口，别让用户以为断了
        ValueListenableBuilder<RemotePhase>(
          valueListenable: svc.phase,
          builder: (_, p, __) {
            if (p == RemotePhase.idle || p == RemotePhase.ended) return const SizedBox.shrink();
            return ListTile(
              tileColor: AppColors.surface,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              leading: Icon(Icons.desktop_windows_rounded, color: AppColors.brand),
              title: const Text('返回进行中的会话'),
              // UU-a：重连中时副标题直接说"在重连"，别让用户以为断了就走了
              subtitle: ValueListenableBuilder<bool>(
                valueListenable: svc.reconnecting,
                builder: (_, rc, __) =>
                    Text(rc ? '网络波动，正在自动重连…' : _phaseText(p)),
              ),
              trailing: TextButton(
                onPressed: () => RemoteAssistService.instance.hangUp(),
                child: Text('结束', style: TextStyle(color: AppColors.danger)),
              ),
              onTap: _openControl,
            );
          },
        ),
      ],
    );
  }
}

/// 选同事的半屏列表（带搜索）。
///
/// 通讯录可能有几十上百人，没有搜索就得一路划到底 —— 而"找个人"这件事
/// 用户心里是有明确目标的，搜索框比分页/分组有用得多。
class _FriendPickerSheet extends StatefulWidget {
  final List<Map<String, dynamic>> friends;
  const _FriendPickerSheet({required this.friends});

  @override
  State<_FriendPickerSheet> createState() => _FriendPickerSheetState();
}

class _FriendPickerSheetState extends State<_FriendPickerSheet> {
  final _q = TextEditingController();
  String _kw = '';

  @override
  void initState() {
    super.initState();
    _q.addListener(() => setState(() => _kw = _q.text.trim().toLowerCase()));
  }

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final all = widget.friends;
    final shown = _kw.isEmpty
        ? all
        : all.where((f) {
            final n = friendDisplayName(f).toLowerCase();
            final u = (f['username'] ?? '').toString().toLowerCase();
            return n.contains(_kw) || u.contains(_kw);
          }).toList();

    return SafeArea(
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.75,
        child: Column(
          children: [
            const SizedBox(height: 10),
            const Text('选择同事',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: TextField(
                controller: _q,
                style: const TextStyle(fontSize: 14),
                decoration: InputDecoration(
                  hintText: '搜名字 / 账号',
                  prefixIcon: const Icon(Icons.search, size: 20),
                  isDense: true,
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(AppRadii.md)),
                  enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(AppRadii.md)),
                  focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(AppRadii.md)),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                ),
              ),
            ),
            const SizedBox(height: 6),
            if (all.isEmpty)
               Padding(
                padding: EdgeInsets.all(28),
                child: Text('通讯录里还没有好友',
                    style: TextStyle(fontSize: 13, color: AppColors.textSub)),
              )
            else if (shown.isEmpty)
               Padding(
                padding: EdgeInsets.all(28),
                child: Text('没找到匹配的人',
                    style: TextStyle(fontSize: 13, color: AppColors.textSub)),
              )
            else
              Expanded(
                child: ListView.separated(
                  itemCount: shown.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    final f = shown[i];
                    final name = friendDisplayName(f);
                    final uname = (f['username'] ?? '').toString();
                    return ListTile(
                      leading: CircleAvatar(
                        radius: 18,
                        backgroundColor: AppColors.brand.withValues(alpha: 0.14),
                        child: Text(
                          name.isEmpty ? '?' : name.characters.first,
                          style:  TextStyle(
                              fontSize: 15, color: AppColors.brand),
                        ),
                      ),
                      title: Text(name, style: const TextStyle(fontSize: 14.5)),
                      subtitle: uname.isEmpty || uname == name
                          ? null
                          : Text(uname,
                              style:  TextStyle(
                                  fontSize: 12, color: AppColors.textWeak)),
                      onTap: () => Navigator.of(context).pop(f),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 本地历史 + 收藏区块（龙哥 2026-10-16：「历史记录和收藏夹，方便下次发起连接」）。
///
/// 交互约定（写在区块里，用户不用教）：
///   · 点一行 = 用原方式再发起（同事→邀请，访问码→兑换）；
///   · ★ = 收藏/取消，收藏永远置顶；
///   · 长按 = 删这条（有确认，防误触）；
///   · 右上角"清空"只清普通记录，收藏保留。
/// 「我的收藏」区 —— **始终渲染，空也不藏**。
///
/// 🔴 为什么必须独立于"最近连接"（龙哥 2026-10-16 真机反馈"我要的收藏夹没有添加"）：
///    原来"收藏"只是历史列表里的一个 ★ 置顶，而历史列表在**空的时候整块不渲染**。
///    于是从没成功连过的人（当时正在排查黑屏，一次都没连上）根本看不到收藏夹 ——
///    连"点一下星号"这个动作都无处可点。可收藏的意义本来就是给
///    "我还没连上 / 以后要常用"准备的，它不能依赖"已经连过一次"这个前提。
///    现在这里永远有一个入口：空的时候直接给「添加」按钮。
class _FavoritesSection extends StatelessWidget {
  const _FavoritesSection({
    required this.items,
    required this.onReconnect,
    required this.onToggleFav,
    required this.onDelete,
    required this.onAdd,
  });

  final List<RemoteHistoryItem> items;
  final ValueChanged<RemoteHistoryItem> onReconnect;
  final ValueChanged<RemoteHistoryItem> onToggleFav;
  final ValueChanged<RemoteHistoryItem> onDelete;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Icon(Icons.star_rounded, size: 17, color: AppColors.warn),
          const SizedBox(width: 6),
          const Text('我的收藏',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
          const SizedBox(width: 8),
          Text('只存在本机',
              style: TextStyle(fontSize: 11, color: AppColors.textWeak)),
          const Spacer(),
          TextButton(
            onPressed: onAdd,
            child: Text('添加',
                style: TextStyle(fontSize: 12, color: AppColors.brand2)),
          ),
        ]),
        if (items.isEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('还没有收藏',
                    style: TextStyle(fontSize: 13.5, color: AppColors.textSub)),
                const SizedBox(height: 4),
                Text(
                  '把常用的同事账号、或无人值守的访问码收藏起来，'
                  '下次点一下就能发起 —— 不用翻记录，也不用重新输码。',
                  style: TextStyle(
                      fontSize: 11.5, color: AppColors.textWeak, height: 1.5),
                ),
              ],
            ),
          )
        else ...[
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text('点一下直接发起 · ☆ 取消收藏 · 长按删除',
                style: TextStyle(fontSize: 11.5, color: AppColors.textWeak)),
          ),
          for (final h in items)
            _RemotePeerTile(
              item: h,
              onReconnect: onReconnect,
              onToggleFav: onToggleFav,
              onDelete: onDelete,
            ),
        ],
      ],
    );
  }
}

class _HistorySection extends StatelessWidget {
  const _HistorySection({
    required this.items,
    required this.onReconnect,
    required this.onToggleFav,
    required this.onDelete,
    required this.onClear,
  });

  final List<RemoteHistoryItem> items;
  final ValueChanged<RemoteHistoryItem> onReconnect;
  final ValueChanged<RemoteHistoryItem> onToggleFav;
  final ValueChanged<RemoteHistoryItem> onDelete;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          const Text('最近连接',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
          const SizedBox(width: 8),
          Text('只存在本机',
              style: TextStyle(fontSize: 11, color: AppColors.textWeak)),
          const Spacer(),
          TextButton(
            onPressed: onClear,
            child: Text('清空',
                style: TextStyle(fontSize: 12, color: AppColors.textSub)),
          ),
        ]),
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            '点一下直接再发起 · ★ 收藏（会移到上面的收藏区）· 长按删除',
            style: TextStyle(fontSize: 11.5, color: AppColors.textWeak),
          ),
        ),
        for (final h in items)
          _RemotePeerTile(
            item: h,
            onReconnect: onReconnect,
            onToggleFav: onToggleFav,
            onDelete: onDelete,
          ),
      ],
    );
  }
}

/// 收藏 / 最近连接列表里的一行。两个区**共用**这个件 ——
/// 同一条记录在两处的呈现必须一致，否则用户会以为它们是两种东西。
class _RemotePeerTile extends StatelessWidget {
  const _RemotePeerTile({
    required this.item,
    required this.onReconnect,
    required this.onToggleFav,
    required this.onDelete,
  });

  final RemoteHistoryItem item;
  final ValueChanged<RemoteHistoryItem> onReconnect;
  final ValueChanged<RemoteHistoryItem> onToggleFav;
  final ValueChanged<RemoteHistoryItem> onDelete;

  @override
  Widget build(BuildContext context) {
    final h = item;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(10),
      ),
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        leading: CircleAvatar(
          radius: 18,
          backgroundColor: AppColors.brand.withValues(alpha: 0.14),
          child: Text(
            h.title.characters.first,
            style: TextStyle(fontSize: 15, color: AppColors.brand),
          ),
        ),
        title: Row(children: [
          Flexible(
            child: Text(
              h.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 14.5),
            ),
          ),
          if (h.isCode) ...[
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: AppColors.warn.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text('无人值守',
                  style: TextStyle(fontSize: 10.5, color: AppColors.warn)),
            ),
          ],
        ]),
        subtitle: Text(_subtitle(h), style: const TextStyle(fontSize: 12)),
        trailing: IconButton(
          icon: Icon(
            h.fav ? Icons.star_rounded : Icons.star_border_rounded,
            color: h.fav ? AppColors.warn : AppColors.textWeak,
          ),
          tooltip: h.fav ? '取消收藏' : '收藏',
          onPressed: () => onToggleFav(h),
        ),
        onTap: () => onReconnect(h),
        onLongPress: () => onDelete(h),
      ),
    );
  }

  /// ⚠️ times == 0 是「手动加进来的收藏，还一次都没连过」。
  ///    这时**不能**显示"连过 0 次 · 刚刚" —— 那看着像刚刚才连上过，
  ///    会让人以为连成功了（而实际上可能正是连不上的那条）。
  static String _subtitle(RemoteHistoryItem h) {
    final what = h.isCode ? '访问码 ${h.code}' : '同事';
    if (h.times <= 0) return '$what · 还没连过';
    return '$what · 连过 ${h.times} 次 · ${remoteWhenText(h.lastAt)}';
  }
}

/// 「添加收藏」弹窗：手动收一个对象，**不需要先连过一次**。
///
/// 为什么分成「同事账号 / 无人值守访问码」两个选项而不是一个输入框猜：
/// 账号 ID 是数字、访问码也是 9 位数字，靠长度猜必然会在某个边界猜错，
/// 而猜错的表象是"收藏点了发起没反应"（存进去的 peerId 永远匹配不上），
/// 极难排查。让用户明确选一次，比事后猜便宜得多。
class _AddFavoriteDialog extends StatefulWidget {
  const _AddFavoriteDialog();

  @override
  State<_AddFavoriteDialog> createState() => _AddFavoriteDialogState();
}

class _AddFavoriteDialogState extends State<_AddFavoriteDialog> {
  final _name = TextEditingController();
  final _value = TextEditingController();
  bool _isCode = false;

  @override
  void dispose() {
    _name.dispose();
    _value.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.bgElevated,
      title: const Text('添加收藏'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _name,
            style: const TextStyle(fontSize: 15),
            decoration: const InputDecoration(
                labelText: '备注名（可空）', isDense: true),
          ),
          const SizedBox(height: 14),
          Row(children: [
            ChoiceChip(
              label: const Text('同事账号'),
              selected: !_isCode,
              onSelected: (_) => setState(() => _isCode = false),
            ),
            const SizedBox(width: 8),
            ChoiceChip(
              label: const Text('无人值守访问码'),
              selected: _isCode,
              onSelected: (_) => setState(() => _isCode = true),
            ),
          ]),
          const SizedBox(height: 12),
          TextField(
            controller: _value,
            keyboardType: TextInputType.number,
            style: const TextStyle(fontSize: 15),
            decoration: InputDecoration(
              labelText: _isCode ? '访问码（9 位）' : '账号 ID',
              hintText: _isCode ? '例如 123456789' : '例如 10086',
              isDense: true,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            _isCode
                ? '收藏后点一下就能直接向那台机器发起协助，不用每次输码。'
                : '对方必须在线，并在弹出提示里点「同意」才会开始。',
            style: TextStyle(
                fontSize: 11.5, color: AppColors.textWeak, height: 1.5),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, (
            name: _name.text,
            id: _isCode ? '' : _value.text,
            code: _isCode ? _value.text : '',
          )),
          child: const Text('保存'),
        ),
      ],
    );
  }
}

String _phaseText(RemotePhase p) {
  switch (p) {
    case RemotePhase.idle:
      return '空闲';
    case RemotePhase.requesting:
      return '等待对方同意…';
    case RemotePhase.connecting:
      return '正在建立连接…';
    case RemotePhase.active:
      return '会话进行中';
    case RemotePhase.ended:
      return '已结束';
  }
}

/// UU-c 画质档位文案。0=原画不限制；数字越大越糊但越省带宽
/// （RtcVideoDegrader 的 tiers，网络差时自动逐级降）。
String remoteQualityText(int level) {
  switch (level) {
    case 0:
      return '画质 · 原画';
    case 1:
      return '画质 · 高清';
    case 2:
      return '画质 · 标清';
    case 3:
      return '画质 · 流畅';
    default:
      return '画质 · 极速';
  }
}

// ---------------------------------------------------------------- 访问码

class _CodesTab extends StatefulWidget {
  const _CodesTab();

  @override
  State<_CodesTab> createState() => _CodesTabState();
}

class _CodesTabState extends State<_CodesTab> {
  List<RemoteCode> _items = [];
  bool _loading = true;
  String? _err;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _err = null; });
    try {
      final list = await ImApi().remoteCodes();
      if (!mounted) return;
      setState(() { _items = list; _loading = false; });
    } catch (e) {
      if (!mounted) return;
      setState(() { _err = '$e'; _loading = false; });
    }
  }

  Future<void> _create() async {
    final label = await showDialog<String>(
      context: context,
      builder: (ctx) => _NewCodeDialog(),
    );
    if (label == null) return;
    try {
      final r = await ImApi().createRemoteCode(label: label);
      if (!mounted) return;
      final code = r['code']?.toString() ?? '';
      await showDialog<void>(
        context: context,
        builder: (_) => _CodeOnceDialog(code: code),
      );
      await _load();
    } catch (e) {
      if (!mounted) return;
      setState(() => _err = '生成失败：$e');
    }
  }

  Future<void> _revoke(RemoteCode c) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.bgElevated,
        title: const Text('吊销这个访问码？'),
        content:  Text(
          '吊销后立刻失效，之前拿到这个码的人将无法连接。'
          '如果你怀疑码泄漏了，就吊销它。',
          style: TextStyle(fontSize: 13.5, color: AppColors.textSub, height: 1.5),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('吊销', style: TextStyle(color: AppColors.danger)),
          ),
        ],
      ),
    );
    if (yes != true) return;
    await ImApi().revokeRemoteCode(c.id);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_err != null) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(_err!, style: TextStyle(color: AppColors.danger, fontSize: 13)),
          const SizedBox(height: 10),
          OutlinedButton(onPressed: _load, child: const Text('重试')),
        ]),
      );
    }
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
        child: Row(children: [
           Expanded(
            child: Text(
              '访问码是「别人能在你不在场时连你电脑」的钥匙。'
              '只在你确实需要长期值守时才开。',
              style: TextStyle(fontSize: 12, color: AppColors.textSub, height: 1.5),
            ),
          ),
          const SizedBox(width: 10),
          FilledButton.icon(
            onPressed: _create,
            icon: const Icon(Icons.add_rounded, size: 17),
            label: const Text('生成'),
          ),
        ]),
      ),
      Expanded(
        child: _items.isEmpty
            ?  Center(
                child: Text('还没有访问码',
                    style: TextStyle(color: AppColors.textWeak, fontSize: 13)),
              )
            : RefreshIndicator(
                onRefresh: _load,
                child: ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: _items.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (_, i) {
                    final c = _items[i];
                    final dead = c.expired || c.usedUp;
                    return Opacity(
                      opacity: dead ? 0.45 : 1,
                      child: ListTile(
                        tileColor: AppColors.surface,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        leading: Icon(
                          dead ? Icons.block_rounded : Icons.vpn_key_rounded,
                          color: dead ? AppColors.textWeak : AppColors.brand,
                        ),
                        title: Text(c.label.isEmpty ? '未命名' : c.label),
                        subtitle: Text(
                          '${c.singleUse ? '一次性' : '长期'}'
                          '${c.expiresAt != null ? ' · 有有效期' : ''}'
                          ' · 已用 ${c.useCount} 次'
                          '${dead ? ' · 已失效' : ''}',
                          style: const TextStyle(fontSize: 12),
                        ),
                        trailing: IconButton(
                          icon: Icon(Icons.delete_outline_rounded, color: AppColors.danger),
                          tooltip: '吊销',
                          onPressed: () => _revoke(c),
                        ),
                      ),
                    );
                  },
                ),
              ),
      ),
    ]);
  }
}

/// 新建访问码
class _NewCodeDialog extends StatefulWidget {
  @override
  State<_NewCodeDialog> createState() => _NewCodeDialogState();
}

class _NewCodeDialogState extends State<_NewCodeDialog> {
  final _label = TextEditingController();
  bool _single = false;
  int _ttl = 0; // 分钟，0 = 长期

  @override
  void dispose() {
    _label.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.bgElevated,
      title: const Text('新建访问码'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _label,
            decoration: const InputDecoration(
              labelText: '备注（给自己认的）',
              hintText: '如：门店前台那台',
              isDense: true,
            ),
          ),
          const SizedBox(height: 6),
          SwitchListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: const Text('一次性（用完自动作废）', style: TextStyle(fontSize: 13.5)),
            value: _single,
            onChanged: (v) => setState(() => _single = v),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            children: [
              for (final opt in const <(int, String)>[(0, '长期'), (60, '1 小时'), (1440, '24 小时'),
                    (10080, '7 天')])
                ChoiceChip(
                  label: Text(opt.$2, style: const TextStyle(fontSize: 12)),
                  selected: _ttl == opt.$1,
                  onSelected: (_) => setState(() => _ttl = opt.$1),
                ),
            ],
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        TextButton(
          onPressed: () => Navigator.pop(context, _label.text.trim()),
          child: const Text('生成'),
        ),
      ],
    );
  }
}

/// 明文只显示一次的弹窗 —— 关掉就再也找不回来了，必须说清楚
class _CodeOnceDialog extends StatelessWidget {
  const _CodeOnceDialog({required this.code});
  final String code;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.bgElevated,
      title: const Text('请把这个码发给对方'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 16),
            decoration: BoxDecoration(
              color: AppColors.surfaceHi,
              borderRadius: BorderRadius.circular(10),
            ),
            child: SelectableText(
              code,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 30, letterSpacing: 8, fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(height: 12),
           Text(
            '⚠️ 关掉这个窗口之后就查不到了（服务端只存哈希，不存明文）。\n'
            '现在没记下的话，只能吊销它重新生成一个。',
            style: TextStyle(fontSize: 12.5, color: AppColors.warn, height: 1.6),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('我记下了')),
      ],
    );
  }
}

// ---------------------------------------------------------------- 记录

class _HistoryTab extends StatefulWidget {
  const _HistoryTab();

  @override
  State<_HistoryTab> createState() => _HistoryTabState();
}

class _HistoryTabState extends State<_HistoryTab> {
  List<RemoteSessionRecord> _items = [];
  bool _loading = true;
  String? _err;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _err = null; });
    try {
      final list = await ImApi().remoteSessions();
      if (!mounted) return;
      setState(() { _items = list; _loading = false; });
    } catch (e) {
      if (!mounted) return;
      setState(() { _err = '$e'; _loading = false; });
    }
  }

  String _fmt(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${d.year}-${'${d.month}'.padLeft(2, '0')}-${'${d.day}'.padLeft(2, '0')} '
        '${'${d.hour}'.padLeft(2, '0')}:${'${d.minute}'.padLeft(2, '0')}';
  }

  String _dur(int sec) {
    if (sec < 60) return '$sec 秒';
    final m = sec ~/ 60;
    final s = sec % 60;
    if (m < 60) return s == 0 ? '$m 分钟' : '$m 分 $s 秒';
    return '${m ~/ 60} 小时 ${m % 60} 分';
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_err != null) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(_err!, style: TextStyle(color: AppColors.danger, fontSize: 13)),
          const SizedBox(height: 10),
          OutlinedButton(onPressed: _load, child: const Text('重试')),
        ]),
      );
    }
    if (_items.isEmpty) {
      return Center(child: Text('还没有远程协助记录', style: TextStyle(color: AppColors.textWeak)));
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.all(16),
        itemCount: _items.length,
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        itemBuilder: (_, i) {
          final r = _items[i];
          final host = r.role == RemoteRole.host;
          return ListTile(
            tileColor: AppColors.surface,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            leading: Icon(
              host ? Icons.screen_share_rounded : Icons.mouse_rounded,
              color: host ? AppColors.warn : AppColors.brand,
            ),
            title: Text(host ? '${r.peerName} 协助了你' : '你协助了 ${r.peerName}'),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 3),
                Text(_fmt(r.createdAt), style: const TextStyle(fontSize: 12)),
                if (r.durationSec > 0)
                  Text('时长 ${_dur(r.durationSec)}'
                      '${r.endReason.isNotEmpty ? ' · ${remoteEndReasonText(r.endReason)}' : ''}',
                      style: const TextStyle(fontSize: 12)),
              ],
            ),
            isThreeLine: r.durationSec > 0,
            trailing: Text(
              r.mode == 'unattended' ? '无人值守' : '有人值守',
              style: TextStyle(fontSize: 11.5, color: AppColors.textWeak),
            ),
          );
        },
      ),
    );
  }
}

// ============================================================ 控制端画布

/// 控制端界面：显示对方屏幕 + 把本地鼠标键盘事件转成指令发出去
/// 把一个 Flutter 按键事件翻译成要发给被控端的 RemoteKey。
///
/// 【为什么单独抽成纯函数】
/// 这段是整个远程协助里最容易出错、又最难靠肉眼验证的部分：
/// 少映射一个修饰键的表象不是"报错"，而是"对方电脑上按不出 Ctrl+C"，
/// 用户只会觉得软件难用，且极难复现。抽出来才能单测，才有改动的兜底。
RemoteKey? remoteKeyOf(LogicalKeyboardKey logical, String? character) {
  if (logical == LogicalKeyboardKey.tab) return const RemoteKey(vk: Vk.tab);
  if (logical == LogicalKeyboardKey.backspace) return const RemoteKey(vk: Vk.backspace);
  if (logical == LogicalKeyboardKey.enter) return const RemoteKey(vk: Vk.enter);
  if (logical == LogicalKeyboardKey.escape) return const RemoteKey(vk: Vk.escape);
  if (logical == LogicalKeyboardKey.arrowUp) return const RemoteKey(vk: Vk.up, extended: true);
  if (logical == LogicalKeyboardKey.arrowDown) return const RemoteKey(vk: Vk.down, extended: true);
  if (logical == LogicalKeyboardKey.arrowLeft) return const RemoteKey(vk: Vk.left, extended: true);
  if (logical == LogicalKeyboardKey.arrowRight) return const RemoteKey(vk: Vk.right, extended: true);
  if (logical == LogicalKeyboardKey.home) return const RemoteKey(vk: Vk.home, extended: true);
  if (logical == LogicalKeyboardKey.end) return const RemoteKey(vk: Vk.end, extended: true);
  if (logical == LogicalKeyboardKey.pageUp) return const RemoteKey(vk: Vk.pageUp, extended: true);
  if (logical == LogicalKeyboardKey.pageDown) return const RemoteKey(vk: Vk.pageDown, extended: true);
  if (logical == LogicalKeyboardKey.delete) return const RemoteKey(vk: Vk.delete, extended: true);
  if (logical == LogicalKeyboardKey.insert) return const RemoteKey(vk: Vk.insert, extended: true);

  // ---- 修饰键 ----
  // ⚠️ 这一组**绝对不能少**。曾经漏掉整个组的后果是：在被控电脑上做不出
  // 任何组合键（Ctrl+C / Ctrl+V / Alt+Tab / Win+D 全废），而这是个靠
  // 看画面很难定位的问题 —— 鼠标、打字都正常，就是复制粘贴不行。
  // 组合键是"序列"不是"单键"：这里把修饰键作为独立的按下/抬起事件发出去，
  // 被控端按原顺序注入，Ctrl+C 自然就成立。
  if (logical == LogicalKeyboardKey.controlLeft) {
    return const RemoteKey(vk: Vk.control);
  }
  if (logical == LogicalKeyboardKey.controlRight) {
    return const RemoteKey(vk: Vk.control, extended: true);
  }
  if (logical == LogicalKeyboardKey.shiftLeft) {
    return const RemoteKey(vk: Vk.shift);
  }
  if (logical == LogicalKeyboardKey.shiftRight) {
    return const RemoteKey(vk: Vk.shift, extended: true);
  }
  if (logical == LogicalKeyboardKey.altLeft) {
    return const RemoteKey(vk: Vk.alt);
  }
  if (logical == LogicalKeyboardKey.altRight) {
    return const RemoteKey(vk: Vk.alt, extended: true);
  }
  if (logical == LogicalKeyboardKey.metaLeft) {
    return const RemoteKey(vk: Vk.meta);
  }
  if (logical == LogicalKeyboardKey.metaRight) {
    return const RemoteKey(vk: Vk.meta, extended: true);
  }

  // F1..F12（远程排障时 F5 刷新、F2 改名这类很常用）
  final f = _fKeys[logical];
  if (f != null) return RemoteKey(vk: f);

  // 可打印字符走 Unicode 注入（不受对方输入法影响，中文也能直接打）。
  // ⚠️ Ctrl/Alt 组合时 Flutter 给的 character 会是控制字符（Ctrl+C → \x03）
  // 甚至 null —— 那种情况**不能**按原样发出去，否则被控端收到一个不可见
  // 字符，组合键根本形不成。所以只对"真是可见字符"走这条路。
  final ch = character;
  if (ch != null && ch.isNotEmpty) {
    final unit = ch.codeUnitAt(0);
    if (unit >= 0x20 && unit != 0x7F) return RemoteKey(char: ch);
  }

  // 走到这里通常是 Ctrl+C 这类组合：换成虚拟键码发出去，
  // 让"Ctrl 已按下"这件事在被控端和这个按键叠加起来。
  final label = logical.keyLabel;
  if (label.length == 1) {
    // Win32 的 VK_A..VK_Z 正好等于大写字母的 ASCII，VK_0..VK_9 等于数字的
    // ASCII —— 所以 toUpperCase 之后取码就是答案，不必写 36 行对照表。
    // 长度必须为 1：'F1'、'Tab' 这种多字符标签取首字母会推导出错误的键。
    final c = label.toUpperCase().codeUnitAt(0);
    final isLetter = c >= 0x41 && c <= 0x5A;
    final isDigit = c >= 0x30 && c <= 0x39;
    if (isLetter || isDigit) return RemoteKey(vk: c);
  }

  if (logical == LogicalKeyboardKey.space) return const RemoteKey(vk: Vk.space);
  return null;
}

/// F1..F12 对照表。远程排障时 F5（刷新）/ F2（改名）这类很常用，
/// 不映射的话按下去对面毫无反应，而用户只会以为"这软件不支持功能键"。
// ⚠️ 不用 `const`：LogicalKeyboardKey 重写了 == / hashCode，Dart 不允许它
// 出现在常量 map 的键位置（那种 map 的查找语义会变得不可预期）。
final Map<LogicalKeyboardKey, int> _fKeys = <LogicalKeyboardKey, int>{
  LogicalKeyboardKey.f1: Vk.f1,
  LogicalKeyboardKey.f2: Vk.f1 + 1,
  LogicalKeyboardKey.f3: Vk.f1 + 2,
  LogicalKeyboardKey.f4: Vk.f1 + 3,
  LogicalKeyboardKey.f5: Vk.f1 + 4,
  LogicalKeyboardKey.f6: Vk.f1 + 5,
  LogicalKeyboardKey.f7: Vk.f1 + 6,
  LogicalKeyboardKey.f8: Vk.f1 + 7,
  LogicalKeyboardKey.f9: Vk.f1 + 8,
  LogicalKeyboardKey.f10: Vk.f1 + 9,
  LogicalKeyboardKey.f11: Vk.f1 + 10,
  LogicalKeyboardKey.f12: Vk.f12,
};

class RemoteControlScreen extends StatefulWidget {
  const RemoteControlScreen({super.key});

  @override
  State<RemoteControlScreen> createState() => _RemoteControlScreenState();
}

class _RemoteControlScreenState extends State<RemoteControlScreen> {
  final _svc = RemoteAssistService.instance;
  final FocusNode _focus = FocusNode();
  bool _ctrlMode = true;

  @override
  void initState() {
    super.initState();
    Future<void>.delayed(const Duration(milliseconds: 200), () {
      if (mounted) FocusScope.of(context).requestFocus(_focus);
    });
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  // ---- 指针 ----
  //
  // 🔴 指针处理已经整体搬到 _RemoteStage（见那里）。
  //    留在这一层会踩同一个坑：坐标按**整个容器**换算，
  //    而画面只是中间一条 —— 点在黑边上（或放大后）落点就偏了。

  // ---- 键盘 ----

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (!_ctrlMode) return KeyEventResult.ignored;
    // 修饰键本身不需要转换：Windows 端按 host 当前状态处理即可，
    // 真正的组合效果（Ctrl+C）由 host 侧的按键序列自然形成。
    final k = _keyOf(e.logicalKey, e.character);
    if (k == null) return KeyEventResult.ignored;
    if (e is KeyDownEvent) {
      _svc.sendKeyDown(k);
    } else if (e is KeyUpEvent) {
      _svc.sendKeyUp(k);
    }
    return KeyEventResult.handled;
  }

  RemoteKey? _keyOf(LogicalKeyboardKey logical, String? character) =>
      remoteKeyOf(logical, character);

  @override
  Widget build(BuildContext context) {
    final svc = _svc;
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: ValueListenableBuilder<RemotePhase>(
          valueListenable: svc.phase,
          builder: (_, p, __) {
            return Column(children: [
              _ControlBar(
                ctrlMode: _ctrlMode,
                onToggle: (v) => setState(() => _ctrlMode = v),
              ),
              Expanded(
                child: Focus(
                  focusNode: _focus,
                  onKeyEvent: _onKey,
                  child: _RemoteStage(
                    svc: svc,
                    ctrlMode: _ctrlMode,
                    phase: p,
                    unattended: svc.session.value?.unattended == true,
                  ),
                ),
              ),
              _DiagBar(),
            ]);
          },
        ),
      ),
    );
  }
}

// ============================================================ 控制端画布

/// 控制端画布：缩放 / 平移 / 指针坐标换算。
///
/// 🔴 2026-10-16 龙哥的原话：「在手机端控制界面画面不能放大，
///    在那么小的画面里看都看不清怎么控制？」
///    在此之前这一块同时踩了两个坑：
///     ① 画面 Contain 居中直接铺满 —— 手机竖屏看一台 16:9 的电脑，
///        就是中间一条小带子，既不能放大也不能挪；
///     ② 更要命的是坐标：点的位置除以的是**整个容器**的宽高，
///        而画面只占中间一条。点在黑边上算出来照样是 0..1 之间的值，
///        于是"点标题栏"其实落到了屏幕正中 —— 现象就是"点了没反应"。
///
/// 现在：
///   · 画面按真实宽高 contain 到一个矩形，外面套 InteractiveViewer
///     （双指缩放 1x~8x，放大后可拖动看四周）；
///   · 指针坐标先逆变换回"视频矩形内坐标"，再除以矩形尺寸，
///     落在矩形外的点一律丢弃 —— 点在黑边上不该被当成点击；
///   · 拖动的语义按"当前有没有放大"自动切换（见 _dragIsPan）：
///     1x 时拖动=移动鼠标（老手感不变），放大后拖动=平移画面，
///     否则想挪一下视角就把人家桌面拖出一大片选区。
class _RemoteStage extends StatefulWidget {
  const _RemoteStage({
    required this.svc,
    required this.ctrlMode,
    required this.phase,
    required this.unattended,
  });

  final RemoteAssistService svc;
  final bool ctrlMode;
  final RemotePhase phase;
  final bool unattended;

  @override
  State<_RemoteStage> createState() => _RemoteStageState();
}

/// ---- 画布几何（纯函数，独立成顶层是为了能直接单测）----
///
/// 远程控制里最阴的坑就是坐标：算错一格，用户看到的就是"点了没反应"，
/// 而代码里看不出任何异常。所以这两个函数不依赖任何 Flutter 状态，
/// 测试可以直接喂数进来验（见 test/remote_stage_test.dart）。

/// 视频按真实宽高 contain 到容器里之后的矩形（含居中留黑边）。
Rect remoteVideoRect(Size box, Size? videoSize) {
  final target = (videoSize == null || videoSize.width <= 0 ||
          videoSize.height <= 0)
      ? const Size(16, 9) // 首帧没到时先按最常见的 16:9 摆着
      : videoSize;
  final s = math.min(box.width / target.width, box.height / target.height);
  final w = target.width * s;
  final h = target.height * s;
  return Rect.fromLTWH((box.width - w) / 2, (box.height - h) / 2, w, h);
}

/// 舞台坐标 → 对端屏幕的归一化坐标（0..1）。
///
/// 逆变换是解析算的：InteractiveViewer 的矩阵形如 p' = s*p + t，
/// 所以 p = (p' - t) / s。缩放恒 > 0，不存在不可逆的情况。
/// 落在画面矩形外（黑边）返回 null —— 点在黑边上不该被当成点击。
Offset? remoteNormFromStage(
    Offset p, Rect videoRect, double scale, Offset pan) {
  if (scale <= 0) return null;
  final inChild = Offset((p.dx - pan.dx) / scale, (p.dy - pan.dy) / scale);
  final nx = (inChild.dx - videoRect.left) / videoRect.width;
  final ny = (inChild.dy - videoRect.top) / videoRect.height;
  if (nx < 0 || nx > 1 || ny < 0 || ny > 1) return null;
  return Offset(nx, ny);
}

/// 一次"可能变成点击"的按下。单指轻点=左键、长按=右键、拖动=移动/平移，
/// 全靠按下时记的这几个数在抬起那一刻判定。
class _PressRecord {
  _PressRecord({required this.time, required this.local, required this.button});

  final DateTime time;
  final Offset local;
  final RemoteMouseButton button;

  /// 已经把「按下」发给对端了。放大态下不发；鼠标态下发。
  /// 抬起（或手势升级成双指缩放）时，只要 sent 为真就必须补一个抬起，
  /// 否则对端鼠标永远卡在按下状态 —— 拖选、按住菜单全跟着坏。
  bool sent = false;
  bool moved = false;
  bool consumed = false; // 已经被当作"这一次手势"处理掉了（比如长按已触发）
}

class _RemoteStageState extends State<_RemoteStage> {
  final TransformationController _tf = TransformationController();

  /// 最新一帧的真实像素尺寸。首帧之前是 null —— 那时按 16:9 先摆着，
  /// 收到首帧再按真实比例重排（不会跳，因为只影响 contain 的矩形）。
  Size? _videoSize;

  final Map<int, _PressRecord> _presses = <int, _PressRecord>{};

  /// 黑屏提示：连上 12s 还没收到帧就置位，见帧即撤。
  Timer? _blackTimer;
  bool _black = false;

  // 手势判定的两个阈值。
  // 移动超过 10 逻辑像素就不算"点击"了（手指本来就抖，卡太紧会点不出）；
  // 长按 600ms 与 iOS/Android 系统长按一致，用户不用重新学。
  static const double _tapSlop = 10;
  static const int _longPressMs = 600;

  RemoteAssistService get _svc => widget.svc;

  @override
  void initState() {
    super.initState();
    _svc.remoteRenderer.addListener(_onRenderer);
    // 自研画面通道（Windows 被控端）的帧尺寸走另一条通知 ——
    // 它没有 RTCVideoRenderer，尺寸只能由帧自己带过来。
    _svc.frameSize.addListener(_onFrameSize);
    _tf.addListener(_onTransform);
    // 🔴 黑屏检测（龙哥 2026-10-16 真机："远程协助界面一片漆黑"）。
    //    连接建立但 12 秒还没收到任何视频帧 → 大概率不是网速问题，
    //    而是对端**采集没起来**（Android 14 没给屏幕采集前台服务 /
    //    手机锁屏 / Windows 没允许屏幕录制）。以前这里是一片纯黑，
    //    用户完全不知道去哪修。现在给一句能照着做的话。
    _blackTimer = Timer(const Duration(seconds: 12), () {
      if (!mounted) return;
      if (_svc.remoteRenderer.videoWidth > 0) return; // 有帧，不打扰
      if (_svc.framesIn > 0) return; // 自研画面通道有帧，不打扰
      if (widget.phase != RemotePhase.active) return;
      setState(() => _black = true);
    });
  }

  @override
  void dispose() {
    _blackTimer?.cancel();
    _svc.remoteRenderer.removeListener(_onRenderer);
    _svc.frameSize.removeListener(_onFrameSize);
    _tf.removeListener(_onTransform);
    _tf.dispose();
    super.dispose();
  }

  void _onRenderer() {
    final w = _svc.remoteRenderer.videoWidth;
    final h = _svc.remoteRenderer.videoHeight;
    if (w <= 0 || h <= 0) return;
    final next = Size(w.toDouble(), h.toDouble());
    if (_videoSize == next) return;
    if (!mounted) return;
    setState(() {
      _videoSize = next;
      _black = false; // 来帧了，黑屏提示撤掉
    });
  }

  /// 自研画面通道来帧：帧尺寸一变就按新比例重排画面矩形，
  /// 并撤销黑屏提示（来帧了就不是黑屏）。
  ///
  /// 为什么不用帧尺寸做"来没来帧"的唯一依据：被控端换分辨率（拔插显示器、
  /// 改缩放）时尺寸才会变，尺寸不变不代表没帧 —— 所以黑屏判定看的是一个
  /// 单独的计数（见 _onFrameTick 的 framesIn）。
  void _onFrameSize() {
    final s = _svc.frameSize.value;
    if (s == null) return;
    final next = Size(s.w.toDouble(), s.h.toDouble());
    if (_videoSize == next && !_black) return;
    if (!mounted) return;
    setState(() {
      _videoSize = next;
      _black = false;
    });
  }

  void _onTransform() {
    // 只为了让缩放比例那几个 UI 跟着变；坐标换算不依赖 setState
    if (mounted) setState(() {});
  }

  // ------------------------------------------------------------ 变换读写

  /// Matrix4 是列主序：storage[0]=m00（缩放）、storage[12]/[13]=tx/ty。
  /// InteractiveViewer 只做"缩放+平移"，所以直接读这两个位置就够了 ——
  /// 不必引 getMaxScaleOnAxis/getTranslation 那些名字在不同版本里漂过的 API。
  double get _scale => _tf.value.entry(0, 0);

  Offset get _pan => Offset(_tf.value.entry(0, 3), _tf.value.entry(1, 3));

  /// 放大了才把拖动当平移（1x 时拖动就是移动鼠标，那是老手感）
  bool get _dragIsPan => _scale > 1.01 && !WebRTC.platformIsDesktop;

  /// 画面在容器里的真实矩形（contain）。
  /// 这一句就是修"点哪儿都不准"的关键：以前算的是整个容器。
  Rect _videoRect(Size box) => remoteVideoRect(box, _videoSize);

  /// 舞台坐标 → 对端屏幕的归一化坐标。落在画面矩形外（黑边）返回 null。
  Offset? _toNorm(Offset p, Size box) =>
      remoteNormFromStage(p, _videoRect(box), _scale, _pan);

  void _applyMatrix(Matrix4 m) {
    _tf.value = m;
  }

  /// 缩放到指定倍数，以 focal（舞台坐标）为中心。
  ///
  /// 必须自己夹边界：InteractiveViewer 在 constrained:false 下不会帮你夹，
  /// 不夹的话缩到 2x 能把画面拖到容器外面去，只剩一片黑。
  Matrix4 _matrixAt(double scale, Offset focal, Size box) {
    final s = scale.clamp(1.0, 8.0);
    // p' = s*p + t，要让 focal 这个点在缩放前后不动：t = focal - s*focal
    var tx = focal.dx - s * focal.dx;
    var ty = focal.dy - s * focal.dy;
    // 夹住：缩放后的画面必须仍然铺满容器（tx∈[w(1-s), 0]）
    tx = tx.clamp(box.width * (1 - s), 0.0);
    ty = ty.clamp(box.height * (1 - s), 0.0);
    return Matrix4.identity()
      ..setEntry(0, 0, s)
      ..setEntry(1, 1, s)
      ..setEntry(0, 3, tx)
      ..setEntry(1, 3, ty);
  }

  void _zoomBy(double step, Size box) {
    final center = Offset(box.width / 2, box.height / 2);
    _applyMatrix(_matrixAt(_scale + step, center, box));
  }

  void _reset() {
    _applyMatrix(Matrix4.identity());
  }

  // ------------------------------------------------------------ 指针

  void _onDown(PointerDownEvent e, Size box) {
    if (!widget.ctrlMode) return;
    // 屏上已经有手指就不登记：第二根手指几乎一定是缩放手势，
    // 把它当控制会造出一串奇怪的点击
    if (_presses.isNotEmpty) return;
    final rec = _PressRecord(
      time: DateTime.now(),
      local: e.localPosition,
      button: _btnOf(e.buttons),
    );
    _presses[e.pointer] = rec;
    if (_dragIsPan) return; // 放大态：抬手时才知道是点击还是平移
    final n = _toNorm(e.localPosition, box);
    if (n == null) return;
    _svc.sendPointer(n.dx, n.dy);
    _svc.sendMouseDown(rec.button);
    rec.sent = true;
  }

  void _onMove(PointerMoveEvent e, Size box) {
    if (!widget.ctrlMode) return;
    final rec = _presses[e.pointer];
    if (rec != null && (rec.local - e.localPosition).distance > _tapSlop) {
      rec.moved = true;
    }
    // 多指 = 用户在缩放/双指平移，不再是"控制"。
    // 🔴 这一步必须把已经发出去的「按下」补一个「抬起」：
    //    捏合缩放的前半段（第一根手指落下）在鼠标态里就是一次真实的按下，
    //    不补的话对端鼠标卡在按下状态，桌面被拖出一大片选区。
    if (_presses.length >= 2) {
      for (final r in _presses.values) {
        if (r.sent && !r.consumed) {
          _svc.sendMouseUp(r.button);
          r.consumed = true;
        }
      }
      return;
    }
    if (_dragIsPan) return;
    if (rec != null && rec.consumed) return;
    final n = _toNorm(e.localPosition, box);
    if (n == null) return;
    _svc.sendPointer(n.dx, n.dy);
  }

  void _onUp(PointerUpEvent e, Size box) {
    if (!widget.ctrlMode) {
      _presses.remove(e.pointer);
      return;
    }
    final rec = _presses.remove(e.pointer);
    if (_dragIsPan) {
      // 放大态下 down/up 都没发过，只有"轻点/长按"才补一次点击。
      // 但如果这条记录在鼠标态里已经按下了（中途切进放大态），必须补抬起。
      if (rec != null && rec.sent && !rec.consumed) {
        _svc.sendMouseUp(rec.button);
        rec.consumed = true;
      }
      if (rec == null || rec.moved || rec.consumed) return;
      final n = _toNorm(e.localPosition, box);
      if (n == null) return;
      final held = DateTime.now().difference(rec.time).inMilliseconds;
      final btn = held >= _longPressMs
          ? RemoteMouseButton.right
          : RemoteMouseButton.left;
      _svc.sendPointer(n.dx, n.dy);
      _svc.sendMouseDown(btn);
      _svc.sendMouseUp(btn);
      return;
    }
    // 🔴 抬起必须用按下时记下的键。
    //    PointerUpEvent 的 buttons 是**事件之后**的按键状态（也就是 0），
    //    照它换算是恒为 left —— 右键点了就松不开，对端右键菜单会一直挂着。
    _svc.sendMouseUp(rec?.button ?? RemoteMouseButton.left);
  }

  /// 指针被取消（系统手势打断、手指滑出屏幕）时不会再来 up，
  /// 不清掉就会让下一次 up 拿到一条过期记录
  void _onCancel(PointerCancelEvent e) {
    _presses.remove(e.pointer);
  }

  void _onHover(PointerHoverEvent e, Size box) {
    if (!widget.ctrlMode) return;
    final n = _toNorm(e.localPosition, box);
    if (n == null) return;
    _svc.sendPointer(n.dx, n.dy);
  }

  void _onSignal(PointerSignalEvent sig, Size box) {
    if (!widget.ctrlMode) return;
    if (sig is! PointerScrollEvent) return;
    // Ctrl+滚轮 = 缩放本地画面（和看图软件的习惯一致）；
    // 裸滚轮 = 发给对端滚屏，这是远控的本来用途
    final ctrl = HardwareKeyboard.instance.isControlPressed;
    final step = sig.scrollDelta.dy > 0 ? -0.25 : 0.25;
    if (ctrl) {
      _applyMatrix(_matrixAt(_scale + step, sig.localPosition, box));
      return;
    }
    _svc.sendWheel(sig.scrollDelta.dy > 0 ? -1 : 1);
  }

  RemoteMouseButton _btnOf(int buttons) {
    if (buttons & kSecondaryButton != 0) return RemoteMouseButton.right;
    if (buttons & kTertiaryButton != 0) return RemoteMouseButton.middle;
    return RemoteMouseButton.left;
  }

  // ------------------------------------------------------------ 构建

  @override
  Widget build(BuildContext context) {
    final p = widget.phase;
    return LayoutBuilder(builder: (_, c) {
      final box = Size(c.maxWidth, c.maxHeight);
      final r = _videoRect(box);
      return Stack(
        children: [
          // 黑底：contain 留出来的边也是界面的一部分，不能透出下面的白
          Positioned.fill(child: Container(color: Colors.black)),
          Positioned.fill(
            child: Listener(
              onPointerHover: (e) => _onHover(e, box),
              onPointerDown: (e) => _onDown(e, box),
              onPointerMove: (e) => _onMove(e, box),
              onPointerUp: (e) => _onUp(e, box),
              onPointerCancel: _onCancel,
              onPointerSignal: (s) => _onSignal(s, box),
              child: InteractiveViewer(
                transformationController: _tf,
                // 缩放范围：1x 起步（不能缩小到比容器还小，那只会多出黑边），
                // 8x 足够看清桌面上的小字
                minScale: 1,
                maxScale: 8,
                // 🔴 constrained:false 是关键：
                //    默认的 true 会把子件钉死在视口大小，
                //    那样放大后拖不动（能放大但看不了四周 = 等于没用）
                constrained: false,
                child: SizedBox(
                  width: box.width,
                  height: box.height,
                  child: Stack(children: [
                    Positioned.fromRect(
                      rect: r,
                      // 两条画面来路，取到哪条用哪条：
                      //   · frameJpeg 有值 → 对端走的是**自研画面通道**
                      //     （Windows 被控端，GDI 抓屏 + DataChannel 推帧）；
                      //   · 否则 → 原来的 WebRTC 视频轨（手机当被控端走这里）。
                      // 画面矩形 r 已经按对应尺寸做过 contain，所以两个分支
                      // 都用 fill：比例由矩形保证，这里再 contain 一次只会缩出黑边。
                      child: ValueListenableBuilder<Uint8List?>(
                        valueListenable: _svc.frameJpeg,
                        builder: (_, jpeg, __) => jpeg == null
                            ? RTCVideoView(
                                _svc.remoteRenderer,
                                objectFit: RTCVideoViewObjectFit
                                    .RTCVideoViewObjectFitContain,
                              )
                            : RemoteFrameView(jpeg: _svc.frameJpeg),
                      ),
                    ),
                  ]),
                ),
              ),
            ),
          ),
          if (p != RemotePhase.active)
            Positioned.fill(
              child: Container(
                color: Colors.black54,
                alignment: Alignment.center,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (p != RemotePhase.ended)
                      const SizedBox(
                        width: 26,
                        height: 26,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    const SizedBox(height: 14),
                    Text(
                      p == RemotePhase.ended
                          ? '会话已结束'
                          : p == RemotePhase.requesting
                              ? (widget.unattended
                                  ? '已发出连接，等待对方撤销窗口结束…'
                                  : '等待对方同意…')
                              : _phaseText(p),
                      style: const TextStyle(color: Colors.white, fontSize: 14),
                    ),
                  ],
                ),
              ),
            ),
          // UU-a：连接还在，但网络波动正在退避重连。
          // 画面是静止的最后一帧，不盖一层用户会以为软件卡死。
          if (p == RemotePhase.active)
            ValueListenableBuilder<bool>(
              valueListenable: _svc.reconnecting,
              builder: (_, rc, __) => rc
                  ? const Positioned.fill(child: _ReconnectOverlay())
                  : const SizedBox.shrink(),
            ),
          // 🔴 黑屏排查提示（龙哥 2026-10-16 真机："一片漆黑"）。
          //    连上 12s 还没有任何帧 → 不是网速，是对端采集没起来。
          //    安卓 14 要求被控端放行"屏幕采集前台服务"；Windows 被控端
          //    要允许屏幕录制；手机锁屏也会停采。
          if (_black && p == RemotePhase.active)
            Positioned(
              left: 12,
              right: 12,
              top: 12,
              child: _BlackScreenTip(
                onRetry: () {
                  setState(() => _black = false);
                  _blackTimer?.cancel();
                  _blackTimer = Timer(const Duration(seconds: 12), () {
                    if (!mounted) return;
                    if (_svc.remoteRenderer.videoWidth <= 0 &&
                        widget.phase == RemotePhase.active) {
                      setState(() => _black = true);
                    }
                  });
                },
              ),
            ),
          // 缩放控制条：放在画面右下角，不占顶栏（顶栏空间已经很紧）
          Positioned(
            right: 10,
            bottom: 10,
            child: _ZoomBar(
              scale: _scale,
              onZoomIn: () => _zoomBy(0.5, box),
              onZoomOut: () => _zoomBy(-0.5, box),
              onReset: _reset,
            ),
          ),
          // 放大了才提示手势用法，1x 时不用教
          if (_scale > 1.01 && p == RemotePhase.active)
            Positioned(
              left: 10,
              top: 10,
              child: _GestureHint(pan: _dragIsPan, ctrlMode: widget.ctrlMode),
            ),
        ],
      );
    });
  }
}

/// 右下角缩放条。三个按钮 + 当前倍数，倍数平时不显眼，放大了才变亮。
class _ZoomBar extends StatelessWidget {
  const _ZoomBar({
    required this.scale,
    required this.onZoomIn,
    required this.onZoomOut,
    required this.onReset,
  });

  final double scale;
  final VoidCallback onZoomIn;
  final VoidCallback onZoomOut;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    final on = scale > 1.01;
    return Container(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(22),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        _btn(Icons.remove_rounded, scale > 1.01 ? onZoomOut : null),
        SizedBox(
          width: 44,
          child: Center(
            child: Text(
              '${scale.toStringAsFixed(1)}x',
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                color: on ? Colors.white : Colors.white70,
              ),
            ),
          ),
        ),
        _btn(Icons.add_rounded, scale < 7.99 ? onZoomIn : null),
        _btn(Icons.fit_screen_rounded, on ? onReset : null),
      ]),
    );
  }

  Widget _btn(IconData icon, VoidCallback? onTap) {
    return SizedBox(
      width: 32,
      height: 32,
      child: IconButton(
        padding: EdgeInsets.zero,
        iconSize: 18,
        // 到头了就置灰，不要"点了没反应"
        color: onTap == null ? Colors.white30 : Colors.white,
        tooltip: icon == Icons.remove_rounded
            ? '缩小'
            : icon == Icons.add_rounded
                ? '放大'
                : '复位到适应窗口',
        icon: Icon(icon),
        onPressed: onTap,
      ),
    );
  }
}

/// 放大后的手势说明。这几句话是"教一次就会"的，不常驻。
class _GestureHint extends StatelessWidget {
  const _GestureHint({required this.pan, required this.ctrlMode});

  final bool pan;
  final bool ctrlMode;

  @override
  Widget build(BuildContext context) {
    final text = !ctrlMode
        ? '双指缩放 · 拖动看四周'
        : pan
            ? '双指缩放 · 拖动看四周 · 单点=单击 · 长按=右键'
            : '双指缩放 · 拖动=移动鼠标 · 单点=单击';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Text(
        text,
        style: const TextStyle(color: Colors.white70, fontSize: 11.5),
      ),
    );
  }
}

class _ControlBar extends StatelessWidget {
  const _ControlBar({required this.ctrlMode, required this.onToggle});
  final bool ctrlMode;
  final ValueChanged<bool> onToggle;

  @override
  Widget build(BuildContext context) {
    final svc = RemoteAssistService.instance;
    return Container(
      color: AppColors.bgElevated,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(children: [
        IconButton(
          icon: Icon(Icons.close_rounded, color: AppColors.danger),
          tooltip: '断开连接',
          onPressed: () async {
            await svc.hangUp();
            if (context.mounted) Navigator.of(context).maybePop();
          },
        ),
        // UU 借鉴：连接状态一眼可见（点 + 文字），断了绝不让人干等
        const _LinkStatusDot(),
        const SizedBox(width: 8),
        Expanded(
          child: ValueListenableBuilder<RemoteSession?>(
            valueListenable: svc.session,
            builder: (_, s, __) => Text(
              s == null ? '远程协助' : '正在协助 ${s.hostName}',
              style: const TextStyle(fontSize: 13.5),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
        // UU-c：画质档位。网络差自动降级时这里变黄字，
        // 让用户知道"画面变糊"是自适应省带宽、不是坏了。
        // 🔴 2026-10-16 龙哥真机反馈之前这是块**纯展示**，想调画质找不到入口
        //    （"版本控制界面一片漆黑"）。改成可点选：控制端选档 → 经控制
        //    通道发给被控端（发送端）落地，勾号记在 svc.qualityPick。
        PopupMenuButton<int?>(
          tooltip: '画质档位',
          onSelected: (lv) => svc.sendQuality(lv),
          itemBuilder: (c) => [
            for (final e in const <(int?, String)>[
              (null, '自动（按网络自适应）'),
              (0, '原画（不限制）'),
              (1, '高清（1500kbps）'),
              (2, '标清（800kbps）'),
              (3, '流畅（400kbps）'),
              (4, '极速（200kbps）'),
            ])
              PopupMenuItem<int?>(
                value: e.$1,
                child: Row(children: [
                  SizedBox(
                    width: 18,
                    child: ValueListenableBuilder<int?>(
                      valueListenable: svc.qualityPick,
                      builder: (_, pick, __) => pick == e.$1
                          ? const Icon(Icons.check, size: 15)
                          : const SizedBox.shrink(),
                    ),
                  ),
                  Text(e.$2),
                ]),
              ),
          ],
          child: ValueListenableBuilder<int>(
            valueListenable: svc.qualityLevel,
            builder: (_, lv, __) => Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: lv == 0
                    ? AppColors.surface
                    : AppColors.warn.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(children: [
                Text(
                  remoteQualityText(lv),
                  style: TextStyle(
                    fontSize: 11,
                    color: lv == 0 ? AppColors.textWeak : AppColors.warn,
                  ),
                ),
                Icon(Icons.arrow_drop_down,
                    size: 14,
                    color: lv == 0 ? AppColors.textWeak : AppColors.warn),
              ]),
            ),
          ),
        ),
        const SizedBox(width: 4),
        Row(children: [
          const Text('允许控制', style: TextStyle(fontSize: 12)),
          Switch(
            value: ctrlMode,
            onChanged: onToggle,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        ]),
      ]),
    );
  }
}

/// 连接状态点：绿=已连接；黄=连接中/重连中；灰=已结束。
class _LinkStatusDot extends StatelessWidget {
  const _LinkStatusDot();

  @override
  Widget build(BuildContext context) {
    final svc = RemoteAssistService.instance;
    return ValueListenableBuilder<RemotePhase>(
      valueListenable: svc.phase,
      builder: (_, p, __) {
        return ValueListenableBuilder<bool>(
          valueListenable: svc.reconnecting,
          builder: (_, rc, __) {
            final Color c;
            final String t;
            if (rc) {
              c = AppColors.warn;
              t = '重连中';
            } else if (p == RemotePhase.active) {
              c = AppColors.online;
              t = '已连接';
            } else if (p == RemotePhase.ended) {
              c = AppColors.textWeak;
              t = '已结束';
            } else {
              c = AppColors.brand2;
              t = '连接中';
            }
            return Row(children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(color: c, shape: BoxShape.circle),
              ),
              const SizedBox(width: 5),
              Text(t, style: TextStyle(fontSize: 12, color: AppColors.textSub)),
            ]);
          },
        );
      },
    );
  }
}

/// UU-a 重连中的居中提示卡：网络波动 → 自动退避重连。
/// 关键诉求是"别让用户手动退出"——退出反而真断了，等几秒它就自己回来。
class _ReconnectOverlay extends StatelessWidget {
  const _ReconnectOverlay();

  @override
  Widget build(BuildContext context) {
    final svc = RemoteAssistService.instance;
    return Container(
      color: Colors.black54,
      alignment: Alignment.center,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 40),
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 22),
        decoration: BoxDecoration(
          color: AppColors.bgElevated,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.warn.withValues(alpha: 0.5)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
             SizedBox(
              width: 30,
              height: 30,
              child: CircularProgressIndicator(strokeWidth: 2.5, color: AppColors.warn),
            ),
            const SizedBox(height: 14),
            ValueListenableBuilder<int>(
              valueListenable: svc.reconnectAttempt,
              builder: (_, n, __) => Text(
                '网络波动，正在自动重连（第 $n/5 次）',
                style: const TextStyle(
                    color: Colors.white, fontSize: 14.5, fontWeight: FontWeight.w600),
              ),
            ),
            const SizedBox(height: 8),
             Text(
              '恢复后会自动接回，请勿关闭窗口',
              style: TextStyle(color: AppColors.textSub, fontSize: 12),
            ),
            const SizedBox(height: 4),
            TextButton(
              onPressed: () async {
                await svc.hangUp();
                if (context.mounted) Navigator.of(context).maybePop();
              },
              child:  Text('手动断开',
                  style: TextStyle(color: AppColors.danger, fontSize: 12.5)),
            ),
          ],
        ),
      ),
    );
  }
}

class _DiagBar extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final svc = RemoteAssistService.instance;
    return ValueListenableBuilder<String>(
      valueListenable: svc.diag,
      builder: (_, d, __) => Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        color: AppColors.bgElevated,
        child: Text(
          d.isEmpty ? '准备就绪' : d,
          style: TextStyle(fontSize: 11.5, color: AppColors.textWeak),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }
}

/// 黑屏提示条：连上了但 12 秒收不到画面时显示。
///
/// 三种真因按现场出现频率排：① 安卓 14 被控端没放行"屏幕采集前台服务"
/// （现象就是权限都给了画面全黑）；② 被控手机锁屏/黑屏待机（MediaProjection
/// 在部分 ROM 上锁屏即停采）；③ Windows 被控端没允许屏幕录制。
/// 提示必须给"能照着做"的话 —— 只说"对方未共享画面"等于没说。
class _BlackScreenTip extends StatelessWidget {
  const _BlackScreenTip({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
        decoration: BoxDecoration(
          color: AppColors.warn.withValues(alpha: 0.16),
          borderRadius: BorderRadius.circular(AppRadii.md),
          border: Border.all(color: AppColors.warn.withValues(alpha: 0.5)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.warning_amber_rounded,
                size: 18, color: AppColors.warn),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('还没收到对方画面',
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: AppColors.warn)),
                  const SizedBox(height: 3),
                  Text(
                    '让对方检查：① 手机是否锁屏了（亮屏再来）；'
                    '② 安卓 14 要在通知里放行「屏幕采集」前台服务；'
                    '③ Windows 端要在系统设置里允许屏幕录制。',
                    style: TextStyle(
                        fontSize: 11.5,
                        color: AppColors.text,
                        height: 1.45),
                  ),
                ],
              ),
            ),
            TextButton(onPressed: onRetry, child: const Text('再等等')),
          ],
        ),
      ),
    );
  }
}

// ============================================================ 被控端 UI

/// 被控端常驻警示条。
///
/// 【为什么必须常驻且醒目】
/// 这是远程协助里唯一能防止"被悄悄控住"的东西。只要会话没结束，用户
/// 就应该随时能在余光里看到它 —— 做成能顺手关掉的通知就失去意义了。
class RemoteHostBanner extends StatefulWidget {
  const RemoteHostBanner({super.key});

  @override
  State<RemoteHostBanner> createState() => _RemoteHostBannerState();
}

class _RemoteHostBannerState extends State<RemoteHostBanner> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    // 下面那行采集状态里有实时计数（已发多少帧 / 丢弃多少），不刷新等于没有。
    // 一秒一次足够：这行字只给人看，不参与任何判定。
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final svc = RemoteAssistService.instance;
    return ValueListenableBuilder<RemotePhase>(
      valueListenable: svc.phase,
      builder: (_, p, __) {
        if (!svc.isHost || p != RemotePhase.active) return const SizedBox.shrink();
        final s = svc.session.value;
        // UU-a：重连中也要醒目 —— 被控端看到"正在重连"才知道
        // 别关机、别断网，等几秒软件自己就把画面接回来了
        return ValueListenableBuilder<bool>(
          valueListenable: svc.reconnecting,
          builder: (_, rc, __) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!rc)
                _bannerRow(
                  icon: Icons.screen_share_rounded,
                  color: AppColors.warn,
                  text: '正在被「${s?.controllerName ?? '对方'}」远程协助 —— 你的屏幕正在共享',
                  onHangUp: svc.hangUp,
                )
              else
                ValueListenableBuilder<int>(
                  valueListenable: svc.reconnectAttempt,
                  builder: (_, n, __) => _bannerRow(
                    icon: Icons.wifi_off_rounded,
                    color: AppColors.danger,
                    text: '网络波动，正在自动重连（第 $n/5 次）… 请勿关机、勿断网',
                    onHangUp: svc.hangUp,
                  ),
                ),
              _captureLine(svc),
            ],
          ),
        );
      },
    );
  }

  /// 画面采集状态行。
  ///
  /// 🔴 被控端原来**没有任何**可看的诊断信息（诊断条只在控制端画布页）。
  ///    于是"手机看到一片黑"的时候，坐在电脑前的人什么也判断不了 ——
  ///    是没抓到？抓到了没发出去？还是发出去被网络吞了？
  ///    2026-10-16 那次排查就是卡在这里只能猜。补上这行之后，
  ///    被控端的人念一句就能定位到环节。
  Widget _captureLine(RemoteAssistService svc) {
    if (svc.reconnecting.value) return const SizedBox.shrink();
    final text = svc.captureStatus;
    if (text.isEmpty) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      color: AppColors.warn.withValues(alpha: 0.08),
      padding: const EdgeInsets.fromLTRB(12, 2, 12, 6),
      child: Text(
        text,
        style: TextStyle(fontSize: 11.5, color: AppColors.textWeak),
      ),
    );
  }

  Widget _bannerRow({
    required IconData icon,
    required Color color,
    required String text,
    required Future<void> Function() onHangUp,
  }) {
    return Container(
      width: double.infinity,
      color: color.withValues(alpha: 0.16),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(children: [
        Icon(icon, size: 17, color: color),
        const SizedBox(width: 8),
        Expanded(
          child: Text(text, style: TextStyle(fontSize: 12.5, color: color)),
        ),
        TextButton(
          onPressed: onHangUp,
          child: Text('立即断开', style: TextStyle(color: AppColors.danger, fontSize: 12.5)),
        ),
      ]),
    );
  }
}

/// 收到协助请求时的确认弹窗（有人值守 / 无人值守都在窗口里给选择）
Future<void> showRemoteRequestDialog(BuildContext context) async {
  final svc = RemoteAssistService.instance;
  final s = svc.session.value;
  if (s == null) return;

  final injector = createInputInjector();
  // 🔴 必须**先问一次**再判断：Android 的无障碍开关用户可以随时在系统设置里
  //    开关，injector 建好时它还不知道当前到底是开着还是关着。
  //    不问就直接拿 supported，会拿到一个恒 false 的初值，
  //    于是弹窗上永远写着"此设备不支持远程控制" —— 明明是能开的。
  await injector.refreshAbility();
  final canControl = injector.supported;

  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) {
      return _RemoteRequestSheet(
        name: s.controllerName,
        unattended: s.unattended,
        canControl: canControl,
        injectHint: injector.hint,
        deadline: s.abortDeadline,
        injector: injector,
      );
    },
  );
}

class _RemoteRequestSheet extends StatefulWidget {
  const _RemoteRequestSheet({
    required this.name,
    required this.unattended,
    required this.canControl,
    required this.injectHint,
    required this.injector,
    this.deadline,
  });

  final String name;
  final bool unattended;
  final bool canControl;
  final String injectHint;
  final InputInjector injector;
  final DateTime? deadline;

  @override
  State<_RemoteRequestSheet> createState() => _RemoteRequestSheetState();
}

class _RemoteRequestSheetState extends State<_RemoteRequestSheet>
    with WidgetsBindingObserver {
  Timer? _t;
  int _left = 0;
  bool _canControl = false;

  @override
  void initState() {
    super.initState();
    _canControl = widget.canControl;
    // 用户从系统设置页切回来时，App 会走 resumed —— 这是唯一可靠的
    // "他可能刚改完开关"的信号。靠它再问一次，弹窗上的话就能跟着变，
    // 不然用户开了回来还得杀进程重进才生效（那种体验等于没做）。
    WidgetsBinding.instance.addObserver(this);
    final d = widget.deadline;
    if (d != null) {
      _tick();
      _t = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    unawaited(_recheck());
  }

  Future<void> _recheck() async {
    await widget.injector.refreshAbility();
    if (!mounted) return;
    setState(() => _canControl = widget.injector.supported);
  }

  /// 拉起系统无障碍设置页。跳不过去的 ROM 要给一句实话，
  /// 不然用户会以为点了没反应。
  Future<void> _openSettings() async {
    final ok = await widget.injector.openAccessibilitySettings();
    if (!mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('这台手机没法直接打开无障碍设置页，请到「设置 → 无障碍」'
              '里找到「小智IM 远程协助」手动开启'),
        ),
      );
    }
  }

  void _tick() {
    final d = widget.deadline;
    if (d == null) return;
    final left = d.difference(DateTime.now()).inSeconds;
    if (!mounted) return;
    setState(() => _left = left > 0 ? left : 0);
    if (left <= 0) {
      // 无人值守窗口结束：服务端会自动放行，这里只是关掉弹窗
      _t?.cancel();
      Navigator.of(context).maybePop();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final svc = RemoteAssistService.instance;
    return AlertDialog(
      backgroundColor: AppColors.bgElevated,
      title: Text(widget.unattended ? '有人用你的访问码发起连接' : '有人请求远程协助你'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('发起方：${widget.name}', style: const TextStyle(fontSize: 14)),
          const SizedBox(height: 12),
          Text(
            '同意后对方将看到你的屏幕'
            '${_canControl ? '，并且可以操作你的${widget.injector.controlObject}' : '（此设备暂不支持被远程控制，对方只能看画面）'}。',
            style: TextStyle(fontSize: 13, color: AppColors.textSub, height: 1.6),
          ),
          if (!_canControl) ...[
            const SizedBox(height: 8),
            Text(widget.injectHint,
                style: TextStyle(fontSize: 12, color: AppColors.warn, height: 1.5)),
            const SizedBox(height: 10),
            // 给一条能直接走出去的路。只解释"为什么不行"而不给按钮，
            // 用户得自己猜去哪儿开 —— 那是把系统规则转嫁给用户。
            OutlinedButton.icon(
              onPressed: _openSettings,
              icon: const Icon(Icons.settings_accessibility_rounded, size: 18),
              label: const Text('去开启（设置 → 无障碍）'),
            ),
          ],
          if (widget.unattended && _left > 0) ...[
            const SizedBox(height: 12),
            Text(
              '$_left 秒后自动同意（无人值守）。不想被连就点拒绝。',
              style: TextStyle(fontSize: 12.5, color: AppColors.warn),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () {
            svc.rejectAsHost();
            Navigator.of(context).pop();
          },
          child: Text('拒绝', style: TextStyle(color: AppColors.danger)),
        ),
        FilledButton(
          onPressed: () {
            svc.acceptAsHost();
            Navigator.of(context).pop();
          },
          child: const Text('同意'),
        ),
      ],
    );
  }
}

// ============================================================ 小组件

class _Card extends StatelessWidget {
  const _Card({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(10),
      ),
      child: child,
    );
  }
}

/// 给最高层的壳用：会话请求来了要弹窗，被控了要挂警示条。
///
/// 单独抽出来的原因是这两件事都必须在"任何页面之上"发生 ——
/// 不能因为用户在聊天页就不给他弹协作请求。
class RemoteAssistWatcher extends StatefulWidget {
  const RemoteAssistWatcher({required this.child, super.key});
  final Widget child;

  @override
  State<RemoteAssistWatcher> createState() => _RemoteAssistWatcherState();
}

class _RemoteAssistWatcherState extends State<RemoteAssistWatcher> {
  final _svc = RemoteAssistService.instance;

  @override
  void initState() {
    super.initState();
    _svc.start();
    _svc.session.addListener(_onSession);
    _svc.phase.addListener(_onPhase);
  }

  void _onSession() => _maybeShowSheet();

  void _onPhase() {
    const idle = RemotePhase.idle;
    const req = RemotePhase.requesting;
    // host 收到请求 → 弹确认框
    if (_svc.isHost && _svc.phase.value == req) {
      _maybeShowSheet();
      return;
    }
    if (_svc.phase.value == idle) return;
  }

  void _maybeShowSheet() {
    if (!_svc.isHost) return;
    if (_svc.phase.value != RemotePhase.requesting) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_svc.phase.value != RemotePhase.requesting) return;
      unawaited(showRemoteRequestDialog(context));
    });
  }

  @override
  void dispose() {
    _svc.session.removeListener(_onSession);
    _svc.phase.removeListener(_onPhase);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const RemoteHostBanner(),
        Expanded(child: widget.child),
      ],
    );
  }
}

double clampRatio(double v) => math.min(1.0, math.max(0.0, v));
