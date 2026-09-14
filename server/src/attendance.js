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
  const ws = s.workStart || '08:00';
  const we = s.workEnd || '17:00';
  return normalizeShift({
    id: null,
    name: '默认班次',
    work_start: ws,
    work_end: we,
    rest_start: s.restStart || null,
    rest_end: s.restEnd || null,
    rest_minutes: s.restMinutes || 0,
    flex_minutes: s.flexMinutes || 0,
    late_grace: s.lateGrace || 0,
    early_grace: s.earlyGrace || 0,
    cross_day: parseHHMM(we) <= parseHHMM(ws) ? 1 : 0,
  });
}

/**
 * 班次归一化。
 *
 * `segments` 是这个模块的核心开关：
 *   2 = 填了午休窗口 → 一天 4 次卡（上班 / 午休下班 / 午休上班 / 下班）
 *   1 = 没填        → 一天 2 次卡（上班 / 下班）
 * 其它所有逻辑（判定、补卡、报表、客户端按钮）都只读这一处结论，
 * 不各自再判一遍"到底几次卡"—— 那种写法改一处漏一处，迟早对不上。
 *
 * 午休窗口要"严格落在班次内 + 非跨天"才算成立。不成立时**静默降级为 2 次卡**：
 * 与其拿一个矛盾的班次去算在岗时长（会得出负数），不如退回老行为。
 * 写入侧的校验在 settings.cleanShift / 班次接口里做，那里才该报错给用户看。
 */
function normalizeShift(r) {
  const workStart = r.work_start;
  const workEnd = r.work_end;
  const endMin = parseHHMM(workEnd);
  const startMin = parseHHMM(workStart);
  // 下班 <= 上班 ⇒ 夜班跨天。允许显式 cross_day 覆盖（如 08:00-08:00 的 24h 班）
  const crossDay = !!r.cross_day || (endMin != null && startMin != null && endMin <= startMin);

  const rsRaw = r.rest_start ? String(r.rest_start).trim() : '';
  const reRaw = r.rest_end ? String(r.rest_end).trim() : '';
  const rsMin = rsRaw ? parseHHMM(rsRaw) : null;
  const reMin = reRaw ? parseHHMM(reRaw) : null;
  const hasRest = rsMin != null && reMin != null && !crossDay
    && startMin != null && endMin != null
    && startMin < rsMin && rsMin < reMin && reMin < endMin;

  const out = {
    id: r.id == null ? null : Number(r.id),
    name: r.name || '班次',
    workStart,
    workEnd,
    startMin,
    endMin,
    restStart: hasRest ? rsRaw : null,
    restEnd: hasRest ? reRaw : null,
    restStartMin: hasRest ? rsMin : null,
    restEndMin: hasRest ? reMin : null,
    segments: hasRest ? 2 : 1,
    punchesPerDay: hasRest ? 4 : 2,
    crossDay,
    restMinutes: Number(r.rest_minutes) || 0,
    flexMinutes: Number(r.flex_minutes) || 0,
    lateGrace: Number(r.late_grace) || 0,
    earlyGrace: Number(r.early_grace) || 0,
    enabled: r.enabled === undefined ? true : !!r.enabled,
    sort: Number(r.sort) || 0,
  };
  // 附上一个班次应出勤多少分钟：管理台班次表、客户端"应出勤 8 小时"都要用。
  // 放在这里算，是为了让它跟着 segments 一起出来 —— 让各处自己拿
  // 上班/下班/午休再减一遍，就是给"两处口径不一致"留后门。
  out.expectedWorkMinutes = expectedMinutes(out);
  return out;
}

function shiftRow(id, orgId) {
  const r = db.prepare('SELECT * FROM att_shifts WHERE id=? AND org_id=?').get(Number(id), Number(orgId));
  return r ? normalizeShift(r) : null;
}

/**
 * 解析"这是今天第几次卡"。
 *
 * 只能传 1 或 2（一个班次最多两段）。**不要**写成 `Number(x) === 2 ? 2 : 1`
 * 这种兜底 —— slot=3 会被静默收编成 1：用户以为补的是第 3 次卡，实际补出一张
 * 第 1 段的卡，报表上那天依旧缺卡，而他明明"补过了"。宁可报错，也别悄悄记错。
 *
 * 不传 / 传空 = 1（老客户端只发 type，那会儿还没有 segment 的概念）。
 * 返回 null 表示非法，调用方自己决定报什么错。
 */
function slotOf(input) {
  if (input == null || input === '') return 1;
  const n = Number(input);
  if (!Number.isInteger(n) || n < 1 || n > 2) return null;
  return n;
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

/**
 * 打卡。type='in'|'out'，slot=1|2（第几段：1=上午，2=下午；2 次卡的班次只有 slot 1）。
 *
 * 语义对齐钉钉的「更新打卡」：同一天**同一张卡**（type+slot 相同）已存在时
 * **覆盖最近一条**（返回 updated=true），而不是新增一条 —— 员工手滑打早了会再打一次，
 * 多出来的流水只会让统计和审计都变脏。
 * 但**保留**最近 24 小时内的旧流水（管理台能看到"8:31 打过又 9:02 补打"），
 * 所以这里的"覆盖"是 UPDATE，不是"删掉旧的"。
 *
 * ⚠️ 一天 4 次卡时,"午休下班(out,1)" 和 "下班(out,2)" 是两张**不同的卡**：
 * 只看 type 不看 slot 的话，中午打的那次会把下班卡覆盖掉 —— 员工下午明明打了卡，
 * 报表上却是缺卡。所以下面的去重口径必须带上 slot。
 */
function clock({ userId, orgId, type, slot = 1, at = Date.now(), lat = null, lng = null, address = null, device = null, source = 'app', addressNote = null }) {
  if (!['in', 'out'].includes(type)) return { error: '打卡类型只能是 in 或 out' };
  // 这里的兜底只负责"把脏值收敛到 1"，不做合法性判断 —— clock() 是内部函数，
  // 边界上的 400 由调用方（路由 / createRequest）用 slotOf() 拦掉。
  const sl = Number(slot) === 2 ? 2 : 1;
  const day = dayOf(at);
  const cnt = db.prepare('SELECT COUNT(*) AS c FROM att_records WHERE user_id=? AND day=? AND type=? AND slot=?')
    .get(Number(userId), day, type, sl).c;
  const addr = address ? String(address).slice(0, 120) : null;
  const dev = device ? String(device).slice(0, 80) : null;
  const note = addressNote ? String(addressNote).slice(0, 120) : null;
  if (cnt === 0) {
    const r = db.prepare(`INSERT INTO att_records
      (org_id,user_id,day,type,slot,at,source,lat,lng,address,device,note,created_at)
      VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)`)
      .run(Number(orgId), Number(userId), day, type, sl, at, source,
        lat == null ? null : Number(lat), lng == null ? null : Number(lng),
        addr, dev, note, Date.now());
    return { record: recordById(r.lastInsertRowid), updated: false };
  }
  // 一天同一张卡打 20 次显然是程序在重放请求，不再新增，只覆盖最近一条
  const last = db.prepare('SELECT id FROM att_records WHERE user_id=? AND day=? AND type=? AND slot=? ORDER BY at DESC LIMIT 1')
    .get(Number(userId), day, type, sl);
  db.prepare('UPDATE att_records SET at=?, lat=?, lng=?, address=?, device=?, source=?, note=? WHERE id=?')
    .run(at, lat == null ? null : Number(lat), lng == null ? null : Number(lng),
      addr, dev, source, note, last.id);
  return { record: recordById(last.id), updated: true };
}

function recordById(id) {
  const r = db.prepare(`SELECT r.*, u.username, u.nickname, u.employee_no
    FROM att_records r LEFT JOIN users u ON u.id=r.user_id WHERE r.id=?`).get(Number(id));
  return r ? decorateRecord(r) : null;
}

function decorateRecord(r) {
  const slot = Number(r.slot) === 2 ? 2 : 1;
  return {
    id: r.id,
    userId: r.user_id,
    day: r.day,
    type: r.type,
    slot,
    // punchKey 是这张卡的身份（前端按钮、补卡单、测试断言都用它）。
    // 不给显示名：out1 在 2 次卡里是"下班"、在 4 次卡里是"午休下班"，
    // 只有拿到班次才说得准 —— 谁需要名字谁用 punchLabelOf(shift, key) 取。
    punchKey: r.type + slot,
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

/**
 * 打卡卡片的显示名。同一个 key 在不同班次下含义不同：
 *   · 4 次卡：out1 是"午休下班"（上午那段结束），out2 才是"下班"
 *   · 2 次卡：out1 就是"下班"
 * 所以必须连着班次一起问，不能写死一张表 —— 写死必然在另一种班次下显示错。
 */
function punchLabelOf(shift, key) {
  if (shift && shift.segments === 2) {
    return { in1: '上班', out1: '午休下班', in2: '午休上班', out2: '下班' }[key] || key;
  }
  return { in1: '上班', out1: '下班' }[key] || key;
}

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
 * 一天的请假 + 外出豁免，**按"哪一张卡"给出**。
 *
 * 4 次卡比 2 次卡多一层"哪一段"的语义：
 *   · 上午半天假 = 免 in1/out1（上午那一段），下午照常打 in2/out2
 *   · 下午半天假 = 免 in2/out2
 *   · 整天假     = 四张全免
 * 2 次卡没有"段"的概念，半天假只能沿用它唯一的那套卡：
 *   上午半天假 → 免上班卡，下午半天假 → 免下班卡（老行为，保持兼容）。
 *
 * 外出：只要这张卡的**应打卡时刻**落在外出时段内，就免打。
 */
function coverageOn(reqs, day, win) {
  const cov = {
    leaveFull: false, leaveAm: false, leavePm: false,
    hasOuting: false,
    exempt: {},
  };
  for (const p of win.plan) cov.exempt[p.key] = false;

  for (const r of reqs || []) {
    if (r.status !== 'approved') continue;
    if (r.kind === 'leave') {
      const c = leaveCoverage(r, day);
      if (c.full) { cov.leaveFull = true; cov.leaveAm = true; cov.leavePm = true; }
      if (c.am) cov.leaveAm = true;
      if (c.pm) cov.leavePm = true;
    }
    if (r.kind === 'outing' && r.start_at && r.end_at) {
      for (const p of win.plan) {
        if (p.at >= r.start_at && p.at <= r.end_at) { cov.exempt[p.key] = true; cov.hasOuting = true; }
      }
    }
  }

  if (win.segments === 1) {
    if (cov.leaveAm) cov.exempt.in1 = true;
    if (cov.leavePm) cov.exempt.out1 = true;
  } else {
    for (const p of win.plan) {
      if (p.slot === 1 && cov.leaveAm) cov.exempt[p.key] = true;
      if (p.slot === 2 && cov.leavePm) cov.exempt[p.key] = true;
    }
  }
  return cov;
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
 * 一天里该打哪几次卡 —— 全模块唯一的"打卡计划"来源。
 *
 * 2 次卡：in1 上班、out1 下班
 * 4 次卡：in1 上班、out1 午休下班、in2 午休上班、out2 下班
 *
 * key 的命名刻意保持 `in1/out1/in2/out2`：它同时是前端的按钮身份、
 * 补卡单里的"补哪一张"、以及测试里的断言名。改名 = 老客户端点错按钮。
 */
function punchPlan(shift, day) {
  const mk = (key, type, slot, hhmm, label) => ({
    key, type, slot, hhmm, label, at: tsOfDay(day, hhmm),
  });
  const plan = shift.segments === 2
    ? [
      mk('in1', 'in', 1, shift.workStart, '上班'),
      mk('out1', 'out', 1, shift.restStart, '午休下班'),
      mk('in2', 'in', 2, shift.restEnd, '午休上班'),
      mk('out2', 'out', 2, shift.workEnd, '下班'),
    ]
    : [
      mk('in1', 'in', 1, shift.workStart, '上班'),
      mk('out1', 'out', 1, shift.workEnd, '下班'),
    ];
  // 跨天班：下班（以及 4 次卡里任何早于上班的时刻）落在**次日**。
  // 这里统一把"比第一张卡还早"的时刻 +24h 拉直，下游就只需前后比大小。
  const first = plan[0].at;
  for (const p of plan) if (p.at < first) p.at += DAY_MS;
  return plan;
}

/**
 * 班次在某天的绝对时间窗。
 * endAt 一定晚于 startAt —— 跨天班在这里被"拉直"，下游所有比较都只需前后比大小，
 * 不用再各写一遍"到底算不算次日"。
 */
function windowOf(shift, day) {
  const plan = punchPlan(shift, day);
  return {
    day,
    segments: shift.segments,
    plan,
    startAt: plan[0].at,
    endAt: plan[plan.length - 1].at,
  };
}

/** 午休窗口的绝对时刻（只有 4 次卡才有），没有则 null */
function restWindowOf(shift, day) {
  if (shift.segments !== 2) return null;
  return { startAt: tsOfDay(day, shift.restStart), endAt: tsOfDay(day, shift.restEnd) };
}

/** 在岗时长（分钟）：把每一段的 下班-上班 加起来；缺一边的段不计入 */
function workedMinutes(shift, day, punches) {
  const get = (key) => {
    const p = (punches || []).find((x) => x.key === key);
    return p && p.at != null ? p.at : null;
  };
  if (shift.segments === 2) {
    let sum = 0;
    const a = get('in1'); const b = get('out1'); const c = get('in2'); const d = get('out2');
    if (a != null && b != null && b > a) sum += Math.round((b - a) / 60000);
    if (c != null && d != null && d > c) sum += Math.round((d - c) / 60000);
    return sum;
  }
  const a = get('in1'); const b = get('out1');
  if (a != null && b != null && b > a) return Math.round((b - a) / 60000);
  return 0;
}

/** 应出勤时长（分钟）：4 次卡 = 两段之和；2 次卡 = 班次跨度 - 休息时长 */
function expectedMinutes(shift) {
  if (shift.segments === 2) {
    return (shift.restStartMin - shift.startMin) + (shift.endMin - shift.restEndMin);
  }
  const span = shift.crossDay ? (DAY_MS / 60000) + shift.endMin - shift.startMin : shift.endMin - shift.startMin;
  return Math.max(0, span - shift.restMinutes);
}

/** "待打 X 卡"这类进行中的说明文字 */
function pendingNote(punches, cov) {
  if (cov.leaveAm && !cov.leavePm) return '上午请假';
  const next = punches.find((p) => p.status === 'pending');
  if (!next) return '进行中';
  const done = punches.filter((p) => p.done).length;
  if (done === 0) return `待打${next.label}卡`;
  return `已打 ${done} 次，待打${next.label}卡`;
}

/** 迟到/早退带上"是哪一张卡"，否则 4 次卡下"迟到 5 分钟"根本看不出是上午还是下午 */
function punchNote(prefix, minutes, items) {
  const parts = items.map((p) => `${p.label} ${p.lateMinutes || p.earlyMinutes} 分`);
  return `${prefix} ${minutes} 分钟（${parts.join('，')}）`;
}

/**
 * 判定某人在某天的考勤状态。
 * 入参全是"已经取好的数据"，不碰数据库 —— 这样它既能被报表批量调用（几万次），
 * 也能被测试直接喂各种边界（迟到一分钟、跨天班、半天假、四段卡）。
 *
 * 【判定粒度是"每一张卡"，不是"一天"】
 * 4 次卡的班次里，上午迟到和下午迟到是两件事，中午忘了打午休下班也是缺卡。
 * 所以先逐张卡算出 { 应打时刻、实打时刻、状态、迟到/早退分钟 }，再由这些卡片
 * 汇总出整天状态。好处是"缺的到底是哪一张"永远说得清楚，报表也能给出"3/4"。
 *
 * status（整天；取值与旧版一致，前端不用改）：
 *   rest     休息日        normal  正常        late     迟到
 *   early    早退          late_early 迟到+早退
 *   missing  缺卡（缺部分）  absent  缺勤（一张都没打）
 *   leave    请假          outing  外出        pending  进行中（今天还有卡没到点）
 *   future   未来日期（不判）
 */
function judgeDay({ day, now, shift, recs, reqs, workdays }) {
  const wd = weekdayOf(day);
  const isWorkday = (workdays || []).includes(wd);
  const win = windowOf(shift, day);
  const cov = coverageOn(reqs, day, win);
  const todayStr = dayOf(now);
  const isToday = day === todayStr;

  // 用时间窗取记录，而不是只用 day 字段：跨天班的下班卡落在次日，
  // 按 day 取就会"下班卡凭空消失"，然后全组被判缺卡。
  const inWin = (recs || []).filter((r) => r.at >= win.startAt - 6 * 3600e3 && r.at <= win.endAt + 6 * 3600e3);
  const latest = (type, slot) => {
    const hits = inWin.filter((r) => r.type === type && (Number(r.slot) === 2 ? 2 : 1) === slot);
    return hits.length ? Math.max(...hits.map((r) => r.at)) : null;
  };

  // 逐张卡判定。弹性只作用于**当天第一次上班**（in1）：下午那次若也给弹性，
  // "晚到两小时"就变成合法了 —— 那不叫弹性，叫没规定下午上班时间。
  const punches = win.plan.map((p) => {
    const at = latest(p.type, p.slot);
    const exempt = !!cov.exempt[p.key];
    const due = now >= p.at;                    // 这张卡到点了没有
    const item = {
      key: p.key, type: p.type, slot: p.slot,
      label: punchLabelOf(shift, p.key),
      expectTime: p.hhmm, expectAt: p.at,
      at, done: at != null, due, exempt,
      lateMinutes: 0, earlyMinutes: 0, status: 'pending',
    };
    if (at == null) {
      item.status = exempt ? 'exempt' : (due ? 'missing' : 'pending');
      return item;
    }
    const m = minutesOfDay(at);
    const expectMin = minutesOfDay(p.at);
    if (p.type === 'in') {
      const flex = p.key === 'in1' ? shift.flexMinutes : 0;
      item.lateMinutes = Math.max(0, m - (expectMin + flex + shift.lateGrace));
      item.status = item.lateMinutes > 0 ? 'late' : 'ok';
    } else {
      // 早退只有"这张卡已经到点"才算得出来。上午 10:41 打了一张下班卡，
      // 若拿 17:00 去减会得出"早退 379 分钟"这种荒唐数字 —— 他可能只是提前
      // 收工，也可能点错了按钮，但无论哪种，现在给的都是一个肯定错的数。
      const earlyMin = due ? Math.max(0, (expectMin - shift.earlyGrace) - m) : 0;
      item.earlyMinutes = earlyMin;
      item.status = earlyMin > 0 ? 'early' : 'ok';
    }
    return item;
  });

  const doneItems = punches.filter((p) => p.done);
  const missingItems = punches.filter((p) => p.status === 'missing');
  const pendingItems = punches.filter((p) => p.status === 'pending');
  const lateItems = punches.filter((p) => p.lateMinutes > 0);
  const earlyItems = punches.filter((p) => p.earlyMinutes > 0);
  const lateMinutes = punches.reduce((s, p) => s + p.lateMinutes, 0);
  const earlyMinutes = punches.reduce((s, p) => s + p.earlyMinutes, 0);
  const inAts = punches.filter((p) => p.type === 'in' && p.at != null).map((p) => p.at);
  const outAts = punches.filter((p) => p.type === 'out' && p.at != null).map((p) => p.at);
  const firstIn = inAts.length ? Math.min(...inAts) : null;
  const lastOut = outAts.length ? Math.max(...outAts) : null;

  const base = {
    day, weekday: wd, isWorkday,
    shift: {
      name: shift.name, workStart: shift.workStart, workEnd: shift.workEnd,
      restStart: shift.restStart, restEnd: shift.restEnd,
      segments: shift.segments, punchesPerDay: shift.punchesPerDay,
    },
    punches,
    expectedPunches: shift.punchesPerDay,
    donePunches: doneItems.length,
    missingPunches: missingItems.map((p) => p.key),
    missingLabels: missingItems.map((p) => p.label),
    firstIn, lastOut,
    firstInTime: firstIn == null ? null : hhmmOf(firstIn),
    lastOutTime: lastOut == null ? null : hhmmOf(lastOut),
    lateMinutes: 0,
    earlyMinutes: 0,
    leave: cov.leaveFull ? 'full' : (cov.leaveAm ? 'am' : (cov.leavePm ? 'pm' : null)),
    outing: cov.hasOuting,
    overtimeMinutes: overtimeMinutesOn(reqs, day),
    workedMinutes: workedMinutes(shift, day, punches),
    expectedWorkMinutes: expectedMinutes(shift),
  };

  if (day > todayStr) {
    return {
      ...base, status: 'future', note: '尚未到来',
      punches: punches.map((p) => ({ ...p, status: p.exempt ? 'exempt' : 'future' })),
    };
  }

  if (!isWorkday) {
    // 休息日：不判出勤，只记录有没有来加班
    return { ...base, status: 'rest', note: base.overtimeMinutes ? `加班 ${Math.round(base.overtimeMinutes / 60 * 10) / 10} 小时` : '休息日' };
  }

  base.lateMinutes = lateMinutes;

  if (cov.leaveFull) return { ...base, status: 'leave', note: '请假' };

  // 今天还有卡没到点：只报既成事实，别把"还没到点"说成缺卡
  // （否则每天上午全公司都是"缺卡"，这功能第一次打开就会被骂）
  if (isToday && pendingItems.length > 0) {
    if (now < win.startAt) return { ...base, status: 'pending', note: '未到上班时间' };
    if (missingItems.length > 0) {
      // 中间那几张已经到点却没打 —— 这是真的缺卡（比如中午忘了打午休下班），
      // 不能因为"后面还有卡没到点"就整天空着不报
      return {
        ...base, status: 'missing',
        note: `缺${missingItems.map((p) => p.label).join('、')}卡，其余进行中`,
      };
    }
    if (lateItems.length > 0) {
      return { ...base, status: 'late', note: punchNote('迟到', lateMinutes, lateItems) };
    }
    return { ...base, status: 'pending', note: pendingNote(punches, cov) };
  }

  // 走到这里说明这天已经过完（或所有卡都到点了），早退才成立
  base.earlyMinutes = earlyMinutes;

  if (doneItems.length === 0 && punches.some((p) => !p.exempt)) {
    return { ...base, status: 'absent', note: '未打卡' };
  }
  if (missingItems.length > 0) {
    return { ...base, status: 'missing', note: `缺${missingItems.map((p) => p.label).join('、')}卡` };
  }
  // 半天假 + 其余卡都打齐了：只要没迟到早退就算正常
  if (lateItems.length > 0 && earlyItems.length > 0) {
    return {
      ...base, status: 'late_early',
      note: `${punchNote('迟到', lateMinutes, lateItems)}，${punchNote('早退', earlyMinutes, earlyItems)}`,
    };
  }
  if (lateItems.length > 0) return { ...base, status: 'late', note: punchNote('迟到', lateMinutes, lateItems) };
  if (earlyItems.length > 0) return { ...base, status: 'early', note: punchNote('早退', earlyMinutes, earlyItems) };
  if (cov.hasOuting) return { ...base, status: 'outing', note: '外出' };
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
      // 报表要按"这人一天打几次卡"渲染列，所以分段信息必须跟着人走 ——
      // 同一个组织里 2 次卡和 4 次卡的人可以共存（不同考勤组）
      shift: {
        name: shift.name, workStart: shift.workStart, workEnd: shift.workEnd,
        restStart: shift.restStart, restEnd: shift.restEnd,
        segments: shift.segments, punchesPerDay: shift.punchesPerDay,
      },
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
    // 打卡次数与在岗时长：4 次卡的班次下，"来了没有"不够用，
    // 管理者要知道"应该打 4 次、实际打了 3 次"和"在岗几小时"。
    expectedPunches: 0, donePunches: 0, missingPunches: 0,
    workedMinutes: 0, expectedWorkMinutes: 0,
    fullDays: 0,     // 当日卡片全部打齐的天数
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

    // 次数/工时只在"确实该出勤且已经过完"的日子上累计 ——
    // 把休息日和未来日期算进来会让"应打 88 次"这种数字看着就不对
    const countable = d.isWorkday && d.status !== 'rest' && d.status !== 'future';
    if (countable) {
      s.expectedPunches += d.expectedPunches || 0;
      s.donePunches += d.donePunches || 0;
      s.missingPunches += (d.missingPunches || []).length;
      s.workedMinutes += d.workedMinutes || 0;
      s.expectedWorkMinutes += d.expectedWorkMinutes || 0;
      if ((d.expectedPunches || 0) > 0 && d.donePunches >= d.expectedPunches) s.fullDays++;
    }
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

function createRequest({ orgId, userId, kind, reason, startDay, endDay, half, leaveType, day, clockType, at, slot, startAt, endAt }) {
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
    // 一天 2 次卡的班次没有"第 2 段"。不拦的话会写出一张**没有任何判定会看它**的
    // 孤儿卡：审批通过了、管理台也显示"已补"，但考勤结果一点没变。
    const sl = slotOf(slot);
    if (sl == null) return { error: '补卡只能补第 1 次卡或第 2 次卡' };
    const { shift } = shiftFor(userId, orgId);
    if (sl > shift.segments) {
      return {
        error: `当前班次（${shift.workStart}-${shift.workEnd}${shift.restStart ? ` / 午休 ${shift.restStart}-${shift.restEnd}` : ''}）`
          + `一天打 ${shift.punchesPerDay} 次卡，没有第 ${sl} 次卡可补`,
      };
    }
    Object.assign(base, { day, clock_type: clockType, at: ts, slot: sl });
  } else {
    const s = Number(startAt); const e = Number(endAt);
    if (!Number.isFinite(s) || !Number.isFinite(e) || e <= s) return { error: '请选择正确的起止时间' };
    if (Math.round((e - s) / 60000) > 24 * 60) return { error: '单次时长不能超过 24 小时' };
    Object.assign(base, { start_at: s, end_at: e, day: dayOf(s) });
  }
  // ⚠️ slot 是整数列，兜底必须用 0 而不是 ''（SQLite 里 INTEGER 恒小于 TEXT，
  // `0 = ''` 永远为假 —— 一旦写成 IFNULL(?,'') 去重就静默失效，重复申请照样进库）
  const dup = db.prepare(`SELECT id FROM att_requests WHERE user_id=? AND kind=? AND status='pending'
    AND IFNULL(start_day,'')=IFNULL(?,'') AND IFNULL(day,'')=IFNULL(?,'')
    AND IFNULL(clock_type,'')=IFNULL(?,'') AND IFNULL(slot,0)=IFNULL(?,0)`)
    .get(base.userId, kind, base.start_day || null, base.day || null,
      base.clock_type || null, base.slot || null);
  if (dup) return { error: '同类型的申请正在审批中，请勿重复提交' };

  const info = db.prepare(`INSERT INTO att_requests
    (org_id,user_id,kind,status,reason,start_day,end_day,half,leave_type,day,clock_type,at,slot,start_at,end_at,created_at)
    VALUES (?,?,?,'pending',?,?,?,?,?,?,?,?,?,?,?,?)`)
    .run(base.orgId, base.userId, kind, base.reason || null,
      base.start_day || null, base.end_day || null, base.half || 0, base.leave_type || null,
      base.day || null, base.clock_type || null, base.at || null, base.slot || 0,
      base.start_at || null, base.end_at || null,
      Date.now());
  return { id: info.lastInsertRowid };
}

/** shiftFor 的短时记忆：列表里同一人可能出现在多行，没必要反复查库 */
function shiftForCached(userId, orgId, cache) {
  const k = Number(userId);
  if (cache.has(k)) return cache.get(k);
  const v = shiftFor(k, orgId);
  cache.set(k, v);
  return v;
}

/**
 * 申请单的展示形态。
 * `shift` 可选：给了才能把"补卡"写成"补午休下班卡"这种人话
 * （同一张 out/1，2 次卡里叫"下班卡"、4 次卡里叫"午休下班卡"，只有班次说得准）。
 */
function decorateRequest(r, shift = null) {
  const km = { leave: '请假', makeup: '补卡', outing: '外出', overtime: '加班' };
  const lm = { personal: '事假', sick: '病假', annual: '年假', comp: '调休' };
  const half = Number(r.half) || 0;
  const slot = Number(r.slot) === 2 ? 2 : 1;
  const punchKey = r.clock_type ? r.clock_type + slot : null;
  const punchLabel = punchKey ? punchLabelOf(shift, punchKey) : null;
  let desc = '';
  if (r.kind === 'leave') {
    desc = r.start_day === r.end_day
      ? `${r.start_day}${half === 1 ? ' 上午' : half === 2 ? ' 下午' : ' 全天'}`
      : `${r.start_day} ~ ${r.end_day}`;
    if (r.leave_type) desc += `（${lm[r.leave_type] || r.leave_type}）`;
  } else if (r.kind === 'makeup') {
    const who = punchLabel || (r.clock_type === 'in' ? '上班卡' : '下班卡');
    desc = `${r.day} ${who}${punchLabel ? '卡' : ''} 补 ${r.at ? hhmmOf(r.at) : ''}`;
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
    day: r.day, clockType: r.clock_type, clockSlot: slot, punchKey, punchLabel,
    at: r.at, startAt: r.start_at, endAt: r.end_at,
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
  const cache = new Map();
  return db.prepare(`SELECT r.*, u.username, u.nickname, u.employee_no
    FROM att_requests r LEFT JOIN users u ON u.id=r.user_id
    WHERE ${where.join(' AND ')} ORDER BY r.created_at DESC LIMIT ?`).all(...args)
    .map((r) => decorateRequest(r, shiftForCached(r.user_id, orgId, cache).shift));
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
    // 补的是哪一张卡必须带上 slot：4 次卡里"午休下班(out,1)"和"下班(out,2)"
    // 是两张卡，只按 type 删旧记录、只按 type 写入，会把下班卡覆盖成中午那次。
    const slot = Number(r.slot) === 2 ? 2 : 1;
    db.prepare('DELETE FROM att_records WHERE user_id=? AND day=? AND type=? AND slot=? AND source=?')
      .run(r.user_id, r.day, r.clock_type, slot, 'makeup');
    clock({
      userId: r.user_id, orgId: Number(orgId), type: r.clock_type, slot, at: r.at,
      source: 'makeup', addressNote: note || '补卡审批通过',
    });
  }

  db.prepare('UPDATE att_requests SET status=?, reviewed_by=?, reviewed_at=?, review_note=? WHERE id=?')
    .run(approve ? 'approved' : 'rejected', Number(reviewerId), Date.now(), note ? String(note).slice(0, 120) : null, Number(id));
  const row = db.prepare(`SELECT r.*, u.username, u.nickname, u.employee_no
    FROM att_requests r LEFT JOIN users u ON u.id=r.user_id WHERE r.id=?`).get(Number(id));
  const { shift } = shiftFor(row.user_id, Number(orgId));
  return { ok: true, request: decorateRequest(row, shift) };
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
      // 逐张卡的实况：4 次卡的看板必须能一眼看出"缺的是午休下班还是下午上班"，
      // 只给最早的上班和最晚的下班是看不出来的
      punches: d.punches.map((p) => ({
        key: p.key, type: p.type, slot: p.slot, label: p.label,
        expectTime: p.expectTime, time: p.at == null ? null : hhmmOf(p.at),
        at: p.at, status: p.status, due: p.due, exempt: p.exempt,
        lateMinutes: p.lateMinutes, earlyMinutes: p.earlyMinutes,
      })),
      expectedPunches: d.expectedPunches,
      donePunches: d.donePunches,
      missingLabels: d.missingLabels,
      workedMinutes: d.workedMinutes,
      expectedWorkMinutes: d.expectedWorkMinutes,
      status: d.status, statusLabel: STATUS_LABEL[d.status] || d.status,
      note: d.note, lateMinutes: d.lateMinutes, earlyMinutes: d.earlyMinutes,
      address: null, location: null,
    };
  });

  // 打卡地址：只有看板需要在列表里直接看到，单独查一次（带定位的打卡）
  const locRows = db.prepare(`SELECT user_id, type, slot, address, lat, lng, source FROM att_records
    WHERE org_id=? AND day=? AND (address IS NOT NULL OR lat IS NOT NULL)`).all(Number(orgId), day);
  const locMap = new Map();
  for (const l of locRows) {
    const cur = locMap.get(l.user_id) || {};
    cur[l.type + (Number(l.slot) === 2 ? 2 : 1)] = { address: l.address, lat: l.lat, lng: l.lng, source: l.source };
    locMap.set(l.user_id, cur);
  }
  for (const it of items) {
    const l = locMap.get(it.userId);
    if (l) {
      it.location = l;
      const withAddr = it.punches.filter((p) => l[p.key] && l[p.key].address);
      it.address = withAddr.length ? l[withAddr[0].key].address : null;
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
      // 打卡次数维度：4 次卡下"出勤率"看人数已经不够，还要看次数
      punchesDone: items.reduce((s, i) => s + (i.donePunches || 0), 0),
      punchesExpected: items.reduce((s, i) => s + (i.expectedPunches || 0), 0),
      missingPunches: items.reduce((s, i) => s + (i.missingLabels || []).length, 0),
    },
    items,
  };
}

module.exports = {
  TZ, STATUS_LABEL, LEAVE_TYPES, REQUEST_KINDS,
  dayOf, minutesOfDay, tsOfDay, today, weekdayOf, addDays, isValidDay, hhmmOf, fmtHHMM, parseHHMM,
  defaultShift, listShifts, shiftFor, shiftForCached, deptChain, deptWithDescendants, groupMemberIds, windowOf,
  restWindowOf, punchPlan, punchLabelOf, slotOf, workedMinutes, expectedMinutes,
  clock, recordsOn, recordsRange, decorateRecord,
  judgeDay, judgeRange, summarize, myRange,
  coverageOn, leaveCoverage, leaveDaysOf,
  createRequest, listRequests, reviewRequest, decorateRequest,
  overview,
};
