const express = require('express');
const cors = require('cors');
const http = require('http');
const path = require('path');
const config = require('./config');
require('./db'); // 确保表结构与种子初始化
const { init: initWs } = require('./ws');

const app = express();
app.use(cors());
app.use(express.json());

// 静态资源：管理后台 + 上传文件
app.use('/admin', express.static(path.join(__dirname, '..', 'public')));
app.use('/files', express.static(config.FILES_DIR));

// API 路由
app.use('/api/auth', require('./routes/auth'));
app.use('/api/users', require('./routes/users'));
app.use('/api/friends', require('./routes/friends'));
app.use('/api/groups', require('./routes/groups'));
app.use('/api/conversations', require('./routes/messages'));
app.use('/api/files', require('./routes/files'));
app.use('/api/admin', require('./routes/admin'));

app.get('/api/health', (req, res) => res.json({ ok: true, ts: Date.now() }));
app.use((req, res) => res.status(404).json({ error: 'not found' }));

const server = http.createServer(app);
initWs(server);

server.listen(config.PORT, () => {
  console.log(`[小智IM] 服务端已启动: http://localhost:${config.PORT}`);
  console.log(`[小智IM] 管理后台:    http://localhost:${config.PORT}/admin`);
  console.log(`[小智IM] WebSocket:   ws://localhost:${config.PORT}/ws`);
});
