// 排班数据源 e2e（P0 #434）
//
// 覆盖「本服务器数据源」的写入口与排班窗口：
//   ① GET /api/hooks/local/duty/schedules —— 默认展示今天起 7 天；?day= 看任意一周
//   ② GET /api/hooks/local/duty/shifts     —— 表单下拉用的班次（label/value 直出）
//   ③ POST .../duty/schedules              —— 表单即录入（admin 可写）
//   ④ 权限与校验分支：员工写 403 / 只读源 405 / 未登录 401 / 坏日期 400 /
//      组织外人 400 / 停用班次 400 / 不存在的源 404
//
//   node test/duty_source_e2e.js

const { spawn } = require('child_process');
const path = require('path');
const fs = require('fs');
const os = require('os');

const PORT = 3697;
const BASE = `http://127.0.0.1:${PORT}`;
const SERVER_DIR = path.resolve(__dirname, '..');
const DATA_DIR = path.join(os.tmpdir(), 'xiaozhi-duty-e2e-' + Date.now());

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

// 与服务端 attendance.today() 同口径（Asia/Shanghai 或 ATT_TIMEZONE）：
// 硬编码日期会让测试在服务器换时区/跨零点后集体造假绿
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

  // 组织外的普通用户：必须在切工作模式**之前**注册 —— 工作模式下自助注册
  // 被刻意关闭（账号由管理员按工号录入），这是产品纪律不是 bug
  const regOut = await api('POST', '/api/auth/register', { body: { username: 'outsider', password: 'pass123456', nickname: '外人' } });
  const outLogin = await api('POST', '/api/auth/login', { body: { username: 'outsider', password: 'pass123456' } });
  const outsider = outLogin.body?.token;
  const outsiderId = outLogin.body?.user?.id;
  ok('先注册一个组织外用户（普通模式）', !!outsider && !!outsiderId,
    `reg=${regOut.status} login=${outLogin.status} ${JSON.stringify(outLogin.body).slice(0, 120)}`);

  // ---------------- 现场：组织 + 员工 + 班次 ----------------
  const adminLogin = (await api('POST', '/api/auth/login', {
    body: { username: 'admin', password: 'admin-test-pw' },
  })).body;
  const admin = adminLogin.token;
  ok('管理员登录', !!admin);

  await api('PUT', '/api/admin/settings', { token: admin, body: { friendMode: 'work' } });
  const orgId = (await api('POST', '/api/orgs', { token: admin, body: { name: '排班测试组织' } })).body?.id;
  ok('创建组织', !!orgId);

  async function addEmp(no, nickname) {
    const rr = await api('POST', `/api/orgs/${orgId}/members`,
      { token: admin, body: { employeeNo: no, nickname, deptId: null } });
    const tok = (await api('POST', '/api/auth/login', { body: { username: no, password: no } })).body?.token;
    return { id: rr.body?.user?.id, token: tok };
  }
  const e1 = await addEmp('dutye1', '张三');
  const e2 = await addEmp('dutye2', '李四');
  ok('两名组织员工 + 组织外用户就绪', !!e1.id && !!e2.id && !!outsider, JSON.stringify([e1.id, e2.id]));

  const early = (await api('POST', '/api/admin/attendance/shifts', {
    token: admin,
    body: { name: '早班', workStart: '08:00', workEnd: '16:00', restMinutes: 30, flexMinutes: 0, lateGrace: 5, earlyGrace: 10 },
  })).body?.id;
  const night = (await api('POST', '/api/admin/attendance/shifts', {
    token: admin,
    body: { name: '夜班', workStart: '22:00', workEnd: '06:00', crossDay: true, restMinutes: 60, flexMinutes: 0, lateGrace: 0, earlyGrace: 0 },
  })).body?.id;
  const off = (await api('POST', '/api/admin/attendance/shifts', {
    token: admin,
    body: { name: '停用班', workStart: '09:00', workEnd: '18:00', restMinutes: 0, flexMinutes: 0, lateGrace: 0, earlyGrace: 0 },
  })).body?.id;
  ok('建三个班次（早班/夜班/停用班）', !!early && !!night && !!off, `early=${early} night=${night} off=${off}`);
  // 把「停用班」停掉。🔴 PUT 要发**全量**字段：shiftPayload 按整单校验，
  // 只发 { enabled:false } 会被当成缺字段打回，班次根本没停 —— 而测试
  // 会以为"停用班能被排进去"是引擎放水，其实是现场没造出来。
  const offResp = await api('PUT', `/api/admin/attendance/shifts/${off}`, {
    token: admin,
    body: { name: '停用班', workStart: '09:00', workEnd: '18:00', restMinutes: 0, flexMinutes: 0, lateGrace: 0, earlyGrace: 0, crossDay: false, enabled: false },
  });
  ok('  停用班已停用', offResp.status === 200 && offResp.body.ok === true, JSON.stringify(offResp.body).slice(0, 120));

  // ---------------- ① POST 写入 ----------------
  console.log('\n① 表单即录入：POST /api/hooks/local/duty/schedules');
  let r = await api('POST', '/api/hooks/local/duty/schedules', {
    token: admin, body: { day: dayOffset(0), userId: e1.id, shiftId: early, position: '收银', note: '顶班' },
  });
  ok('管理员 POST 一条排班 → 200', r.status === 200 && r.body.ok === true, JSON.stringify(r.body).slice(0, 160));
  ok('  回包带回写入结果（day/userId/shiftId）',
    r.body?.result?.day === dayOffset(0) && r.body?.result?.userId === e1.id && r.body?.result?.shiftId === early,
    JSON.stringify(r.body?.result));

  r = await api('POST', '/api/hooks/local/duty/schedules', {
    token: admin, body: { day: dayOffset(1), userId: e2.id, shiftId: night },
  });
  ok('第二天夜班（跨天班）→ 200', r.status === 200 && r.body.ok === true, JSON.stringify(r.body).slice(0, 160));

  // 同一天同人再 POST = 更新（表单重复提交不能变两行）
  r = await api('POST', '/api/hooks/local/duty/schedules', {
    token: admin, body: { day: dayOffset(0), userId: e1.id, shiftId: night, position: '防损' },
  });
  ok('同人同日重复提交 → 200（upsert）', r.status === 200 && r.body.ok === true);

  // 休息 = shiftId 空
  r = await api('POST', '/api/hooks/local/duty/schedules', {
    token: admin, body: { day: dayOffset(2), userId: e2.id, shiftId: '' },
  });
  ok('shiftId 传空 = 排"休息" → 200', r.status === 200 && r.body.ok === true, JSON.stringify(r.body).slice(0, 160));

  // ---------------- ② GET 取数 ----------------
  console.log('\n② 取数：GET 排班表（默认今天起 7 天）');
  r = await api('GET', '/api/hooks/local/duty/schedules', { token: admin });
  ok('GET → 200 且形状 {ok,data:{rows,total}}',
    r.status === 200 && r.body.ok === true && Array.isArray(r.body?.data?.rows), JSON.stringify(r.body).slice(0, 120));
  const rows = r.body?.data?.rows || [];
  ok('  窗口内 3 条（e1×2 + e2×2 中去重后…按实际写入 3 条）', rows.length === 3, `实际 ${rows.length} 条`);
  ok('  默认不含 7 天前的旧数据', rows.every((x) => x.day >= dayOffset(0) && x.day <= dayOffset(6)));
  const e1today = rows.find((x) => x.userId === e1.id && x.day === dayOffset(0));
  ok('  upsert 后 e1 今天是夜班（不是早班）', e1today?.shift === '夜班 22:00-06:00（次日）', JSON.stringify(e1today));
  ok('  岗位/备注跟着更新', e1today?.position === '防损', JSON.stringify(e1today));
  const e2rest = rows.find((x) => x.userId === e2.id && x.day === dayOffset(2));
  ok('  e2 后天显示"休息"', e2rest?.shift === '休息', JSON.stringify(e2rest));

  // ?day= 看任意一周
  r = await api('GET', `/api/hooks/local/duty/schedules?day=${dayOffset(0)}`, { token: e1.token });
  ok('员工也能读排班表（module:all）→ 200', r.status === 200 && r.body.ok === true, JSON.stringify(r.body).slice(0, 120));
  ok('  员工看到同样的行', (r.body?.data?.rows || []).length === 3);

  r = await api('GET', `/api/hooks/local/duty/schedules?day=${dayOffset(-14)}`, { token: admin });
  ok('?day= 看两周前 → 0 条（那天没排）',
    r.status === 200 && (r.body?.data?.rows || []).length === 0, JSON.stringify(r.body?.data?.total));

  r = await api('GET', '/api/hooks/local/duty/schedules', {});
  ok('未登录 GET → 401', r.status === 401);
  r = await api('GET', '/api/hooks/local/duty/nope', { token: admin });
  ok('不存在的数据源 → 404', r.status === 404 && /没有这个数据源/.test(r.body?.error || ''), JSON.stringify(r.body));
  r = await api('GET', '/api/hooks/local/../duty/schedules', { token: admin });
  ok('路径穿越样式 → 400（正则先拦）', r.status === 400 || r.status === 404);

  // ---------------- ③ 班次下拉源 ----------------
  console.log('\n③ 表单下拉：GET duty/shifts');
  r = await api('GET', '/api/hooks/local/duty/shifts', { token: e1.token });
  ok('员工能取班次列表（表单下拉用）', r.status === 200 && r.body.ok === true);
  const shifts = r.body?.data?.rows || [];
  // 3 个真班次 + 1 行"休息"哨兵（rowsFirst，给表单下拉当"不排班"选项）
  ok('  三个班次 + 休息选项全在', shifts.length === 4, `实际 ${shifts.length}`);
  ok('  "休息"是第一行（下拉里排最前）', shifts[0]?.value === 'rest' && /休息/.test(shifts[0]?.label || ''), JSON.stringify(shifts[0]));
  ok('  每行有 label/value（客户端零加工）',
    shifts.every((s) => typeof s.label === 'string' && s.value !== undefined), JSON.stringify(shifts[1]));
  ok('  停用班标注"（已停用）"', shifts.find((s) => s.value === off)?.label.includes('（已停用）'),
    JSON.stringify(shifts.find((s) => s.value === off)));
  ok('  夜班展示带"次日"', (shifts.find((s) => s.value === night)?.label || '').includes('（次日）'));

  // ---------------- ④ 写权限与校验分支 ----------------
  console.log('\n④ 写入的权限与校验分支');
  r = await api('POST', '/api/hooks/local/duty/schedules', {
    token: e1.token, body: { day: dayOffset(0), userId: e1.id, shiftId: early },
  });
  ok('普通员工 POST → 403（排班只有管理员能改）', r.status === 403, JSON.stringify(r.body).slice(0, 120));

  r = await api('POST', '/api/hooks/local/work_org/members', {
    token: admin, body: { day: dayOffset(0), userId: e1.id },
  });
  ok('往只读源 POST → 405', r.status === 405, JSON.stringify(r.body).slice(0, 120));

  r = await api('POST', '/api/hooks/local/duty/schedules', { body: { day: dayOffset(0), userId: e1.id, shiftId: early } });
  ok('未登录 POST → 401', r.status === 401);

  const bad = [
    ['坏日期 2026-13-45', { day: '2026-13-45', userId: e1.id, shiftId: early }],
    ['缺日期', { userId: e1.id, shiftId: early }],
    ['员工不存在', { day: dayOffset(0), userId: 99999, shiftId: early }],
    ['组织外用户', { day: dayOffset(0), userId: outsiderId, shiftId: early }],
    ['班次不存在', { day: dayOffset(0), userId: e1.id, shiftId: 99999 }],
    ['停用班次', { day: dayOffset(0), userId: e1.id, shiftId: off }],
  ];
  for (const [name, body] of bad) {
    const rr = await api('POST', '/api/hooks/local/duty/schedules', { token: admin, body });
    ok(`  ${name} → 400`, rr.status === 400, JSON.stringify(rr.body).slice(0, 120));
  }

  // 停用班那条被拒后，库里 e1 今天应该还是夜班（没被脏写覆盖）
  r = await api('GET', '/api/hooks/local/duty/schedules', { token: admin });
  const still = (r.body?.data?.rows || []).find((x) => x.userId === e1.id && x.day === dayOffset(0));
  ok('  被拒的写入没有脏进库（e1 今天仍是夜班）', still?.shift === '夜班 22:00-06:00（次日）', JSON.stringify(still));

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
