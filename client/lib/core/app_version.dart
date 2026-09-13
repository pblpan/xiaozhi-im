/// 应用版本号 —— 单独成文件，避免 api.dart 与 remote_config.dart 互相 import。
///
/// 发版时必须四处一起改：
///   ① pubspec.yaml（version: X.Y.Z+N）
///   ② android/local.properties（flutter.versionName / versionCode）
///   ③ pack_win.py 里的产物名
///   ④ 这里
const String kAppVersion = '0.9.2';
