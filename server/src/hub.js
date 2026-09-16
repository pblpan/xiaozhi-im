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

/**
 * 这个人此刻是不是有活跃连接。
 *
 * 【用途】推送的"要不要发"判据：连着 WebSocket 说明 App 就在前台
 * （Android 端甚至缩在托盘也还连着），消息已经实时到了，
 * 再推一条通知就是**重复打扰**。
 * 【注意】只能用来"省一次推送"，**不能**反过来当"离线"的判据用：
 * iOS 后台连接会被系统掐掉，这里返回 false 才是常态。
 */
function isUserOnline(userId) {
  const set = userSockets.get(userId);
  return !!set && set.size > 0;
}

function broadcastToConversation(db, conversationId, payload, excludeUserId) {
  const rows = db.prepare('SELECT user_id FROM conversation_members WHERE conversation_id = ?').all(conversationId);
  for (const r of rows) {
    if (r.user_id === excludeUserId) continue;
    broadcastToUser(r.user_id, payload);
  }
}

module.exports = { userSockets, addSocket, removeSocket, send, broadcastToUser, broadcastToConversation, isUserOnline };
