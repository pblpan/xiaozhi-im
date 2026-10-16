/// 应用版本号 —— 单独成文件，避免 api.dart 与 remote_config.dart 互相 import。
///
/// 🔴 发版真正要改的**只有两处**（这两个才是源头）：
///   ① pubspec.yaml（`version: X.Y.Z+N`）—— APK / exe 的版本号由它来
///   ② 这里（界面显示，以及"要不要升级"的比对都读它）
///
/// 校验：`client/tools/check_version_sync.sh` 比对 ① 与 ②，
/// 从 0.18.0 起已接进 CI 的 test job（改完 pubspec 忘了改这里就会红）。
/// 本机也能跑：`bash tools/check_version_sync.sh`。
///
/// ⚠️ `android/local.properties` 里的 `flutter.versionName` / `versionCode`
///    **不是源头、是派生物**：Flutter 工具每次构建会拿 pubspec.yaml 覆写它，
///    而且这文件被 .gitignore 了、CI 根本看不到（CI 自己生成一份）。
///    改它没有任何作用 —— 老注释写的"三处同步"是把结果当成了原因。
///    （`android/app/build.gradle.kts` 里 `versionName = flutter.versionName`，
///    那个 `flutter` 对象就是工具从 pubspec 灌进去的。）
///
/// 产物名由 pack_win.py 从 pubspec.yaml 读，不需要手改。
const String kAppVersion = '0.28.5';
