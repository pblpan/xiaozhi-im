import 'package:shared_preferences/shared_preferences.dart';
import 'config.dart';
import 'discover.dart';

/// 本机偏好设置（服务器地址、网络模式等），与登录态分开存。
class Settings {
  static const _kLan = 'xz_lan_url';
  static const _kWan = 'xz_wan_url';
  static const _kMode = 'xz_net_mode';
  // 兼容老版本：旧用户只存了 _kServer 一条，这里保留以便升级过渡
  static const _kLegacyServer = 'xz_server_url';

  /// 启动时调用：把所有用户保存的偏好载入 Config
  static Future<void> load() async {
    final p = await SharedPreferences.getInstance();

    final lan = p.getString(_kLan);
    final wan = p.getString(_kWan);
    final mode = p.getString(_kMode);
    final legacy = p.getString(_kLegacyServer);

    // 优先级：新格式 lan/wan > 旧格式 _kServer（填到 lan） > 打包内置（加固后是空串）
    if (lan != null && lan.isNotEmpty) {
      Config.lanUrl = lan;
    } else if (legacy != null && legacy.isNotEmpty) {
      // 旧版本只有一个地址：放到 lan，让用户后续补 wan
      Config.lanUrl = legacy;
      await p.setString(_kLan, legacy);
    } else {
      Config.lanUrl = Config.builtInBaseUrl; // 加固后是 ''，即"还不知道服务器在哪"
    }

    // ⚠️ 不再 fallback 到内置外网域名（加固前这里是 builtInWanUrl）。
    //    没配就是没配，宁可走下一段的局域网发现，也不要连写死的地址。
    Config.wanUrl = wan ?? '';
    Config.mode = mode ?? Config.modeAuto;

    // 首次启动（一个地址都没有）：**别把用户直接丢在"连不上"的登录页上**。
    // 先扫一次局域网 —— 服务器（飞牛）在同一个网段时会应答，扫到就直接能用。
    // 扫不到不写盘、不报错：留给上层引导手填（见 screens/setup_server.dart）。
    // 刻意**不持久化**扫描结果：一旦写进 _kLan，就等于"用户配过地址"，
    // Settings.hasUserServers() 会变 true，管理台下发的候选地址就再也进不来了。
    if (Config.lanUrl.isEmpty && Config.wanUrl.isEmpty) {
      try {
        final found = await LanDiscover.scan();
        if (found.isNotEmpty) Config.lanUrl = found.first.url;
      } catch (_) {
        // 发现失败不是错误：本机没有 UDP 栈 / 不在同一网段都会走到这
      }
    }

    // 启动探测：决定 currentUrl
    await Config.pickUrl(force: true);
  }

  static Future<String?> getLan() async =>
      (await SharedPreferences.getInstance()).getString(_kLan);

  static Future<String?> getWan() async =>
      (await SharedPreferences.getInstance()).getString(_kWan);

  static Future<String?> getMode() async =>
      (await SharedPreferences.getInstance()).getString(_kMode);

  /// 保存服务器三件套（lan/wan/mode）
  static Future<void> setServers({
    required String lan,
    required String wan,
    required String mode,
  }) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kLan, Config.normalize(lan));
    if (wan.isEmpty) {
      await p.remove(_kWan);
    } else {
      await p.setString(_kWan, Config.normalize(wan));
    }
    await p.setString(_kMode, mode);

    Config.lanUrl = Config.normalize(lan);
    // 外网地址留空就是留空 —— 不再回填内置域名（加固后本来也没有内置值）
    Config.wanUrl = wan.isEmpty ? '' : Config.normalize(wan);
    Config.mode = mode;
  }

  /// 用户是否自己保存过服务器地址（RemoteConfig 判断"地址候选要不要跟随下发"用：
  /// 用户手动配过的优先，绝不被下发的候选覆盖）
  static Future<bool> hasUserServers() async {
    final p = await SharedPreferences.getInstance();
    return p.containsKey(_kLan) || p.containsKey(_kWan) || p.containsKey(_kMode);
  }

  /// 清空所有用户设置（恢复出厂）。
  /// 加固后"恢复默认"= **没有任何地址**（内置值已是空串），下次启动重新走局域网发现。
  static Future<void> reset() async {
    final p = await SharedPreferences.getInstance();
    await p.remove(_kLan);
    await p.remove(_kWan);
    await p.remove(_kMode);
    await p.remove(_kLegacyServer);
    Config.lanUrl = Config.builtInBaseUrl;
    Config.wanUrl = Config.builtInWanUrl;
    Config.mode = Config.modeAuto;
    // 内存里的探测结果也要作废，否则 currentUrl 还指着旧服务器
    Config.invalidateProbeCache();
    await Config.pickUrl(force: true);
  }

  const Settings._();
}