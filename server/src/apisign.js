// 开放 API 的「签名通道」：app_id + app_secret + HMAC-SHA256
//
//   请求头：
//     X-App-Id     应用标识
//     X-Timestamp  unix **秒**
//     X-Nonce      随机串（时间窗内一次一用）
//     X-Sign       hex(HMAC-SHA256(app_secret, 待签串))
//
//   待签串（\n 分隔；顺序即协议，改了就是破坏性变更）：
//     method \n path \n query \n timestamp \n nonce \n sha256_hex(原始请求体)
//
// ── 两个偏离原草稿的地方，以及为什么 ──────────────────────────────
// ① **query 也要签进去。** 只签 path 的话，中间人可以把 `?limit=20` 改成
//    `?limit=20000`，签名照样对得上 —— "防中途改包"就成了半截。
// ② **nonce 在验签之后才落表。** 反过来的话，任何人都能耗掉 nonce 命名空间
//    （拿一堆随机 nonce 猛灌），那是给没签名的人一把写表的钥匙。
//
// 🔴 **必须用原始字节算 body 哈希**，不能用 `JSON.stringify(req.body)`：
//    重新序列化会因键序/空格差异算出不同的哈希，对接方永远签不过。
//    `express.json` 的 `verify` 已经把原始字节挂在 `req.rawBody` 上（见 index.js）。
//
// ── 和长期令牌（Bearer）什么关系 ──────────────────────────────────
// 两条通道并存、不互相污染：带 `X-App-Id` 的请求走签名，其余照旧走 Bearer。
// 签名通道解决的是"长期令牌泄露 = 可无限重放、且看不出是谁在调"。
const crypto = require('crypto');
const db = require('./db');
const config = require('./config');

/** 时间窗（秒）。太大 = 重放窗口大；太小 = 对接方机器时钟一偏就全挂。 */
const SIGN_WINDOW_SEC = 300;
/** 轮换后的旧密钥还能用多久（毫秒）。立刻失效等于"轮换一下就断线"。 */
const ROTATE_GRACE_MS = 24 * 60 * 60 * 1000;

const H = {
  appId: 'x-app-id',
  ts: 'x-timestamp',
  nonce: 'x-nonce',
  sign: 'x-sign',
};

const str = (v) => String(v == null ? '' : v).trim();

/* ==================== 密钥的静态存储 ==================== */

let _key = null;

/** 从持久化的 JWT_SECRET 派生一把固定密钥（AES-256-GCM 用）。 */
function masterKey() {
  if (_key) return _key;
  // 不另起一个"主密钥"配置项 —— 多一个要保管的机密就多一处会丢的地方，
  // 这里需要的只是"换个用途的同一把根密钥"。
  _key = crypto.scryptSync(String(config.JWT_SECRET || ''),
    'xz-api-client-secret-v1', 32);
  return _key;
}

/** 只测速 / 自测用：换根密钥后必须能重新派生，否则老客户端全废。 */
function resetMasterKeyForTest() { _key = null; }

function encryptSecret(plain) {
  const iv = crypto.randomBytes(12);
  const c = crypto.createCipheriv('aes-256-gcm', masterKey(), iv);
  const ct = Buffer.concat([c.update(String(plain), 'utf8'), c.final()]);
  return [
    'v1',
    iv.toString('base64url'),
    c.getAuthTag().toString('base64url'),
    ct.toString('base64url'),
  ].join('.');
}

function decryptSecret(packed) {
  const parts = String(packed || '').split('.');
  if (parts.length !== 4 || parts[0] !== 'v1') return '';
  try {
    const d = crypto.createDecipheriv('aes-256-gcm', masterKey(),
      Buffer.from(parts[1], 'base64url'));
    d.setAuthTag(Buffer.from(parts[2], 'base64url'));
    return Buffer.concat([d.update(Buffer.from(parts[3], 'base64url')), d.final()])
      .toString('utf8');
  } catch (_) {
    // 解密失败（换了根密钥 / 手改过库）→ 当作没有密钥。
    // 🔴 不能抛：一个坏行就会把整个开放接口打挂，而它还偏偏最难被发现。
    return '';
  }
}

/* ==================== 签名与校验 ==================== */

/**
 * 请求体的 sha256。
 *
 * 🔴 非 JSON 请求（比如 multipart 上传文件）`express.json` 不会跑 verify，
 *    `req.rawBody` 就是 undefined —— 这时按**空串**算。于是这类请求的
 *    "改包防护"只覆盖请求头，不覆盖文件内容，这点要写进对接文档。
 */
function bodyHash(req) {
  const raw = Buffer.isBuffer(req.rawBody) ? req.rawBody : Buffer.alloc(0);
  return crypto.createHash('sha256').update(raw).digest('hex');
}

function splitUrl(u) {
  const s = String(u || '/');
  const i = s.indexOf('?');
  return i < 0 ? [s, ''] : [s.slice(0, i), s.slice(i + 1)];
}

function canonicalString(o) {
  return [o.method, o.path, o.query, o.timestamp, o.nonce, o.bodyHashHex].join('\n');
}

function signWith(secret, o) {
  return crypto.createHmac('sha256', secret).update(canonicalString(o)).digest('hex');
}

/**
 * 定时安全的字符串比较。
 *
 * 两边各先哈希一次再比：长度一定相等（timingSafeEqual 长度不同会抛），
 * 也顺带避免了"长度不同就提前返回"泄露字节数。
 */
function safeEqual(a, b) {
  const ha = crypto.createHash('sha256').update(String(a)).digest();
  const hb = crypto.createHash('sha256').update(String(b)).digest();
  return crypto.timingSafeEqual(ha, hb);
}

function deny(code, error, detail) {
  return { ok: false, code, error, detail };
}

/**
 * 校验一次签名请求。返回 `{ok:true, ...}` 或 `{ok:false, code, error, detail}`。
 *
 * 校验顺序（任一不过即拒，**先拒后办**）：
 *   1. app_id 存在且启用
 *   2. 时间戳在 ±300 秒内
 *   3. 重算签名并定时安全比较
 *   4. nonce 落表（重复 → 409）
 */
function verifySignedRequest(req) {
  const appId = str(req.headers[H.appId]);
  const tsRaw = str(req.headers[H.ts]);
  const nonce = str(req.headers[H.nonce]);
  const signHex = str(req.headers[H.sign]);

  if (!appId || !tsRaw || !nonce || !signHex) {
    return deny(401, '缺少签名请求头', 'sign_missing');
  }

  // 🔴 app_id 不存在和已停用**回同一个码**：分开回等于给了外部
  //    "枚举哪些 app_id 是真的"的工具。
  const row = db.prepare('SELECT * FROM api_clients WHERE app_id = ?').get(appId);
  if (!row || !row.enabled) return deny(401, 'app_id 无效', 'app_invalid');
  if (nonce.length > 128) return deny(401, 'nonce 过长', 'bad_nonce');

  const nowSec = Math.floor(Date.now() / 1000);
  const tsSec = Number(tsRaw);
  if (!Number.isInteger(tsSec)) return deny(401, '时间戳不合法', 'bad_timestamp');
  if (Math.abs(nowSec - tsSec) > SIGN_WINDOW_SEC) {
    return deny(401, `时间戳超出 ±${SIGN_WINDOW_SEC} 秒`, 'timestamp_out_of_window');
  }

  const secret = decryptSecret(row.app_secret_enc);
  if (!secret) return deny(401, 'app_id 无效', 'app_invalid');

  const [path, query] = splitUrl(req.originalUrl);
  const o = {
    method: String(req.method || 'GET').toUpperCase(),
    path,
    query,
    timestamp: tsRaw,
    nonce,
    bodyHashHex: bodyHash(req),
  };

  // 轮换宽限期内的旧密钥也认：不然"轮换一下就断线"，没人敢轮换。
  let okSign = safeEqual(signWith(secret, o), signHex);
  if (!okSign && row.app_secret_prev_enc && (row.prev_valid_until || 0) > Date.now()) {
    const prev = decryptSecret(row.app_secret_prev_enc);
    if (prev) okSign = safeEqual(signWith(prev, o), signHex);
  }
  if (!okSign) return deny(401, '签名校验失败', 'bad_sign');

  try {
    db.prepare('INSERT INTO api_nonce (nonce, app_id, at) VALUES (?,?,?)')
      .run(nonce, appId, Date.now());
  } catch (_) {
    return deny(409, 'nonce 已被使用（重放）', 'nonce_replayed');
  }
  maybePurgeNonces();

  const u = db.prepare('SELECT id, is_bot, role FROM users WHERE id = ?').get(row.user_id);
  if (!u) return deny(401, 'app_id 无效', 'app_invalid');

  // 打使用时间戳：60 秒节流，避免高频调用把写放大（和 api_tokens 同一套做法）
  const now = Date.now();
  if (now - (row.last_used_at || 0) > 60000) {
    db.prepare('UPDATE api_clients SET last_used_at = ? WHERE id = ?').run(now, row.id);
  }

  return {
    ok: true,
    via: 'sign',
    appId: row.app_id,
    clientId: row.id,
    clientName: row.name,
    userId: u.id,
    isBot: !!u.is_bot,
    role: u.role,
    // 不在这里解析 scope：那属于 integration 的概念，避免两个模块互相 require
    scopesRaw: row.scopes || '',
  };
}

/** 请求有没有带签名通道的标志头。 */
function looksSigned(req) {
  return !!str(req.headers[H.appId]);
}

/* ==================== nonce 清理 ==================== */

let _lastPurge = 0;

/**
 * 🔴 `api_nonce` 会一路涨下去 —— 不放清理就是给自己埋一个慢性的磁盘炸弹。
 * 每分钟最多清一次（清表是扫索引的写操作，别每次请求都做）。
 */
function maybePurgeNonces() {
  const now = Date.now();
  if (now - _lastPurge < 60000) return 0;
  _lastPurge = now;
  return purgeExpiredNonces(now);
}

function purgeExpiredNonces(now = Date.now()) {
  // 🔴 保留期必须是 **2 倍时间窗 + 冗余**，不是 1 倍。
  //
  // 推导：设第一次请求落库时刻为 `at`、它签的时间戳是 `ts`。
  //   ① 第一次能通过窗口校验 ⇒ |at - ts| ≤ W ⇒ at ≥ ts - W
  //   ② 重放要能通过窗口 ⇒ now_replay ≤ ts + W
  //   由 ① 得 ts ≤ at + W，代入 ② ⇒ now_replay ≤ at + 2W
  // 所以一个 nonce 的"可被重放"时间跨度是从 `at` 起 **2W**，不是 W。
  // 只留 W 的话，把时钟往前偏 ~W 的对接方，它的 nonce 会在还能重放的时候
  // 被清掉 —— 那就等于给重放开了一道口子，而且只在"时钟偏了"这种
  // 最难复现的场景里出现。
  const cut = now - (SIGN_WINDOW_SEC * 2 + 60) * 1000;
  return db.prepare('DELETE FROM api_nonce WHERE at < ?').run(cut).changes;
}

/* ==================== 客户端（app_id / app_secret）管理 ==================== */

function publicApiClient(r) {
  if (!r) return null;
  return {
    id: r.id,
    appId: r.app_id,
    name: r.name,
    scopes: String(r.scopes || '').split(',').map((s) => s.trim()).filter(Boolean),
    userId: r.user_id,
    enabled: !!r.enabled,
    createdAt: r.created_at,
    lastUsedAt: r.last_used_at || 0,
    rotatedAt: r.rotated_at || 0,
    prevValidUntil: r.prev_valid_until || 0,
  };
}

function listApiClients() {
  return db.prepare('SELECT * FROM api_clients ORDER BY id DESC')
    .all().map(publicApiClient);
}

function findApiClient(id) {
  return db.prepare('SELECT * FROM api_clients WHERE id = ?').get(Number(id));
}

/**
 * 发一对 app_id / app_secret。
 *
 * 🔴 **明文 secret 只在这一次的返回值里出现一次。** 库里只存密文，
 *    以后列不出来、也找不回来 —— 这是"能溯源"和"泄露面"之间的取舍：
 *    找不回来最多是重新发一对，找得回来就是多一条泄露路径。
 */
function createApiClient({ name, userId, scopesCsv = '', createdBy }) {
  const appId = 'ak_' + crypto.randomBytes(8).toString('hex');
  const secret = crypto.randomBytes(24).toString('hex');
  const now = Date.now();
  const info = db.prepare(`
    INSERT INTO api_clients
      (app_id, app_secret_enc, name, scopes, user_id, enabled, created_by, created_at)
    VALUES (?,?,?,?,?,1,?,?)
  `).run(appId, encryptSecret(secret), String(name || '未命名').slice(0, 120),
    String(scopesCsv || ''), Number(userId), Number(createdBy), now);
  const row = db.prepare('SELECT * FROM api_clients WHERE id = ?').get(info.lastInsertRowid);
  return { client: publicApiClient(row), secret };
}

/** 停用 / 启用。停用是**立刻生效**的（不像密钥轮换有宽限期）。 */
function setApiClientEnabled(id, enabled) {
  const n = db.prepare('UPDATE api_clients SET enabled = ? WHERE id = ?')
    .run(enabled ? 1 : 0, Number(id)).changes;
  return { ok: n > 0, id: Number(id), enabled: !!enabled };
}

/**
 * 轮换密钥：新密钥立刻生效，旧密钥保留 [ROTATE_GRACE_MS] 让对接方有时间改。
 *
 * 为什么要有宽限期：立刻失效的话，"点一下轮换"就等于"当场把对接方踢下线"，
 * 而这事往往发生在排查故障时，于是轮换变成了没人敢按的按钮。
 */
function rotateApiClientSecret(id) {
  const row = findApiClient(id);
  if (!row) return null;
  const now = Date.now();
  const secret = crypto.randomBytes(24).toString('hex');
  db.prepare(`
    UPDATE api_clients
       SET app_secret_prev_enc = app_secret_enc,
           prev_valid_until = ?,
           app_secret_enc = ?,
           rotated_at = ?
     WHERE id = ?
  `).run(now + ROTATE_GRACE_MS, encryptSecret(secret), now, Number(id));
  const after = findApiClient(id);
  return { client: publicApiClient(after), secret };
}

function deleteApiClient(id) {
  const n = db.prepare('DELETE FROM api_clients WHERE id = ?').run(Number(id)).changes;
  return { ok: n > 0, id: Number(id) };
}

module.exports = {
  SIGN_WINDOW_SEC, ROTATE_GRACE_MS, H,
  encryptSecret, decryptSecret, resetMasterKeyForTest,
  bodyHash, splitUrl, canonicalString, signWith, safeEqual,
  verifySignedRequest, looksSigned,
  purgeExpiredNonces, maybePurgeNonces,
  listApiClients, findApiClient, createApiClient,
  setApiClientEnabled, rotateApiClientSecret, deleteApiClient,
  publicApiClient,
};
