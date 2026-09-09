const { WebSocketServer } = require('ws');
const hub = require('./hub');
const { verifyToken } = require('./auth');
const { sendMessage } = require('./chat');

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
      if (frame.type === 'message:send') {
        try {
          const msg = sendMessage({
            conversationId: frame.conversationId,
            senderId: userId,
            kind: frame.kind,
            content: frame.content,
            fileId: frame.fileId,
          });
          hub.send(ws, { type: 'message:new', message: msg });
        } catch (e) {
          hub.send(ws, { type: 'error', message: e.message });
        }
      }
    });

    ws.on('close', () => hub.removeSocket(userId, ws));
    ws.on('error', () => hub.removeSocket(userId, ws));
  });
  return wss;
}

module.exports = { init };
