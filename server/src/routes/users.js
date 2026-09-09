const router = require('express').Router();
const db = require('../db');
const { verifyToken } = require('../auth');

function uidOf(req, res) {
  const c = verifyToken(req.headers.authorization?.replace('Bearer ', ''));
  if (!c) { res.status(401).json({ error: 'unauthorized' }); return null; }
  return c.uid;
}
function publicUser(u) {
  return { id: u.id, username: u.username, nickname: u.nickname, avatar: u.avatar, role: u.role, created_at: u.created_at };
}

router.get('/search', (req, res) => {
  const uid = uidOf(req, res); if (uid === null) return;
  const q = (req.query.q || '').trim();
  if (!q) return res.json([]);
  const rows = db.prepare('SELECT id,username,nickname,avatar,role,created_at FROM users WHERE username LIKE ? OR nickname LIKE ? LIMIT 20')
    .all(`%${q}%`, `%${q}%`);
  res.json(rows);
});

router.get('/:id', (req, res) => {
  const uid = uidOf(req, res); if (uid === null) return;
  const u = db.prepare('SELECT id,username,nickname,avatar,role,created_at FROM users WHERE id = ?').get(req.params.id);
  if (!u) return res.status(404).json({ error: 'not found' });
  res.json(publicUser(u));
});

module.exports = router;
