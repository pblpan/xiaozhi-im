// 修改密码 POST /api/auth/password —— 端到端测试
//
//   node test/password_e2e.js
//
// 起隔离实例，覆盖：鉴权、旧密码校验、新密码强度、改密成功后
// 新旧密码行为、旧 token 有效性（JWT 无状态 → 预期仍有效）、重启持久化。

const { spawn } = require('child_process');
const path = require('path');
const fs = require('fs');
const os = require('os');

const PORT = 3698;
const BASE = `http://127.0.0.1:${PORT}`;
const SERVER_DIR = path.resolve(__dirname, '..');
const DATA_DIR = path.join(os.tmpdir(), 'xiaozhi-password-e2e-' + Date.now());

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
    env: { ...process.env, PORT: String(PORT), DATA_DIR, ADMIN_PASSWORD: 'admin123' },
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
  console.log('[password E2E] 服务端已就绪 ' + BASE + '\n');

  const OLD_PW = 'old123456';
  const NEW_PW = 'new-pw-2026!';

  // 注册一个用户并登录
  let r = await api('POST', '/api/auth/register', { body: { username: 'user1', password: OLD_PW, nickname: 'u1' } });
  const u1 = r.body?.token;
  ok('注册用户 user1', !!u1, JSON.stringify(r.body));

  // ---------------- 鉴权与旧密码 ----------------
  console.log('\n【一】鉴权与旧密码');
  r = await api('POST', '/api/auth/password', { body: { oldPassword: OLD_PW, newPassword: NEW_PW } });
  ok('未登录改密 → 401', r.status === 401, JSON.stringify(r.body));

  r = await api('POST', '/api/auth/password', { token: u1, body: { oldPassword: 'wrong-pw', newPassword: NEW_PW } });
  ok('旧密码错误 → 401 且中文提示',
    r.status === 401 && r.body.error === '旧密码不正确', JSON.stringify(r.body));

  r = await api('POST', '/api/auth/password', { token: u1, body: { oldPassword: OLD_PW } });
  ok('缺新密码 → 400', r.status === 400, JSON.stringify(r.body));

  // ---------------- 新密码强度 ----------------
  console.log('\n【二】新密码强度');
  r = await api('POST', '/api/auth/password', { token: u1, body: { oldPassword: OLD_PW, newPassword: '12345' } });
  ok('5 位被拒', r.status === 400 && /至少 6 位/.test(r.body.error || ''), JSON.stringify(r.body));
  r = await api('POST', '/api/auth/password', { token: u1, body: { oldPassword: OLD_PW, newPassword: 'x'.repeat(65) } });
  ok('65 位被拒', r.status === 400 && /最长 64 位/.test(r.body.error || ''), JSON.stringify(r.body));
  r = await api('POST', '/api/auth/password', { token: u1, body: { oldPassword: OLD_PW, newPassword: OLD_PW } });
  ok('新密码与旧密码相同被拒', r.status === 400 && /相同/.test(r.body.error || ''), JSON.stringify(r.body));

  // ---------------- 成功改密 ----------------
  console.log('\n【三】成功改密');
  r = await api('POST', '/api/auth/password', { token: u1, body: { oldPassword: OLD_PW, newPassword: NEW_PW } });
  ok('改密成功返回 ok', r.status === 200 && r.body.ok === true, JSON.stringify(r.body));

  r = await api('POST', '/api/auth/login', { body: { username: 'user1', password: NEW_PW } });
  ok('新密码可登录', r.status === 200 && !!r.body.token, JSON.stringify(r.body));

  r = await api('POST', '/api/auth/login', { body: { username: 'user1', password: OLD_PW } });
  ok('旧密码登录被拒', r.status === 401, JSON.stringify(r.body));

  // JWT 无状态，本版本不做全局吊销：旧 token 在有效期内仍可用是有意行为
  r = await api('GET', '/api/auth/me', { token: u1 });
  ok('改密后旧 token 仍可用（JWT 无状态，有意行为）', r.status === 200, JSON.stringify(r.body));

  // 连续改密：用当前 token 再改一次
  const SECOND_PW = 'second-777';
  r = await api('POST', '/api/auth/password', { token: u1, body: { oldPassword: NEW_PW, newPassword: SECOND_PW } });
  ok('连续第二次改密成功', r.status === 200 && r.body.ok === true, JSON.stringify(r.body));
  r = await api('POST', '/api/auth/login', { body: { username: 'user1', password: SECOND_PW } });
  ok('第二次改密后新密码可登录', r.status === 200, JSON.stringify(r.body));

  // ---------------- 持久化（重启后新密码仍有效） ----------------
  console.log('\n【四】持久化');
  killServer();
  await sleep(300);
  await startServer();
  r = await api('POST', '/api/auth/login', { body: { username: 'user1', password: SECOND_PW } });
  ok('重启后新密码仍可登录', r.status === 200, JSON.stringify(r.body));
  r = await api('POST', '/api/auth/login', { body: { username: 'user1', password: OLD_PW } });
  ok('重启后旧密码仍被拒', r.status === 401, JSON.stringify(r.body));

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
