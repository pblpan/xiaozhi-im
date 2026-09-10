// 开放集成层：机器人、API 令牌、scope 鉴权
//
// 设计目标：让「任何软件」都能对接小智 IM，而不需要改 IM 的代码。
//   1. 机器人（bot）—— 特殊用户，能被拉进群、能发言，但不能登录
//   2. API 令牌 —— 外部系统的长期凭证，带 scope 白名单，可随时吊销
//   3. 统一鉴权 —— 客户端 JWT 与外部 Token 走同一个入口，路由层无感
const crypto = require('crypto');
const db = require('./db');
const { verifyToken } = require('./auth');

/** API 令牌前缀：一眼能认出这是集成令牌，也便于鉴权分流 */
const TOKEN_PREFIX = 'xz_';

/**
 * 权限清单。外部令牌按需勾选，最小权限原则。
 * 客户端登录的 JWT 天然拥有 '*'（真人用户不受限）。
 */
const SCOPES = {
  'message:send': '发送消息',
  'message:read': '读取消息',
  'conversation:read': '读取会话与成员',
  'user:read': '读取用户',
  'file:upload': '上传文件',
  'bot:manage': '管理机器人与 Webhook',
};

function randomHex(bytes) {
  return crypto.randomBytes(bytes).toString('hex');
}

function newApiToken() {
  return TOKEN_PREFIX + randomHex(24);
}

function newSecret() {
  return randomHex(24);
}

function newHookToken() {
  return randomHex(16);
}

/** scopes 存库是逗号分隔字符串，出口统一转数组 */
function parseScopes(raw) {
  if (!raw) return [];
  return String(raw).split(',').map((s) => s.trim()).filter(Boolean);
}

/** 过滤掉不认识的名字，避免管理员手抖写进脏数据 */
function sanitizeScopes(list) {
  const arr = Array.isArray(list) ? list : parseScopes(list);
  return [...new Set(arr.map((s) => String(s).trim()).filter((s) => SCOPES[s]))];
}

function hasScope(auth, scope) {
  if (!auth || !auth.ok) return false;
  if (auth.scopes.includes('*')) return true;
  return auth.scopes.includes(scope);
}

/* ==================== 机器人 ==================== */

/**
 * 建一个机器人。机器人是 users 表里的普通行，只是 is_bot=1。
 * 这样群成员、会话成员、消息发送者的所有既有逻辑都能直接复用，不需要开新分支。
 * password_hash 固定为 '!'，verifyPassword 解析失败 → 永远登录不进来。
 */
function createBot({ name, ownerId, avatar }) {
  const nick = String(name || '').trim().slice(0, 32);
  if (!nick) throw new Error('机器人名称不能为空');
  let username;
  for (let i = 0; i < 5; i++) {
    username = 'bot_' + randomHex(4);
    if (!db.prepare('SELECT id FROM users WHERE username = ?').get(username)) break;
    username = null;
  }
  if (!username) throw new Error('生成机器人账号失败，请重试');
  const info = db.prepare(`INSERT INTO users
    (username, password_hash, nickname, avatar, role, created_at, is_bot, bot_owner_id)
    VALUES (?,?,?,?,?,?,1,?)`)
    .run(username, '!', nick, avatar || null, 'user', Date.now(), ownerId);
  return publicBot(db.prepare('SELECT * FROM users WHERE id = ?').get(info.lastInsertRowid));
}

function publicBot(u) {
  if (!u) return null;
  return {
    id: u.id,
    username: u.username,
    nickname: u.nickname,
    avatar: u.avatar,
    is_bot: !!u.is_bot,
    bot_owner_id: u.bot_owner_id || null,
    created_at: u.created_at,
  };
}

function listBots() {
  return db.prepare('SELECT * FROM users WHERE is_bot = 1 ORDER BY id ASC').all().map(publicBot);
}

function getBot(id) {
  const u = db.prepare('SELECT * FROM users WHERE id = ? AND is_bot = 1').get(Number(id));
  return u ? publicBot(u) : null;
}

/** 删除机器人：连同它的令牌、入站 Webhook、会话成员关系一起清掉 */
function deleteBot(id) {
  const bot = db.prepare('SELECT id FROM users WHERE id = ? AND is_bot = 1').get(Number(id));
  if (!bot) throw new Error('机器人不存在');
  const hooks = db.prepare('SELECT id FROM incoming_hooks WHERE bot_id = ?').all(bot.id).map((r) => r.id);
  for (const hid of hooks) {
    db.prepare('DELETE FROM webhook_deliveries WHERE hook_id = ?').run(hid);
  }
  db.prepare('DELETE FROM incoming_hooks WHERE bot_id = ?').run(bot.id);
  db.prepare('DELETE FROM api_tokens WHERE user_id = ?').run(bot.id);
  db.prepare('DELETE FROM conversation_members WHERE user_id = ?').run(bot.id);
  db.prepare('DELETE FROM group_members WHERE user_id = ?').run(bot.id);
  db.prepare('DELETE FROM users WHERE id = ?').run(bot.id);
  return { ok: true, id: bot.id };
}

/** 把机器人加进会话（建入站 Webhook 时自动调用，避免"推不进去"） */
function ensureBotInConversation(botId, conversationId) {
  const conv = db.prepare('SELECT id FROM conversations WHERE id = ?').get(Number(conversationId));
  if (!conv) throw new Error('会话不存在');
  db.prepare('INSERT OR IGNORE INTO conversation_members (conversation_id, user_id) VALUES (?,?)')
    .run(conv.id, Number(botId));
  // 群聊还要同步 group_members，否则群成员列表看不到机器人
  const g = db.prepare('SELECT id FROM groups WHERE conversation_id = ?').get(conv.id);
  if (g) {
    db.prepare('INSERT OR IGNORE INTO group_members (group_id, user_id, role, joined_at) VALUES (?,?,?,?)')
      .run(g.id, Number(botId), 'member', Date.now());
  }
  return conv.id;
}

/* ==================== API 令牌 ==================== */

function createApiToken({ name, userId, scopes, expiresAt, createdBy }) {
  const label = String(name || '').trim().slice(0, 64);
  if (!label) throw new Error('令牌名称不能为空');
  const uid = Number(userId);
  const u = db.prepare('SELECT id, is_bot FROM users WHERE id = ?').get(uid);
  if (!u) throw new Error('指定的身份用户不存在');
  const sc = sanitizeScopes(scopes);
  if (!sc.length) throw new Error('至少勾选一个权限');
  const token = newApiToken();
  const info = db.prepare(`INSERT INTO api_tokens
    (name, token, scopes, user_id, created_by, expires_at, created_at)
    VALUES (?,?,?,?,?,?,?)`)
    .run(label, token, sc.join(','), uid, Number(createdBy) || uid,
      Number(expiresAt) || 0, Date.now());
  return getApiToken(info.lastInsertRowid, { reveal: true });
}

/** reveal=true 才返回明文 token；列表接口默认打码，避免后台截图泄露 */
function getApiToken(id, { reveal = false } = {}) {
  const r = db.prepare(`SELECT t.*, u.nickname AS user_name, u.is_bot AS user_is_bot
    FROM api_tokens t LEFT JOIN users u ON u.id = t.user_id WHERE t.id = ?`).get(Number(id));
  if (!r) return null;
  return shapeToken(r, reveal);
}

function shapeToken(r, reveal) {
  return {
    id: r.id,
    name: r.name,
    token: reveal ? r.token : maskToken(r.token),
    scopes: parseScopes(r.scopes),
    user_id: r.user_id,
    user_name: r.user_name || null,
    user_is_bot: !!r.user_is_bot,
    created_by: r.created_by,
    last_used_at: r.last_used_at || 0,
    expires_at: r.expires_at || 0,
    revoked: !!r.revoked,
    created_at: r.created_at,
  };
}

function maskToken(t) {
  const s = String(t || '');
  if (s.length <= 12) return s;
  return s.slice(0, 7) + '…' + s.slice(-4);
}

function listApiTokens() {
  return db.prepare(`SELECT t.*, u.nickname AS user_name, u.is_bot AS user_is_bot
    FROM api_tokens t LEFT JOIN users u ON u.id = t.user_id
    ORDER BY t.id DESC`).all().map((r) => shapeToken(r, false));
}

function revokeApiToken(id, revoked = true) {
  const r = db.prepare('SELECT id FROM api_tokens WHERE id = ?').get(Number(id));
  if (!r) throw new Error('令牌不存在');
  db.prepare('UPDATE api_tokens SET revoked = ? WHERE id = ?').run(revoked ? 1 : 0, r.id);
  return { ok: true, id: r.id, revoked: !!revoked };
}

function deleteApiToken(id) {
  db.prepare('DELETE FROM api_tokens WHERE id = ?').run(Number(id));
  return { ok: true, id: Number(id) };
}

/** 令牌鉴权：吊销 / 过期 / 身份丢失 全部按 401 处理，不泄露具体原因给外部 */
function authByApiToken(raw) {
  const row = db.prepare('SELECT * FROM api_tokens WHERE token = ?').get(raw);
  if (!row) return { ok: false, code: 401, error: 'invalid token' };
  if (row.revoked) return { ok: false, code: 401, error: 'token revoked' };
  if (row.expires_at && row.expires_at < Date.now()) {
    return { ok: false, code: 401, error: 'token expired' };
  }
  const u = db.prepare('SELECT id, is_bot, role FROM users WHERE id = ?').get(row.user_id);
  if (!u) return { ok: false, code: 401, error: 'token owner not found' };

  // 打使用时间戳：60 秒节流，避免高频调用把写放大
  const now = Date.now();
  if (now - (row.last_used_at || 0) > 60000) {
    db.prepare('UPDATE api_tokens SET last_used_at = ? WHERE id = ?').run(now, row.id);
  }

  return {
    ok: true,
    via: 'token',
    tokenId: row.id,
    tokenName: row.name,
    userId: u.id,
    isBot: !!u.is_bot,
    role: u.role,
    scopes: parseScopes(row.scopes),
  };
}

/**
 * 统一鉴权入口：同时接受客户端 JWT 和外部 API 令牌。
 * 返回 { ok:true, userId, scopes, ... } 或 { ok:false, code, error }。
 */
function authenticate(req) {
  const raw = String(req.headers?.authorization || '')
    .replace(/^Bearer\s+/i, '').trim();
  if (!raw) return { ok: false, code: 401, error: 'missing credentials' };

  if (raw.startsWith(TOKEN_PREFIX)) return authByApiToken(raw);

  const claims = verifyToken(raw);
  if (!claims) return { ok: false, code: 401, error: 'unauthorized' };
  const u = db.prepare('SELECT id, is_bot, role FROM users WHERE id = ?').get(claims.uid);
  if (!u) return { ok: false, code: 401, error: 'unauthorized' };
  return {
    ok: true,
    via: 'jwt',
    userId: u.id,
    isBot: !!u.is_bot,
    role: u.role,
    scopes: ['*'],
  };
}

/** 写响应并返回 null 的便捷函数，风格与既有路由的 uidOf 保持一致 */
function requireAuth(req, res) {
  const auth = authenticate(req);
  if (!auth.ok) { res.status(auth.code || 401).json({ error: auth.error }); return null; }
  return auth;
}

function requireScope(req, res, scope) {
  const auth = requireAuth(req, res);
  if (!auth) return null;
  if (!hasScope(auth, scope)) {
    res.status(403).json({ error: `权限不足，需要 ${scope}` });
    return null;
  }
  return auth;
}

module.exports = {
  TOKEN_PREFIX, SCOPES,
  randomHex, newApiToken, newSecret, newHookToken,
  parseScopes, sanitizeScopes, hasScope,
  createBot, listBots, getBot, deleteBot, ensureBotInConversation, publicBot,
  createApiToken, getApiToken, listApiTokens, revokeApiToken, deleteApiToken,
  authenticate, requireAuth, requireScope,
};
