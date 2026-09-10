import 'package:shared_preferences/shared_preferences.dart';
import 'config.dart';

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

    // 优先级：新格式 lan/wan > 旧格式 _kServer（填到 lan） > 打包内置
    if (lan != null && lan.isNotEmpty) {
      Config.lanUrl = lan;
    } else if (legacy != null && legacy.isNotEmpty) {
      // 旧版本只有一个地址：放到 lan，让用户后续补 wan
      Config.lanUrl = legacy;
      await p.setString(_kLan, legacy);
    } else {
      Config.lanUrl = Config.builtInBaseUrl;
    }

    Config.wanUrl = wan ?? '';
    Config.mode = mode ?? Config.modeAuto;

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
    Config.wanUrl = wan.isEmpty ? Config.builtInWanUrl : Config.normalize(wan);
    Config.mode = mode;
  }

  /// 恢复打包内置地址（清空所有用户设置）
  static Future<void> reset() async {
    final p = await SharedPreferences.getInstance();
    await p.remove(_kLan);
    await p.remove(_kWan);
    await p.remove(_kMode);
    await p.remove(_kLegacyServer);
    Config.lanUrl = Config.builtInBaseUrl;
    Config.wanUrl = Config.builtInWanUrl;
    Config.mode = Config.modeAuto;
  }

  const Settings._();
}