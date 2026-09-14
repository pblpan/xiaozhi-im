# 消息管理与文件管理 — 设计规格

> 版本：v1.1（已按代码核对 + 评审修订）
> 状态：**设计已确认，待龙哥过目后开工**
> 目标版本：服务端 v0.14.0（客户端不受影响，本规格不触及任何 Dart 代码）
>
> v1.1 修订（评审发现，逐条已到代码复核）：
> ① 修正"只有管理台在用这些接口"的错误 —— `deploy/` 下还有 5 个脚本在用（§2.5）
> ② 补充 `favorites` / `pinned_message_id` 两个悬空引用级联（§3.3.1，**现存 bug**）
> ③ 扩充受分页影响的调用方：4 处选择器共用 `users.value`（§7）
> ④ 修正索引数量与作用说明（§5，7 条；排序走主键不吃这些索引）
> ⑤ 明确 `from`/`to` 与"全部时间"的语义（§2.1）

---

## 1. 要解决的问题

管理台的「消息管理」「文件管理」是为**小数据量**写的：每个列表接口都是写死的
`LIMIT`，**没有 offset、没有总数**，前端也**没有任何分页器**（全项目 `el-pagination`
出现 0 次）。后果不是"显示得乱"，而是**数据被静默截断**：

| 接口 | 现状 | 后果 |
|---|---|---|
| `GET /admin/messages` | 前端固定要 300 条 | 第 301 条起永远看不到，界面无任何提示 |
| `GET /admin/files` | 写死 `LIMIT 500` | 第 501 个起的老文件在界面上不存在，看不到也删不掉 |
| `GET /admin/users` | 写死 `LIMIT 500` | 同上 |
| `GET /admin/friendships` | 写死 `LIMIT 500` | 同上 |
| `GET /admin/groups` | 无 LIMIT，全量返回 | 群多了直接把响应撑大 |

管理员看到的是"最近 500 条"，但界面上没有任何东西告诉他被截断了。想找一笔历史消息
只能靠关键词搜，搜不到就以为没有。

两个被实测确认的硬伤（生产库实测：`indexes_messages` 为空列表）：

- **`messages` / `files` 表一个索引都没有**。`ORDER BY id DESC` 靠主键还行，但
  `content LIKE '%关键词%'` 是**全表扫描**。
- **没有任何清理机制**，消息只增不减；文件删除只能一条条点。

实测生产当前数据量（2026-09-14）：消息 55 条、文件 7 个共 6.7MB、会话 13 个、用户 9 个。
**量还小，所以现在改正是时候** —— 改完再涨就不会痛。

### 目标

1. 列表**永远能翻到全部数据**，且"一共有多少"始终可见。
2. 能**按人、按时间、按会话、按类型**定位（"找某人某数据"是核心诉求）。
3. 能**按条件批量清理**，且误删风险可控。
4. 文件页能回答"**谁把磁盘吃满了**"和"**磁盘和库对不上**"。
5. 把分页/筛选抽成一套**全站通用**的约定，用户/群/好友列表一并受益，避免以后每页重来。

### 非目标（明确不做）

- **不上 SQLite FTS5 全文检索。** 不是偷懒：FTS5 的中文分词有硬伤 —— `unicode61`
  把连续汉字当成**一个** token（搜「吃饭」匹配不到「我们去吃饭吧」），换 `trigram`
  又要求查询至少 3 个字符（两字词直接失效）。上了反而"该搜到的搜不到"。
  公司内部 IM 量级（50 人 3 年约 20 万条）下 `LIKE` + 时间窗 + 索引是几十毫秒。
  真到千万级要做的不是 FTS5，是换 PostgreSQL。
- **不做自动定时清理。** 第一版只做手动批量，观察一段时间再议是否加保留期。
- **不做消息内容编辑 / 全量审计导出。**
- **不改客户端。** Flutter App 完全不碰这些接口（已逐个核对 `client/`，无 `/api/admin/*`
  调用），所以改响应结构不会波及任何已发布客户端。
  ⚠️ 但**内部脚本在用**，见 §2.5。

---

## 2. 通用列表约定（全站统一）

### 2.1 请求参数

所有列表接口统一接受：

| 参数 | 说明 |
|---|---|
| `page` | 页码，从 1 开始，默认 1 |
| `pageSize` | 每页条数，默认 50，**硬上限 200** |
| `from` / `to` | 时间范围（毫秒时间戳），**含两端**（语义见下） |
| `allTime` | `1` = 不限时间（显式"全部时间"） |
| `sort` | `desc`（默认，新→旧）/ `asc` |

**`from` / `to` 的完整语义**（必须定义清楚，否则每个实现者会各写一套）：

| 传了什么 | 含义 |
|---|---|
| `from` + `to` | 闭区间 `[from, to]` |
| 只传 `from` | 从 `from` 到现在 |
| 只传 `to` | 从最早到现在 `to` |
| 都不传 | **默认最近 30 天**（不是全部！见 §2.4） |
| `allTime=1` | 不限时间。前端「全部时间」选项走这个，**不要靠"不传"来表达** |

### 2.2 响应结构

```json
{ "items": [ ... ], "total": 312, "page": 1, "pageSize": 50 }
```

`total` 是**当前筛选条件下**的总条数，分页器基于它 —— 所以界面上永远知道
"我一共翻得到多少"。

### 2.3 参数护栏（必须实现）

| 输入 | 行为 |
|---|---|
| `page` 为 0 / 负数 / 非数字 | 归一化为 1（不报错，容错优先） |
| `pageSize` 超上限 | 截断到 200（**不能报错**：报错会让前端整页挂掉） |
| `from > to` | 400 |
| `from` / `to` 非法时间戳 | 400 |
| `q` 含 `%` `_` `\` | **转义后再进 LIKE**（见 §3.4） |

> 为什么 `pageSize` 是截断而 `from > to` 是报错：前者前端可能因为状态没初始化好
> 传个超大值，截断是"帮它兜住"；后者是用户操作产生了矛盾条件，必须明确告诉他。

### 2.4 默认时间窗

**打开列表默认只查最近 30 天**，不是全量。这是"数据不炸"的第一道防线，也是最容易
漏掉的一环。筛选栏给快捷选项：今天 / 7 天 / 30 天 / 90 天 / 全部 / 自定义。

⚠️ **配套体验细节（必须做）**：当筛选后 `total === 0` 但全库有数据时，空状态要提示
「当前时间范围内没有数据，试试放宽时间范围」，并给一个「改为全部时间」按钮。
否则用户会以为数据没了 —— 这类"以为数据丢了"的误判比截断本身更吓人。

### 2.5 ⚠️ 这是破坏性变更：受影响的调用方必须同步改

响应从**裸数组**改成 `{items, total, ...}` 对象后，所有原来写
`.body.length` / `.body.find(...)` / 直接当数组遍历的地方**都会静默失效**
（`undefined === 0` 为 false、`undefined.find` 直接抛错）。经逐个核对，
`deploy/` 下有 5 个脚本在消费这些接口：

| 脚本 | 用法 | 风险 |
|---|---|---|
| `deploy/verify_prod_v040.js:271-276` | `(...).body.length === 0` 判断"残留已清除" | ⚠️ **假通过**：`undefined === 0` 为 false，断言方向若反了就变成无声通过 |
| `deploy/verify_prod_v030.js:271-275` | `admMsgs` / `admAdmin` 当数组用 | 抛错或误判 |
| `deploy/clean_test_messages.js:56` | 列表当数组遍历 | 抛错 |
| `deploy/setup_im_for_factory.js:48` | `/admin/users` 当数组用 | 初始化脚本直接坏 |
| `deploy/probe_im.js:26` | `/admin/users` 当数组用 | 探针坏 |

**处理：本次一并改这些脚本**，让它们读 `.body.items`。不留兼容期 ——
这些脚本都在同一个仓库、同一个提交里改，加 `?format=array` 只会留下长期负担。

> 教训：改接口响应结构前**先把所有调用方搜出来**（含脚本、测试、文档里的示例），
> 不能只看前端。`.body.length === 0` 这类断言在结构变了之后是**假通过**，
> 比直接报错更危险。

---

## 3. 消息管理

### 3.1 `GET /api/admin/messages`

筛选参数（在通用参数之外）：

| 参数 | 说明 |
|---|---|
| `senderId` | 按发送者 |
| `conversationId` | 按会话 |
| `kind` | `text` / `image` / `file` / `audio` |
| `q` | 内容关键词 |
| `mentioned` | `1` 只看 @提及 |

响应 `items` 每行：`id, conversation_id, conversation_name, sender_id, sender_name,
kind, content, file_id, created_at, deleted, edited, mentions`。

**新增 `conversation_name`**：现在只显示会话 ID（`conversation_id`），对人毫无意义。
群会话显示群名，单聊显示对方昵称。

### 3.2 排序

默认 `id DESC`。`asc` 时用 `id ASC`（用 id 不用 created_at：id 单调递增且是主键，
created_at 可能因并发写入相同值导致翻页错乱）。

### 3.3 批量清理（三步安全模型）

**不采用"勾选一堆 ID"**，而是**把当前筛选条件直接交给服务端执行**。
理由：用户诉求是"按条件定位"而非人工挑几千条；按条件删顺带解决三个坑 ——
翻页丢勾选、前端要塞几千个 ID、以及点了删除才发现删多了。

| 步骤 | 接口 | 行为 |
|---|---|---|
| 1 | `GET /api/admin/messages/purge-preview`<br>（筛选参数同上） | **只算不删** → `{ count, oldest, newest }` |
| 2 | — | 弹窗列出完整条件 + 条数 + 时间跨度，明说不可恢复 |
| 3 | `POST /api/admin/messages/purge`<br>body: 筛选参数 + `confirm: <条数>` | 服务端**重新算** count，`confirm !== count` → **409 拒绝** |

**第 3 步是核心护栏**：从"算条数"到"真删"之间如果数据变了（有人正在发消息），
服务端会拒绝并返回新的 count，让用户重新确认 —— 而不是多删。

补充护栏：

- 单次 `count > 20000` → 400，要求收窄条件（防止一次删掉整库）
- 执行前**自动导出要删的消息到 `<DATA_DIR>/purge-backup/messages-<时间戳>.json`**，
  并在响应里返回文件名，前端给下载链接。
  成本极低，但把"不可恢复"变成"能捞回来" —— 这是审计留痕的标准做法。
- 整个清理操作走显式 `BEGIN` / `COMMIT`（`node:sqlite` 没有 `db.transaction()`）。

**级联规则**（沿用现有单条删除的语义，不能改）：

1. 收集本次涉及的所有 `file_id`
2. 批量判断每个文件是否**还有其它消息引用**
3. 无引用的：删 `files` 行 + 删磁盘文件
4. 仍有引用的：文件保留
5. 引用消息**已随本次删除消失**，所以不需要像单条删那样把 content 改成
   `[文件已被管理员删除]`（那条规则是给"文件被删但消息还在"准备的）

### 3.3.1 ⚠️ 必须一并修掉的两个悬空引用（现存缺陷）

这两个是**现在就存在的 bug**，批量清理会把它们放大成千倍，所以本次必须一起修：

**(a) `favorites` 收藏残留 —— 会导致收藏数对不上**

`server/src/routes/admin.js:287` 只在**删会话**时清 `favorites`；
而 `DELETE /admin/messages/:id`（`:353`）**完全没清**。后果在 `server/src/chat.js`：

- `:533` 收藏**列表**是 `favorites JOIN messages` —— 消息没了，这一行就 JOIN 不出来
- `:535` 收藏**总数**是 `SELECT COUNT(*) FROM favorites WHERE user_id=?` —— **没有 JOIN**

于是删掉消息后，用户看到「收藏 20 条」但列表里只有 15 条，**数字和内容对不上，
且没有任何报错**。单条删影响小，批量删几千条就会让所有人的收藏数集体虚高。

修法：删除消息**之前**先 `DELETE FROM favorites WHERE message_id IN (...)`，
单条和批量两条路径都要做。

**(b) `conversations.pinned_message_id` 悬空**

`server/src/db.js:175` 定义、`server/src/chat.js:492` 使用。消息被删后这个字段仍指向
已不存在的 id，导致**群公告/置顶位失效**（表现为置顶区空白或报错）。

修法：删除消息前先
`UPDATE conversations SET pinned_message_id=NULL WHERE pinned_message_id IN (...)`。

### 3.4 LIKE 通配符转义（现有代码已做，保持）

```js
params.push('%' + q.replace(/[\\%_]/g, (ch) => '\\' + ch) + '%');
// SQL: m.content LIKE ? ESCAPE '\'
```

不转义的话，管理员输入 `%` 就变成"匹配全部"，输入 `_` 匹配任意单字符 ——
搜索框就成了全表扫描的开关。

---

## 4. 文件管理

### 4.1 `GET /api/admin/files`

| 参数 | 说明 |
|---|---|
| `ownerId` | 按上传者 |
| `mime` | 类型前缀匹配（`image` 匹配 `image/png`） |
| `minSize` / `maxSize` | 字节数范围 |
| `q` | 原始文件名关键词 |

响应每行**新增 `refCount`** —— 该文件被多少条消息引用。
删除前用它告知影响面，避免"文件删了，还有人翻旧消息点不开"。

### 4.2 `GET /api/admin/files/storage` — 存储占用分析

```json
{
  "totalBytes": 6763314, "totalCount": 7,
  "byType":  [ { "mime": "image/png", "count": 4, "bytes": 1234567 } ],
  "byOwner": [ { "owner_id": 2, "username": "王建国", "count": 3, "bytes": 999999 } ]
}
```

`byType` 按 `bytes` 降序；`byOwner` 取 **TOP 10**。这直接回答"谁把磁盘吃满了"。

### 4.3 `GET /api/admin/files/orphans` — 孤儿文件巡检

两类不一致，都要能查出来：

| 类别 | 含义 | 成因 |
|---|---|---|
| `dbOnly` | `files` 表有记录，磁盘文件不存在 | 断链：手动删了磁盘文件 / 挂载变更 / 迁移丢文件 |
| `diskOnly` | 磁盘有文件，`files` 表无记录 | 残留：删库残留 / 上传中途失败 |

```json
{ "dbOnly": [ {...} ], "diskOnly": [ {...} ], "counts": { "dbOnly": 2, "diskOnly": 5 } }
```

实现注意：

- 扫描 `FILES_DIR` 只做**单层 + 有限递归**，并对结果设上限（默认 5000），
  避免超大目录把接口拖死；超出上限时在响应里标 `truncated: true`。
- 排除 `purge-backup/` 等非用户文件目录。

### 4.4 批量清理

与消息同构：`purge-preview` → 手输条数确认 → `purge`。
额外支持 `orphanOnly=1`（只清 `diskOnly` 残留），这一类**删除风险最低**，
因为库里本来就没记录。

### 4.5 保留现有单条删除语义

`DELETE /api/admin/files/:id` 现在的行为是：

```js
db.prepare('UPDATE messages SET file_id=NULL,kind=?,content=? WHERE file_id=?')
  .run('text', '[文件已被管理员删除]', fid);
```

即**消息保留、内容替换成占位文案**。这个行为是对的（用户翻到旧消息至少知道发生过什么），
批量和单条都要保持一致。

---

## 5. 索引

在 `server/src/db.js` 的索引区追加（`CREATE INDEX IF NOT EXISTS` 幂等，不需要迁移标记）。
共 **7 条**（messages 4 + files 3）：

```sql
CREATE INDEX IF NOT EXISTS idx_messages_created ON messages (created_at);
CREATE INDEX IF NOT EXISTS idx_messages_sender  ON messages (sender_id, created_at);
CREATE INDEX IF NOT EXISTS idx_messages_conv    ON messages (conversation_id, created_at);
CREATE INDEX IF NOT EXISTS idx_messages_kind    ON messages (kind, created_at);
CREATE INDEX IF NOT EXISTS idx_files_created    ON files (created_at);
CREATE INDEX IF NOT EXISTS idx_files_owner      ON files (owner_id, created_at);
CREATE INDEX IF NOT EXISTS idx_files_size       ON files (size);
```

**为什么不写 `DESC`：** SQLite 可以**反向扫描**索引，所以单列索引上标 `DESC` 与
`ASC` 完全等价，写了只是噪音。（只有多列且**各列方向不一致**时，方向才有意义，
本规格没有这种场景。）

**这些索引解决什么、不解决什么（别指望错）：**

| 用途 | 是否用得上索引 |
|---|---|
| 时间范围筛选 `created_at BETWEEN ? AND ?` | ✅ `idx_messages_created` |
| 按发送者筛 + 时间范围 | ✅ `idx_messages_sender`（复合，两列都吃到） |
| 按会话 / 按类型筛 + 时间范围 | ✅ 同理 |
| **排序** `ORDER BY id DESC` | ✅ 走**主键**（`messages` 是 `INTEGER PRIMARY KEY`，即 rowid，天然有序）—— 用不上上面任何一条 |
| 关键词 `content LIKE '%x%'` | ❌ **前导通配符，任何索引都用不上** |

所以整体策略是：**索引负责把行数砍下来（时间/人/会话/类型），再对剩下的少量行做 LIKE**。
这也是为什么 §2.4 的默认时间窗如此重要 —— 没有它，LIKE 会扫全表。

---

## 6. 界面改动（admin/src/App.vue）

### 6.1 抽通用分页

因为目标是"全站列表统一分页"，所以抽一套可复用件：

- `usePager(loader)` 组合式函数：管理 `page / pageSize / total / loading`，提供
  `reload()` / `reset()`（重置到第 1 页）。
- 一段通用分页器模板：`el-pagination` + `layout="total, sizes, prev, pager, next, jumper"`。
- 通用筛选栏：时间范围快捷选项 + 自定义。

**筛选条件变化时必须重置到第 1 页** —— 否则在第 5 页改筛选条件，会查到空结果，
用户以为"没数据"。

### 6.2 消息管理页

筛选栏（时间范围 / 发送者 / 会话 / 类型 / 内容关键词）+ 表格 + 分页器
+ 「批量清理」按钮 + 「导出当前结果」入口。

筛选栏里**两个下拉都需要新的数据源**，现有接口都不合适：

| 下拉 | 需要什么 | 现有接口的问题 |
|---|---|---|
| 发送者 | 全部用户 `{id, username}` | `/admin/users` 改分页后只回一页 → 见 §7 |
| 会话 | 全部会话 `{id, name, type}` | 现在会话列表来自 `integrations.js:30-36`，**群和单聊各自 `LIMIT 100`** → 第 101 个群选不到 |

所以新增 `GET /api/admin/conversations/options` → `[{ id, name, type }]`，
与 §7 的用户 options 同构、同样不分页。

### 6.3 文件管理页

- 顶部三张卡片：总占用 / 文件数 / 库盘不一致数
- 存储占用区块：按类型分布 + 按上传者 TOP 10（条形）
- 标签页：全部文件 / 孤儿巡检
- 表格加「引用」列（`refCount`）

### 6.4 用户 / 群 / 好友页

接同一套分页，消灭另外几处静默截断：

| 接口 | 现状 |
|---|---|
| `GET /admin/users` | 写死 `LIMIT 500` |
| `GET /admin/friendships` | 写死 `LIMIT 500` |
| `GET /admin/groups` | **完全没有 LIMIT**，全量返回（群多了直接把响应撑大） |
| `GET /admin/modules/:id/submissions` | 固定 `LIMIT 100` |

⚠️ 用户页分页后**必须同时处理 §7 的共享 `users.value` 问题**，
否则 4 处选择器会集体少人。

---

## 7. ⚠️ 最大的副作用：共享 users 数组被 4 处选择器依赖

管理台有一个**全局共享的 `users.value`**（由 `admin/src/App.vue:3155-3159` 的
`Promise.all` 一次性拉取后赋值），然后被下面这些地方**同时依赖**：

| 位置 | 用途 | 分页后的后果 |
|---|---|---|
| `App.vue:634` + `:3532` `filteredUsers` | 用户页表格 + **前端搜索** | 搜索只在本页 50 条里搜，**搜不到第 51 个人**，且不报错 |
| `App.vue:2748` + `:3740` `identityOptions` | 身份下拉（机器人 / 发言者） | 第 51 个人选不到 |
| `App.vue:2665` `groupForm.member_ids` | 建群选成员（多选） | 建群漏人 |
| `App.vue:2359` `attGroupForm.memberIds` | 考勤组指定到人（多选） | 考勤组漏人 |

这四处**都不会报错**，只会"人变少了"—— 属最难查的一类问题。

### 处理办法

**(a) 新增不分页的轻量 options 接口**（供上述 4 处消费）：

```
GET /api/admin/users/options
→ [ { id, username, nickname, is_bot } ]      // 不分页，只回必要字段
```

**(b) 用户页的搜索改到服务端**：`GET /admin/users?q=<关键词>`，不再用
`filteredUsers` 做前端过滤。前端过滤 + 服务端分页天然矛盾，必须二选一 ——
这里选服务端，因为分页是本次的目标。

用户上千时 options 接口本身会变大。第一版接受（4 个字段，1000 人约 40KB）；
真到上万再做**服务端搜索式下拉**（输入关键词才查、回前 50 条）。现在不做，YAGNI。

---

## 8. 测试

### 8.1 服务端 E2E（新增 `server/test/admin_list_e2e.js`）

**核心回归用例**（直接锁住本次要修的 bug）：

1. 造 120 条数据，`pageSize=50` → 逐页取完确实拿到 **120 条不重不漏**
   （用 id 集合校验）
2. 每页 `total` 一致，且等于逐页条数累加
3. `page=0` / `page=-1` / `page=abc` → 归一化为第 1 页
4. `pageSize=999999` → 截断到 200，**不报错**
5. `from > to` → 400
6. 筛选：时间范围 / 发送者 / 会话 / 类型 各自命中数正确
7. `q='%'` 查找**不应**匹配全部（通配符转义）
8. `purge-preview.count` 与随后 `purge` 实际删除数一致
9. `confirm` 传错数字 → **409**，且数据**一条没少**
10. `count` 超 20000 → 400
11. 备份文件确实生成且内容条数等于删除数
12. 删除后：无引用的文件行与磁盘文件都消失；有引用的文件保留
13. 孤儿巡检两类都能正确识别（造一个 dbOnly、一个 diskOnly）
14. `/users/options` 返回全部用户，不受 pageSize 影响
15. `/conversations/options` 返回全部会话（含第 101 个，锁住 `LIMIT 100` 截断）
16. `/admin/users?q=` 服务端搜索命中第 51 个人之后的用户（锁住前端过滤的坑）

**悬空引用回归用例**（锁住 §3.3.1 的两个现存 bug）：

17. 收藏一条消息 → 删该消息 → `favorites` 行消失，**且「收藏数」与「收藏列表长度
    相等」**（直接锁住 `chat.js:533` JOIN / `:535` 不 JOIN 的不一致）
18. 置顶一条消息 → 删该消息 → `conversations.pinned_message_id` 变为 NULL
    （不是留下一个指向不存在消息的 id）

### 8.2 前端真机渲染

扩展现有 `deploy/admin_ui_check.js`：5 个页签 + 两个新页签（存储分析 / 孤儿巡检）
零 console 报错，并截图。**bundle grep 抓不出白屏，必须真渲染一次。**

### 8.3 生产只读冒烟

扩展 `deploy/att_api_smoke.js` 的模式，新增一个只读校验：
分页接口返回 `total` 且 `items.length <= pageSize`；`purge-preview` 只读不写。

---

## 9. 版本与交付

- 服务端 **0.14.0**（`server/package.json` + `deploy/fpk-build/manifest`）
- **客户端版本不动**（本规格不触及任何 Dart 代码，App 不调这些接口）
- 交付：重建 `server/public`（管理台构建产物）+ 重打 fpk + 热更生产
- `client/verify_release.py` 增加 v0.14.0 判据（管理台静态资源里的新组件标识；
  判据**先在产物上实测命中再写进清单**）
- **同步改 5 个内部脚本**读 `.body.items`（见 §2.5）：
  `verify_prod_v030.js`、`verify_prod_v040.js`、`clean_test_messages.js`、
  `setup_im_for_factory.js`、`probe_im.js`

---

## 10. 风险与取舍

| 风险 | 处理 |
|---|---|
| `OFFSET` 深翻页慢 | 接受。默认 30 天窗 + 筛选已把结果集压小；真要翻到第 1 万页是极端场景 |
| 批量删误伤 | 三步确认 + 手输条数 + 单次上限 + 自动备份，四重 |
| **响应结构变更打破内部脚本** | 5 个 `deploy/` 脚本同步改（§2.5）；`.body.length` 型断言会**假通过**，必须逐个改成 `.body.items` |
| **4 处选择器静默少人** | `/users/options` 独立接口 + 用户页搜索改服务端（§7） |
| 会话/类型下拉拿不到全部 | `/conversations/options`（§6.2） |
| 删消息留下收藏/置顶悬空引用 | §3.3.1 两个级联修复 + 用例 17/18 锁住 |
| 老数据"消失"的错觉 | 默认时间窗 + 空状态引导按钮（§2.4） |
| 索引影响写入性能 | 7 个索引；内部 IM 写入量极低，可忽略 |
