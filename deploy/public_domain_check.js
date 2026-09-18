// 外网穿透域名全链路体检（隧道到底能不能撑起整个客户端）
//
//   node deploy/public_domain_check.js [域名]
//
// 为什么单独做这一份：局域网通 ≠ 外网通。隧道最容易在**两个地方**悄悄瘸掉，
// 而这两个恰好都是"打开 App 看着正常、用起来才发现不对"：
//   ① **WebSocket 升级**：只代理普通 HTTP 的隧道不给 Upgrade → 消息收不到实时推送，
//      用户表现是"要下拉刷新才出新消息"，极难往隧道上想；
//   ② **长连接被隧道静默回收**：能连上、但几分钟后无声断掉（心跳帧是关键证据）。
// 所以本脚本必须**真的连一次 WS 并收到服务端的 connected 帧**，
// 而不是只看 HTTP 200。
//
// 只读 + 幂等改写设置（写成当前值），不产生任何业务数据。

const path = require('path');
const WebSocket = require(path.join(__dirname, '..', 'server', 'node_modules', 'ws'));

const DOMAIN = (process.argv[2] || 'https://39e4d73830e146799c3d92ff4e040e3b.hn.takin.cc').replace(/\/+$/, '');
const WS_DOMAIN = DOMAIN.replace(/^http/, 'ws');
const PW_FILE = 'D:\\Users\\pblpa\\Desktop\\小智 IM\\小智管理台新密码-请勿外传.txt';
const fs = require('fs');

let pass = 0, fail = 0;
const ok = (n, c, e) => {
  if (c) { pass++; console.log('  OK   ' + n); }
  else { fail++; console.log('  FAIL ' + n + (e ? '  -> ' + e : '')); }
};
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const t0 = Date.now();

async function api(method, p, token, body) {
  const res = await fetch(DOMAIN + p, {
    method,
    headers: {
      'Content-Type': 'application/json',
      ...(token ? { Authorization: 'Bearer ' + token } : {}),
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  let json = null;
  try { json = await res.json(); } catch { /* 可能无 body */ }
  return { status: res.status, body: json };
}

(async () => {
  console.log(`[外网全链路体检] ${DOMAIN}\n`);

  // ① 免鉴权启动接口（客户端冷启动第一步）
  const t1 = Date.now();
  const boot = await fetch(DOMAIN + '/api/client/bootstrap').then((r) => r.json());
  const bootMs = Date.now() - t1;
  ok('bootstrap 可达', !!boot.serverVersion, JSON.stringify(boot).slice(0, 120));
  ok('下发公司名（客户端标题靠它）', boot.companyName === '好又多', JSON.stringify(boot.companyName));
  ok('下发好友模式（导航形态靠它）', boot.friendMode === 'work', String(boot.friendMode));
  console.log(`      服务端版本 ${boot.serverVersion} · 免鉴权接口耗时 ${bootMs}ms`);

  // ② 走隧道登录（带 body 的 POST，验证隧道不吞请求体）
  const pw = fs.readFileSync(PW_FILE, 'utf8').match(/^新密码\s*[:：]\s*(\S+)\s*$/m)[1];
  const t2 = Date.now();
  const lg = await api('POST', '/api/auth/login', null, { username: 'admin', password: pw });
  ok('外网登录成功（隧道转发 POST body 正常）',
    lg.status === 200 && !!lg.body?.token, lg.status + ' ' + JSON.stringify(lg.body).slice(0, 100));
  console.log(`      登录耗时 ${Date.now() - t2}ms`);
  const tok = lg.body.token;

  // ③ 隧道下的 WebSocket —— 这一条才是"外网真的能用"的命门
  const frames = [];
  const ws = new WebSocket(`${WS_DOMAIN}/ws?token=${encodeURIComponent(tok)}`);
  let connectedFrame = null;
  const wsErr = await new Promise((res) => {
    const t = setTimeout(() => res('超时 15s（隧道很可能不支持 Upgrade）'), 15000);
    ws.on('open', () => { clearTimeout(t); res(null); });
    ws.on('error', (e) => { clearTimeout(t); res(e.message); });
  });
  ok('WebSocket 经隧道建立成功', wsErr === null, String(wsErr));
  ws.on('message', (d) => { try { frames.push(JSON.parse(d.toString())); } catch { /* 忽略 */ } });
  // 等 connected 帧：**用轮询，不要固定 sleep**。
  // 隧道首次建连可能几百毫秒到两秒才把首帧带过来，固定等 1.2s 会得到假失败
  // （2026-09-18 实测踩到过一次：同一条链路上一轮过、下一轮挂，纯看时序）。
  for (let i = 0; i < 40 && !connectedFrame; i++) {
    await sleep(200);
    connectedFrame = frames.find((f) => f.type === 'connected');
  }
  ok('收到服务端 connected 帧（证明是双向长连接，不是单向挂名）', !!connectedFrame,
    JSON.stringify(frames).slice(0, 160));

  // ④ 长连接存活探测（隧道会在空闲时静默回收，这是"看着在线其实掉线"的源头）
  await sleep(4000);
  ok('闲置 4 秒后连接仍在 OPEN 状态', ws.readyState === WebSocket.OPEN,
    'readyState=' + ws.readyState);

  // ⑤ 上游取数通道（门店日报就是要靠它在客户端里出数）
  const up = await api('GET', '/api/hooks/up/tiger/report/daily', tok);
  const payload = up.body?.data;
  ok('上游取数通道可访问', up.status === 200 && !!payload, up.status + ' ' + JSON.stringify(up.body).slice(0, 120));
  const rows = payload?.summary_rows;
  ok('真的取到业务数据（不是空壳）', Array.isArray(rows) && rows.length > 0,
    // String(...) 必须有：失败时 payload 是 undefined，JSON.stringify 返回的也是
    // undefined（不是字符串），直接 .slice 会抛，把"通道不通"变成"脚本崩了"
    String(JSON.stringify(payload)).slice(0, 160));

  // ⑥ 设置变更广播（幂等改写当前值，客户端无感）
  frames.length = 0;
  const put = await api('PUT', '/api/admin/settings', tok, { companyName: boot.companyName });
  ok('保存设置 200', put.status === 200, String(put.status));
  await sleep(1200);
  ok('隧道下也能收到 settings:changed 广播',
    frames.filter((f) => f.type === 'settings:changed').length === 1,
    JSON.stringify(frames).slice(0, 160));

  ws.close();
  console.log(`\n总耗时 ${((Date.now() - t0) / 1000).toFixed(1)}s`);
  console.log('='.repeat(48));
  console.log(`通过 ${pass} / ${pass + fail}`);
  console.log('='.repeat(48));
  process.exit(fail ? 1 : 0);
})().catch((e) => { console.error('异常中断：', e); process.exit(1); });
