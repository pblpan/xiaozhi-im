/// 应用版本号 —— 单独成文件，避免 api.dart 与 remote_config.dart 互相 import。
///
/// 发版时必须一起改（漏一处就是"版本显示不一致"，很难发现）：
///   ① pubspec.yaml（version: X.Y.Z+N）
///   ② android/local.properties（flutter.versionName / versionCode）
///   ③ 这里
///   ④ verify_release.py 里的期望版本（发版自校验，会主动拦住漏改）
/// 产物名由 pack_win.py 从 pubspec.yaml 读，不需要手改。
const String kAppVersion = '0.13.2';
