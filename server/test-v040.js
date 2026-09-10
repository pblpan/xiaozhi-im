/**
 * 小智IM v0.4.0 功能回归测试：开放集成层
 * 覆盖：机器人 / API 令牌与 scope / 开放 API / 入站 Webhook（含签名）/ 出站 Webhook（含重试）/ 卡片消息
 * 用法：node test-v040.js
 */
const { spawn } = require('child_process');
const http = require('http');
const crypto = require('crypto');
const path = require('path');
const fs = require('fs');
const os = require('os');
const WebSocket = require('ws');

const PORT = 3804;
const HOOK_PORT = 3805;
const BASE = `http://127.0.0.1:${PORT}`;
const DATA = path.join(os.tmpdir(), 'xz-v040-test');
const DB_FILE = path.join(DATA, 't.db');

fs.rmSync(DATA, { recursive: true, force: true });
fs.mkdirSync(DATA, { recursive: true });

const env = {
  ...process.env,
  PORT: String(PORT),
  ADMIN_PASSWORD: 'test123',
  JWT_SECRET: 'testsecret',
  DB_PATH: DB_FILE,
  DATA_DIR: DATA,
  FILES_DIR: path.join(DATA, 'files'),
};

let pass = 0, fail = 0;
const ok = (name, cond, extra = '') => {
  if (cond) { pass++; console.log(`  \u2705 ${name}`); }
  else { fail++; console.log(`  \u274c ${name}${extra ? '  -> ' + extra : ''}`); }
};
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function api(p, { method = 'GET', token, body, headers = {}, raw } = {}) {
  const r = await fetch(BASE + '/api' + p, {
    method,
    headers: {
      'Content-Type': 'application/json',
      ...(token ? { Authorization: 'Bearer ' + token } : {}),
      ...headers,
    },
    body: raw !== undefined ? raw : (body ? JSON.stringify(body) : undefined),
  });
  const j = await r.json().catch(() => null);
  return { status: r.status, body: j };
}

function connectWs(token) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(`ws://127.0.0.1:${PORT}/ws?token=${token}`);
    const frames = [];
    ws.on('message', (d) => { try { frames.push(JSON.parse(d.toString())); } catch { /* ignore */ } });
    ws.on('open', () => resolve({ ws, frames }));
    ws.on('error', reject);
  });
}

async function waitFor(fn, timeout = 3000) {
  const t0 = Date.now();
  while (Date.now() - t0 < timeout) {
    if (fn()) return true;
    await sleep(40);
  }
  return false;
}

/* ---------- 模拟"外部系统"：一个接收回调的 HTTP 服务器 ---------- */
const received = [];
function startReceiver() {
  const srv = http.createServer((req, res) => {
    let raw = '';
    req.on('data', (c) => { raw += c; });
    req.on('end', () => {
      received.push({
        url: req.url,
        headers: req.headers,
        raw,
        body: (() => { try { return JSON.parse(raw); } catch { return null; } })(),
      });
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end('{"ok":true}');
    });
  });
  return new Promise((resolve) => srv.listen(HOOK_PORT, '127.0.0.1', () => resolve(srv)));
}

(async () => {
  const recv = await startReceiver();
  const srv = spawn(process.execPath, ['src/index.js'], {
    cwd: __dirname, env, stdio: ['ignore', 'pipe', 'pipe'],
  });
  srv.stdout.on('data', (d) => process.stdout.write('  [srv] ' + d));
  srv.stderr.on('data', (d) => {
    const s = d.toString();
    if (!s.includes('ExperimentalWarning') && !s.includes('trace-warnings')) {
      process.stderr.write('  [srv:err] ' + s);
    }
  });

  let exitCode = 0;
  try {
    let up = false;
    for (let i = 0; i < 60; i++) {
      try { const r = await fetch(BASE + '/api/health'); if (r.status === 200) { up = true; break; } } catch { /* retry */ }
      await sleep(150);
    }
    if (!up) throw new Error('服务未启动');

    /* ==================== 准备 ==================== */
    console.log('\n=== 0. 准备：账号 / 群 / 成员 ===');
    const admin = (await api('/auth/login', { method: 'POST', body: { username: 'admin', password: 'test123' } })).body.token;
    const mk = async (u, n) => (await api('/admin/users', { method: 'POST', token: admin, body: { username: u, password: 'abc123', nickname: n } })).body.id;
    const aliceId = await mk('alice', '爱丽丝');
    const bobId = await mk('bob', '鲍勃');
    const login = async (u) => (await api('/auth/login', { method: 'POST', body: { username: u, password: 'abc123' } })).body.token;
    const alice = await login('alice');
    const bob = await login('bob');
    const A = await connectWs(alice);
    const B = await connectWs(bob);
    ok('账号与 WebSocket 就绪', !!(aliceId && bobId && A.ws && B.ws));

    const g = (await api('/groups', { method: 'POST', token: alice, body: { name: '工厂管理群' } })).body;
    await api(`/groups/${g.groupId}/members`, { method: 'POST', token: alice, body: { userId: bobId } });
    const gcid = g.conversationId;
    ok('建群并拉入 bob', !!gcid);

    /* ==================== 1. 集成元信息 ==================== */
    console.log('\n=== 1. 集成元信息 ===');
    const meta = await api('/admin/integrations/meta', { token: admin });
    ok('meta 返回 scope 清单', Array.isArray(meta.body?.scopes) && meta.body.scopes.length >= 6);
    ok('meta 返回事件清单', Array.isArray(meta.body?.events) && meta.body.events.some((e) => e.name === 'message.created'));
    ok('meta 返回会话下拉选项', meta.body.conversations.some((c) => c.id === gcid));
    ok('非管理员访问集成接口被拒', (await api('/admin/integrations/meta', { token: alice })).status === 403);
    ok('无 token 访问集成接口被拒', (await api('/admin/integrations/meta')).status === 401);

    /* ==================== 2. 机器人 ==================== */
    console.log('\n=== 2. 机器人 ===');
    const bot = (await api('/admin/integrations/bots', {
      method: 'POST', token: admin, body: { name: '工厂助手', conversationId: gcid },
    })).body;
    ok('创建机器人', !!bot.id && bot.is_bot === true);
    ok('机器人被自动拉进群', (await api(`/conversations/${gcid}/messages`, { token: alice }))
      .body.members.some((m) => m.user_id === bot.id));
    ok('机器人不能被登录', (await api('/auth/login', { method: 'POST', body: { username: bot.username, password: 'abc123' } })).status === 401);
    ok('空名字机器人被拒', (await api('/admin/integrations/bots', { method: 'POST', token: admin, body: { name: '  ' } })).status === 400);
    const bot2 = (await api('/admin/integrations/bots', { method: 'POST', token: admin, body: { name: '告警机器人' } })).body;
    ok('第二个机器人账号不重复', bot2.username !== bot.username);
    ok('机器人列表', (await api('/admin/integrations/bots', { token: admin })).body.length === 2);

    /* ==================== 3. API 令牌与 scope ==================== */
    console.log('\n=== 3. API 令牌与 scope ===');
    const tokFull = (await api('/admin/integrations/tokens', {
      method: 'POST', token: admin,
      body: { name: '工厂V2', userId: bot.id, scopes: ['message:send', 'message:read', 'conversation:read', 'user:read'] },
    })).body;
    ok('创建令牌并返回明文', typeof tokFull.token === 'string' && tokFull.token.startsWith('xz_'));
    ok('令牌 scope 落库正确', tokFull.scopes.length === 4);
    ok('列表接口对令牌打码', (await api('/admin/integrations/tokens', { token: admin }))
      .body.find((t) => t.id === tokFull.id).token.includes('…'));
    ok('未知 scope 被过滤', (await api('/admin/integrations/tokens', {
      method: 'POST', token: admin, body: { name: 'x', scopes: ['message:send', 'hack:everything'] },
    })).body.scopes.length === 1);
    ok('空 scope 被拒', (await api('/admin/integrations/tokens', {
      method: 'POST', token: admin, body: { name: 'x', scopes: [] },
    })).status === 400);
    ok('令牌身份不存在被拒', (await api('/admin/integrations/tokens', {
      method: 'POST', token: admin, body: { name: 'x', userId: 99999, scopes: ['message:send'] },
    })).status === 400);

    const T = tokFull.token;
    ok('伪造令牌被拒', (await api('/open/me', { token: 'xz_deadbeef' })).status === 401);
    ok('无凭证被拒', (await api('/open/me')).status === 401);

    /* ==================== 4. 开放 API ==================== */
    console.log('\n=== 4. 开放 API ===');
    const me = await api('/open/me', { token: T });
    ok('/open/me 返回身份与权限', me.body?.identity?.id === bot.id && me.body.scopes.includes('message:send'));
    const convs = await api('/open/conversations', { token: T });
    ok('/open/conversations 列出机器人所在会话', convs.body.items.some((c) => c.id === gcid));
    const members = await api(`/open/conversations/${gcid}/members`, { token: T });
    ok('/open/conversations/:id/members', members.body.items.length === 3);

    const sent = await api(`/open/conversations/${gcid}/messages`, {
      method: 'POST', token: T, body: { text: '库存日报：今日出库 128 件' },
    });
    ok('令牌发文字消息', sent.status === 200 && sent.body.kind === 'text');
    ok('群成员实时收到机器人消息', await waitFor(() => A.frames.some((f) => f.type === 'message:new' && f.message?.id === sent.body.id)));

    const sentCard = await api(`/open/conversations/${gcid}/messages`, {
      method: 'POST', token: T,
      body: { title: '库存预警', text: '3 个商品低于安全库存', color: 'red', fields: [{ label: '东北大米', value: '剩 3 袋' }] },
    });
    ok('不带 kind 自动识别为卡片', sentCard.body.kind === 'card');
    const cardContent = JSON.parse(sentCard.body.content);
    ok('卡片字段正确落库', cardContent.title === '库存预警' && cardContent.color === 'red' && cardContent.fields.length === 1);

    const users = await api('/open/users?q=爱丽', { token: T });
    ok('/open/users 关键词搜索', users.body.items.length === 1 && users.body.items[0].id === aliceId);
    ok('/open/bots 列出机器人', (await api('/open/bots', { token: T })).body.items.length === 2);

    // scope 越权
    const tokSendOnly = (await api('/admin/integrations/tokens', {
      method: 'POST', token: admin, body: { name: '只读发送', userId: bot.id, scopes: ['message:send'] },
    })).body.token;
    ok('缺 conversation:read → 403', (await api('/open/conversations', { token: tokSendOnly })).status === 403);
    ok('缺 user:read → 403', (await api('/open/users', { token: tokSendOnly })).status === 403);
    ok('有 message:send 可发消息', (await api(`/open/conversations/${gcid}/messages`, {
      method: 'POST', token: tokSendOnly, body: { text: 'ok' },
    })).status === 200);

    // 非成员会话越权
    const dm = (await api(`/conversations/dm/${bobId}`, { token: alice })).body.conversationId;
    ok('机器人不在的单聊 → 403', (await api(`/open/conversations/${dm}/messages`, {
      method: 'POST', token: T, body: { text: 'x' },
    })).status === 403);

    /* ==================== 5. 卡片校验 ==================== */
    console.log('\n=== 5. 卡片消息校验 ===');
    const emptyCard = await api(`/open/conversations/${gcid}/messages`, {
      method: 'POST', token: T, body: { kind: 'card', content: {} },
    });
    ok('空卡片被拒', emptyCard.status === 400);
    const badColor = await api(`/open/conversations/${gcid}/messages`, {
      method: 'POST', token: T, body: { title: 'x', color: 'neon-pink' },
    });
    ok('非法颜色兜底为 blue', JSON.parse(badColor.body.content).color === 'blue');
    const longText = await api(`/open/conversations/${gcid}/messages`, {
      method: 'POST', token: T, body: { kind: 'card', content: { title: 'a'.repeat(200), text: 'b'.repeat(5000) } },
    });
    ok('卡片超长字段被截断', JSON.parse(longText.body.content).title.length === 80);
    ok('卡片正文截断到 2000', JSON.parse(longText.body.content).text.length === 2000);
    ok('卡片非法 URL 被清空', JSON.parse((await api(`/open/conversations/${gcid}/messages`, {
      method: 'POST', token: T, body: { title: 'x', url: 'javascript:alert(1)' },
    })).body.content).url === '');
    ok('文字超长被拒', (await api(`/open/conversations/${gcid}/messages`, {
      method: 'POST', token: T, body: { kind: 'text', content: 'x'.repeat(8001) },
    })).status === 400);
    ok('不支持的消息类型被拒', (await api(`/open/conversations/${gcid}/messages`, {
      method: 'POST', token: T, body: { kind: 'video', content: 'x' },
    })).status === 400);

    /* ==================== 6. 入站 Webhook ==================== */
    console.log('\n=== 6. 入站 Webhook（免登录推送）===');
    const ih = (await api('/admin/integrations/incoming', {
      method: 'POST', token: admin, body: { name: '工厂预警', botId: bot.id, conversationId: gcid, signed: false },
    })).body;
    ok('创建入站 Webhook', !!ih.token && ih.path === `/api/hooks/incoming/${ih.token}`);

    ok('GET 地址可自检', (await api(`/hooks/incoming/${ih.token}`)).body?.ok === true);
    ok('未知 token → 401', (await api('/hooks/incoming/nope', { method: 'POST', body: { text: 'x' } })).status === 401);

    const push1 = await api(`/hooks/incoming/${ih.token}`, { method: 'POST', body: { text: '【预警】东北大米库存不足' } });
    ok('免登录推文字', push1.status === 200 && push1.body.ok === true);
    ok('推送消息实时到达群成员', await waitFor(() => B.frames.some((f) => f.type === 'message:new' && f.message?.id === push1.body.messageId)));
    ok('推送以机器人身份发出', (await api(`/conversations/${gcid}/messages`, { token: alice }))
      .body.messages.find((m) => m.id === push1.body.messageId)?.sender_id === bot.id);

    const push2 = await api(`/hooks/incoming/${ih.token}`, {
      method: 'POST', body: { title: '销售日报', text: '今日销售额 ¥12,860', fields: [{ label: '客单价', value: '¥68' }], color: 'green' },
    });
    ok('推卡片（title+fields 自动识别）', push2.status === 200 && push2.body.kind === 'card');

    const push3 = await api(`/hooks/incoming/${ih.token}`, {
      method: 'POST', body: { text: '大家注意', mentions: ['all'] },
    });
    ok('@所有人 推送成功', push3.status === 200);
    const convsAfter = (await api('/conversations', { token: bob })).body;
    ok('bob 会话列表出现"有人@我"', convsAfter.find((c) => c.id === gcid)?.has_mention === true);

    ok('空 body 被拒', (await api(`/hooks/incoming/${ih.token}`, { method: 'POST', body: {} })).status === 400);

    // 吊销
    await api(`/admin/integrations/incoming/${ih.id}/revoke`, { method: 'POST', token: admin, body: {} });
    ok('吊销后推送被拒', (await api(`/hooks/incoming/${ih.token}`, { method: 'POST', body: { text: 'x' } })).status === 401);
    await api(`/admin/integrations/incoming/${ih.id}/revoke`, { method: 'POST', token: admin, body: { revoked: false } });
    ok('恢复后推送正常', (await api(`/hooks/incoming/${ih.token}`, { method: 'POST', body: { text: '恢复' } })).status === 200);

    /* ---- 签名模式 ---- */
    const ih2 = (await api('/admin/integrations/incoming', {
      method: 'POST', token: admin, body: { name: '签名推送', botId: bot.id, conversationId: gcid, signed: true },
    })).body;
    ok('创建带签名的 Webhook', ih2.signed === true && ih2.secret.length === 48);

    const rawBody = JSON.stringify({ text: '带签名的推送' });
    const goodSig = 'sha256=' + crypto.createHmac('sha256', ih2.secret).update(rawBody, 'utf8').digest('hex');
    ok('缺签名被拒', (await api(`/hooks/incoming/${ih2.token}`, { method: 'POST', raw: rawBody })).status === 401);
    ok('错签名被拒', (await api(`/hooks/incoming/${ih2.token}`, {
      method: 'POST', raw: rawBody, headers: { 'X-Xiaozhi-Signature': 'sha256=bad' },
    })).status === 401);
    ok('正确签名通过', (await api(`/hooks/incoming/${ih2.token}`, {
      method: 'POST', raw: rawBody, headers: { 'X-Xiaozhi-Signature': goodSig },
    })).status === 200);

    // 后台一键试推
    ok('后台一键试推', (await api(`/admin/integrations/incoming/${ih.id}/send`, {
      method: 'POST', token: admin, body: { text: '后台测试' },
    })).body.ok === true);

    /* ==================== 7. 出站 Webhook ==================== */
    console.log('\n=== 7. 出站 Webhook（事件回调）===');
    const oh = (await api('/admin/integrations/outgoing', {
      method: 'POST', token: admin,
      body: { name: '工厂V2回调', url: `http://127.0.0.1:${HOOK_PORT}/xz`, events: ['message.created'] },
    })).body;
    ok('创建出站 Webhook', !!oh.id && oh.secret.length === 48);
    ok('非法 URL 被拒', (await api('/admin/integrations/outgoing', {
      method: 'POST', token: admin, body: { name: 'x', url: 'ftp://a/b' },
    })).status === 400);

    const at = (p) => received.filter((r) => r.url === p);

    received.length = 0;
    await api(`/conversations/${gcid}/messages`, { method: 'POST', token: alice, body: { kind: 'text', content: '触发回调' } });
    ok('事件回调被投递', await waitFor(() => at('/xz').length > 0));
    const first = at('/xz')[0];
    ok('回调事件名正确', first.body?.event === 'message.created');
    ok('回调带会话信息', first.body?.conversation?.id === gcid);
    ok('回调带消息内容', first.body?.data?.message?.content === '触发回调');
    const wantSig = 'sha256=' + crypto.createHmac('sha256', oh.secret).update(first.raw, 'utf8').digest('hex');
    ok('HMAC 签名可验证', first.headers['x-xiaozhi-signature'] === wantSig);
    ok('回调带 deliveryId', Number(first.headers['x-xiaozhi-delivery']) > 0);
    ok('body 里的 deliveryId 与 header 一致',
      first.body?.deliveryId === Number(first.headers['x-xiaozhi-delivery']));

    const dels = (await api(`/admin/integrations/deliveries?hookId=${oh.id}`, { token: admin })).body;
    ok('投递日志记录成功', dels.length >= 1 && dels[0].ok === true && dels[0].status === 200);

    // 事件过滤：只订阅 message.mention 的 hook，普通消息不该收到
    const ohMention = (await api('/admin/integrations/outgoing', {
      method: 'POST', token: admin,
      body: { name: '只收@', url: `http://127.0.0.1:${HOOK_PORT}/mention`, events: ['message.mention'] },
    })).body;
    received.length = 0;
    await api(`/conversations/${gcid}/messages`, { method: 'POST', token: alice, body: { kind: 'text', content: '普通消息不该触发' } });
    await sleep(700);
    ok('未订阅的事件不投递', at('/mention').length === 0);
    ok('已订阅的事件仍投递', at('/xz').length >= 1);
    await api(`/conversations/${gcid}/messages`, { method: 'POST', token: alice, body: { kind: 'text', content: '@鲍勃 看一下', mentions: [bobId] } });
    ok('订阅的事件命中时投递', await waitFor(() => at('/mention').length > 0));
    ok('@事件带提及列表', (at('/mention')[0].body?.data?.mentions || []).includes(bobId));

    // 会话范围过滤：订阅别的会话
    const oh3 = (await api('/admin/integrations/outgoing', {
      method: 'POST', token: admin,
      body: { name: '别的会话', url: `http://127.0.0.1:${HOOK_PORT}/other`, events: ['*'], conversationId: dm },
    })).body;
    received.length = 0;
    await api(`/conversations/${gcid}/messages`, { method: 'POST', token: alice, body: { kind: 'text', content: '不在范围内' } });
    await sleep(700);
    ok('会话范围过滤生效', at('/other').length === 0);
    ok('删除该 hook', (await api(`/admin/integrations/outgoing/${oh3.id}`, { method: 'DELETE', token: admin })).body.ok === true);

    // 停用
    await api(`/admin/integrations/outgoing/${oh.id}`, { method: 'PATCH', token: admin, body: { active: false } });
    received.length = 0;
    await api(`/conversations/${gcid}/messages`, { method: 'POST', token: alice, body: { kind: 'text', content: '停用后不该投递' } });
    await sleep(700);
    ok('停用后不再投递', at('/xz').length === 0);
    await api(`/admin/integrations/outgoing/${oh.id}`, { method: 'PATCH', token: admin, body: { active: true } });
    ok('轮换密钥后旧签名失效', (await api(`/admin/integrations/outgoing/${oh.id}`, {
      method: 'PATCH', token: admin, body: { rotateSecret: true },
    })).body.secret !== oh.secret);

    // ping 测试
    received.length = 0;
    const ping = await api(`/admin/integrations/outgoing/${oh.id}/test`, { method: 'POST', token: admin, body: {} });
    ok('ping 测试投递成功', await waitFor(() => received.some((r) => r.body?.event === 'ping')));
    ok('ping 返回 deliveryId', ping.body.deliveryId > 0);

    /* ---- 失败重试 ---- */
    const ohBad = (await api('/admin/integrations/outgoing', {
      method: 'POST', token: admin,
      body: { name: '不可达地址', url: 'http://127.0.0.1:9/dead', events: ['*'] },
    })).body;
    const badDelivery = (await api(`/admin/integrations/outgoing/${ohBad.id}/test`, { method: 'POST', token: admin, body: {} })).body.deliveryId;
    await sleep(1200);
    const badRow = (await api(`/admin/integrations/deliveries?hookId=${ohBad.id}`, { token: admin })).body[0];
    ok('投递失败被记录', badRow.ok === false && badRow.attempts >= 1);
    ok('失败排入重试队列', badRow.next_retry_at > Date.now());
    ok('失败原因有记录', !!badRow.error);

    const retry = await api(`/admin/integrations/deliveries/${badDelivery}/retry`, { method: 'POST', token: admin, body: {} });
    ok('手工重发可用', retry.body.ok === true);
    await sleep(1200);
    ok('重发后尝试次数重置并递增', (await api(`/admin/integrations/deliveries?hookId=${ohBad.id}`, { token: admin })).body[0].attempts === 1);

    ok('投递日志可按失败筛选', (await api('/admin/integrations/deliveries?ok=0', { token: admin })).body.every((d) => !d.ok));

    /* ==================== 8. 令牌吊销 / 过期 ==================== */
    console.log('\n=== 8. 令牌吊销与过期 ===');
    await api(`/admin/integrations/tokens/${tokFull.id}/revoke`, { method: 'POST', token: admin, body: {} });
    ok('吊销后调用被拒', (await api('/open/me', { token: T })).status === 401);
    await api(`/admin/integrations/tokens/${tokFull.id}/revoke`, { method: 'POST', token: admin, body: { revoked: false } });
    ok('恢复后调用正常', (await api('/open/me', { token: T })).status === 200);

    const expired = (await api('/admin/integrations/tokens', {
      method: 'POST', token: admin, body: { name: '已过期', userId: bot.id, scopes: ['conversation:read'], expiresAt: Date.now() - 1000 },
    })).body;
    ok('过期令牌被拒', (await api('/open/me', { token: expired.token })).status === 401);
    ok('删除令牌', (await api(`/admin/integrations/tokens/${expired.id}`, { method: 'DELETE', token: admin })).body.ok === true);

    /* ==================== 9. 级联清理 ==================== */
    console.log('\n=== 9. 机器人删除级联 ===');
    ok('删除机器人', (await api(`/admin/integrations/bots/${bot.id}`, { method: 'DELETE', token: admin })).body.ok === true);
    ok('机器人令牌被一并清理', (await api('/open/me', { token: T })).status === 401);
    ok('机器人入站 Webhook 被清理', (await api(`/hooks/incoming/${ih.token}`, { method: 'POST', body: { text: 'x' } })).status === 401);
    ok('机器人已不在会话成员里', !(await api(`/conversations/${gcid}/messages`, { token: alice }))
      .body.members.some((m) => m.user_id === bot.id));

    /* ==================== 10. 卡片可搜索 ==================== */
    console.log('\n=== 10. 卡片消息参与搜索 ===');
    const found = await api('/conversations/search?q=库存预警', { token: alice });
    ok('搜到卡片消息', found.body.items.some((m) => m.kind === 'card'));

    A.ws.close(); B.ws.close();
    await sleep(200);
  } catch (e) {
    console.error('\n测试异常：', e);
    exitCode = 1;
  } finally {
    srv.kill();
    recv.close();
    await sleep(300);
  }

  console.log(`\n${'='.repeat(46)}`);
  console.log(`  通过 ${pass} / 失败 ${fail}`);
  console.log(`${'='.repeat(46)}\n`);
  process.exit(fail > 0 || exitCode ? 1 : 0);
})();
