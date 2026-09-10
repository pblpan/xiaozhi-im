import 'package:shared_preferences/shared_preferences.dart';

class Storage {
  static const _k = 'xz_token';
  static const _kRecentEmoji = 'xz_recent_emoji';

  static Future<void> saveToken(String t) async =>
      (await SharedPreferences.getInstance()).setString(_k, t);

  static Future<String?> getToken() async =>
      (await SharedPreferences.getInstance()).getString(_k);

  static Future<void> clear() async =>
      (await SharedPreferences.getInstance()).remove(_k);

  /// 最近用过的表情（面板「常用」那一栏）。最新的排最前。
  static Future<List<String>> getRecentEmoji() async =>
      (await SharedPreferences.getInstance()).getStringList(_kRecentEmoji) ??
      const [];

  static Future<List<String>> addRecentEmoji(String e, {int max = 16}) async {
    final sp = await SharedPreferences.getInstance();
    final list = sp.getStringList(_kRecentEmoji) ?? <String>[];
    list.remove(e);
    list.insert(0, e);
    if (list.length > max) list.removeRange(max, list.length);
    await sp.setStringList(_kRecentEmoji, list);
    return list;
  }
}
