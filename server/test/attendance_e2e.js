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

  // 默认班次带午休窗口（08:00-12:00 / 13:00-17:00）＝ 一天 4 次卡，
  // 工作日设成全周（判定用例需要"昨天一定是工作日"）
  await api('PUT', '/api/admin/attendance/config', {
    token: admin, body: { workdays: [0, 1, 2, 3, 4, 5, 6], enabled: true },
  });

  // ---------------- 二：默认班次兜底 ----------------
  console.log('\n【二】默认班次兜底（没建任何考勤组也能打卡）');
  r = await api('GET', '/api/attendance/today', { token: e1.token });
  ok('员工 today → available:true', r.status === 200 && r.body.available === true, JSON.stringify(r.body).slice(0, 200));
  ok('  班次来源 = default', r.body.shiftSource === 'default', r.body.shiftSource);
  ok('  默认班次 08:00-17:00 含午休 12:00-13:00',
    r.body.shift?.workStart === '08:00' && r.body.shift?.workEnd === '17:00'
    && r.body.shift?.restStart === '12:00' && r.body.shift?.restEnd === '13:00',
    JSON.stringify(r.body.shift));
  ok('  默认一天 4 次卡（segments=2 / punchesPerDay=4）',
    r.body.shift?.segments === 2 && r.body.shift?.punchesPerDay === 4, JSON.stringify(r.body.shift));
  ok('  打卡计划 4 张卡且顺序为 上班/午休下班/午休上班/下班',
    JSON.stringify((r.body.punchPlan || []).map((p) => [p.key, p.label]))
      === JSON.stringify([['in1', '上班'], ['out1', '午休下班'], ['in2', '午休上班'], ['out2', '下班']]),
    JSON.stringify((r.body.punchPlan || []).map((p) => [p.key, p.label])));
  ok('  今日应打 4 次', r.body.today?.expectedPunches === 4, JSON.stringify(r.body.today));
  ok('  无考勤组', r.body.group === null, JSON.stringify(r.body.group));

  // 管理台「考勤设置」的默认班次表单读的是 /config 的 defaultShift。
  // 它必须**同时**带上可编辑字段和派生字段 —— 只给存储值的话，界面就不知道
  // "这个班次一天打几次卡"，只能在客户端再减一遍，那是口径分家的起点。
  r = await api('GET', '/api/admin/attendance/config', { token: admin });
  ok('/config 的 defaultShift 带派生字段（一次几次卡 / 应出勤）',
    r.body.defaultShift?.punchesPerDay === 4 && r.body.defaultShift?.segments === 2
    && r.body.defaultShift?.expectedWorkMinutes === 480,
    JSON.stringify(r.body.defaultShift));
  ok('  同时保留可编辑字段', r.body.defaultShift?.workStart === '08:00'
    && r.body.defaultShift?.restStart === '12:00' && r.body.defaultShift?.restEnd === '13:00'
    && r.body.defaultShift?.workEnd === '17:00', JSON.stringify(r.body.defaultShift));

  r = await api('PUT', '/api/admin/attendance/config',
    { token: admin, body: { defaultShift: { workStart: '08:30', workEnd: '17:30', restMinutes: 60, flexMinutes: 0, lateGrace: 0, earlyGrace: 0 } } });
  ok('改默认班次 → 200', r.status === 200, JSON.stringify(r.body));
  r = await api('GET', '/api/attendance/today', { token: e1.token });
  ok('  员工看到新上班时间 08:30', r.body.shift?.workStart === '08:30', JSON.stringify(r.body.shift));
  r = await api('PUT', '/api/admin/attendance/config',
    { token: admin, body: { defaultShift: { workStart: '09:00', workEnd: '18:00', restMinutes: 60, flexMinutes: 0, lateGrace: 0, earlyGrace: 0 } } });
  ok('清空午休窗口 → 降级为一天 2 次卡', r.status === 200);
  r = await api('GET', '/api/attendance/today', { token: e1.token });
  ok('  午休为空时 shift.restStart=null 且 punchesPerDay=2',
    r.body.shift?.restStart === null && r.body.shift?.segments === 1 && r.body.shift?.punchesPerDay === 2,
    JSON.stringify(r.body.shift));
  ok('  打卡计划退化为 上班/下班 两张',
    JSON.stringify((r.body.punchPlan || []).map((p) => p.key)) === JSON.stringify(['in1', 'out1']),
    JSON.stringify((r.body.punchPlan || []).map((p) => p.key)));
  // 只填一半的午休窗口是非法配置：判定时算不出该打几次卡，必须明确报错
  r = await api('PUT', '/api/admin/attendance/config', { token: admin, body: { defaultShift: { workStart: '09:00', workEnd: '18:00', restStart: '12:00' } } });
  ok('只填午休开始 → 400', r.status === 400, JSON.stringify(r.body));
  r = await api('PUT', '/api/admin/attendance/config', { token: admin, body: { defaultShift: { workStart: '09:00', workEnd: '18:00', restStart: '12:00', restEnd: '13:00' } } });
  ok('午休落在班次内 → 200', r.status === 200, JSON.stringify(r.body));
  r = await api('PUT', '/api/admin/attendance/config', { token: admin, body: { defaultShift: { workStart: '09:00', workEnd: '18:00', restStart: '08:00', restEnd: '13:00' } } });
  ok('午休早于上班 → 400', r.status === 400, JSON.stringify(r.body));
  // ★ 复位成"09:00-18:00 无午休"的 2 次卡 —— 下面所有判定用例都建立在这个班次上，
  //   留成 4 次卡会把它们全部带偏（缺卡、迟到分钟数、在岗时长都不是原来的数）
  r = await api('PUT', '/api/admin/attendance/config',
    { token: admin, body: { defaultShift: { workStart: '09:00', workEnd: '18:00', restMinutes: 60, flexMinutes: 0, lateGrace: 0, earlyGrace: 0 } } });
  r = await api('GET', '/api/attendance/today', { token: e1.token });
  ok('复位为 2 次卡班次（供后续判定用例使用）',
    r.body.shift?.punchesPerDay === 2 && r.body.punchPlan?.length === 2, JSON.stringify(r.body.shift));
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
  // 员工不该看到管理员的看板入口：入口可见性与接口权限必须是同一套判据，
  // 否则员工点进去只会拿到 403（"点了才知道"是最差的交互）。
  ok('  不含管理员的「考勤记录」', !ids.includes('att_admin'), JSON.stringify(ids));

  r = await api('GET', '/api/client/apps', { token: admin });
  const aids = (r.body.apps || []).map((x) => x.id);
  ok('管理员视角：不含考勤打卡（管理员不参与考勤）', !aids.includes('attendance'), JSON.stringify(aids));
  ok('  也不含我的申请（他不打卡也就没有申请）', !aids.includes('my_requests'), JSON.stringify(aids));
  ok('  含「考勤记录」（主管看板 + 代补卡）', aids.includes('att_admin'), JSON.stringify(aids));
  ok('  但含组织通讯录', aids.includes('work_org'), JSON.stringify(aids));
  const admApp = r.body.apps.find((x) => x.id === 'att_admin');
  ok('  考勤记录 kind=builtin 且分组 work', admApp?.kind === 'builtin' && admApp?.group === 'work', JSON.stringify(admApp));

  // 角标＝待审批条数（管理员的待办）。这里临时造一条再撤掉，用完复原，
  // 免得给后面的用例留下"多出来一条待审批"的暗坑。
  r = await api('POST', '/api/attendance/requests', {
    token: e1.token,
    body: { kind: 'makeup', day: Y2, clockType: 'in', at: tsAt(Y2, '09:00'), reason: '角标用例' },
  });
  const badgeReqId = r.body?.id;
  ok('员工提交补卡申请（为角标造数据）', r.status === 200 && !!badgeReqId, JSON.stringify(r.body));
  r = await api('GET', '/api/client/apps', { token: admin });
  const badgeOf = (b) => Number((b.body.apps || []).find((x) => x.id === 'att_admin')?.badge || 0);
  const badgeBefore = badgeOf(r);
  ok('  管理员「考勤记录」带待审批角标', badgeBefore >= 1, 'badge=' + badgeBefore);
  await api('POST', `/api/attendance/requests/${badgeReqId}/cancel`, { token: e1.token });
  r = await api('GET', '/api/client/apps', { token: admin });
  ok('  撤销后角标跟着减一（角标是真查出来的，不是摆设）',
      badgeOf(r) === badgeBefore - 1, `before=${badgeBefore} after=${badgeOf(r)}`);

  // 管理员看板的数据源：管理端 overview 此前只有管理台在用，客户端要复用同一份口径
  r = await api('GET', `/api/admin/attendance/overview?day=${TODAY}`, { token: admin });
  ok('管理员可拉今日看板 overview', r.status === 200 && !!r.body.stats && Array.isArray(r.body.items),
      JSON.stringify(r.body).slice(0, 120));

  // 字段集必须和 punchView()（员工打卡页用的那份）逐字对齐。
  // 踩过：overview 少发了 done → 客户端照 punchPlan 的读法渲染，
  // **已经打过的卡在看板上显示成"缺"**，而员工页显示正常，两边对不上。
  // 所以这里按字段名逐个卡一遍，不是"看起来有数据就算过"。
  {
    const NEED = ['key', 'type', 'slot', 'label', 'expectTime', 'expectAt',
                  'time', 'at', 'done', 'due', 'exempt', 'status',
                  'lateMinutes', 'earlyMinutes'];
    const punches = (r.body.items || []).flatMap((i) => i.punches || []);
    ok('  看板的卡带齐 punchView 的全部字段（含 done）',
        punches.length > 0 && punches.every((p) => NEED.every((k) => k in p)),
        '缺少: ' + JSON.stringify(NEED.filter((k) => punches.some((p) => !(k in p)))));
    // done 必须就是"有没有打卡时刻"，两处口径不能分家
    ok('  done 与 time 一致（打了才有时刻，有时刻就是打了）',
        punches.every((p) => p.done === (p.time != null)),
        JSON.stringify(punches.filter((p) => p.done !== (p.time != null)).slice(0, 3)));
  }
  r = await api('GET', `/api/admin/attendance/overview?day=${TODAY}`, { token: e1.token });
  ok('  员工拉管理员看板 → 403（入口与权限同源）', r.status === 403, JSON.stringify(r.body));

  // 考勤停用后管理员的看板入口也要消失（不能留一个点进去空的入口）
  await api('PUT', '/api/admin/attendance/config', { token: admin, body: { enabled: false } });
  r = await api('GET', '/api/client/apps', { token: admin });
  ok('考勤停用：管理员也不下发「考勤记录」',
      !(r.body.apps || []).some((x) => x.id === 'att_admin'),
      JSON.stringify((r.body.apps || []).map((x) => x.id)));
  await api('PUT', '/api/admin/attendance/config', { token: admin, body: { enabled: true } });

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

  // ---------------- 十三：一天 4 次卡（午休窗口） ----------------
  console.log('\n【十三】一天 4 次卡（上班 / 午休下班 / 午休上班 / 下班）');
  // 这一节拿**默认班次**当载体：临时改成 08:00-12:00 / 13:00-17:00，验完复位。
  // e1（张三）走的正是默认班次，不必新建考勤组。
  //
  // 日期一律取 -101 往后：前面小节已经把 -1 ~ -20 用得七七八八（尤其 -7 上挂着
  // 一张事假单），随手挑一天就会撞上"那天是请假"的既有事实，断言看着像代码错了。
  async function fixSlot(uid, day, type, slot, hhmm) {
    return api('POST', '/api/admin/attendance/records',
      { token: admin, body: { userId: uid, day, type, slot, time: hhmm } });
  }
  async function dayRec(uid, day) {
    const rr = await api('GET', `/api/admin/attendance/report?from=${day}&to=${day}`, { token: admin });
    const u = (rr.body.users || []).find((x) => x.userId === uid);
    return u?.days?.[0];
  }
  const REST_SHIFT = {
    workStart: '08:00', restStart: '12:00', restEnd: '13:00', workEnd: '17:00',
    restMinutes: 60, flexMinutes: 0, lateGrace: 0, earlyGrace: 0,
  };

  r = await api('PUT', '/api/admin/attendance/config', { token: admin, body: { defaultShift: REST_SHIFT } });
  ok('配 08:00-12:00 / 13:00-17:00 含午休的班次 → 200', r.status === 200, JSON.stringify(r.body));
  r = await api('GET', '/api/attendance/today', { token: e1.token });
  ok('  识别为 2 段 → 一天 4 次卡',
    r.body.shift?.segments === 2 && r.body.shift?.punchesPerDay === 4, JSON.stringify(r.body.shift));
  ok('  应出勤 8 小时 = 480 分钟', r.body.shift?.expectedWorkMinutes === 480,
    String(r.body.shift?.expectedWorkMinutes));
  ok('  四张卡依次是 上班/午休下班/午休上班/下班',
    JSON.stringify((r.body.punchPlan || []).map((p) => p.label))
      === JSON.stringify(['上班', '午休下班', '午休上班', '下班']),
    JSON.stringify((r.body.punchPlan || []).map((p) => p.label)));

  // (0) 工作台角标的口径：不能是"有没有上班卡"。
  //     老写法是 `type='in'` 存在就消角标 —— 4 次卡下员工打完 08:00 的上班卡，
  //     中午、下午三张全漏了也照样没提醒。现在按"已到点却没打的卡"算。
  //     这里用**确定性的**那一半做断言：今天 4 张全打完 → 角标必须消失。
  //     （反过来"没打就有角标"依赖当前时刻，07:00 跑测试时第一张卡还没到点，
  //      所以只在已过 08:00 时才顺带验一下。）
  const TODAY2 = dayStr(0);
  const todayIds = [];
  for (const [t, sl, hh] of [['in', 1, '08:00'], ['out', 1, '12:00'], ['in', 2, '13:00'], ['out', 2, '17:00']]) {
    const rr = await fixSlot(e1.id, TODAY2, t, sl, hh);
    if (rr.body?.record?.id) todayIds.push(rr.body.record.id);
  }
  r = await api('GET', '/api/client/apps', { token: e1.token });
  const attBadge = (r.body.apps || []).find((x) => x.id === 'attendance');
  ok('今天 4 张卡全打完 → 工作台角标消失', !!attBadge && !attBadge.badge,
    JSON.stringify({ badge: attBadge?.badge }));

  // 清掉这几条，免得影响后续断言（今天的数据不在前面的报表区间内，但别留垃圾）
  for (const id of todayIds) await api('DELETE', `/api/admin/attendance/records/${id}`, { token: admin });

  const nowMin = new Date().getHours() * 60 + new Date().getMinutes();
  if (nowMin >= 8 * 60) {
    r = await api('GET', '/api/client/apps', { token: e1.token });
    const attBadge2 = (r.body.apps || []).find((x) => x.id === 'attendance');
    ok('  今天一张没打（且已过 08:00）→ 角标为「待打卡」',
      (attBadge2?.badge || '') === '待打卡', JSON.stringify({ badge: attBadge2?.badge }));
  }

  // (1) 四张卡都在点上：两段各 4 小时多 5 分钟，合计 8 小时 20 分
  const D1 = dayStr(-101);
  await fixSlot(e1.id, D1, 'in', 1, '07:55');
  await fixSlot(e1.id, D1, 'out', 1, '12:05');
  await fixSlot(e1.id, D1, 'in', 2, '12:55');
  await fixSlot(e1.id, D1, 'out', 2, '17:05');
  d = await dayRec(e1.id, D1);
  ok('四张卡齐全 → normal', d?.status === 'normal', JSON.stringify({ s: d?.status, note: d?.note }));
  ok('  已完成 4 张 / 应打 4 张', d?.donePunches === 4 && d?.expectedPunches === 4,
    JSON.stringify({ done: d?.donePunches, exp: d?.expectedPunches }));
  ok('  在岗时长 500 分钟（250 + 250，两段各算各的）', d?.workedMinutes === 500, String(d?.workedMinutes));
  ok('  缺卡清单为空', (d?.missingPunches || []).length === 0, JSON.stringify(d?.missingPunches));

  // (2) 上午迟 20 分钟：只有 in1 迟到，下午那段不受牵连
  const D2 = dayStr(-102);
  await fixSlot(e1.id, D2, 'in', 1, '08:20');
  await fixSlot(e1.id, D2, 'out', 1, '12:00');
  await fixSlot(e1.id, D2, 'in', 2, '13:00');
  await fixSlot(e1.id, D2, 'out', 2, '17:00');
  d = await dayRec(e1.id, D2);
  const p2 = (d?.punches || []).reduce((m, x) => (m[x.key] = x, m), {});
  ok('上午 08:20 上班 → 迟到 20 分钟且只算在 in1 上',
    d?.lateMinutes === 20 && p2.in1?.lateMinutes === 20 && p2.in2?.lateMinutes === 0,
    JSON.stringify({ day: d?.lateMinutes, in1: p2.in1?.lateMinutes, in2: p2.in2?.lateMinutes }));
  ok('  在岗时长 460 分钟（迟到不影响在岗时长，08:20→12:00 + 13:00→17:00）', d?.workedMinutes === 460, String(d?.workedMinutes));
  ok('  四张卡的 expectTime 正确',
    JSON.stringify((d?.punches || []).map((x) => x.expectTime)) === JSON.stringify(['08:00', '12:00', '13:00', '17:00']),
    JSON.stringify((d?.punches || []).map((x) => x.expectTime)));

  // (3) 下午那次上班迟到：in2 迟到必须独立计（这一条专治"只判第一次上班"的写法）
  const D3 = dayStr(-103);
  await fixSlot(e1.id, D3, 'in', 1, '08:00');
  await fixSlot(e1.id, D3, 'out', 1, '12:00');
  await fixSlot(e1.id, D3, 'in', 2, '13:40');
  await fixSlot(e1.id, D3, 'out', 2, '17:00');
  d = await dayRec(e1.id, D3);
  ok('午休后 13:40 上班 → in2 迟到 40 分钟',
    (d?.punches || []).find((x) => x.key === 'in2')?.lateMinutes === 40,
    JSON.stringify((d?.punches || []).find((x) => x.key === 'in2')));

  // (4) 只打了一半：缺的两张卡要**点名**，不是笼统说"缺卡"
  const D4 = dayStr(-104);
  await fixSlot(e1.id, D4, 'in', 1, '08:00');
  await fixSlot(e1.id, D4, 'out', 1, '12:00');
  d = await dayRec(e1.id, D4);
  ok('只打上午两张 → 缺午休上班、下班两张卡',
    d?.status === 'missing'
    && JSON.stringify(d?.missingPunches) === JSON.stringify(['in2', 'out2'])
    && JSON.stringify(d?.missingLabels) === JSON.stringify(['午休上班', '下班']),
    JSON.stringify({ s: d?.status, keys: d?.missingPunches, labels: d?.missingLabels }));
  ok('  在岗时长只算打完的那段 = 240 分钟', d?.workedMinutes === 240, String(d?.workedMinutes));

  // (5) 一张没打 → 缺勤
  const D5 = dayStr(-105);
  d = await dayRec(e1.id, D5);
  ok('一张没打 → absent', d?.status === 'absent', JSON.stringify({ s: d?.status, n: d?.note }));

  // (6) 中午那段下班卡早退：11:20 就走 → 早退 40 分钟
  const D6 = dayStr(-106);
  await fixSlot(e1.id, D6, 'in', 1, '08:00');
  await fixSlot(e1.id, D6, 'out', 1, '11:20');
  await fixSlot(e1.id, D6, 'in', 2, '13:00');
  await fixSlot(e1.id, D6, 'out', 2, '17:00');
  d = await dayRec(e1.id, D6);
  ok('午休 11:20 下班 → out1 早退 40 分钟',
    (d?.punches || []).find((x) => x.key === 'out1')?.earlyMinutes === 40,
    JSON.stringify((d?.punches || []).find((x) => x.key === 'out1')));
  ok('  在岗时长 440 分钟（3h20m + 4h）', d?.workedMinutes === 440, String(d?.workedMinutes));

  // (7) 补卡必须带 slot：补第 2 段的上班卡，审批后要落到 in2 上
  //     若只补 type=in 不带 slot，卡会挂到第 1 段 —— 那天依旧"缺午休上班卡"
  const D7 = dayStr(-107);
  await fixSlot(e1.id, D7, 'in', 1, '08:00');
  await fixSlot(e1.id, D7, 'out', 1, '12:00');
  await fixSlot(e1.id, D7, 'out', 2, '17:00');
  d = await dayRec(e1.id, D7);
  ok('缺 in2 时状态为 missing', d?.status === 'missing' && JSON.stringify(d?.missingPunches) === JSON.stringify(['in2']),
    JSON.stringify({ s: d?.status, k: d?.missingPunches }));

  r = await api('POST', '/api/attendance/requests', {
    token: e1.token,
    body: { kind: 'makeup', day: D7, clockType: 'in', slot: 2, at: tsAt(D7, '13:00'), reason: '下午忘打卡' },
  });
  const mk2Id = r.body?.id;
  ok('提交补卡（第 2 段上班卡）→ 200', r.status === 200 && !!mk2Id, JSON.stringify(r.body));
  r = await api('GET', '/api/admin/attendance/requests', { token: admin });
  const mkRow = (r.body.items || []).find((x) => x.id === mk2Id);
  ok('  补卡申请显示为「午休上班卡」',
    mkRow?.punchLabel === '午休上班', JSON.stringify({ label: mkRow?.punchLabel, slot: mkRow?.slot }));
  r = await api('POST', `/api/admin/attendance/requests/${mk2Id}/review`, { token: admin, body: { approve: true } });
  ok('审批通过补卡 → 200', r.status === 200, JSON.stringify(r.body));
  d = await dayRec(e1.id, D7);
  ok('  补卡落到 in2 上：那一天不再是缺卡',
    (d?.punches || []).find((x) => x.key === 'in2')?.done === true && d?.status !== 'missing',
    JSON.stringify({ s: d?.status, in2: (d?.punches || []).find((x) => x.key === 'in2') }));

  // (8) 2 次卡的人不许补"第 2 段"：不然会写出一张没有任何判定会看的孤儿卡
  r = await api('POST', '/api/attendance/requests', {
    token: e1.token,
    body: { kind: 'makeup', day: dayStr(-107), clockType: 'out', slot: 3, at: tsAt(dayStr(-107), '17:00'), reason: '乱填' },
  });
  ok('补第 3 次卡 → 400（4 次卡也只有 2 段）', r.status === 400, JSON.stringify(r.body));

  // (9) 半天请假只豁免对应的那一段的卡
  const D8 = dayStr(-108);
  r = await api('POST', '/api/attendance/requests', {
    token: e1.token,
    body: { kind: 'leave', startDay: D8, endDay: D8, half: 1, leaveType: 'personal', reason: '上午有事' },
  });
  const halfId = r.body?.id;
  await api('POST', `/api/admin/attendance/requests/${halfId}/review`, { token: admin, body: { approve: true } });
  d = await dayRec(e1.id, D8);
  const hp = (d?.punches || []).reduce((m, x) => (m[x.key] = x, m), {});
  ok('上午半天假 → in1/out1 豁免（exempt），下午两张仍要打',
    hp.in1?.exempt === true && hp.out1?.exempt === true
    && hp.in2?.exempt !== true && hp.out2?.exempt !== true,
    JSON.stringify({ in1: hp.in1?.status, out1: hp.out1?.status, in2: hp.in2?.status, out2: hp.out2?.status }));
  ok('  当天请假标记为 am', d?.leave === 'am', String(d?.leave));

  // (10) 未填午休的班次不该被 4 次卡逻辑污染（回归：2 次卡仍然只有 2 张卡）
  r = await api('PUT', '/api/admin/attendance/config',
    { token: admin, body: { defaultShift: { workStart: '09:00', workEnd: '18:00', restMinutes: 60, flexMinutes: 0, lateGrace: 0, earlyGrace: 0 } } });
  r = await api('GET', '/api/attendance/today', { token: e1.token });
  ok('复位为 2 次卡班次后 punchPlan 只有 2 张',
    r.body.shift?.punchesPerDay === 2 && r.body.punchPlan?.length === 2, JSON.stringify(r.body.shift));

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
