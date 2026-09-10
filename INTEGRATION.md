# 小智 IM 对接开发文档（开放集成层）

> 版本：v0.4.0 起提供。目标：**任何软件都能在不改 IM 代码的前提下接入**。
> 本文所有示例都可用 `node deploy/demo_integration.js <服务端地址>` 一键跑通。

服务端地址示例：
- 内网：`http://192.168.31.44:3602`
- 外网：`https://<你的域名>`

---

## 一、四种接入方式，按需选

| 方式 | 方向 | 鉴权 | 适用场景 |
|---|---|---|---|
| **入站 Webhook** | 外部 → 群 | URL 里的 token（可选 HMAC 签名） | 最常用。库存预警、销售日报、审批通知，一个 POST 搞定 |
| **开放 API** | 双向 | `Authorization: Bearer xz_xxx` | 需要读会话/成员、发消息、传文件的程序 |
| **出站 Webhook** | 群 → 外部 | 服务端主动回调，带 HMAC 签名 | 想在自己系统里响应群消息、做机器人应答 |
| **WebSocket** | 双向实时 | JWT | 客户端专用（普通对接不建议） |

配置入口：管理后台 → **集成对接**（浏览器访问 `http://服务端地址/admin`）。

---

## 二、入站 Webhook（推荐首选）

### 2.1 创建

管理后台 → 集成对接 → **机器人** → 新建机器人（如「工厂助手」）→ 再点「加入会话」把它拉进目标群。
然后切到 **入站推送（外部 → 群）** → 新建推送地址，选择机器人与目标会话。

创建后得到形如下面的地址：

```
http://192.168.31.44:3602/api/hooks/incoming/86ef7e0987568a99e86aef8455f728c4
```

> 地址里的 token 就是凭证，**不要提交到公开仓库**。怀疑泄露时在后台点「停用」或「删除」，立刻失效。

### 2.2 推送文字

```bash
curl -X POST "http://192.168.31.44:3602/api/hooks/incoming/<token>" \
  -H "Content-Type: application/json" \
  -d '{"text":"【库存预警】东北大米只剩 3 袋"}'
```

响应：

```json
{ "ok": true, "messageId": 12, "conversationId": 1, "kind": "text", "bot": "工厂助手" }
```

### 2.3 推送卡片（日报 / 预警 / 审批单）

字段不用写 `kind`，只要出现 `title` / `fields` / `color` 就自动识别为卡片：

```bash
curl -X POST "http://192.168.31.44:3602/api/hooks/incoming/<token>" \
  -H "Content-Type: application/json" \
  -d '{
    "title": "销售日报 · 9月10日",
    "text": "今日整体达成率 92%，2 个品类未达标。",
    "color": "orange",
    "fields": [
      {"label": "销售额",  "value": "¥128,600", "short": true},
      {"label": "环比",    "value": "+8.4%",    "short": true},
      {"label": "未达标品类", "value": "生鲜、日配"}
    ],
    "footer": "数据来源：工厂管理系统 V2",
    "url": "https://example.com/report/2026-09-10"
  }'
```

**卡片字段规格**

| 字段 | 类型 | 上限 | 说明 |
|---|---|---|---|
| `title` | string | 80 字 | 卡片标题（加粗） |
| `text` | string | 2000 字 | 正文 |
| `fields` | array | 12 项 | 键值对表格，`label` ≤24 字、`value` ≤200 字；`short: true` 表示可与相邻项并排 |
| `color` | string | — | `red` 预警 / `orange` 提醒 / `green` 正常 / `blue` 信息（默认）/ `purple` / `gray` |
| `footer` | string | 120 字 | 脚注，小灰字 |
| `url` | string | 500 字 | 非空时卡片底部出现「查看详情」按钮，点击用浏览器打开 |

`title` / `text` / `fields` 至少要有一个，否则返回 400。
超出上限的内容会被**自动截断**而不是报错，对接方不必自己裁剪。

### 2.4 @ 某人 / @所有人

```json
{ "text": "请各位店长今天下班前核对库存差异", "mentions": ["all"] }
```

`mentions` 支持：`"all"`（所有人）、用户 id（数字）、用户名或昵称。
服务端会二次过滤，只会 @ 到该会话里真实存在的成员。

### 2.5 开启签名校验（生产建议）

创建推送地址时打开「签名校验」，会生成一个 `secret`。之后每个请求必须带：

```
X-Xiaozhi-Signature: sha256=<HMAC-SHA256(原始请求体, secret) 的十六进制>
```

Node.js 验签示例：

```js
const crypto = require('crypto');
const raw = JSON.stringify(body);            // 必须与实际发送的字节完全一致
const sig = 'sha256=' + crypto.createHmac('sha256', SECRET).update(raw, 'utf8').digest('hex');
```

Python 验签示例：

```python
import hmac, hashlib
sig = 'sha256=' + hmac.new(SECRET.encode(), raw_body_bytes, hashlib.sha256).hexdigest()
```

> 签名对**原始字节**计算，所以发送端不要在签名后重新序列化 JSON。

### 2.6 其它

- 用浏览器直接 **GET** 推送地址可自检，返回该地址的用途、机器人、目标会话、是否开启签名。
- 限流：每个地址 **每分钟 120 条**，超出返回 429。
- 单条文字上限 8000 字。

---

## 三、开放 API（API 令牌）

### 3.1 发放令牌

管理后台 → 集成对接 → **API 令牌** → 发放令牌：
选择**身份**（一般选机器人）、勾选**权限**、设置有效期（0 = 永不过期）。
令牌形如 `xz_9c1976f3...`，**只在创建时显示一次**，请立刻保存。

权限（scope）清单：

| scope | 说明 |
|---|---|
| `message:send` | 发送消息 |
| `message:read` | 读取消息 |
| `conversation:read` | 读取会话与成员 |
| `user:read` | 读取用户列表 |
| `file:upload` | 上传文件 |
| `bot:manage` | 管理机器人与 Webhook |

### 3.2 接口一览

所有请求都带 `Authorization: Bearer <令牌>`，基础路径 `/api/open`。

| 方法 | 路径 | 需要 scope | 说明 |
|---|---|---|---|
| GET | `/me` | conversation:read | 令牌自检：返回身份与权限 |
| GET | `/conversations` | conversation:read | 我能发消息的会话列表（拿 conversationId） |
| GET | `/conversations/:id/members` | conversation:read | 会话成员 |
| GET | `/conversations/:id/messages?limit=&sinceId=` | message:read | 读消息，`sinceId` 支持增量拉取 |
| POST | `/conversations/:id/messages` | message:send | 发消息（文字 / 卡片） |
| GET | `/users?q=` | user:read | 搜用户 |
| GET | `/bots` | conversation:read | 机器人清单 |
| POST | `/files` | file:upload | 上传文件（multipart，字段名 `file`） |

### 3.3 示例

```bash
TOKEN=xz_9c1976f379b230026916d4349f762517d7d41ef8cfdd4300
BASE=http://192.168.31.44:3602

# 自检
curl -H "Authorization: Bearer $TOKEN" $BASE/api/open/me

# 找会话 id
curl -H "Authorization: Bearer $TOKEN" $BASE/api/open/conversations

# 发文字
curl -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  $BASE/api/open/conversations/1/messages -d '{"text":"你好"}'

# 发卡片（不写 kind，有 title/fields 即识别为卡片）
curl -X POST -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  $BASE/api/open/conversations/1/messages \
  -d '{"title":"库存预警","color":"red","fields":[{"label":"东北大米","value":"剩 3 袋"}]}'

# 上传文件
curl -X POST -H "Authorization: Bearer $TOKEN" \
  -F "file=@/path/to/report.pdf" $BASE/api/open/files
```

权限不足返回 403，令牌错误/吊销/过期统一返回 401。

---

## 四、出站 Webhook（事件订阅）

### 4.1 创建

管理后台 → 集成对接 → **事件订阅（群 → 外部）** → 新建订阅：
填回调地址、勾选事件（一个都不勾 = 订阅全部）、可选限定监听某个会话。
创建后返回一个 `secret`，用于验签。

### 4.2 可订阅事件

| 事件 | 触发时机 |
|---|---|
| `message.created` | 有新消息（文字 / 图片 / 文件 / 语音 / 卡片） |
| `message.mention` | 消息里 @了人（含 @所有人） |
| `message.recalled` | 消息被撤回 |
| `message.edited` | 消息被编辑 |
| `member.joined` | 有成员加入群聊 |
| `member.left` | 有成员退出 / 被移出群聊 |
| `conversation.created` | 新建会话（单聊或群聊） |
| `ping` | 测试事件（后台「发测试事件」按钮触发） |

### 4.3 请求格式

请求头：

```
Content-Type: application/json
X-Xiaozhi-Event: message.created
X-Xiaozhi-Delivery: 42
X-Xiaozhi-Attempt: 1
X-Xiaozhi-Signature: sha256=<HMAC-SHA256(body, secret)>
```

请求体：

```json
{
  "event": "message.created",
  "ts": 1789014107269,
  "deliveryId": 42,
  "hook": "工厂V2-消息回调",
  "conversation": { "id": 1, "type": "group", "groupId": 1, "title": "工厂管理群" },
  "data": {
    "message": {
      "id": 6,
      "conversationId": 1,
      "senderId": 1,
      "senderName": "管理员",
      "senderIsBot": false,
      "kind": "text",
      "content": "这条消息会触发回调",
      "fileId": null,
      "fileUrl": null,
      "mentions": [],
      "edited": false,
      "deleted": false,
      "createdAt": 1789014107263
    }
  }
}
```

`message.mention` 事件额外带 `data.mentions`（被 @ 的用户 id 数组，`-1` 表示所有人）。

### 4.4 接收端要求

- **2xx 即视为成功**，其它状态码与超时（10 秒）都算失败。
- 失败自动重试，最多 **4 次**，间隔 30 秒 → 2 分钟 → 10 分钟。
- 所有投递（含失败原因、尝试次数）都在管理后台 **投递日志** 里，可点「重发」手工再试。
- 建议**先验签再处理**，并按 `X-Xiaozhi-Delivery` 做幂等（重试可能重复投递同一条）。

**调试技巧**：服务端提供了一个回调自检地址 `POST /api/hooks/ping`，它只回一个 200 与回显内容，不落任何数据。
把订阅地址临时指向它，就能确认「服务端出口网络是否通、请求长什么样」，排查时很好用：

```bash
curl -X POST "http://192.168.31.44:3602/api/hooks/ping" \
  -H "Content-Type: application/json" -d '{"hello":"world"}'
```

Node.js 接收端最小示例：

```js
const crypto = require('crypto');
app.post('/xiaozhi/hook', (req, res) => {
  const raw = req.rawBody;  // 必须拿原始字节，不能是 re-serialize 的 JSON
  const want = 'sha256=' + crypto.createHmac('sha256', SECRET).update(raw).digest('hex');
  if (req.headers['x-xiaozhi-signature'] !== want) return res.status(401).end();
  res.json({ ok: true });   // 先回 200，再异步处理业务
  handle(req.body);
});
```

---

## 五、机器人

机器人是「系统发言人」：

- 是特殊用户，能被拉进群、能发消息、能在成员列表里出现
- **无法登录**（密码不可用），不会冒充真人
- 消息在客户端带「机器人」标签，与真人发言一眼可区分
- 删除机器人会**级联清理**它的 API 令牌与入站 Webhook

对接方通常一个业务系统配一个机器人，例如「工厂助手」「库存预警」「门店日报」。

---

## 六、常见问题

**Q：推送成功了但群里没看到？**
A：确认机器人已加入目标会话（后台「机器人 → 加入会话」，或建推送地址时会自动加入）。

**Q：返回 401 invalid hook token？**
A：地址被停用或删除了。到后台「入站推送」看状态。

**Q：返回 429？**
A：每分钟超过 120 条。批量数据请合并成一条卡片推送，而不是每条一行。

**Q：回调一直失败？**
A：看后台「投递日志」里的 `error` 字段（会写 HTTP 状态码或超时）。确认对方地址能从飞牛所在网络访问。

**Q：卡片在手机上和电脑上都能看吗？**
A：都能。Android / Windows 客户端都会渲染成同一套卡片样式。

**Q：想改卡片配色？**
A：对接方只传语义色名（`red`/`orange`/…），具体色值由客户端决定。IM 换肤不会影响对接。
