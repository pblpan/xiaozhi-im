const router = require('express').Router();
const db = require('../db');
const hub = require('../hub');
const { hashPassword, verifyPassword, signToken, verifyToken } = require('../auth');

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
  const { username, password, nickname } = req.body || {};
  if (!username || !password) return res.status(400).json({ error: 'username & password required' });
  if (username.length < 3) return res.status(400).json({ error: 'username too short' });
  if (db.prepare('SELECT id FROM users WHERE username = ?').get(username)) return res.status(409).json({ error: 'username taken' });
  const info = db.prepare('INSERT INTO users (username, password_hash, nickname, role, created_at) VALUES (?,?,?,?,?)')
    .run(username, hashPassword(password), nickname || username, 'user', Date.now());
  const user = db.prepare('SELECT * FROM users WHERE id = ?').get(info.lastInsertRowid);
  res.json({ token: signToken({ uid: user.id, role: user.role }), user: publicUser(user) });
});

router.post('/login', (req, res) => {
  const { username, password } = req.body || {};
  const user = db.prepare('SELECT * FROM users WHERE username = ?').get(username);
  if (!user || !verifyPassword(password || '', user.password_hash)) return res.status(401).json({ error: 'invalid credentials' });
  res.json({ token: signToken({ uid: user.id, role: user.role }), user: publicUser(user) });
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

module.exports = router;
