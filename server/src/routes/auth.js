const router = require('express').Router();
const db = require('../db');
const hub = require('../hub');
const { hashPassword, verifyPassword, signToken, verifyToken } = require('../auth');
const settings = require('../settings');
const tokens = require('../tokens');
const { RateLimiter, ipOf } = require('../ratelimit');

// ---------------------------------------------------------------------------
// 登录/注册限流（2026-10-03 补，审计 P1-1）
//
// 🔴 为什么登录必须限流（它同时是爆破面和 DoS 面）
//   1. 爆破：登录是全系统唯一"可以无限次重试"的写接口，弱口令能被慢慢磨出来。
//   2. DoS：密码校验走 `crypto.scryptSync` —— **同步、CPU 密集**，
//      单次约几十到上百毫秒，而且**它不让出事件循环**。
//      所以几十个并发登录请求就能把整个 Node 进程占死，
//      表现是**所有接口一起超时**（连 /api/health 都响应不了）——
//      攻击者不需要账号，用一个脚本就能让服务器"看起来宕机"。
//   setup.js 早就有限流了（防脚本刷设置密码），唯独登录这个最该有的没有。
//
// 两条维度，缺一不可：
//   · IP 维度 → 挡"一个来源换着账号刷"
//   · 账号维度 → 挡"多个来源盯着同一个账号爆破"（分布式也躲不过）
// 只做 IP 维度的话，换个 IP 就能继续猜；只做账号维度的话，
// 攻击者随便填个不存在的账号名就能把受害者锁在门外（DoS 变成互相伤害）。
//
// 阈值为什么这么定：
//   · 登录 10 次 / 15 分钟：正常人一天也就登录几次（换设备、重连）；
//     连续输错 10 次基本就是记错密码或有人在猜。给到 10 次是留足余量。
//   · 账号锁定 5 次 / 15 分钟：比 IP 维度更严。5 次错密码就该让本人
//     停手并走"忘记密码"了（自助注册开着的话重置更简单）。
//   · 注册 5 次 / 小时：注册一次只多一条用户记录，危害远小于登录爆破，
//     但批量灌账号是刷数据的常见手段，所以也要有。
// 判据：成功登录**清零**该账号的失败计数（本人输对了就不该再被锁），
// 但不清 IP 计数（不然攻击者拿一个账号成功一次就能重置自己的爆破额度）。
// ---------------------------------------------------------------------------
const LOGIN_WINDOW_MS = 15 * 60 * 1000;
const LOGIN_MAX_PER_IP = 10;
const LOGIN_MAX_PER_ACCOUNT = 5;
const REGISTER_WINDOW_MS = 60 * 60 * 1000;
const REGISTER_MAX = 5;

const loginByIp = new RateLimiter({ windowMs: LOGIN_WINDOW_MS, max: LOGIN_MAX_PER_IP });
const loginByAccount = new RateLimiter({ windowMs: LOGIN_WINDOW_MS, max: LOGIN_MAX_PER_ACCOUNT });
const registerByIp = new RateLimiter({ windowMs: REGISTER_WINDOW_MS, max: REGISTER_MAX });

/** 账号维度的键：加盐哈希，避免明文账号名留在内存 Map 里 */
function accountKey(username) {
  return require('crypto').createHash('sha256')
    .update(String(username || '').toLowerCase())
    .digest('base64url');
}

/** 429 的统一口径。附带 Retry-After，方便客户端自己退避 */
function tooMany(res, seconds, msg) {
  res.set('Retry-After', String(seconds));
  return res.status(429).json({ error: msg, retryAfter: seconds });
}

function uidOf(req, res) {
  const c = verifyToken(req.headers.authorization?.replace('Bearer ', ''));
  if (!c) { res.status(401).json({ error: 'unauthorized' }); return null; }
  return c.uid;
}

/// 对外暴露的用户字段。
/// 改动这里务必同步 users.js 里的同名函数 —— 两处不一致会出现
/// 「自己看得到签名、别人看不到」这种诡异现象。
function publicUser(u) {
  return {
    id: u.id,
    username: u.username,
    nickname: u.nickname,
    avatar: u.avatar,
    role: u.role,
    created_at: u.created_at,
    signature: u.signature || null,
    gender: u.gender || null,
    region: u.region || null,
    birthday: u.birthday || null,
  };
}

// ============================================================
// 资料字段校验
// ============================================================
const GENDERS = ['', 'male', 'female', 'other'];

// 用码点数而不是 String.length 计长度：一个 emoji 在 JS 里 length=2，
// 按 length 限制会让「昵称最多 24 字」对 emoji 用户凭空砍半。
const len = (s) => [...s].length;

function validBirthday(s) {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(s)) return false;
  const [y, m, d] = s.split('-').map(Number);
  const dt = new Date(Date.UTC(y, m - 1, d));
  // 用 Date 回读校验：能挡住 2026-02-31 这种「格式对但日子不存在」的输入
  return dt.getUTCFullYear() === y && dt.getUTCMonth() === m - 1 && dt.getUTCDate() === d;
}

/**
 * 校验并生成 UPDATE 补丁。
 * 语义：字段「没传」= 不改；「传空串」= 清空。所以用 hasOwnProperty 判断，
 * 不能用 `if (body.signature)` —— 那样用户永远清不掉签名。
 */
function buildPatch(body) {
  const patch = {};
  const has = (k) => Object.prototype.hasOwnProperty.call(body, k);
  const str = (v) => (v == null ? '' : String(v)).trim();

  if (has('nickname')) {
    const v = str(body.nickname);
    if (!v) return { error: '昵称不能为空' };
    if (len(v) > 24) return { error: '昵称最多 24 个字' };
    patch.nickname = v;
  }
  if (has('signature')) {
    const v = str(body.signature);
    if (len(v) > 60) return { error: '个性签名最多 60 个字' };
    patch.signature = v;
  }
  if (has('region')) {
    const v = str(body.region);
    if (len(v) > 20) return { error: '地区最多 20 个字' };
    patch.region = v;
  }
  if (has('avatar')) {
    const v = str(body.avatar);
    if (v) {
      // 只收站内相对路径或 http(s) 绝对地址：头像地址会被客户端直接塞进
      // Image.network，放任 data:/javascript: 是隐患
      if (!/^\/files\/[\w.\-]+$/.test(v) && !/^https?:\/\//i.test(v)) {
        return { error: '头像地址不合法' };
      }
      if (v.length > 255) return { error: '头像地址过长' };
    }
    patch.avatar = v;
  }
  if (has('gender')) {
    const v = str(body.gender).toLowerCase();
    if (!GENDERS.includes(v)) return { error: '性别取值不合法' };
    patch.gender = v;
  }
  if (has('birthday')) {
    const v = str(body.birthday);
    if (v && !validBirthday(v)) return { error: '生日格式应为 YYYY-MM-DD' };
    patch.birthday = v;
  }

  if (!Object.keys(patch).length) return { error: '没有需要更新的字段' };
  return { patch };
}

/// 资料变更后通知「能看见我的人」：好友 + 共同群成员。
/// 不广播的话，对方要等下一次拉会话列表才看到新昵称/新头像。
function broadcastProfile(uid, user) {
  const ids = new Set();
  for (const r of db.prepare("SELECT friend_id AS id FROM friendships WHERE user_id=? AND status='accepted'").all(uid)) ids.add(r.id);
  for (const r of db.prepare(`SELECT DISTINCT gm2.user_id AS id FROM group_members gm1
      JOIN group_members gm2 ON gm2.group_id = gm1.group_id
      WHERE gm1.user_id = ?`).all(uid)) ids.add(r.id);
  ids.delete(uid);
  const frame = {
    type: 'user:update',
    user: {
      id: uid, nickname: user.nickname, avatar: user.avatar,
      signature: user.signature, gender: user.gender,
      region: user.region, birthday: user.birthday,
    },
  };
  for (const id of ids) hub.broadcastToUser(id, frame);
}

// ============================================================
// 路由
// ============================================================
router.post('/register', (req, res) => {
  // 工作模式关闭自助注册：账号由管理员按工号录入（POST /api/orgs/:id/members），
  // 放开注册会让"工号=账号、初始密码=工号"的账号纪律形同虚设
  if (settings.get('friendMode') === 'work') {
    return res.status(403).json({ error: '工作模式下由管理员统一添加员工账号' });
  }
  const { username, password, nickname } = req.body || {};
  if (!username || !password) return res.status(400).json({ error: '请填写账号和密码' });
  if (username.length < 3) return res.status(400).json({ error: '账号至少需要 3 个字符' });
  // 注册限流：批量灌账号是刷数据的常见手段（审计 P1-1 顺带覆盖）。
  if (registerByIp.isBlocked(ipOf(req))) {
    return tooMany(res, Math.ceil(REGISTER_WINDOW_MS / 1000), '注册过于频繁，请稍后再试');
  }
  registerByIp.allow(ipOf(req));
  if (db.prepare('SELECT id FROM users WHERE username = ?').get(username)) return res.status(409).json({ error: '该账号已被注册' });
  const info = db.prepare('INSERT INTO users (username, password_hash, nickname, role, created_at) VALUES (?,?,?,?,?)')
    .run(username, hashPassword(password), nickname || username, 'user', Date.now());
  const user = db.prepare('SELECT * FROM users WHERE id = ?').get(info.lastInsertRowid);
  res.json({ ...tokens.issuePair(user), user: publicUser(user) });
});

// 换新 access/refresh（客户端支持刷新后调它）
// 🔴 旧客户端不会调这个端点 —— 它是**纯新增**，用来平滑引入短时效令牌。
//    不配刷新逻辑的老版本继续用 30 天的 token，不会被踢（见 src/tokens.js 顶部说明）。
router.post('/refresh', (req, res) => {
  // 刷新端点也要限流：它接受一个不可撤销的凭据反复换令牌，
  // 不限流就成了"无限续期"的漏洞（拿到 refresh 就能一直保持登录态）。
  if (loginByIp.isBlocked(ipOf(req))) {
    return tooMany(res, Math.ceil(LOGIN_WINDOW_MS / 1000), '刷新过于频繁，请稍后再试');
  }
  loginByIp.allow(ipOf(req));

  const r = tokens.rotate((req.body || {}).refreshToken);
  if (r.error) return res.status(r.status).json({ error: r.error });
  res.json({ ...r.pair, user: publicUser(r.user) });
});

router.post('/login', (req, res) => {
  const ip = ipOf(req);
  const username = String((req.body || {}).username || '').trim();
  const akey = accountKey(username);

  // 先查后记：**已经超限的请求直接拒，不再走 scrypt**。
  // 顺序很关键 —— 如果先 allow 再校验，超限的那次仍然要付一次 scrypt 的
  // CPU 代价，限流就挡不住 DoS 了。
  if (loginByIp.isBlocked(ip)) {
    return tooMany(res, Math.ceil(LOGIN_WINDOW_MS / 1000), '尝试过于频繁，请过几分钟再试');
  }
  if (username && loginByAccount.isBlocked(akey)) {
    // 账号维度超限：可能是本人记错密码反复试，也可能是别人在爆破。
    // 两种情况的处理是一样的 —— 都不放行，且**不说"这个账号存在"**
    // （那句话本身就是个信息泄露：能被用来枚举账号）。
    return tooMany(res, Math.ceil(LOGIN_WINDOW_MS / 1000), '该账号尝试过于频繁，请稍后再试');
  }

  loginByIp.allow(ip);
  if (username) loginByAccount.allow(akey);

  const user = db.prepare('SELECT * FROM users WHERE username = ?').get(username);
  if (!user || !verifyPassword((req.body || {}).password || '', user.password_hash)) {
    // 中文文案：客户端虽然有错误映射层（core/errors.dart），服务端直接给中文
    // 双保险 —— 旧版本 App / 管理台 / 第三方调用看到的也是人话。
    // 刻意不说"账号不存在"还是"密码错"：那句本身就是账号枚举的敲门砖。
    return res.status(401).json({ error: '账号或密码错误' });
  }
  // 登上了：清掉该账号的失败计数（本人输对了就不该再被锁）。
  // IP 计数**故意不清** —— 否则攻击者用一个能登的账号成功一次，
  // 就能把自己这一轮的爆破额度重置掉。
  loginByAccount.clearFails(akey);
  // token 字段保持原样（access，30 天）—— 旧客户端靠它，行为不能变；
  // refreshToken 是新增字段，旧客户端会忽略它，新客户端用它续期。
  res.json({ ...tokens.issuePair(user), user: publicUser(user) });
});

router.get('/me', (req, res) => {
  const uid = uidOf(req, res); if (uid === null) return;
  const user = db.prepare('SELECT * FROM users WHERE id = ?').get(uid);
  if (!user) return res.status(401).json({ error: 'unauthorized' });
  res.json({ user: publicUser(user) });
});

// 更新个人资料：昵称 / 头像 / 签名 / 性别 / 地区 / 生日
// 账号（username）、ID、角色不可改 —— 这里只认白名单字段，其余静默忽略
router.put('/profile', (req, res) => {
  const uid = uidOf(req, res); if (uid === null) return;
  const r = buildPatch(req.body || {});
  if (r.error) return res.status(400).json({ error: r.error });

  // 列名全部来自 buildPatch 里的硬编码常量，不拼接用户输入
  const keys = Object.keys(r.patch);
  db.prepare(`UPDATE users SET ${keys.map((k) => `${k} = ?`).join(', ')} WHERE id = ?`)
    .run(...keys.map((k) => r.patch[k]), uid);

  const user = db.prepare('SELECT * FROM users WHERE id = ?').get(uid);
  broadcastProfile(uid, user);
  res.json({ user: publicUser(user) });
});

// ============================================================
// 修改密码
// ============================================================
// 安全边界说明：token 是无状态 JWT（没有 session 表），改密后旧 token
// 在剩余有效期内（最长 30 天）依然可用 —— 做「改密即全端下线」需要
// 给十几个路由的 uidOf 加版本比对或引入统一鉴权中间件，本版本不做，
// 局域网场景下风险可接受。当前会话 token 继续有效正是用户期望的行为：
// 改完密码不会被自己踢出去，其他端下次登录才用新密码。
router.post('/password', (req, res) => {
  const uid = uidOf(req, res); if (uid === null) return;
  const { oldPassword, newPassword } = req.body || {};
  const user = db.prepare('SELECT * FROM users WHERE id = ?').get(uid);
  if (!user) return res.status(401).json({ error: 'unauthorized' });

  // 旧密码必须本人确认 —— 防止设备被他人顺手改掉密码
  if (!verifyPassword(String(oldPassword ?? ''), user.password_hash)) {
    return res.status(401).json({ error: '旧密码不正确' });
  }
  const np = String(newPassword ?? '');
  // 注册接口没设密码强度底线（历史包袱），但「主动改密」是安全动作，
  // 这里给出 6 位下限是合理增量；不回填到注册是为了不破坏既有账号习惯
  if (np.length < 6) return res.status(400).json({ error: '新密码至少 6 位' });
  if (np.length > 64) return res.status(400).json({ error: '新密码最长 64 位' });
  if (np === String(oldPassword ?? '')) {
    return res.status(400).json({ error: '新密码不能与旧密码相同' });
  }
  db.prepare('UPDATE users SET password_hash = ? WHERE id = ?').run(hashPassword(np), uid);
  // 改密码后**作废该用户全部 refresh token**（2026-10-03 补，审计 P2）。
  // 这是双令牌机制最实际的安全收益：改密码的本意是"把拿到旧凭证的人挡在外面"，
  // 不作废 refresh 的话，对方手上的 refresh 还能继续换出新令牌 —— 改密码等于白改。
  // access token 因为无状态做不到即时作废（最多再撑到过期，见 src/tokens.js）。
  tokens.revokeAll(uid);
  res.json({ ok: true });
});

module.exports = router;
