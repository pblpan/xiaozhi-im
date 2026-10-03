import 'package:shared_preferences/shared_preferences.dart';
import 'config.dart';
import 'server_profile.dart';
import 'session_manager.dart';

/// 本机偏好设置（服务器地址、网络模式等），与登录态分开存。
///
/// 多企业改造后，**单组 lan/wan/mode 的"全局真相"已经搬到 [ServerProfile]**，
/// 这里降级为"激活档案"的便捷入口：
///   · [setServers] 写的是**激活企业**的地址（首启没有档案时落成默认企业）。
///   · [hasUserServers] 表示用户至少已经配置过一家企业（管理台下发的候选不再覆盖）。
/// 旧的 `xz_lan_url` 等键仅作为"单服务器 → 多档案"的迁移来源，不再主动写入。
class Settings {
  static const _kLan = 'xz_lan_url';
  static const _kWan = 'xz_wan_url';
  static const _kMode = 'xz_net_mode';
  // 兼容老版本：旧用户只存了 _kServer 一条，迁移用
  static const _kLegacyServer = 'xz_server_url';

  /// 启动时调用：把所有用户保存的偏好载入 Config。
  ///
  /// 多企业改造后，档案的载入由 [SessionManager.load] 负责（含旧键迁移 +
  /// 首启局域网发现）。这里保留为兼容入口，直接转发即可。
  static Future<void> load() async {
    await SessionManager.instance.load();
  }

  static Future<String?> getLan() async =>
      (await SharedPreferences.getInstance()).getString(_kLan);

  static Future<String?> getWan() async =>
      (await SharedPreferences.getInstance()).getString(_kWan);

  static Future<String?> getMode() async =>
      (await SharedPreferences.getInstance()).getString(_kMode);

  /// 保存服务器三件套（lan/wan/mode）—— 写入**激活企业**档案。
  /// 首启（还没有任何档案）时，落成一条默认企业并激活。
  static Future<void> setServers({
    required String lan,
    required String wan,
    required String mode,
  }) async {
    final sm = SessionManager.instance;
    final id = sm.activeId;
    if (id != null) {
      await sm.updateAddresses(id, lan, wan, mode);
    } else {
      final p = ServerProfile(
        id: ServerProfile.newId(),
        name: '小智',
        lan: Config.normalize(lan),
        wan: Config.normalize(wan),
        mode: mode,
      );
      await sm.addProfile(p, makeActive: true);
    }
  }

  /// 用户是否自己配置过服务器（管理台候选地址要不要跟随下发的判据）。
  /// 现在 = "至少有了一家企业档案"。
  static Future<bool> hasUserServers() async =>
      SessionManager.instance.profiles.isNotEmpty;

  /// 清空所有用户设置（恢复出厂）。
  /// 多企业改造后 = 清空所有企业档案 + 旧键；下次启动重新走发现。
  static Future<void> reset() async {
    final p = await SharedPreferences.getInstance();
    await p.remove(_kLan);
    await p.remove(_kWan);
    await p.remove(_kMode);
    await p.remove(_kLegacyServer);
    final sm = SessionManager.instance;
    // 逐个删除（会处理激活项自动切换）
    for (final pr in List<ServerProfile>.from(sm.profiles)) {
      await sm.removeProfile(pr.id);
    }
    Config.lanUrl = Config.builtInBaseUrl;
    Config.wanUrl = Config.builtInWanUrl;
    Config.mode = Config.modeAuto;
    Config.invalidateProbeCache();
    await Config.pickUrl(force: true);
  }

  const Settings._();
}
