# iOS 推送（APNs）方案与落地清单

> 配套文档：`iOS版开工前置报告.md`（排期与前置条件）、`iOS音频会话设计.md`（通话）。
> 本文只讲**推送**这一期（前置报告里的 D1），并且区分清楚「服务端已经做完的部分」
> 和「必须在 Mac 上做的部分」。

---

## 一、为什么这件事不能省

Android 客户端缩到后台/托盘时，靠**常连 WebSocket**继续收消息（所以那个版本专门做了
「关闭窗口缩到托盘」）。iOS 没有这条路：App 一退到后台，进程很快被系统挂起，socket 断掉。

结果就是：**不打开 App 就收不到任何消息**。而「能随时收到消息」恰恰是这个 IM 存在的理由。

所以 iOS 版的正确形态是：

```
有新消息 → 服务端判断收件人此刻不在线 → 投一条 APNs 通知 → 用户点通知 → 拉起 App → 连 WS 拉增量
```

---

## 二、服务端：已完成（本机可测，不依赖 Mac）

### 2.1 实现位置

| 文件 | 作用 |
|---|---|
| `server/src/push.js` | APNs 投递引擎：provider JWT 签发、HTTP/2 连接复用、令牌登记、失效治理、投递日志 |
| `server/src/routes/push.js` | 客户端接口（`/api/push`）+ 管理台接口（`/api/admin/push`） |
| `server/src/chat.js` | `notifyPush()`：发消息时决定「推给谁、文案是什么」 |
| `server/src/db.js` | 新表 `push_devices`（设备令牌）、`push_log`（投递日志） |
| `server/test/apns_push_test.js` | **80 项断言**的链路实测（本地假 APNs） |

### 2.2 关键设计（每条都有"不这么做会怎样"）

- **用 token-based（.p8 密钥）而不是推送证书**：一把密钥管所有 App、所有环境，
  不会像证书那样一年一换再全量重发。签名只用 `node:crypto`，**没有新增任何依赖**。
- **只用出站 443**：和 Cloudflare TURN 同一个道理，家宽没有公网 IP 也能用，不需要端口映射。
- **`dsaEncoding: 'ieee-p1363'` 不能省**：ECDSA 默认吐 DER，而 JWS 要求裸的 R‖S。
  写错了 Apple 只回一个 `403 InvalidProviderToken`，完全看不出是哪里错。
  （这条已被测试**反向验证**过：去掉它，测试里那条验签断言当场失败。）
- **在线的人不推**：连着 WebSocket 说明消息已经实时到了，再推一条就是重复打扰。
- **410 / BadDeviceToken 才作废令牌**：5xx / 429 / 网络错误**绝不**因此下线设备
  —— 把 Apple 侧的抖动当成"令牌死了"，用户就再也收不到推送了。
- **令牌以 token 为唯一键 upsert**：同一台手机换人登录时，旧账号的推送必须立刻停。
  否则会出现「新用户登录后，手机还在收上一个用户的私聊通知」——最严重的一类隐私事故。
- **通知栏不回显正文全文**：图片/语音/文件/卡片都只显示 `[图片]` `[语音]` `[文件] 报表.xlsx`
  `[卡片] 库存预警`，锁屏上不该把私聊内容整段摊开。
- **投递结果全部落 `push_log`**：没有这张表，"用户说收不到通知"就只能靠猜；
  而 APNs 的 `reason`（`BadDeviceToken` / `Unregistered` / `DeviceTokenNotForTopic`）
  恰好能直接定位问题。令牌在日志里**只留尾 8 位**。

### 2.3 接口

**客户端（需登录）**

| 方法 | 路径 | 说明 |
|---|---|---|
| POST | `/api/push/register` | 上报设备令牌 `{token, env?, deviceName?}`；返回 `serverEnabled` 告诉客户端"这台服务器到底会不会推" |
| POST | `/api/push/unregister` | 退出登录 / 关通知开关时调用（**删行**，不是置无效） |
| GET | `/api/push/devices` | 我登记过的设备（令牌只回尾号） |

**管理台（需管理员）**

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/api/admin/push` | 状态 + 统计 + 最近投递日志 |
| POST | `/api/admin/push/probe` | **本地自检**：拿（可以还没保存的）凭据试签一次 JWT，不联网、不落盘 |
| POST | `/api/admin/push/config` | 保存并**立即生效**（同时写 `apns.env`，容器重建不丢） |
| POST | `/api/admin/push/test` | **发一条真推送** —— 唯一能证明"Apple 认这对密钥"的办法 |
| POST | `/api/admin/push/clear` | 清空配置 |
| POST | `/api/admin/push/sweep` | 清老投递日志（默认留 30 天，服务端每 12 小时自动清一次） |

冷启动接口 `/api/client/bootstrap` 也带上了 `push: {enabled, topic, env}`，
客户端据此决定**要不要请求通知权限** —— 服务器没配推送就上报令牌，用户会一直等一条永远不来的通知。

### 2.4 实测覆盖（80 项，`node server/test/apns_push_test.js`）

本地起一个假 APNs（明文 h2c，省掉自签证书），逐项断言请求头/请求体，**并用公钥真验签**：

1. 没配密钥时：不发任何请求、不写日志
2. 正常投递：方法/路径、`apns-topic`、`apns-push-type`、`apns-priority`、
   `apns-collapse-id`、`apns-id`、`apns-expiration`、`authorization`、
   JWT 的 `alg/kid/iss/iat` 与签名、`aps.alert`、`aps.badge`、`aps.thread-id`、自定义跳转数据
3. **410 `Unregistered`** → 设备下架、第二次不再投
4. **400 `BadDeviceToken`** → 同样下架
5. **500** → 设备**留着**、`fail_count` 累加、下次仍重试
6. 响应体是 HTML（有网关时）→ 不崩、reason 退化成状态码
7. sandbox 令牌 + production 服务器 → **一条都不发**，且不误杀令牌
8. 同一令牌换账号 → 只留一行、归属改新用户、旧账号收不到
9. **端到端**：发消息 → 该推谁、单聊标题取"接收方视角的会话名"（含好友备注）、
   群消息标题=群名且正文带发送者、在线不推、自己发的不推、五种消息类型的预览文案
10. 管理台自检：缺私钥 / Key ID 位数不对 / 把证书当私钥贴 / 私钥内容损坏
    → 全部判为不可用；且**自检不会改动已保存的配置**

> ⚠️ 诚实标注：这套测试证明的是"请求构造、签名、令牌治理、文案组装"是对的。
> 它**不能**证明 Apple 会接受这对密钥 —— 那必须要一条真推送（`/api/admin/push/test`）。

---

## 三、客户端（iOS）：必须在 Mac 上做

### 3.1 依赖选型：**不引第三方插件，自己写 MethodChannel**

理由：

1. 只有两件事要做 —— **取到 deviceToken** 和 **处理通知点击**，加起来几十行 Swift；
2. 引 `flutter_apns` 之类的插件会影响 Windows / Android 的构建（插件注册表是全局的），
   而这两个平台现在都是**已经能发货**的状态，不能为了 iOS 去冒回归风险；
3. 项目本来就在手写原生代码（Android 侧已经有 `xiaozhi/guard` 这个 MethodChannel 的先例），
   风格一致，排查时也不用去读第三方库。

### 3.2 要改的文件

| 文件 | 改动 |
|---|---|
| `ios/Runner/AppDelegate.swift` | 设 `UNUserNotificationCenter` 代理；实现 `didRegisterForRemoteNotificationsWithDeviceToken`（令牌 → 十六进制 → 回调 Dart）；实现"通知被点击"（带 `conversationId` 回调 Dart） |
| `ios/Runner/Info.plist` | **不需要** 加 `UIBackgroundModes: remote-notification`（那是给静默推送用的；我们发的是 alert 推送，加了反而会引审核问询）。ATS 已经按 `NSAllowsLocalNetworking` 配好了 |
| Xcode → Signing & Capabilities | 加 **Push Notifications** 能力（生成 `aps-environment` 授权）。用 .p8 之后**不需要**再建推送证书，但 App ID 上必须勾上这个能力 |
| `client/lib/core/push.dart`（新建） | `requestPermission()` → `registerForRemoteNotifications()` → 拿到令牌调 `POST /api/push/register`；监听点击事件 → 交给导航层跳对应会话；退出登录时调 `/api/push/unregister` |
| `client/lib/main.dart` | 已登录且 `bootstrap.push.enabled` 为真时才走上面的流程 |

### 3.3 三个必踩的坑（提前写下来）

1. **令牌只能真机拿**。模拟器上 `didRegisterForRemoteNotificationsWithDeviceToken` 不会被调用
   （iOS 16+/Apple Silicon 模拟器有例外，但不要指望）。至少一台真 iPhone。
2. **`env` 必须对上**。Xcode 直连调试拿到的令牌是 **sandbox** 的，TestFlight / Ad Hoc
   装出来的包是 **production** 的，两边不通用。服务端已经按 env 分组、不匹配就跳过
   （不会误杀令牌），但配置时要把服务端的 `env` 调到和当前装的包一致。
3. **通知点击要在"App 还没起来"时也能处理**。冷启动路径（`launchOptions` 里带 remote
   notification）和热启动路径（`didReceive`）**两条都要接** —— 这和 Android 侧
   「分享到小智」那次踩的坑完全同构（冷启动 `getInitialShare` + 热启动 `onNewIntent`）。

---

## 四、需要龙哥准备的东西

| 项 | 说明 | 能不能绕过 |
|---|---|---|
| **Apple 开发者账号** | ¥688/年 | **不能**。推送、真机长期调试、TestFlight 全都要它 |
| **APNs 密钥（.p8）** | Apple Developer → Keys → 新建一个勾选 *Apple Push Notifications service (APNs)* 的 Key，下载后拿到 **Key ID** | 不能。**注意：.p8 只能下载一次**，丢了只能重新生成 |
| **Team ID** | 开发者账号主页右上角那 10 位 | 不能 |
| **Bundle ID** | 建议 `com.pblpa.xiaozhi-im`（与 Android 的 `com.example` 分开，理由见前置报告第五节） | 不能，且要和 Xcode 工程、服务端 `APNS_TOPIC` 三处一致 |
| **一台真 iPhone** | 模拟器测不了推送 | 不能 |

拿到 `.p8` 后怎么填：管理台「系统设置 → 消息推送」填 Key ID / Team ID / Bundle ID / 私钥内容
→ 点**自检**（当场能发现"少了换行""贴成证书"这类问题）→ 保存 → 在 iPhone 上打开一次 App
→ 回到管理台点**发送测试推送**。
（管理台面板还没做，目前可以用 `POST /api/admin/push/config` 直接写，或把参数写进
`${DATA_DIR}/apns.env` 后重启容器。）

---

## 五、Mac 到位后的执行顺序（D1 段）

| 步 | 做什么 | 验收信号 |
|---|---|---|
| D1-1 | Xcode 工程加 Push Notifications 能力 + 上传/新建含该能力的 App ID | 描述文件里出现 `aps-environment` |
| D1-2 | `AppDelegate.swift` 接 `didRegisterForRemoteNotifications...`，Dart 侧打日志 | 真机日志里出现 64 位十六进制令牌 |
| D1-3 | 调 `/api/push/register` | 数据库 `push_devices` 多一行，`env` 与实际包一致 |
| D1-4 | 管理台发测试推送 | **锁屏上弹出通知**（这一步才真正证明密钥有效） |
| D1-5 | App 退到后台，用另一个账号发消息 | 锁屏收到通知，标题是会话名、正文是一句话预览 |
| D1-6 | 点通知 | App 被拉起并**直接进到那个会话**（冷启动、热启动两条路径都试） |
| D1-7 | 退出登录 | `push_devices` 里该设备消失，此后不再收到该账号的通知 |
| D1-8 | 恶意路径：服务端把 `env` 改成 sandbox | 该设备被跳过（`skipped` 计数 +1），令牌**没被作废** |

配套的 `verify_ios.py` 里已有"工程文件不许残留生产地址"这类静态断言；
推送这一期要在 C2 段（判据实测）**实测哪些字符串在 iOS 产物里真的留下来了**再补判据 ——
照抄 Android 的清单会得到一堆永远不命中的假判据。

---

## 六、这一期**不做**的事

- **VoIP Push + CallKit**（锁屏来电像真电话一样响）：这是 D2，需要额外的 PushKit 权限。
  普通 alert 推送在锁屏上响铃不够看 —— 要解锁、要手动打开 App 才接得上。
  在 D2 之前，iOS 端**来电只能在 App 前台时正常振铃**。
- **Android 统一推送（FCM/厂商通道）**：`push_devices.platform` 留了列，
  但当前只投 `ios`。Android 现在靠常连 WS 是能用的，优先级低。
