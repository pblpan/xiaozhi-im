import 'package:flutter/material.dart';
import 'package:xiaozhi_im_client/core/config.dart';
import 'package:xiaozhi_im_client/core/server_profile.dart';
import 'package:xiaozhi_im_client/core/session_manager.dart';
import 'package:xiaozhi_im_client/core/theme.dart';
import 'package:xiaozhi_im_client/screens/add_enterprise.dart';
import 'package:xiaozhi_im_client/socket.dart';

/// 企业切换器（龙哥 2026-10-01 需求的核心 UI）。
///
/// 组件：
///   · [EnterpriseSwitcherSheet] —— 底部弹层，列出所有企业：企业名 + 两个服务器地址的
///     在线/离线点 + 未读数 + 激活高亮，点一下整域切换；另有重命名 / 删除，底部「+ 添加企业」。
///     入口在会话页右上角「⋮ → 切换企业」。
///   · [ConnStatusChip] —— 连接状态（点 + 文案），用在「服务器设置」弹窗顶部。
///   · [EnterpriseHeader] —— 只剩一件事：后台企业来新消息时出提醒条，没有就不占空间。
///
/// ── 为什么首页顶部不再有常驻企业条（龙哥 2026-10-06 真机截图反馈）────────
/// 顶上那条「● 已连接 ∨」占了 34px + 一整条状态栏留白，把整个界面往下顶；
/// 而它显示的连接状态与会话页 AppBar 里那个点**是同一个信息**（重复两遍），
/// 切换企业又是低频动作。所以：
///   ① 顶条整条撤掉，界面直接顶到系统状态栏下面；
///   ② 连接状态挪进「⋮ → 服务器设置」弹窗顶部（排查网络时正好要在这里看）；
///   ③ 切换企业挪进「⋮ → 切换企业」；
///   ④ [BackgroundReminderBar] 保留原位，但没有提醒时整条不占空间。

// ---- 连接状态 → 颜色 / 文案 ----
Color connStateColor(ConnState s) {
  switch (s) {
    case ConnState.online:
      return AppColors.online;
    case ConnState.connecting:
      return AppColors.warn;
    case ConnState.offline:
      return AppColors.danger;
    default:
      return AppColors.textWeak;
  }
}

String connStateText(ConnState s) {
  switch (s) {
    case ConnState.online:
      return '已连接';
    case ConnState.connecting:
      return '连接中';
    case ConnState.offline:
      return '离线';
    default:
      return '未连接';
  }
}

/// 无激活企业时的占位连接状态（恒 idle），避免给空 id 建无用 notifier。
final ValueNotifier<ConnState> _idleNotifier =
    ValueNotifier<ConnState>(ConnState.idle);

/// 当前应当展示的连接状态：跟激活企业走（多企业时各域各连各的），
/// 没有激活企业（登录前 / 已登出）就退回全局 socket 状态。
ValueNotifier<ConnState> activeLinkNotifier() {
  final sm = SessionManager.instance;
  final active = sm.active;
  return active != null ? sm.linkStateOf(active.id) : _idleNotifier;
}

/// 连接状态小徽章：一个点 + 一行字（已连接 / 连接中 / 离线 / 未连接）。
///
/// 从首页顶条撤下来之后，这里成了连接状态的**唯一文字出口**，
/// 目前用在「服务器设置」弹窗顶部 —— 排查网络时打开就能看到当前通不通。
class ConnStatusChip extends StatelessWidget {
  final double dotSize;
  final double fontSize;

  const ConnStatusChip({super.key, this.dotSize = 9, this.fontSize = 12});

  @override
  Widget build(BuildContext context) {
    final sm = SessionManager.instance;
    final active = sm.active;
    return ValueListenableBuilder<ConnState>(
      valueListenable: activeLinkNotifier(),
      builder: (_, state, __) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: dotSize,
            height: dotSize,
            decoration:
                BoxDecoration(color: connStateColor(state), shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(connStateText(state),
              style: TextStyle(fontSize: fontSize, color: connStateColor(state))),
          // 多企业时点开能确认是哪家（单企业就没什么可确认的，省掉）
          if (sm.profiles.length > 1 && active != null) ...[
            const SizedBox(width: 6),
            Text(active.name,
                style: TextStyle(
                    fontSize: fontSize - 1, color: AppColors.textSub)),
          ],
        ],
      ),
    );
  }
}

class _StateDot extends StatelessWidget {
  final ConnState state;
  final double size;
  const _StateDot({required this.state, this.size = 8});
  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: connStateColor(state),
          shape: BoxShape.circle,
        ),
      );
}

/// 由档案 id 派生一个稳定颜色（不依赖任何外部包）。
Color enterpriseColor(String id) {
  const palette = [
    AppColors.brand,
    AppColors.brand2,
    Colors.orange,
    Colors.purple,
    Colors.blue,
    Colors.teal,
  ];
  var h = 0;
  for (final c in id.codeUnits) {
    h = (h * 31 + c) & 0x7fffffff;
  }
  return palette[h % palette.length];
}

/// 首页顶部的企业条 + 后台提醒条。
class EnterpriseHeader extends StatefulWidget {
  const EnterpriseHeader({super.key});

  @override
  State<EnterpriseHeader> createState() => _EnterpriseHeaderState();
}

class _EnterpriseHeaderState extends State<EnterpriseHeader> {
  final _sm = SessionManager.instance;

  void _onChange() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    _sm.profilesVersion.addListener(_onChange);
    _sm.domainVersion.addListener(_onChange);
    _sm.bgNotify.addListener(_onChange);
  }

  @override
  void dispose() {
    _sm.profilesVersion.removeListener(_onChange);
    _sm.domainVersion.removeListener(_onChange);
    _sm.bgNotify.removeListener(_onChange);
    super.dispose();
  }

  /// 有未读 / 待处理好友申请的非激活企业（提醒条的数据源）。
  List<ServerProfile> get _bgWithUnread {
    final out = <ServerProfile>[];
    for (final p in _sm.profiles) {
      if (p.id == _sm.activeId) continue;
      final b = _sm.badgesOf(p.id);
      if (b.unread.value > 0 || b.pending.value > 0) out.add(p);
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final bg = _bgWithUnread;
    // 没有后台企业提醒 → 整条不占任何空间（连 SafeArea 都不占），
    // 让下面的 AppBar 自己顶到系统状态栏下面 —— 龙哥 2026-10-06 真机截图要求
    // "整个界面移到上面画线的地方"。原来这条常驻 34px + 状态栏留白，白白往下顶。
    if (bg.isEmpty) return const SizedBox.shrink();
    // ⚠️ 提醒条要钉在系统状态栏之下，所以仍用 SafeArea 顶开状态栏占位；
    //    外层 Material 填 bgElevated，让占位区和提醒条同色。
    return Material(
      color: AppColors.bgElevated,
      child: SafeArea(
        top: true,
        bottom: false,
        left: false,
        right: false,
        child: Column(
          children: [
            for (final p in bg)
              BackgroundReminderBar(
                profile: p,
                onTap: () => SessionManager.instance.setActive(p.id),
              ),
          ],
        ),
      ),
    );
  }
}

/// 弹出企业切换面板（底部弹层）。
///
/// 首页顶部的常驻条撤掉之后（见文件头注释），这里成了唯一入口 ——
/// 会话页「⋮ → 切换企业」调的就是它。入口必须显性存在：
/// "一个入口藏在别人页面里 = 没有入口"。
Future<void> showEnterpriseSwitcher(BuildContext context) {
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.bgElevated,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadii.lg)),
    ),
    builder: (_) => const EnterpriseSwitcherSheet(),
  );
}

/// 后台企业收到新消息时的提醒条：点一下快速切换过去。
class BackgroundReminderBar extends StatelessWidget {
  final ServerProfile profile;
  final VoidCallback onTap;

  const BackgroundReminderBar({
    super.key,
    required this.profile,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final b = SessionManager.instance.badgesOf(profile.id);
    final unread = b.unread.value;
    final pending = b.pending.value;
    final tail = unread > 0 ? '$unread 条新消息' : '$pending 条好友申请';
    return Material(
      color: AppColors.brand.withValues(alpha: 0.14),
      child: InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          child: Row(
            children: [
              const Icon(Icons.notifications_active_rounded,
                  size: 16, color: AppColors.brand),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${profile.name} 有 $tail，点击切换',
                  style: const TextStyle(
                    fontSize: 12.5,
                    color: AppColors.text,
                  ),
                ),
              ),
              const Icon(Icons.swap_horiz_rounded,
                  size: 18, color: AppColors.brand),
            ],
          ),
        ),
      ),
    );
  }
}

/// 底部企业切换面板。
class EnterpriseSwitcherSheet extends StatefulWidget {
  const EnterpriseSwitcherSheet({super.key});

  @override
  State<EnterpriseSwitcherSheet> createState() =>
      _EnterpriseSwitcherSheetState();
}

class _EnterpriseSwitcherSheetState extends State<EnterpriseSwitcherSheet> {
  final _sm = SessionManager.instance;
  final Map<String, bool> _reach = {}; // url -> 可达
  bool _probing = false;
  VoidCallback? _off;

  @override
  void initState() {
    super.initState();
    _sm.profilesVersion.addListener(_rebuild);
    _sm.bgNotify.addListener(_rebuild);
    _off = () {
      _sm.profilesVersion.removeListener(_rebuild);
      _sm.bgNotify.removeListener(_rebuild);
    };
    _probeAll();
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _off?.call();
    super.dispose();
  }

  /// 探测每个档案的内网 / 外网地址是否可达，显示"两个地址都在链接状态"。
  Future<void> _probeAll() async {
    if (mounted) setState(() => _probing = true);
    final urls = <String>{};
    for (final p in _sm.profiles) {
      if (p.lan.isNotEmpty) urls.add(p.lan);
      if (p.wan.isNotEmpty) urls.add(p.wan);
    }
    final results = <String, bool>{};
    for (final u in urls) {
      results[u] = await Config.isReachable(u);
    }
    if (!mounted) return;
    setState(() {
      _reach.addAll(results);
      _probing = false;
    });
  }

  void _switchTo(String id) {
    Navigator.pop(context);
    SessionManager.instance.setActive(id);
  }

  Future<void> _rename(String id) async {
    final pr = _sm.profiles.where((x) => x.id == id).isEmpty
        ? null
        : _sm.profiles.firstWhere((x) => x.id == id);
    if (pr == null) return;
    final ctrl = TextEditingController(text: pr.name);
    final name = await showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('重命名企业'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: '企业名称'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(d, ctrl.text.trim()),
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.brand,
              foregroundColor: Colors.white,
            ),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (name != null && name.isNotEmpty) {
      await SessionManager.instance.renameProfile(id, name);
    }
  }

  Future<void> _delete(String id) async {
    final pr = _sm.profiles.firstWhere((x) => x.id == id);
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('删除该企业？'),
        content: Text(
          '将移除「${pr.name}」的服务器与登录信息，并断开它的后台连接。\n'
          '之后需要从头登录才能再次使用这家企业。',
          style: const TextStyle(height: 1.6),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.danger,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(d, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok == true) {
      Navigator.pop(context); // 先关面板
      await SessionManager.instance.removeProfile(id);
    }
  }

  Widget _addrLine(String label, String url) {
    final ok = url.isEmpty ? null : _reach[url];
    Color? dot;
    if (ok == true) dot = AppColors.online;
    if (ok == false) dot = AppColors.danger;
    return Row(
      children: [
        if (dot != null)
          Container(
            width: 6,
            height: 6,
            margin: const EdgeInsets.only(right: 6),
            decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
          )
        else
          const SizedBox(width: 12),
        Text(
          label,
          style: const TextStyle(fontSize: 11, color: AppColors.textWeak),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            url.isEmpty ? '未填写' : url,
            style: const TextStyle(
              fontSize: 11.5,
              fontFamily: 'monospace',
              color: AppColors.textSub,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final profiles = _sm.profiles;
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 顶部把手 + 标题 + 刷新
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 10, 4),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    '切换企业',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: AppColors.text,
                    ),
                  ),
                ),
                if (_probing)
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  IconButton(
                    tooltip: '刷新连接状态',
                    onPressed: _probeAll,
                    icon: const Icon(Icons.refresh_rounded, size: 18),
                    color: AppColors.textSub,
                  ),
              ],
            ),
          ),
          const Divider(height: 1, color: AppColors.divider),
          Flexible(
            child: ListView.separated(
              shrinkWrap: true,
              padding: const EdgeInsets.symmetric(vertical: 6),
              itemCount: profiles.length,
              separatorBuilder: (_, __) =>
                  const Divider(height: 1, color: AppColors.divider),
              itemBuilder: (_, i) {
                final pr = profiles[i];
                final isActive = pr.id == _sm.activeId;
                final state = _sm.linkStateOf(pr.id).value;
                final badges = _sm.badgesOf(pr.id);
                final unread = badges.unread.value;
                final pending = badges.pending.value;
                return InkWell(
                  onTap: isActive ? null : () => _switchTo(pr.id),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 11),
                    child: Row(
                      children: [
                        Container(
                          width: 38,
                          height: 38,
                          decoration: BoxDecoration(
                            color: enterpriseColor(pr.id).withValues(alpha: 0.18),
                            shape: BoxShape.circle,
                          ),
                          child: Center(
                            child: Text(
                              pr.name.isNotEmpty ? pr.name[0] : '?',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                                color: enterpriseColor(pr.id),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      pr.name,
                                      style: const TextStyle(
                                        fontSize: 14.5,
                                        fontWeight: FontWeight.w600,
                                        color: AppColors.text,
                                      ),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  if (isActive)
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 8, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: AppColors.brand
                                            .withValues(alpha: 0.16),
                                        borderRadius: BorderRadius.circular(999),
                                      ),
                                      child: const Text(
                                        '当前',
                                        style: TextStyle(
                                          fontSize: 11,
                                          color: AppColors.brand,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                              const SizedBox(height: 5),
                              _addrLine('内网', pr.lan),
                              const SizedBox(height: 3),
                              _addrLine('外网', pr.wan),
                              const SizedBox(height: 5),
                              Row(
                                children: [
                                  _StateDot(state: state, size: 7),
                                  const SizedBox(width: 6),
                                  Text(
                                    connStateText(state),
                                    style: const TextStyle(
                                      fontSize: 11.5,
                                      color: AppColors.textWeak,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                        // 未读 / 待处理角标
                        if (unread > 0 || pending > 0)
                          Container(
                            margin: const EdgeInsets.only(left: 8),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: AppColors.danger,
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              unread > 0 ? '$unread' : '$pending',
                              style: const TextStyle(
                                fontSize: 11.5,
                                color: Colors.white,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        // 操作菜单（重命名 / 删除）
                        if (!isActive)
                          PopupMenuButton<String>(
                            icon: const Icon(Icons.more_vert_rounded,
                                size: 18, color: AppColors.textSub),
                            color: AppColors.surface,
                            onSelected: (v) {
                              if (v == 'rename') _rename(pr.id);
                              if (v == 'delete') _delete(pr.id);
                            },
                            itemBuilder: (_) => const [
                              PopupMenuItem(
                                  value: 'rename', child: Text('重命名')),
                              PopupMenuItem(
                                  value: 'delete', child: Text('删除')),
                            ],
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          const Divider(height: 1, color: AppColors.divider),
          Padding(
            padding: const EdgeInsets.all(12),
            child: SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () {
                  Navigator.pop(context);
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => const AddEnterpriseScreen()),
                  );
                },
                icon: const Icon(Icons.add_rounded, size: 18),
                label: const Text('添加企业'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.brand,
                  side: const BorderSide(color: AppColors.border),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppRadii.sm),
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
