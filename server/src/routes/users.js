const router = require('express').Router();
const db = require('../db');
const { verifyToken } = require('../auth');

function uidOf(req, res) {
  const c = verifyToken(req.headers.authorization?.replace('Bearer ', ''));
  if (!c) { res.status(401).json({ error: 'unauthorized' }); return null; }
  return c.uid;
}

/// 与 routes/auth.js 里的 publicUser 保持一致（两处不同步会出现
/// 「自己看得到资料、别人看不到」的问题）
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

const COLS = 'id,username,nickname,avatar,role,created_at,signature,gender,region,birthday';

/// 转义 LIKE 的通配符：用户搜「100%」时不希望它变成「匹配任意」，
/// 搜「_」也不会匹配到所有人。
function escapeLike(s) {
  return s.replace(/[\\%_]/g, (m) => `\\${m}`);
}

router.get('/search', (req, res) => {
  const uid = uidOf(req, res); if (uid === null) return;
  const q = (req.query.q || '').trim();
  if (!q) return res.json([]);
  const like = `%${escapeLike(q)}%`;
  const rows = db.prepare(`SELECT ${COLS} FROM users
    WHERE username LIKE ? ESCAPE '\\' OR nickname LIKE ? ESCAPE '\\'
    ORDER BY id LIMIT 20`).all(like, like);
  res.json(rows);
});

// 查看用户公开资料（个人信息面板 / 好友资料卡都走这里）
router.get('/:id', (req, res) => {
  const uid = uidOf(req, res); if (uid === null) return;
  const target = Number(req.params.id);
  if (!Number.isInteger(target) || target <= 0) return res.status(400).json({ error: '用户 id 不合法' });
  const u = db.prepare(`SELECT ${COLS} FROM users WHERE id = ?`).get(target);
  if (!u) return res.status(404).json({ error: '用户不存在' });
  res.json(publicUser(u));
});

module.exports = router;
