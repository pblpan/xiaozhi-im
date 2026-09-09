// 消息落库 + 实时广播（REST 与 WebSocket 共用）
const db = require('./db');
const hub = require('./hub');

function sendMessage({ conversationId, senderId, kind, content, fileId }) {
  const conv = db.prepare('SELECT id FROM conversations WHERE id = ?').get(conversationId);
  if (!conv) throw new Error('conversation not found');
  const member = db.prepare('SELECT user_id FROM conversation_members WHERE conversation_id = ? AND user_id = ?')
    .get(conversationId, senderId);
  if (!member) throw new Error('not a member of this conversation');

  const res = db.prepare(`INSERT INTO messages
    (conversation_id, sender_id, kind, content, file_id, created_at, edited, deleted)
    VALUES (?,?,?,?,?,?,0,0)`)
    .run(conversationId, senderId, kind || 'text', content || null, fileId || null, Date.now());

  const msg = db.prepare('SELECT * FROM messages WHERE id = ?').get(res.lastInsertRowid);
  const payload = { type: 'message:new', message: msg };
  hub.broadcastToConversation(db, conversationId, payload, senderId);
  return msg;
}

module.exports = { sendMessage };
