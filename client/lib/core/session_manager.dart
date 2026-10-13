import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'badges.dart';
import 'config.dart';
import 'discover.dart';
import 'server_profile.dart';
import '../socket.dart';
import 'storage.dart';
import 'workspace.dart';

/// 每个企业档案自己的角标（未读 / @提醒 / 待处理好友申请）。
///
/// 与全局 [Badges] 分离：全局 [Badges] 只服务于**激活企业**的导航栏，
/// 这里按档案 id 各存一份，后台企业也能累计未读、在切换器和提醒条上显示。
class ProfileBadges {
  final ValueNotifier<int> unread = ValueNotifier<int>(0);
  final ValueNotifier<bool> mention = ValueNotifier<bool>(false);
  final ValueNotifier<int> pending = ValueNotifier<int>(0);
}

/// 多企业会话管理：所有服务器档案 + 当前激活项。
///
/// 设计铁律（与既定架构一致）：
///   · **激活路径完全复用旧单服务器逻辑**——激活档案的 lan/wan/mode 镜像进
///     [Config]、token 镜像进 [Storage] 与 [ImApi]，[SocketService] 连的就是
///     激活档案；所以现有所有 `ImApi().xxx` / `Config.baseUrl` 调用无需改动，
///     自动命中激活服务器。
///   · **非激活企业**只靠 [BackgroundLinkService] 保持一条轻量 WS，收推送累计
///     未读 + 上报连接状态，不参与收发业务。
///   · 切换激活企业 = "整域切换"：好友 / 工作台 / 会话全部换成那家服务器的数据
///     （通过 [domainVersion] 通知各页重新拉取）。
class SessionManager {
  static final SessionManager instance = SessionManager._();
  SessionManager._();

  static const _kProfiles = 'xz_profiles';
  static const _kActive = 'xz_active_id';

  /// 所有企业档案。
  ///
  /// 🔴 初始化用**可写**空列表，不能用 `const []`：全新安装 + 局域网没扫到时
  /// load() 会把 profiles 留成不可变列表，之后 addProfile 一 add 就抛
  /// UnsupportedError，而调用链上没人接异常 —— 表现是服务器设置里"点保存
  /// 毫无反应"（龙哥 2026-10-13 实测）。所有写入点都必须保证列表可写。
  List<ServerProfile> profiles = [];

  /// 激活档案 id。
  String? activeId;

  /// 档案列表变化（新增 / 删除 / 改名）→ 切换器重建。
  final ValueNotifier<int> profilesVersion = ValueNotifier<int>(0);

  /// 数据域变化（切换激活企业）→ 会话/工作台/好友重新拉取。
  final ValueNotifier<int> domainVersion = ValueNotifier<int>(0);

  /// 后台（非激活）企业未读 / 待处理好友申请变化时 bump，
  /// 供主页面"后台企业收到新消息"提醒条刷新（不依赖轮询）。
  final ValueNotifier<int> bgNotify = ValueNotifier<int>(0);

  /// 通知主页面：某个后台企业的角标变了（新消息 / 新好友申请）。
  void notifyBackgroundChange() => bgNotify.value++;

  /// 每个档案的连接状态（激活企业由 [SocketService] 同步，其余由后台连接同步）。
  final Map<String, ValueNotifier<ConnState>> _linkStates = {};

  /// 每个档案的角标。
  final Map<String, ProfileBadges> _badges = {};

  /// 激活企业的"全局角标 ↔ 本档案角标"双向同步监听句柄（切换时摘掉旧的）。
  final List<VoidCallback> _activeBadgeSync = [];

  /// 激活企业连接状态监听的摘掉句柄。
  VoidCallback? _activeLinkUnsub;

  bool get hasProfiles => profiles.isNotEmpty;

  ServerProfile? get active {
    if (profiles.isEmpty) return null;
    for (final pr in profiles) {
      if (pr.id == activeId) return pr;
    }
    return profiles.first;
  }

  ProfileBadges badgesOf(String id) =>
      _badges.putIfAbsent(id, () => ProfileBadges());

  ValueNotifier<ConnState> linkStateOf(String id) =>
      _linkStates.putIfAbsent(id, () => ValueNotifier<ConnState>(ConnState.idle));

  /// 冷启动：载入档案；没有则尝试从旧的"单服务器"键迁移。
  ///
  /// [connect] 默认 false：启动时连接交给上层统一流程（SocketService.connect），
  /// 这里只负责把激活档案镜像进 Config / Storage，不抢着连。
  Future<void> load({bool connect = false}) async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_kProfiles);
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        final list = decoded is List ? decoded : <dynamic>[];
        profiles = list
            .whereType<Map>()
            .map((e) => ServerProfile.fromJson(Map<String, dynamic>.from(e)))
            .toList();
      } catch (_) {
        profiles = [];
      }
    }
    if (profiles.isEmpty) {
      profiles = _migrateFromLegacy(p);
    }
    // 全新安装（一个档案都没有）：扫一次局域网，扫到就落成默认档案，
    // 不让用户一上来就对着"连不上"的登录页。扫不到不写盘，留给上层引导手填。
    if (profiles.isEmpty) {
      try {
        final found = await LanDiscover.scan();
        if (found.isNotEmpty) {
          final s = found.first;
          profiles = [
            ServerProfile(
              id: ServerProfile.newId(),
              name: '小智',
              lan: s.url,
              wan: '',
              mode: Config.modeAuto,
            )
          ];
        }
      } catch (_) {
        // 发现失败不是错误：没有 UDP 栈 / 不在同一网段都会走到这
      }
    }
    final savedActive = p.getString(_kActive);
    if (savedActive != null && profiles.any((x) => x.id == savedActive)) {
      activeId = savedActive;
    } else if (profiles.isNotEmpty) {
      activeId = profiles.first.id;
    }
    for (final pr in profiles) {
      pr.active = pr.id == activeId;
    }
    // 出口归一化：不管上面哪条分支（JSON 解码 / 旧键迁移 / 局域网发现）给的，
    // 出去时必须是一份**可写**列表。不可变列表会让后续 addProfile/removeProfile
    // 抛 UnsupportedError，且保存链上没人接 —— "点保存没反应"就是这么来的。
    profiles = List<ServerProfile>.of(profiles);
    await _applyActive(connect: connect, emitDomain: false);
    profilesVersion.value++;
  }

  /// 从旧版本的单服务器键构造一个默认档案（升级过渡）。
  List<ServerProfile> _migrateFromLegacy(SharedPreferences p) {
    final lan =
        p.getString('xz_lan_url') ?? p.getString('xz_server_url') ?? '';
    final wan = p.getString('xz_wan_url') ?? '';
    final mode = p.getString('xz_net_mode') ?? Config.modeAuto;
    final token = p.getString('xz_token');
    if (lan.isEmpty && wan.isEmpty) return []; // 🔴 不能返回 const []：见 profiles 字段注释
    return [
      ServerProfile(
        id: ServerProfile.newId(),
        name: '小智',
        lan: Config.normalize(lan),
        wan: Config.normalize(wan),
        mode: mode,
        token: token,
      )
    ];
  }

  Future<void> persist() async {
    final p = await SharedPreferences.getInstance();
    await p.setString(
        _kProfiles, jsonEncode(profiles.map((e) => e.toJson()).toList()));
    if (activeId != null) await p.setString(_kActive, activeId!);
  }

  /// 把激活档案镜像进全局单例（Config / Storage / ImApi token），并在需要时重连。
  Future<void> _applyActive(
      {bool connect = false, bool emitDomain = true}) async {
    final a = active;
    if (a != null) {
      a.normalizeAddresses();
      Config.lanUrl = a.lan;
      Config.wanUrl = a.wan;
      Config.mode = a.mode;
      final url = await Config.resolveNow();
      a.currentUrl = url;
      // token：写进 Storage（旧读取方）；ImApi 会直接读激活档案 token
      if (a.token != null) await Storage.saveToken(a.token!);
      // 激活档案的连接状态跟随 SocketService
      _bindActiveLinkState();
      // 激活角标 ↔ 全局角标双向同步
      _bindActiveBadges();
    }
    if (connect) {
      await SocketService().reconnect();
    }
    if (emitDomain) domainVersion.value++;
    await persist();
  }

  /// 切换激活企业。
  ///
  /// [connect] 默认 true：用户手动切换时立即重连 WS；冷启动走 load() 不连。
  Future<void> setActive(String id, {bool connect = true}) async {
    if (!profiles.any((x) => x.id == id)) return;
    for (final pr in profiles) pr.active = pr.id == id;
    activeId = id;
    await _applyActive(connect: connect);
    // 切到新服务器，重新拉它的公司名 / 好友模式（导航形态可能变）
    Workspace.refresh();
    notifyBackgroundChange(); // 后台企业集合变了，提醒条要重算
  }

  /// 新增一个企业档案（登录成功后调用）。[makeActive] 决定是否立即切过去。
  Future<ServerProfile> addProfile(ServerProfile profile,
      {bool makeActive = false}) async {
    profile.normalizeAddresses();
    // 🔴 总闸：profiles 可能还是某条路径留下的不可变列表（const []）。
    //    对它 add/remove 会抛 UnsupportedError，且保存链上没人接异常，
    //    用户看到的就是"点保存没反应"。这里统一换成可写列表再写。
    profiles = List<ServerProfile>.of(profiles);
    profiles.add(profile);
    if (makeActive || activeId == null) {
      await setActive(profile.id, connect: true);
    } else {
      await persist();
      profilesVersion.value++;
    }
    return profile;
  }

  /// 删除企业档案。若删的是激活项，自动切到剩下的第一个。
  Future<void> removeProfile(String id) async {
    profiles = List<ServerProfile>.of(profiles); // 同 addProfile：保证可写
    profiles.removeWhere((x) => x.id == id);
    _badges.remove(id);
    _linkStates.remove(id);
    if (activeId == id) {
      activeId = profiles.isNotEmpty ? profiles.first.id : null;
      for (final pr in profiles) pr.active = pr.id == activeId;
      if (activeId != null) await _applyActive(connect: true);
    }
    await persist();
    profilesVersion.value++;
    notifyBackgroundChange(); // 删档案后，提醒条要重算
  }

  /// 改企业名（切换器里重命名）。
  Future<void> renameProfile(String id, String name) async {
    final pr = _find(id);
    if (pr == null) return;
    final n = name.trim();
    if (n.isNotEmpty) pr.name = n;
    await persist();
    profilesVersion.value++;
  }

  /// 更新某档案的登录 token（登录成功后）。
  Future<void> updateToken(String id, String token) async {
    final pr = _find(id);
    if (pr == null) return;
    pr.token = token;
    if (pr.id == activeId) await Storage.saveToken(token);
    await persist();
  }

  /// 更新某档案的地址（服务器设置保存后）。
  Future<void> updateAddresses(
      String id, String lan, String wan, String mode) async {
    final pr = _find(id);
    if (pr == null) return;
    pr.lan = Config.normalize(lan);
    pr.wan = Config.normalize(wan);
    pr.mode = mode;
    if (pr.id == activeId) {
      Config.lanUrl = pr.lan;
      Config.wanUrl = pr.wan;
      Config.mode = pr.mode;
      await Config.resolveNow();
      await persist();
      domainVersion.value++;
      await SocketService().reconnect();
    } else {
      await persist();
    }
  }

  ServerProfile? _find(String id) {
    for (final x in profiles) {
      if (x.id == id) return x;
    }
    return null;
  }

  // ---- 激活连接状态 / 角标同步 ----

  void _bindActiveLinkState() {
    _activeLinkUnsub?.call();
    _activeLinkUnsub = null;
    final a = active;
    if (a == null) return;
    final target = linkStateOf(a.id);
    target.value = SocketService().state.value;
    void onState() => target.value = SocketService().state.value;
    SocketService().state.addListener(onState);
    _activeLinkUnsub = () => SocketService().state.removeListener(onState);
  }

  void _bindActiveBadges() {
    for (final off in _activeBadgeSync) off();
    _activeBadgeSync.clear();
    final a = active;
    if (a == null) return;
    final pb = badgesOf(a.id);
    // 1) 切过来时，把本档案已存的角标值拷进全局（导航栏立刻显示对的未读数）
    Badges.instance.setUnread(pb.unread.value, hasMention: pb.mention.value);
    Badges.instance.setPendingFriends(pb.pending.value);
    // 2) 激活期间，全局角标任何变化都实时写回本档案（切走再切回不丢）
    void syncUnread() => pb.unread.value = Badges.instance.unread.value;
    void syncMention() => pb.mention.value = Badges.instance.mention.value;
    void syncPending() =>
        pb.pending.value = Badges.instance.pendingFriends.value;
    Badges.instance.unread.addListener(syncUnread);
    Badges.instance.mention.addListener(syncMention);
    Badges.instance.pendingFriends.addListener(syncPending);
    _activeBadgeSync.addAll([
      () => Badges.instance.unread.removeListener(syncUnread),
      () => Badges.instance.mention.removeListener(syncMention),
      () => Badges.instance.pendingFriends.removeListener(syncPending),
    ]);
  }
}
