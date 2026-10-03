/**
 * 双令牌签发（access + refresh）—— 2026-10-03 补，审计 P2
 *
 * ─────────────────────────────────────────────────────────────────
 * 【原来是什么问题】
 *   signToken 的 expiresIn 是 **30 天**，且**没有服务端记录**：
 *   令牌一旦签发就无法作废。这意味着：
 *     · 令牌泄露（抓包、日志、备份文件里）→ **30 天内任何人都能用它登进这个账号**；
 *     · 用户改完密码，旧令牌**照样能用** —— 改密码���"把小偷锁在外面"的直觉是假的；
 *     · 管理员删了账号 / 禁用了账号，已签发的令牌仍能继续访问到过期。
 *
 * ─────────────────────────────────────────────────────────────────
 * 【现在的设计】
 *   access token  短时效（默认 2 小时），无状态，**不落库**。
 *     —— 泄露窗口从 30 天缩到 2 小时，这是最主要的收益。
 *   refresh token 长时效（默认 30 天），**哈希后落库**，可作废。
 *     —— 它才是"长期凭证"，所以必须能撤销：改密码 / 登出 / 删号时一并清掉。
 *   两者都用 JWT 签发，但 refresh 带 `kind: 'refresh'`，
 *   并且**校验时确认它确实存在于库里**（只靠 JWT 签名是不够的：
 *   库里已作废的 token 签名依然有效，签名验证会放行）。
 *
 * ─────────────────────────────────────────────────────────────────
 * 【为什么不把 access 也落库】
 *   落库就等于每次鉴权都要查一次表，而鉴权在每个接口、每次 WS 心跳都要做。
 *   access 的价值就在于"不查库也能验"；用短时效把它的风险窗口压到可接受，
 *   撤销能力则由 refresh token 承担（作废 refresh → 最多 2 小时内旧 access 失效）。
 *   这是业界通行取舍，不是偷懒。
 *
 * ─────────────────────────────────────────────────────────────────
 * 【向后兼容：绝不能让已装的客户端掉线】
 *   客户端 0.21.0+59 **没有刷新逻辑**（收到 401 直接跳登录页），
 *   而且**改服务端不能要求用户重装**（那要等龙哥发版）。
 *   所以这里刻意做了两件事：
 *     1. `signToken` 的默认行为与原来**完全一致**（access，30 天），
 *        登录/注册的响应里**同时**带上 refreshToken 字段；
 *     2. 新增的 /auth/refresh 端点是**纯新增**，旧客户端不会调它。
 *   ⇒ 旧客户端继续正常用 30 天的 access，不受影响；
 *     新客户端用上 refreshToken 后，自动获得"短时效 + 可撤销"的好处。
 *   真正的切换要等客户端适配后再把 ACCESS_TTL 调短。
 */
const crypto = require('crypto');
const { signToken, verifyToken } = require('./auth');
const db = require('./db');

/** access 有效期。⚠️ 默认仍是 30 天 —— 为兼容已装客户端，等客户端支持刷新后再调短。 */
const ACCESS_TTL = process.env.ACCESS_TTL || '30d';
/** refresh 有效期 */
const REFRESH_TTL_DAYS = Number(process.env.REFRESH_TTL_DAYS || 30);
/** refresh 在库里存哈希，不存明文：库里被拖走也无法直接拿去用 */
const REFRESH_TTL_MS = REFRESH_TTL_DAYS * 24 * 3600 * 1000;

function hashToken(t) {
  return crypto.createHash('sha256').update(String(t)).digest('hex');
}

/**
 * 签发一对令牌。
 * @param {{id:number, role:string}} user
 * @returns {{token:string, refreshToken:string, expiresIn:number}}
 */
function issuePair(user) {
  const token = signToken({ uid: user.id, role: user.role }); // 仍是 access，兼容旧客户端
  const refreshToken = crypto.randomBytes(32).toString('base64url');
  db.prepare('INSERT INTO refresh_tokens (user_id, token_hash, expires_at, created_at) VALUES (?,?,?,?)')
    .run(user.id, hashToken(refreshToken), Date.now() + REFRESH_TTL_MS, Date.now());
  // 顺手清掉这个用户已过期的 refresh，避免表无限增长
  db.prepare('DELETE FROM refresh_tokens WHERE user_id=? AND expires_at < ?').run(user.id, Date.now());
  return { token, refreshToken, expiresIn: Math.floor(REFRESH_TTL_MS / 1000) };
}

/**
 * 用 refresh token 换一对新的。
 * ⚠️ 关键：校验通过后**立即作废旧的**（轮换，rotate）。
 * 泄露场景下攻击者最多能用一次；如果不做轮换，偷到的 refresh 就能一直续命，
 * 直到 30 天后自然过期 —— 那就等于没有刷新机制。
 */
function rotate(refreshToken) {
  if (!refreshToken) return { error: 'refreshToken 缺失', status: 400 };
  const h = hashToken(refreshToken);
  const row = db.prepare('SELECT * FROM refresh_tokens WHERE token_hash=?').get(h);
  if (!row) return { error: 'refreshToken 无效', status: 401 };
  if (row.expires_at < Date.now()) {
    db.prepare('DELETE FROM refresh_tokens WHERE token_hash=?').run(h);
    return { error: 'refreshToken 已过期，请重新登录', status: 401 };
  }
  const user = db.prepare('SELECT id,role,username,nickname,avatar FROM users WHERE id=?').get(row.user_id);
  if (!user) {
    // 账号已被删除：令牌自然也该作废
    db.prepare('DELETE FROM refresh_tokens WHERE user_id=?').run(row.user_id);
    return { error: '账号不存在', status: 401 };
  }
  // 轮换：旧的立即作废
  db.prepare('DELETE FROM refresh_tokens WHERE token_hash=?').run(h);
  return { user, pair: issuePair(user) };
}

/** 作废某用户全部 refresh（改密码 / 登出 / 删号时调用） */
function revokeAll(userId) {
  try {
    db.prepare('DELETE FROM refresh_tokens WHERE user_id=?').run(userId);
  } catch (_) { /* 表还没建（首次部署前）就算了，不该因此报错 */ }
}

/** 定期清过期 refresh */
function sweep() {
  try {
    db.prepare('DELETE FROM refresh_tokens WHERE expires_at < ?').run(Date.now());
  } catch (_) { /* 同上 */ }
}

module.exports = { issuePair, rotate, revokeAll, sweep, ACCESS_TTL, REFRESH_TTL_DAYS };
