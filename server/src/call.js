// 1v1 音视频通话信令中继
//
// 服务端不碰媒体：只把 SDP / ICE 在通话两端之间转发。媒体走 WebRTC P2P，
// 所以通话本身不占服务端带宽（同网段 host candidate 直连即可；
// 跨 NAT 需要 TURN 中转时，另行部署 coturn 并在客户端配置 iceServers）。
//
// 状态机：ringing → connecting → active → ended
//   ringing     已呼叫，等待对方接听（超时 45s 自动结束）
//   connecting  对方已接听，正在交换 SDP / ICE
//   active      收到 answer，媒体通道建立
//
// 所有异常路径都会落一条通话记录消息（kind='call'）进会话，双方都能看到，
// 这样"漏接"不会静默丢失。

const db = require('./db');
const hub = require('./hub');
const { sendMessage } = require('./chat');

/** 振铃超时：45 秒无人接听即结束 */
const RING_TIMEOUT_MS = 45 * 1000;

/** 单次通话硬上限：4 小时（防止忘记挂断把两端一直占着） */
const MAX_DURATION_MS = 4 * 60 * 60 * 1000;

/** 支持的通话模式 */
const MODES = ['audio', 'video'];

/**
 * 掉线宽限期。
 *
 * 外网（尤其走内网穿透隧道 / 手机流量）WebSocket 抖动是常态。
 * 老逻辑是"被叫 socket 一断就判未接、直接拆通话"，结果是：网络抖一下，
 * 对方那通还在响的来电就被判死了，用户重连上也接不到 —— 只能看到
 * 一条"未接视频"。给 20 秒重连窗口，人回来了就接着响、补推来电界面。
 *
 * 可用 OFFLINE_GRACE_MS 覆盖（测试里压到几秒，免得每个用例干等）。
 */
const OFFLINE_GRACE_MS = Number(process.env.OFFLINE_GRACE_MS || 20 * 1000);

/** 通话记录里的状态取值（客户端按这个渲染文案） */
const STATUS = {
  ENDED: 'ended',       // 正常通话结束（含时长）
  MISSED: 'missed',     // 未接听 / 无应答
  REJECTED: 'rejected', // 对方拒接
  CANCELED: 'canceled', // 主叫取消
  BUSY: 'busy',         // 对方忙线中
  FAILED: 'failed',     // 连接失败 / 对方掉线
};

const calls = new Map();    // callId -> call
const userCall = new Map(); // userId -> callId（同一时刻只允许一通）

function genId() {
  return 'c' + Date.now().toString(36) + Math.random().toString(36).slice(2, 8);
}

function otherSide(call, userId) {
  return call.callerId === userId ? call.calleeId : call.callerId;
}

/** 通话对外摘要（不含 SDP，只用于界面展示） */
function publicInfo(call) {
  const u = db.prepare('SELECT id, username, nickname, avatar FROM users WHERE id = ?').get(call.callerId);
  return {
    callId: call.id,
    conversationId: call.conversationId,
    mode: call.mode,
    callerId: call.callerId,
    calleeId: call.calleeId,
    callerName: u ? (u.nickname || u.username) : '',
    callerAvatar: u ? u.avatar : null,
  };
}

/** 清理内存状态（不影响已落库的通话记录） */
function cleanup(call) {
  if (call.timer) clearTimeout(call.timer);
  if (call.maxTimer) clearTimeout(call.maxTimer);
  // 连掉线宽限定时器一起清，否则它们超时后会对着已经结束的通话再操作一遍
  if (call.offlineTimers) {
    for (const t of call.offlineTimers.values()) clearTimeout(t);
    call.offlineTimers.clear();
  }
  calls.delete(call.id);
  if (userCall.get(call.callerId) === call.id) userCall.delete(call.callerId);
  if (userCall.get(call.calleeId) === call.id) userCall.delete(call.calleeId);
}

/** 通话记录消息：落进会话，双方都能看到 */
function logCall(call, status, durationSec) {
  try {
    const payload = {
      mode: call.mode,
      status,
      duration: Math.max(0, Math.round(durationSec || 0)),
      caller: call.callerId,
      callee: call.calleeId,
    };
    const msg = sendMessage({
      conversationId: call.conversationId,
      senderId: call.callerId,
      kind: 'call',
      content: JSON.stringify(payload),
    });
    // sendMessage 已广播给"除主叫外的会话成员"（= 被叫）；这里补一条给主叫自己（含其多端）
    hub.broadcastToUser(call.callerId, { type: 'message:new', message: msg });
    return msg;
  } catch (e) {
    // 通话记录落库失败不能影响通话本身
    console.error('[call] 通话记录写入失败:', e.message);
    return null;
  }
}

/** 当前通话已持续多少秒（未接通则为 0） */
function durationOf(call) {
  if (!call.answeredAt) return 0;
  return (Date.now() - call.answeredAt) / 1000;
}

/** 校验会话可通话：必须是单聊，且双方都是成员 */
function resolveConversation(conversationId, callerId, calleeId) {
  // 先做入参体检：缺参数 / 非数字时直接给出可读错误。
  // 否则 undefined 会被塞进 SQLite 绑定，底层抛
  // "Provided value cannot be bound to SQLite parameter 1."，客户端完全看不懂。
  const convId = Number(conversationId);
  if (!Number.isInteger(convId) || convId <= 0) throw new Error('通话参数不正确：缺少会话');

  const conv = db.prepare('SELECT id, type FROM conversations WHERE id = ?').get(convId);
  if (!conv) throw new Error('会话不存在');
  if (conv.type !== 'dm') throw new Error('暂时只支持单聊通话');

  const cid = Number(calleeId);
  if (!Number.isInteger(cid) || cid <= 0 || cid === Number(callerId)) throw new Error('通话对象不正确');

  const members = db.prepare('SELECT user_id FROM conversation_members WHERE conversation_id = ?')
    .all(convId).map((r) => r.user_id);
  if (!members.includes(callerId)) throw new Error('你不在该会话中');
  if (!members.includes(cid)) throw new Error('对方不在该会话中');

  const peer = db.prepare('SELECT id, is_bot FROM users WHERE id = ?').get(cid);
  if (!peer) throw new Error('对方不存在');
  if (peer.is_bot) throw new Error('机器人不支持通话');

  return { conversationId: conv.id, calleeId: cid };
}

/**
 * 发起通话。
 * - 自己被占线 → 直接报错（客户端弹提示）
 * - 对方被占线 → 不回错误，而是发 call:busy 并落一条"对方忙线"记录
 */
function invite({ conversationId, callerId, calleeId, mode }) {
  const m = MODES.includes(String(mode)) ? String(mode) : 'video';
  const { conversationId: cid, calleeId: peerId } = resolveConversation(conversationId, callerId, calleeId);

  if (userCall.has(callerId)) throw new Error('你正在通话中，请先挂断');

  // 对方忙线：不建立通话，只告知主叫 + 留痕
  if (userCall.has(peerId)) {
    const busyCall = {
      id: genId(), conversationId: cid, callerId, calleeId: peerId, mode: m,
      state: 'ended', answeredAt: 0,
    };
    logCall(busyCall, STATUS.BUSY, 0);
    hub.broadcastToUser(callerId, { type: 'call:busy', calleeId: peerId, mode: m });
    return { callId: null, busy: true };
  }

  const call = {
    id: genId(),
    conversationId: cid,
    callerId,
    calleeId: peerId,
    mode: m,
    state: 'ringing',
    createdAt: Date.now(),
    answeredAt: 0,
    timer: null,
    maxTimer: null,
    // userId -> 掉线宽限定时器
    offlineTimers: new Map(),
  };
  calls.set(call.id, call);
  userCall.set(callerId, call.id);
  userCall.set(peerId, call.id);

  const info = publicInfo(call);
  // 被叫可能多端在线：全部振铃，任一端接听后其余端收到 call:handled 自行收起
  hub.broadcastToUser(peerId, { type: 'call:incoming', ...info, from: callerId });
  hub.broadcastToUser(callerId, { type: 'call:ringing', ...info, peerId });

  call.timer = setTimeout(() => {
    if (call.state !== 'ringing') return;
    hub.broadcastToUser(callerId, { type: 'call:timeout', callId: call.id });
    hub.broadcastToUser(peerId, { type: 'call:canceled', callId: call.id, reason: 'timeout' });
    logCall(call, STATUS.MISSED, 0);
    cleanup(call);
  }, RING_TIMEOUT_MS);

  return { callId: call.id, busy: false };
}

/** 接听：仅被叫、仅 ringing 状态 */
function accept({ callId, userId }) {
  const call = calls.get(callId);
  if (!call) throw new Error('通话已结束');
  if (call.calleeId !== userId) throw new Error('只有被叫方可以接听');
  if (call.state !== 'ringing') throw new Error('通话状态不允许接听');

  if (call.timer) { clearTimeout(call.timer); call.timer = null; }
  call.state = 'connecting';
  call.answeredAt = Date.now();

  hub.broadcastToUser(call.callerId, { type: 'call:accepted', callId: call.id, by: userId });
  // 被叫的其他端（多设备）停止振铃
  hub.broadcastToUser(call.calleeId, { type: 'call:handled', callId: call.id, by: userId });

  // 硬上限：防止双方都忘了挂断
  call.maxTimer = setTimeout(() => {
    hub.broadcastToUser(call.callerId, { type: 'call:ended', callId: call.id, reason: 'timeout' });
    hub.broadcastToUser(call.calleeId, { type: 'call:ended', callId: call.id, reason: 'timeout' });
    logCall(call, STATUS.ENDED, durationOf(call));
    cleanup(call);
  }, MAX_DURATION_MS);

  return { callId: call.id, state: call.state };
}

/** 拒接：仅被叫、仅 ringing 状态 */
function reject({ callId, userId, reason }) {
  const call = calls.get(callId);
  if (!call) return { callId, ok: false };
  if (call.calleeId !== userId) throw new Error('只有被叫方可以拒接');

  const busy = reason === 'busy';
  hub.broadcastToUser(call.callerId, {
    type: 'call:rejected', callId: call.id, by: userId, reason: busy ? 'busy' : 'declined',
  });
  logCall(call, busy ? STATUS.BUSY : STATUS.REJECTED, 0);
  cleanup(call);
  return { callId: call.id, ok: true };
}

/** 主叫取消：仅主叫、仅 ringing 状态 */
function cancel({ callId, userId }) {
  const call = calls.get(callId);
  if (!call) return { callId, ok: false };
  if (call.callerId !== userId) throw new Error('只有主叫方可以取消');
  if (call.state !== 'ringing') throw new Error('对方已接听，请使用挂断');

  hub.broadcastToUser(call.calleeId, { type: 'call:canceled', callId: call.id, reason: 'canceled' });
  logCall(call, STATUS.CANCELED, 0);
  cleanup(call);
  return { callId: call.id, ok: true };
}

/** 挂断：接通中/通话中任一方可发起 */
function end({ callId, userId, reason }) {
  const call = calls.get(callId);
  if (!call) return { callId, ok: false };
  if (userId !== call.callerId && userId !== call.calleeId) throw new Error('你不是通话参与方');

  const dur = durationOf(call);
  hub.broadcastToUser(otherSide(call, userId), {
    type: 'call:ended', callId: call.id, reason: reason || 'hangup', by: userId,
  });
  logCall(call, call.state === 'ringing' ? STATUS.CANCELED : STATUS.ENDED, dur);
  cleanup(call);
  return { callId: call.id, ok: true };
}

/**
 * SDP / ICE 中继。
 * type ∈ offer | answer | ice
 * 只在 connecting / active 阶段转发——ringing 阶段对方还没接，
 * 提前送 SDP 会被对端当成无效帧丢弃，不如直接拒绝。
 */
function relay({ callId, userId, type, data }) {
  const call = calls.get(callId);
  if (!call) throw new Error('通话已结束');
  if (userId !== call.callerId && userId !== call.calleeId) throw new Error('你不是通话参与方');
  if (call.state === 'ringing') throw new Error('对方尚未接听');

  if (type === 'answer' && call.state === 'connecting') call.state = 'active';

  hub.broadcastToUser(otherSide(call, userId), {
    type: 'call:' + type,
    callId: call.id,
    from: userId,
    data,
  });
  return { callId: call.id, state: call.state };
}

/**
 * 某用户的所有连接都断开时调用（hub 里已确认没有剩余 socket）。
 *
 * 不立刻拆通话，而是挂一个 20 秒宽限定时器：
 * - 期间重连回来 → [handleOnline] 取消定时器，通话继续（来电界面由
 *   [pendingForUser] 补推）
 * - 到期仍未归 → 才按"真的掉线"处理：振铃中判未接/取消，通话中判失败
 */
function handleOffline(userId) {
  const callId = userCall.get(userId);
  if (!callId) return;
  const call = calls.get(callId);
  if (!call) { userCall.delete(userId); return; }

  if (!call.offlineTimers) call.offlineTimers = new Map();
  // 同一端可能因 close + error 被通知两次，别叠定时器
  if (call.offlineTimers.has(userId)) return;

  const timer = setTimeout(() => {
    call.offlineTimers.delete(userId);
    // 人已经回来了（handleOnline 会清掉定时器，这里是双保险）
    if (hub.userSockets.has(userId)) return;
    if (!calls.has(call.id)) return;

    const peer = otherSide(call, userId);
    if (call.state === 'ringing') {
      hub.broadcastToUser(peer, { type: 'call:ended', callId: call.id, reason: 'unreachable', by: userId });
      logCall(call, call.calleeId === userId ? STATUS.MISSED : STATUS.CANCELED, 0);
    } else {
      hub.broadcastToUser(peer, { type: 'call:ended', callId: call.id, reason: 'peer-offline', by: userId });
      logCall(call, STATUS.FAILED, durationOf(call));
    }
    cleanup(call);
  }, OFFLINE_GRACE_MS);

  call.offlineTimers.set(userId, timer);
}

/**
 * 用户（重新）上线时调用。
 * 取消他的掉线宽限定时器 —— 人回来了，这通电话不该再被判死。
 * 振铃中的来电由 [pendingForUser] 负责把界面补推回去。
 */
function handleOnline(userId) {
  const callId = userCall.get(userId);
  if (!callId) return;
  const call = calls.get(callId);
  if (!call || !call.offlineTimers) return;
  const t = call.offlineTimers.get(userId);
  if (t) {
    clearTimeout(t);
    call.offlineTimers.delete(userId);
  }
}

/**
 * 用户（重新）上线时补推正在振铃的通话。
 *
 * 背景：外网环境下 WebSocket 容易被 NAT / 隧道静默回收，被叫断线期间
 * `call:incoming` 直接进了黑洞，用户完全无感知，只能等主叫挂断后
 * 在会话里看到一条"未接视频"。这里让被叫一重连就立刻补弹来电界面。
 *
 * - 被叫 → call:incoming
 * - 主叫 → call:ringing（客户端若已本地结束会安全忽略）
 * - 只补 ringing 阶段：已接通的通话没法靠补帧恢复，需要重新协商 SDP。
 */
function pendingForUser(userId) {
  const callId = userCall.get(userId);
  if (!callId) return null;
  const c = calls.get(callId);
  if (!c || c.state !== 'ringing') return null;

  const info = publicInfo(c);
  if (c.calleeId === userId) {
    return { type: 'call:incoming', ...info, from: c.callerId, resumed: true };
  }
  return { type: 'call:ringing', ...info, peerId: c.calleeId, resumed: true };
}

/** 给管理后台/健康检查看的运行态快照 */
function stats() {
  const list = [...calls.values()].map((c) => ({
    callId: c.id, conversationId: c.conversationId,
    callerId: c.callerId, calleeId: c.calleeId,
    mode: c.mode, state: c.state, duration: Math.round(durationOf(c)),
  }));
  return { active: list.length, calls: list };
}

module.exports = {
  invite, accept, reject, cancel, end, relay,
  handleOffline, handleOnline, pendingForUser, stats,
  RING_TIMEOUT_MS, OFFLINE_GRACE_MS, MODES, STATUS,
};
