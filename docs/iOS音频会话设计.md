# iOS 音频会话设计与通话行为（A5）

> 面向"没有 Mac 也能先定下来"的部分：**结论、依据、要改哪个文件、怎么验证**。
> 写这份文档的原因：iOS 音频问题是本项目跨平台差异最大的一块，
> 而且**失败方式全是静默的**（没声音、免提不生效、切后台断音频），
> 到了真机上再猜会浪费大量时间。先把结论钉死。

---

## 1. 一句话结论

**必须在 `AppDelegate` 启动时把 `AVAudioSession` 分类设为 `PlayAndRecord`，
模式设为 `VoiceChat`，否则 `toggleSpeaker()` 在 iOS 上会被静默忽略。**

---

## 2. 依据：不是猜的，是插件源码里写死的分支

### 2.1 `setSpeakerphoneOn(true)` 有前置条件，不满足就**静默 return**

`flutter_webrtc-1.6.2+hotfix.1/ios/.../AudioUtils.m` 第 68 行起：

```objc
+ (void)setSpeakerphoneOn:(BOOL)enable {
  RTCAudioSession* session = [RTCAudioSession sharedInstance];
  RTCAudioSessionConfiguration* config = [RTCAudioSessionConfiguration webRTCConfiguration];

  if(enable && config.category != AVAudioSessionCategoryPlayAndRecord) {
    NSLog(@"setSpeakerphoneOn: Category option 'defaultToSpeaker' is only "
           "applicable with category 'playAndRecord', ignore.");
    return;                       // ← 什么都没做，也没有回调/异常
  }
  ...
```

**关键点**：
- 判断的是 `config.category`（`RTCAudioSessionConfiguration` 的当前值），**不是** `session.category`
- 不满足时**只打一行 NSLog 就 return**，Flutter 侧收不到任何错误

### 2.2 客户端这边不知道它没生效

`lib/core/call_service.dart` 第 468-472 行：

```dart
Future<void> toggleSpeaker() async {
  if (!Platform.isAndroid && !Platform.isIOS) return;
  speakerOn.value = !speakerOn.value;          // ← UI 先翻转了
  await Helper.setSpeakerphoneOn(speakerOn.value);   // ← 可能什么都没发生
}
```

`speakerOn` 是 `ValueNotifier`，UI 直接读它显示"免提开/关"。
所以**分类不对时的表现是**：图标显示免提已开，声音却仍从听筒出来（很小声），
用户会以为"这个按钮坏了"，我们却在日志里看到一行没人看的 NSLog。

### 2.3 `ensureAudioSessionWithRecording` 会兜底，但时机不对

同文件第 12-14 行：

```objc
// require audio session to be either PlayAndRecord or MultiRoute
if (recording && session.category != AVAudioSessionCategoryPlayAndRecord &&
    session.category != AVAudioSessionCategoryMultiRoute) {
  config.category = AVAudioSessionCategoryPlayAndRecord;
  ...
```

它确实会把分类设成 `PlayAndRecord` —— 但这个函数是在**开采集（拿音频轨）**时才调的。
于是存在一个时间窗：

1. 用户接听 → 界面先出来 → 用户马上点"免提"
2. 此时采集还没真正开始 → `config.category` 还不是 `PlayAndRecord`
3. `setSpeakerphoneOn(true)` 走了 return 分支 → 免提没开
4. 之后采集启动，分类才变成 `PlayAndRecord` —— 但那个被忽略的调用不会重放

**所以不能依赖插件的自动兜底**，必须自己在启动时设置。

---

## 3. 要落地的改动

### 3.1 `ios/Runner/AppDelegate.swift` 启动时配置会话

在 `didFinishLaunchingWithOptions` 里（`super` 之后）加上：

```swift
import AVFoundation   // 文件顶部

// 启动时把音频会话配成"可以录音 + 通话模式"
//
// ⚠️ 为什么必须在启动时就设，而不是等接通了再设：
//   1. flutter_webrtc 的 setSpeakerphoneOn(true) 要求
//      RTCAudioSessionConfiguration.category == PlayAndRecord，
//      否则**静默 return**（见 AudioUtils.m:68）。
//   2. 插件的自动兜底发生在"开采集"时，与用户点免提存在时间窗，
//      有概率永久失效（见上节）。
//   3. 设成 VoiceChat 模式能启用系统的回声消除/自动增益，
//      否则双向通话时本方扬声器的声音会被自己麦克风收回去 → 对方听到回声。
//   4. 分类不是 PlayAndRecord 时，iOS 会在**静音开关拨到静音**时
//      把通话声音一起静掉 —— 用户会觉得"电话没声音"。
do {
  let session = AVAudioSession.sharedInstance()
  try session.setCategory(
    .playAndRecord,
    mode: .voiceChat,
    options: [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker]
  )
} catch {
  NSLog("[xiaozhi] AVAudioSession 配置失败: \(error)")
}
```

**这几个选项的作用，逐个说清楚（都有具体后果）**：

| 选项 | 不写会怎样 |
|---|---|
| `.playAndRecord` | 上面说的：免提静默失效、静音开关会静掉通话、录音可能失败 |
| `.voiceChat` 模式 | 没有回声消除与自动增益，对方会听到自己的回声；声音忽大忽小 |
| `.allowBluetooth` | 蓝牙耳机（HFP）连不上，只能走手机听筒 |
| `.allowBluetoothA2DP` | 蓝牙耳机只能当麦克风用、不能放声音（音质差） |
| `.defaultToSpeaker` | 普通通话默认走听筒（小声），而不是扬声器 |

> `.defaultToSpeaker` 与我们自己的"免提开关"是**两层**：
> 它决定"分类为 PlayAndRecord 时的默认输出口"，我们的 `setSpeakerphoneOn`
> 在其之上做 `overrideOutputAudioPort`。两者不冲突，但前者必须存在，
> 后者才有意义。

### 3.2 中断与路由变化要处理（不然"来电话后就没声音了"）

iOS 上接听系统电话、插拔耳机、切换蓝牙都会改变音频路由。
**默认行为下，通话不会自动恢复。**

`flutter_webrtc` 已经在 `FlutterWebRTCPlugin.m` 里监听了
`AVAudioSessionRouteChangeNotification` 和中断通知（第 295-342 行），
会转发给 Flutter 侧。客户端要做的是**收到后重新激活会话**：

在 `call_service.dart` 里监听插件的 `onAudioRouteChanged`（或等价的
事件通道），在有活跃通话时重新 `setActive(true)`。
**这一条留到真机上调**（没有 Mac 无法验证事件是否真的到达 Flutter 侧）。

### 3.3 免提切换要"以实际结果为准"

现在 `toggleSpeaker()` 是"先翻转 UI，再发指令"。iOS 上指令可能被忽略，
于是 UI 说谎。改成**根据分类状态决定按钮是否可用**，或至少在
`setSpeakerphoneOn` 之后回读一次端口状态再刷新 UI。

> 这条属于 B 阶段（要真机验证）。A 阶段只记录问题，不盲改 ——
> 因为"回读端口"用什么 API、返回什么值，没有 Mac 时无法验证，
> 猜着写等于埋雷。

---

## 4. 后台与推送（B 阶段，先记账）

iOS 与 Android 在这一点上**根本不同**：

- Android：前台服务 + 长连接，App 在后台甚至被杀后仍能收消息
- iOS：**不允许** App 在后台维持长连接。App 进入后台后，
  WebSocket 会在几十秒内被系统挂起

后果：**iOS 版在后台收不到来电**，这是平台限制，不是 bug。
必须做推送：

| 场景 | 方案 | 为什么 |
|---|---|---|
| 收到新消息 | APNs 普通推送 | 标准做法 |
| **收到来电** | **APNs + PushKit(VoIP) + CallKit** | 普通推送不能唤醒到"能弹全屏来电界面"；VoIP 推送可以在 App 未运行时唤醒并调 `reportNewIncomingCall`，才有原生的来电界面 |

**CallKit 的两个硬约束（现在就要知道，影响后续设计）**：
1. 使用 VoIP 推送**必须**调用 `reportNewIncomingCall`，否则系统会杀 App /
   收回推送权限
2. `reportNewIncomingCall` 之后**必须**在合理时间内（几秒）要么
   `reportCall(with:endedAt:reason:)`，要么真正接通 —— 不能"报来电后一直挂着"

**证书依赖**：VoIP 推送要单独的 PushKit 证书，与普通 APNs 证书分开。
**必须在 Apple 开发者账号办好、Bundle ID 定下来之后再申请** ——
所以这件事**卡在 B 阶段**，现在做不了（也没有意义，Bundle ID 改了证书要重做）。

---

## 5. A 阶段能做完 / 做不了的边界

| 事项 | 现在（无 Mac） | 到 Mac 上 |
|---|---|---|
| AVAudioSession 分类与选项 | ✅ 已定结论并落地到 AppDelegate | 验证真机是否真的双向有声 |
| 中断/路由变化恢复 | ⚠️ 只记录方案 | 真机实测事件是否到达 |
| 免提按钮与实际输出一致 | ⚠️ 只记录问题 | 回读端口状态后改 |
| APNs / VoIP / CallKit | ❌ 依赖开发者账号与证书 | 全量做 |
| 蓝牙耳机/耳机插拔 | ⚠️ 只列清单 | 逐个实测 |

---

## 6. 真机上要重点验的清单（B 阶段直接用）

1. **1v1 语音通话**：双方都能听到对方吗（先不做免提）
2. **点免提**：声音是否真的从扬声器出来（不是只听图标变化）
3. **静音开关**：iPhone 侧边静音拨到静音时，通话是否仍有声音
   （配了 `PlayAndRecord` 才有；没配就会被静掉）
4. **回声**：对着扬声器说话，对方是否听到自己回声（验 `voiceChat` 模式）
5. **插拔耳机**：通话中插拔有线耳机，音频是否自动切换且不中断
6. **蓝牙耳机**：能否同时出声与收音（验 A2DP + HFP 两个选项）
7. **来电中断**：通话中接一个系统电话，挂掉后能否自动恢复
8. **切后台**：App 退到后台，音频是否继续（WebRTC 需要后台音频权限）
9. **锁屏**：锁屏后音频是否继续
10. **前后台切换**：切回来画面与声音是否都正常

---

## 7. 与"工作模式/组织机构"那批需求的关系

这批需求里有一条是"**客户端首次安装完扫描局域网查找服务器**"。
它和本文件的关系是：**首次连接服务器的流程要在 iOS 上重做一遍验证**。

原因：iOS 14 起的**本地网络权限**是个**独立授权**，
用户第一次访问局域网地址时系统才弹窗（而不是安装时）。
漏配 `NSLocalNetworkUsageDescription` 的表现是
"外网能连、内网连不上且不报错" —— 这在 A 阶段的 `Info.plist` 里
**已经配好了**（见 `verify_ios.py` 的检查项），
但**弹窗文案与时机必须真机验证**。
