const router = require('express').Router();
const db = require('../db');
const { hashPassword, verifyPassword, signToken, verifyToken } = require('../auth');

function publicUser(u) {
  return { id: u.id, username: u.username, nickname: u.nickname, avatar: u.avatar, role: u.role, created_at: u.created_at };
}
function uidOf(req, res) {
  const c = verifyToken(req.headers.authorization?.replace('Bearer ', ''));
  if (!c) { res.status(401).json({ error: 'unauthorized' }); return null; }
  return c.uid;
}

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

router.put('/profile', (req, res) => {
  const uid = uidOf(req, res); if (uid === null) return;
  const { nickname, avatar } = req.body || {};
  if (nickname) db.prepare('UPDATE users SET nickname = ? WHERE id = ?').run(nickname, uid);
  if (avatar) db.prepare('UPDATE users SET avatar = ? WHERE id = ?').run(avatar, uid);
  const user = db.prepare('SELECT * FROM users WHERE id = ?').get(uid);
  res.json({ user: publicUser(user) });
});

module.exports = router;
