const router = require('express').Router();
const db = require('../db');
const { verifyToken } = require('../auth');
const hub = require('../hub');

function uidOf(req, res) {
  const c = verifyToken(req.headers.authorization?.replace('Bearer ', ''));
  if (!c) { res.status(401).json({ error: 'unauthorized' }); return null; }
  return c.uid;
}

// 创建单聊会话（若不存在）
function createDM(a, b) {
  const existing = db.prepare(`SELECT c.id FROM conversations c
    JOIN conversation_members m1 ON m1.conversation_id=c.id AND m1.user_id=?
    JOIN conversation_members m2 ON m2.conversation_id=c.id AND m2.user_id=?
    WHERE c.type='dm'`).get(a, b);
  if (existing) return existing.id;
  const info = db.prepare("INSERT INTO conversations (type,created_at) VALUES ('dm',?)").run(Date.now());
  const cid = info.lastInsertRowid;
  db.prepare('INSERT INTO conversation_members (conversation_id,user_id) VALUES (?,?)').run(cid, a);
  db.prepare('INSERT INTO conversation_members (conversation_id,user_id) VALUES (?,?)').run(cid, b);
  return cid;
}

// 发起好友请求
router.post('/request', (req, res) => {
  const uid = uidOf(req, res); if (uid === null) return;
  const friendId = Number(req.body?.friendId);
  if (!friendId || friendId === uid) return res.status(400).json({ error: 'invalid friendId' });
  if (!db.prepare('SELECT id FROM users WHERE id = ?').get(friendId)) return res.status(404).json({ error: 'user not found' });
  if (db.prepare('SELECT id FROM friendships WHERE user_id=? AND friend_id=?').get(uid, friendId))
    return res.status(409).json({ error: 'already requested' });
  db.prepare('INSERT INTO friendships (user_id,friend_id,status,created_at) VALUES (?,?,?,?)').run(uid, friendId, 'pending', Date.now());
  hub.broadcastToUser(friendId, { type: 'friend:request', from: uid });
  res.json({ ok: true });
});

// 我的好友 + 待处理请求
router.get('/', (req, res) => {
  const uid = uidOf(req, res); if (uid === null) return;
  const friends = db.prepare(`SELECT u.id,u.username,u.nickname,u.avatar FROM friendships f
    JOIN users u ON u.id=f.friend_id WHERE f.user_id=? AND f.status='accepted'`).all(uid);
  const pending = db.prepare(`SELECT u.id,u.username,u.nickname,u.avatar FROM friendships f
    JOIN users u ON u.id=f.user_id WHERE f.friend_id=? AND f.status='pending'`).all(uid);
  res.json({ friends, pending });
});

// 接受好友请求（自动建单聊会话）
router.post('/accept', (req, res) => {
  const uid = uidOf(req, res); if (uid === null) return;
  const friendId = Number(req.body?.friendId);
  const row = db.prepare("SELECT id FROM friendships WHERE user_id=? AND friend_id=? AND status='pending'").get(friendId, uid);
  if (!row) return res.status(404).json({ error: 'request not found' });
  db.prepare("UPDATE friendships SET status='accepted' WHERE user_id=? AND friend_id=?").run(friendId, uid);
  if (!db.prepare('SELECT id FROM friendships WHERE user_id=? AND friend_id=?').get(uid, friendId))
    db.prepare("INSERT INTO friendships (user_id,friend_id,status,created_at) VALUES (?,?,?,?)").run(uid, friendId, 'accepted', Date.now());
  createDM(uid, friendId);
  hub.broadcastToUser(friendId, { type: 'friend:accepted', from: uid });
  res.json({ ok: true });
});

// 删除好友
router.delete('/:friendId', (req, res) => {
  const uid = uidOf(req, res); if (uid === null) return;
  const friendId = Number(req.params.friendId);
  db.prepare('DELETE FROM friendships WHERE (user_id=? AND friend_id=?) OR (user_id=? AND friend_id=?)').run(uid, friendId, friendId, uid);
  res.json({ ok: true });
});

module.exports = router;
