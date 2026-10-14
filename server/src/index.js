const express = require('express');
const cors = require('cors');
const http = require('http');
const path = require('path');
const config = require('./config');
require('./db'); // 确保表结构与种子初始化
const { init: initWs } = require('./ws');
const dispatcher = require('./dispatcher');
const license = require('./license');
const filelog = require('./filelog');

// Windows 服务模式没有控制台，stdout 会进黑洞 —— 注册服务时会在环境里设
// XZ_LOG_FILE，这里发现就镜像一份日志到文件。没设（前台/后台启动）则零影响。
const filelogResult = filelog.init(process.env.XZ_LOG_FILE);
if (filelogResult.enabled) {
  console.log(`[小智IM] 文件日志已启用：${filelogResult.file}`);
} else if (filelogResult.reason) {
  console.warn(`[小智IM] 文件日志启用失败（不影响服务）：${filelogResult.reason}`);
}

const app = express();

// ---------------------------------------------------------------------------
// 安全头（2026-10-03 补，审计 P2）
//
// 为什么不全套 helmet：这里的服务形态是「内网 IM + 管理台静态页」，
// 不对外提供 HTML 文档渲染，helmet 默认那套 CSP（禁 inline script）会
// **把管理台自己的构建产物打死**（Vite 打包出来的 js/css 走的就是内联/外链混合）。
// 所以这里只开确实有意义、且不会误伤的那几项，逐条说明理由：
//
//   · nosniff            —— 挡住「把 .txt 猜成 js 执行」这类老把戏
//   · frame-ancestors     —— 防点击劫持。X-Frame-Options 已被现代浏览器忽略，
//                           所以用 CSP 的 frame-ancestors（同时给老浏览器补 XFO）
//   · referrer-policy    —— 管理台里的地址不该出现在别站 Referer 里
//   · x-content-type     —— 呼应 nosniff，明确"我发的就是这类型"
//   · HSTS               —— ⚠️ **仅在 HTTPS 下加**。这是内网/局域网部署，
//                           绝大多数是 http，乱加 HSTS 会让浏览器把 http 永久
//                           升级到 https —— 在没有 https 的部署里直接把网站搞坏。
//                           所以按请求是否 https 来决定，代理后面也认 X-Forwarded-Proto。
//   · 隐藏 x-powered-by   —— Express 默认会暴露框架名，纯信息泄露
//
// ⚠️ 关于 CORS：见下面 cors(...) 的注释。
// ---------------------------------------------------------------------------
app.disable('x-powered-by');

app.use((req, res, next) => {
  res.set('X-Content-Type-Options', 'nosniff');
  res.set('X-Frame-Options', 'SAMEORIGIN');
  res.set('Content-Security-Policy', "frame-ancestors 'self'");
  res.set('Referrer-Policy', 'strict-origin-when-cross-origin');
  const proto = String(req.headers['x-forwarded-proto'] || '').split(',')[0].trim()
    || (req.socket.encrypted ? 'https' : 'http');
  if (proto === 'https') {
    res.set('Strict-Transport-Security', 'max-age=15552000; includeSubDomains');
  }
  next();
});

// CORS 显式来源（2026-10-03 补，审计 P2）
//
// 🔴 原来这里是裸 `app.use(cors())` —— **等于允许任意来源**。
//    配合"令牌存在客户端本地"这一点，风险在于：用户在小智IM 管理台登录后，
//    访问的任意第三方网页都能用 fetch 带 cookie/头去打这台服务器的管理接口。
//    （虽然 Bearer 令牌不在 Cookie 里、跨站读不到 localStorage，实际可利用性有限，
//      但"生产环境任意源"这件事本身就该收紧。）
//
// 怎么收紧而不弄坏功能 —— 需要分清谁真的需要跨域：
//   · **管理台**：和 API 同源（都走 :3602），**不需要 CORS**。
//   · **Flutter 客户端**：原生 HTTP（dart:io），**不受 CORS 约束**（那是浏览器的东西）。
//   · **管理台 Vite 开发服务器**（本地改前端时）：`npm run dev` 在 5173 端口，
//     确实需要跨域 → 走下面的白名单。
//   · **飞牛/frp/Cloudflare 隧道**：同源，不需要。
// 所以白名单默认只放行开发端口，够用且不放开给任何陌生网站。
//
// 想再加来源用环境变量（逗号分隔）：CORS_ORIGINS=https://a.com,https://b.com
const DEV_ORIGINS = ['http://localhost:5173', 'http://127.0.0.1:5173'];
const EXTRA_ORIGINS = String(process.env.CORS_ORIGINS || '')
  .split(',').map((s) => s.trim()).filter(Boolean);
const ALLOWED_ORIGINS = new Set([...DEV_ORIGINS, ...EXTRA_ORIGINS]);

app.use(cors({
  // 白名单制：不在名单里就**不返回** Access-Control-Allow-Origin，
  // 浏览器的同源策略自然会把响应拦掉。
  // ⚠️ 刻意不用 origin: true（那等于"反射任意来源"，和不设一样）。
  origin(origin, cb) {
    // 没有 Origin 头的 = 同源请求、curl、服务端调用、WebSocket 握手 → 直接放行
    if (!origin) return cb(null, true);
    if (ALLOWED_ORIGINS.has(origin)) return cb(null, true);
    cb(null, false);
  },
  credentials: false, // 本项目令牌在 Authorization 头里，不依赖 Cookie
}));

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

// 应用停用门禁（「应用中心 → 管理 → 停用」的后端那一半）。
// 🔴 必须排在所有业务路由之前，而且**用 app.use(fn) 不挂前缀** ——
//    这样 req.path 就是浏览器里看到的那条完整路径（含 /api），
//    注册表里写的路径跟接口对照不用脑内转换。
app.use(require('./appguard').middleware);

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
// 数据体检（孤儿巡检）：全库 0 外键，靠触发器只挡住了"新的脏数据"，
// 历史上遗留的孤儿行要靠这个页体检 + 清理。挂 /api/admin 之前（路径更长者优先）。
app.use('/api/admin/orphans', require('./routes/orphans'));
// 部署向导：换云服务器一键部署（frps/TURN/隧道）。挂 /api/admin 之前（路径更长）。
app.use('/api/admin/deploy', require('./routes/deploy_wizard'));
// 智能助手（#314）：员工问答 + 管理端配置。管理前缀更长，挂 /api/admin 之前。
app.use('/api/admin/assistant', require('./routes/assistant').admin);
app.use('/api/assistant', require('./routes/assistant'));
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
// 通用审批中心：待审 / 通过 / 驳回（驳回理由必填）。
// 盘点单审批走它（kind=stocktake, ref=sheet_no），后面别的业务直接挂上来。
app.use('/api/approval', require('./routes/approval'));
// 培训中心：课程 / 章节 / 课时（看视频记进度）/ 章节考试（判分留档）。
// 客户端工作台入口 id 与显示名都是「培训中心」。
app.use('/api/training', require('./routes/training'));
// 库房减货单：员工上传 / 管理台列表·明细·对账。
// 与盘点共用 inv_sheets + inv_scans，靠 sheet_type='deduct' 区分
// （盘点走 /api/stocktake，减货走这里，两边互不干扰）。
app.use('/api/deduct', require('./routes/deduct'));

// 健康检查：进程活着就算活。
//   /health 给「进程是否在跑」用 —— 容器编排、飞牛的界面探活都看它，
//   所以它必须**不能依赖数据库**，否则数据库一坏就会把进程也判死、触发重启风暴。
app.get('/api/health', (req, res) => res.json({ ok: true, ts: Date.now() }));

// 就绪检查：能不能**真的干活**。
//   差别在 /ready 会碰一下数据库。数据库打不开时返回 503，
//   让负载均衡/编排知道"别往我这发流量"，但进程本身不必重启。
//   这对"容器起来了但库还没准备好"那种启动竞态很有用（SQLite 首次迁移时确实有窗口）。
app.get('/api/ready', (req, res) => {
  try {
    // 真正查一次：SELECT 1 不会走索引但会打开文件、验证页可读，
    // 库损坏/文件权限不对/磁盘挂掉都会在这里暴露出来。
    require('./db').prepare('SELECT COUNT(*) c FROM users').get();
    res.json({ ok: true, db: 'ready', ts: Date.now() });
  } catch (e) {
    res.status(503).json({ ok: false, db: 'unavailable', error: e.message, ts: Date.now() });
  }
});

app.use((req, res) => res.status(404).json({ error: 'not found' }));

const server = http.createServer(app);
const wss = initWs(server);
// 局域网发现服务（UDP 广播应答，客户端首装自动找到服务器）
require('./discover').start();
// 出站 Webhook 失败重试巡检
dispatcher.start();
// 推送：每天清一次老日志；已配置时开机打一行自检结果
require('./push').start();
// refresh token 表清理：过期行没有任何用处，留着只会让表慢慢变大。
// 每天一次即可（有效期 30 天，精度要求很低）。
// 用 unref 让这个定时器**不阻止进程退出** —— 否则优雅停机时会卡在这儿等它。
setInterval(() => require('./tokens').sweep(), 24 * 3600 * 1000).unref();

server.listen(config.PORT, () => {
  console.log(`[小智IM] 服务端已启动: http://localhost:${config.PORT}`);
  console.log(`[小智IM] 管理后台:    http://localhost:${config.PORT}/admin`);
  console.log(`[小智IM] WebSocket:   ws://localhost:${config.PORT}/ws`);
  console.log(`[小智IM] 开放接口:    http://localhost:${config.PORT}/api/open  /api/hooks/incoming/<token>`);
  // 打印机器码与剩余天数，并起「授权失效即断开在线连接」的巡检
  license.init();
});

// ---------------------------------------------------------------------------
// 优雅停机（2026-10-03 补，审计 P1-5）
//
// 🔴 为什么必须加
//   `docker compose restart xiaozhi-im` 发的是 **SIGTERM**，不是 SIGKILL。
//   以前没接 SIGTERM，Node 的默认行为是**直接退出进程**。于是每次重启/发版都会：
//     · 正在处理中的请求被砍断（客户端收到 ECONNRESET，不是 502/超时）；
//     · WebSocket 连接被硬断，客户端要等重连超时才发现断线（表现为"消息发不出去"）；
//     · **SQLite 的 WAL 没做 checkpoint** —— 已提交的数据还在 -wal 文件里，
//       极端情况下（下一次又是硬杀）可能丢最后几笔写入。
//   换句话说，"重启一下服务"这个最平常的操作，本身就是一个数据风险点。
//
// 停机顺序是有讲究的，不能反：
//   ① 停收新连接（server.close）—— 先把入口关上，别再接新请求进来；
//   ② 关 WebSocket —— 让客户端**立刻**知道该重连，而不是等 TCP 超时；
//   ③ 等存量请求做完（给一个上限）—— 不硬砍正在写库的请求；
//   ④ 关数据库（close 会顺带 checkpoint WAL）—— 最后一步，确保数据落盘；
//   ⑤ 兜底强杀 —— 上面的等待有上限，卡住也不能让容器永远停不下来
//     （docker stop 超时后会 SIGKILL，那时再做一次也没意义了）。
//
// 为什么要在 shutdown 里 db.close()：node:sqlite 的 DatabaseSync 有 close()，
// 它会把 WAL 落盘并合并。进程被硬杀时这一步不会执行，恰恰就是丢数据的原因。
// ---------------------------------------------------------------------------
let shuttingDown = false;
function shutdown(signal) {
  if (shuttingDown) return; // Docker 重启时会连发信号，重复执行会二次 close 抛错
  shuttingDown = true;
  const hard = setTimeout(() => {
    console.error('[小智IM] 优雅停机超时，强制退出');
    process.exit(1);
  }, 10000);
  hard.unref();

  console.log(`[小智IM] 收到 ${signal}，开始优雅停机…`);

  // ① 停收新 HTTP 连接
  server.close(() => {
    // server.close 的回调 = 所有存量请求都处理完了，走到这说明 ③ 完成
    console.log('[小智IM] HTTP 连接已收干');
  });

  // ② 通知并关闭 WS（close 会触发各连接的 close 事件，客户端能立刻重连）
  try {
    for (const ws of wss.clients) {
      try { ws.close(1001, 'server shutting down'); } catch (_) { /* 已经断了 */ }
    }
    wss.close();
  } catch (e) {
    console.warn('[小智IM] 关闭 WebSocket 出错（不影响停机）:', e.message);
  }

  // ③④ 给存量请求一点时间，然后关库；server.getConnections 用来判断是否真的收干了
  setTimeout(() => {
    server.getConnections((err, n) => {
      if (err) console.warn('[小智IM] 统计连接数失败:', err.message);
      else if (n > 0) console.warn(`[小智IM] 仍有 ${n} 个连接未结束，继续等`);
    });
    try {
      // db.js 直接导出 DatabaseSync 实例，close() 会把 WAL checkpoint 落盘
      require('./db').close();
      console.log('[小智IM] 数据库已关闭（WAL 已落盘）');
    } catch (e) {
      console.warn('[小智IM] 关闭数据库出错:', e.message);
    }
    clearTimeout(hard);
    console.log('[小智IM] 已退出');
    process.exit(0);
  }, 2000);
}

process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));
