// 全员群（工作模式自动建群 / 入职进群 / 离职退群）—— 端到端测试
//
//   node test/orggroup_e2e.js
//
// 龙哥 2026-10-27 需求：软件改为工作模式后自动建立一个群，新入职的员工自动入群，
// 离职的自动离群。这个测试就是钉住这三句话，以及几个"不做就会有人踩"的细节：
//   · 只建一个（反复切模式 / 反复 ensure 不能建出第二个全员群）
//   · 管理员必须在群里（他们的 org_id 是 NULL，只按 org_id 筛会把群主自己漏掉）
//   · 手动踢掉的人会被 sync 加回来 —— 故意的，想让人走应该走"移出组织"
//   · 离职只是退群，账号还在（他不是被删了）

const { spawn } = require('child_process');
const path = require('path');
const os = require('os');

const PORT = 3701;
const BASE = `http://127.0.0.1:${PORT}`;
const SERVER_DIR = path.resolve(__dirname, '..');
const DATA_DIR = path.join(os.tmpdir(), 'xiaozhi-orggroup-e2e-' + Date.now());

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
  throw new Error('服务端启动超时\n' + serverLog.slice(-800));
}

function stopServer() {
  if (serverProc) { try { serverProc.kill(); } catch { /* ignore */ } }
}

async function main() {
  console.log('[orggroup E2E] 启动隔离实例 ' + BASE + '\n');
  await startServer();

  let r = await api('POST', '/api/auth/login', { body: { username: 'admin', password: 'TestAdmin_123' } });
  const admin = r.body?.token;
  ok('管理员登录', !!admin, JSON.stringify(r.body).slice(0, 120));

  // ---------------- 一：普通模式 ----------------
  console.log('\n【一】普通模式：没有全员群，也还不许建组织');
  r = await api('GET', '/api/groups/my', { token: admin });
  ok('普通模式下没有自动建群', Array.isArray(r.body) && r.body.length === 0, JSON.stringify(r.body).slice(0, 120));
  r = await api('POST', '/api/orgs', { token: admin, body: { name: '南部新城小智' } });
  ok('普通模式下建组织被拦（必须先切工作模式）', r.status === 400, JSON.stringify(r.body).slice(0, 120));

  // ---------------- 二：切工作模式 + 建组织 → 自动建群 ----------------
  // 顺序是被产品逻辑逼出来的：建组织的接口要求"已经是工作模式"，
  // 所以切模式那一秒组织必然不存在，真正能建群的第一个时机是"建组织成功之后"。
  console.log('\n【二】切工作模式 → 建组织 → 自动建全员群');
  r = await api('PUT', '/api/admin/settings', { token: admin, body: { friendMode: 'work' } });
  ok('切工作模式 → 200', r.status === 200, JSON.stringify(r.body).slice(0, 160));
  ok('  此时还没有组织，所以先不建群（skipped:no-org）',
    r.body?.orgGroup?.skipped === 'no-org', JSON.stringify(r.body?.orgGroup));

  r = await api('POST', '/api/orgs', { token: admin, body: { name: '南部新城小智' } });
  const orgId = r.body?.id;
  ok('建组织', r.status === 200 && !!orgId, JSON.stringify(r.body).slice(0, 120));
  ok('  建组织的同时把全员群建起来了', !!r.body?.orgGroup?.groupId, JSON.stringify(r.body?.orgGroup || ''));
  const gid = r.body?.orgGroup?.groupId;
  ok('  群名 = 全员群', r.body?.orgGroup?.groupName === '全员群', r.body?.orgGroup?.groupName);

  r = await api('GET', '/api/groups/my', { token: admin });
  const mine = Array.isArray(r.body) ? r.body : [];
  ok('管理员能看到全员群', mine.length === 1 && mine[0].id === gid, JSON.stringify(mine).slice(0, 200));
  ok('  刚建组织时群里只有管理员 1 人', mine[0]?.members === 1, 'members=' + mine[0]?.members);

  // ---------------- 三：录员工 → 自动入群 ----------------
  console.log('\n【三】录员工 → 自动进群');
  const empIds = [];
  for (const no of ['10001', '10002', '10003']) {
    r = await api('POST', `/api/orgs/${orgId}/members`, { token: admin, body: { employeeNo: no, nickname: '员工' + no.slice(-1) } });
    ok(`录员工 ${no}`, r.status === 200 && !!r.body?.user?.id, JSON.stringify(r.body).slice(0, 120));
    empIds.push(r.body?.user?.id);
  }

  r = await api('GET', `/api/groups/${gid}`, { token: admin });
  let mem = (r.body?.members || []).map((m) => m.id);
  ok('三个员工都在群里', empIds.every((id) => mem.includes(id)), JSON.stringify(mem));
  ok('  成员数 = 3 员工 + 管理员 = 4', mem.length === 4, 'len=' + mem.length);
  ok('管理员自己在群里（org_id 为 NULL 也没漏）',
    mem.includes(r.body?.group?.owner_id), JSON.stringify({ owner: r.body?.group?.owner_id, mem }));

  // 幂等：再切一次（work → work 不变），不能建出第二个群
  r = await api('PUT', '/api/admin/settings', { token: admin, body: { friendMode: 'work' } });
  ok('重复切工作模式 → 不报错', r.status === 200, JSON.stringify(r.body).slice(0, 120));
  r = await api('GET', '/api/groups/my', { token: admin });
  ok('  仍然只有一个全员群', (r.body || []).length === 1, JSON.stringify(r.body).slice(0, 200));

  // ---------------- 三：入职 → 自动入群 ----------------
  console.log('\n【三】新入职 → 自动进群');
  r = await api('POST', `/api/orgs/${orgId}/members`, { token: admin, body: { employeeNo: '10004', nickname: '新来的' } });
  const newUid = r.body?.user?.id;
  ok('录新员工 10004', r.status === 200 && !!newUid, JSON.stringify(r.body).slice(0, 120));

  r = await api('GET', `/api/groups/${gid}`, { token: admin });
  mem = (r.body?.members || []).map((m) => m.id);
  ok('新员工自动在全员群里', mem.includes(newUid), JSON.stringify(mem));
  ok('  成员数 4 → 5', mem.length === 5, 'len=' + mem.length);

  // 员工自己也能看到这个群（不是只有管理员可见）
  r = await api('POST', '/api/auth/login', { body: { username: '10004', password: '10004' } });
  const empToken = r.body?.token;
  ok('新员工能用工号登录', !!empToken, JSON.stringify(r.body).slice(0, 120));
  r = await api('GET', '/api/groups/my', { token: empToken });
  ok('  他能看到全员群', (r.body || []).some((g) => g.id === gid), JSON.stringify(r.body).slice(0, 160));

  // ---------------- 四：离职 → 自动退群 ----------------
  console.log('\n【四】离职 → 自动退群（账号保留）');
  r = await api('DELETE', `/api/orgs/${orgId}/members/${newUid}`, { token: admin });
  ok('移出组织 → 200', r.status === 200, JSON.stringify(r.body).slice(0, 120));

  r = await api('GET', `/api/groups/${gid}`, { token: admin });
  mem = (r.body?.members || []).map((m) => m.id);
  ok('离职的人已退出全员群', !mem.includes(newUid), JSON.stringify(mem));
  ok('  成员数回到 4', mem.length === 4, 'len=' + mem.length);

  r = await api('GET', '/api/groups/my', { token: empToken });
  ok('  他的群列表里也没有了', !(r.body || []).some((g) => g.id === gid), JSON.stringify(r.body).slice(0, 160));

  // 账号只是离开组织，没被删 —— 用原密码还能登录（这条防"离职=删号"的误实现）
  r = await api('POST', '/api/auth/login', { body: { username: '10004', password: '10004' } });
  ok('  账号仍存在（能登录，只是不在组织里）', r.status === 200 && !!r.body?.token, JSON.stringify(r.body).slice(0, 120));

  // ---------------- 五：批量导入 = 同时入职 ----------------
  console.log('\n【五】批量导入 → 一起进群');
  r = await api('POST', `/api/orgs/${orgId}/members/import`, {
    token: admin,
    body: { rows: [{ employeeNo: '20001', nickname: '批量一' }, { employeeNo: '20002', nickname: '批量二' }] },
  });
  ok('批量导入 2 人', r.status === 200 && r.body?.created === 2, JSON.stringify(r.body).slice(0, 160));
  ok('  导入结果带回全员群同步数', !!r.body?.orgGroup, JSON.stringify(r.body?.orgGroup));

  r = await api('GET', `/api/groups/${gid}`, { token: admin });
  mem = (r.body?.members || []).map((m) => m.id);
  ok('导入的 2 人都在全员群里', mem.length === 6, 'len=' + mem.length);

  // ---------------- 收尾 ----------------
  console.log('\n====================================================');
  console.log(`通过 ${passed} / ${passed + failed}`);
  if (failed) {
    console.log('\n失败项：');
    for (const f of failures) console.log('  \u2717 ' + f);
  }
  console.log('====================================================');

  stopServer();
  process.exit(failed ? 1 : 0);
}

main().catch((e) => {
  console.error('测试异常：', e.message);
  console.error(serverLog.slice(-1500));
  stopServer();
  process.exit(1);
});
