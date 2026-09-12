// 个人资料 / 好友认证附言与模板 / 消息不可编辑 —— 端到端测试
//
//   node test/profile_friends_e2e.js
//
// 起一个隔离实例（独立 DATA_DIR + 端口），跑真实 HTTP + WebSocket。
// 重点覆盖"脏输入"：超长字段、非法枚举、不存在的日期、越权改用户名，
// 这些是上一轮 call.js 缺参数没被覆盖、结果在生产被打脸的同一类问题。

const { spawn } = require('child_process');
const path = require('path');
const fs = require('fs');
const os = require('os');
const WebSocket = require('ws');

const PORT = 3698;
const BASE = `http://127.0.0.1:${PORT}`;
const SERVER_DIR = path.resolve(__dirname, '..');
const DATA_DIR = path.join(os.tmpdir(), 'xiaozhi-mp-e2e-' + Date.now());

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

// ------------------------------------------------------------------ WS

class Ws {
  constructor(token) {
    this.buf = [];
    this.wake = null;
    this.ws = new WebSocket(`ws://127.0.0.1:${PORT}/ws?token=${encodeURIComponent(token)}`);
    this.ws.on('message', (raw) => {
      let m;
      try { m = JSON.parse(raw.toString()); } catch { return; }
      this.buf.push(m);
      if (this.wake) { const w = this.wake; this.wake = null; w(); }
    });
  }
  open() {
    return new Promise((res, rej) => {
      this.ws.on('open', res);
      this.ws.on('error', rej);
    });
  }
  send(o) { this.ws.send(JSON.stringify(o)); }
  async wait(type, ms = 4000) {
    const t0 = Date.now();
    while (Date.now() - t0 < ms) {
      const i = this.buf.findIndex((m) => m.type === type);
      if (i >= 0) return this.buf.splice(i, 1)[0];
      await new Promise((r) => { this.wake = r; setTimeout(r, 100); });
    }
    return null;
  }
  close() { try { this.ws.close(); } catch { /* ignore */ } }
}

// ------------------------------------------------------------------ 服务器

let serverProc = null;
let serverLog = '';

async function startServer() {
  serverProc = spawn(process.execPath, [path.join(SERVER_DIR, 'src', 'index.js')], {
    env: { ...process.env, PORT: String(PORT), DATA_DIR, ADMIN_PASSWORD: 'admin123' },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  serverProc.stdout.on('data', (d) => { serverLog += d.toString(); });
  serverProc.stderr.on('data', (d) => { serverLog += d.toString(); });
  for (let i = 0; i < 60; i++) {
    try {
      const r = await fetch(BASE + '/api/health');
      if (r.ok) return;
    } catch { /* 还没起来 */ }
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
  console.log('[profile/friends E2E] 服务端已就绪 ' + BASE + '\n');

  // ---------------- 注册三个用户 ----------------
  const reg = async (u) => {
    const r = await api('POST', '/api/auth/register', { body: { username: u, password: 'pw123456', nickname: u } });
    if (!r.body?.token) throw new Error(`注册 ${u} 失败: ${JSON.stringify(r)}`);
    return r.body;
  };
  const A = await reg('alice');
  const B = await reg('bob');
  const C = await reg('carol');
  const ta = A.token, tb = B.token, tc = C.token;

  console.log('【一】个人资料面板');
  let r = await api('GET', '/api/auth/me', { token: ta });
  ok('新注册用户资料字段齐全且为空',
    r.status === 200 && r.body.user.signature === null && r.body.user.gender === null
    && r.body.user.region === null && r.body.user.birthday === null,
    JSON.stringify(r.body.user));

  r = await api('PUT', '/api/auth/profile', {
    token: ta,
    body: { nickname: '爱丽丝', signature: '今天也要好好吃饭', gender: 'female', region: '黑龙江 海伦', birthday: '2000-02-29' },
  });
  ok('一次更新全部资料字段',
    r.status === 200 && r.body.user.nickname === '爱丽丝' && r.body.user.signature === '今天也要好好吃饭'
    && r.body.user.gender === 'female' && r.body.user.region === '黑龙江 海伦' && r.body.user.birthday === '2000-02-29',
    JSON.stringify(r.body));

  r = await api('GET', '/api/auth/me', { token: ta });
  ok('资料已持久化', r.body.user.nickname === '爱丽丝' && r.body.user.birthday === '2000-02-29');

  r = await api('PUT', '/api/auth/profile', { token: ta, body: { nickname: 'x'.repeat(25) } });
  ok('超长昵称被拒（24 字上限）', r.status === 400 && /24/.test(r.body.error || ''), JSON.stringify(r.body));

  r = await api('PUT', '/api/auth/profile', { token: ta, body: { signature: 'y'.repeat(61) } });
  ok('超长签名被拒（60 字上限）', r.status === 400 && /60/.test(r.body.error || ''), JSON.stringify(r.body));

  r = await api('PUT', '/api/auth/profile', { token: ta, body: { region: 'z'.repeat(21) } });
  ok('超长地区被拒（20 字上限）', r.status === 400, JSON.stringify(r.body));

  r = await api('PUT', '/api/auth/profile', { token: ta, body: { birthday: '2026-02-31' } });
  ok('不存在的日期被拒（2026-02-31）', r.status === 400 && /YYYY-MM-DD/.test(r.body.error || ''), JSON.stringify(r.body));

  r = await api('PUT', '/api/auth/profile', { token: ta, body: { birthday: '2000/01/01' } });
  ok('错误分隔符的日期被拒', r.status === 400, JSON.stringify(r.body));

  r = await api('PUT', '/api/auth/profile', { token: ta, body: { gender: 'alien' } });
  ok('非法性别被拒', r.status === 400 && /性别/.test(r.body.error || ''), JSON.stringify(r.body));

  r = await api('PUT', '/api/auth/profile', { token: ta, body: { avatar: 'javascript:alert(1)' } });
  ok('非法的头像地址被拒（防注入到 Image.network）', r.status === 400 && /头像/.test(r.body.error || ''), JSON.stringify(r.body));

  r = await api('PUT', '/api/auth/profile', { token: ta, body: { avatar: '/files/abc123.png' } });
  ok('合法的站内头像路径通过', r.status === 200 && r.body.user.avatar === '/files/abc123.png', JSON.stringify(r.body));

  r = await api('PUT', '/api/auth/profile', { token: ta, body: { username: 'hacker' } });
  ok('不可改字段（username）被忽略且提示无变更',
    r.status === 400 && /没有需要更新/.test(r.body.error || ''), JSON.stringify(r.body));
  r = await api('GET', '/api/auth/me', { token: ta });
  ok('username 确实没被改', r.body.user.username === 'alice');

  r = await api('PUT', '/api/auth/profile', { token: ta, body: { signature: '   ' } });
  ok('传空串可清空签名（不是"不改"）', r.status === 200 && (r.body.user.signature === '' || r.body.user.signature === null), JSON.stringify(r.body.user.signature));

  r = await api('PUT', '/api/auth/profile', { token: ta, body: { nickname: '😀'.repeat(24) } });
  ok('emoji 昵称按码点计数（24 个通过）', r.status === 200, JSON.stringify(r.body));
  r = await api('PUT', '/api/auth/profile', { token: ta, body: { nickname: '😀'.repeat(25) } });
  ok('emoji 昵称 25 个被拒', r.status === 400, JSON.stringify(r.body));

  r = await api('GET', `/api/users/${B.user.id}`, { token: ta });
  ok('可查看他人公开资料', r.status === 200 && r.body.username === 'bob' && 'signature' in r.body, JSON.stringify(r.body));

  r = await api('GET', '/api/users/999999', { token: ta });
  ok('查看不存在的用户 → 404 中文提示', r.status === 404, JSON.stringify(r.body));

  r = await api('GET', '/api/users/not-a-number', { token: ta });
  ok('非法用户 id → 400（不再把脏值喂给 SQLite）', r.status === 400, JSON.stringify(r.body));

  r = await api('GET', '/api/users/search?q=' + encodeURIComponent('bob'), { token: ta });
  ok('用户搜索返回资料字段', r.status === 200 && r.body.length >= 1 && 'signature' in r.body[0], JSON.stringify(r.body));

  r = await api('GET', '/api/users/search?q=' + encodeURIComponent('%'), { token: ta });
  ok('LIKE 通配符被转义（搜 % 不会匹配所有人）', r.status === 200 && r.body.length === 0, `命中 ${r.body.length} 人`);

  // ---------------- 好友申请 + 认证附言 ----------------
  console.log('\n【二】好友添加认证附言');
  const wsB = new Ws(tb);
  await wsB.open();
  await sleep(120);

  const bId = B.user.id;
  const aId = A.user.id;

  r = await api('POST', '/api/friends/request', { token: ta, body: { friendId: bId, message: '你好，我是隔壁老王介绍的' } });
  ok('发起好友申请（带附言）', r.status === 200 && r.body.ok === true, JSON.stringify(r.body));

  const frame = await wsB.wait('friend:request');
  ok('被申请方实时收到 friend:request 帧', !!frame, '未收到帧');
  ok('帧里带申请人资料与附言',
    !!frame && frame.message === '你好，我是隔壁老王介绍的' && frame.user && frame.user.username === 'alice',
    JSON.stringify(frame));

  r = await api('GET', '/api/friends', { token: tb });
  ok('待处理列表能看到申请', r.status === 200 && r.body.pending.length === 1, JSON.stringify(r.body.pending));
  ok('待处理项带附言 / 申请人昵称 / 时间',
    r.body.pending[0].message === '你好，我是隔壁老王介绍的'
    && r.body.pending[0].username === 'alice'
    && typeof r.body.pending[0].created_at === 'number',
    JSON.stringify(r.body.pending[0]));

  r = await api('POST', '/api/friends/request', { token: ta, body: { friendId: bId, message: '补充一句：头像是我本人' } });
  ok('重复申请（改附言）算更新，不算错误', r.status === 200 && r.body.updated === true, JSON.stringify(r.body));
  r = await api('GET', '/api/friends', { token: tb });
  ok('改附言后仍只有 1 条待处理，且附言已更新',
    r.body.pending.length === 1 && r.body.pending[0].message === '补充一句：头像是我本人',
    JSON.stringify(r.body.pending));

  r = await api('POST', '/api/friends/request', { token: tb, body: { friendId: aId, message: '反过来申请' } });
  ok('对方已申请过我时，反向申请被拦并提示去处理',
    r.status === 409 && /新的朋友/.test(r.body.error || ''), JSON.stringify(r.body));

  r = await api('POST', '/api/friends/request', { token: ta, body: { friendId: aId, message: '自己加自己' } });
  ok('不能加自己为好友', r.status === 400, JSON.stringify(r.body));

  r = await api('POST', '/api/friends/request', { token: ta, body: { friendId: 999999, message: 'x' } });
  ok('申请不存在的用户 → 404', r.status === 404, JSON.stringify(r.body));

  r = await api('POST', '/api/friends/request', { token: ta, body: { friendId: bId, message: 'm'.repeat(101) } });
  ok('超长附言被拒（100 字上限）', r.status === 400 && /100/.test(r.body.error || ''), JSON.stringify(r.body));

  r = await api('POST', '/api/friends/accept', { token: tb, body: { friendId: aId } });
  ok('接受好友申请', r.status === 200, JSON.stringify(r.body));

  r = await api('GET', '/api/friends', { token: ta });
  ok('申请人这边也变成好友（双向）',
    r.body.friends.some((f) => f.id === bId), JSON.stringify(r.body.friends));
  r = await api('GET', '/api/friends', { token: tb });
  ok('接受后待处理清空', r.body.pending.length === 0, JSON.stringify(r.body.pending));

  r = await api('POST', '/api/friends/request', { token: ta, body: { friendId: bId, message: '再加一次' } });
  ok('已是好友再申请 → 409', r.status === 409 && /已经是好友/.test(r.body.error || ''), JSON.stringify(r.body));

  // 拒绝路径
  r = await api('POST', '/api/friends/request', { token: tc, body: { friendId: bId, message: '我是 carol' } });
  ok('第三人发起申请', r.status === 200, JSON.stringify(r.body));
  r = await api('POST', '/api/friends/reject', { token: tb, body: { friendId: C.user.id } });
  ok('拒绝好友申请', r.status === 200, JSON.stringify(r.body));
  r = await api('GET', '/api/friends', { token: tb });
  ok('拒绝后待处理清空（且不是好友）',
    r.body.pending.length === 0 && !r.body.friends.some((f) => f.id === C.user.id),
    JSON.stringify(r.body));
  r = await api('POST', '/api/friends/request', { token: tc, body: { friendId: bId, message: '再试一次' } });
  ok('被拒后可以再次申请（不是永久拉黑）', r.status === 200, JSON.stringify(r.body));
  r = await api('POST', '/api/friends/reject', { token: tb, body: { friendId: C.user.id } });
  ok('再次拒绝成功', r.status === 200, JSON.stringify(r.body));
  r = await api('POST', '/api/friends/reject', { token: tb, body: { friendId: C.user.id } });
  ok('拒绝不存在的申请 → 404', r.status === 404, JSON.stringify(r.body));

  // ---------------- 好友备注 ----------------
  // 备注是「我这一侧」的私有属性，落在 friendships(user_id=我, friend_id=对方)，
  // 要同时验三件事：能存、对方看不到、能顶替昵称出现在会话标题上。
  console.log('\n【二·五】好友备注');
  r = await api('GET', '/api/friends', { token: ta });
  ok('未设备注时 remark 为空',
    r.body.friends.find((f) => f.id === bId)?.remark == null,
    JSON.stringify(r.body.friends));

  r = await api('PUT', `/api/friends/${bId}/remark`, { token: ta, body: { remark: '隔壁老王' } });
  ok('设置好友备注', r.status === 200 && r.body.remark === '隔壁老王', JSON.stringify(r.body));

  r = await api('GET', '/api/friends', { token: ta });
  ok('备注回显在好友列表里',
    r.body.friends.find((f) => f.id === bId)?.remark === '隔壁老王',
    JSON.stringify(r.body.friends));

  r = await api('GET', '/api/friends', { token: tb });
  ok('备注只对我可见（对方那份记录仍为空）',
    r.body.friends.find((f) => f.id === aId)?.remark == null,
    JSON.stringify(r.body.friends));

  // 接受申请时服务端已自动建过单聊，这里拿现成的
  r = await api('GET', `/api/conversations/dm/${bId}`, { token: ta });
  const dmCid = r.body?.conversationId;
  ok('取到单聊会话 id', Number.isInteger(dmCid), JSON.stringify(r.body));

  r = await api('GET', '/api/conversations', { token: ta });
  let dmA = r.body.find((c) => c.id === dmCid);
  ok('我这边单聊标题 = 备注', !!dmA && dmA.title === '隔壁老王',
    JSON.stringify(dmA && dmA.title));
  ok('会话 peer 里也带 remark',
    !!dmA && dmA.peer && dmA.peer.remark === '隔壁老王',
    JSON.stringify(dmA && dmA.peer));

  // A 的昵称在前面的用例里被改成了 24 个 emoji，这里动态取一次再比，
  // 免得以后改前面的用例又把这个断言带崩
  const aNick = (await api('GET', '/api/auth/me', { token: ta })).body.user.nickname;
  r = await api('GET', '/api/conversations', { token: tb });
  const dmB = r.body.find((c) => c.id === dmCid);
  ok('对方那边标题仍是昵称（不受我的备注影响）',
    !!dmB && dmB.title === aNick && dmB.title !== '隔壁老王',
    JSON.stringify(dmB && dmB.title));
  ok('对方 peer.remark 为空',
    !!dmB && dmB.peer && dmB.peer.remark == null, JSON.stringify(dmB && dmB.peer));

  r = await api('GET', `/api/conversations/${dmCid}/messages`, { token: ta });
  ok('聊天页标题也用备注', r.body?.conversation?.title === '隔壁老王',
    JSON.stringify(r.body && r.body.conversation));

  // 改备注 → 无需重建会话，标题立刻跟着变
  r = await api('PUT', `/api/friends/${bId}/remark`, { token: ta, body: { remark: '老王（同事）' } });
  ok('改备注', r.status === 200 && r.body.remark === '老王（同事）', JSON.stringify(r.body));
  r = await api('GET', '/api/conversations', { token: ta });
  ok('改完备注立刻反映到会话标题',
    r.body.find((c) => c.id === dmCid)?.title === '老王（同事）',
    JSON.stringify(r.body.find((c) => c.id === dmCid)?.title));

  // 清空：空串 / 纯空格都退回昵称
  r = await api('PUT', `/api/friends/${bId}/remark`, { token: ta, body: { remark: '   ' } });
  ok('纯空格视为清空', r.status === 200 && r.body.remark === null, JSON.stringify(r.body));
  r = await api('GET', '/api/conversations', { token: ta });
  ok('清空后备注消失、退回对方昵称',
    r.body.find((c) => c.id === dmCid)?.title === 'bob',
    JSON.stringify(r.body.find((c) => c.id === dmCid)?.title));
  r = await api('GET', '/api/friends', { token: ta });
  ok('清空后列表 remark 为 null',
    r.body.friends.find((f) => f.id === bId)?.remark == null,
    JSON.stringify(r.body.friends));

  // 脏输入
  r = await api('PUT', `/api/friends/${bId}/remark`, { token: ta, body: { remark: '备'.repeat(31) } });
  ok('超长备注被拒（30 字上限）',
    r.status === 400 && /30/.test(r.body.error || ''), JSON.stringify(r.body));
  r = await api('PUT', `/api/friends/${bId}/remark`, { token: ta, body: { remark: '备'.repeat(30) } });
  ok('刚好 30 字放行', r.status === 200, JSON.stringify(r.body));
  r = await api('PUT', `/api/friends/${aId}/remark`, { token: ta, body: { remark: '自己' } });
  ok('不能给自己设备注 → 400', r.status === 400, JSON.stringify(r.body));
  r = await api('PUT', `/api/friends/${C.user.id}/remark`, { token: ta, body: { remark: '非好友' } });
  ok('非好友不能设备注 → 404',
    r.status === 404 && /不是好友/.test(r.body.error || ''), JSON.stringify(r.body));
  r = await api('PUT', '/api/friends/abc/remark', { token: ta, body: { remark: 'x' } });
  ok('非法好友 id → 400', r.status === 400, JSON.stringify(r.body));
  r = await api('PUT', `/api/friends/${bId}/remark`, { body: { remark: 'x' } });
  ok('未登录 → 401', r.status === 401, JSON.stringify(r.body));
  // 备注被拒时不应写坏原值
  r = await api('GET', '/api/friends', { token: ta });
  ok('被拒的请求没有改动已有备注',
    r.body.friends.find((f) => f.id === bId)?.remark === '备'.repeat(30),
    JSON.stringify(r.body.friends.find((f) => f.id === bId)?.remark));
  // 复原，免得影响后面用例
  await api('PUT', `/api/friends/${bId}/remark`, { token: ta, body: { remark: '' } });

  // ---------------- 认证模板 ----------------
  console.log('\n【三】好友申请附言模板');
  r = await api('GET', '/api/friends/templates', { token: ta });
  ok('首次读取自动播种 3 条默认模板', r.status === 200 && r.body.length === 3, JSON.stringify(r.body));

  const firstTpl = r.body[0];
  r = await api('POST', '/api/friends/templates', { token: ta, body: { content: '我是海伦盛京优特的，加个好友' } });
  ok('新增模板', r.status === 200 && r.body.id > 0, JSON.stringify(r.body));
  const newTplId = r.body.id;

  r = await api('POST', '/api/friends/templates', { token: ta, body: { content: '我是海伦盛京优特的，加个好友' } });
  ok('重复模板 → 409 友好提示', r.status === 409 && /已经有了/.test(r.body.error || ''), JSON.stringify(r.body));

  r = await api('POST', '/api/friends/templates', { token: ta, body: { content: '  ' } });
  ok('空模板被拒', r.status === 400, JSON.stringify(r.body));

  r = await api('POST', '/api/friends/templates', { token: ta, body: { content: 'x'.repeat(101) } });
  ok('超长模板被拒（100 字上限）', r.status === 400, JSON.stringify(r.body));

  r = await api('PUT', `/api/friends/templates/${newTplId}`, { token: ta, body: { content: '改过的模板内容' } });
  ok('修改模板', r.status === 200 && r.body.content === '改过的模板内容', JSON.stringify(r.body));

  r = await api('PUT', `/api/friends/templates/${newTplId}`, { token: tb, body: { content: '偷改别人的' } });
  ok('不能改别人的模板（越权）', r.status === 404, JSON.stringify(r.body));

  r = await api('DELETE', `/api/friends/templates/${newTplId}`, { token: ta });
  ok('删除模板', r.status === 200, JSON.stringify(r.body));
  r = await api('GET', '/api/friends/templates', { token: ta });
  ok('删除后回到 3 条', r.body.length === 3, JSON.stringify(r.body));

  r = await api('GET', '/api/friends/templates', { token: tb });
  ok('模板人手一份（bob 的种子里不含 alice 的改动）',
    r.body.length === 3 && !r.body.some((t) => t.content === '改过的模板内容'), JSON.stringify(r.body));

  r = await api('GET', '/api/friends/templates', { token: tc });
  ok('模板接口同样补齐 3 条种子', r.body.length === 3, JSON.stringify(r.body));

  r = await api('DELETE', `/api/friends/templates/${firstTpl.id}`, { token: ta });
  ok('删除自己的种子模板成功（种子不是不可删）', r.status === 200, JSON.stringify(r.body));

  // 模板路由不能被 DELETE /:friendId 抢走
  ok('DELETE /friends/templates/:id 未被 /:friendId 抢占', r.status === 200, `status=${r.status}`);

  // ---------------- 消息不可编辑 ----------------
  console.log('\n【四】已发消息不可编辑');
  r = await api('GET', '/api/conversations', { token: ta });
  const dm = (r.body.items || r.body).find((c) => c.type === 'dm');
  ok('好友通过后自动建了单聊会话', !!dm, JSON.stringify(r.body).slice(0, 200));

  const cid = dm.id;
  r = await api('POST', `/api/conversations/${cid}/messages`, { token: ta, body: { kind: 'text', content: '原始内容' } });
  ok('发一条消息', r.status === 200 && !!r.body.id, JSON.stringify(r.body).slice(0, 200));
  const msgId = r.body.id;

  r = await api('PATCH', `/api/conversations/${cid}/messages/${msgId}`, { token: ta, body: { content: '偷偷改掉' } });
  ok('编辑消息 → 410（接口已下线）', r.status === 410, `status=${r.status}`);
  ok('410 带中文可读原因', /不支持修改/.test(r.body.error || '') && /撤回/.test(r.body.error || ''), JSON.stringify(r.body));

  r = await api('GET', `/api/conversations/${cid}/messages`, { token: ta });
  const mine = r.body.messages.find((m) => m.id === msgId);
  ok('消息内容确实没被改动', !!mine && mine.content === '原始内容', JSON.stringify(mine));
  ok('也没有被标记为已编辑', !!mine && !mine.edited, JSON.stringify(mine && mine.edited));

  const wsA = new Ws(ta);
  await wsA.open();
  await sleep(120);
  wsA.send({ type: 'message:edit', messageId: msgId, content: '走 WebSocket 改' });
  const errFrame = await wsA.wait('error');
  ok('WS 走 message:edit 收到明确错误（旧客户端兜底）',
    !!errFrame && errFrame.ref === 'message:edit' && /撤回/.test(errFrame.message || ''),
    JSON.stringify(errFrame));

  // 撤回仍然可用
  r = await api('POST', `/api/conversations/${cid}/messages/${msgId}/recall`, { token: ta });
  ok('撤回仍然正常工作（只禁编辑，不禁撤回）', r.status === 200, JSON.stringify(r.body));
  r = await api('GET', `/api/conversations/${cid}/messages`, { token: ta });
  const recalled = r.body.messages.find((m) => m.id === msgId);
  ok('撤回后 deleted=1', !!recalled && recalled.deleted === 1, JSON.stringify(recalled && recalled.deleted));

  wsA.close();
  wsB.close();

  // ---------------- 结果 ----------------
  console.log(`\n${'='.repeat(52)}`);
  console.log(`通过 ${passed} / ${passed + failed}`);
  if (failed) {
    console.log('失败项：');
    for (const f of failures) console.log('  - ' + f);
  }
  console.log('='.repeat(52));
  stopServer();
  process.exit(failed ? 1 : 0);
})().catch((e) => {
  console.error('\n测试异常：', e.message);
  console.error(serverLog.slice(-2000));
  stopServer();
  process.exit(1);
});
