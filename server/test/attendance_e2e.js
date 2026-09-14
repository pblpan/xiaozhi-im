// 考勤引擎（工作模式随动启用）—— 端到端测试
//
//   node test/attendance_e2e.js
//
// 覆盖：门禁（普通模式 / 考勤停用 / 管理员无考勤资格 / 未登录）、默认班次兜底、
// 打卡（重复打卡=更新、时间以服务器为准、定位要求）、单日判定（正常/迟到/早退/
// 迟到早退/缺卡/缺勤/请假/休息日/进行中）、跨天夜班、请假与补卡审批后对统计的影响、
// 考勤组（按部门纳入含子部门、显式成员优先、删除护栏）、区间报表与部门过滤、
// 权限隔离、应用中心下发。
//
// 【判定用例为什么全部用"管理员给历史日期补卡"来构造】
// 单日判定要验证的是"9:30 打上班卡算迟到 30 分钟"这类**既定事实**。
// 如果用"现在就打卡"来测，结果会随测试运行的时刻变化（早上跑是正常、
// 下午跑是迟到），断言就成了看运气。补历史日期则完全可控：
// 昨天一定是过去的一天，9:30 一定晚于 9:00。所以判定与报表相关的用例
// 一律走 /api/admin/attendance/records 造数据，只有"打卡接口本身"用真打卡。

const { spawn } = require('child_process');
const path = require('path');
const fs = require('fs');
const os = require('os');

const PORT = 3701;
const BASE = `http://127.0.0.1:${PORT}`;
const SERVER_DIR = path.resolve(__dirname, '..');
const DATA_DIR = path.join(os.tmpdir(), 'xiaozhi-att-e2e-' + Date.now());

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

/** 'YYYY-MM-DD'（相对今天偏移；测试机与服务器同为北京时间） */
function dayStr(offset = 0) {
  const d = new Date(Date.now() + offset * 86400000);
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
}
function weekdayOf(day) {
  const [y, m, d] = day.split('-').map(Number);
  return new Date(Date.UTC(y, m - 1, d)).getUTCDay();
}
/** 某天某时刻的时间戳（北京时区固定 +08:00，与服务器一致） */
function tsAt(day, hhmm) { return new Date(`${day}T${hhmm}:00+08:00`).getTime(); }

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

function stopServer() {
  if (serverProc) { try { serverProc.kill(); } catch { /* ignore */ } }
  try { fs.rmSync(DATA_DIR, { recursive: true, force: true }); } catch { /* ignore */ }
}

(async () => {
  await startServer();
  console.log('[attendance E2E] 服务端已就绪 ' + BASE + '\n');

  let r = await api('POST', '/api/auth/login', { body: { username: 'admin', password: 'admin123' } });
  const admin = r.body?.token;
  ok('管理员登录', !!admin, JSON.stringify(r.body));

  const Y1 = dayStr(-1);   // 昨天
  const Y2 = dayStr(-2);   // 前天
  const Y3 = dayStr(-3);   // 大前天
  const TODAY = dayStr(0);

  // ---------------- 一：门禁（普通模式） ----------------
  console.log('\n【一】门禁：普通模式');
  r = await api('GET', '/api/attendance/today', { token: admin });
  ok('普通模式 today → available:false', r.status === 200 && r.body.available === false, JSON.stringify(r.body));
  ok('  且原因指向普通模式', /普通好友模式/.test(r.body.reason || ''), r.body.reason);
  r = await api('GET', '/api/attendance/today');
  ok('未登录 today → 401', r.status === 401);

  // 建组织 + 录员工
  await api('PUT', '/api/admin/settings', { token: admin, body: { friendMode: 'work' } });
  r = await api('POST', '/api/orgs', { token: admin, body: { name: '盛京食品厂' } });
  const orgId = r.body?.id;
  ok('创建组织', r.status === 200 && !!orgId, JSON.stringify(r.body));

  r = await api('POST', '/api/orgs/depts', { token: admin, body: { name: '生产部', sort: 1 } });
  const prodDept = r.body?.id;
  r = await api('POST', '/api/orgs/depts', { token: admin, body: { name: '包装车间', parentId: prodDept, sort: 1 } });
  const packDept = r.body?.id;
  ok('建部门「生产部」+ 子部门「包装车间」', !!prodDept && !!packDept, JSON.stringify(r.body));

  async function addEmp(no, nickname, deptId) {
    const rr = await api('POST', `/api/orgs/${orgId}/members`,
      { token: admin, body: { employeeNo: no, nickname, deptId: deptId || null } });
    const tok = (await api('POST', '/api/auth/login', { body: { username: no, password: no } })).body?.token;
    return { id: rr.body?.user?.id, token: tok, no };
  }
  const e1 = await addEmp('emp01', '张三', packDept);
  const e2 = await addEmp('emp02', '李四', prodDept);
  ok('录员工 emp01/emp02 并能登录', !!e1.id && !!e1.token && !!e2.id, JSON.stringify([e1.id, e2.id]));

  // 默认班次 09:00-18:00，工作日设成全周（判定用例需要"昨天一定是工作日"）
  await api('PUT', '/api/admin/attendance/config', {
    token: admin, body: { workdays: [0, 1, 2, 3, 4, 5, 6], enabled: true },
  });

  // ---------------- 二：默认班次兜底 ----------------
  console.log('\n【二】默认班次兜底（没建任何考勤组也能打卡）');
  r = await api('GET', '/api/attendance/today', { token: e1.token });
  ok('员工 today → available:true', r.status === 200 && r.body.available === true, JSON.stringify(r.body).slice(0, 200));
  ok('  班次来源 = default', r.body.shiftSource === 'default', r.body.shiftSource);
  ok('  默认班次 09:00-18:00', r.body.shift?.workStart === '09:00' && r.body.shift?.workEnd === '18:00', JSON.stringify(r.body.shift));
  ok('  无考勤组', r.body.group === null, JSON.stringify(r.body.group));

  r = await api('PUT', '/api/admin/attendance/config',
    { token: admin, body: { defaultShift: { workStart: '08:30', workEnd: '17:30', restMinutes: 60, flexMinutes: 0, lateGrace: 0, earlyGrace: 0 } } });
  ok('改默认班次 → 200', r.status === 200, JSON.stringify(r.body));
  r = await api('GET', '/api/attendance/today', { token: e1.token });
  ok('  员工看到新上班时间 08:30', r.body.shift?.workStart === '08:30', JSON.stringify(r.body.shift));
  r = await api('PUT', '/api/admin/attendance/config',
    { token: admin, body: { defaultShift: { workStart: '09:00', workEnd: '18:00', restMinutes: 60, flexMinutes: 0, lateGrace: 0, earlyGrace: 0 } } });
  ok('恢复默认班次 09:00-18:00', r.status === 200);
  r = await api('PUT', '/api/admin/attendance/config', { token: admin, body: { defaultShift: { workStart: '25:00', workEnd: '18:00' } } });
  ok('非法上班时间被拒', r.status === 400, JSON.stringify(r.body));
  r = await api('PUT', '/api/admin/attendance/config', { token: admin, body: { workdays: [1, 9] } });
  ok('非法星期被拒', r.status === 400, JSON.stringify(r.body));

  // ---------------- 三：打卡接口 ----------------
  console.log('\n【三】打卡');
  r = await api('POST', '/api/attendance/clock', { token: e1.token, body: { type: 'in' } });
  ok('上班打卡成功', r.status === 200 && r.body.ok === true, JSON.stringify(r.body).slice(0, 200));
  const firstAt = r.body?.record?.at;
  ok('  返回 message 含"上班打卡成功"', /上班打卡成功/.test(r.body.message || ''), r.body.message);
  ok('  打卡类型 in', r.body.record?.type === 'in', JSON.stringify(r.body.record));

  r = await api('GET', `/api/attendance/records?day=${TODAY}`, { token: e1.token });
  ok('  今日流水 1 条', r.body.items?.length === 1, JSON.stringify(r.body.items));

  await sleep(1100);
  r = await api('POST', '/api/attendance/clock', { token: e1.token, body: { type: 'in' } });
  ok('重复打上班卡 → updated:true', r.body.updated === true, JSON.stringify(r.body).slice(0, 160));
  ok('  打卡时间被刷新（晚于第一次）', r.body.record?.at > firstAt, `${firstAt} → ${r.body.record?.at}`);
  r = await api('GET', `/api/attendance/records?day=${TODAY}`, { token: e1.token });
  ok('  流水仍是 1 条（更新而非新增）', r.body.items?.length === 1, JSON.stringify(r.body.items));

  // 客户端传 at 必须被忽略（否则改手机时间就能补卡）
  r = await api('POST', '/api/attendance/clock',
    { token: e2.token, body: { type: 'in', at: tsAt(TODAY, '06:00') } });
  ok('客户端传的 at 被忽略（以服务器时钟为准）',
    r.status === 200 && Math.abs(r.body.record.at - Date.now()) < 60000, JSON.stringify(r.body.record));

  r = await api('POST', '/api/attendance/clock', { token: e1.token, body: { type: 'sideways' } });
  ok('非法打卡类型 → 400', r.status === 400, JSON.stringify(r.body));
  r = await api('POST', '/api/attendance/clock', { token: admin, body: { type: 'in' } });
  ok('管理员打卡 → 403（无考勤资格）', r.status === 403, JSON.stringify(r.body));

  r = await api('POST', '/api/attendance/clock',
    { token: e1.token, body: { type: 'out', lat: 45.5, lng: 126.9, address: '黑龙江海伦' } });
  ok('下班打卡带定位成功', r.status === 200 && r.body.record?.address === '黑龙江海伦', JSON.stringify(r.body.record));
  r = await api('GET', `/api/attendance/records?day=${TODAY}`, { token: e1.token });
  const outRec = r.body.items.find((x) => x.type === 'out');
  ok('  定位被记录', outRec?.lat === 45.5 && outRec?.lng === 126.9, JSON.stringify(outRec));

  r = await api('GET', '/api/attendance/today', { token: e1.token });
  ok('today 显示今日两张卡', !!r.body.cards.in && !!r.body.cards.out, JSON.stringify(r.body.cards));
  // 今天还没到下班时间：只报"既成事实"（迟到），且**不能**判早退 ——
  // 一个 10:41 打的下班卡相对 18:00 是"早退 439 分钟"，但下班时间根本还没到，
  // 判早退就是错的（这正是"上午打开 App 全公司缺卡"那类 bug 的同源问题）。
  ok('  今日状态：未到点只报已确定的问题（pending 或 late）',
    ['pending', 'late'].includes(r.body.today.status), JSON.stringify(r.body.today));
  ok('  今日不判早退（下班时间未到，早退不成立）', r.body.today.earlyMinutes === 0, JSON.stringify(r.body.today));

  // ---------------- 四：单日判定（用历史补卡构造既定事实） ----------------
  console.log('\n【四】单日判定（管理员给历史日期补卡）');

  async function fix(uid, day, type, hhmm) {
    return api('POST', '/api/admin/attendance/records',
      { token: admin, body: { userId: uid, day, type, time: hhmm } });
  }
  async function statusOf(day, userId) {
    const rr = await api('GET', `/api/admin/attendance/report?from=${day}&to=${day}`, { token: admin });
    const u = (rr.body.users || []).find((x) => x.userId === userId);
    return u?.days?.[0];
  }

  // 正常：8:50 上班 / 18:05 下班
  r = await fix(e1.id, Y1, 'in', '08:50');
  ok('补上班卡 08:50 → 200', r.status === 200, JSON.stringify(r.body));
  await fix(e1.id, Y1, 'out', '18:05');
  let d = await statusOf(Y1, e1.id);
  ok('8:50/18:05 → normal', d?.status === 'normal', JSON.stringify(d));

  // 迟到 30 分钟
  await fix(e1.id, Y2, 'in', '09:30');
  await fix(e1.id, Y2, 'out', '18:00');
  d = await statusOf(Y2, e1.id);
  ok('9:30 上班 → late', d?.status === 'late', JSON.stringify(d));
  ok('  迟到分钟 = 30', d?.lateMinutes === 30, String(d?.lateMinutes));

  // 早退 60 分钟
  await fix(e1.id, Y3, 'in', '08:55');
  await fix(e1.id, Y3, 'out', '17:00');
  d = await statusOf(Y3, e1.id);
  ok('17:00 下班 → early', d?.status === 'early', JSON.stringify(d));
  ok('  早退分钟 = 60', d?.earlyMinutes === 60, String(d?.earlyMinutes));

  // 迟到 + 早退
  const Y4 = dayStr(-4);
  await fix(e1.id, Y4, 'in', '09:20');
  await fix(e1.id, Y4, 'out', '17:30');
  d = await statusOf(Y4, e1.id);
  ok('迟到 20 + 早退 30 → late_early', d?.status === 'late_early', JSON.stringify(d));

  // 只打上班卡 → 缺下班卡
  const Y5 = dayStr(-5);
  await fix(e2.id, Y5, 'in', '08:58');
  d = await statusOf(Y5, e2.id);
  ok('只打上班卡 → missing（缺下班卡）', d?.status === 'missing', JSON.stringify(d));
  ok('  说明指向"缺下班卡"', /缺下班卡/.test(d?.note || ''), d?.note);

  // 一张卡都没打 → 缺勤
  d = await statusOf(Y1, e2.id);
  ok('两张卡都没有 → absent', d?.status === 'absent', JSON.stringify(d));

  // 迟到宽限：默认班次 lateGrace=10 → 9:05 不算迟到
  await api('PUT', '/api/admin/attendance/config',
    { token: admin, body: { defaultShift: { workStart: '09:00', workEnd: '18:00', restMinutes: 60, flexMinutes: 0, lateGrace: 10, earlyGrace: 0 } } });
  const Y6 = dayStr(-6);
  await fix(e2.id, Y6, 'in', '09:05');
  await fix(e2.id, Y6, 'out', '18:00');
  d = await statusOf(Y6, e2.id);
  ok('宽限 10 分钟内 9:05 → normal', d?.status === 'normal', JSON.stringify(d));
  await api('PUT', '/api/admin/attendance/config',
    { token: admin, body: { defaultShift: { workStart: '09:00', workEnd: '18:00', restMinutes: 60, flexMinutes: 0, lateGrace: 0, earlyGrace: 0 } } });

  // 休息日：把昨天那一星期几排除出工作日
  const wd = weekdayOf(Y1);
  await api('PUT', '/api/admin/attendance/config',
    { token: admin, body: { workdays: [0, 1, 2, 3, 4, 5, 6].filter((x) => x !== wd) } });
  d = await statusOf(Y1, e1.id);
  ok('把昨天设为休息日 → rest', d?.status === 'rest', JSON.stringify(d));
  ok('  休息日不判缺勤（e2 仍非 absent）', (await statusOf(Y1, e2.id))?.status === 'rest');
  await api('PUT', '/api/admin/attendance/config',
    { token: admin, body: { workdays: [0, 1, 2, 3, 4, 5, 6] } });

  // 未来日期不判
  d = await statusOf(dayStr(3), e1.id);
  ok('未来日期 → future', d?.status === 'future', JSON.stringify(d));

  // ---------------- 五：跨天夜班（窗口必须"拉直"） ----------------
  console.log('\n【五】跨天夜班');
  r = await api('POST', '/api/admin/attendance/shifts', {
    token: admin,
    body: { name: '夜班', workStart: '22:00', workEnd: '06:00', restMinutes: 60, flexMinutes: 0, lateGrace: 0, earlyGrace: 0 },
  });
  const nightShift = r.body?.id;
  ok('建夜班 22:00-06:00', r.status === 200 && !!nightShift, JSON.stringify(r.body));
  r = await api('GET', '/api/admin/attendance/shifts', { token: admin });
  const ns = r.body.items.find((x) => x.id === nightShift);
  ok('  自动识别为跨天班', ns?.crossDay === true, JSON.stringify(ns));

  r = await api('POST', '/api/admin/attendance/groups',
    { token: admin, body: { name: '夜班组', shiftId: nightShift, memberIds: [e2.id] } });
  const nightGroup = r.body?.id;
  ok('建夜班组并把 emp02 点名入组', r.status === 200 && !!nightGroup, JSON.stringify(r.body));
  r = await api('GET', '/api/attendance/today', { token: e2.token });
  ok('  emp02 班次来源 = group', r.body.shiftSource === 'group', r.body.shiftSource);
  ok('  emp02 看到夜班 22:00-06:00', r.body.shift?.workStart === '22:00' && r.body.shift?.workEnd === '06:00', JSON.stringify(r.body.shift));

  const NY = dayStr(-2); // 前天 22:00 上班、次日 06:00 下班
  const nextOfNY = dayStr(-1);
  await fix(e2.id, NY, 'in', '22:10');       // 迟到 10 分钟
  await fix(e2.id, nextOfNY, 'out', '05:30'); // 次日 05:30 下班 → 早退 30 分钟
  d = await statusOf(NY, e2.id);
  ok('夜班 22:10 上班 → 迟到 10 分钟',
    ['late', 'late_early'].includes(d?.status) && d?.lateMinutes === 10, JSON.stringify(d));
  // 次日 05:30 的下班卡必须被算进**前一天**的窗口（跨天班的核心断言：
  // 若按 day 字段取记录，这张卡会跑到次日去，前天就变成"缺下班卡"）
  ok('  次日 05:30 的下班卡算进前一天 → 早退 30 分钟（不是缺卡）',
    d?.earlyMinutes === 30 && d?.lastOutTime === '05:30',
    JSON.stringify({ status: d?.status, early: d?.earlyMinutes, lastOut: d?.lastOutTime, note: d?.note }));

  // ---------------- 六：请假 ----------------
  console.log('\n【六】请假（审批后进统计）');
  const L1 = dayStr(-7);
  r = await api('POST', '/api/attendance/requests', {
    token: e1.token,
    body: { kind: 'leave', startDay: L1, endDay: L1, half: 0, leaveType: 'personal', reason: '家里有事' },
  });
  const leaveId = r.body?.id;
  ok('提交请假（事假 1 天）', r.status === 200 && !!leaveId, JSON.stringify(r.body));
  d = await statusOf(L1, e1.id);
  ok('  审批前：仍是缺勤（申请未生效）', d?.status === 'absent', JSON.stringify(d));

  r = await api('POST', '/api/attendance/requests', {
    token: e1.token,
    body: { kind: 'leave', startDay: L1, endDay: L1, half: 0, leaveType: 'personal' },
  });
  ok('  重复提交被拒', r.status === 400, JSON.stringify(r.body));

  r = await api('POST', `/api/admin/attendance/requests/${leaveId}/review`, { token: admin, body: { approve: true, note: '同意' } });
  ok('管理员审批通过', r.status === 200 && r.body.request?.status === 'approved', JSON.stringify(r.body).slice(0, 200));
  d = await statusOf(L1, e1.id);
  ok('  审批后：那天 = leave', d?.status === 'leave', JSON.stringify(d));

  r = await api('POST', `/api/admin/attendance/requests/${leaveId}/review`, { token: admin, body: { approve: false } });
  ok('  重复审批被拒', r.status === 400, JSON.stringify(r.body));

  // 半天假（下午）
  const L2 = dayStr(-8);
  r = await api('POST', '/api/attendance/requests', {
    token: e1.token, body: { kind: 'leave', startDay: L2, endDay: L2, half: 2, leaveType: 'sick' },
  });
  const halfLeave = r.body?.id;
  await api('POST', `/api/admin/attendance/requests/${halfLeave}/review`, { token: admin, body: { approve: true } });
  await fix(e1.id, L2, 'in', '08:55');  // 上午来了
  d = await statusOf(L2, e1.id);
  ok('下午半天假 + 上午打卡 → 不判缺卡', d?.status !== 'missing' && d?.status !== 'absent', JSON.stringify(d));
  const rep8 = await api('GET', `/api/admin/attendance/report?from=${L2}&to=${L2}`, { token: admin });
  const u1 = rep8.body.users.find((x) => x.userId === e1.id);
  ok('  请假天数计 0.5', u1?.summary?.leave === 0.5, JSON.stringify(u1?.summary));

  r = await api('POST', '/api/attendance/requests', {
    token: e1.token, body: { kind: 'leave', startDay: L2, endDay: dayStr(-9), half: 0, leaveType: 'annual' },
  });
  ok('结束日期早于开始 → 400', r.status === 400, JSON.stringify(r.body));
  r = await api('POST', '/api/attendance/requests', {
    token: e1.token, body: { kind: 'leave', startDay: Y1, endDay: Y2, half: 1, leaveType: 'annual' },
  });
  ok('多日请假却选半天 → 400', r.status === 400, JSON.stringify(r.body));

  // ---------------- 七：补卡 ----------------
  console.log('\n【七】补卡（审批通过后直接修正考勤）');
  const M1 = dayStr(-10);
  r = await api('POST', '/api/attendance/requests', {
    token: e1.token, body: { kind: 'makeup', day: M1, clockType: 'in', at: tsAt(M1, '08:50'), reason: '忘打卡' },
  });
  const mkId = r.body?.id;
  ok('提交补卡（上班卡 08:50）', r.status === 200 && !!mkId, JSON.stringify(r.body));
  d = await statusOf(M1, e1.id);
  ok('  审批前：缺勤', d?.status === 'absent', JSON.stringify(d));

  r = await api('POST', `/api/admin/attendance/requests/${mkId}/review`, { token: admin, body: { approve: true } });
  ok('补卡审批通过', r.status === 200, JSON.stringify(r.body));
  d = await statusOf(M1, e1.id);
  ok('  通过后上班卡时间 = 08:50', d?.firstInTime === '08:50', JSON.stringify(d));
  ok('  状态变为缺卡（只补了上班卡）', d?.status === 'missing', JSON.stringify(d));
  r = await api('GET', `/api/admin/attendance/records?day=${M1}&userId=${e1.id}`, { token: admin });
  const mkRec = r.body.items.find((x) => x.type === 'in');
  ok('  流水来源标记为 makeup', mkRec?.source === 'makeup', JSON.stringify(mkRec));

  r = await api('POST', '/api/attendance/requests', {
    token: e1.token, body: { kind: 'makeup', day: M1, clockType: 'out', at: tsAt(Y1, '18:00') },
  });
  ok('补卡时刻不在所选日期 → 400', r.status === 400, JSON.stringify(r.body));
  r = await api('POST', '/api/attendance/requests', {
    token: e1.token, body: { kind: 'makeup', day: dayStr(2), clockType: 'in', at: tsAt(dayStr(2), '09:00') },
  });
  ok('给未来日期补卡 → 400', r.status === 400, JSON.stringify(r.body));

  // ---------------- 八：外出 / 加班 ----------------
  console.log('\n【八】外出与加班');
  // 用 e1（此时仍走默认班次 09:00-18:00）。不能用 e2 —— 他在第五节已被点名进夜班组，
  // 白天 08:00~19:00 的外出覆盖不到 22:00/06:00 两张卡，那测的就不是外出的语义了。
  const O1 = dayStr(-11);
  r = await api('POST', '/api/attendance/requests', {
    token: e1.token,
    body: { kind: 'outing', startAt: tsAt(O1, '08:00'), endAt: tsAt(O1, '19:00'), reason: '外出送货' },
  });
  const outId = r.body?.id;
  ok('提交外出申请（全天）', r.status === 200 && !!outId, JSON.stringify(r.body));
  await api('POST', `/api/admin/attendance/requests/${outId}/review`, { token: admin, body: { approve: true } });
  d = await statusOf(O1, e1.id);
  ok('  外出覆盖上下班时间点 → 不判缺勤', d?.status === 'outing', JSON.stringify(d));

  const OT = dayStr(-12);
  r = await api('POST', '/api/attendance/requests', {
    token: e1.token,
    body: { kind: 'overtime', startAt: tsAt(OT, '18:00'), endAt: tsAt(OT, '21:30'), reason: '赶订单' },
  });
  const otId = r.body?.id;
  await api('POST', `/api/admin/attendance/requests/${otId}/review`, { token: admin, body: { approve: true } });
  const repOt = await api('GET', `/api/admin/attendance/report?from=${OT}&to=${OT}`, { token: admin });
  const uOt = repOt.body.users.find((x) => x.userId === e1.id);
  ok('加班 3.5 小时计入统计', uOt?.summary?.overtimeMinutes === 210, JSON.stringify(uOt?.summary));
  r = await api('POST', '/api/attendance/requests', {
    token: e1.token, body: { kind: 'overtime', startAt: tsAt(OT, '22:00'), endAt: tsAt(OT, '10:00'), reason: '跨天' },
  });
  ok('时长超过 24 小时被拒 / 起止倒置被拒', r.status === 400, JSON.stringify(r.body));

  // 撤销
  r = await api('POST', '/api/attendance/requests', {
    token: e2.token, body: { kind: 'leave', startDay: dayStr(-14), endDay: dayStr(-14), half: 0, leaveType: 'annual' },
  });
  const cancelId = r.body?.id;
  r = await api('POST', `/api/attendance/requests/${cancelId}/cancel`, { token: e2.token });
  ok('撤销自己的待审批申请', r.status === 200, JSON.stringify(r.body));
  r = await api('POST', `/api/attendance/requests/${mkId}/cancel`, { token: e2.token });
  ok('撤销别人的申请 / 已通过 → 404 或 400', r.status === 404 || r.status === 400, JSON.stringify(r.body));

  // ---------------- 九：考勤组（按部门纳入 + 子部门） ----------------
  console.log('\n【九】考勤组');
  r = await api('POST', '/api/admin/attendance/shifts', {
    token: admin, body: { name: '早班', workStart: '08:00', workEnd: '16:00', restMinutes: 30, flexMinutes: 15, lateGrace: 5, earlyGrace: 10 },
  });
  const earlyShift = r.body?.id;
  ok('建早班 08:00-16:00（弹性15/宽限5/提前10）', r.status === 200, JSON.stringify(r.body));

  r = await api('POST', '/api/admin/attendance/groups', {
    token: admin, body: { name: '生产部早班', shiftId: earlyShift, deptIds: [prodDept], locationMode: 'optional' },
  });
  const prodGroup = r.body?.id;
  ok('建考勤组并绑定「生产部」', r.status === 200 && !!prodGroup, JSON.stringify(r.body));
  r = await api('GET', '/api/admin/attendance/groups', { token: admin });
  const pg = r.body.items.find((x) => x.id === prodGroup);
  ok('  组内人数含子部门员工（2 人）', pg?.memberCount === 2, JSON.stringify(pg));

  // emp01 在子部门「包装车间」，应当命中绑定了父部门「生产部」的组
  r = await api('GET', '/api/attendance/today', { token: e1.token });
  ok('  子部门员工命中父部门考勤组（dept 来源）', r.body.shiftSource === 'dept' && r.body.shift?.workStart === '08:00', JSON.stringify({ s: r.body.shiftSource, sh: r.body.shift }));
  ok('  组信息随 today 下发（locationMode=optional）', r.body.group?.locationMode === 'optional', JSON.stringify(r.body.group));

  // 点名入组应优先于部门
  r = await api('POST', '/api/admin/attendance/groups', {
    token: admin, body: { name: '特批小组', shiftId: nightShift, memberIds: [e1.id] },
  });
  const specialGroup = r.body?.id;
  r = await api('GET', '/api/attendance/today', { token: e1.token });
  ok('  显式点名优先于部门绑定（group 来源）', r.body.shiftSource === 'group' && r.body.group?.name === '特批小组', JSON.stringify({ s: r.body.shiftSource, g: r.body.group }));
  await api('DELETE', `/api/admin/attendance/groups/${specialGroup}`, { token: admin });

  r = await api('DELETE', `/api/admin/attendance/shifts/${earlyShift}`, { token: admin });
  ok('删除被考勤组占用的班次 → 400', r.status === 400, JSON.stringify(r.body));
  r = await api('DELETE', `/api/admin/attendance/groups/${prodGroup}`, { token: admin });
  ok('删考勤组 → 200', r.status === 200, JSON.stringify(r.body));
  r = await api('DELETE', `/api/admin/attendance/shifts/${earlyShift}`, { token: admin });
  ok('  组删掉后班次可删', r.status === 200, JSON.stringify(r.body));

  r = await api('POST', '/api/admin/attendance/groups', { token: admin, body: { name: '坏组', shiftId: 99999 } });
  ok('考勤组指向不存在的班次 → 400', r.status === 400, JSON.stringify(r.body));

  // 定位要求：用一个干净的人（emp03 不属于任何考勤组），否则会被前一个组的规则盖住 ——
  // "一人命中多个考勤组时按 id 最早优先"是有意设计，测试必须顺着它来测
  const e3 = await addEmp('emp03', '王五', packDept);
  r = await api('POST', '/api/admin/attendance/groups', {
    token: admin, body: { name: '强制定位组', shiftId: nightShift, memberIds: [e3.id], locationMode: 'required' },
  });
  const locGroup = r.body?.id;
  r = await api('POST', '/api/attendance/clock', { token: e3.token, body: { type: 'in' } });
  ok('强制定位组不带定位打卡 → 400', r.status === 400 && /定位/.test(r.body.error || ''), JSON.stringify(r.body));
  r = await api('POST', '/api/attendance/clock', { token: e3.token, body: { type: 'in', lat: 45.51, lng: 126.95 } });
  ok('  带定位则成功', r.status === 200, JSON.stringify(r.body));
  r = await api('POST', '/api/attendance/clock', { token: e3.token, body: { type: 'in', lat: 0, lng: 0 } });
  ok('  (0,0) 视为无效定位 → 400', r.status === 400, JSON.stringify(r.body));
  await api('DELETE', `/api/admin/attendance/groups/${locGroup}`, { token: admin });

  // ---------------- 十：报表与看板 ----------------
  console.log('\n【十】报表与看板');
  const from = dayStr(-12), to = TODAY;
  r = await api('GET', `/api/admin/attendance/report?from=${from}&to=${to}`, { token: admin });
  ok('区间报表返回 3 人', r.status === 200 && r.body.users?.length === 3, JSON.stringify(r.body).slice(0, 160));
  const t = r.body.totals;
  ok('  合计含人数与出勤/异常计数', t?.people === 3 && typeof t.absent === 'number' && typeof t.late === 'number', JSON.stringify(t));
  ok('  天数 = 13 天', r.body.users[0].days.length === 13, String(r.body.users[0].days.length));
  ok('  昨天 e1 = normal（08:50 / 18:05）',
    r.body.users.find((x) => x.userId === e1.id).days.find((x) => x.day === Y1).status === 'normal',
    JSON.stringify(r.body.users.find((x) => x.userId === e1.id).days.find((x) => x.day === Y1)));

  r = await api('GET', `/api/admin/attendance/report?from=${from}&to=${to}&deptId=${prodDept}`, { token: admin });
  ok('按部门过滤：选「生产部」含子部门「包装车间」→ 3 人全在',
    r.body.users?.length === 3, JSON.stringify(r.body.users?.map((x) => x.username)));

  r = await api('GET', '/api/admin/attendance/overview?day=' + Y2, { token: admin });
  // Y2 那天 e1 白班 9:30 迟到、e2 夜班 22:10 迟到（夜班组在第五节已把 emp02 点名入组）；
  // e3 那天没有任何记录 → 缺勤，但不该被算成迟到
  ok('看板：前天 3 人、迟到 2 人、缺勤 1 人',
    r.status === 200 && r.body.items?.length === 3 && r.body.stats.late === 2 && r.body.stats.absent === 1,
    JSON.stringify(r.body.stats));
  const ovE1 = r.body.items.find((x) => x.userId === e1.id);
  ok('  看板能看到迟到分钟与打卡时间', ovE1?.firstInTime === '09:30' && ovE1?.lateMinutes === 30, JSON.stringify(ovE1));

  r = await api('GET', `/api/admin/attendance/overview?day=${TODAY}`, { token: admin });
  ok('看板：今天有 1 人已打上班卡', r.body.stats.present >= 1, JSON.stringify(r.body.stats));

  r = await api('GET', '/api/attendance/my', { token: e1.token });
  ok('我的月度考勤：available + days/summary', r.body.available === true && r.body.days?.length >= 28 && !!r.body.summary, JSON.stringify(r.body.summary));
  r = await api('GET', '/api/attendance/my?month=2026-01', { token: e1.token });
  ok('  指定月份可用', r.body.month === '2026-01' && r.body.days.length === 31, JSON.stringify({ m: r.body.month, n: r.body.days?.length }));

  // 管理员手工改记录 + 删除
  r = await api('POST', '/api/admin/attendance/records',
    { token: admin, body: { userId: e1.id, day: Y2, type: 'in', time: '08:45', note: '系统故障代为修正' } });
  ok('管理员修正打卡（覆盖同日同类型）', r.status === 200, JSON.stringify(r.body));
  d = await statusOf(Y2, e1.id);
  ok('  修正后不再迟到', d?.firstInTime === '08:45' && d?.status === 'normal', JSON.stringify(d));
  r = await api('POST', '/api/admin/attendance/records',
    { token: admin, body: { userId: e1.id, day: Y2, type: 'in', time: '9:45' } });
  ok('非法时间格式被拒', r.status === 400, JSON.stringify(r.body));
  r = await api('POST', '/api/admin/attendance/records',
    { token: admin, body: { userId: e1.id, day: '2026-13-45', type: 'in', time: '09:00' } });
  ok('非法日期被拒', r.status === 400, JSON.stringify(r.body));

  r = await api('GET', `/api/admin/attendance/records?day=${Y2}&userId=${e1.id}`, { token: admin });
  const delId = r.body.items.find((x) => x.type === 'out')?.id;
  r = await api('DELETE', `/api/admin/attendance/records/${delId}`, { token: admin });
  ok('删除一条打卡流水', r.status === 200, JSON.stringify(r.body));

  // 审批列表
  r = await api('GET', '/api/admin/attendance/requests?status=all', { token: admin });
  ok('审批列表（全部）返回计数', r.body.items?.length >= 5 && typeof r.body.counts.pending === 'number', JSON.stringify(r.body.counts));
  r = await api('GET', '/api/admin/attendance/requests?status=pending', { token: admin });
  ok('  默认只看待审批', r.body.items.every((x) => x.status === 'pending'), JSON.stringify(r.body.items.map((x) => x.status)));

  // ---------------- 十一：权限隔离 ----------------
  console.log('\n【十一】权限隔离');
  r = await api('GET', '/api/admin/attendance/config', { token: e1.token });
  ok('员工读考勤配置 → 403', r.status === 403, JSON.stringify(r.body));
  r = await api('PUT', '/api/admin/attendance/config', { token: e1.token, body: { enabled: false } });
  ok('员工改考勤配置 → 403', r.status === 403, JSON.stringify(r.body));
  r = await api('GET', '/api/admin/attendance/report', { token: e1.token });
  ok('员工读全组织报表 → 403', r.status === 403, JSON.stringify(r.body));
  r = await api('POST', `/api/admin/attendance/requests/${leaveId}/review`, { token: e1.token, body: { approve: true } });
  ok('员工审批申请 → 403', r.status === 403, JSON.stringify(r.body));
  r = await api('GET', '/api/attendance/requests', { token: e1.token });
  ok('员工只能看到自己的申请', r.body.items?.every((x) => x.userId === e1.id), JSON.stringify(r.body.items.map((x) => x.userId)));
  r = await api('GET', '/api/attendance/today');
  ok('未登录 today → 401', r.status === 401);

  // ---------------- 十二：应用中心（工作台） ----------------
  console.log('\n【十二】应用中心（工作台）');
  r = await api('GET', '/api/client/apps', { token: e1.token });
  const ids = (r.body.apps || []).map((x) => x.id);
  ok('员工拿到应用列表', r.status === 200 && ids.length >= 3, JSON.stringify(ids));
  ok('  含考勤打卡', ids.includes('attendance'), JSON.stringify(ids));
  ok('  含我的申请', ids.includes('my_requests'), JSON.stringify(ids));
  ok('  含组织通讯录', ids.includes('work_org'), JSON.stringify(ids));
  const attApp = r.body.apps.find((x) => x.id === 'attendance');
  ok('  考勤 kind=builtin 且分组 work', attApp?.kind === 'builtin' && attApp?.group === 'work', JSON.stringify(attApp));

  r = await api('GET', '/api/client/apps', { token: admin });
  const aids = (r.body.apps || []).map((x) => x.id);
  ok('管理员视角：不含考勤打卡（管理员不参与考勤）', !aids.includes('attendance'), JSON.stringify(aids));
  ok('  但含组织通讯录', aids.includes('work_org'), JSON.stringify(aids));

  // 动态模块并入同一列表
  r = await api('POST', '/api/admin/modules', {
    token: admin,
    body: {
      moduleId: 'att_test_app', title: '自建应用', icon: 'note', sort: 5, enabled: true,
      body: [{ component: 'text', text: 'hello' }],
    },
  });
  ok('管理台建动态模块', r.status === 200, JSON.stringify(r.body).slice(0, 120));
  r = await api('GET', '/api/client/apps', { token: e1.token });
  const dyn = r.body.apps.find((x) => x.id === 'att_test_app');
  ok('  动态模块作为 kind=dynamic 出现在同一列表', dyn?.kind === 'dynamic' && dyn?.group === 'custom', JSON.stringify(dyn));

  // 版本闸门（回归）：需求版本高于客户端的模块必须按 ?clientVersion= 过滤掉。
  // 这条曾经真实出过问题 —— 客户端调 /client/apps 时漏传 clientVersion，
  // 服务端拿到空串 → versionGte 一律 false → 凡设了最低版本的模块**整个消失**，
  // 现象是"管理台明明发布了、客户端工作台里就是没有"。所以三种入参都要断言。
  await api('POST', '/api/admin/modules', {
    token: admin,
    body: {
      moduleId: 'att_future_app', title: '未来应用', icon: 'note', sort: 6, enabled: true,
      minClientVersion: '9.9.9',
      body: [{ component: 'text', text: 'need newer client' }],
    },
  });
  r = await api('GET', '/api/client/apps?clientVersion=0.11.0', { token: e1.token });
  ok('客户端版本不够：minVersion=9.9.9 的模块不下发',
      !(r.body.apps || []).some((x) => x.id === 'att_future_app'),
      JSON.stringify((r.body.apps || []).map((x) => x.id)));
  r = await api('GET', '/api/client/apps?clientVersion=9.9.9', { token: e1.token });
  const fut = (r.body.apps || []).find((x) => x.id === 'att_future_app');
  ok('  版本够：下发，且带 minVersion 供客户端二次校验',
      !!fut && fut.minVersion === '9.9.9', JSON.stringify(fut));
  r = await api('GET', '/api/client/apps', { token: e1.token });
  ok('  不带 clientVersion：按"版本不满足"处理（宁可少入口，也不给打不开的页面）',
      !(r.body.apps || []).some((x) => x.id === 'att_future_app'),
      JSON.stringify((r.body.apps || []).map((x) => x.id)));
  r = await api('GET', '/api/admin/apps', { token: admin });
  ok('管理台应用中心：内置 + 自定义 + 上下文', r.body.builtin?.length >= 3 && r.body.dynamic?.length >= 1 && !!r.body.context, JSON.stringify(r.body.context));
  r = await api('GET', '/api/admin/apps/why?id=attendance', { token: admin });
  ok('  「为什么看不到」诊断可用', r.status === 200 && typeof r.body.visible === 'boolean', JSON.stringify(r.body));

  // 停用考勤 → 相关入口整体消失
  await api('PUT', '/api/admin/attendance/config', { token: admin, body: { enabled: false } });
  r = await api('GET', '/api/client/apps', { token: e1.token });
  const ids2 = r.body.apps.map((x) => x.id);
  ok('停用考勤后：考勤与我的申请入口消失', !ids2.includes('attendance') && !ids2.includes('my_requests'), JSON.stringify(ids2));
  ok('  组织通讯录仍在（不依赖考勤）', ids2.includes('work_org'), JSON.stringify(ids2));
  r = await api('GET', '/api/attendance/today', { token: e1.token });
  ok('  停用后 today → available:false 且说明原因', r.body.available === false && /停用/.test(r.body.reason || ''), JSON.stringify(r.body));
  r = await api('POST', '/api/attendance/clock', { token: e1.token, body: { type: 'in' } });
  ok('  停用后打卡 → 400', r.status === 400, JSON.stringify(r.body));
  r = await api('POST', '/api/attendance/requests', {
    token: e1.token, body: { kind: 'leave', startDay: dayStr(-20), endDay: dayStr(-20), half: 0, leaveType: 'annual' },
  });
  ok('  停用后提交申请 → 400', r.status === 400, JSON.stringify(r.body));

  await api('PUT', '/api/admin/attendance/config', { token: admin, body: { enabled: true } });
  r = await api('GET', '/api/attendance/today', { token: e1.token });
  ok('重新开启后立即可用', r.body.available === true, JSON.stringify(r.body).slice(0, 120));

  // 历史记录不因停用而丢
  r = await api('GET', `/api/admin/attendance/report?from=${from}&to=${to}`, { token: admin });
  ok('停用/重启后历史考勤数据仍在', r.body.users?.length === 3, JSON.stringify(r.body.users?.length));

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
