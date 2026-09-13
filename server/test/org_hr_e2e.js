// 组织机构人事扩展（部门 / 岗位 / 批量导入）—— 端到端测试
//
//   node test/org_hr_e2e.js
//
// 套用工厂 V2 人事模型：部门（父子层级+排序）→ 岗位（可挂部门）→
// 员工（users 挂 dept_id/position_id）。覆盖：部门 CRUD 与环检测/删除护栏、
// 岗位 CRUD、录员工带部门岗位、改员工、批量导入（自动建部门岗位、
// 重号跳过、坏行跳过不整批回滚）。

const { spawn } = require('child_process');
const path = require('path');
const fs = require('fs');
const os = require('os');

const PORT = 3699;
const BASE = `http://127.0.0.1:${PORT}`;
const SERVER_DIR = path.resolve(__dirname, '..');
const DATA_DIR = path.join(os.tmpdir(), 'xiaozhi-org-hr-e2e-' + Date.now());

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
  console.log('[org-hr E2E] 服务端已就绪 ' + BASE + '\n');

  let r = await api('POST', '/api/auth/login', { body: { username: 'admin', password: 'admin123' } });
  const admin = r.body?.token;
  ok('管理员登录', !!admin, JSON.stringify(r.body));

  // 开工作模式 + 建组织
  await api('PUT', '/api/admin/settings', { token: admin, body: { friendMode: 'work' } });
  r = await api('POST', '/api/orgs', { token: admin, body: { name: '盛京食品厂' } });
  const orgId = r.body?.id;
  ok('创建组织', r.status === 200 && !!orgId, JSON.stringify(r.body));

  // ---------------- 一：部门管理 ----------------
  console.log('\n【一】部门管理');
  r = await api('GET', '/api/orgs/depts', { token: admin });
  ok('空部门列表', r.status === 200 && Array.isArray(r.body) && r.body.length === 0, JSON.stringify(r.body));

  r = await api('POST', '/api/orgs/depts', { token: admin, body: { name: '生产部', sort: 1 } });
  const prodDept = r.body?.id;
  ok('建顶级部门「生产部」', r.status === 200 && !!prodDept, JSON.stringify(r.body));
  r = await api('POST', '/api/orgs/depts', { token: admin, body: { name: '包装车间', parentId: prodDept, sort: 1 } });
  const packDept = r.body?.id;
  ok('建子部门「包装车间」', r.status === 200 && !!packDept, JSON.stringify(r.body));
  r = await api('POST', '/api/orgs/depts', { token: admin, body: { name: '质检部', sort: 2 } });
  const qcDept = r.body?.id;
  ok('建顶级部门「质检部」', r.status === 200 && !!qcDept, JSON.stringify(r.body));

  r = await api('POST', '/api/orgs/depts', { token: admin, body: { name: '' } });
  ok('空名部门被拒', r.status === 400, JSON.stringify(r.body));
  r = await api('POST', '/api/orgs/depts', { token: admin, body: { name: '幽灵', parentId: 99999 } });
  ok('上级不存在被拒', r.status === 400, JSON.stringify(r.body));

  r = await api('PUT', `/api/orgs/depts/${prodDept}`, { token: admin, body: { parentId: packDept } });
  ok('上级设为自己的子部门 → 400（成环检测）', r.status === 400 && /子部门/.test(r.body.error || ''), JSON.stringify(r.body));
  r = await api('PUT', `/api/orgs/depts/${prodDept}`, { token: admin, body: { parentId: prodDept } });
  ok('上级设为自身 → 400', r.status === 400, JSON.stringify(r.body));
  r = await api('PUT', `/api/orgs/depts/${prodDept}`, { token: admin, body: { name: '生产中心' } });
  ok('改部门名', r.status === 200, JSON.stringify(r.body));

  r = await api('DELETE', `/api/orgs/depts/${prodDept}`, { token: admin });
  ok('有子部门的部门不能删', r.status === 400 && /子部门/.test(r.body.error || ''), JSON.stringify(r.body));

  // ---------------- 二：岗位管理 ----------------
  console.log('\n【二】岗位管理');
  r = await api('POST', '/api/orgs/positions', { token: admin, body: { name: '包装工', deptId: packDept } });
  const posPack = r.body?.id;
  ok('建岗位「包装工」挂包装车间', r.status === 200 && !!posPack, JSON.stringify(r.body));
  r = await api('POST', '/api/orgs/positions', { token: admin, body: { name: '质检员', deptId: qcDept } });
  const posQc = r.body?.id;
  ok('建岗位「质检员」挂质检部', r.status === 200 && !!posQc, JSON.stringify(r.body));

  r = await api('GET', '/api/orgs/positions', { token: admin });
  ok('岗位列表带部门名',
    r.body.length === 2 && r.body.some((p) => p.dept_name === '包装车间'), JSON.stringify(r.body));

  r = await api('PUT', `/api/orgs/positions/${posPack}`, { token: admin, body: { name: '高级包装工' } });
  ok('改岗位名', r.status === 200, JSON.stringify(r.body));

  // ---------------- 三：录员工带部门/岗位 + 编辑 ----------------
  console.log('\n【三】录员工带部门/岗位 + 编辑');
  r = await api('POST', `/api/orgs/${orgId}/members`, {
    token: admin, body: { employeeNo: 'emp001', nickname: '张一', deptId: packDept, positionId: posPack },
  });
  ok('录 emp001（包装车间/包装工）', r.status === 200 && r.body.user?.dept_name === '包装车间', JSON.stringify(r.body));

  r = await api('POST', `/api/orgs/${orgId}/members`, {
    token: admin, body: { employeeNo: 'emp002', nickname: '李二', deptId: 99999 },
  });
  ok('部门不存在 → 400', r.status === 400, JSON.stringify(r.body));

  r = await api('POST', `/api/orgs/${orgId}/members`, { token: admin, body: { employeeNo: 'emp002', nickname: '李二', deptId: qcDept, positionId: posQc } });
  ok('录 emp002（质检部）', r.status === 200, JSON.stringify(r.body));

  const emp2Id = r.body?.user?.id;
  r = await api('PUT', `/api/orgs/${orgId}/members/${emp2Id}`, { token: admin, body: { deptId: packDept, nickname: '李二丰' } });
  ok('编辑员工：调部门+改昵称',
    r.status === 200 && r.body.user?.dept_name === '包装车间' && r.body.user?.nickname === '李二丰', JSON.stringify(r.body));

  r = await api('PUT', `/api/orgs/${orgId}/members/${emp2Id}`, { token: admin, body: { positionId: 88888 } });
  ok('编辑到不存在的岗位 → 400', r.status === 400, JSON.stringify(r.body));

  // 删除护栏：有员工的部门/岗位不能删
  r = await api('DELETE', `/api/orgs/depts/${packDept}`, { token: admin });
  ok('有员工的部门不能删', r.status === 400 && /员工/.test(r.body.error || ''), JSON.stringify(r.body));
  r = await api('DELETE', `/api/orgs/positions/${posQc}`, { token: admin });
  ok('有员工的岗位不能删（emp2 还挂着质检员）', r.status === 400 && /员工/.test(r.body.error || ''), JSON.stringify(r.body));
  r = await api('PUT', `/api/orgs/${orgId}/members/${emp2Id}`, { token: admin, body: { positionId: null } });
  ok('清空员工岗位', r.status === 200 && r.body.user?.position_name == null, JSON.stringify(r.body));
  r = await api('DELETE', `/api/orgs/positions/${posQc}`, { token: admin });
  ok('岗位没人后可删', r.status === 200, JSON.stringify(r.body));

  // ---------------- 四：批量导入 ----------------
  console.log('\n【四】批量导入');
  r = await api('POST', `/api/orgs/${orgId}/members/import`, {
    token: admin,
    body: {
      rows: [
        { employeeNo: 'emp010', nickname: '王十', dept: '生产中心', position: '包装工' },
        { employeeNo: 'emp011', nickname: '王十一', dept: '生产中心', position: '包装工' },
        { employeeNo: 'emp012', nickname: '赵十二', dept: '销售部', position: '业务员' },
        { employeeNo: 'x', nickname: '坏工号' },
        { employeeNo: 'emp001', nickname: '重号' },
        { employeeNo: 'admin', nickname: '撞管理员' },
      ],
    },
  });
  ok('导入：成功 3 行',
    r.status === 200 && r.body.created === 3, JSON.stringify(r.body));
  ok('导入：跳过 3 行且带原因',
    r.body.skipped?.length === 3 && r.body.skipped.every((s) => s.reason), JSON.stringify(r.body.skipped));
  ok('导入：自动建「销售部」（生产中心已存在复用）',
    r.body.newDepts?.includes('销售部') && !r.body.newDepts.includes('生产中心'), JSON.stringify(r.body.newDepts));

  // 导入的员工部门/岗位正确 + 能登录
  r = await api('POST', '/api/auth/login', { body: { username: 'emp012', password: 'emp012' } });
  ok('导入员工 emp012 初始密码=工号可登录', !!r.body?.token, JSON.stringify(r.body));
  const emp12 = r.body?.token;
  r = await api('GET', '/api/orgs/my', { token: emp12 });
  const me12 = (r.body?.members || []).find((m) => m.username === 'emp012');
  ok('emp012 部门=销售部、岗位=业务员',
    me12?.dept_name === '销售部' && me12?.position_name === '业务员', JSON.stringify(me12));

  // 导入的员工互为好友（emp010 与 emp011）
  r = await api('POST', '/api/auth/login', { body: { username: 'emp010', password: 'emp010' } });
  const emp10 = r.body?.token;
  r = await api('GET', '/api/friends', { token: emp10 });
  const has11 = (r.body?.friends || []).some((f) => f.username === 'emp011');
  ok('导入员工之间自动互为好友', r.status === 200 && has11, JSON.stringify(r.body?.friends?.map?.((f) => f.username)));

  // my 接口带出 depts/positions（客户端分组用）
  r = await api('GET', '/api/orgs/my', { token: admin });
  ok('my 返回 depts/positions 全集',
    Array.isArray(r.body?.depts) && r.body.depts.length >= 3 && Array.isArray(r.body?.positions), JSON.stringify(r.body?.depts));

  // 空导入被拒
  r = await api('POST', `/api/orgs/${orgId}/members/import`, { token: admin, body: { rows: [] } });
  ok('空导入 → 400', r.status === 400, JSON.stringify(r.body));

  // 员工不能调管理接口
  r = await api('POST', '/api/orgs/depts', { token: emp10, body: { name: '私自建部' } });
  ok('普通员工建部门 → 403', r.status === 403, JSON.stringify(r.body));

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
