// 生产环境探测：个人信息面板 / 好友认证模板 / 已发消息不可编辑
//
//   node deploy/probe_profile_prod.js
//
// 设计原则：**零副作用**。
// 只发 GET，不改任何人的资料、不发好友申请、不产生脏数据。
// 唯一"写"的是首次读模板时服务端会自动播种 3 条默认模板 —— 对发起探测的人本身
// 是预期行为（用户第一次打开也是这个结果），不影响别人。
//
// 只依赖 http 内置模块，不 require ws，避免从 deploy/ 解析依赖时找不到。

const http = require('http');

const BASE = process.env.PROBE_BASE || 'http://192.168.31.44:3602';
const USER = process.env.PROBE_USER || 'admin';
const PASS = process.env.PROBE_PASS || 'admin123';

let pass = 0;
let fail = 0;
const bad = [];

function ok(name, cond, extra) {
  if (cond) {
    pass++;
    console.log('  \u2713 ' + name);
  } else {
    fail++;
    bad.push(name + (extra ? ' — ' + extra : ''));
    console.log('  \u2717 ' + name + (extra ? '  → ' + extra : ''));
  }
}

function req(method, path, body, token) {
  return new Promise((resolve, reject) => {
    const data = body ? JSON.stringify(body) : null;
    const u = new URL(BASE + path);
    const r = http.request({
      hostname: u.hostname,
      port: u.port,
      path: u.pathname + u.search,
      method,
      headers: {
        'Content-Type': 'application/json',
        ...(data ? { 'Content-Length': Buffer.byteLength(data) } : {}),
        ...(token ? { Authorization: 'Bearer ' + token } : {}),
      },
    }, (res) => {
      let b = '';
      res.on('data', (c) => b += c);
      res.on('end', () => {
        let json = null;
        try { json = JSON.parse(b); } catch { /* 非 JSON */ }
        resolve({ status: res.statusCode, body: json, raw: b });
      });
    });
    r.on('error', reject);
    if (data) r.write(data);
    r.end();
  });
}

(async () => {
  console.log('探测目标: ' + BASE + '\n');

  const lg = await req('POST', '/api/auth/login', { username: USER, password: PASS });
  if (!lg.body || !lg.body.token) {
    console.log('登录失败，无法继续：', JSON.stringify(lg).slice(0, 300));
    process.exit(1);
  }
  const token = lg.body.token;
  console.log('登录成功: ' + USER + '\n');

  console.log('【一】个人资料字段');
  const me = await req('GET', '/api/auth/me', null, token);
  const u = (me.body || {}).user || {};
  ok('GET /auth/me 通', me.status === 200, 'status=' + me.status);
  for (const k of ['signature', 'gender', 'region', 'birthday']) {
    ok('资料字段 ' + k + ' 已就位', Object.prototype.hasOwnProperty.call(u, k),
      JSON.stringify(u));
  }

  console.log('\n【二】好友认证模板');
  const tpl = await req('GET', '/api/friends/templates', null, token);
  ok('GET /friends/templates 通', tpl.status === 200, 'status=' + tpl.status);
  ok('返回数组', Array.isArray(tpl.body), JSON.stringify(tpl.body).slice(0, 200));
  ok('首次读取自动播种（>=3 条）', Array.isArray(tpl.body) && tpl.body.length >= 3,
    '条数=' + (Array.isArray(tpl.body) ? tpl.body.length : 'N/A'));
  ok('模板结构含 id 与 content',
    Array.isArray(tpl.body) && tpl.body.length > 0 &&
    'id' in tpl.body[0] && 'content' in tpl.body[0],
    JSON.stringify(tpl.body && tpl.body[0]));

  console.log('\n【三】好友接口返回附言字段');
  const fr = await req('GET', '/api/friends', null, token);
  ok('GET /friends 通', fr.status === 200, 'status=' + fr.status);
  ok('返回 friends / pending 两组',
    !!(fr.body && Array.isArray(fr.body.friends) && Array.isArray(fr.body.pending)),
    JSON.stringify(fr.body).slice(0, 200));

  console.log('\n【四】用户资料可查（他人）');
  const one = await req('GET', '/api/users/1', null, token);
  ok('GET /users/1 通', one.status === 200, 'status=' + one.status);
  ok('公开资料带 signature 字段',
    !!(one.body && Object.prototype.hasOwnProperty.call(one.body, 'signature')),
    JSON.stringify(one.body).slice(0, 200));
  const badId = await req('GET', '/api/users/abc', null, token);
  ok('非法用户 id → 400 而非 500', badId.status === 400, 'status=' + badId.status);

  console.log('\n【五】编辑消息已下线');
  // 用不存在的会话/消息 id 探测：只关心"不是 200 成功"
  const ed = await req('PATCH', '/api/conversations/999999/messages/999999',
    { content: 'x' }, token);
  ok('PATCH 编辑接口不再返回成功', ed.status !== 200, 'status=' + ed.status);
  ok('返回 403/404（会话越权/不存在）或 410（已下线）',
    [403, 404, 410].includes(ed.status), 'status=' + ed.status);

  console.log('\n' + '='.repeat(50));
  console.log('通过 ' + pass + ' / ' + (pass + fail));
  if (fail) {
    console.log('失败项：');
    for (const b of bad) console.log('  - ' + b);
  }
  console.log('='.repeat(50));
  process.exit(fail ? 1 : 0);
})().catch((e) => {
  console.log('探测异常: ' + e.message);
  process.exit(1);
});
