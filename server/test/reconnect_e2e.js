// 断线重连 / 心跳 / ICE 下发 端到端测试
//
// 覆盖 2026-09 外网通话排障的修复：
//   ① WS 心跳 ping/pong（客户端靠它识别"半死连接"）
//   ② 被叫掉线后重连 → 补推来电界面（不再直接判未接）
//   ③ 主叫掉线后重连 → 恢复"正在呼叫"
//   ④ 掉线宽限期到期仍未归 → 才判未接
//   ⑤ 已接通 / 已结束的通话不补推
//   ⑥ GET /api/call/ice 下发 STUN 列表
//
//   node test/reconnect_e2e.js

const { spawn } = require('child_process');
const path = require('path');
const fs = require('fs');
const os = require('os');
const WebSocket = require('ws');

const PORT = 3696;
const BASE = `http://127.0.0.1:${PORT}`;
const SERVER_DIR = path.resolve(__dirname, '..');
const DATA_DIR = path.join(os.tmpdir(), 'xiaozhi-reconnect-e2e-' + Date.now());

// 把宽限期压到 3 秒，好在测试里同时验证"期内重连恢复"和"期外判未接"
const GRACE_MS = 3000;

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

  async has(type) {
    await sleep(120);
    return this.frames.some((f) => f.type === type);
  }

  close() {
    try { this.ws.terminate(); } catch { /* ignore */ }
  }
}

async function main() {
  fs.mkdirSync(DATA_DIR, { recursive: true });
  const child = spawn(process.execPath, ['src/index.js'], {
    cwd: SERVER_DIR,
    env: {
      ...process.env,
      PORT: String(PORT),
      DATA_DIR,
      DB_PATH: path.join(DATA_DIR, 'test.db'),
      OFFLINE_GRACE_MS: String(GRACE_MS),
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

  let up = false;
  for (let i = 0; i < 60; i++) {
    try {
      const r = await fetch(BASE + '/api/health');
      if (r.ok) { up = true; break; }
    } catch { /* 还没起来 */ }
    await sleep(200);
  }
  if (!up) throw new Error('服务端未能在 12 秒内启动');

  const mk = async (name) => {
    const r = await api('POST', '/api/auth/register', {
      body: { username: name, password: 'pass1234', nickname: name.toUpperCase() },
    });
    if (r.status !== 200) throw new Error(`注册 ${name} 失败: ${JSON.stringify(r.body)}`);
    return { token: r.body.token, id: r.body.user.id };
  };
  const alice = await mk('alice');
  const bob = await mk('bob');
  const dm = (await api('GET', `/api/conversations/dm/${bob.id}`, { token: alice.token }))
    .body.conversationId;

  // ============================================ ① ICE 配置下发
  console.log('\n[场景1] ICE 配置下发（无需登录）');
  {
    const r = await api('GET', '/api/call/ice');
    ok('GET /api/call/ice 返回 200', r.status === 200, `status=${r.status}`);
    const list = r.body && r.body.iceServers;
    ok('下发 iceServers 数组', Array.isArray(list) && list.length > 0,
      JSON.stringify(r.body));
    ok('每项都带 urls', Array.isArray(list) && list.every((x) => x.urls),
      JSON.stringify(list));
    ok('默认不含已失效的 stun.qq.com',
      Array.isArray(list) && !JSON.stringify(list).includes('stun.qq.com'),
      JSON.stringify(list));
    ok('带 turnConfigured 标志', r.body && r.body.turnConfigured === false,
      `turnConfigured=${r.body && r.body.turnConfigured}`);
  }

  // ============================================ ② 心跳
  console.log('\n[场景2] WS 应用层心跳');
  {
    const A = new Client(alice.token, 'alice');
    await A.ready();
    await A.next('connected');
    A.send({ type: 'ping', ts: 12345 });
    const pong = await A.next('pong');
    ok('ping → pong', pong.echo === 12345, JSON.stringify(pong));
    A.close();
    await sleep(150);
  }

  // ============================================ ③ 被叫掉线重连 → 补推来电
  console.log('\n[场景3] 被叫掉线重连 → 补推来电（宽限期内）');
  {
    const A = new Client(alice.token, 'alice');
    const B = new Client(bob.token, 'bob');
    await Promise.all([A.ready(), B.ready()]);
    await Promise.all([A.next('connected'), B.next('connected')]);

    A.send({ type: 'call:invite', conversationId: dm, calleeId: bob.id, mode: 'video' });
    const ringing = await A.next('call:ringing');
    const first = await B.next('call:incoming');
    ok('被叫首次收到来电', first.callId === ringing.callId);

    // 模拟外网 socket 被静默回收
    B.close();
    await sleep(400);

    const B2 = new Client(bob.token, 'bob2');
    await B2.ready();
    await B2.next('connected');
    const resumed = await B2.next('call:incoming');
    ok('重连后补推来电', resumed.callId === ringing.callId,
      `callId=${resumed.callId}`);
    ok('补推帧带 resumed 标记', resumed.resumed === true);
    ok('重连仍能接听', resumed.mode === 'video' && resumed.callerName === 'ALICE',
      `mode=${resumed.mode} name=${resumed.callerName}`);
    ok('宽限期内主叫不会收到通话结束', !(await A.has('call:ended')));

    // 接听链路依然可用
    B2.send({ type: 'call:accept', callId: resumed.callId });
    const accepted = await A.next('call:accepted');
    ok('重连后接听成功', accepted.callId === ringing.callId);

    A.send({ type: 'call:end', callId: ringing.callId });
    await sleep(200);
    A.close();
    B2.close();
    await sleep(150);
  }

  // ============================================ ④ 主叫掉线重连 → 恢复呼叫
  console.log('\n[场景4] 主叫掉线重连 → 补推 call:ringing（宽限期内）');
  {
    const A = new Client(alice.token, 'alice');
    const B = new Client(bob.token, 'bob');
    await Promise.all([A.ready(), B.ready()]);
    await Promise.all([A.next('connected'), B.next('connected')]);

    A.send({ type: 'call:invite', conversationId: dm, calleeId: bob.id, mode: 'audio' });
    const ringing = await A.next('call:ringing');
    await B.next('call:incoming');

    A.close();
    await sleep(400);

    const A2 = new Client(alice.token, 'alice2');
    await A2.ready();
    await A2.next('connected');
    const back = await A2.next('call:ringing');
    ok('主叫重连恢复呼叫中状态', back.callId === ringing.callId);
    ok('补推帧带 resumed 标记', back.resumed === true);
    ok('宽限期内被叫不会收到结束', !(await B.has('call:ended')));

    A2.send({ type: 'call:cancel', callId: ringing.callId });
    await sleep(200);
    A2.close();
    B.close();
    await sleep(150);
  }

  // ============================================ ⑤ 宽限期外 → 判未接
  console.log(`\n[场景5] 掉线超过宽限期（${GRACE_MS}ms）→ 判未接`);
  {
    const A = new Client(alice.token, 'alice');
    const B = new Client(bob.token, 'bob');
    await Promise.all([A.ready(), B.ready()]);
    await Promise.all([A.next('connected'), B.next('connected')]);

    A.send({ type: 'call:invite', conversationId: dm, calleeId: bob.id, mode: 'video' });
    await A.next('call:ringing');
    await B.next('call:incoming');

    B.close();
    const ended = await A.next('call:ended', GRACE_MS + 4000);
    ok('超期未重连 → 主叫收到 call:ended', ended.reason === 'unreachable',
      `reason=${ended.reason}`);

    // 事后重连不该再冒出来电界面（通话已拆）
    const B2 = new Client(bob.token, 'bob2');
    await B2.ready();
    await B2.next('connected');
    ok('通话结束后重连不再补推来电', !(await B2.has('call:incoming')));

    A.close();
    B2.close();
    await sleep(150);
  }

  // ============================================ ⑥ 已接通不补推
  console.log('\n[场景6] 已接通的通话不补推来电界面');
  {
    const A = new Client(alice.token, 'alice');
    const B = new Client(bob.token, 'bob');
    await Promise.all([A.ready(), B.ready()]);
    await Promise.all([A.next('connected'), B.next('connected')]);

    A.send({ type: 'call:invite', conversationId: dm, calleeId: bob.id, mode: 'video' });
    const ringing = await A.next('call:ringing');
    await B.next('call:incoming');
    B.send({ type: 'call:accept', callId: ringing.callId });
    await A.next('call:accepted');
    A.send({ type: 'call:offer', callId: ringing.callId, data: { sdp: 'S', type: 'offer' } });
    await B.next('call:offer');
    B.send({ type: 'call:answer', callId: ringing.callId, data: { sdp: 'S', type: 'answer' } });
    await A.next('call:answer');

    // 通话中（active）掉线重连：媒体靠的是 P2P，补不了，也不该弹来电界面
    B.close();
    await sleep(400);
    const B2 = new Client(bob.token, 'bob2');
    await B2.ready();
    await B2.next('connected');
    ok('已接通状态不补推来电', !(await B2.has('call:incoming')));

    A.send({ type: 'call:end', callId: ringing.callId });
    await sleep(200);
    A.close();
    B2.close();
  }

  console.log('\n' + '='.repeat(52));
  console.log(`通过 ${passed} 项，失败 ${failed} 项`);
  console.log('='.repeat(52));
  if (failures.length) {
    console.log('\n失败明细：');
    for (const f of failures) console.log('  · ' + f);
  }

  shutdown();
  process.exit(failed === 0 ? 0 : 1);
}

main().catch((e) => {
  console.error('\n测试异常终止：', e);
  process.exit(1);
});
