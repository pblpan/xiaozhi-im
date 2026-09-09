// 消息落库 + 实时广播（REST 与 WebSocket 共用）
const db = require('./db');
const hub = require('./hub');

// 给消息行补上文件访问地址（历史消息 content 存的是原始名，实际要按 files.path 取）
function withFileInfo(row) {
  if (!row) return row;
  if (!row.file_id) return { ...row, file_url: null };
  const f = db.prepare('SELECT name,mime,size,path FROM files WHERE id=?').get(row.file_id);
  if (!f) return { ...row, file_url: null };
  return { ...row, file_url: `/files/${f.path}`, file_name: f.name, file_mime: f.mime, file_size: f.size };
}

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
  const full = withFileInfo(msg);
  const payload = { type: 'message:new', message: full };
  hub.broadcastToConversation(db, conversationId, payload, senderId);
  return full;
}

module.exports = { sendMessage, withFileInfo };
