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

/**
 * 广播给**所有在线用户**（跨用户，与好友/群无关）。
 *
 * 【用途】全服务生效的设置变更：公司名、好友模式。这两项直接决定客户端
 * 顶部标题和底部导航形态，改完必须让已经开着的 App 当场跟上 ——
 * 不然就出现"管理台改了、客户端还是老样子"（龙哥 2026-09-18 报的那个）。
 * 【注意】只发给已登录的连接。未登录/离线的人靠下次 `Workspace.refresh()` 拿，
 * 所以这里**不是**唯一通道，不必为它做补发。
 * 【安全】只广播公开字段（bootstrap 里本来就免鉴权可得），别往里塞任何内部数据。
 */
function broadcastAll(payload) {
  for (const set of userSockets.values()) {
    for (const ws of set) send(ws, payload);
  }
}

module.exports = { userSockets, addSocket, removeSocket, send, broadcastToUser, broadcastToConversation, broadcastAll, isUserOnline };
