import 'package:shared_preferences/shared_preferences.dart';

class Storage {
  static const _k = 'xz_token';

  static Future<void> saveToken(String t) async =>
      (await SharedPreferences.getInstance()).setString(_k, t);

  static Future<String?> getToken() async =>
      (await SharedPreferences.getInstance()).getString(_k);

  static Future<void> clear() async =>
      (await SharedPreferences.getInstance()).remove(_k);
}
