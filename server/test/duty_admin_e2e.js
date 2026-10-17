// 排班管理接口 e2e（P0 #435）
//
// 覆盖管理台「排班管理」周视图背后的接口，以及模板落地：
//   ① GET  /api/admin/duty/week      一页数据（员工行 + 7 天格子 + 班次色板）
//   ② POST /api/admin/duty/cell      单格 upsert（与管理台共用引擎）
//   ③ POST /api/admin/duty/batch     整列填充（默认全员）
//   ④ DELETE /api/admin/duty/cell    删一格
//   ⑤ POST /api/admin/duty/clear-day / clear-range
//   ⑥ 模板 duty_schedule 能通过管理台接口建出来（submit 指向数据源 POST）
//   ⑦ 鉴权：非管理员 403 / 未登录 401
//
//   node test/duty_admin_e2e.js

const { spawn } = require('child_process');
const path = require('path');
const fs = require('fs');
const os = require('os');

const PORT = 3698;
const BASE = `http://127.0.0.1:${PORT}`;
const SERVER_DIR = path.resolve(__dirname, '..');
const DATA_DIR = path.join(os.tmpdir(), 'xiaozhi-duty-admin-' + Date.now());

let passed = 0;
let failed = 0;
const failures = [];

function ok(name, cond, extra) {
  if (cond) {
    passed++;
    console.log(`  ✓ ${name}`);
  } else {
    failed++;
    failures.push(name + (extra ? ` — ${extra}` : ''));
    console.log(`  ✗ ${name}${extra ? '  → ' + extra : ''}`);
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

function todayStr() {
  const tz = process.env.ATT_TIMEZONE || 'Asia/Shanghai';
  return new Intl.DateTimeFormat('en-CA', {
    timeZone: tz, year: 'numeric', month: '2-digit', day: '2-digit',
  }).format(new Date());
}

function dayOffset(n) {
  const [y, mo, d] = todayStr().split('-').map(Number);
  const t = new Date(Date.UTC(y, mo - 1, d + n));
  return `${t.getUTCFullYear()}-${String(t.getUTCMonth() + 1).padStart(2, '0')}-${String(t.getUTCDate()).padStart(2, '0')}`;
}

async function main() {
  fs.mkdirSync(DATA_DIR, { recursive: true });
  const child = spawn(process.execPath, ['src/index.js'], {
    cwd: SERVER_DIR,
    env: {
      ...process.env,
      PORT: String(PORT),
      DATA_DIR,
      DB_PATH: path.join(DATA_DIR, 'test.db'),
      ADMIN_USERNAME: 'admin',
      ADMIN_PASSWORD: 'admin-test-pw',
    },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  child.stdout.on('data', () => {});
  child.stderr.on('data', (d) => process.stderr.write('[server] ' + d));

  const shutdown = () => {
    try { child.kill(); } catch { /* ignore */ }
    try { fs.rmSync(DATA_DIR, { recursive: true, force: true }); } catch { /* ignore */ }
  };
  process.on('exit', shutdown);

  let up = false;
  for (let i = 0; i < 60; i++) {
    try {
      const r = await fetch(BASE + '/api/health');
      if (r.ok) { up = true; break; }
    } catch { /* 还没起来 */ }
    await sleep(200);
  }
  if (!up) throw new Error('服务端未能在 12 秒内启动');

  const admin = (await api('POST', '/api/auth/login', {
    body: { username: 'admin', password: 'admin-test-pw' },
  })).body?.token;
  ok('管理员登录', !!admin);

  await api('PUT', '/api/admin/settings', { token: admin, body: { friendMode: 'work' } });
  const orgId = (await api('POST', '/api/orgs', { token: admin, body: { name: '排班管理测试' } })).body?.id;
  const emp = async (no, nickname) => {
    const rr = await api('POST', `/api/orgs/${orgId}/members`,
      { token: admin, body: { employeeNo: no, nickname, deptId: null } });
    return { id: rr.body?.user?.id, token: (await api('POST', '/api/auth/login', { body: { username: no, password: no } })).body?.token };
  };
  const e1 = await emp('adm01', '张三');
  const e2 = await emp('adm02', '李四');
  const e3 = await emp('adm03', '王五');
  ok('三名组织员工', !!e1.id && !!e2.id && !!e3.id);

  const early = (await api('POST', '/api/admin/attendance/shifts', {
    token: admin,
    body: { name: '早班', workStart: '08:00', workEnd: '16:00', restMinutes: 30, flexMinutes: 0, lateGrace: 5, earlyGrace: 10 },
  })).body?.id;
  const night = (await api('POST', '/api/admin/attendance/shifts', {
    token: admin,
    body: { name: '夜班', workStart: '22:00', workEnd: '06:00', crossDay: true, restMinutes: 60, flexMinutes: 0, lateGrace: 0, earlyGrace: 0 },
  })).body?.id;
  ok('两个班次', !!early && !!night, `early=${early} night=${night}`);

  // ---------------- ① 周视图 ----------------
  console.log('\n① GET /api/admin/duty/week');
  let r = await api('GET', '/api/admin/duty/week', { token: admin });
  ok('周视图 → 200', r.status === 200 && r.body.ok === true, JSON.stringify(r.body).slice(0, 160));
  ok('  7 天列', (r.body?.days || []).length === 7);
  ok('  行 = 组织全员 3 人', (r.body?.users || []).length === 3, `实际 ${(r.body?.users || []).length}`);
  ok('  班次色板含两个班次', (r.body?.shifts || []).length === 2, JSON.stringify(r.body?.shifts?.map((s) => s.name)));
  ok('  空组织时 cells 为空对象', r.body?.cells && Object.keys(r.body.cells).length === 0);
  ok('  workedDays 初始为空', r.body?.workedDays && Object.keys(r.body.workedDays).length === 0);

  r = await api('GET', '/api/admin/duty/week?day=2026-13-45', { token: admin });
  ok('  坏日期 → 400', r.status === 400, JSON.stringify(r.body).slice(0, 100));
  r = await api('GET', '/api/admin/duty/week');
  ok('  未登录 → 401', r.status === 401);

  // ---------------- ② 单格 + 周视图回读 ----------------
  console.log('\n② POST /api/admin/duty/cell + 周视图回读');
  r = await api('POST', '/api/admin/duty/cell', {
    token: admin, body: { day: dayOffset(0), userId: e1.id, shiftId: early, position: '收银' },
  });
  ok('存一格 → 200', r.status === 200 && r.body.ok === true, JSON.stringify(r.body).slice(0, 120));

  r = await api('GET', '/api/admin/duty/week', { token: admin });
  const cell = r.body?.cells?.[`${e1.id}:${dayOffset(0)}`];
  ok('周视图能看到这一格', !!cell && cell.shiftId === early && cell.position === '收银', JSON.stringify(cell));
  ok('  workedDays 计 1 天', r.body?.workedDays?.[e1.id] === 1, JSON.stringify(r.body?.workedDays));

  // ---------------- ③ 批量填充 ----------------
  console.log('\n③ POST /api/admin/duty/batch（整列填充）');
  r = await api('POST', '/api/admin/duty/batch', {
    token: admin, body: { day: dayOffset(1), shiftId: night },
  });
  ok('整列填夜班（默认全员）→ 200', r.status === 200 && r.body.ok === true, JSON.stringify(r.body).slice(0, 120));
  ok('  填了 3 人', r.body?.filled === 3, JSON.stringify(r.body));

  r = await api('POST', '/api/admin/duty/batch', {
    token: admin, body: { day: dayOffset(2), shiftId: null, userIds: [e2.id, e3.id] },
  });
  ok('指定两人填"休息"→ 200', r.status === 200 && r.body.filled === 2, JSON.stringify(r.body));

  r = await api('GET', '/api/admin/duty/week', { token: admin });
  ok('  次日三人都上夜班', [e1.id, e2.id, e3.id].every((id) => r.body?.cells?.[`${id}:${dayOffset(1)}`]?.shiftId === night));
  ok('  第三天后两人休息（rest=true）',
    r.body?.cells?.[`${e2.id}:${dayOffset(2)}`]?.rest === true && r.body?.cells?.[`${e3.id}:${dayOffset(2)}`]?.rest === true);
  ok('  e1 第三天后没排（没有格子，不是"休息"）', !r.body?.cells?.[`${e1.id}:${dayOffset(2)}`]);

  r = await api('POST', '/api/admin/duty/batch', {
    token: admin, body: { day: dayOffset(3), shiftId: 99999 },
  });
  ok('  填不存在的班次 → 400', r.status === 400, JSON.stringify(r.body).slice(0, 100));

  // ---------------- ④ 删一格 / 清一天 / 清一段 ----------------
  console.log('\n④ DELETE cell / clear-day / clear-range');
  r = await api('DELETE', `/api/admin/duty/cell?day=${dayOffset(0)}&userId=${e1.id}`, { token: admin });
  ok('删一格 → 200', r.status === 200 && r.body.deleted === 1, JSON.stringify(r.body));

  r = await api('POST', '/api/admin/duty/clear-day', { token: admin, body: { day: dayOffset(1) } });
  ok('清空一整天（3 条）→ 200', r.status === 200 && r.body.deleted === 3, JSON.stringify(r.body));

  r = await api('POST', '/api/admin/duty/clear-range', {
    token: admin, body: { from: dayOffset(0), to: dayOffset(6) },
  });
  // 此时库里只剩 day2 的 e2/e3 两行（day0 的 e1 已删、day1 已清空）
  ok('清空本周 → 200', r.status === 200 && r.body.deleted === 2, JSON.stringify(r.body));

  r = await api('GET', '/api/admin/duty/week', { token: admin });
  ok('  清完周视图全空', Object.keys(r.body?.cells || {}).length === 0);

  r = await api('POST', '/api/admin/duty/clear-range', {
    token: admin, body: { from: dayOffset(0), to: dayOffset(200) },
  });
  ok('  超大范围 → 400', r.status === 400, JSON.stringify(r.body).slice(0, 100));

  // ---------------- ⑤ 非管理员 ----------------
  console.log('\n⑤ 权限：员工不能动排班管理');
  r = await api('GET', '/api/admin/duty/week', { token: e1.token });
  ok('员工看周视图 → 403', r.status === 403, JSON.stringify(r.body).slice(0, 100));
  r = await api('POST', '/api/admin/duty/cell', {
    token: e1.token, body: { day: dayOffset(0), userId: e1.id, shiftId: early },
  });
  ok('员工改格子 → 403', r.status === 403);

  // ---------------- ⑥ 模板落地 ----------------
  console.log('\n⑥ 模板 duty_schedule 通过管理台接口落地');
  // 真实路径：管理台先拉 templates，用户点一个模板后编辑器被填满，
  // 再 POST /api/admin/modules 整串定义（与手填模块同一个入口）
  const meta = await api('GET', '/api/admin/modules', { token: admin });
  const tpl = (meta.body?.capability?.templates || []).find((t) => t.id === 'duty_schedule');
  ok('管理台能拉到排班表模板', !!tpl, JSON.stringify((meta.body?.capability?.templates || []).map((t) => t.id)));

  r = await api('POST', '/api/admin/modules', { token: admin, body: tpl?.module });
  ok('按模板建排班模块 → 200', r.status === 200 && r.body.ok === true, JSON.stringify(r.body).slice(0, 160));

  const list = (await api('GET', '/api/admin/modules', { token: admin })).body;
  const created = (list?.modules || []).find((m) => m.moduleId === 'duty_schedule');
  ok('  模块在列表里', !!created, JSON.stringify(list?.modules?.map((m) => m.moduleId)));
  if (created) {
    const form = (created.body || []).find((c) => c.component === 'form');
    ok('  表单 submit 指向排班数据源 POST',
      form?.submit?.action === 'api' && form?.submit?.path === '/api/hooks/local/duty/schedules' && form?.submit?.method === 'POST',
      JSON.stringify(form?.submit));
    ok('  员工/班次两个下拉是动态源',
      form?.fields?.find((f) => f.key === 'userId')?.optionsFrom === '/api/hooks/local/work_org/members'
      && form?.fields?.find((f) => f.key === 'shiftId')?.optionsFrom === '/api/hooks/local/duty/shifts',
      JSON.stringify(form?.fields?.map((f) => [f.key, f.optionsFrom])));
  }

  // 员工能收到这个模块（全员可见）：已登录取数走 /api/client/config
  const vis = await api('GET', '/api/client/config', { token: e1.token });
  const mine = (vis.body?.modules || []).find((m) => m.moduleId === 'duty_schedule');
  ok('  员工端能拉到排班模块（全员可见）', !!mine, JSON.stringify(vis.body).slice(0, 160));

  console.log(`\n通过 ${passed} / ${failed}`);
  if (failed) {
    console.log('失败项：');
    for (const f of failures) console.log('  - ' + f);
  }
  process.exit(failed ? 1 : 0);
}

main().catch((e) => {
  console.error('e2e 异常：', e);
  process.exit(1);
});
