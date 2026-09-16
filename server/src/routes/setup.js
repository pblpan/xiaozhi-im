/**
 * 首次运行初始化路由 —— 挂在 /api/setup，**免鉴权**（挂载见 src/index.js）
 *
 * 两个接口：
 *   GET  /api/setup/status   管理台打开时问一句"要不要走向导"
 *   POST /api/setup/init     设置管理台密码，成功即返回登录凭证（省得再登一次）
 *
 * 免鉴权是必须的：向导要在**登录之前**跑，否则又回到"得先知道密码才能改密码"。
 * 代价是这台服务器在"装好但还没设密码"的窗口期里，谁能访问谁就能把密码定下来
 * （Nextcloud / Grafana 这类自建系统的首次安装页都是这个性质）。所以这里做三件事
 * 把窗口压到最小、并且留痕：
 *   · 一旦设置成功，needSetup 立刻变 false，接口随即 409，窗口永久关闭；
 *   · 按来源 IP 限流，挡掉脚本刷；
 *   · 成功这件事写进服务端日志（谁、什么时候、从哪来）。
 * 部署文档里的口径也要跟上：**先设密码，再对外开端口。**
 */
const router = require('express').Router();
const config = require('../config');
const setup = require('../setup');
const { signToken } = require('../auth');

const WINDOW_MS = 10 * 60 * 1000;
const MAX_TRIES = 20;
const tries = new Map(); // ip -> 时间戳数组

/**
 * 取来源 IP。
 * 信任 X-Forwarded-For 是**刻意**的：小智IM 常挂在 Cloudflare Tunnel / frp 后面，
 * 那时 req.socket.remoteAddress 是隧道进程自己（永远 127.0.0.1），限流会把所有
 * 人算成同一个人。代价是能伪造 XFF 绕限流 —— 但这里防的是"脚本刷"，不是精确审计；
 * 真正拦住攻击面的是"设完就关"。
 */
function ipOf(req) {
  const xff = req.headers['x-forwarded-for'];
  const first = String(xff || '').split(',')[0].trim();
  return first || req.socket.remoteAddress || '?';
}

function rateLimited(ip) {
  const now = Date.now();
  const list = (tries.get(ip) || []).filter((t) => now - t < WINDOW_MS);
  list.push(now);
  tries.set(ip, list);
  // 顺手清掉过期条目，免得这张表跟着 IP 数量无限长（服务端可能常年不重启）
  if (tries.size > 512) {
    for (const [k, v] of tries) {
      if (!v.some((t) => now - t < WINDOW_MS)) tries.delete(k);
    }
  }
  return list.length > MAX_TRIES;
}

router.get('/status', (req, res) => {
  res.json({
    needSetup: setup.needSetup(),
    username: config.ADMIN_USERNAME,
    minLength: setup.PW_MIN,
    maxLength: setup.PW_MAX,
  });
});

router.post('/init', (req, res) => {
  const ip = ipOf(req);
  if (rateLimited(ip)) {
    return res.status(429).json({ error: '尝试过于频繁，请过几分钟再试' });
  }
  // 先判后写，中间没有 await：不存在"两个请求同时通过判定"的窗口
  if (!setup.needSetup()) {
    return res.status(409).json({ error: '本服务器已经初始化过了，请直接登录', code: 'ALREADY_INITIALIZED' });
  }
  const c = setup.cleanPassword(req.body?.password);
  if (c.error) return res.status(400).json({ error: c.error });

  const r = setup.runSetup(c.value, ip);
  if (r.error) return res.status(500).json({ error: r.error });

  res.json({
    ok: true,
    // 直接给凭证：他刚设完密码，再让他输一遍没有意义
    token: signToken({ uid: r.uid, role: 'admin' }),
    username: config.ADMIN_USERNAME,
  });
});

module.exports = router;
