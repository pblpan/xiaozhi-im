# iOS 版开工前置报告（小智 IM 客户端）

> 结论先说：**代码不需要重写** —— 平台专有代码（win32 / ffi / tray / 文件打开）都已按平台分派，
> iOS 侧是"补平台目录 + 补权限声明 + 补推送/音频会话"这三类事情。
> **真正的门槛不在代码，在两件不可绕过的事**：必须有一台 Mac 出包，以及 iOS 上
> "App 退到后台就收不到消息"，需要一套推送体系才能达到和 Android 一致的体验。
> 以下按"能不能落地"分档，把边界摆清楚。

---

## 〇、最终确定的推进顺序（2026-09-13 定）

龙哥明确：**「iOS 先做，再做 Mac，我手里没有 Mac 设备」**。

据此把工作拆成两类：

| 阶段 | 内容 | 现在能不能做 | 前置 |
|---|---|---|---|
| **A. iOS 代码侧准备（无 Mac）** | 平台分支体检 / 依赖体检 / 权限清单 / `ios/` 目录手工补齐 / iOS 校验脚本 | ✅ **现在就能做完** | 无 |
| **B. Mac 环境** | 一台 Mac + Xcode + CocoaPods，`flutter doctor` iOS 段全绿 | ❌ 等 Mac | 硬件 |
| C. 构建与真机验证 | `flutter build ios` + 真机跑通 | ❌ 等 B | A + B |
| D. APNs 推送 / CallKit | 见第四节 | ❌ 等 C（服务端部分可先设计） | C |

> ⚠️ **先说清一件事，免得白做工**：A 阶段**做不出能运行的 iOS 应用**。
> 没有 Mac 就没有 Xcode，就没有编译器、没有签名、没有 ipa。
> A 阶段交付的是「**一套质量极高的起跑线**」—— 代码保证在 iOS 上编得过、
> 依赖不拖后腿、权限一项不漏、验证脚本提前就位。
> **真正"能装到 iPhone 上用"的那一步，只在 Mac 上发生。**

### 为什么不"先在 Windows 上试试编译 iOS"
Flutter 支持非 macOS 主机做 **Android / Windows / Web** 目标，但 **iOS 目标只支持 macOS 主机** ——
`flutter build ios` 在 Windows 上会直接拒绝执行。所以"先做 iOS"= 先把**代码与配置**做到位，
而不是把编译提前。

---

## 二、环境基线（已查证，写下来免得每次重问）

| 项 | 值 |
|---|---|
| Flutter SDK | **3.47.2 stable**（revision `d3b14c8769`，2026-08-26） |
| Dart | **3.13.2** |
| 客户端版本 | 0.9.3+28 |
| SDK 约束 | `>=3.3.0 <4.0.0` |
| 现有平台目录 | `android/`、`windows/` |
| Flutter SDK 自带 iOS 模板 | ✅ 有，`tools/flutter/packages/flutter_tools/templates/app/ios.tmpl/`（40 个文件）→ **Windows 上可手工补齐项目** |
| **Xcode 版本要求** | **待定 —— 取决于 Flutter 3.47.2 的官方要求，必须查文档，别猜** |

### 2.1 ⚠️ Xcode 版本不能猜
Flutter 每个大版本都会抬高 Xcode / iOS 的最低要求，装"最新的 Xcode"或"手边有的旧 Xcode"
都可能直接构建失败。拿到 Mac 后第一件事：查 Flutter 3.47.2 官方文档里
*Supported deployment platforms* 那张表（iOS 最低版本 + 推荐 Xcode），再决定装哪个。
命令侧对应 `flutter doctor -v` 的 iOS 段。

---

## 三、代码侧要动的地方（已逐个查证，不是猜测）

### 3.1 已经做好的（不用改）
这些都已按平台分派，iOS 进来是"不匹配就走 else 分支"，不会崩：

| 文件 | 现有处理 |
|---|---|
| `lib/core/input_inject.dart` | `if (Platform.isWindows) ... if (Platform.isAndroid) ...` → iOS 落到"不支持"分支（远程协助被控侧 iOS 做不了，**合规上也不允许**：App Store 禁第三方 App 控制系统全局输入） |
| `lib/core/file_io.dart` | 仅 Windows 走 `WinShell`（原生 ShellExecuteW），其余走 `open_filex` → iOS 直接用后者 |
| `lib/core/tray_service.dart` | `supported => Platform.isWindows \|\| Platform.isLinux` → iOS 恒 false，托盘整套逻辑不进包（不会编译报错） |
| `lib/core/call_service.dart` | `toggleSpeaker()` 已写了 `isAndroid \|\| isIOS`；震动 `if (!Platform.isAndroid) return`，iOS 静默跳过 |
| `lib/screens/call.dart` | 已有 `Platform.isAndroid \|\| Platform.isIOS` 的"移动端"判断 |

### 3.2 依赖侧：**8 个依赖全部有 iOS 原生实现**（好消息）

`.flutter-plugins-dependencies` 里 **iOS 段已经存在**（这份文件是 Flutter 按所有平台
生成的，不需要 Mac 也能看到）：

| 依赖 | iOS 侧实现 | 用在哪 |
|---|---|---|
| `audioplayers` | `audioplayers_darwin` | 提示音 / 铃声 |
| `file_picker` | `file_picker_darwin` | 选文件 |
| `flutter_webrtc` | `flutter_webrtc` | 音视频通话 |
| `open_filex` | `open_filex` | 打开收到的文件 |
| `path_provider` | `path_provider_foundation` | 本地目录 |
| `record` | `record_ios` | 语音消息录制 |
| `shared_preferences` | `shared_preferences_foundation` | 记住设置/选择 |
| `url_launcher` | `url_launcher_ios` | 外链 |

**结论：没有任何依赖在 iOS 上缺实现** —— 不需要换库，这是最好的开局。

而 `tray_manager` / `window_manager` / `win32` **没有**出现在 iOS 段里 ——
说明 Flutter 工具链自己就把它们认作"仅桌面平台"，iOS 构建时不会塞进去，
这与 3.1 里 `tray_service.dart` 的 `supported` 判断吻合。

### 3.3 需要新增/补的

| 项 | 说明 | 复杂度 |
|---|---|---|
| `ios/` 平台目录 | **Windows 上手工补齐**（从 SDK 自带模板生成，见第〇节 A2），不必等 Mac | 中 |
| `ios/Runner/Info.plist` 权限声明 | 摄像头 / 麦克风 / 相册读写 / **本地网络**（iOS 14+ 连局域网必须声明 `NSLocalNetworkUsageDescription` + `NSBonjourServices`，否则连不上飞牛内网那个 `192.168.31.44:3602`） | 低但**极易漏**，漏了现象是"Android 好好的，iOS 连不上" |
| 明文 HTTP（ATS） | 内网地址是 `http://`，iOS 默认**禁止**明文 HTTP。需要在 `Info.plist` 加 `NSAppTransportSecurity` 例外（或只对该域名开 `NSAllowsArbitraryLoadsInWebContent`/指定域例外）。上架审核时"任意明文"会被问，**建议只给内网 IP 段和自有域名开例外** | 低 |
| 音频会话 | iOS 通话要显式管理 `AVAudioSession`（通话时切 `playAndRecord`+`voiceChat`，结束后还原；否则可能"能听见对方、对方听不见你"，或扬声器/听筒不对）。`flutter_webrtc` 有 `Helper.setSpeakerphoneOn`，但**音频会话分类需要补一层平台配置** | 中，**是 iOS 通话最常见的坑** |
| 录音格式 | 语音消息现在用 `AudioEncoder.aacLc` / 32kbps（`voice.dart`），iOS 原生支持 AAC-LC，**基本不用改**；需实测采样率与时长边界 | 低 |
| 推送（见第四节） | 体验一致性的关键 | 高 |

---

## 四、推送：必须专门做一期，否则 iOS 版是"半残"

这是我要**重点提醒**的一条，因为它决定 iOS 版到底能不能用。

- **Android 现在的体验**：App 缩到后台/托盘，靠常连 WS 继续收消息（所以我们才做了"关闭窗口缩到托盘"）。
- **iOS 的现实**：切到后台后进程会被挂起，socket 断掉。别人的 iPhone 上，你不打开 App 就**收不到任何消息**，也没有来电铃声 —— 而"能随时收到消息"恰恰是这个 IM 存在的理由。
- **要补的东西**：`APNs`（苹果推送服务）接入 —— 服务端持 Apple 密钥 → 有新消息/来电时推一条通知 → 用户点通知拉起 App 再连 WS 拉取。
- **来电还要更强的一层**：普通通知在锁屏上响铃不够（要解锁、要手动打开 App），要真做到"像电话一样响"，得用 **VoIP Push + CallKit**（需要额外的 PushKit 证书与系统权限）。这一层可以放到第二期。
- **Apple 开发者账号**：¥688/年，**推送、真机长期调试、上架都必须有**。

> ⚠️ 结论：**没有推送的 iOS 版只能"打开 App 时能聊天"，不能算能用。**
> 所以正确的排期是「iOS 基础版（能登录/聊天/通话）」和「APNs 推送」分两期，但**第二期不能省**。

---

## 五、还有两个绕不开的现实问题

1. **证书 / 签名 / 上架**
   - 仅自己内测：Apple 开发者账号 + 测试设备 UDID 加进描述文件（Ad Hoc），或走 TestFlight（需审核，但比上架快）。
   - 想给别人随便装：**没有 Android 那种"发个 ipa 就能装"的路**。个人证书 7 天过期、企业证书贵且滥用会被吊销 —— 这点要有预期。
   - 上架 App Store 还需要审核：IM 类应用要提供隐私政策、举报机制、账号注销入口（我们目前**没有账号注销功能**，这是审核会被卡的项）。

2. **包名 / 用户数据**
   - Android 包名与 iOS Bundle ID 是两套，iOS 侧会新起一个 Bundle ID（如 `com.pblpa.xiaozhi-im`）。
   - **机会点**：我们早就发现包名还是 Flutter 默认的 `com.example`（用户数据在 `%APPDATA%\com.example\xiaozhi_im_client`），一直没改，就因为**改包名会搬掉用户数据目录**。**iOS 是全新平台，天然该用正式包名** —— 顺便把"新平台用正式 ID、老平台维持现状等一次专门迁移"这件事定下来。

---

## 六、质量保障（这次想提前避免重演）

Windows 那边我们吃过"静态校验全绿、真机一装才发现问题"的亏（托盘图标 Debug 有 Release 空、taskkill 假承诺）。
iOS 侧要**提前立规矩**，别等出了包才想验证：

1. **判据必须两端实测**：Windows 那套 `verify_release.py` 的教训已经吃过三次。
   iOS 的 ipa 是 zip，可以解包扫字符串 —— 但要先确认哪些串在 iOS 产物里真的留下来了
   （`Platform.isIOS` 分支可能被 AOT 内联或剔除，**跟 Android 一样会出现"某条判据在 iOS 里搜不到"**），
   **不能照抄 Android 的判据清单**。
2. **权限声明要能自动验**：`Info.plist` 里的 `NSLocalNetworkUsageDescription`、`NSCameraUsageDescription`、
   `NSMicrophoneUsageDescription`、ATS 例外，**解包 ipa 直接读 plist 断言**，不靠人眼。
3. **音频会话要有可观测信号**：iOS 通话最容易出"单向没声音"，要能打出当前音频分类/路由（参考 Android 那次
   的教训：**关键状态必须是会失败的断言，不能只是打印一行警告**）。
4. **推送要有服务端侧的可观测性**：APNs 发送结果（成功/失败/令牌失效）必须落库可查，
   否则"用户说收不到通知"时无从下手。
5. **真机验证不可替代**：模拟器测不了麦克风/摄像头/推送/后台挂起。至少一台真 iPhone。

---

## 七、完整落地顺序（每阶段都能验证）

| 阶段 | 内容 | 交付/验证 | 前置 |
|---|---|---|---|
| **A1 体检** | 平台分支体检：`flutter analyze` + `flutter test` + `flutter build apk` / `build windows`，证明现有平台没被 iOS 准备动作弄坏 | 构建 + 测试全绿 | 无 |
| **A2 平台骨架** | Windows 上**手工补齐 `ios/`**（从 SDK 模板生成 + 项目名/Bundle ID/图标/启动图 + 修正 Podfile 平台版本） | 目录结构完整、与插件 podhelper 一致 | A1 |
| **A3 权限与网络** | `Info.plist`：摄像头/麦克风/相册/**本地网络** + ATS 例外；`Podfile` 平台版本 | `verify_ios.py` 自动断言全绿 | A2 |
| **A4 校验脚本** | `client/verify_ios.py`：解 ipa 断言结构 + 权限 + 判据（**判据占位，等 Mac 上实测再填**） | 脚本就位并自测 | A3 |
| **A5 通话设计** | 音频会话 / 通话在 iOS 上的实现方案落成文档 | 设计稿 | A2 |
| **B Mac 环境** | 装 Xcode（**版本按 Flutter 3.47.2 要求，别装错**）+ CocoaPods，`flutter doctor` iOS 段全绿 | 环境就绪 | 硬件 |
| **C1 首次编译** | Mac 上 `flutter build ios --debug`，逐条修编译错误（预计出在 `flutter_webrtc`/`record` 的 Podfile 平台版本、Swift 版本） | 编译通过 | B |
| **C2 判据实测** | **实测哪些串在 iOS 产物里真留下来了**再填进 `verify_ios.py`（`WIN_MARKS` 的教训） | 判据两端命中 | C1 |
| **C3 真机核心** | 模拟器 → 真机：登录/会话/聊天/图片文件/语音消息 | 真机与 Android/Windows 互通 | C2 |
| **C4 真机通话** | 音频会话分类 + WebRTC 权限与路由；先语音后视频 | iOS ↔ Android **双向都有声** | C3 |
| **D1 APNs** | 服务端持 Apple 密钥 + 客户端注册 token + 通知点击拉起 | App 退后台仍能收到消息 | C4 |
| **D2 来电** | VoIP Push + CallKit | 锁屏可接来电 | D1 |
| **D3 分发** | TestFlight 内测 → 补齐审核要件（隐私政策、举报、**账号注销**）→ 上架（可选） | TestFlight 可装 | D2 |

---

## 八、需要龙哥决策 / 提供的事

1. **Mac 怎么来**（A 阶段完成后就要用）：借一台 / 云 Mac 按小时租 / 买台 Mac mini。
   **没有 Mac，B 阶段之后的任何一步都无法推进**，这是硬前置。
2. **Apple 开发者账号**（¥688/年）—— 只做真机内测也必须有；不买只能停在"模拟器里能跑"。
3. **iOS 版的目标**：自己/少数人内测（TestFlight 或 Ad Hoc），还是要上架 App Store？
   上架要多做「隐私政策 + 举报机制 + 账号注销」，需要单独排期。
4. **iOS Bundle ID 用哪个**（建议 `com.pblpa.xiaozhi-im`；老平台维持 `com.example` 不动，
   等日后专门做一次数据迁移）。
5. **iOS 最低支持版本**：建议定 **iOS 15.0**（覆盖面与 API 的平衡点），
   最终下限以 Flutter 3.47.2 官方要求为准。
