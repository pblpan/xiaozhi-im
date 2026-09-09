/// 服务端地址配置。
/// 部署时把 BASE_URL 指向你的飞牛服务端，例如：
///   flutter run --dart-define=BASE_URL=http://192.168.31.44:3602
/// 打包 Android:
///   flutter build apk --dart-define=BASE_URL=http://192.168.31.44:3602
/// 打包 Windows:
///   flutter build windows --dart-define=BASE_URL=http://192.168.31.44:3602
class Config {
  static const String baseUrl = String.fromEnvironment(
    'BASE_URL',
    defaultValue: 'http://localhost:3602',
  );

  static String get wsUrl => baseUrl.replaceFirst(RegExp(r'^http'), 'ws');
}
