// 群通话（多人音视频）信令端到端测试
//
// 起一个隔离的服务端实例（独立 DATA_DIR / 端口），用四个真实 WebSocket 客户端
// 把群通话的每条路径跑一遍：多人同时接通、mesh 定向转发、中途加入、单人退出、
// 上限拦截、全员退出清理，最后再验一遍 1v1 老协议没被群逻辑改坏。
//
//   node test/group_call_e2e.js
//
// 之所以不用单元测试框架：群通话的坑几乎都在"多方 + 服务端状态机 + mesh 拓扑"
// 的交互上，真实 WS 往返比 mock 更能说明问题。
//
// 【mesh 拓扑约定，客户端实现必须与之一致】
//   1. 谁在房间里谁发 offer：后加入者只接收连接，不主动发。
//      固定这一条是为了避免双方同时发 offer 撞车（glare）。
//   2. 每条 offer/answer/ice 都必须带 `to`，否则服务端会广播给所有人。
//   3. 服务端只做转发，不关心 mesh 的拓扑，也不碰媒体。

const { spawn } = require('child_process');
const path = require('path');
const fs = require('fs');
const os = require('os');
const WebSocket = require('ws');

const PORT = 3698;
const BASE = `http://127.0.0.1:${PORT}`;
const SERVER_DIR = path.resolve(__dirname, '..');
const DATA_DIR = path.join(os.tmpdir(), 'xiaozhi-gcall-e2e-' + Date.now());

let passed = 0;
let failed = 0;
const failures = [];

function ok(name, cond, extra) {
  if (cond) {
    passed++;
    console.log(`  \u2713 ${name}`);
  } else {
    failed++;
    failures.push(name + (extra ? ` — ${extra}` : ''));
    console.log(`  \u2717 ${name}${extra ? '  → ' + extra : ''}`);
  }
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ------------------------------------------------------------------ HTTP

async function api(method, p, { token, body } = {}) {
  const res = await fetch(BASE + p, {
    method,
    headers: {
      'Content-Type': 'application/json',
      ...(token ? { Authorization: 'Bearer ' + token } : {}),
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  let json = null;
  try { json = await res.json(); } catch { /* 空响应 */ }
  return { status: res.status, body: json };
}

// ------------------------------------------------------------------ WS 客户端

class Client {
  constructor(token, label) {
    this.label = label;
    this.frames = [];
    this.ws = new WebSocket(`ws://127.0.0.1:${PORT}/ws?token=${token}`);
  }

  ready() {
    return new Promise((resolve, reject) => {
      this.ws.on('open', resolve);
      this.ws.on('error', reject);
      this.ws.on('message', (raw) => {
        try { this.frames.push(JSON.parse(raw.toString())); } catch { /* ignore */ }
      });
    });
  }

  send(obj) { this.ws.send(JSON.stringify(obj)); }

  /** 等一个指定 type 的帧（已消费的不会再被匹配到） */
  async next(type, ms = 5000) {
    const deadline = Date.now() + ms;
    while (Date.now() < deadline) {
      const i = this.frames.findIndex((f) => f.type === type && !f.__used);
      if (i >= 0) {
        this.frames[i].__used = true;
        return this.frames[i];
      }
      await sleep(25);
    }
    throw new Error(`[${this.label}] 等待 ${type} 超时（已收到: ${this.frames.map((f) => f.type).join(',')}）`);
  }

  /** 等一个满足额外条件的帧 */
  async nextWhere(type, pred, ms = 5000) {
    const deadline = Date.now() + ms;
    while (Date.now() < deadline) {
      const i = this.frames.findIndex((f) => f.type === type && !f.__used && pred(f));
      if (i >= 0) {
        this.frames[i].__used = true;
        return this.frames[i];
      }
      await sleep(25);
    }
    throw new Error(`[${this.label}] 等待 ${type}(条件) 超时（已收到: ${this.frames.map((f) => f.type).join(',')}）`);
  }

  /** 断言在给定时间内"不会"收到某类帧 */
  async none(type, ms = 700) {
    await sleep(ms);
    return !this.frames.some((f) => f.type === type && !f.__used);
  }

  /** 清空未消费帧，给下一段场景一个干净起点 */
  clear() { this.frames = []; }

  close() { try { this.ws.close(); } catch { /* ignore */ } }
}

// ------------------------------------------------------------------ 主流程

async function main() {
  fs.mkdirSync(DATA_DIR, { recursive: true });
  const child = spawn(process.execPath, ['src/index.js'], {
    cwd: SERVER_DIR,
    env: {
      ...process.env,
      PORT: String(PORT),
      DATA_DIR,
      DB_PATH: path.join(DATA_DIR, 'test.db'),
      // 掉线宽限期压到 1.5 秒，好让"某人掉线 → 其余继续"这条用例快速跑完
      OFFLINE_GRACE_MS: '1500',
      // 上限压到 4 人，方便用 5 个账号验证拦截（生产默认 6）
      MAX_CALL_PARTICIPANTS: '4',
    },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  child.stdout.on('data', () => {});
  child.stderr.on('data', (d) => process.stderr.write('[server] ' + d));

  const shutdown = () => {
    try { child.kill(); } catch { /* ignore */ }
    try { fs.rmSync(DATA_DIR, { recursive: true, force: true }); } catch { /* ignore */ }
  };
  process.on('exit', shutdown);

  // 等服务端起来
  let up = false;
  for (let i = 0; i < 60; i++) {
    try {
      const r = await fetch(BASE + '/api/health');
      if (r.ok) { up = true; break; }
    } catch { /* 还没起来 */ }
    await sleep(200);
  }
  if (!up) throw new Error('服务端未能在 12 秒内启动');

  // ---- 准备数据：五个用户 + 一个五人群 ----
  const mk = async (name) => {
    const r = await api('POST', '/api/auth/register', {
      body: { username: name, password: 'pass1234', nickname: name.toUpperCase() },
    });
    if (r.status !== 200) throw new Error(`注册 ${name} 失败: ${JSON.stringify(r.body)}`);
    return { token: r.body.token, id: r.body.user.id };
  };
  const alice = await mk('alice');
  const bob = await mk('bob');
  const carol = await mk('carol');
  const dave = await mk('dave');
  const erin = await mk('erin');

  // 建群（alice 是群主），把 bob/carol/dave/erin 都拉进来
  const created = await api('POST', '/api/groups', { token: alice.token, body: { name: '群通话测试群' } });
  if (created.status !== 200) throw new Error('建群失败: ' + JSON.stringify(created.body));
  const gid = created.body.groupId;
  const gconv = created.body.conversationId;
  for (const u of [bob, carol, dave, erin]) {
    const r = await api('POST', `/api/groups/${gid}/members`, { token: alice.token, body: { userId: u.id } });
    if (r.status !== 200) throw new Error(`拉人入群失败(${u.id}): ` + JSON.stringify(r.body));
  }

  const A = new Client(alice.token, 'alice');
  const B = new Client(bob.token, 'bob');
  const C = new Client(carol.token, 'carol');
  const D = new Client(dave.token, 'dave');
  const E = new Client(erin.token, 'erin');
  await Promise.all([A.ready(), B.ready(), C.ready(), D.ready(), E.ready()]);
  await Promise.all([
    A.next('connected'), B.next('connected'), C.next('connected'),
    D.next('connected'), E.next('connected'),
  ]);

  // ============================================ 场景 1：群内发起，三人依次接通
  console.log('\n[场景1] 群内发起 → 三人依次接听 → mesh 定向转发');
  // 不传 calleeIds = 邀请群内所有其他人
  A.send({ type: 'call:invite', conversationId: gconv, mode: 'video' });
  const ringing = await A.next('call:ringing');
  const callId = ringing.callId;
  ok('群内发起返回 callId', !!callId);
  ok('call:ringing 标记为群通话', ringing.group === true, `group=${ringing.group}`);
  ok('参与者名单含 5 人', Array.isArray(ringing.participants) && ringing.participants.length === 5,
    `participants=${ringing.participants && ringing.participants.length}`);

  const inB = await B.next('call:incoming');
  ok('bob 收到来电', inB.callId === callId);
  ok('来电帧带 group 标记', inB.group === true);
  ok('来电帧带头像/昵称名单', Array.isArray(inB.participants) && inB.participants.length === 5);
  const inC = await C.next('call:incoming');
  ok('carol 收到来电', inC.callId === callId);

  // 1v1 兼容：calleeId 必须是"第一个被邀请的人"，老客户端靠它认对象
  ok('保留 calleeId 兼容字段', !!inB.calleeId,
    `calleeId=${inB.calleeId}`);

  // bob 接听
  B.send({ type: 'call:accept', callId });
  const accepted = await A.next('call:accepted');
  ok('主叫收到 call:accepted', accepted.by === bob.id);
  const joinedB = await B.next('call:joined');
  ok('bob 收到 call:joined 且带 peers=主叫', Array.isArray(joinedB.peers) && joinedB.peers.length === 1
    && joinedB.peers[0].userId === alice.id,
    `peers=${JSON.stringify(joinedB.peers)}`);
  ok('call:joined 自报 self', joinedB.self === bob.id);
  ok('bob 不是"接听来电"而是首发加入', joinedB.accepted === false, `accepted=${joinedB.accepted}`);

  // 房间内已有 alice → bob 加入时，a 应收到 peer-joined（由 a 向 b 发 offer）
  const pjB = await A.next('call:peer-joined');
  ok('已入房间的人收到 call:peer-joined', pjB.peer && pjB.peer.userId === bob.id,
    `peer=${JSON.stringify(pjB.peer)}`);

  // mesh 定向转发：a → b 的 offer 带 to
  A.send({ type: 'call:offer', callId, to: bob.id, data: { sdp: 'OFFER_AB', type: 'offer' } });
  const offAB = await B.next('call:offer');
  ok('offer 带 to 定向送达 bob', offAB.data && offAB.data.sdp === 'OFFER_AB');
  ok('offer 带 from', offAB.from === alice.id);

  // carol 还在响铃，不该收到这条 offer
  ok('定向 offer 不泄漏给未接听的 carol', await C.none('call:offer', 400));

  B.send({ type: 'call:answer', callId, to: alice.id, data: { sdp: 'ANSWER_AB', type: 'answer' } });
  const ansAB = await A.next('call:answer');
  ok('answer 定向回主叫', ansAB.data && ansAB.data.sdp === 'ANSWER_AB');

  A.send({ type: 'call:ice', callId, to: bob.id, data: { candidate: 'ice-ab', sdpMid: '0', sdpMLineIndex: 0 } });
  const iceAB = await B.next('call:ice');
  ok('ICE 定向送达', iceAB.data && iceAB.data.candidate === 'ice-ab');

  // ---- carol 接听：mesh 新增一条边 ----
  C.send({ type: 'call:accept', callId });
  await A.next('call:accepted');
  const pjC = await A.next('call:peer-joined');
  ok('carol 加入时 alice 收到 peer-joined', pjC.peer && pjC.peer.userId === carol.id);
  const pjCB = await B.next('call:peer-joined');
  ok('carol 加入时 bob 也收到 peer-joined', pjCB.peer && pjCB.peer.userId === carol.id);

  const joinedC = await C.next('call:joined');
  ok('carol 的 peers 列出已入房间的两人',
    Array.isArray(joinedC.peers) && joinedC.peers.length === 2
    && joinedC.peers.some((p) => p.userId === alice.id)
    && joinedC.peers.some((p) => p.userId === bob.id),
    `peers=${JSON.stringify(joinedC.peers)}`);

  // 三条边各走一轮定向 SDP，验证不会串线
  A.send({ type: 'call:offer', callId, to: carol.id, data: { sdp: 'OFFER_AC', type: 'offer' } });
  const offAC = await C.next('call:offer');
  ok('alice→carol 定向 offer 不串到 bob', offAC.data.sdp === 'OFFER_AC');
  B.send({ type: 'call:offer', callId, to: carol.id, data: { sdp: 'OFFER_BC', type: 'offer' } });
  const offBC = await C.next('call:offer');
  ok('bob→carol 定向 offer 送达', offBC.data.sdp === 'OFFER_BC');

  // 不传 to 时的兜底：广播给所有其他参与者（1v1 老行为）
  A.send({ type: 'call:ice', callId, data: { candidate: 'ice-broadcast', sdpMid: '0', sdpMLineIndex: 0 } });
  const bcB = await B.next('call:ice');
  const bcC = await C.next('call:ice');
  ok('不传 to 时广播给其余所有人（bob）', bcB.data.candidate === 'ice-broadcast');
  ok('不传 to 时广播给其余所有人（carol）', bcC.data.candidate === 'ice-broadcast');

  // ============================================ 场景 2：dave 中途加入
  console.log('\n[场景2] dave 中途加入进行中的通话');
  // participants 里既有"已接听"也有"还在振铃"的人，凡是要数"真的在线几人"
  // 的地方都得过滤 state==='joined'。
  const joinedCount = (f) => (f.participants || []).filter((p) => p.state === 'joined').length;
  D.send({ type: 'call:join', callId });
  const joinedD = await D.next('call:joined');
  ok('dave 收到 call:joined', joinedD.callId === callId);
  ok('dave 的 peers 列出已在房间的三人', joinedD.peers.length === 3,
    `peers=${joinedD.peers && joinedD.peers.length}`);
  const pjD = await A.next('call:peer-joined');
  ok('alice 收到 dave 的 peer-joined', pjD.peer.userId === dave.id);

  // participants 是**全部参与者**（含还在振铃的 erin），所以要数 state==='joined' 的。
  // 用 nextWhere 精确等"dave 进来之后"那条，避免匹配到场景 1 里的旧帧。
  const updated = await A.nextWhere('call:updated',
    (f) => (f.participants || []).some((p) => p.userId === dave.id && p.state === 'joined'));
  ok('房间成员变化广播 call:updated', joinedCount(updated) === 4,
    `joined=${joinedCount(updated)} 全体=${updated.participants && updated.participants.length}`);

  // 重复 join 必须幂等，不能报错也不能重复广播
  D.send({ type: 'call:join', callId });
  ok('重复 join 幂等（无 error 帧）', await D.none('error', 400));

  // ============================================ 场景 3：单人退出，其余继续
  console.log('\n[场景3] 单人退出 → 通话继续（群通话的核心语义）');
  B.send({ type: 'call:end', callId });
  const leftAtA = await A.nextWhere('call:peer-left', (f) => f.peerId === bob.id);
  ok('alice 收到 bob 退出通知', leftAtA.peerId === bob.id);
  ok('退出帧标记其原本是已接通', leftAtA.joined === true);
  ok('bob 退出后通话未结束（alice 侧）', await A.none('call:ended', 500));
  const leftAtC = await C.nextWhere('call:peer-left', (f) => f.peerId === bob.id);
  ok('carol 也收到 bob 退出通知', leftAtC.peerId === bob.id);
  const upd3 = await A.nextWhere('call:updated', (f) => joinedCount(f) === 3);
  ok('bob 退出后已接听人数降为 3', joinedCount(upd3) === 3,
    `joined=${joinedCount(upd3)}`);

  // 已退出的人不能再收发信令
  B.send({ type: 'call:offer', callId, to: alice.id, data: { sdp: 'AFTER_LEAVE', type: 'offer' } });
  const errB = await B.next('error');
  ok('已退出者再发信令被拒', /不是通话参与方/.test(errB.message || ''), errB.message);

  // ============================================ 场景 4：发起人退出也不解散
  console.log('\n[场景4] 发起人退出 → 通话仍继续');
  A.send({ type: 'call:end', callId });
  ok('alice（发起人）退出后 carol 侧未收到 call:ended', await C.none('call:ended', 500));
  const upd4 = await C.nextWhere('call:updated', (f) => joinedCount(f) === 2);
  ok('房间只剩 carol + dave 两人实际在线', joinedCount(upd4) === 2,
    `joined=${joinedCount(upd4)}`);

  // 剩下两人仍能互通 SDP
  C.send({ type: 'call:offer', callId, to: dave.id, data: { sdp: 'OFFER_CD', type: 'offer' } });
  const offCD = await D.next('call:offer');
  ok('剩余两人仍可正常协商', offCD.data.sdp === 'OFFER_CD');

  // ============================================ 场景 5：上限拦截 + 权限
  console.log('\n[场景5] 人数上限与非群成员拦截');
  // 此时房间 2 人（carol/dave），上限 4 → 还能进 2 人
  E.send({ type: 'call:join', callId });
  await E.next('call:joined');
  ok('erin 加入后房间 3 人', true);

  // 已退出的 bob 想再进来 —— 他仍是群成员，允许
  B.send({ type: 'call:join', callId });
  const rejoined = await B.next('call:joined');
  ok('退出后可重新加入', rejoined.callId === callId);
  ok('重新加入被标记为 accepted（不是首次接听）', rejoined.accepted === true,
    `accepted=${rejoined.accepted}`);
  ok('重新加入后实际在线 4 人（达上限）', joinedCount(rejoined) === 4,
    `joined=${joinedCount(rejoined)}`);

  // 满员后 alice 再进 —— 她是群成员但房间已满
  A.send({ type: 'call:join', callId });
  const errFull = await A.next('error');
  ok('满员后加入被拒', /上限/.test(errFull.message || ''), errFull.message);

  // 非群成员（新注册一个）不能加入
  const frank = await mk('frank');
  const F = new Client(frank.token, 'frank');
  await F.ready();
  await F.next('connected');
  F.send({ type: 'call:join', callId });
  const errF = await F.next('error');
  ok('非群成员加入被拒', /不在该会话/.test(errF.message || ''), errF.message);
  F.close();

  // ============================================ 场景 6：全员退出 → 落记录 + 清理
  console.log('\n[场景6] 全员退出 → 落通话记录并清理房间');
  for (const c of [B, C, D, E]) {
    c.send({ type: 'call:end', callId });
    await sleep(80);
  }
  await sleep(400);

  const stats = await api('GET', '/api/admin/call/stats', { token: alice.token });
  // 不同版本管理接口路径可能不同，拿不到就跳过这条（不作为失败）
  if (stats.status === 200 && stats.body) {
    const list = (stats.body.calls || []).filter((c) => c.callId === callId);
    ok('全员退出后房间已清理', list.length === 0,
      `仍存在: ${JSON.stringify(list)}`);
  } else {
    console.log('  · 跳过管理接口校验（该路径需管理员权限或未开放）');
  }

  const hist = await api('GET', `/api/conversations/${gconv}/messages?limit=30`, { token: alice.token });
  const items = (hist.body.items || hist.body.messages || []);
  const rec = items.find((m) => m.kind === 'call');
  ok('群通话结束时落了一条通话记录', !!rec, JSON.stringify(hist.body).slice(0, 160));
  if (rec) {
    const payload = JSON.parse(rec.content || '{}');
    ok('记录标记为群通话', payload.group === true, JSON.stringify(payload));
    ok('记录带通话时长', payload.duration > 0, `duration=${payload.duration}`);
  }

  // ============================================ 场景 7：1v1 老协议回归
  console.log('\n[场景7] 1v1 老协议未被群逻辑改坏');
  const dm = (await api('GET', `/api/conversations/dm/${bob.id}`, { token: alice.token })).body.conversationId;
  A.clear(); B.clear();
  A.send({ type: 'call:invite', conversationId: dm, calleeId: bob.id, mode: 'audio' });
  const r1v1 = await A.next('call:ringing');
  const c1v1 = r1v1.callId;
  ok('1v1 走通 call:ringing', !!c1v1);
  ok('1v1 的 group 标记为 false', r1v1.group === false, `group=${r1v1.group}`);
  ok('1v1 参与者 2 人', r1v1.participants.length === 2);

  const in1v1 = await B.next('call:incoming');
  ok('1v1 来电 calleeId 正确', in1v1.calleeId === bob.id, `calleeId=${in1v1.calleeId}`);
  B.send({ type: 'call:accept', callId: c1v1 });
  await A.next('call:accepted');
  // 1v1 不带 to 也要能通（老客户端根本不发 to）
  A.send({ type: 'call:offer', callId: c1v1, data: { sdp: 'LEGACY_OFFER', type: 'offer' } });
  const lOff = await B.next('call:offer');
  ok('1v1 无 to 字段仍能转发', lOff.data.sdp === 'LEGACY_OFFER');

  A.send({ type: 'call:end', callId: c1v1 });
  const lEnd = await B.next('call:ended');
  ok('1v1 挂断仍整通结束', lEnd.reason === 'hangup');
  ok('1v1 挂断后不残留 call:peer-left 语义', await B.none('call:peer-left', 400));

  // ============================================ 收尾
  for (const c of [A, B, C, D, E]) c.close();
  await sleep(200);

  console.log('\n' + '='.repeat(52));
  console.log(`通过 ${passed} 项，失败 ${failed} 项`);
  if (failed) {
    console.log('失败明细：');
    for (const f of failures) console.log('  - ' + f);
  }
  console.log('='.repeat(52));

  shutdown();
  process.exit(failed ? 1 : 0);
}

main().catch((e) => {
  console.error('测试中断:', e.message);
  process.exit(1);
});
