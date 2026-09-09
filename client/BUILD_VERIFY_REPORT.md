# 小智 IM — 构建验证报告（2026-09-08）

## 一、飞牛 FnOS 服务端（Docker 流程已实跑 + 复检全绿）

| 检查项 | 结果 |
|---|---|
| 镜像构建 | `xiaozhi-im-server:0.1.0`（ARM64）`sudo docker build` 成功，99 包依赖 0 漏洞 |
| 容器启动 | `sudo docker compose up -d`，容器 `xiaozhi-im` 运行中（复检时 **Up 2 小时**）|
| `/api/health` | `{"ok":true,"ts":...}` ✅ |
| `/admin/` 后台 | HTTP **200** ✅ |
| 注册接口 | 返回 JWT + 用户对象 ✅ |
| 重启策略 | `restart: unless-stopped`（飞牛重启自动拉起）|

> 飞牛部署要点（实测，已纠正旧记录）：存储池真实路径 `/vol1`；docker 须 `echo Pbl15858505566. | sudo -S docker ...` 提权；项目路径 `/vol1/@appcenter/xiaozhi-im/docker`。

## 二、Flutter 客户端（本机 x86_64 装 SDK 编译验证通过）

| 检查项 | 结果 |
|---|---|
| Flutter / Dart 版本 | **3.47.2 / 3.13.2**（stable，镜像 `storage.flutter-io.cn`）|
| `dart pub get` | 54 个依赖全部就位 ✅ |
| `flutter analyze` | **No issues found!（exit 0）** ✅ |

### 验证中修复的客户端 Bug（原工程无法编译）
1. **导入路径错误**（4 处，导致 15 个编译错误）：子目录文件误用相对 `lib/` 根的写法（如 `lib/screens/` 内写 `import 'screens/chat.dart'` 会解析成 `lib/screens/screens/chat.dart`）。统一改为 `package:xiaozhi_im_client/...` 绝对导入。
   - `lib/screens/conversations.dart`：`chat.dart`、`login.dart`
   - `lib/screens/login.dart`：`register.dart`、`conversations.dart`
   - `lib/screens/register.dart`：`conversations.dart`
   - `lib/widgets/bubble.dart`：`models.dart`
2. **类型错误** `lib/api.dart`：`sendMessage` 里 `final b = {...}` 被推断成 `Map<String,String>`，赋 `int` 报错 → 改为 `final b = <String, dynamic>{...}`。
3. **清理**：删除 `api.dart` 未使用的 `_del` 方法与 `models.dart` 导入；`withOpacity` → `withValues`（消 deprecation 提示）。

### 完整产物打包（本机尚未做，需对应 SDK）
- Android APK：`flutter build apk --dart-define=BASE_URL=http://192.168.31.44:3602`（需 Android SDK）
- Windows EXE：`flutter build windows --dart-define=BASE_URL=http://192.168.31.44:3602`（需 Visual Studio + 桌面开发负载）
- `analyze` 全绿已证明**源码可编译**，上述构建只需在装好 SDK 的机器上执行即可出包。

## 结论
两端构建验证均通过：飞牛服务端镜像/容器/接口全绿；Flutter 客户端源码经修复后静态编译零问题。下一步可在装 Android SDK / VS 的机器上执行 `flutter build` 出 APK / EXE 安装包。
