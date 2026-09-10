const { WebSocketServer } = require('ws');
const hub = require('./hub');
const { verifyToken } = require('./auth');
const { sendMessage, recallMessage, editMessage, markRead, typing } = require('./chat');
const call = require('./call');

function init(server) {
  const wss = new WebSocketServer({ server, path: '/ws' });
  wss.on('connection', (ws, req) => {
    const params = new URL(req.url, 'http://localhost').searchParams;
    const claims = verifyToken(params.get('token'));
    if (!claims) { ws.close(4001, 'unauthorized'); return; }

    const userId = claims.uid;
    hub.addSocket(userId, ws);
    hub.send(ws, { type: 'connected', userId });

    ws.on('message', (raw) => {
      let frame;
      try { frame = JSON.parse(raw.toString()); } catch { return; }
      try {
        switch (frame.type) {
          case 'message:send': {
            const msg = sendMessage({
              conversationId: frame.conversationId,
              senderId: userId,
              kind: frame.kind,
              content: frame.content,
              fileId: frame.fileId,
              mentions: frame.mentions,
            });
            hub.send(ws, { type: 'message:new', message: msg });
            break;
          }
          // 撤回 / 编辑：内部已广播给会话全体（含发起端，用于多端同步），无需再回执
          case 'message:recall':
            recallMessage({ messageId: frame.messageId, userId });
            break;
          case 'message:edit':
            editMessage({ messageId: frame.messageId, userId, content: frame.content });
            break;
          // 已读回执：推进自己的 last_read_id 并广播给对方
          case 'message:read': {
            markRead({ conversationId: frame.conversationId, userId, messageId: frame.messageId });
            break;
          }
          // 输入中：纯透传，不落库
          case 'typing': {
            typing({ conversationId: frame.conversationId, userId });
            break;
          }
          // ---- 音视频通话信令（服务端只转发，媒体走 WebRTC P2P）----
          case 'call:invite':
            call.invite({
              conversationId: frame.conversationId,
              callerId: userId,
              calleeId: frame.calleeId,
              mode: frame.mode,
            });
            break;
          case 'call:accept':
            call.accept({ callId: frame.callId, userId });
            break;
          case 'call:reject':
            call.reject({ callId: frame.callId, userId, reason: frame.reason });
            break;
          case 'call:cancel':
            call.cancel({ callId: frame.callId, userId });
            break;
          case 'call:end':
            call.end({ callId: frame.callId, userId, reason: frame.reason });
            break;
          // offer / answer / ice 三种 SDP 交换共用一条中继
          case 'call:offer':
          case 'call:answer':
          case 'call:ice':
            call.relay({
              callId: frame.callId,
              userId,
              type: frame.type.slice(5),
              data: frame.data,
            });
            break;
          default:
            break;
        }
      } catch (e) {
        hub.send(ws, { type: 'error', message: e.message, ref: frame.type });
      }
    });

    ws.on('close', () => {
      hub.removeSocket(userId, ws);
      // 该用户所有端都掉线了，才认为他真的离线（通话可能还挂在另一端）
      if (!hub.userSockets.has(userId)) call.handleOffline(userId);
    });
    ws.on('error', () => {
      hub.removeSocket(userId, ws);
      if (!hub.userSockets.has(userId)) call.handleOffline(userId);
    });
  });
  return wss;
}

module.exports = { init };
