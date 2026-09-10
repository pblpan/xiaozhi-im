// 消息落库 + 实时广播（REST 与 WebSocket 共用）
const db = require('./db');
const hub = require('./hub');

/** 撤回时限：2 分钟（与主流 IM 一致） */
const RECALL_WINDOW_MS = 2 * 60 * 1000;

// 给消息行补上文件访问地址（历史消息 content 存的是原始名，实际要按 files.path 取）
function withFileInfo(row) {
  if (!row) return row;
  if (row.deleted) return { ...row, file_url: null, file_name: null, file_mime: null, file_size: null };
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

  // 发消息视为已读到本条，避免自己发的消息显示未读
  db.prepare(`UPDATE conversation_members SET last_read_id = ?
    WHERE conversation_id = ? AND user_id = ? AND last_read_id < ?`)
    .run(res.lastInsertRowid, conversationId, senderId, res.lastInsertRowid);

  const msg = db.prepare('SELECT * FROM messages WHERE id = ?').get(res.lastInsertRowid);
  const full = withFileInfo(msg);
  hub.broadcastToConversation(db, conversationId, { type: 'message:new', message: full }, senderId);
  return full;
}

/** 撤回消息：仅本人、2 分钟内、未被撤回。广播给会话全体（含自己的其他端）。 */
function recallMessage({ messageId, userId }) {
  const m = db.prepare('SELECT * FROM messages WHERE id = ?').get(messageId);
  if (!m) throw new Error('消息不存在');
  if (m.sender_id !== userId) throw new Error('只能撤回自己的消息');
  if (m.deleted) throw new Error('该消息已撤回');
  if (Date.now() - m.created_at > RECALL_WINDOW_MS) throw new Error('超过 2 分钟，无法撤回');

  db.prepare('UPDATE messages SET deleted = 1, content = NULL, file_id = NULL WHERE id = ?').run(messageId);

  const payload = {
    type: 'message:recall',
    messageId,
    conversationId: m.conversation_id,
    senderId: userId,
  };
  hub.broadcastToConversation(db, m.conversation_id, payload, null);
  return payload;
}

/** 编辑消息：仅本人、仅文字、未被撤回。广播给会话全体（含自己的其他端）。 */
function editMessage({ messageId, userId, content }) {
  const m = db.prepare('SELECT * FROM messages WHERE id = ?').get(messageId);
  if (!m) throw new Error('消息不存在');
  if (m.sender_id !== userId) throw new Error('只能编辑自己的消息');
  if (m.deleted) throw new Error('该消息已撤回');
  if (m.kind !== 'text') throw new Error('只能编辑文字消息');

  const text = (content || '').trim();
  if (!text) throw new Error('内容不能为空');
  if (text === m.content) return { type: 'message:edit', messageId, conversationId: m.conversation_id, content: text };

  db.prepare('UPDATE messages SET content = ?, edited = 1 WHERE id = ?').run(text, messageId);

  const payload = {
    type: 'message:edit',
    messageId,
    conversationId: m.conversation_id,
    content: text,
    edited: 1,
  };
  hub.broadcastToConversation(db, m.conversation_id, payload, null);
  return payload;
}

/** 标记已读：把会话成员的 last_read_id 推进到指定消息（缺省=该会话最新一条）。 */
function markRead({ conversationId, userId, messageId }) {
  const member = db.prepare('SELECT last_read_id FROM conversation_members WHERE conversation_id = ? AND user_id = ?')
    .get(conversationId, userId);
  if (!member) throw new Error('not a member of this conversation');

  let target = Number(messageId) || 0;
  if (!target) {
    const row = db.prepare('SELECT MAX(id) AS mid FROM messages WHERE conversation_id = ?').get(conversationId);
    target = row?.mid || 0;
  }
  const cur = member.last_read_id || 0;
  if (target <= cur) return { conversationId, userId, lastReadId: cur, changed: false };

  db.prepare('UPDATE conversation_members SET last_read_id = ? WHERE conversation_id = ? AND user_id = ?')
    .run(target, conversationId, userId);

  // 告诉会话内其他人"我读到哪了"（用于对方渲染已读回执）
  hub.broadcastToConversation(db, conversationId, {
    type: 'message:read',
    conversationId,
    userId,
    lastReadId: target,
  }, userId);

  return { conversationId, userId, lastReadId: target, changed: true };
}

/** 输入中状态：不落库，纯透传给会话内其他人。 */
function typing({ conversationId, userId }) {
  const member = db.prepare('SELECT user_id FROM conversation_members WHERE conversation_id = ? AND user_id = ?')
    .get(conversationId, userId);
  if (!member) return;
  hub.broadcastToConversation(db, conversationId, {
    type: 'typing',
    conversationId,
    userId,
  }, userId);
}

/** 会话成员的已读位置快照（供历史接口返回，渲染已读回执）。 */
function readState(conversationId) {
  return db.prepare('SELECT user_id, last_read_id FROM conversation_members WHERE conversation_id = ?')
    .all(conversationId);
}

module.exports = {
  sendMessage, withFileInfo,
  recallMessage, editMessage, markRead, typing, readState,
  RECALL_WINDOW_MS,
};
