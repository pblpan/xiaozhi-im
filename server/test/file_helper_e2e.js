// 「文件助手」端到端测试：自己↔自己的会话，用来在手机和电脑之间倒文件
//
//   node test/file_helper_e2e.js
//
// 起一个隔离实例（独立 DATA_DIR + 端口），跑真实 HTTP + 真实 WebSocket。
//
// 【三条必须钉住的性质】
//   ① 每个用户只有一个文件助手：重复 GET 必须返回同一个 id，
//      否则每点一次入口就多一条会话，列表会被自己刷屏。
//   ② 它不能走 /dm/:userId —— 那条路由拒绝 self，所以单开 filehelper 类型。
//      反过来说：dm 拒绝 self 这件事本身也要留着断言，别让后来人"顺手放开"。
//   ③ 🔴 广播**不能**排除发送者。排除了就一个接收者都不剩：
//      手机上传的文件，电脑上要手动刷新才看得到，那这功能就白做了。
//      这条靠 WebSocket 实测，不是读代码得出的结论。

const { spawn } = require('child_process');
const path = require('path');
const fs = require('fs');
const os = require('os');
const WebSocket = require('ws');

const PORT = 3732;
const BASE = `http://127.0.0.1:${PORT}`;
const SERVER_DIR = path.resolve(__dirname, '..');
const DATA_DIR = path.join(os.tmpdir(), 'xiaozhi-filehelper-e2e-' + Date.now());

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

/** 上传一个文件，返回 files 表里的 id（发文件消息要用） */
async function upload(token, filename, mime, content) {
  const fd = new FormData();
  fd.append('file', new Blob([content], { type: mime }), filename);
  const res = await fetch(BASE + '/api/files/upload', {
    method: 'POST',
    headers: { Authorization: 'Bearer ' + token },
    body: fd,
  });
  return { status: res.status, body: await res.json().catch(() => null) };
}

/** 一个 WS 连接，收帧进 frames（用来验证"自己发的会广播回自己"） */
class Client {
  constructor(token) {
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

  close() { try { this.ws.close(); } catch { /* ignore */ } }
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
  console.log('[文件助手 E2E] 服务端已就绪 ' + BASE + '\n');

  const reg = async (u) => {
    const r = await api('POST', '/api/auth/register', { body: { username: u, password: 'pw123456', nickname: u } });
    if (!r.body?.token) throw new Error(`注册 ${u} 失败: ${JSON.stringify(r)}`);
    return r.body;
  };
  const A = await reg('alice');
  const B = await reg('bob');
  const ta = A.token, tb = B.token;
  const aId = A.user.id;

  // ---------------- 一：会话创建与幂等 ----------------
  console.log('\n【一】文件助手会话：创建 + 幂等');

  let r = await api('GET', '/api/conversations/filehelper');
  ok('未登录 → 401', r.status === 401, JSON.stringify(r.body));

  r = await api('GET', '/api/conversations/filehelper', { token: ta });
  const cid = r.body?.conversationId;
  ok('首次调用 → 200 且返回会话 id', r.status === 200 && Number.isInteger(cid), JSON.stringify(r.body));

  r = await api('GET', '/api/conversations/filehelper', { token: ta });
  ok('🔴 再次调用返回同一个 id（不会每点一次多一条会话）',
    r.status === 200 && r.body?.conversationId === cid, JSON.stringify(r.body));

  r = await api('GET', '/api/conversations/filehelper', { token: tb });
  ok('另一个人有自己的文件助手（不是共用一条）',
    r.status === 200 && Number.isInteger(r.body?.conversationId) && r.body.conversationId !== cid,
    JSON.stringify(r.body));

  // dm 拒绝 self：文件助手存在的理由，这条不能被人"顺手放开"
  r = await api('GET', `/api/conversations/dm/${aId}`, { token: ta });
  ok('单聊仍然拒绝 self → 400（所以才要单独一个类型）', r.status === 400, JSON.stringify(r.body));

  // ---------------- 二：会话列表里的形态 ----------------
  console.log('\n【二】会话列表里的文件助手');

  r = await api('GET', '/api/conversations', { token: ta });
  const mine = (r.body || []).find((c) => c.id === cid);
  ok('出现在我的会话列表里', !!mine, JSON.stringify((r.body || []).map((c) => [c.id, c.type])));
  ok('  标题固定「文件助手」', mine?.title === '文件助手', JSON.stringify(mine?.title));
  ok('  type 是 filehelper（客户端据此画文件夹图标）', mine?.type === 'filehelper', JSON.stringify(mine?.type));
  ok('  is_filehelper=true / is_group=false',
    mine?.is_filehelper === true && mine?.is_group === false,
    JSON.stringify([mine?.is_filehelper, mine?.is_group]));

  r = await api('GET', '/api/conversations', { token: tb });
  ok('别人的列表里看不到我的文件助手',
    !(r.body || []).some((c) => c.id === cid),
    JSON.stringify((r.body || []).map((c) => c.id)));

  // ---------------- 三：发消息 ----------------
  console.log('\n【三】往文件助手里发消息');

  r = await api('GET', `/api/conversations/${cid}/messages`, { token: ta });
  ok('历史接口的会话标题是「文件助手」',
    r.body?.conversation?.title === '文件助手', JSON.stringify(r.body?.conversation));
  ok('  只有自己一个成员', (r.body?.members || []).length === 1, JSON.stringify(r.body?.members));

  r = await api('POST', `/api/conversations/${cid}/messages`,
    { token: ta, body: { kind: 'text', content: '电脑上看得到吗' } });
  const textMsgId = r.body?.id;
  ok('发文字 → 200', r.status === 200 && Number.isInteger(textMsgId), JSON.stringify(r.body).slice(0, 160));

  r = await api('GET', '/api/conversations', { token: ta });
  const mine2 = (r.body || []).find((c) => c.id === cid);
  ok('🔴 自己发的不算未读（不会给自己刷红点）', mine2?.unread === 0, JSON.stringify(mine2?.unread));
  ok('  预览显示正文', mine2?.last_content === '电脑上看得到吗', JSON.stringify(mine2?.last_content));

  const doc = await upload(ta, '门店日报.txt', 'text/plain', 'hello-file-helper');
  ok('上传一个文件 → 200', doc.status === 200 && Number.isInteger(doc.body?.id), JSON.stringify(doc.body));
  r = await api('POST', `/api/conversations/${cid}/messages`,
    { token: ta, body: { kind: 'file', fileId: doc.body.id, content: '门店日报.txt' } });
  const fileMsgId = r.body?.id;
  ok('发文件 → 200', r.status === 200 && Number.isInteger(fileMsgId), JSON.stringify(r.body).slice(0, 160));

  r = await api('GET', `/api/conversations/${cid}/messages`, { token: ta });
  const fm = (r.body?.messages || []).find((m) => m.id === fileMsgId);
  ok('历史里能拿到这条文件，且带访问地址',
    !!fm?.file_url && fm?.file_name === '门店日报.txt', JSON.stringify(fm).slice(0, 200));
  ok('  访问地址是 /files/ 开头（不露磁盘路径）',
    String(fm?.file_url || '').startsWith('/files/'), JSON.stringify(fm?.file_url));

  // ---------------- 四：撤回 ----------------
  console.log('\n【四】撤回');
  r = await api('POST', `/api/conversations/${cid}/messages/${textMsgId}/recall`, { token: ta });
  ok('撤回自己发的文字 → 200', r.status === 200, JSON.stringify(r.body).slice(0, 120));
  r = await api('GET', `/api/conversations/${cid}/messages`, { token: ta });
  // sqlite 里 deleted 是 0/1 整数，不是布尔 —— 用 === true 判会永远假绿不了
  ok('历史里标记为已撤回',
    !!(r.body?.messages || []).find((m) => m.id === textMsgId)?.deleted,
    JSON.stringify((r.body?.messages || []).map((m) => [m.id, m.deleted])));

  // ---------------- 五：隔离 ----------------
  console.log('\n【五】隔离：只有本人能进');
  r = await api('GET', `/api/conversations/${cid}/messages`, { token: tb });
  ok('别人读我的文件助手 → 403', r.status === 403, JSON.stringify(r.body));
  // 发消息这条路由没有显式 memberOf 前置，靠 sendMessage 抛错挡回去 → 400。
  // 只要不是 200 就算拦住了，别把状态码钉死在实现细节上（以后加了前置会变 403）。
  r = await api('POST', `/api/conversations/${cid}/messages`, { token: tb, body: { kind: 'text', content: 'x' } });
  ok('别人往里发消息 → 被拒', r.status === 400 || r.status === 403, JSON.stringify([r.status, r.body]));
  r = await api('GET', `/api/conversations/${cid}/messages`);
  ok('未登录 → 401', r.status === 401, JSON.stringify(r.body));

  // ---------------- 六：广播不排除发送者（手机↔电脑同步的关键）----------------
  console.log('\n【六】🔴 自己发的消息会广播回自己的其它端');

  const c1 = new Client(ta);
  await c1.ready();
  await sleep(200);

  r = await api('POST', `/api/conversations/${cid}/messages`,
    { token: ta, body: { kind: 'text', content: '来自手机的同步消息' } });
  ok('发一条文字 → 200', r.status === 200, JSON.stringify(r.body).slice(0, 120));

  for (let i = 0; i < 40; i++) {
    if (c1.frames.some((f) => f.type === 'message:new' && f.message?.conversation_id === cid)) break;
    await sleep(100);
  }
  const pushed = c1.frames.filter((f) => f.type === 'message:new' && f.message?.conversation_id === cid);
  ok('同一账号的另一条连接收到了这条消息（电脑端不用刷新就能看到）',
    pushed.length === 1, JSON.stringify(c1.frames.map((f) => f.type)));
  ok('  推的就是刚发的那条（按 id 对得上，客户端据此去重）',
    pushed[0]?.message?.id === r.body?.id, JSON.stringify([pushed[0]?.message?.id, r.body?.id]));

  // 普通单聊必须仍然排除发送者（这条被改坏会让所有人收到自己刚发的消息）
  await api('POST', '/api/friends/requests', { token: ta, body: { userId: B.user.id, message: 'hi' } });
  const reqs = await api('GET', '/api/friends/requests', { token: tb });
  const reqId = (reqs.body?.pending || reqs.body?.items || [])[0]?.userId;
  if (reqId) await api('POST', '/api/friends/accept', { token: tb, body: { userId: reqId } });
  const dmR = await api('GET', `/api/conversations/dm/${B.user.id}`, { token: ta });
  const dmCid = dmR.body?.conversationId;
  ok('建一条普通单聊 → 200', Number.isInteger(dmCid), JSON.stringify(dmR.body));
  c1.frames.length = 0;
  await api('POST', `/api/conversations/${dmCid}/messages`, { token: ta, body: { kind: 'text', content: '单聊不该回声' } });
  await sleep(600);
  ok('  普通单聊不会把消息回推给自己（排除发送者仍在生效）',
    !c1.frames.some((f) => f.type === 'message:new' && f.message?.conversation_id === dmCid),
    JSON.stringify(c1.frames.map((f) => [f.type, f.message?.conversation_id])));
  c1.close();

  // ---------------- 七：搜索 ----------------
  console.log('\n【七】搜索');
  r = await api('GET', '/api/conversations/search?q=' + encodeURIComponent('同步消息'), { token: ta });
  ok('能搜到文件助手里的文字（它也是"我参与的会话"）',
    (r.body?.items || []).some((m) => m.conversation_id === cid),
    JSON.stringify((r.body?.items || []).map((m) => m.conversation_id)));
  r = await api('GET', '/api/conversations/search?q=' + encodeURIComponent('同步消息'), { token: tb });
  ok('别人搜不到', (r.body?.items || []).length === 0, JSON.stringify(r.body?.total));

  // ---------------- 收尾 ----------------
  console.log(`\n结果：${passed} 通过 / ${failed} 失败`);
  if (failed) {
    console.log('\n失败项：');
    for (const f of failures) console.log('  - ' + f);
  }
  stopServer();
  process.exit(failed ? 1 : 0);
})().catch((e) => {
  console.error('E2E 崩溃：', e);
  console.error(serverLog.slice(-2000));
  stopServer();
  process.exit(1);
});
