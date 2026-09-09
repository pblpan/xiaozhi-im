const router = require('express').Router();
const db = require('../db');
const { verifyToken } = require('../auth');
const { sendMessage } = require('../chat');

function uidOf(req, res) {
  const c = verifyToken(req.headers.authorization?.replace('Bearer ', ''));
  if (!c) { res.status(401).json({ error: 'unauthorized' }); return null; }
  return c.uid;
}

// 我的会话列表（含最近一条消息预览）
router.get('/', (req, res) => {
  const uid = uidOf(req, res); if (uid === null) return;
  const convs = db.prepare(`SELECT c.id, c.type, c.created_at,
      (SELECT content FROM messages m WHERE m.conversation_id=c.id ORDER BY m.id DESC LIMIT 1) AS last_content,
      (SELECT kind FROM messages m WHERE m.conversation_id=c.id ORDER BY m.id DESC LIMIT 1) AS last_kind,
      (SELECT MAX(created_at) FROM messages m WHERE m.conversation_id=c.id) AS last_at
    FROM conversations c
    JOIN conversation_members cm ON cm.conversation_id=c.id
    WHERE cm.user_id=? ORDER BY last_at DESC`).all(uid);
  const out = convs.map(c => {
    if (c.type === 'dm') {
      const other = db.prepare(`SELECT u.id,u.username,u.nickname,u.avatar FROM conversation_members cm
        JOIN users u ON u.id=cm.user_id WHERE cm.conversation_id=? AND cm.user_id!=?`).get(c.id, uid);
      return { ...c, title: other?.nickname || other?.username, avatar: other?.avatar, peer: other };
    }
    const g = db.prepare('SELECT name,avatar FROM groups WHERE conversation_id=?').get(c.id);
    return { ...c, title: g?.name, avatar: g?.avatar };
  });
  res.json(out);
});

// 获取/创建与某用户的单聊会话
router.get('/dm/:userId', (req, res) => {
  const uid = uidOf(req, res); if (uid === null) return;
  const otherId = Number(req.params.userId);
  if (otherId === uid) return res.status(400).json({ error: 'cannot dm self' });
  const existing = db.prepare(`SELECT c.id FROM conversations c
    JOIN conversation_members m1 ON m1.conversation_id=c.id AND m1.user_id=?
    JOIN conversation_members m2 ON m2.conversation_id=c.id AND m2.user_id=?
    WHERE c.type='dm'`).get(uid, otherId);
  if (existing) return res.json({ conversationId: existing.id });
  const info = db.prepare("INSERT INTO conversations (type,created_at) VALUES ('dm',?)").run(Date.now());
  const cid = info.lastInsertRowid;
  db.prepare('INSERT INTO conversation_members (conversation_id,user_id) VALUES (?,?)').run(cid, uid);
  db.prepare('INSERT INTO conversation_members (conversation_id,user_id) VALUES (?,?)').run(cid, otherId);
  res.json({ conversationId: cid });
});

// 会话消息历史
router.get('/:id/messages', (req, res) => {
  const uid = uidOf(req, res); if (uid === null) return;
  const cid = Number(req.params.id);
  if (!db.prepare('SELECT user_id FROM conversation_members WHERE conversation_id=? AND user_id=?').get(cid, uid))
    return res.status(403).json({ error: 'forbidden' });
  const rows = db.prepare('SELECT * FROM messages WHERE conversation_id=? AND deleted=0 ORDER BY id ASC LIMIT 200').all(cid);
  res.json(rows);
});

// 发送消息（REST 路径；服务端落库并实时广播）
router.post('/:id/messages', (req, res) => {
  const uid = uidOf(req, res); if (uid === null) return;
  const cid = Number(req.params.id);
  const { kind, content, fileId } = req.body || {};
  if (!kind) return res.status(400).json({ error: 'kind required' });
  try {
    const msg = sendMessage({ conversationId: cid, senderId: uid, kind, content, fileId });
    res.json(msg);
  } catch (e) { res.status(400).json({ error: e.message }); }
});

module.exports = router;
