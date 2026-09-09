const router = require('express').Router();
const db = require('../db');
const { verifyToken } = require('../auth');

function adminOf(req, res) {
  const c = verifyToken(req.headers.authorization?.replace('Bearer ', ''));
  if (!c) { res.status(401).json({ error: 'unauthorized' }); return null; }
  const u = db.prepare('SELECT role FROM users WHERE id=?').get(c.uid);
  if (!u || u.role !== 'admin') { res.status(403).json({ error: 'forbidden' }); return null; }
  return c.uid;
}

router.get('/stats', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  res.json({
    users: db.prepare('SELECT COUNT(*) c FROM users').get().c,
    groups: db.prepare('SELECT COUNT(*) c FROM groups').get().c,
    messages: db.prepare('SELECT COUNT(*) c FROM messages').get().c,
    files: db.prepare('SELECT COUNT(*) c FROM files').get().c,
    friendships: db.prepare("SELECT COUNT(*) c FROM friendships WHERE status='accepted'").get().c,
  });
});

router.get('/users', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  res.json(db.prepare('SELECT id,username,nickname,avatar,role,created_at FROM users ORDER BY id DESC LIMIT 200').all());
});

router.post('/users/:id/role', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  const role = req.body?.role === 'admin' ? 'admin' : 'user';
  db.prepare('UPDATE users SET role=? WHERE id=?').run(role, Number(req.params.id));
  res.json({ ok: true });
});

router.delete('/users/:id', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  const target = Number(req.params.id);
  if (target === uid) return res.status(400).json({ error: 'cannot delete self' });
  db.prepare('DELETE FROM users WHERE id=?').run(target);
  res.json({ ok: true });
});

router.get('/groups', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  res.json(db.prepare(`SELECT g.id,g.name,g.owner_id,u.nickname owner_name,g.created_at,
    (SELECT COUNT(*) FROM group_members gm WHERE gm.group_id=g.id) members
    FROM groups g JOIN users u ON u.id=g.owner_id ORDER BY g.id DESC`).all());
});

router.delete('/groups/:id', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  const gid = Number(req.params.id);
  const g = db.prepare('SELECT conversation_id FROM groups WHERE id=?').get(gid);
  db.prepare('DELETE FROM groups WHERE id=?').run(gid);
  db.prepare('DELETE FROM group_members WHERE group_id=?').run(gid);
  if (g) db.prepare('DELETE FROM conversation_members WHERE conversation_id=?').run(g.conversation_id);
  res.json({ ok: true });
});

module.exports = router;
