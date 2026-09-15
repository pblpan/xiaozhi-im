/**
 * 考勤接口（工作模式下随工作模式一起启用）
 *
 * 分成两个 router：
 *   router       → /api/attendance        员工端（打卡、我的考勤、我的申请）
 *   admin        → /api/admin/attendance  管理端（看板、报表、班次/考勤组、审批、手工修正）
 *
 * 门禁口径统一在 guard() 里，避免出现"员工端拒绝、管理端放行"这种自相矛盾
 * （组织机构那轮就踩过：POST 有 requireWorkMode、PUT/DELETE 忘了，结果是
 * "能加不能改"，很难解释）。所以这里写成一个函数，谁都得过。
 */
const express = require('express');
const db = require('../db');
const { verifyToken } = require('../auth');
const settings = require('../settings');
const att = require('../attendance');

const router = express.Router();
const admin = express.Router();

const MAX_ADDRESS = 120;

function authOf(req, res, { needAdmin = false } = {}) {
  const c = verifyToken(req.headers.authorization?.replace('Bearer ', ''));
  if (!c) { res.status(401).json({ error: 'unauthorized' }); return null; }
  const u = db.prepare('SELECT id,role,org_id,nickname,username,employee_no,dept_id,position_id FROM users WHERE id=?').get(c.uid);
  if (!u) { res.status(401).json({ error: 'unauthorized' }); return null; }
  if (needAdmin && u.role !== 'admin') { res.status(403).json({ error: 'forbidden' }); return null; }
  return u;
}

function theOrg() {
  return db.prepare('SELECT id, name, created_by FROM orgs LIMIT 1').get() || null;
}

/** 是否处于"考勤生效"的状态：工作模式 + 考勤开启 + 组织存在 */
function state() {
  const org = theOrg();
  return {
    org,
    workMode: settings.get('friendMode') === 'work',
    enabled: settings.get('attendanceEnabled') !== false,
  };
}

/**
 * 员工端门禁：返回员工上下文，或已响应错误并返回 null。
 * 考勤只对"组织员工"开放 —— 管理员账号没有 org_id，也就没有考勤资格。
 */
function guard(req, res) {
  const u = authOf(req, res); if (!u) return null;
  const st = state();
  if (!st.workMode) { res.status(400).json({ error: '当前是普通好友模式，未启用考勤' }); return null; }
  if (!st.enabled) { res.status(400).json({ error: '管理员已停用考勤' }); return null; }
  if (!st.org) { res.status(400).json({ error: '尚未创建组织，考勤不可用' }); return null; }
  if (!u.org_id || u.org_id !== st.org.id) {
    res.status(403).json({ error: '当前账号不在组织中，无需打卡' });
    return null;
  }
  return { u, org: st.org };
}

/** 管理端门禁：admin + 组织存在（不要求工作模式，管理员需要能提前配好班次） */
function adminGuard(req, res) {
  const u = authOf(req, res, { needAdmin: true }); if (!u) return null;
  const st = state();
  if (!st.org) { res.status(404).json({ error: '尚未创建组织' }); return null; }
  return { u, org: st.org };
}

/** 今天是否工作日 + 今天要不要打卡（客户端据此决定显示"今天休息"） */
function needClockToday(day = att.today()) {
  const workdays = settings.get('attWorkdays') || [1, 2, 3, 4, 5];
  return workdays.includes(att.weekdayOf(day));
}

/* ============================================================
 * 员工端
 * ============================================================ */

/** 班次对客户端的展示形态（含"一天几次卡"与休息时段） */
function shiftView(s) {
  return {
    name: s.name, workStart: s.workStart, workEnd: s.workEnd,
    restStart: s.restStart, restEnd: s.restEnd,
    segments: s.segments, punchesPerDay: s.punchesPerDay,
    crossDay: s.crossDay, restMinutes: s.restMinutes,
    flexMinutes: s.flexMinutes, lateGrace: s.lateGrace, earlyGrace: s.earlyGrace,
    // 一个班次应出勤多少分钟（两个在岗段之和）。客户端拿它显示"应出勤 8 小时"，
    // 不用自己拿 下班-上班-休息 再算一遍 —— 少一处能算错的地方
    expectedWorkMinutes: s.expectedWorkMinutes,
  };
}

/**
 * 打卡计划的展示形态 —— 客户端打卡页的按钮直接照它渲染。
 * 每个 item 都带齐"该打几点、打没打、打的几点、什么状态、迟到早退几分钟"，
 * 客户端一条判断都不用自己写：口径只存在服务端一处，才不会出现
 * "我这边显示正常、后台报表显示迟到"这种互相打脸的情况。
 */
function punchView(day) {
  return (day.punches || []).map((p) => ({
    key: p.key, type: p.type, slot: p.slot, label: p.label,
    expectTime: p.expectTime, expectAt: p.expectAt,
    time: p.at == null ? null : att.hhmmOf(p.at), at: p.at,
    done: p.done, due: p.due, exempt: p.exempt, status: p.status,
    lateMinutes: p.lateMinutes, earlyMinutes: p.earlyMinutes,
  }));
}

/** 今日状态：客户端打卡页一次拉全（班次、我的卡、今日判定、本月汇总、待办） */
router.get('/today', (req, res) => {
  const u = authOf(req, res); if (!u) return;
  const st = state();
  // 未启用的状态也返回 200：客户端要显示"考勤未启用"的说明页，而不是弹错误
  if (!st.workMode || !st.enabled || !st.org || !u.org_id || u.org_id !== st.org.id) {
    return res.json({
      available: false,
      workMode: st.workMode,
      enabled: st.enabled,
      reason: !st.workMode ? '当前是普通好友模式，考勤由管理员在开启工作模式后启用'
        : (!st.enabled ? '考勤已被管理员停用'
          : (!st.org ? '尚未创建组织' : '当前账号不在组织中，无需打卡')),
      serverTime: Date.now(),
      timezone: att.TZ,
    });
  }

  const now = Date.now();
  const day = att.dayOf(now);
  const { shift, group, source } = att.shiftFor(u.id, st.org.id);
  const recs = att.recordsRange(st.org.id, att.addDays(day, -1), att.addDays(day, 1), [u.id]);
  const reqs = db.prepare("SELECT * FROM att_requests WHERE user_id=? AND status='approved'").all(u.id);
  const workdays = settings.get('attWorkdays') || [1, 2, 3, 4, 5];
  const today = att.judgeDay({ day, now, shift, recs, reqs, workdays });
  const month = att.myRange({ id: u.id }, st.org.id, day.slice(0, 8) + '01', day, now);

  res.json({
    available: true,
    serverTime: now,
    timezone: att.TZ,
    date: day,
    dayOfWeek: att.weekdayOf(day),
    isWorkday: needClockToday(day),
    shift: shiftView(shift),
    /** 今天该打哪几次卡 + 每次的实况。按钮就照这个渲染 */
    punchPlan: punchView(today),
    group: group ? { id: group.id, name: group.name, locationMode: group.locationMode } : null,
    shiftSource: source,
    /**
     * 兼容字段：最早上班卡 / 最晚下班卡。
     * 老客户端还在读它，别删 —— 但新客户端请用 punchPlan —— 那张表才知道该打几张、哪一张属于哪一段。
     */
    cards: {
      in: today.firstIn == null ? null : { at: today.firstIn, time: today.firstInTime, count: recs.filter((r) => r.type === 'in' && r.day === day).length },
      out: today.lastOut == null ? null : { at: today.lastOut, time: today.lastOutTime, count: recs.filter((r) => r.type === 'out' && r.day === day).length },
    },
    today: {
      status: today.status, statusLabel: att.STATUS_LABEL[today.status] || today.status,
      note: today.note, lateMinutes: today.lateMinutes, earlyMinutes: today.earlyMinutes,
      leave: today.leave, outing: today.outing,
      donePunches: today.donePunches, expectedPunches: today.expectedPunches,
      missingLabels: today.missingLabels,
      workedMinutes: today.workedMinutes, expectedWorkMinutes: today.expectedWorkMinutes,
    },
    monthSummary: month.summary,
    pendingRequests: db.prepare("SELECT COUNT(*) AS c FROM att_requests WHERE user_id=? AND status='pending'").get(u.id).c,
    workdays,
  });
});

/**
 * 打卡。
 * body: { type:'in'|'out', slot:1|2, lat, lng, address, device }
 * 时间一律以**服务器时钟**为准（客户端传 at 会被忽略）——
 * 否则改一次手机时间就能随便补卡，考勤数据立刻失去意义。
 */
router.post('/clock', (req, res) => {
  const g = guard(req, res); if (!g) return;
  const type = String(req.body?.type || '');
  if (!['in', 'out'].includes(type)) return res.status(400).json({ error: '打卡类型不正确' });

  const now = Date.now();
  const day = att.dayOf(now);
  const { shift, group } = att.shiftFor(g.u.id, g.org.id);

  // 一天 4 次卡的班次才有第 2 段。不拦的话会凭空多出"下午上班卡"，
  // 而判定计划里根本没有它 —— 员工以为自己打了卡，报表上还是缺卡。
  const slot = att.slotOf(req.body?.slot);
  if (slot == null) return res.status(400).json({ error: '第几次卡只能是 1 或 2' });
  if (slot > shift.segments) {
    return res.status(400).json({
      error: `当前班次一天打 ${shift.punchesPerDay} 次卡（${shift.workStart}-${shift.workEnd}），没有第 ${slot} 次卡`,
    });
  }

  // 定位要求：required 时必须有坐标；optional/off 有就记下来
  const mode = group?.locationMode || 'off';
  const hasLoc = Number.isFinite(Number(req.body?.lat)) && Number.isFinite(Number(req.body?.lng))
    && !(Number(req.body?.lat) === 0 && Number(req.body?.lng) === 0);
  if (mode === 'required' && !hasLoc) {
    return res.status(400).json({ error: '本考勤组要求打卡时提供定位，请允许客户端获取位置后重试' });
  }

  const r = att.clock({
    userId: g.u.id, orgId: g.org.id, type, slot, at: now,
    lat: hasLoc ? Number(req.body.lat) : null,
    lng: hasLoc ? Number(req.body.lng) : null,
    address: req.body?.address ? String(req.body.address).slice(0, MAX_ADDRESS) : null,
    device: req.body?.device ? String(req.body.device).slice(0, 80) : null,
    source: 'app',
  });
  if (r.error) return res.status(400).json({ error: r.error });

  // 打完卡立刻把判定结果一起返回：客户端不用再拉一次 today（弱网下少一次失败机会）
  const recs = att.recordsRange(g.org.id, att.addDays(day, -1), att.addDays(day, 1), [g.u.id]);
  const reqs = db.prepare("SELECT * FROM att_requests WHERE user_id=? AND status='approved'").all(g.u.id);
  const workdays = settings.get('attWorkdays') || [1, 2, 3, 4, 5];
  const today = att.judgeDay({ day, now, shift, recs, reqs, workdays });

  res.json({
    ok: true,
    updated: !!r.updated,
    record: r.record,
    serverTime: now,
    punchPlan: punchView(today),
    today: {
      status: today.status, statusLabel: att.STATUS_LABEL[today.status] || today.status,
      note: today.note, lateMinutes: today.lateMinutes, earlyMinutes: today.earlyMinutes,
      donePunches: today.donePunches, expectedPunches: today.expectedPunches,
      workedMinutes: today.workedMinutes,
    },
    message: `${att.punchLabelOf(shift, type + slot)}打卡成功 ${att.hhmmOf(now)}${r.updated ? '（已更新今天这张卡）' : ''}`,
  });
});

/** 我的考勤明细：month=YYYY-MM（默认当月） */
router.get('/my', (req, res) => {
  const u = authOf(req, res); if (!u) return;
  const st = state();
  if (!st.workMode || !st.enabled || !st.org || !u.org_id) {
    return res.json({ available: false, days: [], summary: null, serverTime: Date.now() });
  }
  const now = Date.now();
  const month = /^\d{4}-\d{2}$/.test(String(req.query.month || '')) ? String(req.query.month) : att.today(now).slice(0, 7);
  const [y, m] = month.split('-').map(Number);
  const lastDay = new Date(Date.UTC(y, m, 0)).getUTCDate();
  const from = `${month}-01`;
  const to = `${month}-${String(lastDay).padStart(2, '0')}`;
  const r = att.myRange({ id: u.id }, st.org.id, from, to, now);
  res.json({
    available: true,
    month, from, to,
    serverTime: now,
    timezone: att.TZ,
    shift: shiftView(r.shift),
    group: r.group ? { id: r.group.id, name: r.group.name, locationMode: r.group.locationMode } : null,
    days: r.days.map((d) => ({
      day: d.day, weekday: d.weekday, isWorkday: d.isWorkday, status: d.status,
      statusLabel: att.STATUS_LABEL[d.status] || d.status, note: d.note,
      firstInTime: d.firstInTime, lastOutTime: d.lastOutTime,
      lateMinutes: d.lateMinutes, earlyMinutes: d.earlyMinutes, leave: d.leave, outing: d.outing,
      overtimeMinutes: d.overtimeMinutes,
      // 4 次卡：明细页要能一条条列出"上班 / 下班 / 上班 / 下班"（每条自带应打时刻）
      punches: punchView(d),
      donePunches: d.donePunches, expectedPunches: d.expectedPunches,
      missingLabels: d.missingLabels,
      workedMinutes: d.workedMinutes, expectedWorkMinutes: d.expectedWorkMinutes,
    })),
    summary: r.summary,
  });
});

/** 我的打卡流水（某天，含被更新过的多条，便于自己核对） */
router.get('/records', (req, res) => {
  const u = authOf(req, res); if (!u) return;
  const st = state();
  if (!st.org || !u.org_id) return res.json({ available: false, items: [] });
  const day = att.isValidDay(req.query.day) ? String(req.query.day) : att.today();
  // 带上班次：同一张 out/1 在 2 次卡里就是收工、在 4 次卡里只是第 1 段结束，
  // 不把班次一起给出来，客户端就只能显示一个含糊的"下班卡"。
  const shift = att.shiftFor(u.id, st.org.id).shift;
  const items = att.recordsOn(u.id, day)
    .map((r) => ({ ...r, punchLabel: att.punchLabelOf(shift, r.punchKey) }));
  res.json({
    available: true, day,
    shift: shiftView(shift),
    plan: att.punchPlan(shift, day).map((p) => ({
      key: p.key, type: p.type, slot: p.slot, label: att.punchLabelOf(shift, p.key),
      expectTime: p.hhmm, expectAt: p.at,
    })),
    items,
  });
});

/* ---------------- 申请（请假 / 补卡 / 外出 / 加班） ---------------- */

router.get('/requests', (req, res) => {
  const g = guard(req, res); if (!g) return;
  res.json({
    items: att.listRequests({
      orgId: g.org.id, userId: g.u.id,
      status: req.query.status ? String(req.query.status) : null,
      kind: req.query.kind ? String(req.query.kind) : null,
      limit: Number(req.query.limit) || 100,
    }),
    leaveTypes: att.LEAVE_TYPES,
  });
});

router.post('/requests', (req, res) => {
  const g = guard(req, res); if (!g) return;
  const b = req.body || {};
  const r = att.createRequest({
    orgId: g.org.id, userId: g.u.id,
    kind: String(b.kind || ''),
    reason: b.reason,
    startDay: b.startDay, endDay: b.endDay, half: b.half, leaveType: b.leaveType,
    day: b.day, clockType: b.clockType, slot: b.slot, at: Number(b.at) || null,
    startAt: Number(b.startAt) || null, endAt: Number(b.endAt) || null,
  });
  if (r.error) return res.status(400).json({ error: r.error });
  res.json({ ok: true, id: r.id, message: '申请已提交，等待管理员审批' });
});

/** 撤销自己的待审批申请 */
router.post('/requests/:id/cancel', (req, res) => {
  const g = guard(req, res); if (!g) return;
  const id = Number(req.params.id);
  const r = db.prepare('SELECT id, status FROM att_requests WHERE id=? AND user_id=?').get(id, g.u.id);
  if (!r) return res.status(404).json({ error: '申请不存在' });
  if (r.status !== 'pending') return res.status(400).json({ error: '只能撤销待审批的申请' });
  db.prepare("UPDATE att_requests SET status='canceled' WHERE id=?").run(id);
  res.json({ ok: true, message: '已撤销' });
});

/* ============================================================
 * 管理端
 * ============================================================ */

/** 考勤配置总览（含服务器时间与时区 —— 打卡时间对不上时第一个要看这里） */
admin.get('/config', (req, res) => {
  const g = adminGuard(req, res); if (!g) return;
  const eff = att.defaultShift();
  res.json({
    org: g.org,
    friendMode: settings.get('friendMode'),
    enabled: settings.get('attendanceEnabled') !== false,
    // 默认班次：**可编辑的存储值 + 归一化后的派生值合并成一个对象**。
    //   只给存储值的话，管理台就不知道"这个班次一天打几次卡、应出勤多少小时"，
    //   只能自己拿 上班/下班/休息 再减一遍 —— 那正是口径分家的起点。
    //   归一化值覆盖同名键（restStart 等在休息时段不成立时会是 null），
    //   所以界面看到的永远是**真正生效**的形状。
    //   写回时 cleanShift 只认它自己那几个键，多出来的派生字段会被忽略，往返安全。
    defaultShift: { ...(settings.get('attDefaultShift') || {}), ...shiftView(eff) },
    workdays: settings.get('attWorkdays'),
    serverTime: Date.now(),
    timezone: att.TZ,
    effectiveDefaultShift: shiftView(eff),
  });
});

admin.put('/config', (req, res) => {
  const g = adminGuard(req, res); if (!g) return;
  const b = req.body || {};
  const patch = {};
  if (b.enabled !== undefined) patch.attendanceEnabled = !!b.enabled;
  if (b.defaultShift !== undefined) patch.attDefaultShift = b.defaultShift;
  if (b.workdays !== undefined) patch.attWorkdays = b.workdays;
  if (!Object.keys(patch).length) return res.status(400).json({ error: '无修改内容' });
  const r = settings.update(patch, g.u.username);
  if (r.error) return res.status(400).json({ error: r.error });
  res.json({ ok: true, enabled: settings.get('attendanceEnabled'), defaultShift: settings.get('attDefaultShift'), workdays: settings.get('attWorkdays') });
});

/** 今日（或指定日）打卡看板：谁打了、谁没打、谁迟到 —— 未打卡的人也要列出 */
admin.get('/overview', (req, res) => {
  const g = adminGuard(req, res); if (!g) return;
  const day = att.isValidDay(req.query.day) ? String(req.query.day) : att.today();
  const o = att.overview({ orgId: g.org.id, day });
  res.json(o);
});

/** 报表：区间汇总（按部门/人员维度），一次算完 */
admin.get('/report', (req, res) => {
  const g = adminGuard(req, res); if (!g) return;
  const now = Date.now();
  const today = att.today(now);
  const to = att.isValidDay(req.query.to) ? String(req.query.to) : today;
  const from = att.isValidDay(req.query.from) ? String(req.query.from) : att.addDays(to, -29);

  const where = ['u.org_id=?', 'u.is_bot=0'];
  const args = [g.org.id];
  if (req.query.deptId) {
    // 向下展开到子孙部门：选「生产部」必须能看到「包装车间」的人，
    // 否则管理者会以为子部门员工不属于该部门（上一版就是这么错的）
    const chain = att.deptWithDescendants(Number(req.query.deptId), g.org.id);
    if (!chain.length) return res.json({ from, to, users: [], totals: null });
    where.push(`u.dept_id IN (${chain.map(() => '?').join(',')})`);
    args.push(...chain);
  }
  const users = db.prepare(`SELECT u.id,u.username,u.nickname,u.employee_no,u.dept_id,
      d.name AS dept_name, p.name AS position_name
    FROM users u LEFT JOIN org_depts d ON d.id=u.dept_id LEFT JOIN org_positions p ON p.id=u.position_id
    WHERE ${where.join(' AND ')} ORDER BY u.dept_id, u.id`).all(...args);

  const r = att.judgeRange({ orgId: g.org.id, users, from, to, now });
  // 组织级合计：管理者最先看的是"这个月整体怎么样"
  const totals = r.users.reduce((a, x) => {
    for (const k of Object.keys(x.summary)) {
      if (typeof x.summary[k] === 'number') a[k] = (a[k] || 0) + x.summary[k];
    }
    return a;
  }, { people: r.users.length });
  totals.leave = Math.round((totals.leave || 0) * 10) / 10;
  res.json({ ...r, totals, serverTime: now });
});

/** 打卡流水明细（可按人/日过滤，管理台"修正"用） */
admin.get('/records', (req, res) => {
  const g = adminGuard(req, res); if (!g) return;
  const now = Date.now();
  const day = att.isValidDay(req.query.day) ? String(req.query.day) : null;
  const from = att.isValidDay(req.query.from) ? String(req.query.from) : null;
  const to = att.isValidDay(req.query.to) ? String(req.query.to) : null;
  const where = ['r.org_id=?'];
  const args = [g.org.id];
  if (req.query.userId) { where.push('r.user_id=?'); args.push(Number(req.query.userId)); }
  if (day) { where.push('r.day=?'); args.push(day); }
  if (from && to) { where.push('r.day>=? AND r.day<=?'); args.push(from, to); }
  if (!day && !(from && to)) { where.push('r.day>=?'); args.push(att.addDays(att.today(now), -30)); }
  const rows = db.prepare(`SELECT r.*, u.username, u.nickname, u.employee_no
    FROM att_records r LEFT JOIN users u ON u.id=r.user_id
    WHERE ${where.join(' AND ')} ORDER BY r.at DESC LIMIT 1000`).all(...args);
  // 带上"这是哪一张卡"：光看 in/out 分不清"第 1 段结束"和"收工"，
  // 管理员修正时点错一张，员工当天就多一条错记录
  const shiftCache = new Map();
  const items = rows.map((r) => {
    const rec = att.decorateRecord(r);
    const { shift } = att.shiftForCached
      ? att.shiftForCached(r.user_id, g.org.id, shiftCache)
      : att.shiftFor(r.user_id, g.org.id);
    rec.punchLabel = att.punchLabelOf(shift, rec.punchKey);
    return rec;
  });
  res.json({ items });
});

/** 管理员补卡/修正：直接写一条记录（source='admin'） */
admin.post('/records', (req, res) => {
  const g = adminGuard(req, res); if (!g) return;
  const b = req.body || {};
  const userId = Number(b.userId);
  const day = String(b.day || '');
  const type = String(b.type || '');
  if (!att.isValidDay(day)) return res.status(400).json({ error: '日期不合法' });
  if (!['in', 'out'].includes(type)) return res.status(400).json({ error: '打卡类型只能是 in/out' });
  const u = db.prepare('SELECT id, org_id FROM users WHERE id=?').get(userId);
  if (!u || u.org_id !== g.org.id) return res.status(404).json({ error: '该用户不是本组织员工' });
  const hhmm = String(b.time || '');
  if (!att.parseHHMM(hhmm)) return res.status(400).json({ error: '时间需为 HH:MM' });
  // 第几段：4 次卡的班次才有第 2 段。不管的话管理员能给 2 次卡的人补出一张
  // 永远不被判定的孤儿卡（看着补上了，考勤结果没变）
  const slot = att.slotOf(b.slot);
  if (slot == null) return res.status(400).json({ error: '第几次卡只能是 1 或 2' });
  const { shift } = att.shiftFor(userId, g.org.id);
  if (slot > shift.segments) {
    return res.status(400).json({ error: `该员工班次一天打 ${shift.punchesPerDay} 次卡，没有第 ${slot} 次卡` });
  }
  const at = att.tsOfDay(day, hhmm);
  const r = att.clock({
    userId, orgId: g.org.id, type, slot, at, source: 'admin',
    addressNote: b.note ? String(b.note).slice(0, 100) : '管理员修正',
  });
  if (r.error) return res.status(400).json({ error: r.error });
  res.json({ ok: true, record: r.record });
});

admin.delete('/records/:id', (req, res) => {
  const g = adminGuard(req, res); if (!g) return;
  const r = db.prepare('DELETE FROM att_records WHERE id=? AND org_id=?').run(Number(req.params.id), g.org.id);
  if (!r.changes) return res.status(404).json({ error: '记录不存在' });
  res.json({ ok: true });
});

/* ---------------- 班次 ---------------- */

admin.get('/shifts', (req, res) => {
  const g = adminGuard(req, res); if (!g) return;
  res.json({ items: att.listShifts(g.org.id), defaultShift: att.defaultShift() });
});

function shiftPayload(b) {
  const name = String(b.name || '').trim();
  if (!name || [...name].length > 20) return { error: '班次名称必填，最多 20 个字' };
  // 时间与休息时段的校验**复用** settings.cleanShift：
  // 默认班次和命名班次必须是同一套规则，否则迟早出现
  // "默认班次能存休息 12:00、命名班次却报错"这种自相矛盾的行为。
  const c = settings.cleanShift({
    workStart: b.workStart, workEnd: b.workEnd,
    restStart: b.restStart, restEnd: b.restEnd,
    restMinutes: b.restMinutes, flexMinutes: b.flexMinutes,
    lateGrace: b.lateGrace, earlyGrace: b.earlyGrace,
  });
  if (c.error) return c;
  const v = c.value;
  return {
    value: {
      name,
      work_start: v.workStart,
      work_end: v.workEnd,
      rest_start: v.restStart || null,
      rest_end: v.restEnd || null,
      rest_minutes: v.restMinutes, flex_minutes: v.flexMinutes,
      late_grace: v.lateGrace, early_grace: v.earlyGrace,
      cross_day: att.parseHHMM(v.workEnd) <= att.parseHHMM(v.workStart) ? 1 : 0,
      enabled: b.enabled === undefined ? 1 : (b.enabled ? 1 : 0),
      sort: Number(b.sort) || 0,
    },
  };
}

admin.post('/shifts', (req, res) => {
  const g = adminGuard(req, res); if (!g) return;
  const p = shiftPayload(req.body || {});
  if (p.error) return res.status(400).json({ error: p.error });
  const v = p.value;
  const info = db.prepare(`INSERT INTO att_shifts
    (org_id,name,work_start,work_end,rest_start,rest_end,rest_minutes,flex_minutes,late_grace,early_grace,cross_day,enabled,sort,created_at)
    VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)`)
    .run(g.org.id, v.name, v.work_start, v.work_end, v.rest_start, v.rest_end,
      v.rest_minutes, v.flex_minutes, v.late_grace, v.early_grace, v.cross_day, v.enabled, v.sort, Date.now());
  res.json({ ok: true, id: info.lastInsertRowid, message: '班次已新增' });
});

admin.put('/shifts/:id', (req, res) => {
  const g = adminGuard(req, res); if (!g) return;
  const id = Number(req.params.id);
  if (!db.prepare('SELECT id FROM att_shifts WHERE id=? AND org_id=?').get(id, g.org.id)) {
    return res.status(404).json({ error: '班次不存在' });
  }
  const p = shiftPayload(req.body || {});
  if (p.error) return res.status(400).json({ error: p.error });
  const v = p.value;
  db.prepare(`UPDATE att_shifts SET name=?,work_start=?,work_end=?,rest_start=?,rest_end=?,
    rest_minutes=?,flex_minutes=?,late_grace=?,early_grace=?,cross_day=?,enabled=?,sort=? WHERE id=?`)
    .run(v.name, v.work_start, v.work_end, v.rest_start, v.rest_end,
      v.rest_minutes, v.flex_minutes, v.late_grace, v.early_grace, v.cross_day, v.enabled, v.sort, id);
  res.json({ ok: true, message: '已保存' });
});

admin.delete('/shifts/:id', (req, res) => {
  const g = adminGuard(req, res); if (!g) return;
  const id = Number(req.params.id);
  const used = db.prepare('SELECT COUNT(*) AS c FROM att_groups WHERE shift_id=?').get(id).c;
  // 直接删会让考勤组悄悄退回默认班次，判定结果瞬间变化而没人知道，所以挡住
  if (used > 0) return res.status(400).json({ error: `有 ${used} 个考勤组正在使用该班次，请先改掉` });
  const r = db.prepare('DELETE FROM att_shifts WHERE id=? AND org_id=?').run(id, g.org.id);
  if (!r.changes) return res.status(404).json({ error: '班次不存在' });
  res.json({ ok: true, message: '已删除' });
});

/* ---------------- 考勤组 ---------------- */

function groupDetail(row) {
  const deptIds = db.prepare('SELECT dept_id FROM att_group_depts WHERE group_id=?').all(row.id).map((r) => r.dept_id);
  const memberIds = db.prepare('SELECT user_id FROM att_group_members WHERE group_id=?').all(row.id).map((r) => r.user_id);
  const shift = row.shift_id ? db.prepare('SELECT * FROM att_shifts WHERE id=?').get(row.shift_id) : null;
  // 实际人数必须与判定口径一致（显式成员 ∪ 部门含子部门内的人），
  // 否则会出现"界面显示 5 人、实际按 7 人算考勤"这种对不上的情况
  const memberCount = att.groupMemberIds(row, row.org_id).size;
  const shiftViewObj = shift ? att.listShifts(row.org_id).find((s) => s.id === shift.id) : null;
  return {
    id: row.id, name: row.name, shiftId: row.shift_id,
    shiftName: shift ? shift.name : '默认班次',
    // 给完整的班次形态（含休息时段与"一天几次卡"），管理台才显示得清
    // "这个组是一天 4 次卡还是一天 2 次卡"
    shift: shiftViewObj ? {
      name: shiftViewObj.name, workStart: shiftViewObj.workStart, workEnd: shiftViewObj.workEnd,
      restStart: shiftViewObj.restStart, restEnd: shiftViewObj.restEnd,
      segments: shiftViewObj.segments, punchesPerDay: shiftViewObj.punchesPerDay,
    } : (() => {
      const d = att.defaultShift();
      return {
        name: d.name, workStart: d.workStart, workEnd: d.workEnd,
        restStart: d.restStart, restEnd: d.restEnd,
        segments: d.segments, punchesPerDay: d.punchesPerDay,
      };
    })(),
    locationMode: row.location_mode || 'off',
    deptIds, memberIds, memberCount,
  };
}

admin.get('/groups', (req, res) => {
  const g = adminGuard(req, res); if (!g) return;
  const rows = db.prepare('SELECT * FROM att_groups WHERE org_id=? ORDER BY id').all(g.org.id);
  res.json({ items: rows.map(groupDetail) });
});

function groupPayload(b) {
  const name = String(b.name || '').trim();
  if (!name || [...name].length > 20) return { error: '考勤组名称必填，最多 20 个字' };
  const mode = ['off', 'optional', 'required'].includes(b.locationMode) ? b.locationMode : 'off';
  return { value: { name, shift_id: b.shiftId ? Number(b.shiftId) : null, location_mode: mode } };
}

/** 写成员关系（先删后插，简单且幂等） */
function setGroupRelations(groupId, orgId, deptIds = [], memberIds = []) {
  db.prepare('DELETE FROM att_group_depts WHERE group_id=?').run(groupId);
  db.prepare('DELETE FROM att_group_members WHERE group_id=?').run(groupId);
  const insD = db.prepare('INSERT OR IGNORE INTO att_group_depts (group_id,dept_id) VALUES (?,?)');
  for (const d of deptIds) {
    if (db.prepare('SELECT id FROM org_depts WHERE id=? AND org_id=?').get(Number(d), orgId)) insD.run(groupId, Number(d));
  }
  const insM = db.prepare('INSERT OR IGNORE INTO att_group_members (group_id,user_id) VALUES (?,?)');
  for (const u of memberIds) {
    if (db.prepare('SELECT id FROM users WHERE id=? AND org_id=?').get(Number(u), orgId)) insM.run(groupId, Number(u));
  }
}

admin.post('/groups', (req, res) => {
  const g = adminGuard(req, res); if (!g) return;
  const p = groupPayload(req.body || {});
  if (p.error) return res.status(400).json({ error: p.error });
  const v = p.value;
  if (v.shift_id && !db.prepare('SELECT id FROM att_shifts WHERE id=? AND org_id=?').get(v.shift_id, g.org.id)) {
    return res.status(400).json({ error: '所选班次不存在' });
  }
  const info = db.prepare('INSERT INTO att_groups (org_id,name,shift_id,location_mode,created_at) VALUES (?,?,?,?,?)')
    .run(g.org.id, v.name, v.shift_id, v.location_mode, Date.now());
  setGroupRelations(info.lastInsertRowid, g.org.id, req.body?.deptIds || [], req.body?.memberIds || []);
  res.json({ ok: true, id: info.lastInsertRowid, message: '考勤组已新增' });
});

admin.put('/groups/:id', (req, res) => {
  const g = adminGuard(req, res); if (!g) return;
  const id = Number(req.params.id);
  if (!db.prepare('SELECT id FROM att_groups WHERE id=? AND org_id=?').get(id, g.org.id)) {
    return res.status(404).json({ error: '考勤组不存在' });
  }
  const p = groupPayload(req.body || {});
  if (p.error) return res.status(400).json({ error: p.error });
  const v = p.value;
  if (v.shift_id && !db.prepare('SELECT id FROM att_shifts WHERE id=? AND org_id=?').get(v.shift_id, g.org.id)) {
    return res.status(400).json({ error: '所选班次不存在' });
  }
  db.prepare('UPDATE att_groups SET name=?,shift_id=?,location_mode=? WHERE id=?')
    .run(v.name, v.shift_id, v.location_mode, id);
  setGroupRelations(id, g.org.id, req.body?.deptIds || [], req.body?.memberIds || []);
  res.json({ ok: true, message: '已保存' });
});

admin.delete('/groups/:id', (req, res) => {
  const g = adminGuard(req, res); if (!g) return;
  const r = db.prepare('DELETE FROM att_groups WHERE id=? AND org_id=?').run(Number(req.params.id), g.org.id);
  if (!r.changes) return res.status(404).json({ error: '考勤组不存在' });
  db.prepare('DELETE FROM att_group_depts WHERE group_id=?').run(Number(req.params.id));
  db.prepare('DELETE FROM att_group_members WHERE group_id=?').run(Number(req.params.id));
  res.json({ ok: true, message: '已删除（这些人回到默认班次）' });
});

/* ---------------- 审批 ---------------- */

admin.get('/requests', (req, res) => {
  const g = adminGuard(req, res); if (!g) return;
  const status = req.query.status === undefined ? 'pending' : (String(req.query.status) || null);
  res.json({
    items: att.listRequests({
      orgId: g.org.id,
      status: status === 'all' ? null : status,
      kind: req.query.kind ? String(req.query.kind) : null,
      limit: Number(req.query.limit) || 200,
    }),
    counts: {
      pending: db.prepare("SELECT COUNT(*) AS c FROM att_requests WHERE org_id=? AND status='pending'").get(g.org.id).c,
      approved: db.prepare("SELECT COUNT(*) AS c FROM att_requests WHERE org_id=? AND status='approved'").get(g.org.id).c,
      rejected: db.prepare("SELECT COUNT(*) AS c FROM att_requests WHERE org_id=? AND status='rejected'").get(g.org.id).c,
    },
  });
});

admin.post('/requests/:id/review', (req, res) => {
  const g = adminGuard(req, res); if (!g) return;
  const approve = req.body?.approve !== false;
  const r = att.reviewRequest({
    orgId: g.org.id, id: Number(req.params.id), approve,
    reviewerId: g.u.id, note: req.body?.note,
  });
  if (r.error) return res.status(400).json({ error: r.error });
  res.json({ ok: true, request: r.request, message: approve ? '已通过' : '已驳回' });
});

module.exports = router;
module.exports.admin = admin;
