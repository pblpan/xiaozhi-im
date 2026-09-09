import 'package:shared_preferences/shared_preferences.dart';
import 'config.dart';

/// 本机偏好设置（服务器地址等），与登录态分开存。
class Settings {
  static const _kServer = 'xz_server_url';

  /// 启动时调用：把用户保存的服务器地址载入 Config
  static Future<void> load() async {
    final v = await getServer();
    if (v != null && v.isNotEmpty) Config.baseUrl = v;
  }

  static Future<String?> getServer() async =>
      (await SharedPreferences.getInstance()).getString(_kServer);

  static Future<void> setServer(String url) async {
    (await SharedPreferences.getInstance())
        .setString(_kServer, Config.normalize(url));
  }

  /// 恢复打包内置地址
  static Future<void> resetServer() async =>
      (await SharedPreferences.getInstance()).remove(_kServer);

  const Settings._();
}
