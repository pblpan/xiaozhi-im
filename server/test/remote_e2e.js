// 远程协助端到端测试（对标 UU 远程第一期）
//
// 这个文件**优先测安全边界**，功能流程反而是次要的 —— 远程协助赋予的是
// "操作别人电脑"的权限，功能错了顶多不好用，边界漏了就是远控木马。
//
//   ① 访问码：明文只给一次、库里只有哈希、吊销即时失效
//   ② 有人值守完整流程：邀请 → 同意 → 信令 → 生效 → 断开 → 审计落 pits
//   ③ 信令隔离：非会话成员不能插手（否则会出现"看不见的控制者"）
//   ④ 拒绝 / 取消 / 不能连自己 / 忙线
//   ⑤ 无人值守：访问码 + 撤销窗口 + 一次性马子用过即废
//   ⑥ 兑换限流（无限撞码 = 9 位口令被暴力枚举）
//   ⑦ 掉线拆会话（绝不留无人看管的控制权）
//
//   node test/remote_e2e.js

const { spawn } = require('child_process');
const path = require('path');
const fs = require('fs');
const os = require('os');
const crypto = require('crypto');
const WebSocket = require('ws');

const PORT = 3699;
const BASE = `http://127.0.0.1:${PORT}`;
const SERVER_DIR = path.resolve(__dirname, '..');
const DATA_DIR = path.join(os.tmpdir(), 'xiaozhi-remote-e2e-' + Date.now());

// 测试里把等待压短，免得为一个超时干等 45 秒
const RING_MS = 1500;
const ABORT_MS = 1200;

let passed = 0;
let failed = 0;
const failures = [];

function ok(name, cond, extra) {
  if (cond) { passed++; console.log(`  \u2713 ${name}`); }
  else {
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
  async next(type, ms = 6000) {
    const deadline = Date.now() + ms;
    while (Date.now() < deadline) {
      const i = this.frames.findIndex((f) => f.type === type && !f.__used);
      if (i >= 0) { this.frames[i].__used = true; return this.frames[i]; }
      await sleep(25);
    }
    throw new Error(`[${this.label}] 等待 ${type} 超时（已收到: ${this.frames.map((f) => f.type).join(',')}）`);
  }
  async none(type, ms = 600) {
    await sleep(ms);
    return !this.frames.some((f) => f.type === type && !f.__used);
  }
  clear() { this.frames.length = 0; }
  close() { try { this.ws.close(); } catch { /* ignore */ } }
}

/**
 * 直接读服务端那个 SQLite 文件（只读，不碰它的数据结构）。
 * 用来校验"到底存了什么" —— 走 HTTP 接口只能看到服务端愿意给你的那一面。
 */
function readDb(sql, ...args) {
  const { DatabaseSync } = require('node:sqlite');
  const db = new DatabaseSync(path.join(DATA_DIR, 'test.db'), { readOnly: true });
  try {
    return db.prepare(sql).get(...args) || null;
  } finally {
    db.close();
  }
}

async function mkUser(child, username, nickname) {
  await api('POST', '/api/auth/register', { body: { username, password: 'pass123456', nickname } });
  const lg = await api('POST', '/api/auth/login', { body: { username, password: 'pass123456' } });
  const tok = lg.body?.token;
  // /api/auth/me 返回的是 { user: {...} }，id 在 user 里
  const me = await api('GET', '/api/auth/me', { token: tok });
  const id = me.body?.user?.id;
  if (!tok || !id) {
    throw new Error(`创建用户失败: ${username} (login=${lg.status}, me=${me.status})`);
  }
  return { token: tok, id, nickname };
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
      ADMIN_USERNAME: 'admin',
      ADMIN_PASSWORD: 'admin-test-pw',
      REMOTE_RING_TIMEOUT_MS: String(RING_MS),
      REMOTE_ABORT_WINDOW_MS: String(ABORT_MS),
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
    try { if ((await fetch(BASE + '/api/health')).ok) { up = true; break; } } catch { /* 还没起来 */ }
    await sleep(200);
  }
  if (!up) throw new Error('服务端未能在 12 秒内启动');

  // ---- 准备用户：A=被控端，B=控制端，C=路人（验证信令隔离），D=专测限流 ----
  const A = await mkUser(child, 'r_host', '被协助的小张');
  const B = await mkUser(child, 'r_ctrl', '协助的老李');
  const C = await mkUser(child, 'r_none', '路人甲');
  const D = await mkUser(child, 'r_brute', '撞码的');

  console.log('\n[1] 接口鉴权');
  ok('GET /api/remote/codes 未登录 → 401',
    (await api('GET', '/api/remote/codes')).status === 401);
  ok('GET /api/remote/sessions 未登录 → 401',
    (await api('GET', '/api/remote/sessions')).status === 401);
  ok('POST /api/remote/codes 未登录 → 401',
    (await api('POST', '/api/remote/codes', { body: { label: 'x' } })).status === 401);
  ok('GET /api/remote/current 登录后可用',
    (await api('GET', '/api/remote/current', { token: A.token })).status === 200);

  console.log('\n[2] 访问码：明文只给一次，库里只有哈希');
  const gen = await api('POST', '/api/remote/codes', {
    token: A.token, body: { label: '门店前台那台', singleUse: false },
  });
  const code = gen.body?.code;
  ok('生成成功并返回 9 位数字访问码', /^\d{9}$/.test(code || ''), `实际 ${code}`);
  const listed = await api('GET', '/api/remote/codes', { token: A.token });
  ok('列表里能看到这条访问码', (listed.body?.items || []).length === 1);
  ok('列表**不含**明文访问码（否则等于永久可查）',
    !JSON.stringify(listed.body).includes(code), '列表泄漏了明文');
  // 直接读 SQLite 文件，确认落盘的是哈希不是明文
  const rawDb = fs.readFileSync(path.join(DATA_DIR, 'test.db')).toString('latin1');
  ok('数据库文件里搜不到明文访问码（只有哈希）', !rawDb.includes(code), 'DB 里出现了明文');
  // ⚠️ 这条断言的目的是"确认库里存的是**慢哈希**，不是能被离线枚举的 SHA256"。
  // 曾经写成 `sha256('x').length === 64` —— 那跟库里的数据毫无关系，恒真，
  // 等于给"9 位访问码可被暴力反推"这个真实风险盖了个合格的章。
  // 现在改成**形态比对**：拿真实库里的这一行重算一遍"如果用的是 SHA256 会是
  // 什么值"，只要实际存的正好等于那个值，就说明安全防护没生效。
  const rowish = readDb('SELECT code_hash h, salt s FROM remote_access_codes LIMIT 1');
  ok('库里确实取到了这行访问码', !!rowish, '没查到，后面的比对就没意义了');
  if (rowish) {
    const shaIfUsed = crypto.createHash('sha256')
      .update(String(rowish.s) + '|' + code).digest('hex');
    ok('存的不是 sha256(salt+code)（必须是慢哈希，否则 9 位码能离线枚举）',
      rowish.h !== shaIfUsed, '库里存的就是可直接枚举的 SHA256');
    ok('哈希仍是 64 位十六进制（格式没走样）', /^[0-9a-f]{64}$/.test(String(rowish.h)),
      String(rowish.h).slice(0, 20));
    // 同一明文 + 同一盐必须算出同一个哈希（兑换时才能比对得上）
    ok('同一明文重算得到同一个哈希（兑换逻辑自洽）',
      crypto.scryptSync(String(code), String(rowish.s), 32,
        { N: 16384, r: 8, p: 1, maxmem: 64 * 1024 * 1024 }).toString('hex') === rowish.h);
  }

  console.log('\n[3] 有人值守：人员确认才授予控制权');
  const a1 = new Client(A.token, 'A');
  const b1 = new Client(B.token, 'B');
  const c1 = new Client(C.token, 'C');
  await Promise.all([a1.ready(), b1.ready(), c1.ready()]);

  b1.send({ type: 'remote:invite', hostId: A.id });
  const inv = await a1.next('remote:invite');
  ok('被控端收到邀请', !!inv.session?.sessionId);
  const sid = inv.session.sessionId;
  ok('邀请里标注了有人值守模式', inv.session.mode === 'attended');
  ok('邀请里带了发起人的名字（被控端要能认出是谁）', inv.session.controllerName === '协助的老李');
  ok('路人收不到别人的邀请', await c1.none('remote:invite', 500));

  // ⚠️ 这个会话此刻还停在 requesting（还没人同意）。
  // 客户端那层确实会拦（phase != active 就丢控制指令），但服务端**不能依赖
  // 客户端自觉**：SDP 一旦允许提前协商，就等于"先把连接建好再等同意"，
  // 客户端任何一处漏判都会变成"没点同意就被控"。
  a1.clear(); b1.clear();
  b1.send({ type: 'remote:offer', sessionId: sid, data: { type: 'offer', sdp: 'v=0-before-accept' } });
  await sleep(500);
  // 这里刻意不用 `await b1.next('error')`：那样一旦服务端**放行**了，
  // 断言会变成"等待超时抛异常"—— 测试确实红了，但报错信息完全看不出是
  // 哪个安全边界漏了。直接查收到帧，失败时才能正是打印出服务端放了什么过来。
  const saw = b1.frames.filter((f) => f.type === 'error' && f.ref === 'remote:offer');
  ok('还没同意就发 offer：服务端回绝发起方', saw.length === 1,
    `服务端没回绝？B 实际收到: ${b1.frames.map((f) => f.type).join(',') || '空'}`);
  ok('还没同意就发 offer：被控端收不到 SDP',
    !a1.frames.some((f) => f.type === 'remote:offer'),
    `A 实际收到: ${a1.frames.map((f) => f.type).join(',') || '空'}`);

  // 只有被控端能同意 —— 这一步是权限的源头
  a1.clear(); b1.clear();
  c1.send({ type: 'remote:accept', sessionId: sid, device: 'Windows' });
  const ce = await c1.next('error');
  ok('非被控端点同意会被拒绝', ce.ref === 'remote:accept', `实际 ${ce.ref || '无 error'}`);

  a1.send({ type: 'remote:accept', sessionId: sid, device: 'Windows 10' });
  const acc = await b1.next('remote:accept');
  ok('控制端收到同意', !!acc.session);
  ok('同意里带回被控端设备信息', acc.session.hostId === A.id);

  console.log('\n[4] 信令隔离：非会话成员不能插手');
  const offer = { type: 'offer', sdp: 'v=0-fake' };
  // 路人往这个会话里塞 offer
  c1.clear();
  c1.send({ type: 'remote:offer', sessionId: sid, data: offer });
  const ce2 = await c1.next('error');
  ok('非会话成员转发 SDP 被拒绝', ce2.ref === 'remote:offer', `实际 ${ce2.ref || '无 error'}`);
  ok('被控端没收到路人的 SDP', await a1.none('remote:offer', 400));

  a1.clear(); b1.clear();
  b1.send({ type: 'remote:offer', sessionId: sid, data: offer });
  const gotOffer = await a1.next('remote:offer');
  ok('会话内 offer 正常转发', gotOffer.data?.sdp === offer.sdp);
  ok('转发标注了来源（便于客户端忽略自己发的）', gotOffer.from === B.id);
  ok('路人不会收到会话内的 SDP', await c1.none('remote:offer', 400));

  a1.clear(); b1.clear();
  a1.send({ type: 'remote:answer', sessionId: sid, data: { type: 'answer', sdp: 'v=0-a' } });
  const gotAns = await b1.next('remote:answer');
  ok('反向 answer 正常转发', gotAns.data?.sdp === 'v=0-a');

  console.log('\n[5] 会话生效与结束');
  a1.clear(); b1.clear();
  b1.send({ type: 'remote:active', sessionId: sid });
  const act1 = await a1.next('remote:active');
  ok('双方都被告知会话已生效', !!act1.session);
  const cur = (await api('GET', '/api/remote/current', { token: A.token })).body?.session;
  ok('GET /api/remote/current 能查到进行中的会话', cur?.sessionId === sid);

  a1.clear(); b1.clear();
  b1.send({ type: 'remote:end', sessionId: sid });
  const ended = await a1.next('remote:end');
  ok('被控端收到结束通知', !!ended.sessionId);
  ok('结束原因标注为控制端断开', ended.reason === 'controller_end', `实际 ${ended.reason}`);
  ok('结束后 current 为空', (await api('GET', '/api/remote/current', { token: A.token })).body?.session === null);

  const histA = (await api('GET', '/api/remote/sessions', { token: A.token })).body?.items || [];
  ok('被控端有会话审计记录', histA.length === 1, `实际 ${histA.length}`);
  ok('记录里我的角色是 host（被协助方）', histA[0]?.role === 'host');
  ok('记录里有对方名字（事后能复盘是谁来过的）', histA[0]?.controllerName === '协助的老李');
  ok('记录里有时长', typeof histA[0]?.durationSec === 'number');
  ok('记录里有被控端设备', histA[0]?.hostDevice === 'Windows 10');
  const histB = (await api('GET', '/api/remote/sessions', { token: B.token })).body?.items || [];
  ok('控制端也能查到同一条记录', histB.length === 1);
  ok('控制端视角角色是 controller', histB[0]?.role === 'controller');

  console.log('\n[6] 拒绝 / 取消 / 不能连自己 / 忙线');
  a1.clear(); b1.clear();
  b1.send({ type: 'remote:invite', hostId: A.id });
  const inv2 = await a1.next('remote:invite');
  a1.send({ type: 'remote:reject', sessionId: inv2.session.sessionId });
  const rej = await b1.next('remote:end');
  ok('被控端拒绝后控制端收到结束', rej.reason === 'rejected', `实际 ${rej.reason}`);

  b1.clear();
  b1.send({ type: 'remote:invite', hostId: A.id });
  const inv3 = await a1.next('remote:invite');
  b1.send({ type: 'remote:cancel', sessionId: inv3.session.sessionId });
  const canc = await a1.next('remote:end');
  ok('控制端取消后被控端收到结束', canc.reason === 'canceled', `实际 ${canc.reason}`);

  b1.clear();
  b1.send({ type: 'remote:invite', hostId: B.id });
  const selfErr = await b1.next('error');
  ok('不能远程协助自己', /自己/.test(selfErr.message || ''), `实际 ${selfErr.message}`);

  // 忙线：A 正在会话里，C 再敲门
  b1.clear(); a1.clear();
  b1.send({ type: 'remote:invite', hostId: A.id });
  const invBusy = await a1.next('remote:invite');
  c1.clear();
  c1.send({ type: 'remote:invite', hostId: A.id });
  const busyErr = await c1.next('error');
  ok('对方忙线时给出提示', /正在其他远程协助/.test(busyErr.message || ''), `实际 ${busyErr.message}`);
  a1.send({ type: 'remote:reject', sessionId: invBusy.session.sessionId });
  await b1.next('remote:end');

  console.log('\n[7] 敲门超时');
  a1.clear(); b1.clear();
  b1.send({ type: 'remote:invite', hostId: A.id });
  await a1.next('remote:invite');
  const to = await b1.next('remote:end', RING_MS + 3000);
  ok('无人应答会超时结束', to.reason === 'timeout', `实际 ${to.reason}`);

  console.log('\n[8] 无人值守：访问码 + 撤销窗口');
  const gen2 = await api('POST', '/api/remote/codes', {
    token: A.token, body: { label: '一次性', singleUse: true },
  });
  const code2 = gen2.body?.code;
  a1.clear(); b1.clear();
  b1.send({ type: 'remote:redeem', code: code2, device: 'Windows 11' });
  const ro = await b1.next('remote:redeem:ok');
  ok('兑换成功并拿到会话号', !!ro.sessionId);
  const inv4 = await a1.next('remote:invite');
  ok('无人值守也要通知被控端（不是悄悄就控了）', !!inv4.session);
  ok('模式标注为 unattended', inv4.session.mode === 'unattended');
  ok('带撤销窗口截止时间（还能反悔）', typeof inv4.session.abortDeadline === 'number');

  // 窗口内被控端可以拒绝 —— 这是防止"码泄漏后被立刻控住"的最后一道
  a1.send({ type: 'remote:reject', sessionId: inv4.session.sessionId });
  const rej2 = await b1.next('remote:end');
  ok('撤销窗口内被控端仍能拒绝', rej2.reason === 'rejected', `实际 ${rej2.reason}`);

  const gen3 = await api('POST', '/api/remote/codes', {
    token: A.token, body: { label: '第二次', singleUse: true },
  });
  const code3 = gen3.body?.code;
  a1.clear(); b1.clear();
  b1.send({ type: 'remote:redeem', code: code3, device: 'Windows 11' });
  await b1.next('remote:redeem:ok');
  await a1.next('remote:invite');
  const autoAccept = await b1.next('remote:accept', ABORT_MS + 3000);
  ok('窗口过了无人反对则自动放行（无人值守的意义）', !!autoAccept.session);
  await a1.next('remote:authed', 3000).then(
    () => ok('被控端收到 authed 通知', true),
    () => ok('被控端收到 authed 通知', false, '没收到'),
  );
  a1.send({ type: 'remote:end', sessionId: autoAccept.session.sessionId });
  await b1.next('remote:end');

  // 一次性码用过即废
  b1.clear();
  b1.send({ type: 'remote:redeem', code: code3, device: 'x' });
  const usedErr = await b1.next('error');
  ok('一次性访问码用过即废', /已被使用|无效/.test(usedErr.message || ''), `实际 ${usedErr.message}`);

  // 吊销后立刻失效
  const gen4 = await api('POST', '/api/remote/codes', { token: A.token, body: { label: '待吊销' } });
  const code4 = gen4.body?.code;
  const rev = await api('DELETE', `/api/remote/codes/${gen4.body.id}`, { token: A.token });
  ok('吊销成功', rev.status === 200 && rev.body?.ok === true);
  await sleep(50);
  b1.clear();
  b1.send({ type: 'remote:redeem', code: code4, device: 'x' });
  const revErr = await b1.next('error');
  ok('吊销后的访问码无法兑换', /无效/.test(revErr.message || ''), `实际 ${revErr.message}`);

  console.log('\n[9] 兑换限流');
  const d1 = new Client(D.token, 'D');
  await d1.ready();
  let blocked = false;
  for (let i = 0; i < 11; i++) {
    d1.clear();
    d1.send({ type: 'remote:redeem', code: '000000000', device: 'x' });
    const e = await d1.next('error', 3000);
    if (/尝试次数过多/.test(e.message || '')) { blocked = true; break; }
  }
  ok('连续撞码会被限流拦下', blocked);
  d1.close();

  console.log('\n[10] 掉线即拆会话（不留无人看管的控制权）');
  // ⚠️ 必须先把 A/B 的**旧连接**全部断开。服务端是"一个用户的最后一条 socket
  //    断开才算离线"（多端登录设计），旧连接还在的话 close 不会触发离线处理。
  a1.close(); b1.close(); c1.close();
  await sleep(400);
  const a2 = new Client(A.token, 'A2');
  const b2 = new Client(B.token, 'B2');
  await Promise.all([a2.ready(), b2.ready()]);
  b2.send({ type: 'remote:invite', hostId: A.id });
  const inv5 = await a2.next('remote:invite');
  a2.send({ type: 'remote:accept', sessionId: inv5.session.sessionId, device: 'Windows' });
  await b2.next('remote:accept');
  b2.clear();
  a2.close();
  await sleep(600);   // 等服务端处理 close
  const off = await b2.next('remote:end', 4000);
  ok('被控端掉线，控制端收到结束', off.reason === 'offline', `实际 ${off.reason}`);
  b2.close();

  // ---- 汇总 ----
  console.log('\n============================================================');
  if (failed === 0) {
    console.log(`全部通过：${passed} / ${passed}`);
  } else {
    console.log(`通过 ${passed} / ${passed + failed}，失败 ${failed} 项：`);
    for (const f of failures) console.log('  - ' + f);
  }
  console.log('============================================================');
  a1.close(); b1.close(); c1.close();
  child.kill();
  process.exit(failed === 0 ? 0 : 1);
}

main().catch((e) => {
  console.error('测试异常:', e);
  process.exit(1);
});
