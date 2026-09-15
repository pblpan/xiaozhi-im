/**
 * 实例级设置（settings 表的 KV 封装）
 *
 * 目前管理两项：
 * - companyName  公司名（存原文，如"盛京"；客户端显示为"盛京小智"）。空 = 未设置。
 * - friendMode   好友模式：'normal' 普通好友模式（自由互加）| 'work' 工作模式（组织机构+工号）。
 *
 * 为什么不用 client_configs：那套是版本化快照 + 灰度 + 回滚，面向"批量下发到
 * 成百上千台设备"的配置；公司名/好友模式是本服务器的身份与策略，改一次全生效，
 * 不需要历史版本。复杂机制只会让"改个名字"变得难懂。
 */
const db = require('./db');

const KEYS = Object.freeze({
  companyName: { key: 'company_name', def: '' },
  friendMode: { key: 'friend_mode', def: 'normal' },
  // 考勤：工作模式下默认开箱可用（"开启工作模式后同时启用"）。
  // 关掉它 = 全组织停用打卡，客户端考勤入口消失但历史记录保留。
  attendanceEnabled: { key: 'attendance_enabled', def: true },
  // 组织默认班次。没建任何考勤组时全员按它打卡 —— 这样"开了工作模式就能用"，
  // 而不是"必须先配班次再用"（配班次是精细化，不该是使用前提）。
  //
  // 填了休息开始/结束 = 一天打 **4 次**卡（上班、下班、上班、下班，靠 slot 分段），
  // 两个在岗段各 4 小时、合计 8 小时；不填就是传统的上班/下班 2 次卡。
  // 默认给 08:00-12:00 / 13:00-17:00 —— 常见的"上午一段下午一段"作息，
  // 不合胃口的在管理台「考勤设置」里改两个时间就行。
  attDefaultShift: {
    key: 'att_default_shift',
    def: {
      workStart: '08:00', restStart: '12:00', restEnd: '13:00', workEnd: '17:00',
      restMinutes: 60,
      flexMinutes: 0, lateGrace: 0, earlyGrace: 0,
    },
  },
  // 应出勤的星期（0=周日 … 6=周六）。默认周一至周五。
  // 工厂/门店周末也上班，所以做成可配；节假日不做统一表（各厂不同），
  // 需要放假的日期用「请假/调休」或管理台手工修正处理。
  attWorkdays: { key: 'att_workdays', def: [1, 2, 3, 4, 5] },
});

const COMPANY_MAX = 20;
const COMPANY_MIN = 2;
const FRIEND_MODES = ['normal', 'work'];
const TIME_RE = /^([01]\d|2[0-3]):[0-5]\d$/;
const MINUTE_MAX = { restMinutes: 480, flexMinutes: 240, lateGrace: 120, earlyGrace: 240 };

function rawGet(key) {
  const row = db.prepare('SELECT value FROM settings WHERE key=?').get(key);
  return row ? row.value : null;
}

/** 读单个设置（带默认值；库里存的是 JSON 字符串，坏数据按默认值兜底不抛错） */
function get(name) {
  const spec = KEYS[name];
  if (!spec) throw new Error(`未知设置项：${name}`);
  const raw = rawGet(spec.key);
  if (raw === null) return spec.def;
  try {
    const v = JSON.parse(raw);
    return v === null ? spec.def : v;
  } catch {
    return spec.def;
  }
}

/** 写设置。返回 { ok: true } 或 { error }。只做本层校验，业务校验在 setCompany 等 */
function setRaw(name, value, by) {
  const spec = KEYS[name];
  if (!spec) return { error: `未知设置项：${name}` };
  db.prepare(`INSERT INTO settings (key,value,updated_at,updated_by) VALUES (?,?,?,?)
    ON CONFLICT(key) DO UPDATE SET value=excluded.value, updated_at=excluded.updated_at, updated_by=excluded.updated_by`)
    .run(spec.key, JSON.stringify(value === undefined ? null : value), Date.now(), String(by || 'admin').slice(0, 60));
  return { ok: true };
}

/** 校验公司名。返回清洗后的值或 { error }。空串 = 清除 */
function cleanCompany(input) {
  const s = String(input ?? '').trim().replace(/\s+/g, '');
  if (!s) return { value: '' };
  if ([...s].length < COMPANY_MIN) return { error: `公司名至少 ${COMPANY_MIN} 个字` };
  if ([...s].length > COMPANY_MAX) return { error: `公司名最多 ${COMPANY_MAX} 个字` };
  if (/[<>"'\\]/.test(s)) return { error: '公司名不能包含特殊字符 < > " \' \\' };
  return { value: s };
}

/** 一次性读全部（bootstrap / 管理台都要用） */
function all() {
  return {
    companyName: get('companyName'),
    friendMode: get('friendMode'),
    attendanceEnabled: get('attendanceEnabled'),
    attDefaultShift: get('attDefaultShift'),
    attWorkdays: get('attWorkdays'),
  };
}

/** 校验时间 'HH:MM' */
function cleanTime(input, label) {
  const s = String(input ?? '').trim();
  if (!TIME_RE.test(s)) return { error: `${label} 需为 HH:MM 格式（如 09:00）` };
  return { value: s };
}

/**
 * 校验默认班次。返回清洗后的值或 { error }。
 * 跨天班（下班 <= 上班）在这里是**合法**的：夜班 22:00-06:00 很常见，
 * 不能因为"下班比上班早"就判为输入错误 —— 那会把工厂夜班挡在门外。
 *
 * 休息时段（restStart/restEnd）：
 *   · 两个都填 = 一天 4 次卡；两个都空 = 一天 2 次卡；只填一个 = 非法
 *     （只填一个的话没法判断该打几次，静默忽略等于"我配了但它没生效"）
 *   · 名字用"休息"而不是"午休"：这段休息可能是午休、晚饭或交接班，
 *     4 次卡的班次也未必是早班（晚班填 17:30-18:30 吃晚饭同样是 4 次卡）
 *   · 必须严格落在上班与下班之间且先后有序，否则判定时会算出负数的在岗时长
 *   · 跨天班（夜班）不支持 —— 凌晨那顿休息跨了日期，语义上不成立，
 *     与其把它算错，不如明确拒绝
 */
function cleanShift(input) {
  if (!input || typeof input !== 'object' || Array.isArray(input)) {
    return { error: '班次必须是一个对象' };
  }
  const out = { ...KEYS.attDefaultShift.def };
  const s = cleanTime(input.workStart, '上班时间');
  if (s.error) return s;
  out.workStart = s.value;
  const e = cleanTime(input.workEnd, '下班时间');
  if (e.error) return e;
  out.workEnd = e.value;

  const rs = String(input.restStart ?? '').trim();
  const re = String(input.restEnd ?? '').trim();
  if (rs || re) {
    if (!rs || !re) return { error: '休息开始与休息结束需要同时填写（同时清空即恢复一天 2 次卡）' };
    const a = cleanTime(rs, '休息开始');
    if (a.error) return a;
    const b = cleanTime(re, '休息结束');
    if (b.error) return b;
    const toMin = (t) => Number(t.slice(0, 2)) * 60 + Number(t.slice(3, 5));
    const [sm, am, bm, em] = [toMin(out.workStart), toMin(a.value), toMin(b.value), toMin(out.workEnd)];
    if (em <= sm) return { error: '跨天班（夜班）不支持休息时段，请清空休息时间' };
    if (!(sm < am && am < bm && bm < em)) {
      return { error: '休息时间需满足：上班 < 休息开始 < 休息结束 < 下班' };
    }
    out.restStart = a.value;
    out.restEnd = b.value;
  } else {
    out.restStart = '';
    out.restEnd = '';
  }

  for (const k of Object.keys(MINUTE_MAX)) {
    if (input[k] === undefined) continue;
    const n = Number(input[k]);
    if (!Number.isFinite(n) || n < 0 || n > MINUTE_MAX[k]) {
      return { error: `${k} 需在 0~${MINUTE_MAX[k]} 之间` };
    }
    out[k] = Math.trunc(n);
  }
  return { value: out };
}

/** 校验应出勤星期数组：去重、升序、0~6 */
function cleanWorkdays(input) {
  if (!Array.isArray(input)) return { error: 'attWorkdays 必须是数组，如 [1,2,3,4,5]' };
  const set = new Set();
  for (const x of input) {
    const n = Number(x);
    if (!Number.isInteger(n) || n < 0 || n > 6) return { error: '星期取值需为 0~6（0=周日）' };
    set.add(n);
  }
  return { value: [...set].sort((a, b) => a - b) };
}

/** 管理台整体更新入口：只处理认识的键，返回 { ok, settings } 或 { error } */
function update(input, by) {
  if (!input || typeof input !== 'object' || Array.isArray(input)) {
    return { error: '设置必须是一个 JSON 对象' };
  }
  for (const k of Object.keys(input)) {
    if (!KEYS[k]) return { error: `不支持的设置项：${k}（允许：${Object.keys(KEYS).join('、')}）` };
  }

  if (input.companyName !== undefined) {
    const c = cleanCompany(input.companyName);
    if (c.error) return { error: c.error };
    const r = setRaw('companyName', c.value, by);
    if (r.error) return r;
  }

  if (input.friendMode !== undefined) {
    if (!FRIEND_MODES.includes(input.friendMode)) {
      return { error: `friendMode 只能是：${FRIEND_MODES.join(' 或 ')}` };
    }
    const r = setRaw('friendMode', input.friendMode, by);
    if (r.error) return r;
  }

  if (input.attendanceEnabled !== undefined) {
    if (typeof input.attendanceEnabled !== 'boolean') {
      return { error: 'attendanceEnabled 必须是 true/false' };
    }
    const r = setRaw('attendanceEnabled', input.attendanceEnabled, by);
    if (r.error) return r;
  }

  if (input.attDefaultShift !== undefined) {
    const c = cleanShift(input.attDefaultShift);
    if (c.error) return { error: c.error };
    const r = setRaw('attDefaultShift', c.value, by);
    if (r.error) return r;
  }

  if (input.attWorkdays !== undefined) {
    const c = cleanWorkdays(input.attWorkdays);
    if (c.error) return { error: c.error };
    const r = setRaw('attWorkdays', c.value, by);
    if (r.error) return r;
  }

  return { ok: true, settings: all() };
}

module.exports = { all, update, cleanCompany, cleanShift, cleanWorkdays, cleanTime, get, KEYS };
