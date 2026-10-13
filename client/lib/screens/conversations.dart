import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:xiaozhi_im_client/api.dart';
import 'package:xiaozhi_im_client/core/badges.dart';
import 'package:xiaozhi_im_client/core/call_service.dart';
import 'package:xiaozhi_im_client/core/media.dart';
import 'package:xiaozhi_im_client/core/read_bus.dart';
import 'package:xiaozhi_im_client/core/remote_config.dart';
import 'package:xiaozhi_im_client/core/app_updater.dart';
import 'package:xiaozhi_im_client/core/session_manager.dart';
import 'package:xiaozhi_im_client/core/sound_service.dart';
import 'package:xiaozhi_im_client/core/storage.dart';
import 'package:xiaozhi_im_client/core/theme.dart';
import 'package:xiaozhi_im_client/core/time.dart';
import 'package:xiaozhi_im_client/core/tray_service.dart';
import 'package:xiaozhi_im_client/core/workspace.dart';
import 'package:xiaozhi_im_client/models.dart';
import 'package:xiaozhi_im_client/socket.dart';
import 'package:xiaozhi_im_client/screens/chat.dart';
import 'package:xiaozhi_im_client/screens/create_group.dart';
import 'package:xiaozhi_im_client/screens/favorites.dart';
import 'package:xiaozhi_im_client/screens/friends_new.dart';
import 'package:xiaozhi_im_client/screens/login.dart';
import 'package:xiaozhi_im_client/screens/remote.dart';
import 'package:xiaozhi_im_client/screens/search.dart';
import 'package:xiaozhi_im_client/widgets/avatar.dart';
import 'package:xiaozhi_im_client/widgets/enterprise_switcher.dart'
    show showEnterpriseSwitcher;
import 'package:xiaozhi_im_client/widgets/friend_auth_sheet.dart';
import 'package:xiaozhi_im_client/widgets/server_settings.dart';

class ConversationsScreen extends StatefulWidget {
  const ConversationsScreen({super.key});
  @override
  State<ConversationsScreen> createState() => ConversationsScreenState();
}

/// State 是**公开**的：外壳（HomeShell）要拿 `GlobalKey<ConversationsScreenState>`
/// 在通讯录里点人时切到消息 Tab 并打开与该人的会话。不这么做的话，通讯录就只能
/// "点一下没反应"，或者被迫自己复制一份建会话的逻辑（两份逻辑必然走歪）。
class ConversationsScreenState extends State<ConversationsScreen> {
  List<Conversation> _all = [];
  Conversation? _sel;
  int _myId = 0;
  int _pendingCount = 0; // 待处理的好友申请数（「新的朋友」入口上显示）
  // 提示音开关（菜单里可切，存本机）。main() 里已 init 过，这里直接读缓存值
  bool _soundOn = SoundService().enabled;
  bool _loading = true;
  String? _error;
  ApiException? _lastErr; // 最近一次错误的原始异常，UI 据此切换文案/按钮
  /// 已读广播订阅（chat 页标记已读 → 本地即时清零红点）。见 [ReadBus]。
  StreamSubscription<int>? _readSub;
  /// _load 并发序号闸门：只认最后一次拉取的结果（见 _load 注释）
  int _loadSeq = 0;

  @override
  void initState() {
    super.initState();
    // 切换企业（整域切换）→ 重新拉取当前激活服务器的会话 / 我 / 待处理
    SessionManager.instance.domainVersion.addListener(_onDomain);
    _readSub = ReadBus.instance.onCleared.listen(_onCleared);
    _init();
  }

  @override
  void dispose() {
    _readSub?.cancel();
    SessionManager.instance.domainVersion.removeListener(_onDomain);
    super.dispose();
  }

  /// 数据域切换（切到另一家企业）时，只重拉数据、不重连/不重复订阅 WS。
  void _onDomain() {
    if (!mounted) return;
    _refreshData();
  }

  Future<void> _init() async {
    setState(() {
      _loading = true;
      _error = null;
      _lastErr = null;
    });
    try {
      final me = await ImApi().me();
      _myId = me['user']['id'];
      SoundService().myId = _myId; // 提示音靠它过滤「自己发的消息不响」
      await SocketService().connect();
      await _load();
      _refreshPendingCount(); // 待处理好友申请数：拉不到不影响主流程
      SocketService().stream.listen(_onEvent);
    } catch (e) {
      // 401 → token 失效，清掉回到登录页（不让用户卡错误循环）
      if (e is ApiException && e.isUnauthorized) {
        if (!mounted) return;
        await Storage.clear();
        ImApi().clearToken();
        SocketService().disconnect();
        await CallService().resetAll();
    await SoundService().reset(); // 清掉 myId 与正在响的提示音
        Badges.instance.clear(); // 同上：token 失效也要清角标
        if (mounted) {
          Navigator.pushReplacement(
              context, MaterialPageRoute(builder: (_) => const LoginScreen()));
        }
        return;
      }
      // 其它（网络/超时/服务端错）：给用户自救了，避免被"重试"死循环卡住
      if (mounted) {
        setState(() {
          _error = _msg(e);
          _lastErr = e is ApiException ? e : null;
        });
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 只重拉数据（切企业后调用）：重新取「我」+ 会话 + 待处理好友申请。
  /// 不重连 / 不重复订阅 WS（那些由 SessionManager.setActive 与 _init 负责）。
  Future<void> _refreshData() async {
    try {
      final me = await ImApi().me();
      _myId = me['user']['id'];
      SoundService().myId = _myId;
      await _load();
      _refreshPendingCount();
    } catch (_) {
      // 切换过程里偶发的瞬断忽略，下次刷新会纠正，不弹错误打断用户
    }
  }

  /// 拉会话列表并刷新角标。
  ///
  /// [_loadSeq] 序号闸门：`_onEvent`（message:new / message:read / …）会在短
  /// 时间内并发触发多次 `_load`，后发出的先回来、先发出的后回来时，旧数据会把
  /// 新数据整个覆盖掉 —— 表现是"红点刚消又闪回来"。只认最后一次的结果。
  Future<void> _load() async {
    final seq = ++_loadSeq;
    final list = await ImApi().conversations();
    if (!mounted || seq != _loadSeq) return;
    final convs = list.map((e) => Conversation.fromJson(e)).toList();
    setState(() {
      _all = convs;
      // 按最后活跃时间倒序
      _all.sort((a, b) => (b.lastAt ?? b.id).compareTo(a.lastAt ?? a.id));
    });
    _recalcBadges(convs);
  }

  /// 未读角标：免打扰的会话不计入（用户明确表示不想被这条打扰，
  /// 还在标签上标红点等于没听他的）
  void _recalcBadges(List<Conversation> convs) {
    var n = 0;
    var at = false;
    for (final c in convs) {
      if (c.muted) continue;
      n += c.unread;
      if (c.hasMention) at = true;
    }
    Badges.instance.setUnread(n, hasMention: at);
  }

  /// 本地即时清零（2026-10-13 龙哥报的 bug「消息已经读了，但提示小点不是
  /// 马上消失」）：chat 页 `_markRead` HTTP 一成功就广播，这里本地把该会话
  /// unread 归零并重算角标，**不等 WS 的 message:read 帧** —— 宽屏（桌面/
  /// 平板）布局下聊天页与会话列表同屏，WS 往返那几百毫秒里红点一直挂着。
  ///
  /// 清零只负责"立刻好看"，随后 `_load()` 拉服务端真值校准：防的是旧
  /// markRead 响应晚到的竞态（清零之后对方又发了一条，本地不能把那条也
  /// 吞成已读）。WS 帧到达时 `_onEvent` 也会 `_load()`，双保险。
  void _onCleared(int convId) {
    if (!mounted) return;
    final i = _all.indexWhere((c) => c.id == convId);
    if (i < 0) return;
    final c = _all[i];
    if (c.unread == 0 && !c.hasMention) return; // 已是清零态，不动
    setState(() => _all[i] = c.copyWith(unread: 0, hasMention: false));
    _recalcBadges(_all);
    _load(); // 校准：不 await，不卡本地即时反馈
  }

  void _onEvent(dynamic e) {
    if (e is! Map) return;
    const refreshOn = {
      'message:new', // 新消息：刷新未读与预览
      'message:recall', // 撤回后刷新预览
      'message:read', // 已读推进：未读数变化
      'conversation:pin', // 置顶变更
      'group:updated', // 群名 / 公告 / 成员变更
      'group:kicked', // 自己被移出群
      'group:invited', // 被拉进新群
      'user:update', // 好友/群友改了昵称或头像
    };
    final t = e['type'];
    if (refreshOn.contains(t)) _load();

    if (t == 'friend:request') {
      // 有人申请加我：提示一句并刷新入口上的数字。
      // 这里刻意不播提示音 —— 「提示音」指的是新消息与来电，
      // 好友申请也响会让人以为来了消息。
      final u = e['user'];
      final name =
          (u is Map ? (u['nickname'] ?? u['username']) : null)?.toString() ?? '有人';
      _toast('$name 请求加你为好友');
      _refreshPendingCount();
    }
    if (t == 'friend:pending') {
      // 上线补推：申请落库那一刻我不在线，friend:request 帧没送到，
      // 服务端在我连上 WS 时把未处理的申请整包补发过来。
      // 有 1 条就说名字，多条说总数 —— 不逐条刷屏。
      final reqs = (e['requests'] as List?) ?? const [];
      if (reqs.isNotEmpty) {
        if (reqs.length == 1) {
          final u = (reqs.first as Map)['user'];
          final name =
              (u is Map ? (u['nickname'] ?? u['username']) : null)?.toString() ?? '有人';
          _toast('$name 请求加你为好友');
        } else {
          _toast('有 ${reqs.length} 条待处理的好友申请');
        }
      }
      _refreshPendingCount();
    }
    if (t == 'friend:accepted' || t == 'friend:rejected') {
      _refreshPendingCount();
      _load();
    }
  }

  /// 拉一次「待处理好友申请」数量，用于菜单入口的数字提示
  Future<void> _refreshPendingCount() async {
    try {
      final d = await ImApi().friends();
      final n = ((d['pending'] as List?) ?? const []).length;
      Badges.instance.setPendingFriends(n); // 通讯录标签的角标
      if (mounted && n != _pendingCount) setState(() => _pendingCount = n);
    } catch (_) {
      // 静默失败：这只是个数字提示，不该弹错误打扰用户
    }
  }

  String _msg(Object e) =>
      e.toString().replaceFirst('Exception: ', '');

  /// 提示音开关；打开时顺便试听一声，让用户确认音量合适
  Future<void> _toggleSound() async {
    final nv = !_soundOn;
    await SoundService().setEnabled(nv);
    if (!mounted) return;
    setState(() => _soundOn = nv);
    if (nv) SoundService().playMessage();
  }

  /// 桌面端：点右上角 × 之后的落点（每次询问 / 缩到托盘 / 直接退出）。
  ///
  /// 做成三态循环而不是单独开关：**用户一旦在关闭对话框里勾了"记住选择"，
  /// 必须还能在这里改回来**，否则那句"记住"就成了单程票。
  Future<void> _cycleCloseAction() async {
    const order = <CloseAction>[
      CloseAction.ask,
      CloseAction.minimize,
      CloseAction.exit,
    ];
    final i = order.indexOf(TrayService.instance.action);
    await TrayService.instance.setAction(order[(i + 1) % order.length]);
    if (!mounted) return;
    setState(() {});
  }

  void _logout() async {
    await Storage.clear();
    ImApi().clearToken();
    SocketService().disconnect();
    await CallService().resetAll();
    await SoundService().reset(); // 清掉 myId 与正在响的提示音
    // 角标是跨页共享的单例，不清的话换个账号登进来会先看到上一个人的未读数
    Badges.instance.clear();
    if (mounted) {
      Navigator.pushReplacement(
          context, MaterialPageRoute(builder: (_) => const LoginScreen()));
    }
  }

  /// 修改服务器地址：换地址后旧 token 失效，回到登录页
  Future<void> _openServer() async {
    final changed = await showServerSettings(context);
    if (changed != true) return;
    await Storage.clear();
    ImApi().clearToken();
    SocketService().disconnect();
    await CallService().resetAll();
    await SoundService().reset(); // 清掉 myId 与正在响的提示音
    if (mounted) {
      Navigator.pushReplacement(
          context, MaterialPageRoute(builder: (_) => const LoginScreen()));
    }
  }

  /// 错误态里的"切换服务器"入口——保留会话，地址变了就地重试。
  /// 同台服务端换域名/IP 不影响 token；如果换到完全不同的服务端，
  /// _init() 会再次触发 401 分支自动跳登录。
  Future<void> _openServerAndRetry() async {
    final changed = await showServerSettings(context);
    if (changed != true) return;
    // showServerSettings 内部已经 resolveNow()，刷新 currentUrl
    await SocketService().reconnect();
    await _init();
  }

  /// 关于 / 检查配置：显示客户端版本 + 已生效配置版本，可手动拉一次配置。
  /// 配置中心"出问题保持现状"（SPEC §6.2），这里拉取失败也只是文案提示，不报错弹窗。
  /// 工作台：统一的应用入口（钉钉/企微/飞书都叫工作台）。
  ///
  Future<void> _openAbout() async {
    final rc = RemoteConfig();
    // ⚠️ fetchTip 必须放在 builder 外面：StatefulBuilder 每次重建都会重新执行
    // builder，写在里面的局部变量会被重置回 null，setD 的赋值永远显示不出来。
    String? fetchTip;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) {
          return AlertDialog(
            title: const Text('关于'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('小智 IM 客户端 v$kAppVersion'),
                const SizedBox(height: 6),
                Text('配置版本：${rc.appliedVersion > 0 ? 'v${rc.appliedVersion}' : '未获取'}',
                    style: const TextStyle(fontSize: 13)),
                if (fetchTip != null) ...[
                  const SizedBox(height: 6),
                  Text(fetchTip!,
                      style: const TextStyle(
                          fontSize: 12, color: AppColors.textSub)),
                ],
                if (rc.upgradeHint.value != null) ...[
                  const SizedBox(height: 10),
                  Text(rc.upgradeHint.value!,
                      style: const TextStyle(
                          fontSize: 13, color: AppColors.danger)),
                ],
                for (final a in (rc.payload['announcements'] as List? ?? []))
                  if (a is Map && (a['text'] ?? '').toString().isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text((a['text'] ?? '').toString(),
                        style: TextStyle(
                            fontSize: 13,
                            color: a['level'] == 'critical'
                                ? AppColors.danger
                                : (a['level'] == 'warn'
                                    ? AppColors.warn
                                    : AppColors.textSub))),
                  ],
              ],
            ),
            actions: [
              ValueListenableBuilder<String?>(
                valueListenable: rc.upgradePackageUrl,
                builder: (_, pkg, __) => pkg == null
                    ? const SizedBox.shrink()
                    : ElevatedButton(
                        onPressed: () async {
                          Navigator.pop(ctx);
                          await AppUpdater.startUpdate(context, pkg);
                        },
                        child: const Text('立即更新'),
                      ),
              ),
              ValueListenableBuilder<String?>(
                valueListenable: rc.upgradePageUrl,
                builder: (_, page, __) => page == null
                    ? const SizedBox.shrink()
                    : TextButton(
                        onPressed: () async {
                          final uri = Uri.parse(page);
                          if (await canLaunchUrl(uri)) {
                            await launchUrl(uri, mode: LaunchMode.externalApplication);
                          }
                        },
                        child: const Text('前往升级页'),
                      ),
              ),
              TextButton(
                onPressed: () async {
                  setD(() => fetchTip = '正在检查…');
                  await rc.fetch();
                  setD(() => fetchTip = rc.appliedVersion > 0
                      ? '已是最新（配置 v${rc.appliedVersion}）'
                      : '暂时连不上，稍后会自动重试');
                },
                child: const Text('检查更新'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('关闭'),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _openChat(Conversation cv) async {
    if (MediaQuery.of(context).size.width > 720) {
      setState(() => _sel = cv);
      return;
    }
    await Navigator.push(
      context,
      MaterialPageRoute(
          builder: (_) => ChatScreen(conv: cv, myId: _myId, peerName: cv.title)),
    );
    _load(); // 返回后刷新最后消息
  }

  // ---------------- 新的朋友 ----------------

  /// 打开与某个人的单聊。**外壳（HomeShell）在通讯录里点人时调用它** ——
  /// 建会话的逻辑只有这一份，通讯录 Tab 不复制第二份（否则两处必然走歪）。
  Future<void> openWithUser(User u) async {
    try {
      final r = await ImApi().dm(u.id);
      if (!mounted) return;
      // 用 noteName：设过备注就显示备注，跟会话列表的标题保持一致
      await _openChat(
          Conversation(id: r['conversationId'], type: 'dm', title: u.noteName));
      if (mounted) _load(); // 打开后未读数变了，顺手刷角标
    } catch (e) {
      _toast(_msg(e));
    }
  }

  Future<void> _openNewFriends() async {
    // 在新朋友页点某个好友时返回该 User，语义是「打开跟 TA 的聊天」
    final u = await Navigator.push<User>(
      context,
      MaterialPageRoute(builder: (_) => const NewFriendsScreen()),
    );
    if (!mounted) return;
    _load();
    _refreshPendingCount();
    if (u == null) return;
    await openWithUser(u);
  }

  /// 打开「文件助手」（自己↔自己的会话，手机↔电脑传文件）。
  /// 通讯录好友列表第一行是同一个东西；这里是会话列表的快捷入口，
  /// 传文件是高频操作，多一个入口少一次翻页。
  Future<void> _openFileHelper() async {
    try {
      final r = await ImApi().fileHelper();
      final cid = (r['conversationId'] ?? 0) as int;
      if (cid == 0) return;
      await _openChat(
          Conversation(id: cid, type: 'filehelper', title: '文件助手'));
      if (mounted) _load(); // 新建的会话要出现在列表里
    } on ApiException catch (e) {
      _toast(e.status == 404
          ? '当前服务端版本还没有文件助手，升级服务端后即可使用'
          : e.message);
    } catch (e) {
      _toast(_msg(e));
    }
  }

  /// 发起群聊（龙哥 2026-10-10：客户端根本没有建群入口，群只能后台建）
  Future<void> _openCreateGroup() async {    final r = await Navigator.push<Map<String, dynamic>>(
      context,
      MaterialPageRoute(builder: (_) => const CreateGroupScreen()),
    );
    if (!mounted) return;
    await _load();
    final cid = (r?['conversationId'] ?? 0) as int;
    if (cid == 0) return;
    for (final c in _all) {
      if (c.id == cid) {
        await _openChat(c);
        break;
      }
    }
  }

  // ---------------- 远程协助 ----------------
  Future<void> _openRemote() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const RemoteHubScreen()),
    );
  }

  // ---------------- 消息搜索 ----------------
  Future<void> _openFavorites() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => FavoritesScreen(myId: _myId)),
    );
    if (mounted) _load();
  }

  Future<void> _openSearch() async {
    final cid = await Navigator.push<int>(
      context,
      MaterialPageRoute(builder: (_) => const SearchScreen()),
    );
    if (cid == null || !mounted) return;

    Conversation? cv;
    for (final c in _all) {
      if (c.id == cid) {
        cv = c;
        break;
      }
    }
    // 会话可能还没加载进来（刚建的会话），拉一次列表再找
    if (cv == null) {
      await _load();
      if (!mounted) return;
      for (final c in _all) {
        if (c.id == cid) {
          cv = c;
          break;
        }
      }
    }
    if (cv != null) await _openChat(cv);
  }

  // ---------------- 添加好友 / 发起聊天 ----------------
  void _openAdd() {
    final q = TextEditingController();
    List<dynamic> results = [];
    bool searching = false;

    showDialog(
      context: context,
      builder: (d) => StatefulBuilder(
        builder: (c, set) => AlertDialog(
          titlePadding: const EdgeInsets.fromLTRB(20, 20, 20, 6),
          contentPadding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
          title: const Text('添加好友 / 发起聊天'),
          content: SizedBox(
            width: 380,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: q,
                  autofocus: true,
                  decoration: InputDecoration(
                    hintText: '搜索账号或昵称',
                    prefixIcon: const Icon(Icons.search_rounded,
                        size: 20, color: AppColors.textWeak),
                    suffixIcon: q.text.isEmpty
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.close_rounded, size: 18),
                            onPressed: () {
                              q.clear();
                              set(() {
                                results = [];
                                searching = false;
                              });
                            },
                          ),
                  ),
                  onChanged: (v) async {
                    if (v.trim().isEmpty) {
                      set(() {
                        results = [];
                        searching = false;
                      });
                      return;
                    }
                    set(() => searching = true);
                    try {
                      final r = await ImApi().search(v.trim());
                      set(() {
                        results = r;
                        searching = false;
                      });
                    } catch (_) {
                      set(() => searching = false);
                    }
                  },
                ),
                const SizedBox(height: 8),
                if (searching)
                  const Padding(
                    padding: EdgeInsets.all(18),
                    child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2)),
                  )
                else if (results.isEmpty && q.text.isNotEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 22),
                    child: Text('没有找到匹配的用户',
                        style: TextStyle(color: AppColors.textWeak)),
                  )
                else
                  Flexible(
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: results.map((u) {
                          final name = u['nickname'] ?? u['username'] ?? '用户';
                          return Container(
                            margin: const EdgeInsets.only(bottom: 6),
                            decoration: BoxDecoration(
                              color: AppColors.surface,
                              borderRadius:
                                  BorderRadius.circular(AppRadii.md),
                            ),
                            child: ListTile(
                              contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 2),
                              leading: UserAvatar(name: name, size: 42),
                              title: Text(name,
                                  style: const TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w600)),
                              subtitle: Text('@${u['username']}',
                                  style: const TextStyle(fontSize: 12.5)),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  TextButton(
                                    onPressed: () async {
                                      final name =
                                          (u['nickname'] ?? u['username'] ?? '用户')
                                              .toString();
                                      // 先写认证附言（可选模板一键填入），再发申请。
                                      // 返回 null = 用户取消，不发。
                                      final msg = await showFriendAuthSheet(
                                        context,
                                        userId: u['id'] as int,
                                        peerName: name,
                                        peerAvatar: u['avatar']?.toString(),
                                      );
                                      if (msg == null || !mounted) return;
                                      try {
                                        final r = await ImApi().friendRequest(
                                            u['id'] as int,
                                            message: msg);
                                        if (!mounted) return;
                                        _toast(r['updated'] == true
                                            ? '验证消息已更新'
                                            : '已发送好友申请');
                                      } catch (e) {
                                        if (mounted) _toast(_msg(e));
                                      }
                                    },
                                    child: const Text('加好友'),
                                  ),
                                  const SizedBox(width: 4),
                                  FilledButton(
                                    onPressed: () async {
                                      try {
                                        final r = await ImApi().dm(u['id']);
                                        final conv = Conversation(
                                            id: r['conversationId'],
                                            type: 'dm',
                                            title: name);
                                        if (!context.mounted) return;
                                        Navigator.pop(d);
                                        await _load();
                                        await _openChat(conv);
                                      } catch (e) {
                                        if (mounted) _toast(_msg(e));
                                      }
                                    },
                                    style: FilledButton.styleFrom(
                                      backgroundColor: AppColors.brand,
                                      foregroundColor: Colors.white,
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 14),
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(
                                            AppRadii.sm),
                                      ),
                                    ),
                                    child: const Text('发消息'),
                                  ),
                                ],
                              ),
                            ),
                          );
                        }).toList(),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(d), child: const Text('关闭')),
          ],
        ),
      ),
    );
  }

  void _toast(String s) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));

  /// 菜单里的分组小标题。不可点、也不占正常行高 ——
  /// 只是把"功能"和"设置"分开，让人一眼知道哪些是干活用的、哪些是调设置的。
  PopupMenuItem<String> _menuGroup(String t) => PopupMenuItem<String>(
        enabled: false,
        height: 30,
        child: Text(t,
            style: const TextStyle(
                fontSize: 11.5,
                color: AppColors.textWeak,
                letterSpacing: 0.6)),
      );

  // ---------------- 侧边栏 ----------------
  String _preview(Conversation cv) {
    final c = cv.lastContent ?? '';
    if (c.isEmpty) return '还没有消息';
    if (c.startsWith('/files/')) {
      return Media.isImagePath(c) ? '[图片]' : '[文件]';
    }
    return c;
  }

  /// 会话头像：群聊用成员头像拼的九宫格，单聊用对方真实头像。
  ///
  /// 以前两种会话都用「名字首字 + 哈希渐变」，一排看下去分不出哪个是群 ——
  /// 现在群聊是拼图 + 右下角「群」徽标，一眼就能分开。
  /// 顺带修了一个老问题：单聊明明有 avatar 字段，列表却从没用它，
  /// 所以设置了头像的人在这里也只显示首字。
  Widget _avatarFor(Conversation cv, String name) {
    if (cv.type == 'group') {
      return GroupAvatar(members: cv.memberAvatars, size: 46, radius: 15);
    }
    // 「文件助手」是自己↔自己的会话，没有"对方头像"可用，固定画成文件夹
    if (cv.isFileHelper) return const FileHelperAvatar(size: 46, radius: 15);
    return UserAvatar(name: name, size: 46, radius: 15, imageUrl: cv.avatar);
  }

  Widget _tile(Conversation cv) {
    final name = cv.title ?? (cv.type == 'group' ? '群聊' : '会话');
    final selected = _sel?.id == cv.id;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Material(
        color: selected ? AppColors.surfaceHi : Colors.transparent,
        borderRadius: BorderRadius.circular(AppRadii.md),
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadii.md),
          onTap: () => _openChat(cv),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 10, 12, 10),
            child: Row(
              children: [
                _avatarFor(cv, name),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                                color: AppColors.text,
                              ),
                            ),
                          ),
                          if (cv.hasMention && cv.unread > 0)
                            Container(
                              margin: const EdgeInsets.only(left: 6),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 5, vertical: 1.5),
                              decoration: BoxDecoration(
                                color: const Color(0xFFF4685E)
                                    .withValues(alpha: 0.18),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: const Text(
                                '有人@我',
                                style: TextStyle(
                                    fontSize: 10.5,
                                    color: Color(0xFFF4685E),
                                    fontWeight: FontWeight.w600),
                              ),
                            ),
                          if (cv.unread > 0)
                            Container(
                              margin: const EdgeInsets.only(left: 6),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 2),
                              constraints: const BoxConstraints(minWidth: 19),
                              decoration: BoxDecoration(
                                color: AppColors.danger,
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Text(
                                cv.unread > 99 ? '99+' : '${cv.unread}',
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 10.5,
                                    height: 1.25,
                                    fontWeight: FontWeight.w600),
                              ),
                            ),
                          if (cv.lastAt != null)
                            Padding(
                              padding: const EdgeInsets.only(left: 6),
                              child: Text(
                                TimeFmt.listStamp(cv.lastAt!),
                                style: const TextStyle(
                                    fontSize: 11.5, color: AppColors.textWeak),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _preview(cv),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 13, color: AppColors.textSub),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _empty() => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const BrandLogo(size: 62),
            const SizedBox(height: 18),
            const Text('还没有会话',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            const Text('搜索好友，发起第一次聊天',
                style: TextStyle(color: AppColors.textSub, fontSize: 13)),
            const SizedBox(height: 20),
            SizedBox(
              width: 160,
              child: FilledButton.icon(
                onPressed: _openAdd,
                icon: const Icon(Icons.person_add_alt_rounded, size: 19),
                label: const Text('发起聊天'),
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.brand,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 13),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppRadii.md)),
                ),
              ),
            ),
          ],
        ),
      );

  Widget _listPane() {
    if (_loading) {
      return const Center(
          child: SizedBox(
              width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)));
    }
    if (_error != null) {
      final isNetwork =
          _lastErr is ApiException && (_lastErr as ApiException).isNetwork;
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                isNetwork
                    ? Icons.cloud_off_rounded
                    : Icons.error_outline_rounded,
                size: 42,
                color: AppColors.textWeak,
              ),
              const SizedBox(height: 12),
              Text(_error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: AppColors.textSub, fontSize: 13)),
              const SizedBox(height: 18),
              // 主按钮：重试（同设置不变的情况下也能好转——比如对端刚重启）
              SizedBox(
                width: 200,
                child: OutlinedButton.icon(
                  onPressed: _init,
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                  label: const Text('重试'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.brand,
                    side: const BorderSide(color: AppColors.brand),
                    padding: const EdgeInsets.symmetric(vertical: 11),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(AppRadii.md)),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              // 次按钮：直接打开服务器设置（卡死用户的救命口）
              SizedBox(
                width: 200,
                child: TextButton.icon(
                  onPressed: _openServerAndRetry,
                  icon: const Icon(Icons.dns_rounded, size: 17),
                  label: const Text('切换服务器'),
                  style: TextButton.styleFrom(
                    foregroundColor: AppColors.textSub,
                    padding: const EdgeInsets.symmetric(vertical: 11),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(AppRadii.md)),
                  ),
                ),
              ),
              const SizedBox(height: 4),
              // 退出登录（小字链接）
              TextButton(
                onPressed: _logout,
                style: TextButton.styleFrom(
                  foregroundColor: AppColors.danger,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 6),
                ),
                child: const Text('退出登录', style: TextStyle(fontSize: 12.5)),
              ),
            ],
          ),
        ),
      );
    }

    final items = _all;
    return RefreshIndicator(
      color: AppColors.brand,
      backgroundColor: AppColors.surfaceHi,
      onRefresh: _load,
      child: Column(
        children: [
          Expanded(
            child: items.isEmpty
                ? _empty()
                : ListView.builder(
                    padding: const EdgeInsets.only(top: 6, bottom: 12),
                    itemCount: items.length,
                    itemBuilder: (c, i) => _tile(items[i]),
                  ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          titleSpacing: 16,
          title: Row(
            children: [
              const BrandLogo(size: 28),
              const SizedBox(width: 10),
              // 标题跟随服务端公司名（「好又多小智」）。以前这里写死『小智 IM』，
              // 管理台改了公司名，登录页变了、登进来又变回去 —— 龙哥 2026-09-18
              // 报的"服务器改了客户端没改"就是这个。规则只在 Workspace.brand 一处。
              ValueListenableBuilder<String>(
                valueListenable: Workspace.brand,
                builder: (_, b, __) => Text(b,
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.w700)),
              ),
            ],
          ),
          actions: [
            ValueListenableBuilder<ConnState>(
              valueListenable: SocketService().state,
              builder: (_, s, __) {
                final (color, tip) = switch (s) {
                  ConnState.online => (AppColors.online, '实时连接正常（点击重连）'),
                  ConnState.connecting => (AppColors.brand, '正在连接…'),
                  ConnState.offline => (AppColors.danger, '连接已断开（点击重连）'),
                  _ => (AppColors.textWeak, '未连接'),
                };
                return IconButton(
                  tooltip: tip,
                  onPressed: () => SocketService().reconnect(),
                  icon: Icon(Icons.circle, size: 11, color: color),
                );
              },
            ),
            IconButton(
              tooltip: '搜索好友与聊天记录',
              onPressed: _openSearch,
              icon: const Icon(Icons.search_rounded),
            ),
            IconButton(
              tooltip: '发起聊天',
              onPressed: _openAdd,
              icon: const Icon(Icons.person_add_alt_rounded),
            ),
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert_rounded),
              onSelected: (v) {
                if (v == 'fav') _openFavorites();
                if (v == 'server') _openServer();
                // 首页顶部的常驻企业条撤掉之后（龙哥 2026-10-06），
                // 这里成了切换企业的唯一入口 —— 入口必须显性存在。
                if (v == 'switchco') showEnterpriseSwitcher(context);
                if (v == 'logout') _logout();
                if (v == 'tray') _cycleCloseAction();
                if (v == 'sound') _toggleSound();
                if (v == 'about') _openAbout();
                if (v == 'remote') _openRemote();
                if (v == 'newfriends') _openNewFriends();
                if (v == 'newgroup') _openCreateGroup();
                if (v == 'filehelper') _openFileHelper();
              },
              // 菜单只放"不常用的功能 + 设置"。
              // 工作台 / 组织机构 / 个人信息已经提到一级导航（见 HomeShell），
              // 从菜单里删掉，免得同一个功能两个入口、用户还得猜哪个是"正门"。
              // 也删掉了「刷新列表」—— 列表本来就支持下拉刷新，菜单里再放一个是重复。
              itemBuilder: (_) => [
                _menuGroup('功能'),
                // 工作模式下「通讯录」标签是组织架构，不含好友申请，所以"新的朋友"
                // 留在菜单里，否则切换模式前收到的申请就再也点不到了；
                // 普通模式下它就是「通讯录」标签本身，菜单里不再重复放一份。
                if (Workspace.isWork)
                  PopupMenuItem(
                      value: 'newfriends',
                      child: Row(children: [
                        const Icon(Icons.person_add_alt_1_rounded, size: 19),
                        const SizedBox(width: 10),
                        const Text('新的朋友'),
                        if (_pendingCount > 0) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 1),
                            decoration: BoxDecoration(
                              color: AppColors.danger,
                              borderRadius: BorderRadius.circular(AppRadii.pill),
                            ),
                            child: Text(
                              '$_pendingCount',
                              style: const TextStyle(
                                  fontSize: 10.5,
                                  color: Colors.white,
                                  fontWeight: FontWeight.w700),
                            ),
                          ),
                        ],
                      ])),
                const PopupMenuItem(
                    value: 'newgroup',
                    child: Row(children: [
                      Icon(Icons.group_add_rounded, size: 19),
                      SizedBox(width: 10),
                      Text('发起群聊')
                    ])),
                const PopupMenuItem(
                    value: 'filehelper',
                    child: Row(children: [
                      Icon(Icons.folder_copy_rounded, size: 19),
                      SizedBox(width: 10),
                      Text('文件助手')
                    ])),
                const PopupMenuItem(
                    value: 'fav',
                    child: Row(children: [
                      Icon(Icons.star_border_rounded, size: 19),
                      SizedBox(width: 10),
                      Text('我的收藏')
                    ])),
                const PopupMenuItem(
                    value: 'remote',
                    child: Row(children: [
                      Icon(Icons.screenshot_monitor_outlined, size: 19),
                      SizedBox(width: 10),
                      Text('远程协助')
                    ])),
                const PopupMenuDivider(),
                _menuGroup('设置'),
                // 切换企业：从首页顶部常驻条挪过来（龙哥 2026-10-06 真机反馈，
                // 顶条把整个界面往下顶，撤掉）。多企业功能入口必须显性存在。
                const PopupMenuItem(
                    value: 'switchco',
                    child: Row(children: [
                      Icon(Icons.swap_horiz_rounded, size: 19),
                      SizedBox(width: 10),
                      Text('切换企业')
                    ])),
                const PopupMenuItem(
                    value: 'server',
                    child: Row(children: [
                      Icon(Icons.dns_rounded, size: 19),
                      SizedBox(width: 10),
                      Text('服务器设置')
                    ])),
                PopupMenuItem(
                    value: 'sound',
                    child: Row(children: [
                      Icon(
                          _soundOn
                              ? Icons.volume_up_rounded
                              : Icons.volume_off_rounded,
                          size: 19),
                      const SizedBox(width: 10),
                      Text(_soundOn ? '提示音：开' : '提示音：关')
                    ])),
                // 只在桌面端出现：托盘是桌面概念，手机上讲"缩到托盘"没有意义
                if (TrayService.supported)
                  PopupMenuItem(
                      value: 'tray',
                      child: Row(children: [
                        const Icon(Icons.cancel_outlined, size: 19),
                        const SizedBox(width: 10),
                        Text('点×时：${TrayService.instance.actionLabel}')
                      ])),
                const PopupMenuItem(
                    value: 'about',
                    child: Row(children: [
                      Icon(Icons.info_outline_rounded, size: 19),
                      SizedBox(width: 10),
                      Text('关于 / 检查配置')
                    ])),
                const PopupMenuDivider(),
                const PopupMenuItem(
                    value: 'logout',
                    child: Row(children: [
                      Icon(Icons.logout_rounded, size: 19, color: AppColors.danger),
                      SizedBox(width: 10),
                      Text('退出登录', style: TextStyle(color: AppColors.danger))
                    ])),
              ],
            ),
            const SizedBox(width: 6),
          ],
        ),
        body: LayoutBuilder(
          builder: (c, box) {
            final wide = box.maxWidth > 720;
            if (!wide) return _listPane();
            return Row(
              children: [
                SizedBox(width: 320, child: _listPane()),
                const VerticalDivider(width: 1),
                Expanded(
                  child: _sel == null
                      ? Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.forum_rounded,
                                  size: 56,
                                  color: AppColors.textWeak
                                      .withValues(alpha: 0.5)),
                              const SizedBox(height: 14),
                              const Text('选择一个会话开始聊天',
                                  style: TextStyle(
                                      color: AppColors.textSub, fontSize: 14)),
                            ],
                          ),
                        )
                      : ChatScreen(
                          key: ValueKey(_sel!.id),
                          conv: _sel!,
                          myId: _myId,
                          peerName: _sel!.title,
                          embedded: true,
                        ),
                ),
              ],
            );
          },
        ),
      );
}
