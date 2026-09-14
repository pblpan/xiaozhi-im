import 'package:flutter/material.dart';

import '../core/badges.dart';
import '../core/theme.dart';
import '../core/workspace.dart';
import '../models.dart';
import 'conversations.dart';
import 'friends_new.dart';
import 'org_screen.dart';
import 'profile.dart';
import 'workbench.dart';

/// 首页外壳：把「消息 / 工作台 / 通讯录 / 我」摆到一级导航上。
///
/// 为什么要这一层：以前所有页面都从右上角「⋮」菜单进，12 项混装在同一列 ——
/// 工作台、组织机构这些**每天要用的功能**和服务器设置、退出登录挤在一起，
/// 工作模式下同事想打个卡得点「⋮ → 工作台」两步。钉钉 / 企微 / 飞书都把这个
/// 收成底部标签栏（手机）/ 左侧导航条（宽屏），常用功能一步直达。
///
/// 两个模式给两套导航：普通模式（家用 / 朋友）不长工作台与组织通讯录，
/// 免得塞一堆用不到的入口；工作模式才长出它们。
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

/// 一个标签的定义。badge/danger 是**通知器**而不是数字：未读会随消息变化，
/// 直接传值的话外壳得自己订阅一堆刷新时机，传通知器让角标自己跟着变。
class HomeTab {
  const HomeTab({
    required this.icon,
    required this.activeIcon,
    required this.label,
    this.badge,
    this.danger,
  });

  final IconData icon;
  final IconData activeIcon;
  final String label;
  final ValueNotifier<int>? badge;
  final ValueNotifier<bool>? danger;
}

/// 首页标签结构（**纯函数**，不依赖 BuildContext）。
///
/// 抽出来单独放着有明确理由：这套结构就是"哪些功能是一级入口"这件事本身，
/// 是这个版本改动的核心。放在 State 私有方法里就只能靠肉眼看代码，
/// 抽成纯函数后可以直接单测（见 test/home_shell_test.dart）。
///
/// 两套结构：
///   工作模式 → 消息 / 工作台 / 通讯录(组织架构) / 我
///   普通模式 → 消息 / 通讯录(好友) / 我      —— 不长出用不到的工作入口
List<HomeTab> homeTabs(bool work) => [
      HomeTab(
        icon: Icons.chat_bubble_outline_rounded,
        activeIcon: Icons.chat_bubble_rounded,
        label: '消息',
        badge: Badges.instance.unread,
        danger: Badges.instance.mention,
      ),
      if (work)
        const HomeTab(
          icon: Icons.grid_view_outlined,
          activeIcon: Icons.grid_view_rounded,
          label: '工作台',
        ),
      HomeTab(
        // 工作模式的通讯录是组织架构，普通模式是好友
        icon: work
            ? Icons.corporate_fare_outlined
            : Icons.people_outline_rounded,
        activeIcon: work ? Icons.corporate_fare_rounded : Icons.people_rounded,
        label: '通讯录',
        // 组织成员没有"待处理申请"的概念，角标只给普通模式的好友申请
        badge: work ? null : Badges.instance.pendingFriends,
      ),
      const HomeTab(
        icon: Icons.person_outline_rounded,
        activeIcon: Icons.person_rounded,
        label: '我',
      ),
    ];

/// 带角标的导航图标（**独立组件**，与外壳解耦后可以直接 render 测试）。
///
/// 抽出来的理由不只是复用：角标是这一版新增的、也是最容易"看着对其实不刷新"的
/// 地方 —— 未读与 @提醒 是两个独立通知器，只订其中一个的话，另一种变化不会重建
/// （表现是"有人 @我 了但角标还是灰的"）。抽成组件后可以在 widget 测试里
/// 真的渲染一遍、真的改通知器的值，验证两边都跟得上。
class NavBadgeIcon extends StatelessWidget {
  const NavBadgeIcon({super.key, required this.tab, required this.active});

  final HomeTab tab;
  final bool active;

  /// 没有 @提醒 通知器时用的占位。必须是**常量**：每次 build 新建一个
  /// 会让每帧都换订阅对象，白白重建。
  static final ValueNotifier<bool> _noMention = ValueNotifier<bool>(false);

  @override
  Widget build(BuildContext context) {
    final icon = Icon(active ? tab.activeIcon : tab.icon);
    final badge = tab.badge;
    if (badge == null) {
      final danger = tab.danger;
      if (danger == null) return icon;
      // 只有"提醒"没有计数：用一个小圆点
      return ValueListenableBuilder<bool>(
        valueListenable: danger,
        builder: (_, on, __) => on ? Badge(child: icon) : icon,
      );
    }
    return ValueListenableBuilder<int>(
      valueListenable: badge,
      builder: (_, n, __) => ValueListenableBuilder<bool>(
        // ⚠️ danger 必须**也订一层**：只在 badge 的回调里读 danger.value 的话，
        // 未读数不变而 @提醒 变化时不会重建，红点就不会亮（难查的一类问题）。
        valueListenable: tab.danger ?? _noMention,
        builder: (_, mentionOn, __) => Badge(
          isLabelVisible: n > 0,
          // 有人 @我 → 用品牌红，提示"这条得看"，与普通未读区分开
          backgroundColor: mentionOn ? AppColors.danger : null,
          label: Text(n > 99 ? '99+' : '$n'),
          child: icon,
        ),
      ),
    );
  }
}

class _HomeShellState extends State<HomeShell> {
  final _convKey = GlobalKey<ConversationsScreenState>();

  /// 当前标签下标
  int _index = 0;

  /// 已经打开过的标签：没打开过的标签**先不构建**。
  /// IndexedStack 会把所有子页都建出来（等于启动时把工作台、组织通讯录、
  /// 个人资料全部请求一遍），既慢又可能因为"还没建组织"之类弹出无关错误。
  /// 访问过之后再构建，且因为 IndexedStack 保活，来回切不会丢状态。
  final Set<int> _visited = {0};

  /// 上一次看到的模式。用来判断"标签结构变了没有"（工作/普通切换会增删标签，
  /// 下标含义随之改变，旧的 _visited / _index 不能继续用）
  bool _lastWork = Workspace.isWork;

  @override
  void initState() {
    super.initState();
    // 进首页时重新确认一次服务器模式（管理员可能刚把服务器切成工作模式）。
    // 拿不到就保持上次缓存的值 —— 导航不会因为一次网络失败而乱跳。
    Workspace.refresh();
    Workspace.mode.addListener(_onModeChanged);
  }

  @override
  void dispose() {
    Workspace.mode.removeListener(_onModeChanged);
    super.dispose();
  }

  void _onModeChanged() {
    final w = Workspace.isWork;
    if (w == _lastWork) return;
    // 标签数量/含义变了：回到消息页并忘掉访问记录，避免下标错位到别的页面
    setState(() {
      _lastWork = w;
      _index = 0;
      _visited
        ..clear()
        ..add(0);
    });
  }

  /// 通讯录里点了某个人：切到「消息」并打开跟他的会话。
  /// 建会话的逻辑只在会话列表页那一份，这里只负责切页 + 转交（不复制第二份）。
  void _openChatWith(User u) {
    setState(() => _index = 0);
    _convKey.currentState?.openWithUser(u);
  }

  void _select(int i) {
    setState(() {
      _index = i;
      _visited.add(i);
    });
  }

  Widget _pageFor(int i, bool work) {
    if (!_visited.contains(i)) return const SizedBox.shrink();
    return switch ((work, i)) {
      (_, 0) => ConversationsScreen(key: _convKey),
      (true, 1) => const WorkbenchPage(),
      (true, 2) => OrgScreen(onPick: _openChatWith),
      (false, 1) => NewFriendsScreen(onPick: _openChatWith),
      _ => const ProfileScreen(),
    };
  }

  @override
  Widget build(BuildContext context) {
    // 模式变了要换一整套标签，所以整壳跟着它重建（只在真的变化时才触发）
    return ValueListenableBuilder<String>(
      valueListenable: Workspace.mode,
      builder: (ctx, mode, _) {
        final work = mode == Workspace.work;
        final tabs = homeTabs(work);
        // 夹一下：模式切换的同一帧里 _index 可能还指向已经不存在的标签
        final idx = _index < tabs.length ? _index : tabs.length - 1;

        return LayoutBuilder(builder: (c, box) {
          // 宽屏（桌面）用左侧竖排导航条 + 内容区：桌面窗口横向空间富余，
          // 底部横条既挤内容又离视线远。窄屏（手机）才是底部标签栏。
          final wide = box.maxWidth > 720;
          final body = IndexedStack(
            index: idx,
            children: [for (var i = 0; i < tabs.length; i++) _pageFor(i, work)],
          );

          if (!wide) {
            return Scaffold(
              body: body,
              bottomNavigationBar: NavigationBar(
                height: 62,
                backgroundColor: AppColors.bgElevated,
                indicatorColor: AppColors.brand.withValues(alpha: 0.18),
                selectedIndex: idx,
                onDestinationSelected: _select,
                destinations: [
                  for (final t in tabs)
                    NavigationDestination(
                      icon: NavBadgeIcon(tab: t, active: false),
                      selectedIcon: NavBadgeIcon(tab: t, active: true),
                      label: t.label,
                    ),
                ],
              ),
            );
          }

          return Scaffold(
            body: Row(
              children: [
                NavigationRail(
                  backgroundColor: AppColors.bgElevated,
                  selectedIndex: idx,
                  onDestinationSelected: _select,
                  labelType: NavigationRailLabelType.all,
                  indicatorColor: AppColors.brand.withValues(alpha: 0.18),
                  selectedIconTheme:
                      const IconThemeData(color: AppColors.brand, size: 23),
                  unselectedIconTheme:
                      const IconThemeData(color: AppColors.textSub, size: 22),
                  selectedLabelTextStyle: const TextStyle(
                      color: AppColors.brand,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600),
                  unselectedLabelTextStyle: const TextStyle(
                      color: AppColors.textSub, fontSize: 11.5),
                  destinations: [
                    for (final t in tabs)
                      NavigationRailDestination(
                        icon: NavBadgeIcon(tab: t, active: false),
                        selectedIcon: NavBadgeIcon(tab: t, active: true),
                        label: Text(t.label),
                      ),
                  ],
                ),
                const VerticalDivider(width: 1, color: AppColors.divider),
                Expanded(child: body),
              ],
            ),
          );
        });
      },
    );
  }
}
