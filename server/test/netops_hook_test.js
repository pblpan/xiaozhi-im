// 网络运维自用工具箱 → 小智IM 入站推送 · 互通性测试
//
// 【为什么要有这个测试】
// 「把告警推到 IM 群」看起来只是"填个地址"，但真实失败点全在**报文格式能不能对上**：
// 工具箱的「通用 Webhook」发的是它自己的业务 JSON（event/severity/device_name/...），
// 而 IM 的入站接口只认 { text } / { title,text,fields } / { kind,content } 三种形状。
// 一旦对不上就是 400，而且现场很难看出是"字段名不匹配"。
//
// 所以这里用**工具箱源码里 _send_webhook() 逐字段复制出来的真实报文**打一遍，
// 断言它落到群里之后长什么样。报文样本来自：
//   网络运维自用工具箱 v1.1 · src/alarm_center.py · _send_webhook()
//
//   node test/netops_hook_test.js
//
// ⚠️ 这里刻意把「severity 没有映射成卡片颜色」也断言出来 —— 它不是 bug，
//    是两边协议不一样的事实。写进测试是为了让后来人一眼看到这个缺口存在，
//    而不是等到"告警推上来了但全是蓝色的"才去猜。

const { spawn } = require('child_process');
const path = require('path');
const fs = require('fs');
const os = require('os');

const PORT = 3696;
const BASE = `http://127.0.0.1:${PORT}`;
const SERVER_DIR = path.resolve(__dirname, '..');
const DATA_DIR = path.join(os.tmpdir(), 'xiaozhi-netops-' + Date.now());

let passed = 0, failed = 0;
const failures = [];

function ok(name, cond, extra) {
  if (cond) { passed++; console.log(`  \u2713 ${name}`); }
  else {
    failed++;
    failures.push(name + (extra ? ` — ${extra}` : ''));
    console.log(`  \u2717 ${name}${extra ? '  → ' + extra : ''}`);
  }
}

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
  try { json = await res.json(); } catch { /* 可能是空响应 */ }
  return { status: res.status, body: json };
}

/** 工具箱 _send_webhook() 实际发出的报文（字段名与取值方式逐条对齐源码） */
function netopsPayload(over = {}) {
  const a = {
    severity: 'critical',
    title: '设备离线',
    message: 'Ping 超时，连续 3 次无响应',
    source: 'ping_monitor',
    device_name: '核心交换机-1F',
    device_ip: '192.168.31.2',
    device_id: 7,
    alert_id: 1024,
    triggered_at: '2026-09-13 10:30:00',
    ...over,
  };
  const SEV_TEXT = { info: '提示', warning: '警告', major: '主要', critical: '严重' };
  const sev = SEV_TEXT[a.severity] || a.severity;
  // _fmt_plain()：工具箱拼的那段多行文本，原样带在 text 字段里
  const text = [
    `【${sev}】${a.title || '网络告警'}`,
    `设备：${a.device_name || '-'}（${a.device_ip || '-'}）`,
    `来源：${a.source || '-'}`,
    `时间：${a.triggered_at}`,
    `详情：${a.message || '-'}`,
  ].join('\n');
  return {
    event: 'network_alert',
    severity: a.severity,
    severity_text: sev,
    title: a.title,
    message: a.message,
    source: a.source,
    device_name: a.device_name,
    device_ip: a.device_ip,
    device_id: a.device_id,
    alert_id: a.alert_id,
    triggered_at: a.triggered_at,
    text,
    // 工具箱本身不发 color（上面字段就是从 _send_webhook 抄的）。
    // 这一行只为验证"对接方明确给 color 时优先级高于 severity"，用了才带出去。
    ...(a.color ? { color: a.color } : {}),
  };
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
    },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  child.stdout.on('data', () => {});
  child.stderr.on('data', (d) => process.stderr.write('[server] ' + d));

  const shutdown = () => {
    try { child.kill(); } catch { /* 已退出 */ }
    try { fs.rmSync(DATA_DIR, { recursive: true, force: true }); } catch { /* 目录可能不在了 */ }
  };
  process.on('exit', shutdown);

  for (let i = 0; i < 60; i++) {
    try { if ((await fetch(BASE + '/api/health')).ok) break; } catch { /* 还没起来 */ }
    await new Promise((r) => setTimeout(r, 250));
    if (i === 59) { console.error('服务端起不来'); process.exit(1); }
  }

  console.log('\n[1] 后台准备：登录 / 建群 / 建机器人');
  const login = await api('POST', '/api/auth/login', {
    body: { username: 'admin', password: 'admin-test-pw' },
  });
  ok('管理员登录', login.status === 200, `got=${login.status}`);
  const token = login.body.token;

  const g = await api('POST', '/api/groups', { token, body: { name: '网络运维告警群' } });
  ok('建群成功', g.status === 200 || g.status === 201, JSON.stringify(g.body).slice(0, 120));
  const convId = g.body.conversationId;

  const bot = await api('POST', '/api/admin/integrations/bots', {
    token, body: { name: '网维告警', conversationId: convId },
  });
  ok('建机器人并自动进群', bot.status === 200 && !!bot.body.id, JSON.stringify(bot.body).slice(0, 140));

  /** 读回群里的消息列表（接口在不同版本上返回数组或 {messages}，两种都认） */
  const msgList = async () => {
    const r = await api('GET', `/api/conversations/${convId}/messages`, { token });
    return Array.isArray(r.body) ? r.body : (r.body.messages || []);
  };

  /** 用工具箱报文推一条，返回落库后那张卡片 */
  const pushAndRead = async (over) => {
    const r = await fetch(url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(netopsPayload(over)),
    });
    const l = await msgList();
    const last = l[l.length - 1];
    return { status: r.status, card: last && last.kind === 'card' ? JSON.parse(last.content) : null };
  };

  console.log('\n[2] 建入站推送地址（= 后台「新建推送地址」那一步）');
  const hook = await api('POST', '/api/admin/integrations/incoming', {
    token, body: { name: '网维告警', botId: bot.body.id, conversationId: convId },
  });
  ok('创建成功并拿到地址', hook.status === 200 && !!hook.body.token, JSON.stringify(hook.body).slice(0, 160));
  const url = `${BASE}/api/hooks/incoming/${hook.body.token}`;

  const self = await fetch(url);
  ok('浏览器打开地址自检返回 200', self.status === 200, `got=${self.status}`);

  console.log('\n[3] 把工具箱的真实报文打进来');
  const p1 = netopsPayload();
  const push = await fetch(url, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(p1),
  });
  const pushBody = await push.json().catch(() => null);
  ok('工具箱原样报文被接受（≥ 200）', push.status === 200,
    `got=${push.status} ${JSON.stringify(pushBody)}`);
  ok('回执里认出了推送方是机器人', pushBody && pushBody.bot === '网维告警', pushBody && pushBody.bot);

  console.log('\n[4] 群里实际收到的卡片长什么样');
  const list = await msgList();
  const last = list[list.length - 1];
  ok('消息已落库', !!last, `共 ${list.length} 条`);
  ok('被识别成了卡片（因为报文里带 title）', last && last.kind === 'card', last && last.kind);

  const card = last && last.kind === 'card' ? JSON.parse(last.content) : {};
  console.log('  ── 卡片内容 ──');
  console.log(JSON.stringify(card, null, 2).split('\n').map((s) => '  ' + s).join('\n'));
  console.log('  ─────────────');

  ok('标题取到了工具箱的 title', card.title === '设备离线', card.title);
  ok('正文取到了工具箱的 text（多行保留）',
    typeof card.text === 'string' && card.text.includes('【严重】设备离线')
      && card.text.includes('核心交换机-1F'),
    JSON.stringify(card.text || '').slice(0, 80));
  ok('设备名 / IP / 详情都在正文里没丢',
    String(card.text || '').includes('192.168.31.2')
      && String(card.text || '').includes('Ping 超时'));

  // 工具箱发的是 severity，IM 卡片要的是 color。中间这层映射让"只填个地址"
  // 接进来的告警也能推出正确的颜色，而不是一律默认蓝。
  ok('severity=critical 自动落成红色卡片（严重告警一眼看出）',
    card.color === 'red', card.color);
  ok('工具箱没给 fields，所以卡片没有键值对表格',
    Array.isArray(card.fields) && card.fields.length === 0);

  console.log('\n[5] 四个级别的颜色映射（对齐工具箱 SEV_TEXT / SEV_COLOR）');
  // 工具箱：info=提示 #2563eb / warning=警告 #d97706 / major=主要 #ea580c / critical=严重 #dc2626
  for (const [sev, want] of [['critical', 'red'], ['major', 'red'],
    ['warning', 'orange'], ['info', 'blue']]) {
    const r = await pushAndRead({ severity: sev });
    ok(`severity=${sev} 被接受且落成卡片`, r.status === 200 && !!r.card, `got=${r.status}`);
    ok(`severity=${sev} → 颜色 ${want}`, r.card && r.card.color === want, r.card && r.card.color);
  }
  // 对接方明确指定 color 时必须优先，不许被 severity 覆盖
  const explicit = await pushAndRead({ severity: 'critical', color: 'green' });
  ok('对接方明确给了 color=green 时以它为准（severity 不覆盖）',
    explicit.card && explicit.card.color === 'green', explicit.card && explicit.card.color);
  const unknown = await pushAndRead({ severity: '什么鬼' });
  ok('认不出的 severity 回落默认 blue，不报错',
    unknown.status === 200 && unknown.card.color === 'blue',
    `${unknown.status} ${unknown.card && unknown.card.color}`);

  console.log('\n[5b] 工具→IM 的正文格式（存档用）');
  console.log('```');
  console.log(String(card.text || ''));
  console.log('```');

  console.log('\n[6] 负向：开了签名校验后，工具箱直连会失败吗');
  const signed = await api('POST', '/api/admin/integrations/incoming', {
    token, body: { name: '网维告警-签名', botId: bot.body.id, conversationId: convId, signed: true },
  });
  const signedUrl = `${BASE}/api/hooks/incoming/${signed.body.token}`;
  const noSig = await fetch(signedUrl, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(netopsPayload()),
  });
  ok('没带 X-Xiaozhi-Signature 会被 401 拦掉', noSig.status === 401, `got=${noSig.status}`);
  const netopsStyle = await fetch(signedUrl, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'X-Netops-Token': 'whatever' },
    body: JSON.stringify(netopsPayload()),
  });
  ok('工具箱只会带 X-Netops-Token，IM 不认这个头 → 仍然 401',
    netopsStyle.status === 401, `got=${netopsStyle.status}`);

  console.log('\n[7] 负向：报文形状对不上时必须报错，绝不许把垃圾塞进群');
  // 这是最容易踩的一格：对接方手上已有钉钉/企微的推送代码，直接改个地址就发过来了。
  // 曾经的行为是 String({content:'x'}) → "[object Object]" 且返回 200 —— 群里出乱码，
  // 发送方却以为成功了。下面同时断言"返回 400"和"群里没多消息"。
  const before = (await msgList()).length;

  const dingtalk = await fetch(url, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ msgtype: 'text', text: { content: '钉钉风格' } }),
  });
  const dtBody = await dingtalk.json().catch(() => null);
  ok('钉钉风格报文被 400 拒绝', dingtalk.status === 400, `got=${dingtalk.status}`);
  ok('错误信息点名是 text 字段 + 给出正确写法',
    String(dtBody && dtBody.error).includes('text')
      && String(dtBody && dtBody.error).includes('字符串'),
    JSON.stringify(dtBody));

  const wecom = await fetch(url, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ msgtype: 'markdown', markdown: { content: '企微风格' } }),
  });
  ok('企微风格报文同样被 400（不是只拦了 text 这一个键名）', wecom.status === 400,
    `got=${wecom.status}`);

  const badCard = await fetch(url, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ title: '库存预警', text: { content: '嵌套正文' } }),
  });
  const bcBody = await badCard.json().catch(() => null);
  ok('卡片里的 text 是对象时被 400', badCard.status === 400, `got=${badCard.status}`);
  ok('并且指名道姓说清是哪个字段坏了',
    String(bcBody && bcBody.error).includes('卡片字段 text'), JSON.stringify(bcBody));

  const after = (await msgList()).length;
  ok('三次被拒的请求一条消息都没落进群', after === before, `${before} → ${after}`);

  console.log('\n[8] 负向：真·畸形输入也不能把服务端打崩');
  for (const bad of ['不是对象', 123, null, [1, 2, 3]]) {
    const r = await fetch(url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(bad),
    });
    ok(`body=${JSON.stringify(bad)} 返回 4xx 而不是 5xx`, r.status >= 400 && r.status < 500,
      `got=${r.status}`);
  }
  const stillAlive = await fetch(BASE + '/api/health');
  ok('挨完一轮畸形请求后服务端仍健康', stillAlive.ok, `got=${stillAlive.status}`);

  console.log('\n' + '='.repeat(52));
  console.log(`通过 ${passed} 项，失败 ${failed} 项`);
  if (failures.length) {
    console.log('失败明细：');
    failures.forEach((f) => console.log('  - ' + f));
  }
  console.log('='.repeat(52));
  child.kill();
  process.exit(failed ? 1 : 0);
}

main().catch((e) => { console.error(e); process.exit(1); });
