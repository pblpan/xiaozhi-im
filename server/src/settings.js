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
});

const COMPANY_MAX = 20;
const COMPANY_MIN = 2;
const FRIEND_MODES = ['normal', 'work'];

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
  };
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

  return { ok: true, settings: all() };
}

module.exports = { all, update, cleanCompany, get, KEYS };
