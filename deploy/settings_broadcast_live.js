// 线上验证：管理台改设置 → 在线客户端是否「当场」收到（0.18.1 新增的 settings:changed）
//
//   node deploy/settings_broadcast_live.js
//
// 为什么要有这个脚本：这条链路是"用户说改了没生效"的根治手段，一旦回归，
// 表现和 0.14.x 一模一样（管理台显示新公司名、客户端纹丝不动），
// 而本地 e2e 用的是隔离实例、证明不了**线上这台**的容器/配置没把广播吃掉。
//
// 安全性：全程用**当前值**做幂等改写（写成和现在一样的公司名），
// 所以对在线客户端是无感的 —— 值没变，只是把广播链路走通一遍。
// 密码现读桌面文件，不写进本脚本。

const fs = require('fs');
const path = require('path');
const WebSocket = require(path.join(__dirname, '..', 'server', 'node_modules', 'ws'));

const BASE = 'http://192.168.31.44:3602';
const PW_FILE = 'D:\\Users\\pblpa\\Desktop\\小智 IM\\小智管理台新密码-请勿外传.txt';

let pass = 0, fail = 0;
const ok = (name, cond, extra) => {
  if (cond) { pass++; console.log('  OK   ' + name); }
  else { fail++; console.log('  FAIL ' + name + (extra ? '  -> ' + extra : '')); }
};
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function api(method, p, token, body) {
  const res = await fetch(BASE + p, {
    method,
    headers: {
      'Content-Type': 'application/json',
      ...(token ? { Authorization: 'Bearer ' + token } : {}),
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  let json = null;
  try { json = await res.json(); } catch { /* 可能没有 body */ }
  return { status: res.status, body: json };
}

(async () => {
  const raw = fs.readFileSync(PW_FILE, 'utf8');
  const m = raw.match(/^新密码\s*[:：]\s*(\S+)\s*$/m);
  if (!m) { console.error('密码文件里没找到「新密码」那一行：' + PW_FILE); process.exit(1); }
  const pw = m[1];

  console.log('[线上广播自检] ' + BASE + '\n');

  // ① 登录 + 看当前值
  const lg = await api('POST', '/api/auth/login', null, { username: 'admin', password: pw });
  ok('管理员登录', lg.status === 200 && !!lg.body?.token, lg.status + ' ' + JSON.stringify(lg.body).slice(0, 100));
  const tok = lg.body.token;

  const cur = await api('GET', '/api/admin/settings', tok);
  ok('读到当前设置', cur.status === 200, String(cur.status));
  const curName = cur.body.companyName;
  const curMode = cur.body.friendMode;
  console.log(`      当前公司名="${curName}"  好友模式=${curMode}`);
  if (curName !== '好又多') {
    console.log('      ⚠️ 当前公司名不是「好又多」，本次会原样写回，不会改你的设置');
  }

  // ② 连 WS，收广播
  const frames = [];
  const ws = new WebSocket(`${BASE.replace('http', 'ws')}/ws?token=${encodeURIComponent(tok)}`);
  const werr = await new Promise((res) => {
    const t = setTimeout(() => res('timeout'), 8000);
    ws.on('open', () => { clearTimeout(t); res(null); });
    ws.on('error', (e) => { clearTimeout(t); res(e.message); });
  });
  ok('建立 WebSocket 连接', werr === null, String(werr));
  ws.on('message', (d) => { try { frames.push(JSON.parse(d.toString())); } catch { /* 忽略 */ } });
  await sleep(300);

  // ③ 幂等改写公司名 -> 必须收到 settings:changed
  frames.length = 0;
  const put = await api('PUT', '/api/admin/settings', tok, { companyName: curName });
  ok('保存设置返回 200', put.status === 200, put.status + ' ' + JSON.stringify(put.body).slice(0, 120));
  await sleep(600);
  const hits = frames.filter((f) => f.type === 'settings:changed');
  ok('在线客户端收到 settings:changed', hits.length === 1, JSON.stringify(frames).slice(0, 200));
  ok('广播里的公司名 = 当前值', hits[0]?.companyName === curName, JSON.stringify(hits[0]));
  ok('广播里带好友模式', hits[0]?.friendMode === curMode, JSON.stringify(hits[0]));

  // ④ 反向断言：非法值 400 时不许推（推了客户端会跟着一个假值跳）
  frames.length = 0;
  const bad = await api('PUT', '/api/admin/settings', tok, { companyName: 'x'.repeat(21) });
  ok('非法公司名被拒（前置条件）', bad.status === 400, String(bad.status));
  await sleep(500);
  ok('设置被拒 → 不广播', frames.filter((f) => f.type === 'settings:changed').length === 0,
    JSON.stringify(frames).slice(0, 200));

  // ⑤ 值没被改坏（幂等改写的最基本要求）
  const after = await api('GET', '/api/admin/settings', tok);
  ok('公司名未被改动', after.body.companyName === curName && after.body.friendMode === curMode,
    JSON.stringify(after.body));

  // ⑥ bootstrap 免鉴权接口也一致（客户端冷启动走这条）
  const boot = await fetch(BASE + '/api/client/bootstrap').then((r) => r.json());
  ok('bootstrap 与设置一致', boot.companyName === curName && boot.friendMode === curMode,
    JSON.stringify({ companyName: boot.companyName, friendMode: boot.friendMode }));

  ws.close();
  console.log('\n' + '='.repeat(46));
  console.log(`通过 ${pass} / ${pass + fail}`);
  console.log('='.repeat(46));
  process.exit(fail ? 1 : 0);
})().catch((e) => { console.error('异常：', e); process.exit(1); });
