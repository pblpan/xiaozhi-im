// 实例级设置（公司名 / 好友模式）+ bootstrap 下发 —— 端到端测试
//
//   node test/settings_e2e.js
//
// 起隔离实例，覆盖：默认值、脏输入拦截、越权、免鉴权下发、显示名拼接约定。

const { spawn } = require('child_process');
const WebSocket = require('ws');
const path = require('path');
const fs = require('fs');
const os = require('os');

const PORT = 3699;
const BASE = `http://127.0.0.1:${PORT}`;
const SERVER_DIR = path.resolve(__dirname, '..');
const DATA_DIR = path.join(os.tmpdir(), 'xiaozhi-settings-e2e-' + Date.now());

let passed = 0;
let failed = 0;
const failures = [];

function ok(name, cond, extra) {
  if (cond) { passed++; console.log(`  \u2713 ${name}`); }
  else {
    failed++;
    failures.push(name + (extra ? ` — ${extra}` : ''));
    console.log(`  \u2717 ${name}${extra ? '  → ' + extra : ''}`);
  }
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function api(method, p, { token, body } = {}) {
  const res = await fetch(BASE + p, {
    method,
    headers: {
      'Content-Type': 'application/json',
      ...(token ? { Authorization: 'Bearer ' + token } : {}),
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  let json = null;
  try { json = await res.json(); } catch { /* 空响应 */ }
  return { status: res.status, body: json };
}

let serverProc = null;
let serverLog = '';

async function startServer() {
  serverProc = spawn(process.execPath, [path.join(SERVER_DIR, 'src', 'index.js')], {
    env: { ...process.env, PORT: String(PORT), DATA_DIR, ADMIN_PASSWORD: 'TestAdmin_123' },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  serverProc.stdout.on('data', (d) => { serverLog += d.toString(); });
  serverProc.stderr.on('data', (d) => { serverLog += d.toString(); });
  for (let i = 0; i < 60; i++) {
    try {
      const r = await fetch(BASE + '/api/health');
      if (r.ok) return;
    } catch { /* 还没起来 */ }
    await sleep(250);
  }
  throw new Error('服务端启动超时\n' + serverLog);
}

function killServer() {
  if (serverProc) { try { serverProc.kill(); } catch { /* ignore */ } }
}

function stopServer() {
  killServer();
  try { fs.rmSync(DATA_DIR, { recursive: true, force: true }); } catch { /* ignore */ }
}

(async () => {
  await startServer();
  console.log('[settings E2E] 服务端已就绪 ' + BASE + '\n');

  // ---------------- 管理员登录 ----------------
  let r = await api('POST', '/api/auth/login', { body: { username: 'admin', password: 'TestAdmin_123' } });
  const admin = r.body?.token;
  ok('管理员登录', !!admin, JSON.stringify(r.body));

  // 普通用户
  r = await api('POST', '/api/auth/register', { body: { username: 'alice', password: 'pw123456', nickname: 'alice' } });
  const alice = r.body?.token;
  ok('注册普通用户', !!alice, JSON.stringify(r.body));

  // ---------------- 默认值 ----------------
  console.log('\n【一】默认值');
  r = await api('GET', '/api/admin/settings', { token: admin });
  ok('未设置时公司名为空', r.status === 200 && r.body.companyName === '', JSON.stringify(r.body));
  ok('未设置时模式为 normal', r.body.friendMode === 'normal', JSON.stringify(r.body));

  r = await api('GET', '/api/client/bootstrap');
  ok('bootstrap 免鉴权可取（默认值）',
    r.status === 200 && r.body.companyName === '' && r.body.friendMode === 'normal',
    JSON.stringify(r.body));

  // ---------------- 公司名校验 ----------------
  console.log('\n【二】公司名');
  r = await api('PUT', '/api/admin/settings', { token: admin, body: { companyName: '盛京' } });
  ok('设置公司名', r.status === 200 && r.body.companyName === '盛京', JSON.stringify(r.body));

  r = await api('GET', '/api/client/bootstrap');
  ok('bootstrap 下发公司名（未登录可取）', r.body.companyName === '盛京', JSON.stringify(r.body.companyName));

  r = await api('PUT', '/api/admin/settings', { token: admin, body: { companyName: '小智' } });
  ok('公司名不该包含"小智"后缀？——不，允许，显示层自行拼接', r.status === 200, JSON.stringify(r.body));
  r = await api('PUT', '/api/admin/settings', { token: admin, body: { companyName: '盛' } });
  ok('单字公司名被拒（2 字起）', r.status === 400, JSON.stringify(r.body));
  r = await api('PUT', '/api/admin/settings', { token: admin, body: { companyName: 'x'.repeat(21) } });
  ok('超长公司名被拒（20 字上限）', r.status === 400, JSON.stringify(r.body));
  r = await api('PUT', '/api/admin/settings', { token: admin, body: { companyName: '盛<京>' } });
  ok('含特殊字符被拒', r.status === 400, JSON.stringify(r.body));
  r = await api('PUT', '/api/admin/settings', { token: admin, body: { companyName: '  盛京  ' } });
  ok('首尾空格被清洗', r.status === 200 && r.body.companyName === '盛京', JSON.stringify(r.body));
  r = await api('PUT', '/api/admin/settings', { token: admin, body: { companyName: '' } });
  ok('空串=清除公司名', r.status === 200 && r.body.companyName === '', JSON.stringify(r.body));
  r = await api('PUT', '/api/admin/settings', { token: admin, body: { companyName: '盛京' } });
  ok('恢复公司名（后续用）', r.status === 200, JSON.stringify(r.body));

  // ---------------- 好友模式 ----------------
  console.log('\n【三】好友模式');
  r = await api('PUT', '/api/admin/settings', { token: admin, body: { friendMode: 'work' } });
  ok('切到 work 模式', r.status === 200 && r.body.friendMode === 'work', JSON.stringify(r.body));
  r = await api('PUT', '/api/admin/settings', { token: admin, body: { friendMode: 'party' } });
  ok('非法模式被拒', r.status === 400, JSON.stringify(r.body));
  r = await api('PUT', '/api/admin/settings', { token: admin, body: { friendMode: 'normal' } });
  ok('切回 normal', r.status === 200, JSON.stringify(r.body));

  // ---------------- 越权与未知键 ----------------
  console.log('\n【四】越权与未知键');
  r = await api('PUT', '/api/admin/settings', { token: alice, body: { companyName: '黑掉的' } });
  ok('普通用户改设置 → 403', r.status === 403, JSON.stringify(r.body));
  r = await api('PUT', '/api/admin/settings', { body: { companyName: '匿名' } });
  ok('未登录改设置 → 401', r.status === 401, JSON.stringify(r.body));
  r = await api('PUT', '/api/admin/settings', { token: admin, body: { evilKey: 1 } });
  ok('未知设置项被拒', r.status === 400 && /不支持的设置项/.test(r.body.error || ''), JSON.stringify(r.body));
  r = await api('PUT', '/api/admin/settings', { token: admin, body: 'not an object' });
  ok('非对象 body 被拒', r.status === 400, JSON.stringify(r.body));

  // ---------------- 设置变更实时广播（WS） ----------------
  //
  // 为什么必须有这段：公司名/好友模式改完要**推给已开着的客户端**，否则用户
  // 看到的永远是"我在服务器上改了，客户端没改"。但光验"推到了"不够 ——
  // 反向还要验"设置被拒时不许推"（否则客户端会跟着一个非法值乱跳）和
  // "未登录连不上"（否则任何人都能挂着 WS 偷看服务端设置）。
  console.log('\n【五】设置变更实时广播');
  const frames = [];
  const ws = new WebSocket(`ws://127.0.0.1:${PORT}/ws?token=${encodeURIComponent(admin)}`);
  const wsErr = await new Promise((res) => {
    const t = setTimeout(() => res('timeout'), 5000);
    ws.on('open', () => { clearTimeout(t); res(null); });
    ws.on('error', (e) => { clearTimeout(t); res(e.message); });
  });
  ok('管理员 WS 连接成功', wsErr === null, String(wsErr));
  ws.on('message', (d) => {
    try { frames.push(JSON.parse(d.toString())); } catch { /* 非 JSON 帧忽略 */ }
  });
  await sleep(200); // 等 connected 帧

  r = await api('PUT', '/api/admin/settings', { token: admin, body: { companyName: '好又多' } });
  await sleep(300);
  let hits = frames.filter((f) => f.type === 'settings:changed');
  ok('改公司名 → 在线客户端收到 settings:changed', hits.length === 1, JSON.stringify(frames));
  ok('广播带新公司名', hits[0]?.companyName === '好又多', JSON.stringify(hits[0]));
  ok('广播带好友模式（客户端据此切导航）', hits[0]?.friendMode === 'normal', JSON.stringify(hits[0]));

  frames.length = 0;
  r = await api('PUT', '/api/admin/settings', { token: admin, body: { friendMode: 'work' } });
  await sleep(300);
  hits = frames.filter((f) => f.type === 'settings:changed');
  ok('改好友模式 → 同样推送', hits.length === 1 && hits[0].friendMode === 'work', JSON.stringify(frames));

  // 反向断言：400 时不许推。推了的话客户端会把一个非法值当真。
  frames.length = 0;
  r = await api('PUT', '/api/admin/settings', { token: admin, body: { companyName: 'x'.repeat(21) } });
  ok('非法公司名被拒（前置条件）', r.status === 400, JSON.stringify(r.body));
  await sleep(250);
  ok('设置被拒 → 不广播', frames.filter((f) => f.type === 'settings:changed').length === 0,
    JSON.stringify(frames));

  // 反向断言：没有 token 的连接根本连不上，收不到任何设置帧。
  const unauth = await new Promise((res) => {
    const w2 = new WebSocket(`ws://127.0.0.1:${PORT}/ws`);
    const t = setTimeout(() => res('timeout'), 3000);
    w2.on('close', (code) => { clearTimeout(t); res(code); });
    w2.on('error', () => { clearTimeout(t); res('error'); });
  });
  ok('未带 token 的 WS 被拒（4001）', unauth === 4001, String(unauth));

  ws.close();
  // 把状态放回【六】持久化期待的值（这段改过的都必须还原，否则下游断言被连坐）
  await api('PUT', '/api/admin/settings', { token: admin, body: { companyName: '盛京' } });
  await api('PUT', '/api/admin/settings', { token: admin, body: { friendMode: 'normal' } });

  // ---------------- 持久化（重启不丢） ----------------
  console.log('\n【六】持久化');
  r = await api('GET', '/api/admin/settings', { token: admin });
  ok('设置仍在（同进程内）', r.body.companyName === '盛京' && r.body.friendMode === 'normal', JSON.stringify(r.body));

  // ⚠️ 用 killServer 而不是 stopServer：后者会把 DATA_DIR 删掉，
  // "重启"就变成"换新库"，那条断言永远红 —— 第一版就是这么错的。
  killServer();
  await sleep(300);
  await startServer();
  r = await api('POST', '/api/auth/login', { body: { username: 'admin', password: 'TestAdmin_123' } });
  r = await api('GET', '/api/admin/settings', { token: r.body.token });
  ok('重启后设置不丢', r.status === 200 && r.body.companyName === '盛京' && r.body.friendMode === 'normal',
    JSON.stringify(r.body));

  // ---------------- 汇总 ----------------
  console.log('\n' + '='.repeat(52));
  console.log(`通过 ${passed} / ${passed + failed}`);
  if (failed) {
    console.log('\n失败项：');
    failures.forEach((f) => console.log('  ✗ ' + f));
  }
  console.log('='.repeat(52));
  stopServer();
  process.exit(failed ? 1 : 0);
})().catch((e) => {
  console.error('\n[E2E] 异常中断:', e);
  stopServer();
  process.exit(1);
});
