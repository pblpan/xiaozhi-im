// 音视频通话信令中继（1v1 + 群通话）
//
// 服务端不碰媒体：只把 SDP / ICE 在通话参与者之间转发。媒体走 WebRTC P2P mesh，
// 所以通话本身不占服务端带宽（同网段 host candidate 直连即可；
// 跨 NAT 需要 TURN 中转时由 TURN 服务承载）。
//
// 【模型演进 v0.7.0】
//
// 老版本是严格双人模型：call 上只有 callerId / calleeId 两个字段，
// userCall 保证"一个人同时只能有一通"。改成多方后：
//
//   participants: Map<userId, { state, joinedAt }>   state ∈ invited | joined | left
//
// 但 **callerId / calleeId 仍然保留**，含义不变：
//   - 1v1 通话里它们就是双方（老客户端完全按这个渲染来电界面，不能动）
//   - 群通话里 callerId = 发起人，calleeId = 第一个被邀请的人
//     （只为兼容老客户端在群里的展示，新客户端一律读 participants）
//
// 状态机：ringing → connecting → active → ended
//   ringing     已呼叫，等待有人接听（超时 45s 自动结束）
//   connecting  至少一人已接听，正在交换 SDP / ICE
//   active      收到 answer，媒体通道建立
//
// 群通话的"谁还在"由 participants 决定，而不是由 state 决定 ——
// 三个人里走了一个，通话必须继续（这正是老双人模型做不到的地方）。
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

/** 单通话最大参与者数。P2P mesh 的连接数 = n(n-1)/2，6 人是 15 条，
 *  再多手机端扛不住（每条连接都要独立编解码 + 上行带宽）。 */
const MAX_PARTICIPANTS = Number(process.env.MAX_CALL_PARTICIPANTS || 6);

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

/**
 * 是否 1v1。
 *
 * ⚠️ **只用 `call.group` 判断，绝不能看 participants.size**。
 * `group` 在 invite 时就定死、全程不变；而 participants 会被 end/reject/
 * handleOffline 删人，群通话收尾那一刻可能已经删到一个不剩 —— 那时
 * participants.size = 0，用 size 判断会把群通话误判成 1v1，于是：
 *   · 通话记录不带 group 标记（客户端显示成普通 1v1 记录）
 *   · end() 走 1v1 分支直接整通结束（"最后一个人挂断"碰巧对，但语义错）
 * 这个坑在场景 6 的全员退出用例里被测试抓出来过一次。
 */
function isOneToOne(call) {
  return !call.group;
}

/** 参与者里除 userId 之外的所有人（1v1 就是那唯一的一个对方） */
function othersOf(call, userId) {
  const out = [];
  for (const uid of call.participants.keys()) {
    if (uid !== userId) out.push(uid);
  }
  return out;
}

/**
 * 房间内当前"应该出现在画面上"的人：已接听 + 未退出。
 * 尚未接听的邀请对象不算，否则发起人会对着一个空框等。
 */
function activeMembers(call) {
  const out = [];
  for (const [uid, p] of call.participants) {
    if (p.state === 'joined') out.push(uid);
  }
  return out;
}

/** 是否还有人在通话里 */
function hasAnyone(call) {
  for (const p of call.participants.values()) {
    if (p.state === 'joined' || p.state === 'invited') return true;
  }
  return false;
}

/** 通话对外摘要（不含 SDP，只用于界面展示） */
function publicInfo(call) {
  const u = db.prepare('SELECT id, username, nickname, avatar FROM users WHERE id = ?').get(call.callerId);
  // 参与者名单：新客户端用它渲染"通话中 x 人"和各自的昵称头像
  const rows = [];
  for (const [uid, p] of call.participants) {
    const m = db.prepare('SELECT id, username, nickname, avatar FROM users WHERE id = ?').get(uid);
    rows.push({
      userId: uid,
      name: m ? (m.nickname || m.username) : '',
      avatar: m ? m.avatar : null,
      state: p.state,
    });
  }
  return {
    callId: call.id,
    conversationId: call.conversationId,
    mode: call.mode,
    callerId: call.callerId,
    // 1v1 兼容字段：老客户端靠它认来电对象
    calleeId: call.calleeId,
    callerName: u ? (u.nickname || u.username) : '',
    callerAvatar: u ? u.avatar : null,
    // 群通话字段
    group: !isOneToOne(call),
    participants: rows,
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
  for (const uid of [call.callerId, call.calleeId]) {
    if (userCall.get(uid) === call.id) userCall.delete(uid);
  }
  // 参与者可能不止这两个（群里后加入的人），一并摘掉
  if (call.participants) {
    for (const uid of call.participants.keys()) {
      if (userCall.get(uid) === call.id) userCall.delete(uid);
    }
  }
}

/**
 * 通话记录消息：落进会话，会话成员都能看到。
 *
 * 注意 sendMessage 会广播给"除 senderId 外的会话成员"；群通话里这已经覆盖了
 * 其余参与者，但**发起人自己**不在其中，所以要显式补一条给他（含他的多端）。
 */
function logCall(call, status, durationSec) {
  try {
    const payload = {
      mode: call.mode,
      status,
      duration: Math.max(0, Math.round(durationSec || 0)),
      caller: call.callerId,
      callee: call.calleeId,
      // 群通话才有意义，1v1 时省略以保持记录格式不变
      ...(isOneToOne(call) ? {} : {
        group: true,
        participantCount: activeMembers(call).length || call.participants.size,
      }),
    };
    const msg = sendMessage({
      conversationId: call.conversationId,
      senderId: call.callerId,
      kind: 'call',
      content: JSON.stringify(payload),
    });
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

/**
 * 校验会话可通话。
 *
 * 支持两种：
 *  - dm    单聊，calleeId 必填且必须是会话成员（老行为，原样保留）
 *  - group 群聊，显式传 calleeIds 数组；不传则表示"向群内所有其他成员发起"
 *
 * 返回 { conversationId, targets, group }
 */
function resolveConversation(conversationId, callerId, calleeId, calleeIds) {
  // 先做入参体检：缺参数 / 非数字时直接给出可读错误。
  // 否则 undefined 会被塞进 SQLite 绑定，底层抛
  // "Provided value cannot be bound to SQLite parameter 1."，客户端完全看不懂。
  const convId = Number(conversationId);
  if (!Number.isInteger(convId) || convId <= 0) throw new Error('通话参数不正确：缺少会话');

  const conv = db.prepare('SELECT id, type FROM conversations WHERE id = ?').get(convId);
  if (!conv) throw new Error('会话不存在');
  if (conv.type !== 'dm' && conv.type !== 'group') throw new Error('该会话不支持通话');

  const members = db.prepare('SELECT user_id FROM conversation_members WHERE conversation_id = ?')
    .all(convId).map((r) => r.user_id);
  if (!members.includes(callerId)) throw new Error('你不在该会话中');

  // 计划邀请谁：显式名单优先，其次单个 calleeId，最后（群里）全体其他人
  let wanted;
  if (Array.isArray(calleeIds) && calleeIds.length) {
    wanted = calleeIds.map(Number);
  } else if (calleeId != null && calleeId !== '') {
    const one = Number(calleeId);
    // 单聊里"呼叫自己"要在这里就点破。往下走会被循环静默跳过，
    // 最后报一句"没有可以呼叫的对象"，用户完全不知道是自己填错了。
    if (one === Number(callerId)) throw new Error('通话对象不正确：不能呼叫自己');
    wanted = [one];
  } else if (conv.type === 'group') {
    wanted = members.filter((m) => m !== callerId);
  } else {
    throw new Error('通话对象不正确：缺少通话对象');
  }

  const targets = [];
  for (const uid of wanted) {
    if (!Number.isInteger(uid) || uid <= 0 || uid === Number(callerId)) continue;
    if (!members.includes(uid)) throw new Error('对方不在该会话中');
    const peer = db.prepare('SELECT id, is_bot FROM users WHERE id = ?').get(uid);
    if (!peer) throw new Error('对方不存在');
    if (peer.is_bot) continue; // 机器人静默跳过，不该因为群里有个机器人就整个发起失败
    if (!targets.includes(uid)) targets.push(uid);
  }
  if (!targets.length) throw new Error('没有可以呼叫的对象');

  return { conversationId: conv.id, targets, group: conv.type === 'group' };
}

/** 找一个会话里正在进行中的通话（用于"加入"） */
function roomOf(conversationId) {
  for (const c of calls.values()) {
    if (c.conversationId === Number(conversationId) && c.state !== 'ended') return c;
  }
  return null;
}

/**
 * 发起通话。
 * - 自己被占线 → 直接报错（客户端弹提示）
 * - 部分对象被占线 → 跳过他们，能叫几个叫几个（群通话不该被一个人的忙线搞崩）
 * - 全部被占线 → 发 call:busy 并落一条"对方忙线"记录
 */
function invite({ conversationId, callerId, calleeId, calleeIds, mode }) {
  const m = MODES.includes(String(mode)) ? String(mode) : 'video';
  const { conversationId: cid, targets, group } = resolveConversation(
    conversationId, callerId, calleeId, calleeIds,
  );

  if (userCall.has(callerId)) throw new Error('你正在通话中，请先挂断');

  // 群里已经有一通在跑 → 转成"加入"，而不是开第二通
  const existing = roomOf(cid);
  if (existing) {
    const err = join({ callId: existing.id, userId: callerId });
    if (err) throw new Error(err);
    return { callId: existing.id, joined: true, busy: false };
  }

  // 挑出没被占线的对象
  const free = [];
  const busyList = [];
  for (const uid of targets) {
    if (userCall.has(uid)) busyList.push(uid); else free.push(uid);
  }

  if (!free.length) {
    const busyCall = {
      id: genId(), conversationId: cid, callerId, calleeId: targets[0], mode: m,
      state: 'ended', answeredAt: 0, participants: new Map(), group,
    };
    logCall(busyCall, STATUS.BUSY, 0);
    hub.broadcastToUser(callerId, { type: 'call:busy', calleeId: targets[0], mode: m });
    return { callId: null, busy: true };
  }

  const participants = new Map();
  participants.set(callerId, { state: 'joined', joinedAt: Date.now() });
  for (const uid of free) participants.set(uid, { state: 'invited', joinedAt: 0 });

  const call = {
    id: genId(),
    conversationId: cid,
    callerId,
    // 1v1 兼容：第一个被邀请的人。群通话里这个字段只作展示兜底。
    calleeId: free[0],
    mode: m,
    group,
    state: 'ringing',
    createdAt: Date.now(),
    answeredAt: 0,
    participants,
    timer: null,
    maxTimer: null,
    // userId -> 掉线宽限定时器
    offlineTimers: new Map(),
  };
  calls.set(call.id, call);
  for (const uid of participants.keys()) userCall.set(uid, call.id);

  const info = publicInfo(call);
  // 被叫可能多端在线：全部振铃，任一端接听后其余端收到 call:handled 自行收起
  for (const uid of free) {
    hub.broadcastToUser(uid, { type: 'call:incoming', ...info, from: callerId });
  }
  hub.broadcastToUser(callerId, { type: 'call:ringing', ...info, peerId: free[0] });
  // 忙线的人让客户端知道"叫了但没叫到"，界面能提示"1 人忙线未加入"
  for (const uid of busyList) {
    hub.broadcastToUser(callerId, { type: 'call:busy', calleeId: uid, mode: m, silent: true });
  }

  call.timer = setTimeout(() => {
    if (call.state !== 'ringing') return;
    for (const uid of free) {
      hub.broadcastToUser(uid, { type: 'call:canceled', callId: call.id, reason: 'timeout' });
    }
    hub.broadcastToUser(callerId, { type: 'call:timeout', callId: call.id });
    logCall(call, STATUS.MISSED, 0);
    cleanup(call);
  }, RING_TIMEOUT_MS);

  return { callId: call.id, busy: false };
}

/**
 * 加入一通已在进行中的通话（群里"我也要进去"）。
 * 返回 null 表示成功，否则返回错误文案。
 */
function join({ callId, userId }) {
  const call = calls.get(callId);
  if (!call) return '通话已结束';

  // 已经在房间里（joined）：幂等返回成功（重连 / 重复点击不该报错）。
  //
  // ⚠️ 这里**不能**把 `invited` 也算作"已在房间" —— 受邀但还没接听的人调
  // join/accept 必须真的完成状态跃迁。老写法用 `exist.state !== 'left'` 判断，
  // 结果被叫点"接听"时直接 return null 什么都没做，participants 里他还是
  // invited、call.state 还停在 ringing，接着主叫发 offer 就被
  // `state === 'ringing'` 挡回去 —— 现象是"点了接听，双方都卡住"。
  const exist = call.participants.get(userId);
  if (exist && exist.state === 'joined') return null;

  if (userCall.has(userId) && userCall.get(userId) !== call.id) return '你正在通话中，请先挂断';

  // 先确认他确实是这个会话的成员
  const member = db.prepare('SELECT user_id FROM conversation_members WHERE conversation_id = ? AND user_id = ?')
    .get(call.conversationId, userId);
  if (!member) return '你不在该会话中';

  // 上限只看**真的接听了**的人。
  //
  // ⚠️ 不能用 participants.size —— 那里面还有一堆 invited（群里收到来电但还没
  // 点"接听"的人）。群里 10 个人收到来电、只有 3 个人接了，房间实际只占 3 个
  // mesh 位；按 size 判断会让第 4 个接听的人被"人数已满"挡住，而他前面根本
  // 没有 4 个人真的在通话。
  if (activeMembers(call).length >= MAX_PARTICIPANTS) {
    return `通话人数已达上限（${MAX_PARTICIPANTS} 人）`;
  }

  call.participants.set(userId, { state: 'joined', joinedAt: Date.now() });
  userCall.set(userId, call.id);

  // 首个人加入时把振铃定时器摘掉，并启动硬上限
  if (call.state === 'ringing') {
    if (call.timer) { clearTimeout(call.timer); call.timer = null; }
    call.state = 'connecting';
    if (!call.answeredAt) call.answeredAt = Date.now();
  }
  if (!call.maxTimer) {
    call.maxTimer = setTimeout(() => {
      for (const uid of call.participants.keys()) {
        hub.broadcastToUser(uid, { type: 'call:ended', callId: call.id, reason: 'timeout' });
      }
      logCall(call, STATUS.ENDED, durationOf(call));
      cleanup(call);
    }, MAX_DURATION_MS);
  }

  const info = publicInfo(call);
  const me = info.participants.find((p) => p.userId === userId);

  // 告知已在房间里的人"来了个新的" —— 由他们在本地建连并**向新人发 offer**。
  // 规则固定为"已在房间里的人发"，这样不会两边同时发 offer 撞车（glare）。
  for (const uid of call.participants.keys()) {
    if (uid === userId) continue;
    if (call.participants.get(uid).state === 'left') continue;
    hub.broadcastToUser(uid, {
      type: 'call:peer-joined', callId: call.id, peer: me, group: call.group,
    });
  }

  // 告诉新人"房间里现在有谁"（他不需要给别人发 offer，只等别人来连）
  hub.broadcastToUser(userId, {
    type: 'call:joined',
    ...info,
    self: userId,
    // 只在房间里、已经接听过的人
    peers: info.participants.filter((p) => p.userId !== userId && p.state === 'joined'),
    // 首次接听来电（之前是 invited）→ false，界面走"接听"文案；
    // 中途加入 / 退出后重进 → true，界面走"已加入"文案。
    // 注意 exist 可能是 undefined（退出过再进来），那种情况同样算 true。
    accepted: !(exist && exist.state === 'invited'),
  });

  // 全员广播一次成员变化：界面上的"通话中 x 人"、参会者头像墙靠它刷新。
  // 注意 join 里已经有 peer-joined 了，那条是给"要建连的人"的，
  // 这条是给"只需要更新名单的人"的，两者受众不同、不能合并。
  for (const uid of call.participants.keys()) {
    if (uid === userId) continue;
    hub.broadcastToUser(uid, { type: 'call:updated', ...info });
  }

  return null;
}

/** 接听：等同 join，但只允许受邀者；已 ringing 阶段或仍是 invited 状态都可以 */
function accept({ callId, userId }) {
  const call = calls.get(callId);
  if (!call) throw new Error('通话已结束');
  const p = call.participants.get(userId);
  if (!p) throw new Error('只有被叫方可以接听');
  if (p.state === 'joined') throw new Error('你已经在这个通话中');
  // 通话已经进到连通阶段、但他还是 invited（群里别人先接了）——依然允许接听，
  // 这正是"后到的人也接进来"需要的行为。
  if (call.state === 'ended') throw new Error('通话已结束');

  const err = join({ callId, userId });
  if (err) throw new Error(err);

  // 1v1 老协议：主叫必须收到 call:accepted 才会去发 offer
  hub.broadcastToUser(call.callerId, { type: 'call:accepted', callId: call.id, by: userId });
  // 被叫的其他端（多设备）停止振铃
  hub.broadcastToUser(userId, { type: 'call:handled', callId: call.id, by: userId });

  return { callId: call.id, state: call.state };
}

/** 拒接：仅受邀者、仅 ringing 阶段 */
function reject({ callId, userId, reason }) {
  const call = calls.get(callId);
  if (!call) return { callId, ok: false };
  const p = call.participants.get(userId);
  if (!p || p.state === 'joined') throw new Error('只有被叫方可以拒接');

  const busy = reason === 'busy';
  p.state = 'left';
  call.participants.delete(userId);
  if (userCall.get(userId) === call.id) userCall.delete(userId);
  hub.broadcastToUser(userId, { type: 'call:handled', callId: call.id, by: userId });

  // 1v1：直接整通结束（老行为）
  if (isOneToOne(call) || !hasAnyone(call)) {
    hub.broadcastToUser(call.callerId, {
      type: 'call:rejected', callId: call.id, by: userId, reason: busy ? 'busy' : 'declined',
    });
    logCall(call, busy ? STATUS.BUSY : STATUS.REJECTED, 0);
    cleanup(call);
    return { callId: call.id, ok: true };
  }

  // 群通话：只是这个人不来了，告知其他人即可
  const info = publicInfo(call);
  for (const uid of call.participants.keys()) {
    hub.broadcastToUser(uid, { type: 'call:peer-left', callId: call.id, peerId: userId, reason: busy ? 'busy' : 'declined' });
    hub.broadcastToUser(uid, { type: 'call:updated', ...info });
  }
  return { callId: call.id, ok: true };
}

/** 主叫取消：仅主叫、仅 ringing 阶段 */
function cancel({ callId, userId }) {
  const call = calls.get(callId);
  if (!call) return { callId, ok: false };
  if (call.callerId !== userId) throw new Error('只有主叫方可以取消');
  if (call.state !== 'ringing') throw new Error('对方已接听，请使用挂断');

  for (const uid of call.participants.keys()) {
    if (uid === userId) continue;
    hub.broadcastToUser(uid, { type: 'call:canceled', callId: call.id, reason: 'canceled' });
  }
  logCall(call, STATUS.CANCELED, 0);
  cleanup(call);
  return { callId: call.id, ok: true };
}

/**
 * 挂断 / 退出通话。
 *
 * 1v1：整通结束（老行为不变）。
 * 群通话：只把自己移出，其余人继续 —— 这是群通话与 1v1 最本质的差别。
 * 发起人退出也不结束通话（否则"发起人手机没电，全群陪跑"）。
 * 只有一个人都不剩了才真正收尾。
 */
function end({ callId, userId, reason }) {
  const call = calls.get(callId);
  if (!call) return { callId, ok: false };
  if (!call.participants.has(userId)) throw new Error('你不是通话参与方');

  const wasJoined = call.participants.get(userId).state === 'joined';
  const dur = durationOf(call);

  if (isOneToOne(call)) {
    for (const uid of othersOf(call, userId)) {
      hub.broadcastToUser(uid, {
        type: 'call:ended', callId: call.id, reason: reason || 'hangup', by: userId,
      });
    }
    logCall(call, call.state === 'ringing' ? STATUS.CANCELED : STATUS.ENDED, dur);
    cleanup(call);
    return { callId: call.id, ok: true };
  }

  // ---- 群通话：单人退出 ----
  call.participants.delete(userId);
  if (userCall.get(userId) === call.id) userCall.delete(userId);

  if (!hasAnyone(call)) {
    logCall(call, call.state === 'ringing' ? STATUS.CANCELED : STATUS.ENDED, dur);
    cleanup(call);
    return { callId: call.id, ok: true };
  }

  const info = publicInfo(call);
  for (const uid of call.participants.keys()) {
    hub.broadcastToUser(uid, {
      type: 'call:peer-left', callId: call.id, peerId: userId,
      joined: wasJoined, reason: reason || 'hangup',
    });
    hub.broadcastToUser(uid, { type: 'call:updated', ...info });
  }
  return { callId: call.id, ok: true };
}

/**
 * SDP / ICE 中继。
 * type ∈ offer | answer | ice
 *
 * `to` 字段：mesh 场景必须 —— 三个人的房间里，A 的 offer 只该给 B 或只给 C，
 * 广播给所有人会让第三人收到一份跟自己无关的 SDP 并搞乱连接状态。
 * 不传 `to` 时退化为"发给所有其他参与者"（1v1 正好只有一个，行为与老版本一致）。
 */
function relay({ callId, userId, type, data, to }) {
  const call = calls.get(callId);
  if (!call) throw new Error('通话已结束');
  if (!call.participants.has(userId)) throw new Error('你不是通话参与方');
  if (call.state === 'ringing') throw new Error('对方尚未接听');

  const targets = to != null && to !== '' ? [Number(to)] : othersOf(call, userId);
  for (const uid of targets) {
    if (uid === userId) continue;
    // 只发给真的在房间里的人，别把信令投给已经退出/还没接的人
    const p = call.participants.get(uid);
    if (!p || p.state === 'left') continue;
    hub.broadcastToUser(uid, {
      type: 'call:' + type,
      callId: call.id,
      from: userId,
      data,
    });
  }

  if (type === 'answer' && call.state === 'connecting') call.state = 'active';
  return { callId: call.id, state: call.state, delivered: targets.length };
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

    const p = call.participants.get(userId);
    const wasInvited = p && p.state === 'invited';

    if (isOneToOne(call)) {
      const peer = othersOf(call, userId)[0];
      if (call.state === 'ringing') {
        if (peer) hub.broadcastToUser(peer, { type: 'call:ended', callId: call.id, reason: 'unreachable', by: userId });
        logCall(call, wasInvited ? STATUS.MISSED : STATUS.CANCELED, 0);
      } else {
        if (peer) hub.broadcastToUser(peer, { type: 'call:ended', callId: call.id, reason: 'peer-offline', by: userId });
        logCall(call, STATUS.FAILED, durationOf(call));
      }
      cleanup(call);
      return;
    }

    // ---- 群通话：一个人掉线，其余继续 ----
    call.participants.delete(userId);
    if (userCall.get(userId) === call.id) userCall.delete(userId);
    if (!hasAnyone(call)) {
      logCall(call, STATUS.ENDED, durationOf(call));
      cleanup(call);
      return;
    }
    const info = publicInfo(call);
    for (const uid of call.participants.keys()) {
      hub.broadcastToUser(uid, {
        type: 'call:peer-left', callId: call.id, peerId: userId, reason: 'offline',
      });
      hub.broadcastToUser(uid, { type: 'call:updated', ...info });
    }
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
  const p = c.participants.get(userId);
  if (p && p.state === 'invited') {
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
    group: !!c.group,
    participants: activeMembers(c),
    participantCount: c.participants.size,
  }));
  return { active: list.length, calls: list, maxParticipants: MAX_PARTICIPANTS };
}

module.exports = {
  invite, accept, reject, cancel, end, join, relay,
  handleOffline, handleOnline, pendingForUser, stats, roomOf,
  RING_TIMEOUT_MS, OFFLINE_GRACE_MS, MODES, STATUS, MAX_PARTICIPANTS,
};
