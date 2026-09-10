/**
 * 小智IM 开放集成层 · 端到端对接演示
 *
 * 一条命令跑通「外部软件 ↔ 小智IM」的全部通道，同时把每一步的真实请求/响应打出来，
 * 可以直接当成对接文档抄给第三方系统的开发者。
 *
 * 用法：
 *   node demo_integration.js                      # 默认 http://127.0.0.1:3602
 *   node demo_integration.js http://192.168.31.44:3602
 *   BASE=... ADMIN_USER=admin ADMIN_PASS=admin123 node demo_integration.js
 */
const http = require('http');
const crypto = require('crypto');

const BASE = (process.argv[2] || process.env.BASE || 'http://127.0.0.1:3602').replace(/\/$/, '');
const ADMIN_USER = process.env.ADMIN_USER || 'admin';
const ADMIN_PASS = process.env.ADMIN_PASS || 'admin123';
const RECV_PORT = Number(process.env.RECV_PORT || 3999);

const line = (t = '') => console.log(t);
const head = (t) => { line(); line('─'.repeat(64)); line('  ' + t); line('─'.repeat(64)); };
const step = (t) => line(`\n▸ ${t}`);
const show = (label, v) => line(`  ${label}: ${typeof v === 'string' ? v : JSON.stringify(v)}`);

async function api(p, { method = 'GET', token, body } = {}) {
  const r = await fetch(BASE + '/api' + p, {
    method,
    headers: {
      'Content-Type': 'application/json',
      ...(token ? { Authorization: 'Bearer ' + token } : {}),
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  const j = await r.json().catch(() => null);
  if (r.status >= 400) throw new Error(`${method} ${p} -> ${r.status} ${JSON.stringify(j)}`);
  return j;
}

/** 模拟"你自己的系统"：一个接收回调的 HTTP 服务 */
function startReceiver() {
  const got = [];
  const srv = http.createServer((req, res) => {
    let raw = '';
    req.on('data', (c) => { raw += c; });
    req.on('end', () => {
      got.push({ url: req.url, headers: req.headers, raw });
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end('{"ok":true}');
    });
  });
  return new Promise((r) => srv.listen(RECV_PORT, '127.0.0.1', () => r({ srv, got })));
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

(async () => {
  head('小智IM 开放集成层 · 端到端对接演示');
  show('服务端地址', BASE);

  const recv = await startReceiver();

  try {
    /* ---------- 0. 登录管理后台（只有人做配置时才需要登录） ---------- */
    step('登录管理后台');
    const admin = (await api('/auth/login', {
      method: 'POST', body: { username: ADMIN_USER, password: ADMIN_PASS },
    })).token;
    show('管理员令牌', admin.slice(0, 24) + '…');

    /* ---------- 1. 建一个群（当"工厂管理群"） ---------- */
    step('建一个群作为推送目标');
    const g = await api('/groups', { method: 'POST', token: admin, body: { name: '工厂管理群' } });
    show('群会话 id (conversationId)', g.conversationId);
    show('群 id (groupId)', g.groupId);

    /* ---------- 2. 建机器人：群里以"系统"身份发言 ---------- */
    step('创建机器人（能被拉进群、能发言，但无法登录）');
    const bot = await api('/admin/integrations/bots', {
      method: 'POST', token: admin, body: { name: '工厂助手', conversationId: g.conversationId },
    });
    show('机器人 id', bot.id);
    show('机器人账号', bot.username);
    line('  （已自动加入群，所以下面推送的消息群里能收到）');

    /* ---------- 3. 入站 Webhook：最简通道，一个 POST 就推消息 ---------- */
    step('创建入站 Webhook（免登录推送地址）');
    const hook = await api('/admin/integrations/incoming', {
      method: 'POST', token: admin,
      body: { name: '工厂V2-库存预警', botId: bot.id, conversationId: g.conversationId, signed: false },
    });
    const pushUrl = BASE + hook.path;
    show('推送地址', pushUrl);
    line('  对方系统只需要：POST 这个地址 + JSON body，不需要任何鉴权头。');

    step('① 推一条纯文字（最简写法）');
    const r1 = await fetch(pushUrl, {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ text: '【库存预警】东北大米只剩 3 袋，低于安全库存 10 袋' }),
    });
    show('响应', await r1.json());

    step('② 推一张卡片（日报 / 预警 / 审批单就用这个）');
    const cardBody = {
      title: '销售日报 · 9月10日',
      text: '今日门店整体销售达成率 92%，有 2 个品类未达标。',
      color: 'orange',
      fields: [
        { label: '销售额', value: '¥128,600', short: true },
        { label: '环比', value: '+8.4%', short: true },
        { label: '客单价', value: '¥68.2', short: true },
        { label: '来客数', value: '1,886', short: true },
        { label: '未达标品类', value: '生鲜、日配' },
      ],
      footer: '数据来源：工厂管理系统 V2',
      url: 'https://example.com/report/2026-09-10',
    };
    show('请求体', cardBody);
    const r2 = await fetch(pushUrl, {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(cardBody),
    });
    show('响应', await r2.json());
    line('  color 可选：red 预警 / orange 提醒 / green 正常 / blue 信息 / purple / gray');

    step('③ @所有人（群里会亮「有人@我」）');
    const r3 = await fetch(pushUrl, {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ text: '请各位店长今天下班前核对库存差异', mentions: ['all'] }),
    });
    show('响应', await r3.json());

    /* ---------- 4. 开启签名校验：地址外泄也不怕 ---------- */
    step('创建带签名的推送地址（生产环境建议开启）');
    const hook2 = await api('/admin/integrations/incoming', {
      method: 'POST', token: admin,
      body: { name: '工厂V2-签名通道', botId: bot.id, conversationId: g.conversationId, signed: true },
    });
    const secret = hook2.secret;
    const rawBody = JSON.stringify({ title: '带签名的预警', text: '这条请求带了 HMAC 签名', color: 'red' });
    const sig = 'sha256=' + crypto.createHmac('sha256', secret).update(rawBody, 'utf8').digest('hex');
    show('签名密钥 secret', secret);
    show('请求头 X-Xiaozhi-Signature', sig);
    const r4 = await fetch(BASE + hook2.path, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'X-Xiaozhi-Signature': sig },
      body: rawBody,
    });
    show('正确签名 → 响应', await r4.json());
    const r5 = await fetch(BASE + hook2.path, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'X-Xiaozhi-Signature': 'sha256=wrong' },
      body: rawBody,
    });
    show('错误签名 → HTTP', r5.status + ' ' + JSON.stringify(await r5.json()));

    /* ---------- 5. 开放 API：令牌方式读会话 / 发消息 ---------- */
    step('发放 API 令牌（给程序用的长期凭证，按需授权）');
    const tok = await api('/admin/integrations/tokens', {
      method: 'POST', token: admin,
      body: {
        name: '工厂V2-服务账号', userId: bot.id,
        scopes: ['message:send', 'message:read', 'conversation:read', 'user:read'],
      },
    });
    show('令牌（只返回这一次，请立刻保存）', tok.token);
    const T = tok.token;

    step('用令牌调开放接口');
    const me = await api('/open/me', { token: T });
    show('GET /api/open/me', { identity: me.identity.nickname, scopes: me.scopes });
    const convs = await api('/open/conversations', { token: T });
    show('GET /api/open/conversations', convs.items.map((c) => `${c.id}(${c.type}) ${c.title}`));
    const sent = await api(`/open/conversations/${g.conversationId}/messages`, {
      method: 'POST', token: T,
      body: { title: '开放 API 推送', text: '这条是通过 API 令牌发出的', color: 'blue' },
    });
    show('POST /api/open/conversations/:id/messages', { messageId: sent.id, kind: sent.kind });

    step('权限隔离：只有 message:send 的令牌读不了用户列表');
    const tok2 = await api('/admin/integrations/tokens', {
      method: 'POST', token: admin, body: { name: '只发不收', userId: bot.id, scopes: ['message:send'] },
    });
    const denied = await fetch(BASE + '/api/open/users', { headers: { Authorization: 'Bearer ' + tok2.token } });
    show('GET /api/open/users → HTTP', denied.status + ' ' + JSON.stringify(await denied.json()));

    /* ---------- 6. 出站 Webhook：IM 事件回调到你的系统 ---------- */
    step('创建事件订阅（群里有动静就回调你的系统）');
    const oh = await api('/admin/integrations/outgoing', {
      method: 'POST', token: admin,
      body: {
        name: '工厂V2-消息回调',
        url: `http://127.0.0.1:${RECV_PORT}/xiaozhi/hook`,
        events: ['message.created', 'message.mention'],
      },
    });
    show('回调地址', oh.url);
    show('验签密钥', oh.secret);

    step('发一条群消息，看回调长什么样');
    await api(`/conversations/${g.conversationId}/messages`, {
      method: 'POST', token: admin, body: { kind: 'text', content: '这条消息会触发回调' },
    });
    await sleep(900);
    const got = recv.got.find((x) => x.url === '/xiaozhi/hook');
    if (!got) {
      line('  ✗ 没收到回调（请检查地址是否可达）');
    } else {
      show('回调请求头 X-Xiaozhi-Event', got.headers['x-xiaozhi-event']);
      show('回调请求头 X-Xiaozhi-Signature', got.headers['x-xiaozhi-signature']);
      const want = 'sha256=' + crypto.createHmac('sha256', oh.secret).update(got.raw, 'utf8').digest('hex');
      show('本地验签结果', got.headers['x-xiaozhi-signature'] === want ? '✅ 签名一致，来源可信' : '✗ 签名不一致');
      line('  回调 body：');
      line('  ' + JSON.stringify(JSON.parse(got.raw), null, 2).split('\n').join('\n  '));
    }

    step('投递日志（失败会自动重试，可手工重发）');
    const dels = await api(`/admin/integrations/deliveries?hookId=${oh.id}`, { token: admin });
    for (const d of dels.slice(0, 5)) {
      show(`#${d.id} ${d.event}`, `ok=${d.ok} status=${d.status} attempts=${d.attempts}`);
    }

    /* ---------- 7. 订阅事件清单 ---------- */
    step('可订阅的事件（meta 接口会返回这份清单）');
    const meta = await api('/admin/integrations/meta', { token: admin });
    for (const e of meta.events) line(`  · ${e.name.padEnd(22)} ${e.desc}`);
    line('  （订阅时留空 = 订阅全部）');

    /* ---------- 8. 清理 ---------- */
    step('清理演示数据');
    await api(`/admin/integrations/outgoing/${oh.id}`, { method: 'DELETE', token: admin });
    await api(`/admin/integrations/bots/${bot.id}`, { method: 'DELETE', token: admin });
    await api(`/groups/${g.groupId}`, { method: 'DELETE', token: admin }).catch(() => {});
    line('  已删除演示用的机器人 / 订阅（机器人删除时它的推送地址与令牌会一并清理）');
    line('  ⚠ 演示群与消息保留，可在管理后台手动删除');

    head('演示结束 —— 上面的地址、令牌、密钥都是真实可用的，抄给对接方即可');
  } catch (e) {
    line('\n✗ 演示中断：' + e.message);
    process.exitCode = 1;
  } finally {
    recv.srv.close();
  }
})();
