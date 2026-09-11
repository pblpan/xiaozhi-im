const router = require('express').Router();
const db = require('../db');
const { verifyToken } = require('../auth');
const events = require('../events');
const {
  sendMessage, withFileInfo,
  recallMessage, markRead, readState, RECALL_WINDOW_MS,
  searchMessages, conversationTitle,
  forwardMessage, togglePin, pinnedMessage, MENTION_ALL, mentionLike,
} = require('../chat');

function uidOf(req, res) {
  const c = verifyToken(req.headers.authorization?.replace('Bearer ', ''));
  if (!c) { res.status(401).json({ error: 'unauthorized' }); return null; }
  return c.uid;
}

/** 校验当前用户是该会话成员，否则回 403 并返回 null */
function memberOf(cid, uid, res) {
  const m = db.prepare('SELECT user_id FROM conversation_members WHERE conversation_id=? AND user_id=?').get(cid, uid);
  if (!m) { res.status(403).json({ error: 'forbidden' }); return null; }
  return m;
}

// 全局消息搜索（只搜我参与的会话；?q=关键词&conversationId=&limit=&offset=）
// 注意：必须注册在 '/:id/...' 之前，否则 'search' 会被当成会话 id
router.get('/search', (req, res) => {
  const uid = uidOf(req, res); if (uid === null) return;
  const { q, conversationId, limit, offset } = req.query || {};
  if (!String(q || '').trim()) {
    return res.json({ items: [], total: 0, keyword: '' });
  }
  try {
    res.json(searchMessages({
      userId: uid,
      q,
      conversationId: conversationId ? Number(conversationId) : null,
      limit,
      offset,
    }));
  } catch (e) { res.status(400).json({ error: e.message }); }
});

// 转发消息到多个会话（body: { messageId, conversationIds: [] }）
// 必须注册在 '/:id/...' 之前，否则 'forward' 会被当成会话 id
router.post('/forward', (req, res) => {
  const uid = uidOf(req, res); if (uid === null) return;
  const { messageId, conversationIds } = req.body || {};
  try {
    res.json(forwardMessage({
      messageId: Number(messageId),
      userId: uid,
      conversationIds,
    }));
  } catch (e) { res.status(400).json({ error: e.message }); }
});

// 我的会话列表（含最近一条消息预览、未读数、是否有人@我）
router.get('/', (req, res) => {
  const uid = uidOf(req, res); if (uid === null) return;
  const convs = db.prepare(`SELECT c.id, c.type, c.created_at, c.pinned_message_id, cm.muted,
      (SELECT CASE m.kind
          WHEN 'text'  THEN m.content
          WHEN 'image' THEN '[图片]'
          WHEN 'file'  THEN '[文件]'
          WHEN 'audio' THEN '[语音]'
          WHEN 'emoji' THEN '[表情]'
          WHEN 'card'  THEN '[卡片]'
          WHEN 'call'  THEN '[通话]'
          ELSE m.content END
        FROM messages m WHERE m.conversation_id=c.id AND m.deleted=0 ORDER BY m.id DESC LIMIT 1) AS last_content,
      (SELECT kind FROM messages m WHERE m.conversation_id=c.id AND m.deleted=0 ORDER BY m.id DESC LIMIT 1) AS last_kind,
      (SELECT MAX(created_at) FROM messages m WHERE m.conversation_id=c.id) AS last_at,
      (SELECT COUNT(*) FROM messages m WHERE m.conversation_id=c.id
         AND m.deleted=0 AND m.sender_id!=cm.user_id AND m.id>cm.last_read_id) AS unread
    FROM conversations c
    JOIN conversation_members cm ON cm.conversation_id=c.id
    WHERE cm.user_id=? ORDER BY last_at DESC`).all(uid);

  // 未读里是否有 @我 / @所有人（群聊的"有人@我"红字提示）
  const mentionStmt = db.prepare(`SELECT COUNT(*) n FROM messages m
    JOIN conversation_members cm2 ON cm2.conversation_id=m.conversation_id AND cm2.user_id=?
    WHERE m.conversation_id=? AND m.deleted=0 AND m.sender_id!=?
      AND m.id > cm2.last_read_id AND m.mentions IS NOT NULL
      AND (m.mentions LIKE ? OR m.mentions LIKE ?)`);

  const out = convs.map(c => {
    const unreadMentions = mentionStmt
      .get(uid, c.id, uid, mentionLike(MENTION_ALL), mentionLike(uid)).n;

    const base = { ...c, has_mention: unreadMentions > 0, muted: !!c.muted };
    if (c.type === 'dm') {
      const other = db.prepare(`SELECT u.id,u.username,u.nickname,u.avatar,u.is_bot FROM conversation_members cm
        JOIN users u ON u.id=cm.user_id WHERE cm.conversation_id=? AND cm.user_id!=?`).get(c.id, uid);
      return {
        ...base, title: other?.nickname || other?.username, avatar: other?.avatar,
        peer: other ? { ...other, is_bot: !!other.is_bot } : other,
      };
    }
    const g = db.prepare('SELECT id,name,avatar,announcement FROM groups WHERE conversation_id=?').get(c.id);
    return {
      ...base, title: g?.name, avatar: g?.avatar,
      announcement: g?.announcement, group_id: g?.id,
    };
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
  events.emit('conversation.created', {
    conversationId: cid,
    selfId: uid,
    data: { type: 'dm', peerId: otherId },
  });
  res.json({ conversationId: cid });
});

// 会话消息历史 + 已读状态（已读回执渲染所需）
router.get('/:id/messages', (req, res) => {
  const uid = uidOf(req, res); if (uid === null) return;
  const cid = Number(req.params.id);
  if (!memberOf(cid, uid, res)) return;

  // 带上发送者是否机器人：客户端据此渲染 BOT 标签
  const rows = db.prepare(`SELECT m.*, u.is_bot AS sender_is_bot
    FROM messages m LEFT JOIN users u ON u.id = m.sender_id
    WHERE m.conversation_id=? ORDER BY m.id ASC LIMIT 200`).all(cid);
  const members = readState(cid);

  // 单聊：对方读到哪；群聊：成员里最小已读（表示"所有人都读到"的水位）
  const peer = members.find((m) => m.user_id !== uid);
  const peerLastReadId = peer ? peer.last_read_id : 0;
  const minOtherReadId = members
    .filter((m) => m.user_id !== uid)
    .reduce((min, m) => (min === null ? m.last_read_id : Math.min(min, m.last_read_id)), null) ?? 0;

  res.json({
    messages: rows.map(withFileInfo),
    members,
    peerLastReadId,
    minOtherReadId,
    recallWindowMs: RECALL_WINDOW_MS,
    pinned: pinnedMessage(cid),
    conversation: conversationTitle(cid, uid),
  });
});

// 发送消息（REST 路径；服务端落库并实时广播）
router.post('/:id/messages', (req, res) => {
  const uid = uidOf(req, res); if (uid === null) return;
  const cid = Number(req.params.id);
  const { kind, content, fileId, mentions } = req.body || {};
  if (!kind) return res.status(400).json({ error: 'kind required' });
  try {
    const msg = sendMessage({ conversationId: cid, senderId: uid, kind, content, fileId, mentions });
    res.json(msg);
  } catch (e) { res.status(400).json({ error: e.message }); }
});

// 置顶 / 取消置顶（同一 messageId 再调一次即取消；群聊需群主或管理员）
router.post('/:id/pin', (req, res) => {
  const uid = uidOf(req, res); if (uid === null) return;
  const cid = Number(req.params.id);
  if (!memberOf(cid, uid, res)) return;
  try {
    res.json(togglePin({
      conversationId: cid,
      userId: uid,
      messageId: (req.body || {}).messageId,
    }));
  } catch (e) { res.status(400).json({ error: e.message }); }
});

// 免打扰开关（只影响自己）
router.post('/:id/mute', (req, res) => {
  const uid = uidOf(req, res); if (uid === null) return;
  const cid = Number(req.params.id);
  if (!memberOf(cid, uid, res)) return;
  const on = (req.body || {}).muted ? 1 : 0;
  db.prepare('UPDATE conversation_members SET muted = ? WHERE conversation_id = ? AND user_id = ?')
    .run(on, cid, uid);
  res.json({ conversationId: cid, muted: !!on });
});

// 撤回消息（仅本人 / 2 分钟内）
router.post('/:id/messages/:msgId/recall', (req, res) => {
  const uid = uidOf(req, res); if (uid === null) return;
  const cid = Number(req.params.id);
  if (!memberOf(cid, uid, res)) return;
  try {
    res.json(recallMessage({ messageId: Number(req.params.msgId), userId: uid }));
  } catch (e) { res.status(400).json({ error: e.message }); }
});

// 编辑消息：已下线。已发送的消息只能撤回，不能修改。
// 路由保留并回 410（Gone）而不是 404：旧版客户端仍会调它，
// 给它一条能读懂的说明，比语焉不详的「not found」有用。
router.patch('/:id/messages/:msgId', (req, res) => {
  const uid = uidOf(req, res); if (uid === null) return;
  const cid = Number(req.params.id);
  if (!memberOf(cid, uid, res)) return;
  res.status(410).json({ error: '已发送的消息不支持修改，只能撤回' });
});

// 标记已读（body.messageId 缺省=读到最新）
router.post('/:id/read', (req, res) => {
  const uid = uidOf(req, res); if (uid === null) return;
  const cid = Number(req.params.id);
  if (!memberOf(cid, uid, res)) return;
  try {
    res.json(markRead({ conversationId: cid, userId: uid, messageId: (req.body || {}).messageId }));
  } catch (e) { res.status(400).json({ error: e.message }); }
});

module.exports = router;
