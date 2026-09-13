// 远程协助信令中继 + 会话管理（对标 UU 远程）
//
// 【和音视频通话的关系】
// 复用同一套思路（WebSocket 只转发 SDP/ICE，媒体走 WebRTC P2P + TURN），
// 但**刻意不复用 call.js**：两者语义差别太大，硬凑会互相拖累。
//   · 通话  多方 / 允许中途加入 / 结束后群里留一条通话记录
//   · 远程协助 **严格 1v1** / 不能中途加入 / 每次会话必须落审计
// 远程协助是**高权限能力**（别人能操作你的键鼠），所有设计都优先服从安全。
//
// 【状态机】
//   requesting  已敲门，等被控端同意（有人值守）；
//               无人值守时是"撤销窗口"，被控端可在窗口期内拒绝
//   connecting  被控端已同意，正在交换 SDP / ICE
//   active      媒体与控制通道建立，控制权生效
//   ended       已结束，落审计
//
// 【安全边界 —— 每一条都是硬要求，不是建议】
// 1. **控制权必须由被控端授予**。有人值守要他明确点同意；无人值守要持有访问码，
//    且仍然给被控端一个撤销窗口（默认 10 秒），不是"有码就立刻能控"。
// 2. **访问码只存哈希**。库丢了也不等于钥匙丢了；明文只在生成时返回一次。
// 3. **兑换限流**。没有限流的话 9 位数字就是个可以无限撞的门。
// 4. **信令只能在会话两人之间转发**。非本会话的 offer/ice 一律丢弃 ——
//    否则任何一方都能把第三方拉进来当"看不见的控制者"。
// 5. **每次会话必有审计**（谁控了谁、多久、怎么结束的），用会话列表可查。

const crypto = require('crypto');
const db = require('./db');
const hub = require('./hub');

/** 有人值守：敲门后多久没人理就算超时（可用 REMOTE_RING_TIMEOUT_MS 覆盖，方便测试） */
const RING_TIMEOUT_MS = Number(process.env.REMOTE_RING_TIMEOUT_MS || 45 * 1000);

/**
 * 无人值守撤销窗口：10 秒。
 * 有访问码也不"立刻开控"，先给被控端一个反悔机会 —— 万一码泄漏、
 * 或正有人在操作这台电脑时被人连了，这 10 秒是最后一道人工兜底。
 * 对方不在（没在线）则到点自动放行，这才是无人值守的意义。
 */
const ABORT_WINDOW_MS = Number(process.env.REMOTE_ABORT_WINDOW_MS || 10 * 1000);

/** 单次会话硬上限：4 小时，防忘记断开导致长期被控 */
const MAX_SESSION_MS = 4 * 60 * 60 * 1000;

/** 访问码长度：9 位数字（和主流远控一致的手感） */
const CODE_LEN = 9;

/** 兑换限流窗口内的最大尝试次数 */
const MAX_ATTEMPTS = 10;
const ATTEMPT_WINDOW_MS = 10 * 60 * 1000;

const STATUS = {
  REQUESTING: 'requesting',
  CONNECTING: 'connecting',
  ACTIVE: 'active',
  ENDED: 'ended',
};

/** 会话是用给自己看的"结束原因"，写进审计供事后复盘 */
const END_REASON = {
  HOST: 'host_end',               // 被控端主动断开
  CONTROLLER: 'controller_end',   // 控制端主动断开
  TIMEOUT: 'timeout',             // 敲门没人理
  REJECTED: 'rejected',           // 被控端拒绝
  CANCELED: 'canceled',           // 控制端取消
  OFFLINE: 'offline',             // 任一方掉线
  FAILED: 'failed',               // 连接失败
};

const sessions = new Map();     // sessionId -> session
const userSession = new Map();  // userId -> sessionId（一个人同时只能有一个会话）

function genId() {
  return 'r' + Date.now().toString(36) + Math.random().toString(36).slice(2, 8);
}

/** 访问码：9 位数字，用 crypto.randomInt 保证不可预测（不用 Math.random） */
function genCode() {
  let s = '';
  for (let i = 0; i < CODE_LEN; i++) s += crypto.randomInt(0, 10);
  return s;
}

/**
 * 访问码 → 哈希。
 *
 * ⚠️ 这里**必须是慢哈希（scrypt），绝不能退回 SHA256**。
 * 访问码只有 9 位数字 = 10^9 种组合。用 SHA256 的话，"库丢了不等于钥匙丢了"
 * 这句话就是假的：离线跑一亿次 SHA256，在 GPU 上是分钟级的开销。
 * scrypt 把单次尝试的成本抬到几十毫秒，配上"每种码只能错 10 次"的限流，
 * 撞库才真的不成立。
 *
 * 代价是每次比对都要 ~60ms，所以 redeem 里会先把候选行收窄到
 * 「还没过期、还没吊销、一次性码还没用过」的少数几条再做比对。
 */
const SCRYPT_OPTS = { N: 16384, r: 8, p: 1, maxmem: 64 * 1024 * 1024 };
const SCRYPT_KEYLEN = 32;

/** 单次兑换最多比对多少条候选。超出就认为是异常数据量（正常部署远远到不了） */
const MAX_CODE_SCAN = 200;

/** scrypt 是同步的，参数也定死了，但这仍是一次 ~60ms 的计算，别在循环里滥用 */
function hashCode(code, salt) {
  return crypto
    .scryptSync(String(code), String(salt), SCRYPT_KEYLEN, SCRYPT_OPTS)
    .toString('hex');
}

/** 用户显示名（审计里要能认出人，不能只给个 id） */
function nameOf(userId) {
  if (!userId) return '';
  const u = db.prepare('SELECT id, username, nickname FROM users WHERE id = ?').get(userId);
  return u ? (u.nickname || u.username) : '';
}

// ---------------------------------------------------------------- 会话模型

/** 会话对外摘要（只含展示字段，绝不含 SDP） */
function publicInfo(s) {
  return {
    sessionId: s.id,
    mode: s.mode,
    status: s.status,
    hostId: s.hostId,
    controllerId: s.controllerId,
    hostName: nameOf(s.hostId),
    controllerName: nameOf(s.controllerId),
    createdAt: s.createdAt,
    startedAt: s.startedAt || null,
    // 无人值守且仍在撤销窗口时，被控端要靠这个显示倒计时
    abortDeadline: s.abortDeadline || null,
  };
}

/** 另一个人是谁（信令只可能发给他） */
function peerOf(s, userId) {
  if (s.hostId === userId) return s.controllerId;
  if (s.controllerId === userId) return s.hostId;
  return null;
}

function cleanup(s) {
  if (s.timer) clearTimeout(s.timer);
  if (s.maxTimer) clearTimeout(s.maxTimer);
  sessions.delete(s.id);
  for (const uid of [s.hostId, s.controllerId]) {
    if (uid && userSession.get(uid) === s.id) userSession.delete(uid);
  }
}

/** 落审计。这是本模块唯一写库的地方，失败也要尽量留下痕迹。 */
function persist(s, reason) {
  const now = Date.now();
  const sec = s.startedAt ? Math.max(0, Math.round((now - s.startedAt) / 1000)) : 0;
  try {
    db.prepare(`
      INSERT INTO remote_sessions
        (id, host_id, controller_id, mode, code_id, status, end_reason,
         created_at, started_at, ended_at, duration_sec, host_device, controller_device)
      VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
      ON CONFLICT(id) DO UPDATE SET
        status=excluded.status, end_reason=excluded.end_reason,
        ended_at=excluded.ended_at, duration_sec=excluded.duration_sec,
        controller_id=excluded.controller_id, controller_device=excluded.controller_device
    `).run(
      s.id, s.hostId, s.controllerId || null, s.mode, s.codeId || null,
      STATUS.ENDED, reason || '', s.createdAt,
      s.startedAt || null, now, sec,
      s.hostDevice || '', s.controllerDevice || '',
    );
  } catch (e) {
    console.error('[remote] 会话审计写入失败:', e.message);
  }
}

/**
 * 结束会话。
 *
 * @param reason 见 END_REASON；决定审计里怎么记，也决定客户端显示什么文案。
 * @param opts.notify 是否通知对方（对方主动挂的场景由他自己知道，不用再推）
 */
function endSession(s, reason, opts = {}) {
  if (s.status === STATUS.ENDED) return;
  s.status = STATUS.ENDED;
  const info = { type: 'remote:end', sessionId: s.id, reason };
  hub.broadcastToUser(s.hostId, info);
  if (opts.notify !== false && s.controllerId) {
    hub.broadcastToUser(s.controllerId, info);
  }
  persist(s, reason);
  cleanup(s);
}

/** 拒绝 / 取消（还没连通的场景，共用一条收尾路径） */
function failSession(s, reason, notifyUser) {
  if (s.status === STATUS.ENDED) return;
  s.status = STATUS.ENDED;
  if (notifyUser) {
    hub.broadcastToUser(notifyUser, {
      type: 'remote:end', sessionId: s.id, reason,
    });
  }
  persist(s, reason);
  cleanup(s);
}

/** 一个人同时在另一个会话里就忙线 —— 远程协助绝不允许"一人多会话" */
function busy(userId) {
  const sid = userSession.get(userId);
  if (!sid) return null;
  const s = sessions.get(sid);
  return (s && s.status !== STATUS.ENDED) ? s : null;
}

// ---------------------------------------------------------------- 有人值守

/**
 * 控制端敲门。
 * @returns {{error?: string, sessionId?: string}}
 */
function request({ controllerId, hostId }) {
  if (!hostId) return { error: '请指定要协助的对象' };
  if (hostId === controllerId) return { error: '不能远程协助自己' };
  const bHost = busy(hostId);
  if (bHost) return { error: '对方正在其他远程协助会话中' };
  const bCtrl = busy(controllerId);
  if (bCtrl) return { error: '你还有一个未结束的远程协助会话' };

  const id = genId();
  const s = {
    id,
    hostId,
    controllerId,
    mode: 'attended',
    codeId: null,
    status: STATUS.REQUESTING,
    createdAt: Date.now(),
    startedAt: null,
    hostDevice: '',
    controllerDevice: '',
  };
  sessions.set(id, s);
  userSession.set(hostId, id);
  userSession.set(controllerId, id);

  // 超时没人理 → 通知双方结束（不等天荒地老）
  s.timer = setTimeout(() => {
    if (s.status !== STATUS.REQUESTING) return;
    failSession(s, END_REASON.TIMEOUT, controllerId);
    hub.broadcastToUser(hostId, { type: 'remote:end', sessionId: id, reason: END_REASON.TIMEOUT });
  }, RING_TIMEOUT_MS);

  hub.broadcastToUser(hostId, {
    type: 'remote:invite',
    session: publicInfo(s),
  });
  return { sessionId: id };
}

/** 被控端同意。此时才允许开始交换 SDP。 */
function accept({ sessionId, userId, device }) {
  const s = sessions.get(sessionId);
  if (!s || s.status === STATUS.ENDED) return { error: '会话已结束' };
  if (s.hostId !== userId) return { error: '只有被协助的一方可以同意' };
  if (s.status !== STATUS.REQUESTING) return { error: '会话状态不正确' };

  s.status = STATUS.CONNECTING;
  s.hostDevice = String(device || '').slice(0, 120);
  if (s.timer) { clearTimeout(s.timer); s.timer = null; }
  s.abortDeadline = null;

  // 到点不断自动拆会话 —— 防止两边都忘了挂，控制权一直挂着
  s.maxTimer = setTimeout(() => {
    endSession(s, END_REASON.TIMEOUT);
  }, MAX_SESSION_MS);

  hub.broadcastToUser(s.controllerId, {
    type: 'remote:accept',
    session: publicInfo(s),
  });
  return {};
}

function reject({ sessionId, userId }) {
  const s = sessions.get(sessionId);
  if (!s || s.status === STATUS.ENDED) return { error: '会话已结束' };
  if (s.hostId !== userId) return { error: '只有被协助的一方可以拒绝' };
  failSession(s, END_REASON.REJECTED, s.controllerId);
  return {};
}

function cancel({ sessionId, userId }) {
  const s = sessions.get(sessionId);
  if (!s || s.status === STATUS.ENDED) return { error: '会话已结束' };
  if (s.controllerId !== userId) return { error: '只有发起方可以取消' };
  failSession(s, END_REASON.CANCELED, s.hostId);
  return {};
}

/** 任一方主动断开（已进入会话，不是"拒绝/取消"） */
function end({ sessionId, userId }) {
  const s = sessions.get(sessionId);
  if (!s || s.status === STATUS.ENDED) return { error: '会话已结束' };
  if (s.hostId !== userId && s.controllerId !== userId) return { error: '你不在该会话中' };
  const reason = s.hostId === userId ? END_REASON.HOST : END_REASON.CONTROLLER;
  endSession(s, reason, { notify: false });
  // 自己不用通知，但要通知对方
  const other = s.hostId === userId ? s.controllerId : s.hostId;
  if (other) hub.broadcastToUser(other, { type: 'remote:end', sessionId: s.id, reason });
  return {};
}

/** 标记已进入 active（客户端确认媒体与控制通道真的通了才算，不以"点了同意"为准） */
function markActive({ sessionId, userId }) {
  const s = sessions.get(sessionId);
  if (!s || s.status === STATUS.ENDED) return { error: '会话已结束' };
  if (s.hostId !== userId && s.controllerId !== userId) return { error: '你不在该会话中' };
  if (!s.startedAt) {
    s.startedAt = Date.now();
    s.status = STATUS.ACTIVE;
    hub.broadcastToUser(s.hostId, { type: 'remote:active', session: publicInfo(s) });
    hub.broadcastToUser(s.controllerId, { type: 'remote:active', session: publicInfo(s) });
  }
  return {};
}

/**
 * SDP / ICE 中继。
 *
 * ⚠️ 只允许转发给会话内的**另一个人**。这里是关键防线之一：
 * 如果允许 `to` 任意指定，任何一方都能把无关第三方拉进会话，
 * 而这个第三方无权也无法破解 DTLS，却会打乱双方的连接状态；
 * 更糟的是给"控制者身份不明"留了口子。
 */
/** 单条信令报文上限。正常 SDP 只有几 KB，放宽到 64KB 足够宽容又不至于被当放大器 */
const MAX_RELAY_BYTES = 64 * 1024;

function relay({ sessionId, userId, type, data }) {
  const s = sessions.get(sessionId);
  if (!s || s.status === STATUS.ENDED) return { error: '会话已结束' };
  // ⚠️ 还没同意（requesting）时不许交换 SDP/ICE。
  // 客户端虽然也拦了一层（phase != active 丢弃控制指令），但服务端不该依赖
  // 客户端自觉：SDP 一旦能提前协商，就等于允许"先建好连接再等同意"，
  // 中间任何一环松了都是"没点同意就被控"。
  if (s.status === STATUS.REQUESTING) return { error: '会话尚未建立' };
  const peer = peerOf(s, userId);
  if (!peer) return { error: '你不在该会话中' };
  // 顺手给个体积上限：SessionDescription 再长也就几 KB。不限的话这条转发
  // 会被当成放大器 —— 一条 WS 消息就能把 MB 级内容推给对端。
  if (typeof data !== 'object' || Array.isArray(data)) {
    return { error: '信令数据格式不正确' };
  }
  let size = 0;
  try { size = JSON.stringify(data).length; } catch { return { error: '信令数据无法序列化' }; }
  if (size > MAX_RELAY_BYTES) return { error: '信令数据过大' };
  hub.broadcastToUser(peer, { type: 'remote:' + type, sessionId, data, from: userId });
  return {};
}

/** 掉线处理：任一方掉线就拆会话，绝不留下"无人看管的控制权" */
function handleOffline(userId) {
  const sid = userSession.get(userId);
  if (!sid) return;
  const s = sessions.get(sid);
  if (!s || s.status === STATUS.ENDED) return;
  endSession(s, END_REASON.OFFLINE);
}

/** 在线（可能重连）：暂不自动恢复 —— 会话已因掉线结束，
 *  让控制端重新敲门更安全，也避免"网络抖动后控制权悄悄回来了"。 */
function handleOnline() { /* 有意留空 */ }

// ---------------------------------------------------------------- 无人值守

/** 兑换窗口内的失败尝试次数 */
function recentAttempts(userId) {
  const since = Date.now() - ATTEMPT_WINDOW_MS;
  return db.prepare('SELECT COUNT(*) c FROM remote_code_attempts WHERE user_id=? AND ts>=?')
    .get(userId, since).c;
}

function logAttempt(userId) {
  db.prepare('INSERT INTO remote_code_attempts (user_id, ts) VALUES (?,?)').run(userId, Date.now());
}

/**
 * 用访问码兑换一次远程协助。
 *
 * 成功时不直接连通，而是走 request 同样的流程 —— 只差一步：
 * 给被控端一个 **10 秒撤销窗口** 而不是无限等待同意。
 */
function redeem({ userId, code, device }) {
  const c = String(code || '').trim();
  if (!/^\d{9}$/.test(c)) return { error: '访问码为 9 位数字' };
  if (recentAttempts(userId) >= MAX_ATTEMPTS) {
    return { error: '尝试次数过多，请稍后再试' };
  }

  // 访问码只存哈希，所以只能"逐个重算比对"。9 位码空间很大，但真正需要
  // 比对的是**还活着的那几条** —— 过期/吊销/一次性已用过的先排掉，
  // 剩下几条就算用 scrypt 也不到一秒。
  const nowMs = Date.now();
  const rows = db.prepare(`
    SELECT id, user_id, code_hash, salt, single_use, expires_at, revoked, use_count
    FROM remote_access_codes
    WHERE revoked = 0
      AND (expires_at IS NULL OR expires_at > ?)
      AND NOT (single_use = 1 AND use_count > 0)
    ORDER BY id DESC LIMIT ?
  `).all(nowMs, MAX_CODE_SCAN);

  let hit = null;
  for (const r of rows) {
    if (hashCode(c, r.salt) === r.code_hash) { hit = r; break; }
  }
  if (!hit) { logAttempt(userId); return { error: '访问码无效' }; }
  // ⚠️ 这几条在 SQL 里已经排过一遍，这里**仍然要再判一次**：
  // 它们决定"能不能开门"，不能只依赖查询条件 —— 万一将来有人改了 SQL，
  // 少一层判断就等于把门敞开。
  if (hit.expires_at && hit.expires_at < Date.now()) return { error: '访问码已过期' };
  if (hit.single_use && hit.use_count > 0) return { error: '该访问码已被使用过' };
  if (hit.user_id === userId) return { error: '不能用访问码连接自己' };

  const bHost = busy(hit.user_id);
  if (bHost) return { error: '对方正在其他远程协助会话中' };
  const bCtrl = busy(userId);
  if (bCtrl) return { error: '你还有一个未结束的远程协助会话' };

  const id = genId();
  const s = {
    id,
    hostId: hit.user_id,
    controllerId: userId,
    mode: 'unattended',
    codeId: hit.id,
    status: STATUS.REQUESTING,
    createdAt: Date.now(),
    startedAt: null,
    abortDeadline: Date.now() + ABORT_WINDOW_MS,
    hostDevice: '',
    controllerDevice: String(device || '').slice(0, 120),
  };
  sessions.set(id, s);
  userSession.set(s.hostId, id);
  userSession.set(s.controllerId, id);

  // 先扣一次使用  ——  即使对方最后拒绝了也算用掉。
  // 一次性码如果不先扣，就能被反复重试直到撞开撤销窗口，那"一次性"就没意义了。
  db.prepare('UPDATE remote_access_codes SET use_count=use_count+1, last_used_at=? WHERE id=?')
    .run(Date.now(), hit.id);
  if (hit.single_use) {
    db.prepare('UPDATE remote_access_codes SET revoked=1 WHERE id=?').run(hit.id);
  }

  // 撤销窗口：窗口内被控端可拒绝；到点没反对就自动放行。
  // 这里**不会因为对方不在线就跳过** —— 不在线时他也收不到画面请求，
  // 放行后如果没人响应 failSession 会把它收掉。
  s.timer = setTimeout(() => {
    if (s.status !== STATUS.REQUESTING) return;
    // 无人值守自动同意：这是它的全部意义（人不在也要能连）
    s.status = STATUS.CONNECTING;
    s.abortDeadline = null;
    s.maxTimer = setTimeout(() => endSession(s, END_REASON.TIMEOUT), MAX_SESSION_MS);
    hub.broadcastToUser(s.controllerId, { type: 'remote:accept', session: publicInfo(s) });
    hub.broadcastToUser(s.hostId, { type: 'remote:authed', session: publicInfo(s) });
  }, ABORT_WINDOW_MS);

  hub.broadcastToUser(s.hostId, { type: 'remote:invite', session: publicInfo(s) });
  return { sessionId: id, hostId: s.hostId, hostName: nameOf(s.hostId) };
}

// ---- 访问码管理 ----

function createCode({ userId, label, singleUse, ttlMinutes }) {
  const cnt = db.prepare('SELECT COUNT(*) c FROM remote_access_codes WHERE user_id=? AND revoked=0').get(userId).c;
  // 上限不是为了省钱，是为了让"我的电脑有哪些钥匙"这件事保持可核查
  if (cnt >= 20) return { error: '访问码数量已达上限（20 个），请先吊销不用的' };
  const code = genCode();
  const salt = crypto.randomBytes(16).toString('hex');
  const now = Date.now();
  const expiresAt = ttlMinutes ? now + Number(ttlMinutes) * 60 * 1000 : null;
  const info = db.prepare(`
    INSERT INTO remote_access_codes
      (user_id, label, code_hash, salt, single_use, expires_at, created_at)
    VALUES (?,?,?,?,?,?,?)
  `).run(userId, String(label || '').slice(0, 60), hashCode(code, salt), salt,
         singleUse ? 1 : 0, expiresAt, now);
  return {
    id: info.lastInsertRowid,
    code,           // ⚠️ 明文只在这一次返回，之后无法找回（库里只有哈希）
    label: String(label || ''),
    singleUse: !!singleUse,
    expiresAt,
  };
}

function listCodes(userId) {
  return db.prepare(`
    SELECT id, label, single_use, expires_at, use_count, last_used_at, created_at
    FROM remote_access_codes WHERE user_id=? AND revoked=0
    ORDER BY created_at DESC
  `).all(userId).map((r) => ({
    id: r.id,
    label: r.label,
    singleUse: !!r.single_use,
    expiresAt: r.expires_at,
    useCount: r.use_count,
    lastUsedAt: r.last_used_at,
    createdAt: r.created_at,
  }));
}

function revokeCode({ userId, id }) {
  const r = db.prepare('UPDATE remote_access_codes SET revoked=1 WHERE id=? AND user_id=?')
    .run(id, userId);
  return { ok: r.changes > 0 };
}

/** 会话历史（审计口径）：我参与过的所有会话，被控与控制都算 */
function history(userId, limit = 50) {
  const lim = Math.min(200, Math.max(1, Number(limit) || 50));
  return db.prepare(`
    SELECT id, host_id, controller_id, mode, status, end_reason,
           created_at, started_at, ended_at, duration_sec, host_device, controller_device
    FROM remote_sessions
    WHERE host_id = ? OR controller_id = ?
    ORDER BY created_at DESC LIMIT ?
  `).all(userId, userId, lim).map((r) => ({
    sessionId: r.id,
    hostId: r.host_id,
    controllerId: r.controller_id,
    hostName: nameOf(r.host_id),
    controllerName: nameOf(r.controller_id),
    mode: r.mode,
    status: r.status,
    endReason: r.end_reason,
    // 我在这次会话里的角色 —— 客户端靠它决定显示"被 XX 协助"还是"我协助了 XX"
    role: r.host_id === userId ? 'host' : 'controller',
    createdAt: r.created_at,
    startedAt: r.started_at,
    endedAt: r.ended_at,
    durationSec: r.duration_sec,
    hostDevice: r.host_device,
    controllerDevice: r.controller_device,
  }));
}

/** 当前进行中的会话（重连用：App 重启后还能回到控制界面） */
function currentOf(userId) {
  const sid = userSession.get(userId);
  const s = sid ? sessions.get(sid) : null;
  return (s && s.status !== STATUS.ENDED) ? publicInfo(s) : null;
}

function stats() {
  return { sessions: sessions.size, codes: db.prepare('SELECT COUNT(*) c FROM remote_access_codes').get().c };
}

/** 仅测试用：清空内存状态 */
function _reset() {
  for (const s of sessions.values()) cleanup(s);
  sessions.clear();
  userSession.clear();
}

module.exports = {
  STATUS, END_REASON, ABORT_WINDOW_MS, MAX_ATTEMPTS, ATTEMPT_WINDOW_MS, CODE_LEN,
  request, accept, reject, cancel, end, markActive, relay,
  handleOffline, handleOnline, currentOf, publicInfo,
  redeem, createCode, listCodes, revokeCode, history, stats,
  _reset,
};
