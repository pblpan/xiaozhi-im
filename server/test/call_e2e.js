// 通话信令端到端测试
//
// 起一个隔离的服务端实例（独立 DATA_DIR / 端口），用两个真实 WebSocket 客户端
// 把 1v1 通话的每条路径都跑一遍：正常接通、拒接、忙线、主叫取消、掉线、
// 越权与参数校验，最后核对通话记录是否真的落库。
//
//   node test/call_e2e.js
//
// 之所以不用单元测试框架：通话的坑基本都在"两端 + 服务端状态机"的交互上，
// 真实 WS 往返比 mock 更能说明问题。

const { spawn } = require('child_process');
const path = require('path');
const fs = require('fs');
const os = require('os');
const WebSocket = require('ws');

const PORT = 3699;
const BASE = `http://127.0.0.1:${PORT}`;
const SERVER_DIR = path.resolve(__dirname, '..');
const DATA_DIR = path.join(os.tmpdir(), 'xiaozhi-call-e2e-' + Date.now());

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

  /** 断言在给定时间内"不会"收到某类帧 */
  async none(type, ms = 700) {
    await sleep(ms);
    return !this.frames.some((f) => f.type === type && !f.__used);
  }

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

  // ---- 准备数据：三个用户 + 两个单聊会话 ----
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

  const dmAB = (await api('GET', `/api/conversations/dm/${bob.id}`, { token: alice.token })).body.conversationId;
  const dmBC = (await api('GET', `/api/conversations/dm/${carol.id}`, { token: bob.token })).body.conversationId;
  const dmAC = (await api('GET', `/api/conversations/dm/${carol.id}`, { token: alice.token })).body.conversationId;

  const A = new Client(alice.token, 'alice');
  const B = new Client(bob.token, 'bob');
  const C = new Client(carol.token, 'carol');
  await Promise.all([A.ready(), B.ready(), C.ready()]);
  await Promise.all([A.next('connected'), B.next('connected'), C.next('connected')]);

  // ================================================ 场景 1：正常接通 + 挂断
  console.log('\n[场景1] 正常接通：invite → incoming → accept → offer/answer/ice → end');
  A.send({ type: 'call:invite', conversationId: dmAB, calleeId: bob.id, mode: 'video' });
  const ringing = await A.next('call:ringing');
  ok('主叫收到 call:ringing', !!ringing.callId);
  const callId = ringing.callId;

  const incoming = await B.next('call:incoming');
  ok('被叫收到 call:incoming', incoming.callId === callId);
  ok('来电带主叫昵称与模式', incoming.callerName === 'ALICE' && incoming.mode === 'video',
    `callerName=${incoming.callerName} mode=${incoming.mode}`);
  ok('来电带 conversationId', incoming.conversationId === dmAB);

  B.send({ type: 'call:accept', callId });
  const accepted = await A.next('call:accepted');
  ok('主叫收到 call:accepted', accepted.callId === callId && accepted.by === bob.id);
  ok('被叫自己的其他端收到 call:handled', await B.next('call:handled').then(() => true).catch(() => false));

  // SDP / ICE 中继
  A.send({ type: 'call:offer', callId, data: { sdp: 'FAKE_OFFER', type: 'offer' } });
  const offer = await B.next('call:offer');
  ok('offer 转发到被叫', offer.data && offer.data.sdp === 'FAKE_OFFER' && offer.from === alice.id);

  B.send({ type: 'call:answer', callId, data: { sdp: 'FAKE_ANSWER', type: 'answer' } });
  const answer = await A.next('call:answer');
  ok('answer 转发到主叫', answer.data && answer.data.sdp === 'FAKE_ANSWER');

  A.send({ type: 'call:ice', callId, data: { candidate: 'cand-1', sdpMid: '0', sdpMLineIndex: 0 } });
  const ice = await B.next('call:ice');
  ok('ICE 候选转发到被叫', ice.data && ice.data.candidate === 'cand-1');

  A.send({ type: 'call:end', callId });
  const ended = await B.next('call:ended');
  ok('挂断通知到被叫', ended.reason === 'hangup');

  // 落库校验
  const hist = await api('GET', `/api/conversations/${dmAB}/messages?limit=20`, { token: alice.token });
  const items = (hist.body.items || hist.body.messages || []);
  const rec = items.find((m) => m.kind === 'call');
  ok('会话里留下通话记录消息', !!rec, JSON.stringify(hist.body).slice(0, 160));
  if (rec) {
    const c = JSON.parse(rec.content);
    ok('记录状态为 ended', c.status === 'ended', c.status);
    ok('记录带通话模式', c.mode === 'video', c.mode);
  }

  // 通话结束后可以再次呼叫（状态已释放）
  A.send({ type: 'call:invite', conversationId: dmAB, calleeId: bob.id, mode: 'audio' });
  const ringing2 = await A.next('call:ringing');
  ok('挂断后可再次发起通话', !!ringing2.callId);
  const incoming2 = await B.next('call:incoming');
  ok('第二次来电为语音模式', incoming2.mode === 'audio', incoming2.mode);
  A.send({ type: 'call:cancel', callId: ringing2.callId });
  const canceled = await B.next('call:canceled');
  ok('主叫取消 → 被叫收到 call:canceled', canceled.reason === 'canceled');

  // ================================================ 场景 2：拒接
  console.log('\n[场景2] 拒接');
  A.send({ type: 'call:invite', conversationId: dmAB, calleeId: bob.id, mode: 'video' });
  const r3 = await A.next('call:ringing');
  await B.next('call:incoming');
  B.send({ type: 'call:reject', callId: r3.callId });
  const rej = await A.next('call:rejected');
  ok('主叫收到 call:rejected', rej.reason === 'declined', rej.reason);

  // ================================================ 场景 3：忙线
  console.log('\n[场景3] 忙线');
  A.send({ type: 'call:invite', conversationId: dmAB, calleeId: bob.id, mode: 'video' });
  const r4 = await A.next('call:ringing');
  await B.next('call:incoming');
  B.send({ type: 'call:accept', callId: r4.callId });
  await A.next('call:accepted');

  // bob 正在通话中，carol 呼他 → 应收到 busy 且不建立通话
  C.send({ type: 'call:invite', conversationId: dmBC, calleeId: bob.id, mode: 'audio' });
  const busy = await C.next('call:busy');
  ok('对方通话中 → 主叫收到 call:busy', !!busy);
  ok('忙线时不向被叫推来电', await B.none('call:incoming'));

  // 自己已在通话中再呼叫 → 服务端回 error 帧
  A.send({ type: 'call:invite', conversationId: dmAB, calleeId: bob.id, mode: 'audio' });
  const errFrame = await A.next('error');
  ok('自己通话中再呼叫 → error 帧', /通话中/.test(errFrame.message || ''), errFrame.message);

  A.send({ type: 'call:end', callId: r4.callId });
  await B.next('call:ended');

  // ================================================ 场景 4：掉线
  console.log('\n[场景4] 被叫掉线');
  A.send({ type: 'call:invite', conversationId: dmAB, calleeId: bob.id, mode: 'video' });
  const r5 = await A.next('call:ringing');
  await B.next('call:incoming');
  B.close();
  const dead = await A.next('call:ended', 6000);
  ok('被叫掉线 → 主叫收到 call:ended(unreachable)', dead.reason === 'unreachable', dead.reason);

  // ================================================ 场景 5：越权与校验
  console.log('\n[场景5] 越权与参数校验');
  // carol 试图用别人的会话呼叫（不是该会话成员）
  C.send({ type: 'call:invite', conversationId: dmAB, calleeId: bob.id, mode: 'video' });
  const e1 = await C.next('error');
  ok('非会话成员呼叫被拒', /不在该会话/.test(e1.message || ''), e1.message);

  // 呼叫自己
  C.send({ type: 'call:invite', conversationId: dmBC, calleeId: carol.id, mode: 'video' });
  const e2 = await C.next('error');
  ok('呼叫自己被拒', /不正确/.test(e2.message || ''), e2.message);

  // 伪造 callId 发 offer
  C.send({ type: 'call:offer', callId: 'not-exist', data: { sdp: 'x', type: 'offer' } });
  const e3 = await C.next('error');
  ok('未知 callId 被拒', /已结束/.test(e3.message || ''), e3.message);

  // 对方还没接就发 SDP
  A.send({ type: 'call:invite', conversationId: dmAC, calleeId: carol.id, mode: 'video' });
  const r6 = await A.next('call:ringing');
  await C.next('call:incoming');
  A.send({ type: 'call:offer', callId: r6.callId, data: { sdp: 'x', type: 'offer' } });
  const e4 = await A.next('error');
  ok('未接听就发 offer 被拒', /尚未接听/.test(e4.message || ''), e4.message);
  A.send({ type: 'call:cancel', callId: r6.callId });
  await C.next('call:canceled');

  // 机器人不可呼叫（admin 种子账号是普通用户，这里用不存在的 id 代替）
  A.send({ type: 'call:invite', conversationId: dmAB, calleeId: 999999, mode: 'video' });
  const e5 = await A.next('error');
  ok('呼叫不存在用户被拒', /对方不在该会话|对方不存在/.test(e5.message || ''), e5.message);

  // 缺参数：老版本会把 undefined 直接喂给 SQLite，报
  // "Provided value cannot be bound to SQLite parameter 1."，客户端根本看不懂。
  // 这里守住：必须回可读的中文错误。
  A.send({ type: 'call:invite', calleeId: bob.id, mode: 'video' });
  const e6 = await A.next('error');
  ok('缺 conversationId → 可读错误', /参数不正确|会话/.test(e6.message || ''), e6.message);
  ok('缺参不再暴露 SQLite 底层错误', !/SQLite|bound/i.test(e6.message || ''), e6.message);

  A.send({ type: 'call:invite', conversationId: 'abc', calleeId: bob.id, mode: 'video' });
  const e7 = await A.next('error');
  ok('非法 conversationId → 可读错误', /参数不正确/.test(e7.message || ''), e7.message);

  A.send({ type: 'call:invite', conversationId: dmAB, mode: 'video' });
  const e8 = await A.next('error');
  ok('缺 calleeId → 可读错误', /通话对象不正确/.test(e8.message || ''), e8.message);

  // ================================================ 汇总
  console.log(`\n${'='.repeat(52)}`);
  console.log(`通过 ${passed} 项，失败 ${failed} 项`);
  if (failed) {
    console.log('失败明细：');
    failures.forEach((f) => console.log('  - ' + f));
  }
  console.log('='.repeat(52));

  A.close(); B.close(); C.close();
  shutdown();
  process.exit(failed ? 1 : 0);
}

main().catch((e) => {
  console.error('\n测试中断:', e.message);
  process.exit(1);
});
