// 断线消息补推（sync 帧）端到端测试
//
// 背景（龙哥 2026-10-14 报：PC 与手机聊天记录对不上、丢两条）：
//   hub.send() 对不在 OPEN 状态的 socket 是静默丢弃、没有离线队列；
//   客户端重连成功后也不会补拉 → 断线窗口内别人发来的消息永久丢失。
//   修复：客户端重连后带"已见过的最大消息 id"发 sync，服务端补发之后的落库消息。
//
// 覆盖：
//   ① 在线时实时送达（基线，别被补推改坏）
//   ② 断线期间的消息，重连后按序补推
//   ③ afterId 边界：已见过的消息不重复补
//   ④ sync:done 带补发条数
//   ⑤ 撤回的消息不进补推
//   ⑥ 自己其他端发的消息也补（多端同步）
//   ⑦ afterId=0（冷启动）补全部 —— 客户端此时不发，但服务端口径要正确
//
//   node test/message_sync_e2e.js

const { spawn } = require('child_process');
const path = require('path');
const fs = require('fs');
const os = require('os');
const WebSocket = require('ws');

const PORT = 3720;
const BASE = `http://127.0.0.1:${PORT}`;
const SERVER_DIR = path.resolve(__dirname, '..');
const DATA_DIR = path.join(os.tmpdir(), 'xiaozhi-msgsync-e2e-' + Date.now());

let passed = 0;
let failed = 0;
const failures = [];

function ok(name, cond, extra) {
  if (cond) {
    passed++;
    console.log(`  ✓ ${name}`);
  } else {
    failed++;
    failures.push(name + (extra ? ` — ${extra}` : ''));
    console.log(`  ✗ ${name}${extra ? '  → ' + extra : ''}`);
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

  /** 收集当前所有未消费的 message:new（补推场景用），并标记为已消费 */
  async drainMessages(ms = 1500) {
    await sleep(ms);
    const out = this.frames.filter((f) => f.type === 'message:new' && !f.__used);
    for (const f of out) f.__used = true;
    return out;
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

  /** 让 alice 通过 WS 发一条，返回消息 */
  const sendAs = async (who, conversationId, content) => {
    who.send({ type: 'message:send', conversationId, content });
    const frame = await who.next('message:new');
    return frame.message;
  };

  // ============================================ ① 基线：在线实时送达
  console.log('\n[场景1] 在线时实时送达（补推不能改坏原有链路）');
  {
    const A = new Client(alice.token, 'alice');
    const B = new Client(bob.token, 'bob');
    await Promise.all([A.ready(), B.ready()]);
    await Promise.all([A.next('connected'), B.next('connected')]);

    const m1 = await sendAs(A, dm, '在线消息-1');
    ok('对端实时收到 message:new', m1.content === '在线消息-1', JSON.stringify(m1));

    // 记录 bob 已见过的最大 id（模拟客户端记账）
    const bobSeen = m1.id;

    // ============================================ ② 断线期间的消息 → 补推
    console.log('\n[场景2] 断线期间的消息，重连后按序补推');
    B.close();
    await sleep(400);

    const m2 = await sendAs(A, dm, '断线消息-2');
    const m3 = await sendAs(A, dm, '断线消息-3');
    await sleep(150);

    const B2 = new Client(bob.token, 'bob2');
    await B2.ready();
    await B2.next('connected');
    // 客户端行为：connected 后自动带 maxSeenMessageId 发 sync
    B2.send({ type: 'sync', afterId: bobSeen });

    const done = await B2.next('sync:done');
    ok('sync:done 报告补发条数', done.count === 2, `count=${done.count}`);

    const missed = (await B2.drainMessages()).map((f) => f.message);
    ok('补推条数正确', missed.length === 2, `实际 ${missed.length} 条: ${missed.map((m) => m.content)}`);
    ok('补推内容按序正确',
      missed.length === 2 && missed[0].content === '断线消息-2' && missed[1].content === '断线消息-3',
      JSON.stringify(missed.map((m) => m.content)));
    ok('补推的是完整消息对象（带发送者/时间）',
      missed.length === 2 && missed[0].sender_id === alice.id && missed[0].created_at > 0,
      JSON.stringify(missed[0]));

    // ============================================ ③ 边界：已见过的不重复补
    console.log('\n[场景3] afterId 边界：已见过的消息不重复补');
    B2.send({ type: 'sync', afterId: m3.id });
    const done2 = await B2.next('sync:done');
    ok('补发到最新后 count=0', done2.count === 0, `count=${done2.count}`);

    // ============================================ ④ 撤回的消息不进补推
    console.log('\n[场景4] 撤回的消息不进补推');
    A.send({ type: 'message:recall', messageId: m2.id });
    await sleep(200);
    B2.send({ type: 'sync', afterId: m3.id });
    const done3 = await B2.next('sync:done');
    const extra = (await B2.drainMessages()).map((f) => f.message);
    ok('撤回后无新消息可补', done3.count === 0 && extra.length === 0,
      `count=${done3.count} extra=${extra.map((m) => m.content)}`);

    A.close();
    B2.close();
    await sleep(150);
  }

  // ============================================ ⑤ 多端同步：自己其他端发的也补
  console.log('\n[场景5] 自己其他端发的消息也补（多端同步）');
  {
    // 设备1：在线时发一条，记下见过的最大 id，然后掉线
    const B1 = new Client(bob.token, 'bob-a');
    await B1.ready();
    await B1.next('connected');
    const seen = (await sendAs(B1, dm, 'bob自己的消息')).id;
    B1.close();
    await sleep(300);

    // 设备2：bob 的另一个端，在设备1掉线期间发消息（设备1收不到实时推送）
    const B2 = new Client(bob.token, 'bob-b');
    await B2.ready();
    await B2.next('connected');
    await sendAs(B2, dm, 'bob另一端发的');
    await sleep(100);

    // 设备1重连 → 补推应包含自己另一端发的消息
    const B3 = new Client(bob.token, 'bob-c');
    await B3.ready();
    await B3.next('connected');
    B3.send({ type: 'sync', afterId: seen });
    const done = await B3.next('sync:done');
    const missed = (await B3.drainMessages()).map((f) => f.message);
    ok('补推含自己其他端发的消息',
      done.count === 1 && missed.length === 1 && missed[0].content === 'bob另一端发的',
      `count=${done.count} ${JSON.stringify(missed.map((m) => m.content))}`);
    ok('补推消息带自己的 senderId', missed.length === 1 && missed[0].sender_id === bob.id);

    B2.close();
    B3.close();
    await sleep(150);
  }

  // ============================================ ⑥ afterId=0（冷启动口径）
  console.log('\n[场景6] afterId=0 时补全部（服务端口径；客户端冷启动不发 sync）');
  {
    const B = new Client(bob.token, 'bob-fresh');
    await B.ready();
    await B.next('connected');
    B.send({ type: 'sync', afterId: 0 });
    const done = await B.next('sync:done');
    const missed = (await B.drainMessages()).map((f) => f.message);
    ok('afterId=0 补出该用户全部会话的消息',
      done.count >= 2 && missed.length === done.count,
      `count=${done.count} 实收 ${missed.length}`);
    ok('补推按 id 升序',
      missed.every((m, i) => i === 0 || m.id > missed[i - 1].id));
    B.close();
    await sleep(150);
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
