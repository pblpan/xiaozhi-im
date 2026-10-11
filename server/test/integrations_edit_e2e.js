// 集成对接「编辑」端到端测试（#313 龙哥：向导要可以修改）
//
//   node test/integrations_edit_e2e.js
//
// 起一个隔离实例（独立 DATA_DIR + 端口），走真实 HTTP。
//
// 【三条必须钉住的性质】
//   ① 🔴 编辑入站推送**不能改 token（即地址）** —— 地址变了等于把所有对接方的
//      配置同时作废。本测试专门断言：改完名字/机器人/会话后，原地址试推仍然成功。
//   ② 换目标会话时机器人必须被**自动**拉进新会话 —— 否则推过去全部失败
//      （机器人不在群里是入站推送的头号故障，这事必须由服务端兜住）。
//   ③ 开签名 → secret 现生成；关签名 → secret 必须清空。留着旧 secret 的"关签名"
//      是半吊子状态，谁也说不清请求到底要不要签。

const { spawn } = require('child_process');
const path = require('path');
const fs = require('fs');
const os = require('os');

const PORT = 3735;
const BASE = `http://127.0.0.1:${PORT}`;
const SERVER_DIR = path.resolve(__dirname, '..');
const DATA_DIR = path.join(os.tmpdir(), 'xiaozhi-intedit-e2e-' + Date.now());

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

let serverProc = null;
let serverLog = '';

async function startServer() {
  serverProc = spawn(process.execPath, [path.join(SERVER_DIR, 'src', 'index.js')], {
    env: { ...process.env, PORT: String(PORT), DATA_DIR, ADMIN_PASSWORD: 'TestAdmin_123' },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  serverProc.stdout.on('data', (d) => { serverLog += d.toString(); });
  serverProc.stderr.on('data', (d) => { serverLog += d.toString(); });
  for (let i = 0; i < 60; i++) {
    try { const r = await fetch(BASE + '/api/health'); if (r.ok) return; } catch { /* 还没起来 */ }
    await sleep(250);
  }
  throw new Error('服务端启动超时\n' + serverLog);
}

function stopServer() {
  if (serverProc) { try { serverProc.kill(); } catch { /* ignore */ } }
  try { fs.rmSync(DATA_DIR, { recursive: true, force: true }); } catch { /* ignore */ }
}

// ------------------------------------------------------------------ 主流程

(async () => {
  await startServer();
  console.log('[集成编辑 E2E] 服务端已就绪 ' + BASE + '\n');

  // 管理员 + 普通用户
  const login = await api('POST', '/api/auth/login', {
    body: { username: 'admin', password: 'TestAdmin_123' },
  });
  ok('管理员登录', login.status === 200, `got=${login.status}`);
  const ta = login.body.token;

  const reg = await api('POST', '/api/auth/register', {
    body: { username: 'alice', password: 'pw123456', nickname: 'alice' },
  });
  const tu = reg.body?.token;
  ok('普通用户注册', !!tu, JSON.stringify(reg.body).slice(0, 100));

  // 两个群 + 两个机器人 + 一条入站推送
  const g1 = (await api('POST', '/api/groups', { token: ta, body: { name: '门店经营' } })).body;
  const g2 = (await api('POST', '/api/groups', { token: ta, body: { name: '测试群' } })).body;
  const conv1 = g1.conversationId, conv2 = g2.conversationId;
  ok('建两个群', Number.isInteger(conv1) && Number.isInteger(conv2), JSON.stringify([conv1, conv2]));

  let bot1 = (await api('POST', '/api/admin/integrations/bots', {
    token: ta, body: { name: '日报机器人', conversationId: conv1 } })).body;
  let bot2 = (await api('POST', '/api/admin/integrations/bots', {
    token: ta, body: { name: '告警机器人' } })).body;
  ok('建两个机器人', !!bot1.id && !!bot2.id, JSON.stringify([bot1.id, bot2.id]));

  let hook = (await api('POST', '/api/admin/integrations/incoming', {
    token: ta, body: { name: '销售日报', botId: bot1.id, conversationId: conv1 } })).body;
  ok('建入站推送（拿到 token/地址）', !!hook.token && !!hook.path, JSON.stringify(hook).slice(0, 140));
  const HOOK_ID = hook.id;
  const ORIG_PATH = hook.path;

  // ================ 一：机器人改名 ================
  console.log('\n【一】PATCH /bots/:id — 机器人改名');

  let r = await api('PATCH', `/api/admin/integrations/bots/${bot1.id}`, { body: { name: '新名字' } });
  ok('未登录 → 401', r.status === 401, JSON.stringify(r.body));

  r = await api('PATCH', `/api/admin/integrations/bots/${bot1.id}`, { token: tu, body: { name: '新名字' } });
  ok('非管理员 → 403', r.status === 403, JSON.stringify(r.body));

  r = await api('PATCH', `/api/admin/integrations/bots/${bot1.id}`, { token: ta, body: { name: '泰格日报' } });
  ok('改名 → 200 且返回新昵称', r.status === 200 && r.body?.nickname === '泰格日报', JSON.stringify(r.body));

  r = await api('GET', '/api/admin/integrations/bots', { token: ta });
  ok('列表里也变成新名字（账号 username 不变）',
    (r.body || []).some((b) => b.id === bot1.id && b.nickname === '泰格日报' && b.username === bot1.username),
    JSON.stringify((r.body || []).map((b) => [b.id, b.nickname])));

  r = await api('PATCH', `/api/admin/integrations/bots/${bot1.id}`, { token: ta, body: { name: '   ' } });
  ok('纯空白名 → 400', r.status === 400, JSON.stringify(r.body));

  r = await api('PATCH', `/api/admin/integrations/bots/${bot1.id}`, { token: ta, body: {} });
  ok('空 body → 400（没有要修改的内容）', r.status === 400, JSON.stringify(r.body));

  r = await api('PATCH', '/api/admin/integrations/bots/999999', { token: ta, body: { name: 'x' } });
  ok('机器人不存在 → 404', r.status === 404, JSON.stringify(r.body));

  // ================ 二：入站推送编辑 ================
  console.log('\n【二】PATCH /incoming/:id — 编辑推送地址');

  r = await api('PATCH', `/api/admin/integrations/incoming/${HOOK_ID}`, { body: { name: 'x' } });
  ok('未登录 → 401', r.status === 401, JSON.stringify(r.body));

  r = await api('PATCH', `/api/admin/integrations/incoming/${HOOK_ID}`, { token: tu, body: { name: 'x' } });
  ok('非管理员 → 403', r.status === 403, JSON.stringify(r.body));

  // 改名：path/token 必须不变（性质①）
  r = await api('PATCH', `/api/admin/integrations/incoming/${HOOK_ID}`, {
    token: ta, body: { name: '泰格POS日报' } });
  ok('改用途名 → 200', r.status === 200 && r.body?.name === '泰格POS日报', JSON.stringify(r.body).slice(0, 160));
  ok('🔴 地址（path）不变 —— 改了等于把对接方的配置全部作废', r.body?.path === ORIG_PATH,
    `${r.body?.path} vs ${ORIG_PATH}`);

  // 换目标会话：机器人必须被自动拉进新会话（性质②）
  r = await api('PATCH', `/api/admin/integrations/incoming/${HOOK_ID}`, {
    token: ta, body: { conversationId: conv2 } });
  ok('换目标会话 → 200 且 conversation_id 更新',
    r.status === 200 && r.body?.conversation_id === conv2, JSON.stringify(r.body).slice(0, 160));

  r = await api('GET', `/api/groups/${conv2}`, { token: ta });
  const members2 = r.body?.members || [];
  ok('🔴 机器人被自动拉进新会话（否则推送全失败）',
    members2.some((m) => m.id === bot1.id || m.user_id === bot1.id),
    JSON.stringify(members2.map((m) => m.id || m.user_id)));

  // 换机器人
  r = await api('PATCH', `/api/admin/integrations/incoming/${HOOK_ID}`, {
    token: ta, body: { botId: bot2.id } });
  ok('换机器人 → 200 且 bot_id 更新',
    r.status === 200 && r.body?.bot_id === bot2.id, JSON.stringify(r.body).slice(0, 160));

  // 签名开关（性质③）
  r = await api('PATCH', `/api/admin/integrations/incoming/${HOOK_ID}`, {
    token: ta, body: { signed: true } });
  ok('开签名 → signed=true 且 secret 非空',
    r.status === 200 && r.body?.signed === true && !!r.body?.secret,
    JSON.stringify({ signed: r.body?.signed, secret: r.body?.secret }));

  r = await api('PATCH', `/api/admin/integrations/incoming/${HOOK_ID}`, {
    token: ta, body: { signed: false } });
  ok('🔴 关签名 → secret 必须清空（不能留半吊子状态）',
    r.status === 200 && r.body?.signed === false && !r.body?.secret,
    JSON.stringify({ signed: r.body?.signed, secret: r.body?.secret }));

  // 边界
  r = await api('PATCH', `/api/admin/integrations/incoming/${HOOK_ID}`, { token: ta, body: {} });
  ok('空 body → 400', r.status === 400, JSON.stringify(r.body));

  r = await api('PATCH', `/api/admin/integrations/incoming/${HOOK_ID}`, {
    token: ta, body: { botId: 999999 } });
  ok('机器人不存在 → 400', r.status === 400, JSON.stringify(r.body));

  r = await api('PATCH', `/api/admin/integrations/incoming/${HOOK_ID}`, {
    token: ta, body: { conversationId: 999999 } });
  ok('会话不存在 → 400', r.status === 400, JSON.stringify(r.body));

  r = await api('PATCH', '/api/admin/integrations/incoming/999999', { token: ta, body: { name: 'x' } });
  ok('推送地址不存在 → 404', r.status === 404, JSON.stringify(r.body));

  // 🔴 收官验证：编辑一整轮之后，原地址试推仍然成功、消息落进新会话
  r = await api('POST', `/api/admin/integrations/incoming/${HOOK_ID}/send`, {
    token: ta, body: { text: '编辑后试推' } });
  ok('编辑一整轮后，原地址试推 → 200', r.status === 200, JSON.stringify(r.body));

  r = await api('GET', `/api/conversations/${conv2}/messages`, { token: ta });
  const msgs = Array.isArray(r.body) ? r.body : (r.body?.messages || []);
  ok('  消息真的落进新会话（且以机器人身份发言）',
    msgs.some((m) => m.sender_id === bot2.id || m.senderId === bot2.id),
    JSON.stringify(msgs.slice(-3).map((m) => [m.sender_id || m.senderId, m.kind || m.type])));

  // ================ 三：出站订阅编辑 ================
  console.log('\n【三】PATCH /outgoing/:id — 事件订阅编辑（后端原有，钉住 UI 依赖的形状）');

  let out = (await api('POST', '/api/admin/integrations/outgoing', {
    token: ta, body: { name: '工厂V2回调', url: 'https://factory.example.com/hook' } })).body;
  ok('建出站订阅', !!out.id, JSON.stringify(out).slice(0, 120));

  r = await api('PATCH', `/api/admin/integrations/outgoing/${out.id}`, {
    token: ta, body: { name: '工厂V2回调-新', url: 'https://factory.example.com/hook2',
      events: ['message.created'], conversationId: conv1 } });
  ok('改名称/地址/事件/范围 → 200 且全部生效',
    r.status === 200 && r.body?.name === '工厂V2回调-新' && r.body?.url?.endsWith('/hook2')
      && r.body?.events === 'message.created' && r.body?.conversation_id === conv1,
    JSON.stringify(r.body).slice(0, 200));

  r = await api('PATCH', `/api/admin/integrations/outgoing/${out.id}`, { token: ta, body: {} });
  ok('空 body → 400', r.status === 400, JSON.stringify(r.body));

  r = await api('PATCH', `/api/admin/integrations/outgoing/${out.id}`, {
    token: ta, body: { url: '不是地址' } });
  ok('非法 URL 不被更新（且无其他字段时 → 400）', r.status === 400, JSON.stringify(r.body));

  // ------------------------------------------------------------------ 结果
  console.log(`\n========== 结果：${passed} 通过 / ${failed} 失败 ==========`);
  if (failures.length) {
    console.log('失败项：');
    for (const f of failures) console.log('  ✗ ' + f);
  }
  stopServer();
  process.exit(failed ? 1 : 0);
})().catch((e) => { console.error('测试执行异常：', e); stopServer(); process.exit(1); });
