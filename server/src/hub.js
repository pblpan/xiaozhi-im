// WebSocket 连接中心：维护 userId -> Set(socket)
const userSockets = new Map();

function addSocket(userId, ws) {
  if (!userSockets.has(userId)) userSockets.set(userId, new Set());
  userSockets.get(userId).add(ws);
}

function removeSocket(userId, ws) {
  const set = userSockets.get(userId);
  if (set) {
    set.delete(ws);
    if (set.size === 0) userSockets.delete(userId);
  }
}

function send(ws, payload) {
  if (ws.readyState === ws.OPEN) {
    try { ws.send(JSON.stringify(payload)); } catch { /* ignore */ }
  }
}

function broadcastToUser(userId, payload) {
  const set = userSockets.get(userId);
  if (!set) return;
  for (const ws of set) send(ws, payload);
}

function broadcastToConversation(db, conversationId, payload, excludeUserId) {
  const rows = db.prepare('SELECT user_id FROM conversation_members WHERE conversation_id = ?').all(conversationId);
  for (const r of rows) {
    if (r.user_id === excludeUserId) continue;
    broadcastToUser(r.user_id, payload);
  }
}

module.exports = { userSockets, addSocket, removeSocket, send, broadcastToUser, broadcastToConversation };
