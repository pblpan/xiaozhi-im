/// 服务端地址配置。
///
/// 优先级：用户在本机设置的地址 > 打包时 --dart-define=BASE_URL=... > 默认 localhost。
/// 打包时仍可用：
///   flutter build apk --dart-define=BASE_URL=http://192.168.31.44:3602
/// 但用户在 App 内「服务器设置」改过之后，以用户设置为准（存本地，升级不丢）。
class Config {
  /// 打包内置地址（不可变，用于判断是否被用户覆盖 / 恢复默认）
  static const String builtInBaseUrl = String.fromEnvironment(
    'BASE_URL',
    defaultValue: 'http://localhost:3602',
  );

  /// 运行时实际使用的地址，启动时由 Settings 载入
  static String baseUrl = builtInBaseUrl;

  static String get wsUrl => baseUrl.replaceFirst(RegExp(r'^http'), 'ws');

  /// 用户是否改过（改过则界面上提示"自定义"）
  static bool get isCustom => baseUrl != builtInBaseUrl;

  /// 规范化用户输入的地址：
  /// 192.168.1.9:3602 -> http://192.168.1.9:3602
  static String normalize(String input) {
    var s = input.trim();
    if (s.isEmpty) return s;
    s = s.replaceAll(RegExp(r'/+$'), ''); // 去掉结尾斜杠
    if (!s.startsWith(RegExp(r'https?://', caseSensitive: false))) {
      s = 'http://$s';
    }
    return s;
  }
}
