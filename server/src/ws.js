const { WebSocketServer } = require('ws');
const hub = require('./hub');
const { verifyToken } = require('./auth');
const { sendMessage, recallMessage, markRead, typing } = require('./chat');
const call = require('./call');

/** 协议层心跳探测间隔：30 秒 */
const PING_EVERY_MS = 30 * 1000;

function init(server) {
  const wss = new WebSocketServer({ server, path: '/ws' });

  // 协议层心跳：NAT / 内网穿透隧道会在空闲时静默回收连接，
  // TCP 层不一定报错。没有这层探测，服务端会把早已死掉的 socket
  // 当成在线，来电帧发进黑洞——用户表现就是"来电界面根本不弹"。
  const pingTimer = setInterval(() => {
    for (const ws of wss.clients) {
      if (ws.isAlive === false) {
        ws.terminate();
        continue;
      }
      ws.isAlive = false;
      try { ws.ping(); } catch { /* 忽略 */ }
    }
  }, PING_EVERY_MS);
  wss.on('close', () => clearInterval(pingTimer));

  wss.on('connection', (ws, req) => {
    const params = new URL(req.url, 'http://localhost').searchParams;
    const claims = verifyToken(params.get('token'));
    if (!claims) { ws.close(4001, 'unauthorized'); return; }

    const userId = claims.uid;
    ws.isAlive = true;
    ws.on('pong', () => { ws.isAlive = true; });
    hub.addSocket(userId, ws);
    hub.send(ws, { type: 'connected', userId });

    // 可能是断线重连：先取消掉线宽限定时器（人回来了，这通电话不该被判死），
    // 再把正在振铃的通话补推给他 —— 否则断线期间错过的来电会变成
    // "永远收不到"，只能等对方挂断后在会话里看到一条未接记录。
    call.handleOnline(userId);
    const pending = call.pendingForUser(userId);
    if (pending) hub.send(ws, pending);

    ws.on('message', (raw) => {
      let frame;
      try { frame = JSON.parse(raw.toString()); } catch { return; }
      try {
        switch (frame.type) {
          // 应用层心跳（客户端每 20 秒一发）。回 pong 让客户端确认链路活着，
          // 同时刷新这里的 isAlive，协议层 ping 就不用重复探测了。
          case 'ping':
            ws.isAlive = true;
            hub.send(ws, { type: 'pong', ts: Date.now(), echo: frame.ts });
            break;
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
          // 撤回：内部已广播给会话全体（含发起端，用于多端同步），无需再回执
          case 'message:recall':
            recallMessage({ messageId: frame.messageId, userId });
            break;
          // 已发消息不可修改，只能撤回。
          // 回一条 error 是给旧版客户端（<= v0.5.2，右键菜单里还有「编辑」）的兜底：
          // 不回的话它点了会毫无反应，用户以为卡住了。
          case 'message:edit':
            hub.send(ws, { type: 'error', ref: 'message:edit', message: '已发送的消息不支持修改，只能撤回' });
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
          // 群通话：calleeIds 是显式邀请名单；都不传则邀请群内全部其他成员
          case 'call:invite':
            call.invite({
              conversationId: frame.conversationId,
              callerId: userId,
              calleeId: frame.calleeId,
              calleeIds: frame.calleeIds,
              mode: frame.mode,
            });
            break;
          case 'call:accept':
            call.accept({ callId: frame.callId, userId });
            break;
          // 中途加入一通正在进行的通话（群里"我也进去"）
          case 'call:join': {
            const err = call.join({ callId: frame.callId, userId });
            if (err) hub.send(ws, { type: 'error', message: err, ref: 'call:join' });
            break;
          }
          case 'call:reject':
            call.reject({ callId: frame.callId, userId, reason: frame.reason });
            break;
          case 'call:cancel':
            call.cancel({ callId: frame.callId, userId });
            break;
          // 挂断。1v1 整通结束；群通话里语义是"我退出"，其余人继续
          // （发起人退出也不解散 —— 否则他手机没电全群陪跑）
          case 'call:end':
            call.end({ callId: frame.callId, userId, reason: frame.reason });
            break;
          // offer / answer / ice 三种 SDP 交换共用一条中继。
          // `to` 是群通话 mesh 的关键：三个人的房间里，A 的 SDP 只能给指定的人，
          // 广播出去会让第三人收到无关 SDP 并打乱连接状态。1v1 不传，行为同老版本。
          case 'call:offer':
          case 'call:answer':
          case 'call:ice':
            call.relay({
              callId: frame.callId,
              userId,
              type: frame.type.slice(5),
              data: frame.data,
              to: frame.to,
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
