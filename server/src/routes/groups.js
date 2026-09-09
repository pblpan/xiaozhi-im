const router = require('express').Router();
const db = require('../db');
const { verifyToken } = require('../auth');
const hub = require('../hub');

function uidOf(req, res) {
  const c = verifyToken(req.headers.authorization?.replace('Bearer ', ''));
  if (!c) { res.status(401).json({ error: 'unauthorized' }); return null; }
  return c.uid;
}

// 建群（同时建群会话）
router.post('/', (req, res) => {
  const uid = uidOf(req, res); if (uid === null) return;
  const name = (req.body?.name || '').trim();
  if (!name) return res.status(400).json({ error: 'name required' });
  const cinfo = db.prepare("INSERT INTO conversations (type,created_at) VALUES ('group',?)").run(Date.now());
  const cid = cinfo.lastInsertRowid;
  const ginfo = db.prepare('INSERT INTO groups (name,owner_id,conversation_id,created_at) VALUES (?,?,?,?)')
    .run(name, uid, cid, Date.now());
  const gid = ginfo.lastInsertRowid;
  db.prepare('INSERT INTO group_members (group_id,user_id,role,joined_at) VALUES (?,?,?,?)').run(gid, uid, 'owner', Date.now());
  db.prepare('INSERT INTO conversation_members (conversation_id,user_id) VALUES (?,?)').run(cid, uid);
  res.json({ groupId: gid, conversationId: cid });
});

// 我加入的群
router.get('/my', (req, res) => {
  const uid = uidOf(req, res); if (uid === null) return;
  const rows = db.prepare(`SELECT g.id,g.name,g.avatar,g.conversation_id,
    (SELECT COUNT(*) FROM group_members gm WHERE gm.group_id=g.id) members
    FROM groups g JOIN group_members gm ON gm.group_id=g.id WHERE gm.user_id=? ORDER BY g.id DESC`).all(uid);
  res.json(rows);
});

// 群信息 + 成员
router.get('/:groupId', (req, res) => {
  const uid = uidOf(req, res); if (uid === null) return;
  const gid = Number(req.params.groupId);
  const g = db.prepare('SELECT id,name,owner_id,avatar,conversation_id,created_at FROM groups WHERE id=?').get(gid);
  if (!g) return res.status(404).json({ error: 'not found' });
  const members = db.prepare(`SELECT u.id,u.username,u.nickname,u.avatar,m.role FROM group_members m
    JOIN users u ON u.id=m.user_id WHERE m.group_id=?`).all(gid);
  res.json({ group: g, members });
});

// 拉人入群
router.post('/:groupId/members', (req, res) => {
  const uid = uidOf(req, res); if (uid === null) return;
  const gid = Number(req.params.groupId);
  const g = db.prepare('SELECT conversation_id,owner_id FROM groups WHERE id=?').get(gid);
  if (!g) return res.status(404).json({ error: 'not found' });
  const userId = Number(req.body?.userId);
  if (!db.prepare('SELECT id FROM users WHERE id=?').get(userId)) return res.status(404).json({ error: 'user not found' });
  if (!db.prepare('SELECT user_id FROM group_members WHERE group_id=? AND user_id=?').get(gid, userId)) {
    db.prepare('INSERT INTO group_members (group_id,user_id,role,joined_at) VALUES (?,?,?,?)').run(gid, userId, 'member', Date.now());
  }
  if (!db.prepare('SELECT user_id FROM conversation_members WHERE conversation_id=? AND user_id=?').get(g.conversation_id, userId)) {
    db.prepare('INSERT INTO conversation_members (conversation_id,user_id) VALUES (?,?)').run(g.conversation_id, userId);
  }
  hub.broadcastToUser(userId, { type: 'group:invited', groupId: gid, conversationId: g.conversation_id });
  res.json({ ok: true });
});

// 移出群
router.delete('/:groupId/members/:userId', (req, res) => {
  const uid = uidOf(req, res); if (uid === null) return;
  const gid = Number(req.params.groupId);
  const g = db.prepare('SELECT conversation_id,owner_id FROM groups WHERE id=?').get(gid);
  if (!g) return res.status(404).json({ error: 'not found' });
  if (g.owner_id !== uid) return res.status(403).json({ error: 'only owner can remove' });
  const userId = Number(req.params.userId);
  db.prepare('DELETE FROM group_members WHERE group_id=? AND user_id=?').run(gid, userId);
  db.prepare('DELETE FROM conversation_members WHERE conversation_id=? AND user_id=?').run(g.conversation_id, userId);
  res.json({ ok: true });
});

module.exports = router;
