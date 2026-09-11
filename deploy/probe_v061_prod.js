// v0.6.1 生产实例探测：ICE 配置下发 + WS 应用层心跳
//
// 用法: node deploy/probe_v061_prod.js [baseUrl]
//
// 刻意只做**只读**检查，不建通话、不写库 —— 生产实例上有真实账号和聊天记录，
// 探测脚本不该留下痕迹。掉线宽限 / 重连补推来电那两条链路有副作用，
// 由 server/test/reconnect_e2e.js 在隔离实例上覆盖（18 项全绿）。
const http = require('http');
const https = require('https');
const path = require('path');
const WebSocket = require(path.join(__dirname, '..', 'server', 'node_modules', 'ws'));

const BASE = process.argv[2] || 'http://192.168.31.44:3602';
const WSURL = BASE.replace(/^http/, 'ws') + '/ws';

let pass = 0, fail = 0;
function ok(name, cond, extra) {
  if (cond) { pass++; console.log('  \u2713 ' + name); }
  else { fail++; console.log(`  \u2717 ${name}${extra ? '  → ' + extra : ''}`); }
}

function post(pathname, body) {
  return new Promise((resolve) => {
    const mod = BASE.startsWith('https') ? https : http;
    const payload = JSON.stringify(body || {});
    const u = new URL(BASE + pathname);
    const req = mod.request({
      hostname: u.hostname,
      port: u.port || (BASE.startsWith('https') ? 443 : 80),
      path: u.pathname,
      method: 'POST',
      timeout: 10000,
      headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(payload) },
    }, (res) => {
      let b = '';
      res.on('data', (c) => (b += c));
      res.on('end', () => {
        let j = null;
        try { j = JSON.parse(b); } catch { /* 非 JSON */ }
        resolve({ status: res.statusCode, body: j, raw: b });
      });
    });
    req.on('error', (e) => resolve({ status: 0, error: e.message }));
    req.on('timeout', () => { req.destroy(); resolve({ status: 0, error: 'timeout' }); });
    req.write(payload);
    req.end();
  });
}

function get(pathname) {
  return new Promise((resolve) => {
    const mod = BASE.startsWith('https') ? https : http;
    const req = mod.get(BASE + pathname, { timeout: 10000 }, (res) => {
      let b = '';
      res.on('data', (c) => (b += c));
      res.on('end', () => {
        let j = null;
        try { j = JSON.parse(b); } catch { /* 非 JSON */ }
        resolve({ status: res.statusCode, body: j, raw: b });
      });
    });
    req.on('error', (e) => resolve({ status: 0, error: e.message }));
    req.on('timeout', () => { req.destroy(); resolve({ status: 0, error: 'timeout' }); });
  });
}

async function main() {
  console.log('='.repeat(56));
  console.log('  v0.6.1 生产探测（只读）  ' + BASE);
  console.log('='.repeat(56));

  // ---- ① ICE 配置下发 ----
  console.log('\n[1] ICE 配置下发接口 GET /api/call/ice');
  const r = await get('/api/call/ice');
  ok('接口返回 200', r.status === 200, `status=${r.status} ${r.error || ''}`);
  const list = r.body && r.body.iceServers;
  ok('下发 iceServers 数组', Array.isArray(list) && list.length > 0, r.raw);
  ok('每项都带 urls', Array.isArray(list) && list.every((x) => x && x.urls),
    JSON.stringify(list));
  const flat = JSON.stringify(list || []);
  ok('不含已失效的 stun.qq.com', !flat.includes('stun.qq.com'), flat);
  ok('含新的国内 STUN', flat.includes('stun.miwifi.com'), flat);
  ok('带 turnConfigured 标志', r.body && typeof r.body.turnConfigured === 'boolean',
    `turnConfigured=${r.body && r.body.turnConfigured}`);
  console.log('    → TURN 中继:', r.body && r.body.turnConfigured
    ? '已下发（客户端会自动使用）'
    : '未下发（外网通话不通时先查这个）');

  // ---- ② WS 心跳 ----
  console.log('\n[2] WS 应用层心跳 ping / pong');
  const health = await get('/api/health');
  ok('服务健康检查', health.status === 200, JSON.stringify(health.body));

  // 心跳要带有效 token 才测得到：无 token 的连接会被服务端直接 4001 拒掉，
  // 那样只能验证"拒绝生效"，验证不了 pong。
  const USER = process.argv[3] || 'admin';
  const PASS = process.argv[4] || 'admin123';
  const login = await post('/api/auth/login', { username: USER, password: PASS });
  if (login.status !== 200 || !login.body || !login.body.token) {
    ok(`用 ${USER} 登录拿 token`, false, `status=${login.status} ${login.raw || login.error}`);
  } else {
    ok(`用 ${USER} 登录拿 token`, true);
    const token = login.body.token;
    await new Promise((resolve) => {
      const ws = new WebSocket(WSURL + '?token=' + encodeURIComponent(token));
      let done = false;
      const finish = (name, cond, extra) => {
        if (done) return;
        done = true;
        ok(name, cond, extra);
        try { ws.close(); } catch { /* ignore */ }
        resolve();
      };
      ws.on('open', () => {
        ws.send(JSON.stringify({ type: 'ping', ts: 20260911 }));
        setTimeout(() => finish('ping → pong', false, '4 秒内无应答'), 4000);
      });
      ws.on('message', (raw) => {
        let f = null;
        try { f = JSON.parse(raw.toString()); } catch { /* ignore */ }
        if (!f) return;
        if (f.type === 'pong') {
          finish('ping → pong（echo 原样带回）', f.echo === 20260911, JSON.stringify(f));
        } else if (f.type === 'error') {
          finish('ping → pong', false, `服务端回 error：${f.message}`);
        }
      });
      ws.on('error', () => finish('WS 连接', false, '握手失败'));
      ws.on('close', (code) => finish('ping → pong', false, `连接被关闭 code=${code}`));
    });
  }

  // ---- ③ 未授权连接必须被拒 ----
  console.log('\n[3] 未授权连接必须被拒绝');
  await new Promise((resolve) => {
    const ws = new WebSocket(WSURL + '?token=probe-invalid-token');
    let done = false;
    const finish = (name, cond, extra) => {
      if (done) return;
      done = true;
      ok(name, cond, extra);
      try { ws.close(); } catch { /* ignore */ }
      resolve();
    };
    ws.on('open', () => {
      // 服务端应该在鉴权失败时立刻关闭，而不是让它挂在那里
      setTimeout(() => finish('无效 token 未被拒绝', false, '3 秒内连接仍然存活'), 3000);
    });
    ws.on('close', (code) => finish('无效 token 被拒绝（code 4001）', code === 4001, `code=${code}`));
    ws.on('error', () => finish('无效 token 被拒绝', true));
  });

  console.log('\n' + '='.repeat(56));
  console.log(`通过 ${pass} 项，失败 ${fail} 项`);
  console.log('='.repeat(56));
  return fail === 0 ? 0 : 1;
}

main().then((c) => process.exit(c)).catch((e) => {
  console.error('探测异常:', e);
  process.exit(1);
});
