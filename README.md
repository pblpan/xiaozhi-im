# 小智 IM（XiaoZhi IM）

自研即时通讯系统。**借鉴开源 IM 的功能设计，不直接使用其源码**；协议与代码完全自研。
先期落地：**飞牛 FnOS 服务端 + Windows 客户端 + Android 客户端**（界面仿 Tailchat）。

## 技术栈
- 服务端：Node.js 22 + Express 5 + WebSocket(`ws`) + SQLite(`node:sqlite`) + JWT
- 管理后台：Vue 3 + Element Plus（由服务端静态托管 `/admin`）
- 客户端：Flutter 3（一套代码出 Windows 桌面 + Android）
- 部署：Docker + 飞牛 fpk（ARM64 / x86）

## 目录
```
xiaozhi-im/
├── SPEC.md            # 需求与架构规格（必读）
├── server/            # Node 后端 + 管理后台托管
│   ├── src/           # 入口 / db / auth / ws / chat / routes
│   ├── public/        # 已构建的 Vue 管理后台（npm run build 生成）
│   └── data/          # 运行时：SQLite + 上传文件（git 忽略）
├── admin/             # Vue3 管理后台源码（Vite）
├── client/            # Flutter 客户端（Win + Android）
└── deploy/            # Dockerfile / compose / 飞牛 fpk 打包
```

## 本地开发（验证后端）
```bash
cd server
npm install
PORT=3602 JWT_SECRET=testsecret node src/index.js
# 管理后台: http://localhost:3602/admin   (默认 admin / admin123)
# 冒烟测试: node smoketest.js
```

## 功能进度（MVP）
- [x] 注册/登录、好友、单聊、群聊、文字/图片/文件、WebSocket 实时消息
- [x] 服务端可视化管理后台（用户/群组/统计）
- [x] 飞牛 fpk + Docker 部署包结构
- [ ] 客户端需在装有 Flutter SDK 的机器上 `flutter pub get` 后构建（本机未装 Flutter，仅出代码）
- [ ] 后续：语音/视频、E2EE、机器人/Webhook、话题线程、联邦、Mac/iOS

## 借鉴点（功能层面）
- Tailchat：左侧会话栏 + 消息区布局、插件化思路
- Matrix：事件溯源式消息、联邦互通（规划）
- Rocket.Chat：客服/加密思路（规划）
- Mattermost：与 OA/ERP 的 Webhook 集成（规划）
- Zulip：群聊话题线程（规划）
