const express = require('express');
const cors = require('cors');
const http = require('http');
const path = require('path');
const config = require('./config');
require('./db'); // 确保表结构与种子初始化
const { init: initWs } = require('./ws');
const dispatcher = require('./dispatcher');

const app = express();
app.use(cors());
// 保留原始请求体：入站 Webhook 的 HMAC 签名必须对「原始字节」计算，
// 重新 JSON.stringify 会因键序/空格差异导致签名对不上。
app.use(express.json({
  limit: '2mb',
  verify: (req, res, buf) => { req.rawBody = buf; },
}));

// 静态资源：管理后台 + 上传文件
app.use('/admin', express.static(path.join(__dirname, '..', 'public')));
app.use('/files', express.static(config.FILES_DIR));

// API 路由
app.use('/api/auth', require('./routes/auth'));
app.use('/api/users', require('./routes/users'));
app.use('/api/friends', require('./routes/friends'));
app.use('/api/groups', require('./routes/groups'));
app.use('/api/conversations', require('./routes/messages'));
app.use('/api/favorites', require('./routes/favorites'));
app.use('/api/files', require('./routes/files'));
// 通话运行参数下发（ICE/STUN/TURN），客户端建 RTCPeerConnection 前拉取
app.use('/api/call', require('./routes/call'));
// 集成管理必须挂在 /api/admin 之前，否则会被管理路由先接管
app.use('/api/admin/integrations', require('./routes/integrations'));
app.use('/api/admin', require('./routes/admin'));
// 对外开放：程序用令牌调用的运行时接口 + 免登录入站 Webhook
app.use('/api/open', require('./routes/open'));
app.use('/api/hooks', require('./routes/hooks'));

app.get('/api/health', (req, res) => res.json({ ok: true, ts: Date.now() }));
app.use((req, res) => res.status(404).json({ error: 'not found' }));

const server = http.createServer(app);
initWs(server);
// 出站 Webhook 失败重试巡检
dispatcher.start();

server.listen(config.PORT, () => {
  console.log(`[小智IM] 服务端已启动: http://localhost:${config.PORT}`);
  console.log(`[小智IM] 管理后台:    http://localhost:${config.PORT}/admin`);
  console.log(`[小智IM] WebSocket:   ws://localhost:${config.PORT}/ws`);
  console.log(`[小智IM] 开放接口:    http://localhost:${config.PORT}/api/open  /api/hooks/incoming/<token>`);
});
