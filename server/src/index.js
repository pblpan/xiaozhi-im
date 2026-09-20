const express = require('express');
const cors = require('cors');
const http = require('http');
const path = require('path');
const config = require('./config');
require('./db'); // 确保表结构与种子初始化
const { init: initWs } = require('./ws');
const dispatcher = require('./dispatcher');
const license = require('./license');

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

// 授权门禁：必须排在所有业务接口之前。
// 授权不可用时一律 403，只放行登录、看状态、激活、健康检查与客户端冷启动握手
// （放行名单见 license.js 的 ALLOW）—— 让管理员能进来看见"为什么用不了"。
app.use('/api', license.gate);

// 授权状态与激活：免鉴权可看状态，激活需管理员
app.use('/api/license', require('./routes/license'));

// 首次运行初始化（管理台设置密码向导）：必须在登录之前就能用，
// 所以既免鉴权、也在 license 放行名单里（未授权/过期的机器同样要能设密码进门）。
app.use('/api/setup', require('./routes/setup'));

// API 路由
app.use('/api/auth', require('./routes/auth'));
app.use('/api/users', require('./routes/users'));
app.use('/api/friends', require('./routes/friends'));
// 组织机构（工作模式）：工号即账号，同事自动互为好友
app.use('/api/orgs', require('./routes/orgs'));
app.use('/api/groups', require('./routes/groups'));
app.use('/api/conversations', require('./routes/messages'));
app.use('/api/favorites', require('./routes/favorites'));
app.use('/api/files', require('./routes/files'));
// 通话运行参数下发（ICE/STUN/TURN），客户端建 RTCPeerConnection 前拉取
app.use('/api/call', require('./routes/call'));
// 远程协助：只管访问码与会话审计，画面/键鼠全走 P2P，不过服务端
app.use('/api/remote', require('./routes/remote'));
// 客户端配置中心（bootstrap 免鉴权，必须在 /api/admin 之前注册无影响，独立前缀）
app.use('/api/client', require('./routes/client'));
// 集成管理必须挂在 /api/admin 之前，否则会被管理路由先接管
app.use('/api/admin/integrations', require('./routes/integrations'));
// 考勤管理端同理：路径前缀更长，必须排在 /api/admin 前面
app.use('/api/admin/attendance', require('./routes/attendance').admin);
// 推送管理端同理（配置 Apple 密钥 / 发测试推送 / 看投递日志）
app.use('/api/admin/push', require('./routes/push').admin);
app.use('/api/admin', require('./routes/admin'));
// 考勤（工作模式下随工作模式启用）：员工端打卡/我的考勤/申请
app.use('/api/attendance', require('./routes/attendance'));
// 推送设备登记（iOS）：客户端拿到 APNs 令牌后上报，退出登录时注销
app.use('/api/push', require('./routes/push'));
// 对外开放：程序用令牌调用的运行时接口 + 免登录入站 Webhook
app.use('/api/open', require('./routes/open'));
app.use('/api/hooks', require('./routes/hooks'));
// 盘点（inventory 模块）：点位 / 库位货架位 / 单据 / 三遍制明细上传。
// ⚠️ 路径里的 stocktake 指「盘点」，不是客户端那个 id 也叫 stocktake 的「扫码枪」。
app.use('/api/stocktake', require('./routes/inventory'));
// 商品 ↔ 货架位：查商品在哪个货架位 / 属于哪个盘点位，以及绑定解绑
app.use('/api/location', require('./routes/inventory').location);
// 商品档案（商档）：盘点算差异要的账面数存在这里，手机一键拉，
// 不再依赖会关机、IP 会漂的泰格上游桥接。
app.use('/api/master', require('./routes/master'));

app.get('/api/health', (req, res) => res.json({ ok: true, ts: Date.now() }));
app.use((req, res) => res.status(404).json({ error: 'not found' }));

const server = http.createServer(app);
initWs(server);
// 局域网发现服务（UDP 广播应答，客户端首装自动找到服务器）
require('./discover').start();
// 出站 Webhook 失败重试巡检
dispatcher.start();
// 推送：每天清一次老日志；已配置时开机打一行自检结果
require('./push').start();

server.listen(config.PORT, () => {
  console.log(`[小智IM] 服务端已启动: http://localhost:${config.PORT}`);
  console.log(`[小智IM] 管理后台:    http://localhost:${config.PORT}/admin`);
  console.log(`[小智IM] WebSocket:   ws://localhost:${config.PORT}/ws`);
  console.log(`[小智IM] 开放接口:    http://localhost:${config.PORT}/api/open  /api/hooks/incoming/<token>`);
  // 打印机器码与剩余天数，并起「授权失效即断开在线连接」的巡检
  license.init();
});
