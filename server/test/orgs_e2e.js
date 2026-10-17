// 组织机构（工作模式）—— 端到端测试
//
//   node test/orgs_e2e.js
//
// 起隔离实例，覆盖：模式/权限门槛、建组织、按工号录入员工（工号=账号、
// 初始密码=工号）、同事自动互为好友、work 模式下注册/搜索/好友申请的
// 行为约束、移除员工、重启持久化。

const { spawn } = require('child_process');
const path = require('path');
const fs = require('fs');
const os = require('os');

const PORT = 3697;
const BASE = `http://127.0.0.1:${PORT}`;
const SERVER_DIR = path.resolve(__dirname, '..');
const DATA_DIR = path.join(os.tmpdir(), 'xiaozhi-orgs-e2e-' + Date.now());

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
  console.log('[orgs E2E] 服务端已就绪 ' + BASE + '\n');

  // ---------------- 前置：admin + normal 模式下的"外人" ----------------
  let r = await api('POST', '/api/auth/login', { body: { username: 'admin', password: 'TestAdmin_123' } });
  const admin = r.body?.token;
  ok('管理员登录', !!admin, JSON.stringify(r.body));

  r = await api('POST', '/api/auth/register', { body: { username: 'outsider', password: 'pw123456', nickname: '外人' } });
  const outsider = r.body?.token;
  ok('normal 模式注册外人（对照组）', !!outsider, JSON.stringify(r.body));

  // ---------------- 一：模式与权限门槛 ----------------
  console.log('\n【一】模式与权限门槛');
  r = await api('POST', '/api/orgs', { token: admin, body: { name: '测试厂' } });
  ok('normal 模式建组织 → 400 要求先切 work',
    r.status === 400 && /工作模式/.test(r.body.error || ''), JSON.stringify(r.body));

  r = await api('PUT', '/api/admin/settings', { token: admin, body: { friendMode: 'work' } });
  ok('切到 work 模式', r.status === 200 && r.body?.friendMode === 'work', JSON.stringify(r.body));

  r = await api('POST', '/api/auth/register', { body: { username: 'newbie', password: 'pw123456', nickname: '新人' } });
  ok('work 模式下自助注册 → 403', r.status === 403 && /管理员/.test(r.body.error || ''), JSON.stringify(r.body));

  r = await api('POST', '/api/orgs', { body: { name: '匿名厂' } });
  ok('未登录建组织 → 401', r.status === 401, JSON.stringify(r.body));

  // ---------------- 二：创建组织与录入员工 ----------------
  console.log('\n【二】创建组织与录入员工');
  r = await api('POST', '/api/orgs', { token: admin, body: { name: '盛' } });
  ok('组织名 1 字被拒', r.status === 400, JSON.stringify(r.body));

  r = await api('POST', '/api/orgs', { token: admin, body: { name: '盛京食品厂' } });
  const orgId = r.body?.id;
  ok('创建组织', r.status === 200 && !!orgId, JSON.stringify(r.body));

  r = await api('POST', '/api/orgs', { token: admin, body: { name: '第二厂' } });
  ok('重复建组织 → 409', r.status === 409, JSON.stringify(r.body));

  r = await api('POST', `/api/orgs/${orgId}/members`, { token: admin, body: { employeeNo: 'e1', nickname: '一毛' } });
  ok('工号太短被拒（3 位起）', r.status === 400, JSON.stringify(r.body));
  r = await api('POST', `/api/orgs/${orgId}/members`, { token: admin, body: { employeeNo: 'emp 001', nickname: '空格' } });
  ok('工号含空格被拒', r.status === 400, JSON.stringify(r.body));

  r = await api('POST', `/api/orgs/${orgId}/members`, { token: admin, body: { employeeNo: 'emp001', nickname: '张一' } });
  ok('录入 emp001', r.status === 200 && r.body.user?.username === 'emp001', JSON.stringify(r.body));

  r = await api('POST', '/api/auth/login', { body: { username: 'emp001', password: 'emp001' } });
  const emp1 = r.body?.token;
  ok('初始密码=工号，emp001 可登录', !!emp1, JSON.stringify(r.body));

  r = await api('POST', `/api/orgs/${orgId}/members`, { token: admin, body: { employeeNo: 'emp001', nickname: '重号' } });
  ok('工号重复 → 409', r.status === 409, JSON.stringify(r.body));

  r = await api('POST', `/api/orgs/${orgId}/members`, { token: admin, body: { employeeNo: 'emp002', nickname: '李二' } });
  ok('录入 emp002', r.status === 200, JSON.stringify(r.body));
  r = await api('POST', `/api/orgs/${orgId}/members`, { token: admin, body: { employeeNo: 'emp003', nickname: '王三' } });
  ok('录入 emp003', r.status === 200, JSON.stringify(r.body));

  // ---------------- 三：同事自动互为好友 ----------------
  console.log('\n【三】同事自动互为好友');
  r = await api('GET', '/api/friends', { token: emp1 });
  const f1 = (r.body?.friends || []).map((x) => x.username).sort();
  ok('emp001 好友 = admin + emp002 + emp003（自动）',
    JSON.stringify(f1) === JSON.stringify(['admin', 'emp002', 'emp003']), JSON.stringify(f1));

  r = await api('GET', '/api/friends', { token: admin });
  const fa = (r.body?.friends || []).map((x) => x.username).sort();
  // 🔴 2026-10-12 更新：好友补齐（backfillAllFriendships，2026-10-11 上线）在
  // 切到 work 模式时会把**所有真人两两**补成好友 —— outsider 也是真人，
  // 所以 admin 的自动好友 = 三名员工 + outsider（emp001 只有 3 个是因为
  // backfill 触发时它还没建出来，之后靠组织自动互好友补齐）。
  ok('admin 好友 = 三名员工 + outsider（自动）',
    JSON.stringify(fa) === JSON.stringify(['emp001', 'emp002', 'emp003', 'outsider']), JSON.stringify(fa));

  // ---------------- 四：work 模式行为约束 ----------------
  console.log('\n【四】work 模式行为约束');
  r = await api('POST', '/api/friends/request', { token: emp1, body: { friendId: 9999, message: '' } });
  ok('work 下好友申请 → 403', r.status === 403 && /自动互为好友/.test(r.body.error || ''), JSON.stringify(r.body));

  r = await api('GET', '/api/users/search?q=outsider', { token: emp1 });
  ok('员工搜不到组织外的用户', Array.isArray(r.body) && r.body.length === 0, JSON.stringify(r.body));

  r = await api('GET', '/api/users/search?q=emp00', { token: emp1 });
  ok('员工能搜到同组织同事（含自己，LIKE 匹配 emp001/002/003）',
    Array.isArray(r.body) && r.body.length === 3, JSON.stringify(r.body));

  r = await api('GET', '/api/users/search?q=outsider', { token: admin });
  ok('admin 搜索不受限', Array.isArray(r.body) && r.body.length === 1, JSON.stringify(r.body));

  // ---------------- 五：GET /orgs/my ----------------
  console.log('\n【五】我的组织');
  r = await api('GET', '/api/orgs/my', { token: emp1 });
  // 2026-10-13：成员口径 = 在册员工 + 系统管理员（org_id=NULL 的 admin 账号）。
  // 修的是龙哥报的"管理员在通讯录里看不到"—— 以前只按 org_id 查，admin
  // 不占编制，于是在任何人的组织通讯录里都消失。游离普通账号（outsider，
  // role='user' 且 org_id=NULL）仍然不列：那不是员工，列进来编制会歪。
  const mems = r.body?.members || [];
  ok('员工查到组织与全员（3 员工 + 管理员）',
    r.body?.org?.name === '盛京食品厂' && mems.length === 4
    && mems.filter((m) => m.employee_no).length === 3
    && mems.some((m) => m.username === 'admin' && m.role === 'admin' && !m.employee_no),
    JSON.stringify(mems));

  r = await api('GET', '/api/orgs/my', { token: outsider });
  ok('组织外用户查 my → org=null', r.body?.org === null, JSON.stringify(r.body));

  r = await api('GET', '/api/orgs/my', { token: admin });
  ok('admin 查到组织：员工 + 自己，但不含组织外游离账号',
    r.body?.org?.name === '盛京食品厂'
    && (r.body.members || []).some((m) => m.username === 'admin' && m.role === 'admin')
    && !(r.body.members || []).some((m) => m.username === 'outsider'),
    JSON.stringify(r.body));

  // ---------------- 六：移除员工 ----------------
  console.log('\n【六】移除员工');
  // 找到 emp002 的 id
  const my = await api('GET', '/api/orgs/my', { token: emp1 });
  const emp2id = my.body.members.find((m) => m.username === 'emp002')?.id;

  r = await api('DELETE', `/api/orgs/${orgId}/members/${emp2id}`, { token: emp1 });
  ok('员工移除同事 → 403', r.status === 403, JSON.stringify(r.body));

  r = await api('DELETE', `/api/orgs/${orgId}/members/${emp2id}`, { token: admin });
  ok('admin 移除 emp002', r.status === 200, JSON.stringify(r.body));

  r = await api('GET', '/api/friends', { token: emp1 });
  const f1b = (r.body?.friends || []).map((x) => x.username).sort();
  ok('移除后 emp001 好友少一个',
    JSON.stringify(f1b) === JSON.stringify(['admin', 'emp003']), JSON.stringify(f1b));

  r = await api('DELETE', `/api/orgs/${orgId}/members/${emp2id}`, { token: admin });
  ok('重复移除 → 404', r.status === 404, JSON.stringify(r.body));

  // ---------------- 七：持久化（重启不丢） ----------------
  console.log('\n【七】持久化');
  killServer();
  await sleep(300);
  await startServer();
  r = await api('POST', '/api/auth/login', { body: { username: 'emp001', password: 'emp001' } });
  ok('重启后 emp001 仍可登录', r.status === 200, JSON.stringify(r.body));
  r = await api('GET', '/api/orgs/my', { token: r.body?.token });
  // 2 员工 + 管理员（org_id=NULL，2026-10-13 起纳入成员口径）
  ok('重启后组织与成员仍在',
    r.body?.org?.name === '盛京食品厂' && r.body.members?.length === 3
    && (r.body.members || []).some((m) => m.username === 'admin' && m.role === 'admin'),
    JSON.stringify(r.body));
  r = await api('GET', '/api/client/bootstrap');
  ok('bootstrap 下发 work 模式', r.body?.friendMode === 'work', JSON.stringify(r.body));

  // ---------------- 八：重命名组织（2026-10-17 龙哥报的 bug） ----------------
  console.log('\n【八】重命名组织');
  // 症状：一个服务器只能建一个组织，创建时名字打错后就再没有任何入口能改，
  // 只能改数据库。本段即回归护栏：接口存在 + 权限 + 长度口径 + 落库持久化。
  r = await api('PUT', `/api/orgs/${orgId}`, { token: admin, body: { name: '盛' } });
  ok('组织名 1 字被拒', r.status === 400, JSON.stringify(r.body));

  r = await api('PUT', `/api/orgs/${orgId}`, { token: admin, body: { name: 'x'.repeat(31) } });
  ok('组织名 31 字被拒', r.status === 400, JSON.stringify(r.body));

  r = await api('PUT', `/api/orgs/${orgId}`, { token: emp1, body: { name: '员工乱改' } });
  ok('员工改名 → 403', r.status === 403, JSON.stringify(r.body));

  r = await api('PUT', '/api/orgs/99999', { token: admin, body: { name: '改错组织' } });
  ok('改不存在的组织 → 404', r.status === 404, JSON.stringify(r.body));

  r = await api('PUT', `/api/orgs/${orgId}`, { body: { name: '匿名改' } });
  ok('未登录改名 → 401', r.status === 401, JSON.stringify(r.body));

  r = await api('PUT', `/api/orgs/${orgId}`, { token: admin, body: { name: '盛京优特商贸' } });
  ok('admin 改名成功', r.status === 200 && r.body?.name === '盛京优特商贸', JSON.stringify(r.body));

  r = await api('GET', '/api/orgs/my', { token: emp1 });
  ok('改名后员工侧同步生效', r.body?.org?.name === '盛京优特商贸', JSON.stringify(r.body?.org));

  // 改名只改名字，不该动编制与好友关系
  r = await api('GET', '/api/friends', { token: emp1 });
  const f1c = (r.body?.friends || []).map((x) => x.username).sort();
  ok('改名不影响成员与好友',
    JSON.stringify(f1c) === JSON.stringify(['admin', 'emp003']), JSON.stringify(f1c));

  // 改名必须落库：重启后仍是新名字（内存态的话重启就打回原形）
  killServer();
  await sleep(300);
  await startServer();
  r = await api('POST', '/api/auth/login', { body: { username: 'emp001', password: 'emp001' } });
  r = await api('GET', '/api/orgs/my', { token: r.body?.token });
  ok('重启后改名仍生效', r.body?.org?.name === '盛京优特商贸', JSON.stringify(r.body?.org));

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

function emp2Helper() { return null; }
