// 智能薪酬（复刻钉钉）端到端测试
//
//   node test/salary_e2e.js
//
// 起一个隔离实例（独立 DATA_DIR + 端口），跑真实 HTTP。
//
// 【测的是什么】
//   ① 规则配置：默认配置可读、保存合法规则、拒绝非法规则（负数 / 档位不递增）
//   ② 月薪基数：批量保存、报表按基数折日工资
//   ③ 🔴 核心算法，每一条都是真金白银的口径：
//        迟到分档（≤30 一档 / >60 按分钟）、缺卡按次、旷工按天×日工资、
//        请假按天×日工资×比例、全勤奖（有出勤且零瑕疵才发）、加班费
//   ④ 报表是现算的：改了规则/删了打卡记录，重算结果立刻变 —— 不存快照
//   ⑤ 员工端只能看自己的工资条
//
// 场景全部落在**上个月**（整月已成历史，没有"未来卡"干扰判定）。

const { spawn } = require('child_process');
const path = require('path');
const fs = require('fs');
const os = require('os');

const PORT = 3734;
const BASE = `http://127.0.0.1:${PORT}`;
const SERVER_DIR = path.resolve(__dirname, '..');
const DATA_DIR = path.join(os.tmpdir(), 'xiaozhi-salary-e2e-' + Date.now());

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

/** 某天某时刻的时间戳（北京时区固定 +08:00，与服务器一致） */
function tsAt(day, hhmm) { return new Date(`${day}T${hhmm}:00+08:00`).getTime(); }

/** 上个月的 'YYYY-MM'（整月已成历史） */
function prevMonth() {
  const n = new Date();
  const d = new Date(Date.UTC(n.getUTCFullYear(), n.getUTCMonth() - 1, 1));
  return `${d.getUTCFullYear()}-${String(d.getUTCMonth() + 1).padStart(2, '0')}`;
}

/** 上个月的所有工作日（周一~周五）与所有休息日 */
function calendarOf(month) {
  const [y, m] = month.split('-').map(Number);
  const last = new Date(Date.UTC(y, m, 0)).getUTCDate();
  const workdays = [], restdays = [];
  for (let d = 1; d <= last; d++) {
    const day = `${month}-${String(d).padStart(2, '0')}`;
    const wd = new Date(Date.UTC(y, m - 1, d)).getUTCDay();
    (wd >= 1 && wd <= 5 ? workdays : restdays).push(day);
  }
  return { workdays, restdays };
}

let serverProc = null;
let serverLog = '';

async function startServer() {
  serverProc = spawn(process.execPath, [path.join(SERVER_DIR, 'src', 'index.js')], {
    env: {
      ...process.env, PORT: String(PORT), DATA_DIR,
      ADMIN_PASSWORD: 'TestAdmin_123', ATT_TIMEZONE: 'Asia/Shanghai',
    },
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

// ------------------------------------------------------------------ 主流程

(async () => {
  await startServer();
  console.log('[智能薪酬 E2E] 服务端已就绪 ' + BASE + '\n');

  const lg = await api('POST', '/api/auth/login', { body: { username: 'admin', password: 'TestAdmin_123' } });
  const admin = lg.body?.token;
  ok('管理员登录', !!admin);

  await api('PUT', '/api/admin/settings', { token: admin, body: { friendMode: 'work' } });
  let r = await api('POST', '/api/orgs', { token: admin, body: { name: '薪酬测试厂' } });
  const orgId = r.body?.id;
  ok('创建组织', r.status === 200 && !!orgId, JSON.stringify(r.body));

  async function addEmp(no, nickname) {
    const rr = await api('POST', `/api/orgs/${orgId}/members`, { token: admin, body: { employeeNo: no, nickname } });
    const tok = (await api('POST', '/api/auth/login', { body: { username: no, password: no } })).body?.token;
    return { id: rr.body?.user?.id, token: tok, no };
  }
  const e1 = await addEmp('emp01', '张三');
  const e2 = await addEmp('emp02', '李四');
  ok('录员工 emp01/emp02', !!e1.id && !!e2.id);

  // 班次：09:00-18:00 无休息 = 一天 2 次卡（全月补卡只补两张，场景才干净）
  await api('PUT', '/api/admin/attendance/config', {
    token: admin,
    body: { workdays: [1, 2, 3, 4, 5], enabled: true,
      defaultShift: { workStart: '09:00', workEnd: '18:00', restMinutes: 60, flexMinutes: 0, lateGrace: 0, earlyGrace: 0 } },
  });

  const month = prevMonth();
  const cal = calendarOf(month);
  ok('上个月的工作日数 ≥ 15（不然场景铺不开）', cal.workdays.length >= 15, `${month} 有 ${cal.workdays.length} 个工作日`);

  const [d1, d2, d3, d4] = cal.workdays;

  // 全月工作日补齐 09:00 / 18:00（e1、e2 都是全勤基线）
  const fix = (userId, day, type, time) =>
    api('POST', '/api/admin/attendance/records', { token: admin, body: { userId, day, type, time } });
  for (const day of cal.workdays) {
    for (const e of [e1, e2]) {
      await fix(e.id, day, 'in', '09:00');
      await fix(e.id, day, 'out', '18:00');
    }
  }

  // ---------------- 一：规则配置 ----------------
  console.log('\n【一】规则配置');
  r = await api('GET', `/api/admin/attendance/salary/config`, { token: admin });
  ok('默认配置可读（还没自定义）', r.status === 200 && r.body.config?.customized === false, JSON.stringify(r.body).slice(0, 200));
  ok('  出厂默认：迟到分两档 + 全勤奖 100 + 计薪 21.75 天',
    r.body.config?.lateTiers?.length === 2 && r.body.config?.fullAttendanceBonus === 100
    && r.body.config?.dayDivisor === 21.75, JSON.stringify(r.body.config));

  r = await api('GET', '/api/admin/attendance/salary/config');
  ok('未登录读配置 → 401', r.status === 401, JSON.stringify(r.body));
  r = await api('PUT', '/api/admin/attendance/salary/config', { token: e1.token, body: { missingCardDeduct: 1 } });
  ok('普通员工改配置 → 403', r.status === 403, JSON.stringify(r.body));

  r = await api('PUT', '/api/admin/attendance/salary/config',
    { token: admin, body: { missingCardDeduct: -5 } });
  ok('负数扣款 → 400（不写半条）', r.status === 400, JSON.stringify(r.body));
  r = await api('PUT', '/api/admin/attendance/salary/config',
    { token: admin, body: { lateTiers: [{ upTo: 60, amount: 50 }, { upTo: 30, amount: 20 }] } });
  ok('迟到档位不递增 → 400', r.status === 400, JSON.stringify(r.body));
  r = await api('PUT', '/api/admin/attendance/salary/config',
    { token: admin, body: { dayDivisor: 0 } });
  ok('计薪天数 0 → 400（要拿它做除数）', r.status === 400, JSON.stringify(r.body));
  r = await api('GET', `/api/admin/attendance/salary/config`, { token: admin });
  ok('非法值不会污染配置', r.body.config?.customized === false, JSON.stringify(r.body.config));

  r = await api('PUT', '/api/admin/attendance/salary/config', {
    token: admin,
    body: { lateTiers: [{ upTo: 30, amount: 20 }, { upTo: 60, amount: 50 }], latePerMinute: 2,
      missingCardDeduct: 50, absentDayDeductPct: 100, leaveDeductPct: 100,
      fullAttendanceBonus: 100, dayDivisor: 21.75, overtimePerHour: 0 },
  });
  ok('保存合法规则 → 200 且 customized=true', r.status === 200 && r.body.config?.customized === true, JSON.stringify(r.body).slice(0, 200));

  // ---------------- 二：月薪基数 ----------------
  console.log('\n【二】月薪基数（4350 / 21.75 = 日工资 200）');
  r = await api('PUT', '/api/admin/attendance/salary/bases',
    { token: admin, body: { items: [{ userId: e1.id, monthBase: 4350 }, { userId: e2.id, monthBase: 4350 }] } });
  ok('批量保存基数 → 200', r.status === 200, JSON.stringify(r.body));
  r = await api('PUT', '/api/admin/attendance/salary/bases',
    { token: admin, body: { items: [{ userId: e1.id, monthBase: -1 }] } });
  ok('负基数 → 400', r.status === 400, JSON.stringify(r.body));
  r = await api('GET', '/api/admin/attendance/salary/bases', { token: admin });
  ok('基数读回来', r.body.items?.find((x) => x.userId === e1.id)?.monthBase === 4350, JSON.stringify(r.body.items));

  // ---------------- 三：制造考勤事实 ----------------
  console.log('\n【三】制造考勤事实（迟到/缺卡/旷工/请假）');
  // e1: 第 1 个工作日迟到 20 分钟（覆盖 09:00 那张上班卡）
  r = await fix(e1.id, d1, 'in', '09:20');
  ok('e1 迟到卡覆盖成功 → 200', r.status === 200, JSON.stringify(r.body).slice(0, 160));
  // e1: 第 2 个工作日删掉下班卡 → 缺卡 1 次
  r = await api('GET', `/api/admin/attendance/records?day=${d2}&userId=${e1.id}`, { token: admin });
  const outRec = (r.body.items || []).find((x) => x.type === 'out');
  r = await api('DELETE', `/api/admin/attendance/records/${outRec?.id}`, { token: admin });
  ok('e1 删掉一天的下班卡（缺卡）→ 200', r.status === 200, JSON.stringify(r.body));
  // e1: 第 3 个工作日两张全删 → 旷工 1 天
  r = await api('GET', `/api/admin/attendance/records?day=${d3}&userId=${e1.id}`, { token: admin });
  for (const rec of r.body.items || []) {
    await api('DELETE', `/api/admin/attendance/records/${rec.id}`, { token: admin });
  }
  ok('e1 删掉一整天的卡（旷工）', true);
  // e1: 第 4 个工作日请假一天（员工申请 + 管理员通过）
  r = await api('POST', '/api/attendance/requests',
    { token: e1.token, body: { kind: 'leave', startDay: d4, endDay: d4, leaveType: 'personal', reason: '家中有事' } });
  const reqId = r.body?.id;
  ok('e1 提交请假申请', r.status === 200 && Number.isInteger(reqId), JSON.stringify(r.body));
  r = await api('POST', `/api/admin/attendance/requests/${reqId}/review`, { token: admin, body: { approve: true } });
  ok('管理员通过请假', r.status === 200, JSON.stringify(r.body).slice(0, 140));

  // ---------------- 四：月度报表 ----------------
  console.log('\n【四】月度报表（每一条都是钱）');
  // 🔍 调试：先看考勤报表本身长什么样（工资是拿它的结果算的）
  const dbg = await api('GET', `/api/admin/attendance/report?from=${month}-01&to=${month}-28`, { token: admin });
  for (const u of dbg.body?.users || []) {
    const miss = (u.days || []).filter((d) => (d.missingLabels || []).length > 0);
    console.log(`  [调试] ${u.username}: donePunches=${u.summary?.donePunches} missingPunches=${u.summary?.missingPunches} present=${u.summary?.present} 缺卡天=${miss.length} 首个=${JSON.stringify(miss[0] ? [miss[0].day, miss[0].missingLabels] : null)}`);
  }
  r = await api('GET', `/api/admin/attendance/salary/report?month=${month}`, { token: admin });
  ok('报表 → 200', r.status === 200, JSON.stringify(r.body).slice(0, 200));
  const s1 = (r.body.items || []).find((x) => x.userId === e1.id);
  const s2 = (r.body.items || []).find((x) => x.userId === e2.id);
  const byKey = (s, k) => (s?.items || []).find((x) => x.key === k);

  // e1：基数 4350 − 迟到 20 − 缺卡 50 − 旷工 200 − 请假 200 = 3880
  ok('e1 迟到 1 次 20 分钟 → 扣 20（第一档）',
    byKey(s1, 'late')?.amount === -20, JSON.stringify(byKey(s1, 'late')));
  ok('e1 缺卡 1 次 → 扣 50', byKey(s1, 'missing')?.amount === -50, JSON.stringify(byKey(s1, 'missing')));
  ok('e1 旷工 1 天 → 扣 200（日工资 200 × 100%）',
    byKey(s1, 'absent')?.amount === -200, JSON.stringify(byKey(s1, 'absent')));
  ok('e1 请假 1 天 → 扣 200（日工资 200 × 100%）',
    byKey(s1, 'leave')?.amount === -200, JSON.stringify(byKey(s1, 'leave')));
  ok('e1 没有全勤奖（有瑕疵不发）', byKey(s1, 'full') === undefined, JSON.stringify(s1?.items?.map((x) => x.key)));
  ok('e1 应发 = 4350 − 470 = 3880', s1?.net === 3880, JSON.stringify(s1?.net));
  ok('e1 扣款合计 470', s1?.deductions === 470, JSON.stringify(s1?.deductions));
  ok('e1 统计：迟到 1 次 20 分钟 / 缺卡 1 / 旷工 1 / 请假 1',
    s1?.stats?.lateCount === 1 && s1?.stats?.lateMinutes === 20 && s1?.stats?.missingCount === 1
    && s1?.stats?.absentDays === 1 && s1?.stats?.leaveDays === 1, JSON.stringify(s1?.stats));

  // e2：全月全勤 → 基数 + 全勤奖
  ok('e2 全勤奖 100', byKey(s2, 'full')?.amount === 100, JSON.stringify(byKey(s2, 'full')));
  ok('e2 没有任何扣款', s2?.deductions === 0, JSON.stringify(s2?.deductions));
  ok('e2 应发 = 4350 + 100 = 4450', s2?.net === 4450, JSON.stringify(s2?.net));
  ok('全员合计 = 8330', r.body.totalNet === 8330, JSON.stringify(r.body.totalNet));

  // ---------------- 五：规则改了立刻生效（不存快照） ----------------
  console.log('\n【五】改规则重算立刻生效');
  r = await api('PUT', '/api/admin/attendance/salary/config',
    { token: admin, body: { missingCardDeduct: 80, fullAttendanceBonus: 200, overtimePerHour: 60 } });
  ok('改规则 → 200', r.status === 200, JSON.stringify(r.body).slice(0, 160));
  // e2 在某个周六提交加班申请（09:00-17:00）并获批准。
  // 🔴 加班时长来自**审批通过的加班申请单**，不是休息日打卡 —— 钉钉同口径：
  //    "来了就算加班"会被滥用（周六顺路来逛一圈也成加班），必须有审批兜底。
  const sat = cal.restdays[0];
  r = await api('POST', '/api/attendance/requests', {
    token: e2.token,
    body: { kind: 'overtime', reason: '周六盘点',
      startAt: tsAt(sat, '09:00'), endAt: tsAt(sat, '17:00') },
  });
  const otId = r.body?.id;
  ok('e2 提交周六加班申请', r.status === 200 && Number.isInteger(otId), JSON.stringify(r.body));
  r = await api('POST', `/api/admin/attendance/requests/${otId}/review`, { token: admin, body: { approve: true } });
  ok('管理员通过加班申请', r.status === 200, JSON.stringify(r.body).slice(0, 140));
  // 周六再来一张 09:20 的上班卡：休息日打卡算加班**不算迟到**（迟到 20 分钟
  // 那档只会因为工作日那张触发）。没有这条，"休息日迟到计费"的回归测不出来。
  r = await fix(e2.id, sat, 'in', '09:20');
  ok('e2 周六补一张 09:20 上班卡（休息日打卡）→ 200', r.status === 200, JSON.stringify(r.body).slice(0, 140));
  r = await api('GET', `/api/admin/attendance/salary/report?month=${month}`, { token: admin });
  const s1b = (r.body.items || []).find((x) => x.userId === e1.id);
  const s2b = (r.body.items || []).find((x) => x.userId === e2.id);
  ok('缺卡单价 50→80：e1 缺卡项变 −80',
    (s1b?.items || []).find((x) => x.key === 'missing')?.amount === -80,
    JSON.stringify((s1b?.items || []).find((x) => x.key === 'missing')));
  ok('e1 应发跟着变 = 4350 − (20+80+200+200) = 3850', s1b?.net === 3850, JSON.stringify(s1b?.net));
  ok('全勤奖 100→200：e2 全勤项变 +200',
    (s2b?.items || []).find((x) => x.key === 'full')?.amount === 200,
    JSON.stringify((s2b?.items || []).find((x) => x.key === 'full')));
  ok('e2 休息日加班 480 分钟 × 60 元/时 → 加班费 +480',
    (s2b?.items || []).find((x) => x.key === 'overtime')?.amount === 480,
    JSON.stringify((s2b?.items || []).find((x) => x.key === 'overtime')));
  ok('🔴 休息日打卡不算迟到（周六那张 09:20 没有触发迟到档）',
    s2b?.stats?.lateCount === 0, JSON.stringify(s2b?.stats));
  ok('e2 应发 = 4350 + 200 + 480 = 5030', s2b?.net === 5030, JSON.stringify(s2b?.net));

  // ---------------- 六：员工端只看自己 ----------------
  console.log('\n【六】员工端工资条');
  r = await api('GET', `/api/attendance/salary?month=${month}`, { token: e1.token });
  ok('员工端 → 200 且 net 与报表一致', r.status === 200 && r.body.net === 3850, JSON.stringify(r.body).slice(0, 240));
  ok('  只有自己的那份', (r.body.items || []).length > 0 && r.body.username === 'emp01', JSON.stringify(r.body.username));
  r = await api('GET', `/api/admin/attendance/salary/report?month=${month}`, { token: e1.token });
  ok('员工端拉全员报表 → 403', r.status === 403, JSON.stringify(r.body));

  // ---------------- 收尾 ----------------
  console.log(`\n结果：${passed} 通过 / ${failed} 失败`);
  if (failed) {
    console.log('\n失败项：');
    for (const f of failures) console.log('  - ' + f);
  }
  stopServer();
  process.exit(failed ? 1 : 0);
})().catch((e) => {
  console.error('E2E 崩溃：', e);
  console.error(serverLog.slice(-2000));
  stopServer();
  process.exit(1);
});
