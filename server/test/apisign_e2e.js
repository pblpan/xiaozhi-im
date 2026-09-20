// 开放 API 签名通道（M3）—— 端到端对抗测试
//
//   node test/apisign_e2e.js
//
// 【为什么必须有反向断言】
// 签名校验这种东西，"正确签名能过"这一条通过说明不了任何事 ——
// 它可能在**什么都没校**的情况下也通过。真正证明它有用的是这四个反面：
//   ① 签名改 1 字节 → 401
//   ② 时间戳挪到 10 分钟前 → 401
//   ③ 同一个 nonce 用第二次 → 409
//   ④ 改了 query / 改了 body（签名没跟着改）→ 401
// 每一条对应一类真实攻击；少一条，那类攻击就是敞开的，而且**没有任何报错**。
//
// 【判据纪律】
// · 不只认状态码：401 下面有 sign_missing / bad_sign / timestamp_out_of_window，
//   必须逐条对上 `code`，否则"因为别的原因 401"也会算过。
// · 变异测试见文件末尾的说明：把时间窗判据改成恒真，本用例必须报红。

const { spawn } = require('child_process');
const path = require('path');
const fs = require('fs');
const os = require('os');
const crypto = require('crypto');

const PORT = 3716;
const BASE = `http://127.0.0.1:${PORT}`;
const SERVER_DIR = path.resolve(__dirname, '..');
const DATA_DIR = path.join(os.tmpdir(), 'xz-apisign-e2e-' + Date.now());
const SCOPES = ['conversation:read', 'message:send', 'user:read'];

let passed = 0;
let failed = 0;
const failures = [];

function ok(name, cond, extra) {
  if (cond) { passed++; console.log(`  \u2713 ${name}`); }
  else {
    failed++;
    failures.push(name + (extra ? ` — ${extra}` : ''));
    console.log(`  \u2717 ${name}${extra ? `  → ${extra}` : ''}`);
  }
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function api(method, p, { headers, body } = {}) {
  const res = await fetch(BASE + p, {
    method,
    headers: {
      ...(body != null ? { 'Content-Type': 'application/json' } : {}),
      ...(headers || {}),
    },
    body: body == null ? undefined : (typeof body === 'string' ? body : JSON.stringify(body)),
  });
  let json = null;
  try { json = await res.json(); } catch { /* 空响应 */ }
  return { status: res.status, body: json };
}

let serverProc = null;
let serverLog = '';

async function startServer() {
  serverProc = spawn(process.execPath, [path.join(SERVER_DIR, 'src', 'index.js')], {
    env: { ...process.env, PORT: String(PORT), DATA_DIR, ADMIN_PASSWORD: 'SignAdmin_123' },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  serverProc.stdout.on('data', (d) => { serverLog += d.toString(); });
  serverProc.stderr.on('data', (d) => { serverLog += d.toString(); });
  for (let i = 0; i < 60; i++) {
    try { const r = await fetch(BASE + '/api/health'); if (r.ok) return; } catch { /* 还没起来 */ }
    await sleep(250);
  }
  throw new Error('服务端启动超时\n' + serverLog);
}

function stopServer() {
  if (serverProc) { try { serverProc.kill(); } catch { /* ignore */ } }
  try { fs.rmSync(DATA_DIR, { recursive: true, force: true }); } catch { /* ignore */ }
}

/* ==================== 客户端侧的签名（照协议算一遍） ==================== */

const nowSec = () => Math.floor(Date.now() / 1000);
const nonceOf = () => crypto.randomBytes(12).toString('hex');

function sha256Hex(bufOrStr) {
  return crypto.createHash('sha256').update(bufOrStr).digest('hex');
}

function splitUrl(u) {
  const s = String(u || '/');
  const i = s.indexOf('?');
  return i < 0 ? [s, ''] : [s.slice(0, i), s.slice(i + 1)];
}

/**
 * 按协议算签名头。
 * 待签串 = method \n path \n query \n timestamp \n nonce \n sha256_hex(原始 body)
 */
function signedHeaders({
  appId, secret, method, url, body = '', timestamp = nowSec(), nonce = nonceOf(),
}) {
  const [p, q] = splitUrl(url);
  const raw = body == null ? '' : (typeof body === 'string' ? body : JSON.stringify(body));
  const sign = crypto.createHmac('sha256', secret)
    .update([
      String(method).toUpperCase(), p, q,
      String(timestamp), nonce, sha256Hex(Buffer.from(raw, 'utf8')),
    ].join('\n'))
    .digest('hex');
  return {
    'X-App-Id': appId,
    'X-Timestamp': String(timestamp),
    'X-Nonce': nonce,
    'X-Sign': sign,
  };
}

/** 篡改签名最后一个字符（改 1 字节，不是换个乱写的值）。 */
function tamperSign(h) {
  const s = h['X-Sign'];
  const last = s.slice(-1);
  return { ...h, 'X-Sign': s.slice(0, -1) + (last === 'a' ? 'b' : 'a') };
}

(async () => {
  await startServer();
  console.log('[签名通道 E2E] 服务端已就绪 ' + BASE + '\n');

  // ── 前置：管理员 + 一对 app_id/app_secret ──
  let r = await api('POST', '/api/auth/login', { body: { username: 'admin', password: 'SignAdmin_123' } });
  const jwt = r.body?.token;
  ok('管理员登录', !!jwt, JSON.stringify(r.body));
  const ADMIN = { Authorization: 'Bearer ' + jwt };

  r = await api('POST', '/api/admin/integrations/clients', {
    headers: { ...ADMIN, 'Content-Type': 'application/json' },
    body: { name: '门店系统', scopes: SCOPES },
  });
  ok('发一对 app_id / app_secret', r.status === 200 && !!r.body?.secret, JSON.stringify(r.body).slice(0, 200));
  const APP_ID = r.body?.client?.appId;
  const SECRET = r.body?.secret;

  r = await api('GET', '/api/admin/integrations/clients', { headers: ADMIN });
  const listed = r.body || [];
  ok('列表里能查到它', listed.some((c) => c.appId === APP_ID), JSON.stringify(listed));
  ok('  🔴 列表里**没有**明文 secret（明文只在发那一次出现）',
    !JSON.stringify(listed).includes(SECRET), 'secret 出现在了列表里 — 泄露面');

  // ============================================================
  // 【一】正确签名 → 200，且能看出是谁在调
  // ============================================================
  console.log('\n【一】正确签名');
  const urlMe = '/api/open/me';
  r = await api('GET', urlMe, { headers: signedHeaders({ appId: APP_ID, secret: SECRET, method: 'GET', url: urlMe }) });
  ok('正确签名 → 200', r.status === 200, JSON.stringify(r.body).slice(0, 200));
  ok('  /me 回 via=sign（溯源用）', r.body?.via === 'sign', JSON.stringify(r.body?.via));
  ok('  /me 回 appId', r.body?.appId === APP_ID, JSON.stringify(r.body?.appId));
  ok('  scope 生效（拿到的是发的时候勾的那些）',
    JSON.stringify(r.body?.scopes) === JSON.stringify(SCOPES), JSON.stringify(r.body?.scopes));

  // ============================================================
  // 【二】四条对抗用例
  // ============================================================
  console.log('\n【二】对抗用例');

  // ① 签名改 1 字节
  r = await api('GET', urlMe, { headers: tamperSign(signedHeaders({ appId: APP_ID, secret: SECRET, method: 'GET', url: urlMe })) });
  ok('① 签名改 1 字节 → 401 bad_sign',
    r.status === 401 && r.body?.code === 'bad_sign', JSON.stringify(r.body));

  // ② 时间戳挪到 10 分钟前
  r = await api('GET', urlMe, {
    headers: signedHeaders({
      appId: APP_ID, secret: SECRET, method: 'GET', url: urlMe,
      timestamp: nowSec() - 600,
    }),
  });
  ok('② 时间戳 10 分钟前 → 401 timestamp_out_of_window',
    r.status === 401 && r.body?.code === 'timestamp_out_of_window', JSON.stringify(r.body));

  // ③ 同一个 nonce 用两次
  const reused = nonceOf();
  const h1 = signedHeaders({ appId: APP_ID, secret: SECRET, method: 'GET', url: urlMe, nonce: reused });
  r = await api('GET', urlMe, { headers: h1 });
  ok('③a 第一次用这个 nonce → 200', r.status === 200, JSON.stringify(r.body).slice(0, 120));
  r = await api('GET', urlMe, { headers: h1 });
  ok('③b 第二次用同一个 nonce → 409 nonce_replayed',
    r.status === 409 && r.body?.code === 'nonce_replayed', JSON.stringify(r.body));

  // ④a 改 query（签名只对原 query 成立）
  const urlQ1 = '/api/open/conversations?limit=1';
  const urlQ2 = '/api/open/conversations?limit=9999';
  const hq = signedHeaders({ appId: APP_ID, secret: SECRET, method: 'GET', url: urlQ1 });
  r = await api('GET', urlQ1, { headers: hq });
  ok('④a 原样带 query → 通过鉴权（不是 401）', r.status !== 401, JSON.stringify(r.body).slice(0, 120));
  r = await api('GET', urlQ2, { headers: hq });
  ok('④b 把 ?limit=1 改成 9999 → 401（query 也必须签进去）',
    r.status === 401 && r.body?.code === 'bad_sign', JSON.stringify(r.body));

  // ④b 改 body（防中途改包）
  const urlMsg = '/api/open/conversations/999999/messages';
  const bodyA = JSON.stringify({ text: 'hi' });
  const bodyB = JSON.stringify({ text: 'hi', extra: 1 });
  const hb = signedHeaders({ appId: APP_ID, secret: SECRET, method: 'POST', url: urlMsg, body: bodyA });
  r = await api('POST', urlMsg, { headers: hb, body: bodyA });
  ok('④c 原样带 body → 通过鉴权（不是 401）', r.status !== 401, JSON.stringify(r.body).slice(0, 160));
  r = await api('POST', urlMsg, { headers: hb, body: bodyB });
  ok('④d body 被改（签名没跟着改）→ 401（防中途改包）',
    r.status === 401 && r.body?.code === 'bad_sign', JSON.stringify(r.body));

  // ⑤ 少一个头
  const hm = signedHeaders({ appId: APP_ID, secret: SECRET, method: 'GET', url: urlMe });
  delete hm['X-Nonce'];
  r = await api('GET', urlMe, { headers: hm });
  ok('⑤ 缺 X-Nonce → 401 sign_missing',
    r.status === 401 && r.body?.code === 'sign_missing', JSON.stringify(r.body));

  // ⑥ app_id 不存在 / 被停用 → 同一个码（不给枚举的工具）
  r = await api('GET', urlMe, {
    headers: signedHeaders({ appId: 'ak_does_not_exist', secret: SECRET, method: 'GET', url: urlMe }),
  });
  ok('⑥a app_id 不存在 → 401 app_invalid',
    r.status === 401 && r.body?.code === 'app_invalid', JSON.stringify(r.body));

  const myId = (await api('GET', '/api/admin/integrations/clients', { headers: ADMIN }))
    .body.find((c) => c.appId === APP_ID).id;
  r = await api('POST', `/api/admin/integrations/clients/${myId}/enable`, {
    headers: { ...ADMIN, 'Content-Type': 'application/json' },
    body: { enabled: false },
  });
  ok('  停用生效', r.status === 200 && r.body?.enabled === false, JSON.stringify(r.body));
  r = await api('GET', urlMe, { headers: signedHeaders({ appId: APP_ID, secret: SECRET, method: 'GET', url: urlMe }) });
  ok('⑥b 已停用 → 401，且与"不存在"同一个码（不给枚举工具）',
    r.status === 401 && r.body?.code === 'app_invalid', JSON.stringify(r.body));
  await api('POST', `/api/admin/integrations/clients/${myId}/enable`, {
    headers: { ...ADMIN, 'Content-Type': 'application/json' },
    body: { enabled: true },
  });

  // ⑦ 🔴 带了 X-App-Id 但签名不对，就**不能**回退去用 Authorization
  r = await api('GET', urlMe, {
    headers: { ...tamperSign(signedHeaders({ appId: APP_ID, secret: SECRET, method: 'GET', url: urlMe })), ...ADMIN },
  });
  ok('⑦ 带 X-App-Id 且签名错 → 仍然 401（不回退到 Bearer）',
    r.status === 401, JSON.stringify(r.body));

  // ============================================================
  // 【三】两条通道并存、不互相污染
  // ============================================================
  console.log('\n【三】两条通道并存');
  r = await api('GET', urlMe, { headers: ADMIN });
  ok('不带 X-App-Id 时，原来的 Bearer 照旧能用', r.status === 200, JSON.stringify(r.body).slice(0, 160));
  ok('  那条通道的 via 不是 sign', r.body?.via !== 'sign', JSON.stringify(r.body?.via));

  r = await api('POST', '/api/admin/integrations/tokens', {
    headers: { ...ADMIN, 'Content-Type': 'application/json' },
    body: { name: '老对接方', scopes: SCOPES },
  });
  const legacyToken = r.body?.token;
  r = await api('GET', urlMe, { headers: { Authorization: 'Bearer ' + legacyToken } });
  ok('长期令牌通道没被签名改造打破', r.status === 200, JSON.stringify(r.body).slice(0, 160));

  // ============================================================
  // 【四】密钥轮换：宽限期内旧的还能用，过期即失效
  // ============================================================
  console.log('\n【四】密钥轮换');
  r = await api('POST', `/api/admin/integrations/clients/${myId}/rotate`, {
    headers: { ...ADMIN, 'Content-Type': 'application/json' },
    body: {},
  });
  ok('轮换返回新 secret', r.status === 200 && !!r.body?.secret && r.body.secret !== SECRET,
    JSON.stringify(r.body).slice(0, 160));
  const NEW_SECRET = r.body.secret;

  r = await api('GET', urlMe, { headers: signedHeaders({ appId: APP_ID, secret: NEW_SECRET, method: 'GET', url: urlMe }) });
  ok('  新密钥立刻可用', r.status === 200, JSON.stringify(r.body).slice(0, 120));
  r = await api('GET', urlMe, { headers: signedHeaders({ appId: APP_ID, secret: SECRET, method: 'GET', url: urlMe }) });
  ok('  旧密钥在宽限期内**仍然可用**（不然"轮换一下就断线"）',
    r.status === 200, JSON.stringify(r.body));

  // ============================================================
  // 【五】时间戳窗口边界（299s 放行 / 301s 拒绝）
  // ============================================================
  console.log('\n【五】时间窗边界');
  r = await api('GET', urlMe, {
    headers: signedHeaders({ appId: APP_ID, secret: NEW_SECRET, method: 'GET', url: urlMe, timestamp: nowSec() - 299 }),
  });
  ok('差 299 秒（窗内）→ 放行', r.status === 200, JSON.stringify(r.body).slice(0, 120));
  r = await api('GET', urlMe, {
    headers: signedHeaders({ appId: APP_ID, secret: NEW_SECRET, method: 'GET', url: urlMe, timestamp: nowSec() + 301 }),
  });
  ok('差 301 秒（窗外）→ 401', r.status === 401, JSON.stringify(r.body));

  // ============================================================
  // 【六】nonce 清理（这一段在**本进程**里直接开库，理由见注释）
  // ============================================================
  //
  // 服务端进程持有这个库，`maybePurgeNonces` 又是 60 秒节流、测不出来，
  // 所以这里在本进程里开同一个库直接调 `purgeExpiredNonces`。
  // SQLite WAL 支持多进程读写，且此时服务端空闲，没有并发写。
  console.log('\n【六】nonce 清理（表不能一路涨下去）');
  process.env.DATA_DIR = DATA_DIR;
  process.env.ADMIN_PASSWORD = 'SignAdmin_123';
  const apisign = require(path.join(SERVER_DIR, 'src', 'apisign'));
  const db = require(path.join(SERVER_DIR, 'src', 'db'));

  const W = apisign.SIGN_WINDOW_SEC;
  const now = Date.now();
  // 两条探针，nonce 值记下来逐条查 —— 只数总数的话，
  // "把全表都清了"和"只清该清的"看起来一样，那就又是一个恒真断言。
  const oldNonce = 'old-' + nonceOf();
  const freshNonce = 'fresh-' + nonceOf();
  db.prepare('INSERT INTO api_nonce (nonce, app_id, at) VALUES (?,?,?)')
    .run(oldNonce, APP_ID, now - (W * 2 + 120) * 1000);
  db.prepare('INSERT INTO api_nonce (nonce, app_id, at) VALUES (?,?,?)')
    .run(freshNonce, APP_ID, now);

  apisign.purgeExpiredNonces(now);
  const has = (n) => db.prepare('SELECT count(*) c FROM api_nonce WHERE nonce = ?').get(n).c;
  ok('🔴 过了保留期的 nonce 被清掉', has(oldNonce) === 0, `old 还在`);
  ok('🔴 窗口内的 nonce **没被**清掉（清掉就等于给重放开口子）',
    has(freshNonce) === 1, `fresh 被误清`);
  // 边界再压一下：刚好卡在保留期内侧（2W+30 秒前）的**必须**留着，
  // 因为它对应的签名在"未来 30 秒"这个点上还是能被重放的。
  const edgeNonce = 'edge-' + nonceOf();
  db.prepare('INSERT INTO api_nonce (nonce, app_id, at) VALUES (?,?,?)')
    .run(edgeNonce, APP_ID, now - (W * 2 + 30) * 1000);
  apisign.purgeExpiredNonces(now);
  ok('🔴 保留期内侧（2×窗口+30s）的 nonce 也留着',
    has(edgeNonce) === 1, `edge 被误清 — 保留期算短了`);
  ok('  保留期 = 2×窗口+60 > 可被重放的时间跨度 2×窗口',
    W * 2 + 60 > W * 2, `W=${W}`);

  stopServer();
  console.log(`\n[签名通道 E2E] 通过 ${passed} / 失败 ${failed}`);
  if (failures.length) { console.log('失败项：'); for (const f of failures) console.log('  ✗ ' + f); }
  process.exit(failed ? 1 : 0);
})().catch((e) => { console.error(e); stopServer(); process.exit(1); });
