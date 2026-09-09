# 小智 IM 客户端（Flutter）

一套 Dart 代码同时构建 **Windows 桌面** 与 **Android** 安装包，界面仿 Tailchat（宽屏双栏 / 窄屏跳转）。

## 功能（MVP）
- 注册 / 登录（JWT）
- 好友：搜索、发起请求、接受、发起单聊
- 群聊：建群、拉人、群消息
- 消息：文字、图片、文件；WebSocket 实时接收
- 服务端地址可编译期注入（`--dart-define=BASE_URL=...`）

## 环境准备（在有 Flutter SDK 的机器上）
```bash
# 1. 安装依赖（首次需联网）
flutter pub get

# 2. 生成各平台工程目录（只需一次）
flutter create .

# 3. 允许 Android 明文 HTTP（开发/内网用）
#    编辑 android/app/src/main/AndroidManifest.xml 的 <application> 加：
#    android:usesCleartextTraffic="true"
#    并在 <manifest> 下加：<uses-permission android:name="android.permission.INTERNET"/>
```

## 运行 / 打包
```bash
# 开发运行（桌面需先开启：flutter config --enable-windows-desktop）
flutter run --dart-define=BASE_URL=http://你的飞牛IP:3602

# 打包 Android
flutter build apk --dart-define=BASE_URL=http://你的飞牛IP:3602
# 产物：build/app/outputs/flutter-apk/app-release.apk

# 打包 Windows
flutter config --enable-windows-desktop
flutter build windows --dart-define=BASE_URL=http://你的飞牛IP:3602
# 产物：build/windows/x64/runner/Release/
```

> 生产环境建议把服务端换成 HTTPS/WSS，并把 `BASE_URL` 指向 `https://域名`，
> Android 端即可去掉 `usesCleartextTraffic`。
