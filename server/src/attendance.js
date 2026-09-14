/**
 * 考勤引擎（工作模式的标配能力，对标钉钉考勤）
 *
 * 一句话职责：**把"几点打了卡"翻译成"这天算出勤、迟到、缺卡还是缺勤"**，
 * 并把这件事的口径全部收在服务端 —— 客户端只展示、不计算。
 *
 * ─────────────────────────────────────────────────────────────
 * 三条容易踩错、但必须一次做对的规矩
 * ─────────────────────────────────────────────────────────────
 *
 * 1. **时区不能用"服务器本地时间"**
 *    容器里 TZ 常常是 UTC（飞牛上就是），而员工看的是北京时间。若用
 *    `new Date().getHours()` 判"几点了"，容器一出海就整体错 8 小时：
 *    早上 9 点打的卡会被记成凌晨 1 点，全员迟到。
 *    所以这里所有"日/时刻"换算都走显式时区（默认 Asia/Shanghai，
 *    可用环境变量 ATT_TIMEZONE 覆盖），与容器 TZ 无关。
 *
 * 2. **时间戳是唯一的真相，"日"只是它的一个视图**
 *    库里同时存了 at(时间戳) 和 day('YYYY-MM-DD')。day 只用于**检索**
 *    （"查某人 9 月 10 号打了什么卡"），判定一律回到时间戳上算 ——
 *    否则跨天班（22:00-06:00）的下班卡落在次日，按 day 判永远算不对。
 *
 * 3. **"今天"不能按"已经结束的一天"来判**
 *    上午 10 点查今天，员工当然还没打下班卡。若不区分，全公司每天上午
 *    打开 App 都是"缺卡"。所以 dayStatus 对今天有专门分支：只报已经
 *    **既成事实**的问题（迟到），未到的部分一律 pending。
 *
 * ─────────────────────────────────────────────────────────────
 * 数据流
 * ─────────────────────────────────────────────────────────────
 *   打卡 clock()  ──→ att_records（流水，一人一天可多条，取极值）
 *   请假/补卡/外出 ──→ att_requests ──审批通过──→ 补卡直接落 att_records；
 *                                              请假/外出在判定时"豁免"对应卡
 *   统计 rangeStats() 先一次性把区间数据取进内存，再逐日判定 ——
 *   500 人的月报表也只查 3 次库，不会变成 N×31 次查询。
 */
const db = require('./db');
const settings = require('./settings');

/* ==================== 1. 时区与时间换算 ==================== */

const TZ = process.env.ATT_TIMEZONE || 'Asia/Shanghai';

const _dayFmt = new Intl.DateTimeFormat('en-CA', {
  timeZone: TZ, year: 'numeric', month: '2-digit', day: '2-digit',
});
const _partFmt = new Intl.DateTimeFormat('en-US', {
  timeZone: TZ, year: 'numeric', month: '2-digit', day: '2-digit',
  hour: '2-digit', minute: '2-digit', second: '2-digit', hour12: false,
});

function partsOf(ts) {
  const o = {};
  for (const p of _partFmt.formatToParts(new Date(ts))) o[p.type] = p.value;
  return o;
}

// 时区偏移按分钟缓存：一个月报表要算几万次，每次都 formatToParts 太浪费
const _offCache = new Map();
function tzOffsetMs(ts) {
  const sec = Math.floor(ts / 1000) * 1000;
  const hit = _offCache.get(sec);
  if (hit !== undefined) return hit;
  const p = partsOf(sec);
  const wall = Date.UTC(+p.year, +p.month - 1, +p.day, (+p.hour) % 24, +p.minute, +p.second);
  const off = wall - sec;             // 北京 = +8h
  if (_offCache.size > 20000) _offCache.clear();
  _offCache.set(sec, off);
  return off;
}

/** 时间戳 → 该时区的 'YYYY-MM-DD' */
function dayOf(ts) { return _dayFmt.format(new Date(ts)); }

/** 时间戳 → 该时区当天已过的分钟数（0~1439） */
function minutesOfDay(ts) {
  const p = partsOf(ts);
  return ((+p.hour) % 24) * 60 + (+p.minute);
}

/** 该时区某天的 'HH:MM' → 时间戳（对夏令时区也正确：迭代两次收敛） */
function tsOfDay(day, hhmm) {
  const [y, mo, d] = String(day).split('-').map(Number);
  const [h, mi] = String(hhmm).split(':').map(Number);
  const wall = Date.UTC(y, mo - 1, d, h, mi, 0, 0);
  let ts = wall;
  for (let i = 0; i < 2; i++) ts = wall - tzOffsetMs(ts);
  return ts;
}

/** 服务器时区下的"今天" */
function today(now = Date.now()) { return dayOf(now); }

/** 'YYYY-MM-DD' → 星期（0=周日 … 6=周六） */
function weekdayOf(day) {
  const [y, mo, d] = String(day).split('-').map(Number);
  return new Date(Date.UTC(y, mo - 1, d)).getUTCDay();
}

const DAY_MS = 86400000;

/** day 加减天数（纯字符串日期运算，不碰时区） */
function addDays(day, n) {
  const [y, mo, d] = String(day).split('-').map(Number);
  const t = new Date(Date.UTC(y, mo - 1, d + n));
  return `${t.getUTCFullYear()}-${String(t.getUTCMonth() + 1).padStart(2, '0')}-${String(t.getUTCDate()).padStart(2, '0')}`;
}

/** 'HH:MM' → 分钟数 */
function parseHHMM(s) {
  const m = /^([01]\d|2[0-3]):([0-5]\d)$/.exec(String(s || ''));
  if (!m) return null;
  return +m[1] * 60 + +m[2];
}

/** 分钟数 → 'HH:MM'（跨天时按 24h 回绕） */
function fmtHHMM(min) {
  const m = ((min % 1440) + 1440) % 1440;
  return `${String(Math.floor(m / 60)).padStart(2, '0')}:${String(m % 60).padStart(2, '0')}`;
}

/** 时间戳 → 该时区的 'HH:MM' */
function hhmmOf(ts) { return fmtHHMM(minutesOfDay(ts)); }

function isValidDay(s) {
  const str = String(s || '');
  if (!/^\d{4}-\d{2}-\d{2}$/.test(str)) return false;
  // ⚠️ 不能只靠 `!Number.isNaN(weekdayOf(s))` 判定：Date.UTC(2026, 12, 45) 会**静默归一化**
  // 成 2027-02-14，于是 '2026-13-45' 也能通过校验，然后被写进库里变成一条
  // 谁都看不懂的打卡记录。必须回格式化比对，确认这一天真实存在。
  const [y, mo, d] = str.split('-').map(Number);
  const t = new Date(Date.UTC(y, mo - 1, d));
  return t.getUTCFullYear() === y && t.getUTCMonth() === mo - 1 && t.getUTCDate() === d;
}

/* ==================== 2. 班次与考勤组 ==================== */

/** 默认班次（settings 里那份）—— 用 shift 的统一形状表示，id=null 表示"不是库里的班次" */
function defaultShift() {
  const s = settings.get('attDefaultShift') || {};
  const ws = s.workStart || '09:00';
  const we = s.workEnd || '18:00';
  return normalizeShift({
    id: null,
    name: '默认班次',
    work_start: ws,
    work_end: we,
    rest_minutes: s.restMinutes || 0,
    flex_minutes: s.flexMinutes || 0,
    late_grace: s.lateGrace || 0,
    early_grace: s.earlyGrace || 0,
    cross_day: parseHHMM(we) <= parseHHMM(ws) ? 1 : 0,
  });
}

function normalizeShift(r) {
  const workStart = r.work_start;
  const workEnd = r.work_end;
  const endMin = parseHHMM(workEnd);
  const startMin = parseHHMM(workStart);
  return {
    id: r.id == null ? null : Number(r.id),
    name: r.name || '班次',
    workStart,
    workEnd,
    startMin,
    endMin,
    // 下班 <= 上班 ⇒ 夜班跨天。允许显式 cross_day 覆盖（如 08:00-08:00 的 24h 班）
    crossDay: !!r.cross_day || (endMin != null && startMin != null && endMin <= startMin),
    restMinutes: Number(r.rest_minutes) || 0,
    flexMinutes: Number(r.flex_minutes) || 0,
    lateGrace: Number(r.late_grace) || 0,
    earlyGrace: Number(r.early_grace) || 0,
    enabled: r.enabled === undefined ? true : !!r.enabled,
    sort: Number(r.sort) || 0,
  };
}

function shiftRow(id, orgId) {
  const r = db.prepare('SELECT * FROM att_shifts WHERE id=? AND org_id=?').get(Number(id), Number(orgId));
  return r ? normalizeShift(r) : null;
}

function listShifts(orgId) {
  return db.prepare('SELECT * FROM att_shifts WHERE org_id=? ORDER BY sort, id').all(Number(orgId))
    .map(normalizeShift);
}

/**
 * 解析"这个人用哪套班次"。
 * 优先级：显式点名所在组 > 他部门命中所在组 > 组织默认班次。
 * 组内再优先取 sort 靠前/创建早的，保证结果稳定可预期（不然同一人今天 9 点、
 * 明天 10 点上班，排障时无从下手）。
 *
 * 返回 { shift, group, source }：source ∈ group | dept | default
 */
function shiftFor(userId, orgId) {
  const g = db.prepare(`
    SELECT gr.*, gm.user_id AS direct_member
    FROM att_groups gr
    LEFT JOIN att_group_members gm ON gm.group_id = gr.id AND gm.user_id = ?
    WHERE gr.org_id = ?
    ORDER BY gr.id`).all(Number(userId), Number(orgId));

  let hit = g.find((x) => x.direct_member);
  let source = 'group';
  if (!hit) {
    // 部门纳入：员工的 dept_id 命中组绑定部门（含其上级部门 —— 绑了"生产部"，
    // 子部门"包装组"的人也应在组里，否则设好的组织层级在这里被抹平）
    const u = db.prepare('SELECT dept_id FROM users WHERE id=?').get(Number(userId));
    if (u && u.dept_id) {
      const chain = deptChain(u.dept_id, orgId);
      for (const grp of g) {
        const bound = db.prepare('SELECT dept_id FROM att_group_depts WHERE group_id=?').all(grp.id)
          .map((r) => r.dept_id);
        if (bound.some((d) => chain.includes(d))) { hit = grp; break; }
      }
    }
    if (hit) source = 'dept';
  }
  if (!hit) return { shift: defaultShift(), group: null, source: 'default' };

  const s = hit.shift_id ? shiftRow(hit.shift_id, orgId) : null;
  return {
    shift: s || defaultShift(),
    group: {
      id: hit.id, name: hit.name, locationMode: hit.location_mode || 'off',
    },
    source,
  };
}

/** 部门及其所有上级（用于"绑了上级部门，子部门的人也在组里"） */
function deptChain(deptId, orgId) {
  const all = db.prepare('SELECT id, parent_id FROM org_depts WHERE org_id=?').all(Number(orgId));
  const byId = new Map(all.map((d) => [d.id, d]));
  const out = [];
  let cur = Number(deptId);
  const seen = new Set();
  while (cur && !seen.has(cur)) {
    seen.add(cur);
    out.push(cur);
    cur = byId.get(cur)?.parent_id || 0;
  }
  return out;
}

/**
 * 部门及其所有子孙部门。
 *
 * 【为什么必须和 deptChain 分开存在】
 * 两个方向都用得到，而搞混过一次就出真 bug：
 *   - 判断"某员工是否命中考勤组/某部门" → 用 deptChain（**向上**爬：员工的部门链里
 *     是否包含绑定部门）。员工在「包装车间」、组绑「生产部」→ 命中。
 *   - 统计"某部门有多少人 / 按部门筛选报表" → 用本函数（**向下**展开：绑定部门
 *     要连子孙一起算）。绑「生产部」时「包装车间」的人当然也算生产部的人。
 * 之前报表按部门筛选只用了向上爬，结果选了「生产部」却看不到子部门的员工 ——
 * 管理者会以为这些人不属于该部门。
 */
function deptWithDescendants(deptId, orgId) {
  const all = db.prepare('SELECT id, parent_id FROM org_depts WHERE org_id=?').all(Number(orgId));
  const out = [];
  const seen = new Set();
  const stack = [Number(deptId)];
  while (stack.length) {
    const cur = stack.pop();
    if (seen.has(cur)) continue;
    seen.add(cur);
    out.push(cur);
    for (const d of all) if (d.parent_id === cur) stack.push(d.id);
  }
  return out;
}

/**
 * 某考勤组的**实际成员**（显式点名 ∪ 绑定部门内的人，含子部门）。
 * 口径与 shiftFor 完全一致 —— 这里若各写一套，就会出现"组里显示 5 人、
 * 实际按 7 人判定"这种查不出来的错。
 */
function groupMemberIds(groupRow, orgId) {
  const set = new Set(db.prepare('SELECT user_id FROM att_group_members WHERE group_id=?')
    .all(groupRow.id).map((r) => r.user_id));
  const deptIds = db.prepare('SELECT dept_id FROM att_group_depts WHERE group_id=?')
    .all(groupRow.id).map((r) => r.dept_id);
  if (deptIds.length) {
    for (const u of db.prepare('SELECT id, dept_id FROM users WHERE org_id=? AND is_bot=0').all(Number(orgId))) {
      if (!u.dept_id) continue;
      if (deptChain(u.dept_id, orgId).some((d) => deptIds.includes(d))) set.add(u.id);
    }
  }
  return set;
}

/* ==================== 3. 打卡 ==================== */

const MAX_RECORDS_PER_DAY_TYPE = 20; // 防手滑：同一天同一类型留太多流水没有意义

/**
 * 打卡。type='in'|'out'。
 * 语义对齐钉钉的「更新打卡」：同一天同类型已存在时**覆盖最近一条**（返回 updated=true），
 * 而不是新增一条 —— 员工手滑打早了会再打一次，多出来的流水只会让统计和审计都变脏。
 * 但**保留**最近 24 小时内的旧流水（管理台能看到"8:31 打过又 9:02 补打"），
 * 所以这里的"覆盖"是 UPDATE，不是"删掉旧的"。
 */
function clock({ userId, orgId, type, at = Date.now(), lat = null, lng = null, address = null, device = null, source = 'app', addressNote = null }) {
  if (!['in', 'out'].includes(type)) return { error: '打卡类型只能是 in 或 out' };
  const day = dayOf(at);
  const cnt = db.prepare('SELECT COUNT(*) AS c FROM att_records WHERE user_id=? AND day=? AND type=?')
    .get(Number(userId), day, type).c;
  if (cnt === 0) {
    const r = db.prepare(`INSERT INTO att_records
      (org_id,user_id,day,type,at,source,lat,lng,address,device,note,created_at)
      VALUES (?,?,?,?,?,?,?,?,?,?,?,?)`)
      .run(Number(orgId), Number(userId), day, type, at, source,
        lat == null ? null : Number(lat), lng == null ? null : Number(lng),
        address ? String(address).slice(0, 120) : null,
        device ? String(device).slice(0, 80) : null,
        addressNote ? String(addressNote).slice(0, 120) : null, Date.now());
    return { record: recordById(r.lastInsertRowid), updated: false };
  }
  if (cnt >= MAX_RECORDS_PER_DAY_TYPE) {
    // 覆盖最近一条即可，不再新增：一天打 20 次卡显然是程序在重放请求
    const last = db.prepare('SELECT id FROM att_records WHERE user_id=? AND day=? AND type=? ORDER BY at DESC LIMIT 1')
      .get(Number(userId), day, type);
    db.prepare('UPDATE att_records SET at=?, lat=?, lng=?, address=?, device=?, source=?, note=? WHERE id=?')
      .run(at, lat == null ? null : Number(lat), lng == null ? null : Number(lng),
        address ? String(address).slice(0, 120) : null,
        device ? String(device).slice(0, 80) : null, source,
        addressNote ? String(addressNote).slice(0, 120) : null, last.id);
    return { record: recordById(last.id), updated: true };
  }
  const last = db.prepare('SELECT id FROM att_records WHERE user_id=? AND day=? AND type=? ORDER BY at DESC LIMIT 1')
    .get(Number(userId), day, type);
  db.prepare('UPDATE att_records SET at=?, lat=?, lng=?, address=?, device=?, source=?, note=? WHERE id=?')
    .run(at, lat == null ? null : Number(lat), lng == null ? null : Number(lng),
      address ? String(address).slice(0, 120) : null,
      device ? String(device).slice(0, 80) : null, source,
      addressNote ? String(addressNote).slice(0, 120) : null, last.id);
  return { record: recordById(last.id), updated: true };
}

function recordById(id) {
  const r = db.prepare(`SELECT r.*, u.username, u.nickname, u.employee_no
    FROM att_records r LEFT JOIN users u ON u.id=r.user_id WHERE r.id=?`).get(Number(id));
  return r ? decorateRecord(r) : null;
}

function decorateRecord(r) {
  return {
    id: r.id,
    userId: r.user_id,
    day: r.day,
    type: r.type,
    at: r.at,
    time: hhmmOf(r.at),
    source: r.source,
    lat: r.lat,
    lng: r.lng,
    address: r.address,
    device: r.device,
    note: r.note,
    username: r.username,
    nickname: r.nickname,
    employeeNo: r.employee_no,
  };
}

/** 某人某天的打卡流水（按 day 检索，跨天班的下班卡会在次日那条里） */
function recordsOn(userId, day) {
  return db.prepare('SELECT * FROM att_records WHERE user_id=? AND day=? ORDER BY at').all(Number(userId), day)
    .map(decorateRecord);
}

/** 区间内所有打卡流水（可选限定若干人）——报表用，一次查完 */
function recordsRange(orgId, from, to, userIds = null) {
  const rows = userIds && userIds.length
    ? db.prepare(`SELECT * FROM att_records WHERE org_id=? AND day>=? AND day<=?
        AND user_id IN (${userIds.map(() => '?').join(',')}) ORDER BY user_id, at`)
      .all(Number(orgId), from, to, ...userIds.map(Number))
    : db.prepare('SELECT * FROM att_records WHERE org_id=? AND day>=? AND day<=? ORDER BY user_id, at')
      .all(Number(orgId), from, to);
  return rows.map(decorateRecord);
}

/* ==================== 4. 请假 / 外出 / 加班 的"豁免"计算 ==================== */

const LEAVE_TYPES = ['personal', 'sick', 'annual', 'comp'];
const REQUEST_KINDS = ['leave', 'makeup', 'outing', 'overtime'];

/** 一天的请假覆盖。half 仅对单日请假生效（多日请假一定是整天） */
function leaveCoverage(req, day) {
  if (!req || req.kind !== 'leave') return { full: false, am: false, pm: false };
  if (!(day >= req.start_day && day <= req.end_day)) return { full: false, am: false, pm: false };
  const single = req.start_day === req.end_day;
  const half = single ? Number(req.half) || 0 : 0;
  if (half === 1) return { full: false, am: true, pm: false };  // 上午半天
  if (half === 2) return { full: false, am: false, pm: true };  // 下午半天
  return { full: true, am: true, pm: true };
}

/** 请假单在一天上的天数（整天=1，单日半天=0.5） */
function leaveDaysOf(req, day) {
  const c = leaveCoverage(req, day);
  if (c.full) return 1;
  if (c.am || c.pm) return 0.5;
  return 0;
}

/**
 * 一天的请假 + 外出覆盖：
 * - leave 覆盖整张卡（am 管上班卡、pm 管下班卡）
 * - outing 覆盖"它的时段碰到的那张卡"（上午外出 → 上班卡不判缺）
 */
function coverageOn(reqs, day, win) {
  const out = { leaveFull: false, leaveAm: false, leavePm: false, inExempt: false, outExempt: false, hasOuting: false };
  for (const r of reqs || []) {
    if (r.status !== 'approved') continue;
    if (r.kind === 'leave') {
      const c = leaveCoverage(r, day);
      if (c.full) { out.leaveFull = true; out.leaveAm = true; out.leavePm = true; }
      if (c.am) out.leaveAm = true;
      if (c.pm) out.leavePm = true;
    }
    if (r.kind === 'outing' && r.start_at && r.end_at) {
      if (win.startAt >= r.start_at && win.startAt <= r.end_at) { out.inExempt = true; out.hasOuting = true; }
      if (win.endAt >= r.start_at && win.endAt <= r.end_at) { out.outExempt = true; out.hasOuting = true; }
    }
  }
  return out;
}

/** 加班分钟数（与班次窗口的重叠部分之外都算？—— 简化：取加班单时长） */
function overtimeMinutesOn(reqs, day) {
  let sum = 0;
  for (const r of reqs || []) {
    if (r.kind !== 'overtime' || r.status !== 'approved' || !r.start_at || !r.end_at) continue;
    if (dayOf(r.start_at) !== day) continue;
    sum += Math.max(0, Math.round((r.end_at - r.start_at) / 60000));
  }
  return sum;
}

/* ==================== 5. 单日判定（纯函数，便于测试） ==================== */

/**
 * 班次在某天的绝对时间窗。
 * endAt 一定晚于 startAt —— 跨天班在这里被"拉直"，下游所有比较都只需前后比大小，
 * 不用再各写一遍"到底算不算次日"。
 */
function windowOf(shift, day) {
  const startAt = tsOfDay(day, shift.workStart);
  let endAt = tsOfDay(day, shift.workEnd);
  if (shift.crossDay || endAt <= startAt) endAt += DAY_MS;
  return { day, startAt, endAt };
}

/**
 * 判定某人在某天的考勤状态。
 * 入参全是"已经取好的数据"，不碰数据库 —— 这样它既能被报表批量调用（几万次），
 * 也能被测试直接喂各种边界（迟到一分钟、跨天班、半天假）。
 *
 * status:
 *   rest     休息日        normal  正常        late     迟到
 *   early    早退          late_early 迟到+早退
 *   missing  缺卡（缺一边） absent  缺勤（两边都没打）
 *   leave    请假          outing  外出        pending  进行中（今天还没到下班）
 *   future   未来日期（不判）
 */
function judgeDay({ day, now, shift, recs, reqs, workdays }) {
  const wd = weekdayOf(day);
  const isWorkday = (workdays || []).includes(wd);
  const win = windowOf(shift, day);
  const cov = coverageOn(reqs, day, win);
  const todayStr = dayOf(now);

  // 用时间窗取记录，而不是用 day 字段：跨天班的下班卡落在次日，
  // 按 day 取就会"下班卡凭空消失"，然后全组被判缺卡。
  const inWin = (recs || []).filter((r) => r.at >= win.startAt - 6 * 3600e3 && r.at <= win.endAt + 6 * 3600e3);
  const ins = inWin.filter((r) => r.type === 'in');
  const outs = inWin.filter((r) => r.type === 'out');
  const firstIn = ins.length ? Math.min(...ins.map((r) => r.at)) : null;
  const lastOut = outs.length ? Math.max(...outs.map((r) => r.at)) : null;

  const base = {
    day, weekday: wd, isWorkday,
    shift: { name: shift.name, workStart: shift.workStart, workEnd: shift.workEnd },
    firstIn, lastOut,
    firstInTime: firstIn == null ? null : hhmmOf(firstIn),
    lastOutTime: lastOut == null ? null : hhmmOf(lastOut),
    lateMinutes: 0,
    earlyMinutes: 0,
    leave: cov.leaveFull ? 'full' : (cov.leaveAm ? 'am' : (cov.leavePm ? 'pm' : null)),
    outing: cov.hasOuting,
    overtimeMinutes: overtimeMinutesOn(reqs, day),
  };

  if (day > todayStr) return { ...base, status: 'future', note: '尚未到来' };

  if (!isWorkday) {
    // 休息日：不判出勤，只记录有没有来加班
    return { ...base, status: 'rest', note: base.overtimeMinutes ? `加班 ${Math.round(base.overtimeMinutes / 60 * 10) / 10} 小时` : '休息日' };
  }

  if (cov.leaveFull) return { ...base, status: 'leave', note: '请假' };

  // 迟到：上班时间 + 弹性 + 宽限之后才算
  const lateThreshold = shift.startMin + shift.flexMinutes + shift.lateGrace;
  let lateMinutes = 0;
  if (firstIn != null) {
    const m = minutesOfDay(firstIn);
    // 跨天班（22:00 上班）时 minutesOfDay 会给出 22:00 之后的值，直接相减即可
    lateMinutes = Math.max(0, m - lateThreshold);
  }
  // 早退：下班时间 - 提前打卡宽限之前才算
  const earlyThreshold = shift.endMin - shift.earlyGrace;
  let earlyMinutes = 0;
  if (lastOut != null) {
    const m = minutesOfDay(lastOut);
    earlyMinutes = Math.max(0, earlyThreshold - m);
  }
  base.lateMinutes = lateMinutes;
  // 早退**先不写**：今天还没到下班时间时"早退"根本不成立 —— 拿一张 10:41 打的下班卡
  // 去比 18:00，会得出"早退 438 分钟"这种荒唐数字，客户端照直显示就成了笑话。
  // 只有走到下面的常规判定（确认下班时间已过）才把它落进结果。
  base.earlyMinutes = 0;

  const isToday = day === todayStr;
  const inDue = now >= win.startAt;                       // 上班卡"该打了"
  const outDue = now >= win.endAt;                        // 下班卡"该打了"
  const missingIn = firstIn == null && !cov.leaveAm && !cov.inExempt;
  const missingOut = lastOut == null && !cov.leavePm && !cov.outExempt;

  // 今天且还没到下班时间：只报既成事实（迟到），其余算"进行中"。
  // 否则每天上午全公司都是"缺卡"，这个功能第一次打开就会被骂。
  if (isToday && now < win.endAt) {
    if (lateMinutes > 0) return { ...base, status: 'late', note: `迟到 ${lateMinutes} 分钟` };
    if (cov.leaveAm && !cov.leavePm) return { ...base, status: 'pending', note: '上午请假' };
    if (firstIn != null) return { ...base, status: 'pending', note: '已打上班卡，进行中' };
    if (!inDue) return { ...base, status: 'pending', note: '未到上班时间' };
    return { ...base, status: 'pending', note: '待打上班卡' };
  }

  // 走到这里说明这天已经过完（或已过下班时间），早退才成立
  base.earlyMinutes = earlyMinutes;

  if (missingIn && missingOut) return { ...base, status: 'absent', note: '未打卡' };
  if (missingIn || missingOut) {
    const who = missingIn ? '上班' : '下班';
    // 今天还没到下班时间时，缺的下班卡只是"还没打"，不要判成异常
    if (isToday && missingOut && !outDue) return { ...base, status: 'pending', note: `已打上班卡，待打下班卡` };
    return { ...base, status: 'missing', note: `缺${who}卡` };
  }
  // 请假半天 + 已打卡：只要没迟到早退就算正常（半天假只豁免对应那张卡）
  if (lateMinutes > 0 && earlyMinutes > 0) {
    return { ...base, status: 'late_early', note: `迟到 ${lateMinutes} 分钟，早退 ${earlyMinutes} 分钟` };
  }
  if (lateMinutes > 0) return { ...base, status: 'late', note: `迟到 ${lateMinutes} 分钟` };
  if (earlyMinutes > 0) return { ...base, status: 'early', note: `早退 ${earlyMinutes} 分钟` };
  if (cov.inExempt || cov.outExempt) return { ...base, status: 'outing', note: '外出' };
  return { ...base, status: 'normal', note: '正常' };
}

/* ==================== 6. 区间统计 ==================== */

const STATUS_LABEL = {
  rest: '休息', normal: '正常', late: '迟到', early: '早退', late_early: '迟到早退',
  missing: '缺卡', absent: '缺勤', leave: '请假', outing: '外出', pending: '进行中', future: '未到',
};

/**
 * 一次判定一批人、一段时间的考勤。
 * 取数只 3 次（成员 / 打卡流水 / 申请单），其余全在内存里算 ——
 * 500 人 × 31 天若逐日查库就是 1.5 万次往返，报表会卡到没人用。
 */
function judgeRange({ orgId, users, from, to, now = Date.now() }) {
  const workdays = settings.get('attWorkdays') || [1, 2, 3, 4, 5];
  const ids = users.map((u) => u.id);
  const recs = recordsRange(orgId, addDays(from, -1), addDays(to, 1), ids);
  const reqRows = ids.length
    ? db.prepare(`SELECT * FROM att_requests WHERE org_id=? AND user_id IN (${ids.map(() => '?').join(',')})
        AND status='approved'`).all(Number(orgId), ...ids)
    : [];
  const reqsByUser = new Map();
  for (const r of reqRows) {
    if (!reqsByUser.has(r.user_id)) reqsByUser.set(r.user_id, []);
    reqsByUser.get(r.user_id).push(r);
  }
  const recsByUser = new Map();
  for (const r of recs) {
    if (!recsByUser.has(r.userId)) recsByUser.set(r.userId, []);
    recsByUser.get(r.userId).push(r);
  }

  const days = [];
  for (let d = from; d <= to; d = addDays(d, 1)) days.push(d);

  const result = [];
  for (const u of users) {
    const { shift, group, source: shiftSource } = shiftFor(u.id, orgId);
    const myRecs = recsByUser.get(u.id) || [];
    const myReqs = reqsByUser.get(u.id) || [];
    const dayList = days.map((d) => judgeDay({ day: d, now, shift, recs: myRecs, reqs: myReqs, workdays }));
    result.push({
      userId: u.id,
      username: u.username,
      nickname: u.nickname || u.username,
      employeeNo: u.employee_no || null,
      deptId: u.dept_id || null,
      deptName: u.dept_name || null,
      positionName: u.position_name || null,
      shiftName: shift.name,
      shift: { workStart: shift.workStart, workEnd: shift.workEnd, name: shift.name },
      groupName: group ? group.name : null,
      shiftSource,
      days: dayList,
      summary: summarize(dayList),
    });
  }
  return { from, to, workdays, users: result };
}

function summarize(dayList) {
  const s = {
    totalDays: dayList.length,
    workdays: 0, present: 0, normal: 0,
    late: 0, early: 0, missing: 0, absent: 0,
    leave: 0, outing: 0, rest: 0, pending: 0,
    lateMinutes: 0, earlyMinutes: 0,
    overtimeMinutes: 0, overtimeDays: 0,
  };
  for (const d of dayList) {
    if (d.isWorkday) s.workdays++;
    if (d.status === 'rest') s.rest++;
    else if (d.status === 'pending' || d.status === 'future') s.pending++;
    if (d.firstIn != null || d.lastOut != null) s.present++;
    if (d.lateMinutes > 0) s.late++;
    if (d.earlyMinutes > 0) s.early++;
    if (d.status === 'missing') s.missing++;
    if (d.status === 'absent') s.absent++;
    if (d.status === 'normal') s.normal++;
    if (d.status === 'outing') s.outing++;
    if (d.status === 'leave' || d.leave) {
      s.leave += leaveDaysOf({ kind: 'leave', start_day: d.day, end_day: d.day, half: d.leave === 'full' ? 0 : (d.leave === 'am' ? 1 : 2) }, d.day);
    }
    s.lateMinutes += d.lateMinutes || 0;
    s.earlyMinutes += d.earlyMinutes || 0;
    if (d.overtimeMinutes > 0) { s.overtimeMinutes += d.overtimeMinutes; s.overtimeDays++; }
  }
  s.leave = Math.round(s.leave * 10) / 10;
  return s;
}

/** 单人（客户端"我的考勤"）：不含 user 表的 join，直接给记录与汇总 */
function myRange(user, orgId, from, to, now = Date.now()) {
  const { shift, group, source } = shiftFor(user.id, orgId);
  const workdays = settings.get('attWorkdays') || [1, 2, 3, 4, 5];
  const recs = recordsRange(orgId, addDays(from, -1), addDays(to, 1), [user.id]);
  const reqs = db.prepare(`SELECT * FROM att_requests WHERE user_id=? AND status='approved'`).all(Number(user.id));
  const days = [];
  for (let d = from; d <= to; d = addDays(d, 1)) {
    days.push(judgeDay({ day: d, now, shift, recs, reqs, workdays }));
  }
  return { shift, group, shiftSource: source, days, summary: summarize(days) };
}

/* ==================== 7. 申请单 ==================== */

function createRequest({ orgId, userId, kind, reason, startDay, endDay, half, leaveType, day, clockType, at, startAt, endAt }) {
  if (!REQUEST_KINDS.includes(kind)) return { error: '申请类型不支持' };
  const base = { orgId: Number(orgId), userId: Number(userId), kind, reason: String(reason || '').slice(0, 200) };
  if (kind === 'leave') {
    if (!isValidDay(startDay) || !isValidDay(endDay)) return { error: '请假请选择起止日期' };
    if (endDay < startDay) return { error: '结束日期不能早于开始日期' };
    if (startDay > endDay) return { error: '日期区间不合法' };
    const span = Math.round((tsOfDay(endDay, '00:00') - tsOfDay(startDay, '00:00')) / DAY_MS) + 1;
    if (span > 30) return { error: '单次请假最多 30 天，更长请分次申请' };
    if (half && startDay !== endDay) return { error: '半天请假只能是同一天（多日请假按整天计）' };
    if (!LEAVE_TYPES.includes(leaveType)) return { error: '请假类型不支持' };
    Object.assign(base, { start_day: startDay, end_day: endDay, half: Number(half) || 0, leave_type: leaveType });
  } else if (kind === 'makeup') {
    if (!isValidDay(day)) return { error: '补卡请选择日期' };
    if (!['in', 'out'].includes(clockType)) return { error: '补卡请选择上班卡或下班卡' };
    const ts = Number(at);
    if (!Number.isFinite(ts) || ts <= 0) return { error: '补卡时间不合法' };
    if (dayOf(ts) !== day) return { error: '补卡时刻必须落在所选日期当天' };
    if (day > today()) return { error: '不能给未来日期补卡' };
    Object.assign(base, { day, clock_type: clockType, at: ts });
  } else {
    const s = Number(startAt); const e = Number(endAt);
    if (!Number.isFinite(s) || !Number.isFinite(e) || e <= s) return { error: '请选择正确的起止时间' };
    if (Math.round((e - s) / 60000) > 24 * 60) return { error: '单次时长不能超过 24 小时' };
    Object.assign(base, { start_at: s, end_at: e, day: dayOf(s) });
  }
  const dup = db.prepare(`SELECT id FROM att_requests WHERE user_id=? AND kind=? AND status='pending'
    AND IFNULL(start_day,'')=IFNULL(?,'') AND IFNULL(day,'')=IFNULL(?,'')`)
    .get(base.userId, kind, base.start_day || null, base.day || null);
  if (dup) return { error: '同类型的申请正在审批中，请勿重复提交' };

  const info = db.prepare(`INSERT INTO att_requests
    (org_id,user_id,kind,status,reason,start_day,end_day,half,leave_type,day,clock_type,at,start_at,end_at,created_at)
    VALUES (?,?,?,'pending',?,?,?,?,?,?,?,?,?,?,?)`)
    .run(base.orgId, base.userId, kind, base.reason || null,
      base.start_day || null, base.end_day || null, base.half || 0, base.leave_type || null,
      base.day || null, base.clock_type || null, base.at || null, base.start_at || null, base.end_at || null,
      Date.now());
  return { id: info.lastInsertRowid };
}

function decorateRequest(r) {
  const km = { leave: '请假', makeup: '补卡', outing: '外出', overtime: '加班' };
  const lm = { personal: '事假', sick: '病假', annual: '年假', comp: '调休' };
  const half = Number(r.half) || 0;
  let desc = '';
  if (r.kind === 'leave') {
    desc = r.start_day === r.end_day
      ? `${r.start_day}${half === 1 ? ' 上午' : half === 2 ? ' 下午' : ' 全天'}`
      : `${r.start_day} ~ ${r.end_day}`;
    if (r.leave_type) desc += `（${lm[r.leave_type] || r.leave_type}）`;
  } else if (r.kind === 'makeup') {
    desc = `${r.day} ${r.clock_type === 'in' ? '上班卡' : '下班卡'} 补 ${r.at ? hhmmOf(r.at) : ''}`;
  } else if (r.start_at && r.end_at) {
    desc = `${dayOf(r.start_at)} ${hhmmOf(r.start_at)} ~ ${hhmmOf(r.end_at)}`;
  }
  return {
    id: r.id,
    userId: r.user_id,
    kind: r.kind,
    kindLabel: km[r.kind] || r.kind,
    status: r.status,
    statusLabel: { pending: '待审批', approved: '已通过', rejected: '已驳回', canceled: '已撤销' }[r.status] || r.status,
    reason: r.reason,
    desc,
    startDay: r.start_day, endDay: r.end_day, half: Number(r.half) || 0, leaveType: r.leave_type,
    day: r.day, clockType: r.clock_type, at: r.at, startAt: r.start_at, endAt: r.end_at,
    reviewedBy: r.reviewed_by, reviewedAt: r.reviewed_at, reviewNote: r.review_note,
    createdAt: r.created_at,
    username: r.username, nickname: r.nickname, employeeNo: r.employee_no,
  };
}

function listRequests({ orgId, userId = null, status = null, kind = null, limit = 200 }) {
  const where = ['r.org_id=?'];
  const args = [Number(orgId)];
  if (userId) { where.push('r.user_id=?'); args.push(Number(userId)); }
  if (status) { where.push('r.status=?'); args.push(status); }
  if (kind) { where.push('r.kind=?'); args.push(kind); }
  args.push(Math.min(Number(limit) || 200, 1000));
  return db.prepare(`SELECT r.*, u.username, u.nickname, u.employee_no
    FROM att_requests r LEFT JOIN users u ON u.id=r.user_id
    WHERE ${where.join(' AND ')} ORDER BY r.created_at DESC LIMIT ?`).all(...args).map(decorateRequest);
}

/**
 * 审批。通过时**立即落地业务后果**：
 * - 补卡通过 → 写/改 att_records（source='makeup'），员工当天立刻从"缺卡"变正常
 * - 请假/外出通过 → 不写记录，判定时按豁免算（改了日期也不用回滚记录）
 * 这样"审批通过"这一个动作就是唯一真相来源，不用再跑一次补偿任务。
 */
function reviewRequest({ orgId, id, approve, reviewerId, note = null }) {
  const r = db.prepare('SELECT * FROM att_requests WHERE id=? AND org_id=?').get(Number(id), Number(orgId));
  if (!r) return { error: '申请不存在' };
  if (r.status !== 'pending') return { error: `该申请已是「${r.status === 'approved' ? '已通过' : '已处理'}」状态` };

  if (approve && r.kind === 'makeup') {
    const user = db.prepare('SELECT org_id FROM users WHERE id=?').get(r.user_id);
    if (!user || !user.org_id) return { error: '该员工已离职或不在组织中，无法补卡' };
    db.prepare('DELETE FROM att_records WHERE user_id=? AND day=? AND type=? AND source=?')
      .run(r.user_id, r.day, r.clock_type, 'makeup');
    clock({
      userId: r.user_id, orgId: Number(orgId), type: r.clock_type, at: r.at,
      source: 'makeup', addressNote: note || '补卡审批通过',
    });
  }

  db.prepare('UPDATE att_requests SET status=?, reviewed_by=?, reviewed_at=?, review_note=? WHERE id=?')
    .run(approve ? 'approved' : 'rejected', Number(reviewerId), Date.now(), note ? String(note).slice(0, 120) : null, Number(id));
  const row = db.prepare(`SELECT r.*, u.username, u.nickname, u.employee_no
    FROM att_requests r LEFT JOIN users u ON u.id=r.user_id WHERE r.id=?`).get(Number(id));
  return { ok: true, request: decorateRequest(row) };
}

/* ==================== 8. 今日总览（管理台看板） ==================== */

/**
 * 某天全组织的打卡情况。"应打卡的人"由考勤规则决定：
 * 工作模式 + 考勤开启 + 属于组织。
 * 未打卡的人**也要列出来**（否则看板只能看到"谁打了"，看不到"谁没来"，
 * 而后者才是管理者真正要看的）。
 */
function overview({ orgId, day, now = Date.now() }) {
  const workdays = settings.get('attWorkdays') || [1, 2, 3, 4, 5];
  const users = db.prepare(`SELECT u.id,u.username,u.nickname,u.employee_no,u.dept_id,d.name AS dept_name
    FROM users u LEFT JOIN org_depts d ON d.id=u.dept_id
    WHERE u.org_id=? AND u.is_bot=0 ORDER BY u.id`).all(Number(orgId));
  const judged = judgeRange({ orgId, users, from: day, to: day, now });
  const isWorkday = workdays.includes(weekdayOf(day));

  const items = judged.users.map((u) => {
    const d = u.days[0];
    return {
      userId: u.userId, username: u.username, nickname: u.nickname,
      employeeNo: u.employeeNo, deptName: u.deptName,
      shiftName: u.shiftName, shift: d.shift, groupName: u.groupName,
      firstInTime: d.firstInTime, lastOutTime: d.lastOutTime,
      status: d.status, statusLabel: STATUS_LABEL[d.status] || d.status,
      note: d.note, lateMinutes: d.lateMinutes, earlyMinutes: d.earlyMinutes,
      address: null, location: null,
    };
  });

  // 打卡地址：只有看板需要在列表里直接看到，单独查一次（带定位的打卡）
  const locRows = db.prepare(`SELECT user_id, type, address, lat, lng, source FROM att_records
    WHERE org_id=? AND day=? AND (address IS NOT NULL OR lat IS NOT NULL)`).all(Number(orgId), day);
  const locMap = new Map();
  for (const l of locRows) {
    const cur = locMap.get(l.user_id) || {};
    cur[l.type] = { address: l.address, lat: l.lat, lng: l.lng, source: l.source };
    locMap.set(l.user_id, cur);
  }
  for (const it of items) {
    const l = locMap.get(it.userId);
    if (l) {
      it.location = l;
      it.address = (l.in && l.in.address) || (l.out && l.out.address) || null;
    }
  }

  const cnt = (st) => items.filter((i) => i.status === st).length;
  return {
    day,
    isWorkday,
    serverTime: now,
    stats: {
      total: items.length,
      present: items.filter((i) => i.firstInTime || i.lastOutTime).length,
      normal: cnt('normal'),
      late: cnt('late') + cnt('late_early'),
      early: cnt('early') + cnt('late_early'),
      missing: cnt('missing'),
      absent: cnt('absent'),
      leave: cnt('leave'),
      outing: cnt('outing'),
      rest: cnt('rest'),
      pending: cnt('pending') + cnt('future'),
    },
    items,
  };
}

module.exports = {
  TZ, STATUS_LABEL, LEAVE_TYPES, REQUEST_KINDS,
  dayOf, minutesOfDay, tsOfDay, today, weekdayOf, addDays, isValidDay, hhmmOf, fmtHHMM, parseHHMM,
  defaultShift, listShifts, shiftFor, deptChain, deptWithDescendants, groupMemberIds, windowOf,
  clock, recordsOn, recordsRange, decorateRecord,
  judgeDay, judgeRange, summarize, myRange,
  coverageOn, leaveCoverage, leaveDaysOf,
  createRequest, listRequests, reviewRequest, decorateRequest,
  overview,
};
