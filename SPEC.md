# 小智 IM（XiaoZhi IM）需求与架构规格

> 版本：v0.1.0（MVP 规划）
> 定位：自研即时通讯系统，**借鉴开源 IM 功能设计、不直接使用其源码**。
> 先期落地：飞牛 FnOS 服务端 + Windows 客户端 + Android 客户端。

---

## 1. 目标与原则

- **自主可控**：服务端私有化部署，数据 100% 存自己服务器（飞牛/群晖/绿联/麒麟等）。
- **多端覆盖**：服务端 Linux（飞牛优先），客户端 Win / Android / Mac / iOS（先期 Win+Android）。
- **借鉴而非复制**：吸收 Tailchat（界面布局/插件化）、Matrix（事件溯源/联邦思路）、Rocket.Chat（客服/加密）、Mattermost（Webhook 集成）、Zulip（话题线程）的优点，协议与代码自研。
- **渐进交付**：先跑通基础通讯链路，再迭代音视频、加密、机器人、联邦。

---

## 2. 技术栈（已确认）

| 层 | 选型 | 说明 |
|---|---|---|
| 服务端语言 | Node.js 22 (LTS) | 与现有工厂 V2 栈一致 |
| Web 框架 | Express 5 | 轻量、生态成熟 |
| 实时通讯 | WebSocket (`ws`) | 双向 JSON 帧 |
| 数据库 | SQLite (`node:sqlite`) | 内置模块、零原生依赖；小规模够用，后期可换 PostgreSQL |
| 鉴权 | JWT (HS256) + scrypt 密码哈希 | Node 内置 crypto |
| 文件 | 本地磁盘 + HTTP 下载 | 元数据入表 |
| 服务端管理 UI | Vue 3 + Element Plus（Vite 构建） | 由 Express 托管 |
| 客户端框架 | Flutter 3 | 一套 Dart 代码出 Android + Windows 桌面 |
| 部署 | Docker + 飞牛 fpk | ARM64 / x86 双架构 |

---

## 3. 功能范围（MVP = 基础通讯）

### 3.1 必做（首版）
- [x] 账号：注册、登录、JWT 鉴权、修改昵称/头像
- [x] 好友：搜索用户、发送/接受好友请求、好友列表
- [x] 单聊：文字、表情、图片、文件
- [x] 群聊：建群、邀请成员、群成员管理、群消息
- [x] 实时消息：WebSocket 推送，在线即达；离线消息登录后拉取
- [x] 文件：图片/文件上传下载（服务端磁盘存储）
- [x] 服务端可视化管理：用户管理、群组管理、消息/文件统计、服务器配置

### 3.2 后期（迭代，不在首版）
- [x] 已读回执、输入中状态、消息撤回/编辑（v0.1.9）
- [x] 语音消息（v0.2.0）：长按录音、松手即发、上滑取消，单条上限 60 秒，波形气泡点击播放
- [x] 全局消息搜索（v0.2.0）：跨会话搜「我参与的」文字消息，命中关键词高亮，点击直达会话
- [x] @提及 + 消息转发 / 收藏 / 置顶（v0.3.0）：群聊输入 @ 选成员或 @所有人，被点名者会话列表显示「有人@我」；
      消息可转发到多个会话、收藏进「我的收藏」跨会话回看、由群主或管理员置顶到会话顶部
- [x] 群管理（v0.3.0）：改群名 / 群公告、设撤管理员、禁言（10 分钟/1 小时/1 天）、移出成员、转让群主、退群
- [ ] 语音通话 / 视频会议
- [ ] 端到端加密 (E2EE)
- [ ] 机器人 / Webhook（对接 OA/ERP，吸收 Mattermost 思路）
- [ ] 群聊话题线程（吸收 Zulip 思路）
- [ ] 联邦互通（吸收 Matrix 思路）
- [ ] Mac / iOS 客户端

---

## 4. 系统架构

```
┌─────────────────┐         ┌──────────────────────────────────┐
│  Windows 客户端  │         │       飞牛 FnOS 服务端             │
│   (Flutter)      │         │  ┌────────────────────────────┐  │
├─────────────────┤  HTTPS/  │  │  Express 5 (REST API)       │  │
│  Android 客户端  │  WSS     │  │  + WebSocket Hub (ws)       │  │
│   (Flutter)      │ ───────► │  │  + Vue3 Admin UI (静态托管) │  │
└─────────────────┘          │  └───────────┬──────────────┘  │
                             │        ┌──────┴──────┐          │
                             │        │  SQLite      │          │
                             │        │  (node:sqlite)│          │
                             │        └──────┬──────┘          │
                             │        ┌──────┴──────┐          │
                             │        │  ./data/files│          │
                             │        │  (上传文件)   │          │
                             │        └─────────────┘          │
                             └──────────────────────────────────┘
```

### 4.1 分层
- **接入层**：Express 提供 REST + 静态资源；`ws` 提供 WebSocket 长连接。
- **业务层**：鉴权、用户、好友、群组、消息、文件、管理。
- **存储层**：SQLite（结构化数据）+ 文件系统（媒体/文件）。
- **管理面**：独立 `/admin` 路由，仅 `role=admin` 可访问。

### 4.2 通信协议（自研）
- 客户端连接 `wss://host/ws?token=JWT`。
- 首帧可选 `auth` 确认；服务端按 token 绑定 user_id ↔ socket。
- 消息帧（JSON）：
  ```json
  { "type": "message:send",
    "conversationId": "c_xxx",
    "kind": "text|image|file|emoji|audio",
    "content": "...", "fileId": "..." }
  ```
  > `kind=audio` 时 `content` 存语音时长（秒，1~600 截断），音频本体走 `fileId`；
  > 客户端录音上限 60 秒，服务端只做范围归一化与文件存在性校验。
- 服务端落库后向会话成员广播：
  ```json
  { "type": "message:new", "message": { ... } }
  ```
- 其他事件：`friend:request` / `friend:accepted` / `group:invited` / `presence`（后期）。

---

## 5. 数据模型（SQLite）

| 表 | 关键字段 |
|---|---|
| `users` | id, username(唯一), password_hash, nickname, avatar, role(admin/user), created_at |
| `friendships` | id, user_id, friend_id, status(pending/accepted), created_at |
| `groups` | id, name, owner_id, avatar, announcement(群公告), conversation_id, created_at |
| `group_members` | group_id, user_id, role(owner/admin/member), muted_until(禁言到期), joined_at |
| `conversations` | id, type(dm/group), pinned_message_id(置顶消息), created_at |
| `conversation_members` | conversation_id, user_id, last_read_id, muted(免打扰) |
| `messages` | id, conversation_id, sender_id, kind, content, file_id, topic, mentions(@提及 id 列表), created_at, edited, deleted |
| `files` | id, owner_id, name, mime, size, path, created_at |
| `favorites` | id, user_id, message_id, created_at（UNIQUE(user_id,message_id)，重复收藏幂等） |

> 单聊 = 仅 2 人的 `conversations(type=dm)`；群聊 = 多人的 `conversations(type=group)`。
> 首版消息为"先删后插"简单模型；后期升级为 Matrix 式事件溯源（编辑/撤回=新业态）。

---

## 6. 多端部署矩阵

| 平台 | 形态 | 首期 |
|---|---|---|
| 飞牛 FnOS | fpk (ARM64/x86) + Docker | ✅ 服务端 |
| 群晖 / 绿联 / 麒麟 | Docker Compose（通用 Linux） | ✅ 同服务端镜像 |
| Windows 服务端 | EXE / nssm（可选） | ❌ 先期不做 |
| Windows 客户端 | Flutter Windows → .exe | ✅ |
| Android 客户端 | Flutter → .apk / .aab | ✅ |
| macOS 客户端 | Flutter macOS | ❌ 后期 |
| iOS 客户端 | Flutter iOS | ❌ 后期 |

自适应安装包策略：
- Linux 各 NAS：统一 Docker 镜像 + 平台适配的 `docker-compose.yaml` 与（飞牛）fpk 打包脚本。
- 飞牛 fpk：标准 FnOS 结构 `manifest` + `app.tgz`(docker/源码) + `cmd/` + `config/` + `ui/` + `ICON*.PNG`，compose 引用预构建镜像、加 `restart: unless-stopped`。

---

## 7. 目录结构

```
xiaozhi-im/
├── server/                # Node.js 后端 + 管理 UI 托管
│   ├── src/
│   │   ├── index.js       # 入口：Express + ws + 静态托管
│   │   ├── db.js          # SQLite 初始化与表结构
│   │   ├── auth.js        # JWT / 密码哈希
│   │   ├── ws.js          # WebSocket Hub
│   │   ├── config.js      # 环境变量配置
│   │   └── routes/        # auth/users/friends/groups/messages/files/admin
│   ├── public/            # 构建后的 Vue 管理 UI
│   ├── data/              # SQLite 文件 + 上传文件（运行时生成）
│   └── package.json
├── admin/                 # Vue3 + Element Plus 管理后台源码（Vite）
├── client/                # Flutter 客户端（Win + Android）
└── deploy/                # Dockerfile / compose / 飞牛 fpk 打包
```

---

## 8. 验收标准（MVP）

1. 服务端在飞牛 Docker 内启动，HTTP/WebSocket 可连。
2. 注册两个账号 → 互加好友 → 单聊收发文字/图片/文件，实时到达。
3. 建群 → 多人收发群消息。
4. `/admin` 可视化管理：看到用户数/群数/消息数，能禁用户/删群。
5. Windows 与 Android 客户端采用「左侧会话栏 + 消息区」布局（宽屏双栏 / 窄屏跳转），同一后端账号数据互通。
