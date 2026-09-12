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

const USER_COLS = 'u.id,u.username,u.nickname,u.avatar,u.signature';
const MAX_TEMPLATES = 10;
const MAX_MESSAGE = 100;
const MAX_REMARK = 30;

const brief = (id) => db.prepare(`SELECT id,username,nickname,avatar,signature FROM users WHERE id=?`).get(id);

// ============================================================
// 认证附言模板
// 注意：这一组必须放在 `DELETE /:friendId` 之前，
// 否则 DELETE /templates 会被 /:friendId 抢先匹配（friendId='templates' → NaN）
// ============================================================

/// 新用户第一次打开「新的朋友」时给几条现成的，省得对着空白框发呆
const SEED_TEMPLATES = [
  '你好，我是小智 IM 的用户，想加你为好友',
  '我们在群里聊过，加个好友吧',
  '有事想请教你，方便加个好友吗',
];

router.get('/templates', (req, res) => {
  const uid = uidOf(req, res); if (uid === null) return;
  let rows = db.prepare('SELECT id,content,sort FROM friend_templates WHERE user_id=? ORDER BY sort,id').all(uid);
  if (!rows.length) {
    const now = Date.now();
    const ins = db.prepare('INSERT OR IGNORE INTO friend_templates (user_id,content,sort,created_at) VALUES (?,?,?,?)');
    SEED_TEMPLATES.forEach((c, i) => ins.run(uid, c, i, now));
    rows = db.prepare('SELECT id,content,sort FROM friend_templates WHERE user_id=? ORDER BY sort,id').all(uid);
  }
  res.json(rows);
});

router.post('/templates', (req, res) => {
  const uid = uidOf(req, res); if (uid === null) return;
  const content = String(req.body?.content || '').trim();
  if (!content) return res.status(400).json({ error: '模板内容不能为空' });
  if ([...content].length > MAX_MESSAGE) return res.status(400).json({ error: `模板最多 ${MAX_MESSAGE} 个字` });
  const n = db.prepare('SELECT COUNT(*) AS c FROM friend_templates WHERE user_id=?').get(uid).c;
  if (n >= MAX_TEMPLATES) return res.status(400).json({ error: `最多只能存 ${MAX_TEMPLATES} 条模板` });
  try {
    const info = db.prepare('INSERT INTO friend_templates (user_id,content,sort,created_at) VALUES (?,?,?,?)')
      .run(uid, content, n, Date.now());
    res.json({ id: info.lastInsertRowid, content, sort: n });
  } catch (e) {
    // UNIQUE(user_id,content) 撞了
    if (/UNIQUE/i.test(e.message)) return res.status(409).json({ error: '这条模板已经有了' });
    throw e;
  }
});

router.put('/templates/:id', (req, res) => {
  const uid = uidOf(req, res); if (uid === null) return;
  const id = Number(req.params.id);
  const content = String(req.body?.content || '').trim();
  if (!content) return res.status(400).json({ error: '模板内容不能为空' });
  if ([...content].length > MAX_MESSAGE) return res.status(400).json({ error: `模板最多 ${MAX_MESSAGE} 个字` });
  const row = db.prepare('SELECT id FROM friend_templates WHERE id=? AND user_id=?').get(id, uid);
  if (!row) return res.status(404).json({ error: '模板不存在' });
  try {
    db.prepare('UPDATE friend_templates SET content=? WHERE id=? AND user_id=?').run(content, id, uid);
    res.json({ id, content });
  } catch (e) {
    if (/UNIQUE/i.test(e.message)) return res.status(409).json({ error: '这条模板已经有了' });
    throw e;
  }
});

router.delete('/templates/:id', (req, res) => {
  const uid = uidOf(req, res); if (uid === null) return;
  const id = Number(req.params.id);
  db.prepare('DELETE FROM friend_templates WHERE id=? AND user_id=?').run(id, uid);
  res.json({ ok: true });
});

// ============================================================
// 好友备注（我给对方起的名字，只对我可见）
// ============================================================

/// 设置 / 清空备注。remark 传空串即清除；备注是「我这一侧」的私有属性，
/// 所以只落在 (user_id=我, friend_id=对方) 这一行，不广播给对方。
router.put('/:friendId/remark', (req, res) => {
  const uid = uidOf(req, res); if (uid === null) return;
  const friendId = Number(req.params.friendId);
  if (!Number.isInteger(friendId) || friendId <= 0) return res.status(400).json({ error: '好友 id 不合法' });
  if (friendId === uid) return res.status(400).json({ error: '不能给自己设备注' });

  const remark = String(req.body?.remark ?? '').trim();
  if ([...remark].length > MAX_REMARK) return res.status(400).json({ error: `备注最多 ${MAX_REMARK} 个字` });

  // 必须是已接受的好友关系才能备注（申请中/已删除都不行）
  const row = db.prepare("SELECT id FROM friendships WHERE user_id=? AND friend_id=? AND status='accepted'")
    .get(uid, friendId);
  if (!row) return res.status(404).json({ error: '你们还不是好友' });

  db.prepare('UPDATE friendships SET remark=? WHERE user_id=? AND friend_id=?')
    .run(remark || null, uid, friendId);
  res.json({ ok: true, friendId, remark: remark || null });
});

// ============================================================
// 好友申请
// ============================================================

// 发起好友请求（带认证附言）
router.post('/request', (req, res) => {
  const uid = uidOf(req, res); if (uid === null) return;
  const friendId = Number(req.body?.friendId);
  const message = String(req.body?.message || '').trim();
  if (!Number.isInteger(friendId) || friendId <= 0) return res.status(400).json({ error: '好友 id 不合法' });
  if (friendId === uid) return res.status(400).json({ error: '不能加自己为好友' });
  if ([...message].length > MAX_MESSAGE) return res.status(400).json({ error: `附言最多 ${MAX_MESSAGE} 个字` });
  if (!db.prepare('SELECT id FROM users WHERE id = ?').get(friendId)) return res.status(404).json({ error: '用户不存在' });

  const mine = db.prepare('SELECT id,status,message FROM friendships WHERE user_id=? AND friend_id=?').get(uid, friendId);
  if (mine && mine.status === 'accepted') return res.status(409).json({ error: '你们已经是好友了' });

  // 对方已经申请过我：别再互发申请，提示去处理
  const theirs = db.prepare("SELECT id FROM friendships WHERE user_id=? AND friend_id=? AND status='pending'").get(friendId, uid);
  if (theirs) return res.status(409).json({ error: '对方已向你发送好友申请，请到「新的朋友」处理' });

  let updated = false;
  if (mine) {
    // 已申请过还没被处理：允许改附言重发，不当成错误（用户多半是想补一句话）
    db.prepare('UPDATE friendships SET message=? WHERE user_id=? AND friend_id=?').run(message, uid, friendId);
    updated = true;
  } else {
    db.prepare('INSERT INTO friendships (user_id,friend_id,status,message,created_at) VALUES (?,?,?,?,?)')
      .run(uid, friendId, 'pending', message, Date.now());
  }

  // 帧里带上申请人资料与附言：被叫端可直接弹通知，不用再查一次接口
  hub.broadcastToUser(friendId, {
    type: 'friend:request',
    from: uid,
    user: brief(uid),
    message,
  });
  res.json({ ok: true, updated });
});

// 我的好友 + 待处理请求（含附言、申请人资料、申请时间）
// remark 一并返回：客户端列表要按「我看到的名称」显示与排序
router.get('/', (req, res) => {
  const uid = uidOf(req, res); if (uid === null) return;
  const friends = db.prepare(`SELECT ${USER_COLS}, f.remark, f.created_at FROM friendships f
    JOIN users u ON u.id=f.friend_id
    WHERE f.user_id=? AND f.status='accepted'
    ORDER BY COALESCE(NULLIF(f.remark,''), u.nickname, u.username)`).all(uid);
  const pending = db.prepare(`SELECT ${USER_COLS}, f.message, f.created_at FROM friendships f
    JOIN users u ON u.id=f.user_id
    WHERE f.friend_id=? AND f.status='pending' ORDER BY f.created_at DESC`).all(uid);
  res.json({ friends, pending });
});

// 接受好友请求（自动建单聊会话）
router.post('/accept', (req, res) => {
  const uid = uidOf(req, res); if (uid === null) return;
  const friendId = Number(req.body?.friendId);
  if (!Number.isInteger(friendId) || friendId <= 0) return res.status(400).json({ error: '好友 id 不合法' });
  const row = db.prepare("SELECT id FROM friendships WHERE user_id=? AND friend_id=? AND status='pending'").get(friendId, uid);
  if (!row) return res.status(404).json({ error: '申请不存在或已处理' });
  db.prepare("UPDATE friendships SET status='accepted' WHERE user_id=? AND friend_id=?").run(friendId, uid);
  if (!db.prepare('SELECT id FROM friendships WHERE user_id=? AND friend_id=?').get(uid, friendId))
    db.prepare("INSERT INTO friendships (user_id,friend_id,status,created_at) VALUES (?,?,?,?)").run(uid, friendId, 'accepted', Date.now());
  createDM(uid, friendId);
  hub.broadcastToUser(friendId, { type: 'friend:accepted', from: uid, user: brief(uid) });
  res.json({ ok: true });
});

// 拒绝好友请求：删掉 pending 记录（对方之后仍可再次申请，不做永久拉黑）
router.post('/reject', (req, res) => {
  const uid = uidOf(req, res); if (uid === null) return;
  const friendId = Number(req.body?.friendId);
  if (!Number.isInteger(friendId) || friendId <= 0) return res.status(400).json({ error: '好友 id 不合法' });
  const info = db.prepare("DELETE FROM friendships WHERE user_id=? AND friend_id=? AND status='pending'").run(friendId, uid);
  if (!info.changes) return res.status(404).json({ error: '申请不存在或已处理' });
  hub.broadcastToUser(friendId, { type: 'friend:rejected', from: uid });
  res.json({ ok: true });
});

// 删除好友
router.delete('/:friendId', (req, res) => {
  const uid = uidOf(req, res); if (uid === null) return;
  const friendId = Number(req.params.friendId);
  if (!Number.isInteger(friendId) || friendId <= 0) return res.status(400).json({ error: '好友 id 不合法' });
  db.prepare('DELETE FROM friendships WHERE (user_id=? AND friend_id=?) OR (user_id=? AND friend_id=?)').run(uid, friendId, friendId, uid);
  res.json({ ok: true });
});

module.exports = router;
