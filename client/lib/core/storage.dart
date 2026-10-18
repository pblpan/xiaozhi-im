import 'package:shared_preferences/shared_preferences.dart';

class Storage {
  static const _k = 'xz_token';
  static const _kRecentEmoji = 'xz_recent_emoji';
  /// 上次登录的账号。改服务器地址会清 token，但不清这个 —— 回到登录页时
  /// 账号自动回显，换账号手动改输入框即可（龙哥 2026-10-18 要求）。
  static const _kLastAccount = 'xz_last_account';

  static Future<void> saveToken(String t) async =>
      (await SharedPreferences.getInstance()).setString(_k, t);

  static Future<String?> getToken() async =>
      (await SharedPreferences.getInstance()).getString(_k);

  static Future<void> clear() async =>
      (await SharedPreferences.getInstance()).remove(_k);

  static Future<void> saveLastAccount(String u) async =>
      (await SharedPreferences.getInstance()).setString(_kLastAccount, u);

  static Future<String?> getLastAccount() async =>
      (await SharedPreferences.getInstance()).getString(_kLastAccount);

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
