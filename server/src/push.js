'use strict';
/**
 * APNs 推送 —— iOS 上「退到后台还能收到消息」的唯一途径
 *
 * 【为什么必须有这一层】
 *   Android 客户端缩到后台靠**常连 WebSocket**继续收消息（所以那个版本做了
 *   "关闭窗口缩到托盘"）。iOS 没有这个可能：App 一退到后台，进程很快被系统挂起，
 *   socket 断掉，**不打开 App 就永远收不到消息**。这恰好把这个 IM 存在的理由
 *   （能随时收到消息）抹掉了。所以 iOS 版离不开服务端推送。
 *
 * 【职责边界】这里只管"把一条通知投到某个用户的设备上"，不负责文案。
 *   通知标题/正文由 chat.js 组装（它才持有会话名、备注、消息类型这些产品语义），
 *   本模块只做传输 + 落库 + 失效令牌治理。这样避免"标题在两处各写一份"。
 *
 * 【鉴权方式】用 Apple 的 **token-based（.p8 密钥）**，不是老的证书：
 *   · 一把密钥管所有 App、所有环境，不会像推送证书那样一年一换再全量重发
 *   · 每次请求带一个自签的 ES256 JWT（用 node:crypto 就能签，**不需要新增依赖**）
 *   · 只用出站 443，不需要任何端口映射 —— 和 Cloudflare TURN 一个道理
 *
 * 【凭据存放】写 `${DATA_DIR}/apns.env`（共享数据目录，容器重建不丢，权限 600）。
 *   和 turn.env 同样的理由：改推送配置**不该需要重建容器**。
 *
 * 【可观测性】每次投递结果都落 `push_log`（成功/失败/APNs 的 reason）。
 *   没有这张表，"用户说收不到通知"就只能靠猜 —— 而 APNs 的错误原因
 *   （BadDeviceToken / Unregistered / DeviceTokenNotForTopic）恰恰能直接定位问题。
 */

const fs = require('fs');
const path = require('path');
const http2 = require('node:http2');
const crypto = require('crypto');

const config = require('./config');
const db = require('./db');

// ---------------------------------------------------------------------------
// 配置：写入 apns.env，支持不重启热加载
// ---------------------------------------------------------------------------

const APNS_ENV_FILE = path.join(config.DATA_DIR, 'apns.env');

/** 允许写进 apns.env 的键（白名单，防止被塞进别的环境变量） */
const APNS_ENV_KEYS = [
  'APNS_KEY_ID',
  'APNS_TEAM_ID',
  'APNS_TOPIC',
  'APNS_KEY_P8',
  'APNS_ENV',
];

/**
 * 读 apns.env。返回值里的 `\n` 会被还原成真换行 ——
 * .p8 是 PEM 多行文本，而 env 文件一行一个键值，只能在写入时转义。
 */
function readApnsEnv() {
  try {
    if (!fs.existsSync(APNS_ENV_FILE)) return {};
    const out = {};
    for (const line of fs.readFileSync(APNS_ENV_FILE, 'utf8').split(/\r?\n/)) {
      const s = line.trim();
      if (!s || s.startsWith('#')) continue;
      const i = s.indexOf('=');
      if (i <= 0) continue;
      const k = s.slice(0, i).trim();
      if (!APNS_ENV_KEYS.includes(k)) continue;
      out[k] = s.slice(i + 1).trim().replace(/\\n/g, '\n');
    }
    return out;
  } catch {
    return {};
  }
}

/** 合并写回 apns.env（只动传入的键，保留其他行）。空值 = 清除该项。 */
function writeApnsEnv(patch) {
  const next = { ...readApnsEnv(), ...patch };
  const lines = [
    '# iOS 推送（APNs）配置 —— 由管理台「系统设置 → 消息推送」或 POST /api/admin/push/config 写入。',
    '# 这个文件在共享数据目录里，容器重建/重启都不会丢失；',
    '# 含 .p8 私钥（注意：Apple 只允许下载一次，丢了只能重新生成一个 Key），权限 600。',
  ];
  for (const k of APNS_ENV_KEYS) {
    const v = next[k];
    if (!v) continue;
    // 换行转义成 \n，否则多行私钥会把 env 文件写坏
    lines.push(`${k}=${String(v).replace(/\r?\n/g, '\\n')}`);
  }
  fs.writeFileSync(APNS_ENV_FILE, lines.join('\n') + '\n', { encoding: 'utf8', mode: 0o600 });
}

const _env = readApnsEnv();

// 用 let 而非 const：管理台保存后要能**不重启**生效
let KEY_ID = _env.APNS_KEY_ID || process.env.APNS_KEY_ID || '';
let TEAM_ID = _env.APNS_TEAM_ID || process.env.APNS_TEAM_ID || '';
let TOPIC = _env.APNS_TOPIC || process.env.APNS_TOPIC || '';
let KEY_P8 = _env.APNS_KEY_P8 || process.env.APNS_KEY_P8 || '';
let ENV = String(_env.APNS_ENV || process.env.APNS_ENV || 'production').toLowerCase();
if (ENV !== 'sandbox') ENV = 'production';

const enabled = () => !!(KEY_ID && TEAM_ID && TOPIC && KEY_P8);

/**
 * APNs 接入点。
 *
 * `APNS_URL` 是**测试专用**逃生门（照抄 CF_TURN_API_BASE 的做法）：
 * 测试脚本用它在本地起一个假 APNs 验证"请求长什么样、410 会不会作废令牌"，
 * 否则这些逻辑只能等真机阶段才发现写错。生产不设这个变量。
 * 允许 http:// —— 本地假 APNs 用明文 h2c，省掉自签证书。
 */
function baseUrl() {
  const override = process.env.APNS_URL;
  if (override) return String(override).replace(/\/+$/, '');
  return ENV === 'sandbox'
    ? 'https://api.sandbox.push.apple.com'
    : 'https://api.push.apple.com';
}

// ---------------------------------------------------------------------------
// Provider JWT（ES256）
//
// 【为什么不上 jsonwebtoken】它虽然能签 ES256，但要读私钥、还多一层；
// 这里只需要"签名"这一件事，node:crypto 原生支持，少一个供应链依赖。
// 【dsaEncoding: 'ieee-p1363' 不能省】ECDSA 默认吐的是 DER 编码，而 JWS 要求
// 裸的 R||S 拼接（64 字节）。写错了 APNs 只会回一个 403 InvalidProviderToken，
// 看不出是哪里的问题 —— 这是接 APNs 最常见的坑之一。
// ---------------------------------------------------------------------------

let _jwt = { token: '', exp: 0 };

function b64url(s) {
  return Buffer.from(s).toString('base64url');
}

/** 取一个可用的 provider JWT；缓存 50 分钟（Apple 要求至少每小时换一次） */
function providerToken() {
  const now = Math.floor(Date.now() / 1000);
  if (_jwt.token && now < _jwt.exp - 300) return _jwt.token;

  const data =
    b64url(JSON.stringify({ alg: 'ES256', kid: KEY_ID })) +
    '.' +
    b64url(JSON.stringify({ iss: TEAM_ID, iat: now }));

  const sig = crypto.sign('sha256', Buffer.from(data), {
    key: KEY_P8,
    dsaEncoding: 'ieee-p1363',
  });
  _jwt = { token: data + '.' + sig.toString('base64url'), exp: now + 3600 };
  return _jwt.token;
}

/** 配置变更后强制换新 JWT（改的是密钥时旧 token 已经无效） */
function invalidateToken() {
  _jwt = { token: '', exp: 0 };
}

// ---------------------------------------------------------------------------
// HTTP/2 连接复用
//
// 一次通知要发多个设备，每条都新建 TLS 连接在 iOS 上完全没必要。
// APNs 只接受 HTTP/2，所以用 node:http2；会话断了自动重建。
// ---------------------------------------------------------------------------

let _session = null;
let _sessionOrigin = '';

function sessionFor(origin) {
  if (_session && _sessionOrigin === origin && !_session.closed && !_session.destroyed) {
    return _session;
  }
  if (_session && !_session.destroyed) {
    try { _session.close(); } catch { /* 忽略 */ }
  }
  const s = http2.connect(origin);
  // 必须挂 error：连接级错误没有监听器会**直接把进程带崩**
  s.on('error', () => {});
  s.on('close', () => { if (_session === s) _session = null; });
  // unref：空闲的推送连接**不该吊住事件循环**。
  // （实测症状：单测/脚本调完 sendToUser 后进程永远不退出，因为这条
  //   keep-alive 的 h2 会话一直活着。服务端本身有 HTTP 监听撑着，
  //   所以这个改动对线上零影响，但对"能跑的测试"是必要的。）
  if (typeof s.unref === 'function') s.unref();
  _session = s;
  _sessionOrigin = origin;
  return s;
}

// ---------------------------------------------------------------------------
// 设备令牌登记
// ---------------------------------------------------------------------------

/** APNs 令牌是 32 字节 → 64 位十六进制；大小写不敏感，统一小写存 */
const TOKEN_RE = /^[0-9a-f]{64}$/i;

/**
 * 登记/更新一台设备。
 *
 * 以 **token 为唯一键**做 upsert，而不是 (user_id, token)：
 * 同一台手机换个人登录时，旧账号的推送必须立刻停掉 —— 否则会出现
 * "新用户登录后，手机还在收上一个用户的私聊通知"，这是最要命的错。
 *
 * @returns {{error?:string, device?:object}}
 */
function registerDevice({ userId, token, platform = 'ios', env, topic, deviceName }) {
  const t = String(token || '').replace(/[\s<>]/g, '').toLowerCase();
  if (!TOKEN_RE.test(t)) return { error: '设备令牌格式不对（应为 64 位十六进制字符）' };
  const uid = Number(userId);
  if (!Number.isInteger(uid) || uid <= 0) return { error: '用户无效' };

  const e = String(env || ENV).toLowerCase() === 'sandbox' ? 'sandbox' : 'production';
  const now = Date.now();

  db.prepare(`INSERT INTO push_devices
      (user_id, platform, token, env, topic, device_name, fail_count, active, created_at, updated_at)
      VALUES (?,?,?,?,?,?,0,1,?,?)
    ON CONFLICT(token) DO UPDATE SET
      user_id = excluded.user_id,
      platform = excluded.platform,
      env = excluded.env,
      topic = excluded.topic,
      device_name = excluded.device_name,
      active = 1,
      fail_count = 0,
      last_error = NULL,
      updated_at = excluded.updated_at`)
    .run(uid, String(platform || 'ios'), t, e, topic || TOPIC || null,
      deviceName ? String(deviceName).slice(0, 64) : null, now, now);

  return { device: db.prepare('SELECT * FROM push_devices WHERE token = ?').get(t) };
}

/** 注销（退出登录 / 关掉通知开关）。直接删行：留着只会在换账号时留下隐患。 */
function unregisterDevice({ userId, token }) {
  const t = String(token || '').replace(/[\s<>]/g, '').toLowerCase();
  if (!t) return { error: '缺少设备令牌' };
  const r = db.prepare('DELETE FROM push_devices WHERE token = ? AND user_id = ?').run(t, Number(userId));
  return { ok: true, removed: Number(r.changes || 0) };
}

/** 某用户的设备（令牌只回尾 8 位，管理台不需要看全量） */
function devicesOf(userId) {
  return db.prepare('SELECT * FROM push_devices WHERE user_id = ? ORDER BY updated_at DESC')
    .all(Number(userId))
    .map(maskDevice);
}

function maskDevice(d) {
  return {
    id: d.id,
    platform: d.platform,
    env: d.env,
    topic: d.topic,
    deviceName: d.device_name,
    active: !!d.active,
    failCount: d.fail_count,
    lastOkAt: d.last_ok_at,
    lastError: d.last_error,
    createdAt: d.created_at,
    updatedAt: d.updated_at,
    tokenTail: '…' + String(d.token).slice(-8),
  };
}

// ---------------------------------------------------------------------------
// 投递
// ---------------------------------------------------------------------------

/** 只有这几种 reason 说明**令牌本身作废了**，才允许把设备下线 */
const DEAD_TOKEN_REASONS = new Set([
  'BadDeviceToken',
  'Unregistered',
  'ExpiredToken',
  'DeviceTokenNotForTopic',
]);

/** 组装 aps 里除 alert 之外的部分 */
function apsOf(note) {
  const aps = {
    alert: { title: note.title || '', body: note.body || '' },
    sound: 'default',
  };
  if (note.badge !== undefined && note.badge !== null) aps.badge = Number(note.badge);
  if (note.threadId) aps['thread-id'] = String(note.threadId);
  return aps;
}

/** 单台设备投一条。永不抛异常 —— 推送失败不能让发消息的人看到报错。 */
function sendOne(dev, note) {
  return new Promise((resolve) => {
    let origin;
    try {
      origin = new URL(baseUrl()).origin;
    } catch (e) {
      return resolve({ status: 0, body: 'APNS_URL 非法: ' + e.message, reason: 'BadConfig' });
    }

    let s;
    try {
      s = sessionFor(origin);
    } catch (e) {
      return resolve({ status: 0, body: String(e.message || e), reason: 'ConnectFail' });
    }

    const apnsId = crypto.randomUUID();
    const headers = {
      ':method': 'POST',
      ':path': '/3/device/' + dev.token,
      authorization: 'bearer ' + providerToken(),
      'apns-topic': dev.topic || TOPIC,
      // push-type 必填：缺了 APNs 直接回 400 MissingTopic / 被丢弃
      'apns-push-type': 'alert',
      // 10=立即投递。这是"有人在等这条消息"，不做省电批处理
      'apns-priority': '10',
      'apns-id': apnsId,
      'apns-expiration': String(Math.floor(Date.now() / 1000) + (note.ttl || 86400)),
    };
    // collapse-id：同一个会话的多条消息在锁屏上合并成一条，
    // 否则群里刷屏会把人手机震到没电
    if (note.collapseId) headers['apns-collapse-id'] = String(note.collapseId).slice(0, 64);

    let req;
    try {
      req = s.request(headers);
    } catch (e) {
      return resolve({ status: 0, body: String(e.message || e), reason: 'ConnectFail' });
    }

    let status = 0;
    let raw = '';
    req.on('response', (h) => { status = Number(h[':status']) || 0; });
    req.setEncoding('utf8');
    req.on('data', (d) => { raw += d; });
    req.on('end', () => resolve(interpret(status, raw, apnsId)));
    req.on('error', (e) => resolve({
      status: 0, body: String(e.message || e), reason: 'ConnectFail', apnsId,
    }));
    req.end(JSON.stringify({ aps: apsOf(note), ...(note.data || {}) }));
  });
}

/** APNs 的响应体是 `{"reason":"BadDeviceToken"}`，解析出来才能对号入座 */
function interpret(status, raw, apnsId) {
  let reason = '';
  try {
    const j = JSON.parse(raw || '{}');
    reason = j.reason || '';
  } catch { /* 非 JSON（比如网关 HTML），保持空 */ }
  if (status === 200) return { ok: true, status, reason: '', apnsId };
  return { ok: false, status, reason: reason || `HTTP ${status || 'ERR'}`, apnsId, body: raw.slice(0, 200) };
}

function writeLog({ userId, deviceId, token, result, note }) {
  try {
    db.prepare(`INSERT INTO push_log
        (user_id, device_id, token_tail, ok, status, reason, title, body, apns_id, created_at)
        VALUES (?,?,?,?,?,?,?,?,?,?)`)
      .run(Number(userId), deviceId || null, String(token || '').slice(-8),
        result.ok ? 1 : 0, result.status || 0, result.reason || null,
        note.title || null, note.body || null, result.apnsId || null, Date.now());
  } catch { /* 日志写不进去不能影响投递本身 */ }
}

/**
 * 把一个通知投给某个用户的**所有有效设备**。
 *
 * 调用方（chat.js）负责判断"该不该发"（在线就不发、自己发的不发）；
 * 这里只负责"发给谁的下线设备"：env 不匹配的跳过（sandbox 令牌投到
 * production 会拿到 BadDeviceToken，照着结果把设备作废就会误伤真令牌）。
 *
 * @returns {Promise<{configured:boolean, sent:number, ok:number, skipped:number}>}
 */
async function sendToUser(userId, note) {
  if (!enabled()) return { configured: false, sent: 0, ok: 0, skipped: 0 };

  const rows = db.prepare(
    "SELECT * FROM push_devices WHERE user_id = ? AND active = 1 AND platform = 'ios'"
  ).all(Number(userId));

  const targets = rows.filter((d) => d.env === ENV);
  const skipped = rows.length - targets.length;
  if (!targets.length) return { configured: true, sent: 0, ok: 0, skipped };

  const results = await Promise.all(targets.map(async (dev) => {
    const r = await sendOne(dev, note);
    const now = Date.now();
    if (r.ok) {
      db.prepare(`UPDATE push_devices SET active = 1, fail_count = 0, last_error = NULL,
          last_ok_at = ?, updated_at = ? WHERE id = ?`).run(now, now, dev.id);
    } else if (r.status === 410 || DEAD_TOKEN_REASONS.has(r.reason)) {
      // 令牌死了：下线，往后不再投。用户下次打开 App 会重新登记。
      db.prepare(`UPDATE push_devices SET active = 0, fail_count = fail_count + 1,
          last_error = ?, updated_at = ? WHERE id = ?`).run(r.reason, now, dev.id);
    } else {
      // 5xx / 429 / 网络错误：**绝不**因此作废令牌（Apple 侧抖动很常见）
      db.prepare(`UPDATE push_devices SET fail_count = fail_count + 1,
          last_error = ?, updated_at = ? WHERE id = ?`).run(r.reason, now, dev.id);
    }
    writeLog({ userId, deviceId: dev.id, token: dev.token, result: r, note });
    return r;
  }));

  return {
    configured: true,
    sent: results.length,
    ok: results.filter((r) => r.ok).length,
    skipped,
  };
}

/** 清老日志（默认留 30 天）。推送日志量不小，不能无限长。 */
function sweep(days = 30) {
  const cut = Date.now() - Math.max(1, Number(days) || 30) * 86400000;
  const r = db.prepare('DELETE FROM push_log WHERE created_at < ?').run(cut);
  return Number(r.changes || 0);
}

// ---------------------------------------------------------------------------
// 管理台：状态 / 自检 / 热配置
// ---------------------------------------------------------------------------

function envLabel() {
  return ENV === 'sandbox' ? '开发（sandbox）' : '生产（production）';
}

/**
 * 配置自检。
 *
 * ⚠️ 诚实说明：**它不联网**，只能证明"私钥能签出 ES256 的 JWT"。
 * 真正"Apple 认不认这对密钥"必须发一条真推送才知道（可点管理台的「发测试推送」）。
 * 之所以还留着：密钥粘贴时最常见的问题是少了换行/贴了证书，
 * 这一步就能当场发现，不用等到手机上没响。
 */
function probe() {
  if (!enabled()) {
    const missing = [];
    if (!KEY_ID) missing.push('Key ID');
    if (!TEAM_ID) missing.push('Team ID');
    if (!TOPIC) missing.push('Bundle ID');
    if (!KEY_P8) missing.push('.p8 私钥');
    return { ok: false, error: '还缺：' + missing.join('、'), missing };
  }
  if (!/^[A-Z0-9]{10}$/i.test(KEY_ID)) {
    return { ok: false, error: 'Key ID 格式不对：Apple 的是 10 位字母数字（如 ABC123DEFG）' };
  }
  if (!/^[A-Z0-9]{10}$/i.test(TEAM_ID)) {
    return { ok: false, error: 'Team ID 格式不对：Apple 的是 10 位字母数字' };
  }
  if (!/-----BEGIN PRIVATE KEY-----/.test(KEY_P8)) {
    return { ok: false, error: '.p8 私钥内容不对：应以 -----BEGIN PRIVATE KEY----- 开头（别贴成 .cer 证书）' };
  }
  try {
    invalidateToken();
    const t = providerToken();
    if (t.split('.').length !== 3) return { ok: false, error: '签名结果异常' };
    return { ok: true, hint: '私钥可用（本地签名通过）。是否真正被 Apple 接受，请发一条测试推送确认。' };
  } catch (e) {
    return { ok: false, error: '私钥无法用于签名：' + String(e.message || e) };
  }
}

const _mask = (s) => {
  const v = String(s || '');
  if (!v) return '';
  if (v.length <= 8) return '*'.repeat(v.length);
  return v.slice(0, 4) + '*'.repeat(Math.min(12, v.length - 8)) + v.slice(-4);
};

function info() {
  return {
    enabled: enabled(),
    env: ENV,
    envLabel: envLabel(),
    endpoint: baseUrl(),
    topic: TOPIC,
    keyId: KEY_ID ? _mask(KEY_ID) : '',
    teamId: TEAM_ID ? _mask(TEAM_ID) : '',
    // 私钥只回"有没有、长什么样"，绝不回内容
    hasKey: !!KEY_P8,
    keyHead: KEY_P8 ? KEY_P8.split('\n')[0] : '',
    keyIdMasked: _mask(KEY_ID),
  };
}

/**
 * 只改内存、不落盘（合并语义：undefined = 保持原值）。
 * `/probe` 要用它"拿还没保存的凭据试签一次"，试完必须能原样退回去 ——
 * 否则一次"自检"就把线上配置改坏了。
 */
function applyMemory({ keyId, teamId, topic, keyP8, env }) {
  if (keyId !== undefined) KEY_ID = String(keyId || '').trim();
  if (teamId !== undefined) TEAM_ID = String(teamId || '').trim();
  if (topic !== undefined) TOPIC = String(topic || '').trim();
  if (keyP8 !== undefined) KEY_P8 = String(keyP8 || '').replace(/\r/g, '').trim();
  if (env !== undefined) ENV = String(env).toLowerCase() === 'sandbox' ? 'sandbox' : 'production';
  invalidateToken();
}

function snapshot() {
  return { keyId: KEY_ID, teamId: TEAM_ID, topic: TOPIC, keyP8: KEY_P8, env: ENV };
}

/**
 * 用一套（可能还没保存的）凭据试签一次，**不动已保存的配置**。
 * 管理台「自检」按钮走这条；保存走 applyConfig。
 */
function probeWith(cfg) {
  const prev = snapshot();
  try {
    applyMemory(cfg || {});
    return probe();
  } finally {
    applyMemory(prev);
  }
}

/**
 * 热加载一套凭据并落盘。
 * 与 TURN 同样的教训：只改内存不改文件，容器一重启就回到旧配置，
 * 表现是"昨天还能收到推送，今天突然全没了"。
 */
function applyConfig(cfg) {
  applyMemory(cfg || {});
  try {
    writeApnsEnv({
      APNS_KEY_ID: KEY_ID,
      APNS_TEAM_ID: TEAM_ID,
      APNS_TOPIC: TOPIC,
      APNS_KEY_P8: KEY_P8,
      APNS_ENV: ENV,
    });
  } catch { /* 落盘失败不影响本次热生效，但会在 info() 里暴露不出来 —— 记录即可 */ }
  return info();
}

/** 清空配置（换 App / 排障用）。设备令牌一并作废，避免拿旧主题乱投。 */
function clearConfig() {
  KEY_ID = ''; TEAM_ID = ''; TOPIC = ''; KEY_P8 = ''; ENV = 'production';
  invalidateToken();
  try { fs.rmSync(APNS_ENV_FILE, { force: true }); } catch { /* 忽略 */ }
  return info();
}
/** 统计（管理台首屏） */
function stats() {
  const total = db.prepare('SELECT COUNT(*) n FROM push_devices').get().n;
  const active = db.prepare('SELECT COUNT(*) n FROM push_devices WHERE active = 1').get().n;
  const since = Date.now() - 86400000;
  const day = db.prepare(
    'SELECT COUNT(*) n, COALESCE(SUM(ok),0) ok FROM push_log WHERE created_at >= ?'
  ).get(since);
  const failReasons = db.prepare(`SELECT reason, COUNT(*) n FROM push_log
      WHERE ok = 0 AND created_at >= ? GROUP BY reason ORDER BY n DESC LIMIT 8`).all(since);
  return {
    enabled: enabled(),
    env: ENV,
    devices: total,
    activeDevices: active,
    last24h: { sent: day.n, ok: Number(day.ok || 0), fail: day.n - Number(day.ok || 0) },
    failReasons,
  };
}

/** 最近投递记录（管理台排障用） */
function recentLogs(limit = 50) {
  const cap = Math.min(Math.max(Number(limit) || 50, 1), 200);
  return db.prepare(`SELECT l.*, u.nickname, u.username FROM push_log l
      LEFT JOIN users u ON u.id = l.user_id
      ORDER BY l.id DESC LIMIT ?`).all(cap).map((r) => ({
    id: r.id,
    userId: r.user_id,
    user: r.nickname || r.username || `#${r.user_id}`,
    ok: !!r.ok,
    status: r.status,
    reason: r.reason,
    title: r.title,
    body: r.body,
    tokenTail: r.token_tail,
    at: r.created_at,
  }));
}

// 后台巡检：每天清一次老日志（推送日志量比消息还大）
let _timer = null;
function start() {
  if (_timer) return;
  _timer = setInterval(() => {
    try { sweep(30); } catch { /* 忽略 */ }
  }, 12 * 3600 * 1000);
  if (_timer.unref) _timer.unref();
  if (enabled()) {
    const p = probe();
    console.log('[小智IM] iOS 推送已启用: env=%s topic=%s%s',
      ENV, TOPIC, p.ok ? '' : ` —— ⚠️ 配置有问题：${p.error}`);
  }
}

module.exports = {
  enabled,
  registerDevice,
  unregisterDevice,
  devicesOf,
  sendToUser,
  sweep,
  probe,
  probeWith,
  info,
  applyConfig,
  clearConfig,
  stats,
  recentLogs,
  start,
  // 供测试断言
  providerToken,
  baseUrl,
  APNS_ENV_FILE,
  TOKEN_RE,
};
