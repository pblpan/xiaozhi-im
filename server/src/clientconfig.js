/**
 * 客户端配置中心（SPEC-动态配置与模块.md 第一期）
 *
 * 设计要点：
 * - client_configs 版本化快照，只增不改；回滚 = 用旧内容发布新版本。
 * - payload 结构严格白名单校验：管理台发上来的东西会被成百上千台设备吃下去，
 *   服务端必须先把脏数据挡住，不能指望客户端"解析失败就保持现状"兜底。
 * - bootstrap 免鉴权（登录前也要拿地址/公告），所以 current() 里绝不能混入
 *   用户定向内容——这是硬边界，见 SPEC §6.1。
 */
const db = require('./db');

/** 首版默认配置：没有任何候选地址时，客户端继续用打包内置地址，行为不变 */
const DEFAULT_CONFIG = Object.freeze({
  serverAddresses: [], // 候选服务器地址，按优先级排序
  features: {},        // 功能开关：{ "groupCall": true, ... }
  minClientVersion: null, // 最低允许版本 "X.Y.Z"；null = 不限制
  upgradeUrl: null,       // 升级说明页/下载地址
  announcements: [],      // 公告 [{ text, level: info|warn|critical }]
  maintenance: null,      // 维护公告 { text, until } 或 null
});

const VERSION_RE = /^\d+\.\d+\.\d+$/;
const MAX_ADDRESSES = 10;
const MAX_ANNOUNCEMENTS = 5;

function current() {
  let row = db.prepare('SELECT version, payload FROM client_configs ORDER BY version DESC LIMIT 1').get();
  if (!row) {
    // 懒播种：保证 bootstrap 开箱即有 version=1，客户端永远能拿到合法结构
    db.prepare('INSERT INTO client_configs (version, payload, note, created_by, created_at) VALUES (?,?,?,?,?)')
      .run(1, JSON.stringify(DEFAULT_CONFIG), '初始默认配置', 'system', Date.now());
    row = { version: 1, payload: JSON.stringify(DEFAULT_CONFIG) };
  }
  let payload;
  try {
    payload = JSON.parse(row.payload);
  } catch {
    // 理论上到不了这里（发布前已校验）；真发生时回退默认，绝不让接口 500
    payload = { ...DEFAULT_CONFIG };
  }
  return { version: row.version, payload };
}

function history(limit = 20) {
  return db.prepare(`SELECT version, note, created_by, created_at, LENGTH(payload) bytes
    FROM client_configs ORDER BY version DESC LIMIT ?`).all(Math.min(Number(limit) || 20, 100));
}

function payloadOf(version) {
  const row = db.prepare('SELECT payload FROM client_configs WHERE version=?').get(Number(version));
  if (!row) return null;
  try { return JSON.parse(row.payload); } catch { return null; }
}

/**
 * 校验并规范化 payload。返回 { ok, payload?, error? }。
 * 未知顶层键直接拒绝——宁可发布时报错，也不要静默丢字段让管理员以为改成功了。
 */
function validate(input) {
  if (!input || typeof input !== 'object' || Array.isArray(input)) {
    return { error: '配置必须是一个 JSON 对象' };
  }
  const known = Object.keys(DEFAULT_CONFIG);
  for (const k of Object.keys(input)) {
    if (!known.includes(k)) return { error: `不支持的配置项：${k}（允许：${known.join('、')}）` };
  }
  const out = { ...DEFAULT_CONFIG };

  // serverAddresses：字符串数组，http(s) 开头，去重、限 10 条
  if (input.serverAddresses !== undefined) {
    const a = input.serverAddresses;
    if (!Array.isArray(a)) return { error: 'serverAddresses 必须是地址数组' };
    const seen = new Set();
    const list = [];
    for (const raw of a) {
      const s = String(raw || '').trim().replace(/\/+$/, '');
      if (!s) continue;
      if (!/^https?:\/\//i.test(s)) return { error: `地址必须以 http:// 或 https:// 开头：${s}` };
      if (!seen.has(s)) { seen.add(s); list.push(s); }
    }
    if (list.length > MAX_ADDRESSES) return { error: `地址最多 ${MAX_ADDRESSES} 条` };
    out.serverAddresses = list;
  }

  // features：对象，值只能是 bool（开关语义保持单一，Phase 1 不做字符串参数）
  if (input.features !== undefined) {
    const f = input.features;
    if (!f || typeof f !== 'object' || Array.isArray(f)) return { error: 'features 必须是对象' };
    for (const [k, v] of Object.entries(f)) {
      if (typeof v !== 'boolean') return { error: `功能开关 ${k} 的值必须是 true/false` };
      if (!/^[a-zA-Z][a-zA-Z0-9_]{0,39}$/.test(k)) return { error: `功能开关名不合法：${k}` };
    }
    out.features = f;
  }

  if (input.minClientVersion !== undefined) {
    const v = input.minClientVersion;
    if (v !== null && v !== undefined && v !== '') {
      if (typeof v !== 'string' || !VERSION_RE.test(v.trim())) {
        return { error: 'minClientVersion 必须是 X.Y.Z 格式或 null' };
      }
      out.minClientVersion = v.trim();
    }
  }

  if (input.upgradeUrl !== undefined) {
    const u = input.upgradeUrl;
    if (u !== null && u !== undefined && u !== '') {
      if (typeof u !== 'string' || !/^https?:\/\//i.test(u.trim())) {
        return { error: 'upgradeUrl 必须以 http:// 或 https:// 开头' };
      }
      out.upgradeUrl = u.trim();
    }
  }

  if (input.announcements !== undefined) {
    const a = input.announcements;
    if (!Array.isArray(a)) return { error: 'announcements 必须是数组' };
    if (a.length > MAX_ANNOUNCEMENTS) return { error: `公告最多 ${MAX_ANNOUNCEMENTS} 条` };
    const list = [];
    for (const raw of a) {
      const text = String(raw?.text || '').trim();
      if (!text) return { error: '公告内容（text）不能为空' };
      const level = ['info', 'warn', 'critical'].includes(raw?.level) ? raw.level : 'info';
      list.push({ text, level });
    }
    out.announcements = list;
  }

  if (input.maintenance !== undefined) {
    const m = input.maintenance;
    if (m === null || m === undefined) {
      out.maintenance = null;
    } else {
      const text = String(m.text || '').trim();
      if (!text) return { error: '维护公告内容（text）不能为空' };
      let until = null;
      if (m.until !== undefined && m.until !== null && m.until !== '') {
        until = Number(m.until);
        if (!Number.isFinite(until)) return { error: '维护截止时间（until）必须是时间戳' };
      }
      out.maintenance = { text, until };
    }
  }

  return { payload: out };
}

/** 发布新版本。version = 当前最大版本 + 1 */
function publish(payload, note, by) {
  const v = validate(payload);
  if (v.error) return { error: v.error };
  const maxRow = db.prepare('SELECT MAX(version) m FROM client_configs').get();
  const next = (maxRow?.m || 0) + 1;
  db.prepare('INSERT INTO client_configs (version, payload, note, created_by, created_at) VALUES (?,?,?,?,?)')
    .run(next, JSON.stringify(v.payload), String(note || '').slice(0, 200) || null,
      String(by || 'admin').slice(0, 60), Date.now());
  return { version: next, payload: v.payload };
}

/** 回滚 = 用旧版本内容发布新版本（历史只增不改，这是刻意的取舍，见 SPEC §5） */
function rollback(fromVersion, by) {
  const p = payloadOf(fromVersion);
  if (!p) return { error: `版本 ${fromVersion} 不存在` };
  const r = publish(p, `回滚自 v${fromVersion}`, by);
  return r;
}

/** 上报已生效版本（幂等：同一设备重复上报只刷新时间） */
function reportApplied(userId, deviceId, configVersion) {
  const v = Number(configVersion);
  if (!Number.isInteger(v) || v <= 0) return false;
  const dev = String(deviceId || 'default').slice(0, 64);
  db.prepare(`INSERT INTO config_applied (user_id, device_id, config_version, applied_at)
    VALUES (?,?,?,?)
    ON CONFLICT(user_id, device_id)
    DO UPDATE SET config_version=excluded.config_version, applied_at=excluded.applied_at`)
    .run(userId, dev, v, Date.now());
  return true;
}

/** 同步状态：每台设备的生效版本 + 用户名，管理员一眼看出谁还在旧配置 */
function appliedStatus(latestVersion) {
  return db.prepare(`SELECT a.device_id, a.config_version, a.applied_at,
      a.user_id, u.nickname, u.username,
      CASE WHEN a.config_version >= ? THEN 'latest' ELSE 'stale' END state
    FROM config_applied a LEFT JOIN users u ON u.id=a.user_id
    ORDER BY a.applied_at DESC LIMIT 500`).all(latestVersion);
}

module.exports = {
  DEFAULT_CONFIG,
  current,
  history,
  payloadOf,
  validate,
  publish,
  rollback,
  reportApplied,
  appliedStatus,
};
