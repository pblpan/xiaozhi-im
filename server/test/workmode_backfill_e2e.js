// 工作模式好友补齐端到端测试（2026-10-11 龙哥反馈：
// normal 模式注册的用户切到工作模式后没有自动互加好友）
//
//   node test/workmode_backfill_e2e.js
//
// 【四条必须钉住的性质】
//   ① normal → work 切换那一刻，所有真人（含 admin）两两互加 accepted ——
//      这是龙哥要的主行为，"改了模式好友还是散的"就是没这条。
//   ② 🔴 幂等：重复触发（再切一次/再点按钮）不加重复关系 —— friendships
//      有 UNIQUE(user_id,friend_id)，但行为上要验证 added=0，不能靠约束兜底算完事。
//   ③ 🔴 机器人不参与好友关系（is_bot=0 过滤）—— 机器人不是人。
//   ④ 已有 accepted 关系原样保留（remark 等不碰）—— 补齐是 OR IGNORE，不是清库重建；
//      normal 时期的 pending 申请则**升级为 accepted**（工作模式"同事天然是好友"，
//      申请-审批语义不再成立；不升级的话 pending 占住 UNIQUE 一行，造成单向好友）。
//
// 🔴 GET /api/friends 返回 { friends:[{id,username,nickname,...,remark,created_at}], pending:[...] }，
//    friends 里全是 accepted，**没有 status 字段** —— 断言按 username 判，别按 status。

const { spawn } = require('child_process');
const path = require('path');
const fs = require('fs');
const os = require('os');

const PORT = 3738;
const BASE = `http://127.0.0.1:${PORT}`;
const SERVER_DIR = path.resolve(__dirname, '..');
const DATA_DIR = path.join(os.tmpdir(), 'xiaozhi-backfill-e2e-' + Date.now());

let passed = 0, failed = 0;
const failures = [];
const ok = (n, c, x) => {
  if (c) { passed++; console.log(`  \u2713 ${n}`); }
  else { failed++; failures.push(n + (x ? ` — ${x}` : '')); console.log(`  \u2717 ${n}${x ? '  → ' + x : ''}`); }
};
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function api(method, p, { token, body } = {}) {
  const res = await fetch(BASE + p, {
    method,
    headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: 'Bearer ' + token } : {}) },
    body: body ? JSON.stringify(body) : undefined,
  });
  let json = null; try { json = await res.json(); } catch { /* 空响应 */ }
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
    try { const r = await fetch(BASE + '/api/health'); if (r.ok) return; } catch { /* 还没起来 */ }
    await sleep(250);
  }
  throw new Error('服务端启动超时\n' + serverLog);
}
function stopServer() {
  if (serverProc) { try { serverProc.kill(); } catch { /* ignore */ } }
  try { fs.rmSync(DATA_DIR, { recursive: true, force: true }); } catch { /* ignore */ }
}

(async () => {
  await startServer();
  console.log('[工作模式好友补齐 E2E] ' + BASE + '\n');

  const login = await api('POST', '/api/auth/login', { body: { username: 'admin', password: 'TestAdmin_123' } });
  ok('管理员登录', login.status === 200, `got=${login.status}`);
  const ta = login.body.token;
  const aId = login.body.user.id;

  // ---------------- 一：normal 模式注册，互不为好友 ----------------
  console.log('\n【一】normal 模式注册 3 人（互不为好友）');
  const users = [];
  for (const u of ['alice', 'bob', 'carol']) {
    const r = await api('POST', '/api/auth/register', { body: { username: u, password: 'pw123456', nickname: u } });
    ok(`注册 ${u}`, !!r.body?.token, JSON.stringify(r.body).slice(0, 80));
    users.push(r.body.user);
  }
  const uidOf = (name) => users.find((u) => u.username === name).id;

  let r = await api('GET', '/api/friends', { token: users[0] && (await api('POST', '/api/auth/login', { body: { username: 'alice', password: 'pw123456' } })).body.token });
  const aliceToken = (await api('POST', '/api/auth/login', { body: { username: 'alice', password: 'pw123456' } })).body.token;
  const aliceFriends = Array.isArray(r.body) ? r.body : (r.body?.friends || []);
  ok('normal 下 alice 没有自动好友（0 个）', aliceFriends.length === 0, JSON.stringify(aliceFriends));

  // alice 与 bob 手动加一个 pending 申请（验证补齐不清库、pending 保留语义见【三】）
  const bobToken = (await api('POST', '/api/auth/login', { body: { username: 'bob', password: 'pw123456' } })).body.token;
  r = await api('POST', '/api/friends/request', { token: aliceToken, body: { friendId: uidOf('bob'), message: '交个朋友' } });
  ok('normal 下手动好友申请可发', r.status === 200 || r.status === 201, JSON.stringify(r.body).slice(0, 100));

  // 建一个机器人（验证不参与）
  r = await api('POST', '/api/admin/integrations/bots', { token: ta, body: { name: '路人机器人' } });
  const botId = r.body?.id;
  ok('建一个机器人', !!botId, JSON.stringify(r.body).slice(0, 80));

  // ---------------- 二：切到 work —— 自动补齐 ----------------
  console.log('\n【二】切到工作模式 → 全员自动互加');

  r = await api('PUT', '/api/admin/settings', { token: ta, body: { friendMode: 'work' } });
  ok('切换 → 200 且带 friendsBackfilled', r.status === 200 && !!r.body?.friendsBackfilled,
    JSON.stringify(r.body).slice(0, 160));
  const bf = r.body?.friendsBackfilled || {};
  // 4 个真人（admin+alice+bob+carol）→ C(4,2)=6 对 → 12 行；
  // alice→bob 的手动 pending 占住一行 → 11 行新增 + 1 行 pending 升级 = 12 行关系
  ok('  🔴 全员补齐：4 人 6 对、12 行关系（11 新增 + 1 pending 升级）',
    bf.users === 4 && bf.pairs === 6 && bf.added === 11 && bf.upgraded === 1,
    JSON.stringify(bf));

  const friendsOf = async (tok) => {
    const x = await api('GET', '/api/friends', { token: tok });
    return Array.isArray(x.body) ? x.body : (x.body?.friends || []);
  };
  const namesOf = (list) => list.map((f) => f.username).sort();
  let af = await friendsOf(aliceToken);
  ok('  🔴 alice 好友 = admin + bob + carol（3 人，pending 的 bob 已升级为 accepted）',
    af.length === 3 && JSON.stringify(namesOf(af)) === JSON.stringify(['admin', 'bob', 'carol']),
    JSON.stringify(af.map((f) => [f.username, f.nickname])));
  ok('  🔴 机器人不在 alice 的好友里', !af.some((f) => f.id === botId), JSON.stringify(af.map((f) => f.id)));

  // bob 一侧：好友 3 人 + 之前收到的 alice 申请不再挂在 pending 队列里
  const bobFriends = await friendsOf(bobToken);
  ok('  bob 好友 = admin + alice + carol（双向关系，不是单向）',
    bobFriends.length === 3 && JSON.stringify(namesOf(bobFriends)) === JSON.stringify(['admin', 'alice', 'carol']),
    JSON.stringify(bobFriends.map((f) => f.username)));
  const bobPending = (await api('GET', '/api/friends', { token: bobToken })).body?.pending || [];
  ok('  bob 的待处理申请队列已清空（pending 升级后不留尾巴）', bobPending.length === 0,
    JSON.stringify(bobPending.map((p) => p.username)));

  // ---------------- 三：幂等 + 手动端点 ----------------
  console.log('\n【三】幂等与手动补齐端点');

  r = await api('POST', '/api/admin/friendships/backfill', { token: ta });
  ok('  🔴 再跑一次补齐 → added=0（幂等，不重复）',
    r.status === 200 && r.body?.added === 0 && r.body?.pairs === 6,
    JSON.stringify(r.body));

  r = await api('PUT', '/api/admin/settings', { token: ta, body: { friendMode: 'work' } });
  ok('已是 work 再切 work → 不触发补齐（无 friendsBackfilled 字段）',
    r.status === 200 && r.body?.friendsBackfilled === undefined, JSON.stringify(r.body).slice(0, 120));

  // 补齐不清库：手动申请的那条 alice→bob 还是原样（accepted 与补齐方向合并成一条也不该报错，
  // 关键是关系仍存在且计数正确）
  af = await friendsOf(aliceToken);
  ok('  已有关系原样保留（alice 仍是 3 个好友）', af.length === 3, JSON.stringify(af.length));

  // 未登录/非管理员
  r = await api('POST', '/api/admin/friendships/backfill', { token: bobToken });
  ok('非管理员调补齐 → 403', r.status === 403, JSON.stringify(r.body));
  r = await api('POST', '/api/admin/friendships/backfill', {});
  ok('未登录调补齐 → 401', r.status === 401, JSON.stringify(r.body));

  // ---------------- 四：工作模式语义不回归 ----------------
  console.log('\n【四】工作模式语义不回归');

  r = await api('POST', '/api/friends/request', { token: aliceToken, body: { friendId: uidOf('carol') } });
  ok('work 模式下好友申请仍被拒（同事自动是好友）', r.status === 403, JSON.stringify(r.body).slice(0, 100));

  // ------------------------------------------------------------------ 结果
  console.log(`\n========== 结果：${passed} 通过 / ${failed} 失败 ==========`);
  if (failures.length) { console.log('失败项：'); for (const f of failures) console.log('  ✗ ' + f); }
  stopServer();
  process.exit(failed ? 1 : 0);
})().catch((e) => { console.error('测试执行异常：', e); stopServer(); process.exit(1); });
