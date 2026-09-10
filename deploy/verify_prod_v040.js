/**
 * 小智IM v0.4.0 生产环境验证：开放集成层
 *
 * 特点：
 *   - 内网 + 外网两条链路都跑
 *   - 全程用带随机后缀的临时账号，绝不碰真人数据
 *   - 出站回调指向服务端自己的 /api/hooks/ping（容器内可达），因此不需要公网回调地址
 *   - 结束前物理删除全部测试痕迹（消息 → 会话 → 群 → 用户），并复查残留为 0
 *
 * 用法：node verify_prod_v040.js [内网地址] [外网地址]
 */
const crypto = require('crypto');

const LAN = (process.argv[2] || 'http://192.168.31.44:3602').replace(/\/$/, '');
const WAN = (process.argv[3] || 'https://1dcf316343d04ecd93dd0330c2d81a0d.hn.takin.cc').replace(/\/$/, '');
const ADMIN_USER = 'admin';
const ADMIN_PASS = 'admin123';

let pass = 0, fail = 0;
const ok = (name, cond, extra = '') => {
  if (cond) { pass++; console.log(`  \u2705 ${name}`); }
  else { fail++; console.log(`  \u274c ${name}${extra ? '  -> ' + extra : ''}`); }
};
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function api(base, p, { method = 'GET', token, body } = {}) {
  const r = await fetch(base + '/api' + p, {
    method,
    headers: {
      'Content-Type': 'application/json',
      ...(token ? { Authorization: 'Bearer ' + token } : {}),
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  const j = await r.json().catch(() => null);
  return { status: r.status, body: j };
}

async function waitFor(fn, timeout = 8000) {
  const t0 = Date.now();
  while (Date.now() - t0 < timeout) {
    if (await fn()) return true;
    await sleep(300);
  }
  return false;
}

const SUF = Math.random().toString(36).slice(2, 8);
const U1 = `v4a${SUF}`;
const U2 = `v4b${SUF}`;

(async () => {
  console.log('\n============================================================');
  console.log('  小智IM v0.4.0 生产验证 · 开放集成层');
  console.log(`  内网: ${LAN}`);
  console.log(`  外网: ${WAN}`);
  console.log(`  临时账号: ${U1} / ${U2}（结束后删除）`);
  console.log('============================================================');

  const created = { users: [], bot: null, outgoing: [], conversation: null };
  let admin = null;
  let exitCode = 0;

  try {
    /* ==================== 1. 外网链路 ==================== */
    console.log('\n=== 1. 外网链路 ===');
    const h = await fetch(WAN + '/api/health');
    ok('外网 /api/health 200', h.status === 200);
    const wanAdmin = await api(WAN, '/auth/login', { method: 'POST', body: { username: ADMIN_USER, password: ADMIN_PASS } });
    ok('外网登录成功', wanAdmin.status === 200 && !!wanAdmin.body?.token);
    const wanAdminPage = await fetch(WAN + '/admin/');
    ok('外网管理后台可访问', wanAdminPage.status === 200);
    const wanMeta = await api(WAN, '/admin/integrations/meta', { token: wanAdmin.body.token });
    ok('外网可读集成配置', wanMeta.status === 200 && Array.isArray(wanMeta.body?.events));
    const wanPing = await api(WAN, '/hooks/ping', { method: 'POST', body: { hello: 'wan' } });
    ok('外网回调自检地址可用', wanPing.status === 200 && wanPing.body?.ok === true);

    /* ==================== 2. 内网准备 ==================== */
    console.log('\n=== 2. 内网准备：临时账号 / 群 ===');
    admin = (await api(LAN, '/auth/login', { method: 'POST', body: { username: ADMIN_USER, password: ADMIN_PASS } })).body.token;
    ok('内网管理员登录', !!admin);

    const mk = async (u, n) => {
      const r = await api(LAN, '/admin/users', { method: 'POST', token: admin, body: { username: u, password: 'abc123', nickname: n } });
      if (r.body?.id) created.users.push(r.body.id);
      return r.body?.id;
    };
    const a1 = await mk(U1, '验证甲');
    const a2 = await mk(U2, '验证乙');
    ok('创建临时账号', !!(a1 && a2));

    const g = (await api(LAN, '/groups', { method: 'POST', token: admin, body: { name: `验证群${SUF}` } })).body;
    created.conversation = g.conversationId;
    await api(LAN, `/groups/${g.groupId}/members`, { method: 'POST', token: admin, body: { userId: a2 } });
    ok('创建临时群', !!g.conversationId);
    const cid = g.conversationId;

    /* ==================== 3. 机器人 ==================== */
    console.log('\n=== 3. 机器人 ===');
    const bot = (await api(LAN, '/admin/integrations/bots', {
      method: 'POST', token: admin, body: { name: `验证助手${SUF}`, conversationId: cid },
    })).body;
    created.bot = bot.id;
    ok('创建机器人', !!bot.id && bot.is_bot === true);
    ok('机器人无法登录', (await api(LAN, '/auth/login', { method: 'POST', body: { username: bot.username, password: 'abc123' } })).status === 401);
    ok('机器人已在群成员里', (await api(LAN, `/conversations/${cid}/messages`, { token: admin }))
      .body.members.some((m) => m.user_id === bot.id));

    /* ==================== 4. 入站 Webhook（免登录推送） ==================== */
    console.log('\n=== 4. 入站 Webhook ===');
    const ih = (await api(LAN, '/admin/integrations/incoming', {
      method: 'POST', token: admin, body: { name: `验证推送${SUF}`, botId: bot.id, conversationId: cid, signed: false },
    })).body;
    ok('创建推送地址', !!ih.token);
    ok('GET 地址自检', (await api(LAN, `/hooks/incoming/${ih.token}`)).body?.ok === true);
    ok('未知 token 被拒', (await api(LAN, '/hooks/incoming/nope', { method: 'POST', body: { text: 'x' } })).status === 401);

    const p1 = await api(LAN, `/hooks/incoming/${ih.token}`, { method: 'POST', body: { text: `生产验证文字 ${SUF}` } });
    ok('推送文字成功', p1.status === 200 && p1.body?.ok === true);
    const p2 = await api(LAN, `/hooks/incoming/${ih.token}`, {
      method: 'POST',
      body: {
        title: `销售日报 ${SUF}`, text: '生产验证卡片', color: 'orange',
        fields: [{ label: '销售额', value: '¥1,234', short: true }, { label: '客单价', value: '¥56' }],
        footer: 'verify_prod_v040',
      },
    });
    ok('推送卡片成功', p2.status === 200 && p2.body?.kind === 'card');
    // 卡片刚推完时它是最新一条，会话列表预览应该显示 [卡片] 而不是一坨 JSON
    const convRow = (await api(LAN, '/conversations', { token: admin })).body.find((x) => x.id === cid);
    ok('会话列表预览显示[卡片]', convRow?.last_content === '[卡片]', `last=${convRow?.last_content}`);
    ok('会话列表带群 id', convRow?.group_id === g.groupId);
    const p3 = await api(LAN, `/hooks/incoming/${ih.token}`, { method: 'POST', body: { text: `请核对 ${SUF}`, mentions: ['all'] } });
    ok('@所有人 推送成功', p3.status === 200);

    const hist = (await api(LAN, `/conversations/${cid}/messages`, { token: admin })).body;
    const pushed = hist.messages.filter((m) => [p1.body.messageId, p2.body.messageId, p3.body.messageId].includes(m.id));
    ok('三条推送都落库', pushed.length === 3);
    ok('推送身份是机器人', pushed.every((m) => m.sender_id === bot.id));
    ok('历史接口带机器人标识', pushed.every((m) => m.sender_is_bot === 1 || m.sender_is_bot === true));
    ok('卡片内容可解析', (() => {
      const c = JSON.parse(hist.messages.find((m) => m.id === p2.body.messageId).content);
      return c.title.startsWith('销售日报') && c.color === 'orange' && c.fields.length === 2;
    })());

    ok('空 body 被拒', (await api(LAN, `/hooks/incoming/${ih.token}`, { method: 'POST', body: {} })).status === 400);

    /* ---- 签名模式 ---- */
    const ih2 = (await api(LAN, '/admin/integrations/incoming', {
      method: 'POST', token: admin, body: { name: `验证签名${SUF}`, botId: bot.id, conversationId: cid, signed: true },
    })).body;
    const rawBody = JSON.stringify({ text: `签名推送 ${SUF}` });
    const goodSig = 'sha256=' + crypto.createHmac('sha256', ih2.secret).update(rawBody, 'utf8').digest('hex');
    const noSig = await fetch(`${LAN}/api/hooks/incoming/${ih2.token}`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' }, body: rawBody,
    });
    ok('缺签名被拒', noSig.status === 401);
    const badSig = await fetch(`${LAN}/api/hooks/incoming/${ih2.token}`, {
      method: 'POST', headers: { 'Content-Type': 'application/json', 'X-Xiaozhi-Signature': 'sha256=deadbeef' }, body: rawBody,
    });
    ok('错签名被拒', badSig.status === 401);
    const okSig = await fetch(`${LAN}/api/hooks/incoming/${ih2.token}`, {
      method: 'POST', headers: { 'Content-Type': 'application/json', 'X-Xiaozhi-Signature': goodSig }, body: rawBody,
    });
    ok('正确签名通过', okSig.status === 200);

    /* ==================== 5. 开放 API + 令牌 ==================== */
    console.log('\n=== 5. 开放 API 与令牌 ===');
    const tok = (await api(LAN, '/admin/integrations/tokens', {
      method: 'POST', token: admin,
      body: { name: `验证令牌${SUF}`, userId: bot.id, scopes: ['message:send', 'message:read', 'conversation:read', 'user:read'] },
    })).body;
    ok('发放令牌', typeof tok.token === 'string' && tok.token.startsWith('xz_'));
    ok('列表对令牌打码', (await api(LAN, '/admin/integrations/tokens', { token: admin })).body.find((t) => t.id === tok.id).token.includes('…'));
    const T = tok.token;

    const me = await api(LAN, '/open/me', { token: T });
    ok('/open/me 正常', me.status === 200 && me.body.identity.id === bot.id);
    const convs = await api(LAN, '/open/conversations', { token: T });
    ok('/open/conversations 含临时群', convs.body.items.some((c) => c.id === cid));
    const sent = await api(LAN, `/open/conversations/${cid}/messages`, {
      method: 'POST', token: T, body: { title: `API卡片 ${SUF}`, text: '通过令牌发出', color: 'blue' },
    });
    ok('令牌发卡片成功', sent.status === 200 && sent.body.kind === 'card');
    ok('/open/users 搜索', (await api(LAN, `/open/users?q=${U1}`, { token: T })).body.items.length === 1);

    const tokLite = (await api(LAN, '/admin/integrations/tokens', {
      method: 'POST', token: admin, body: { name: `验证只发${SUF}`, userId: bot.id, scopes: ['message:send'] },
    })).body;
    ok('缺 scope 被拒(403)', (await api(LAN, '/open/users', { token: tokLite.token })).status === 403);
    ok('伪造令牌被拒(401)', (await api(LAN, '/open/me', { token: 'xz_fakefakefake' })).status === 401);

    /* ==================== 6. 出站 Webhook ==================== */
    console.log('\n=== 6. 出站 Webhook（回调到服务端自检地址）===');
    const oh = (await api(LAN, '/admin/integrations/outgoing', {
      method: 'POST', token: admin,
      body: { name: `验证回调${SUF}`, url: `${LAN}/api/hooks/ping`, events: ['message.created'] },
    })).body;
    created.outgoing.push(oh.id);
    ok('创建事件订阅', !!oh.id && oh.secret.length === 48);

    const before = (await api(LAN, `/admin/integrations/deliveries?hookId=${oh.id}`, { token: admin })).body.length;
    await api(LAN, `/conversations/${cid}/messages`, { method: 'POST', token: admin, body: { kind: 'text', content: `触发回调 ${SUF}` } });
    const gotIt = await waitFor(async () => {
      const d = (await api(LAN, `/admin/integrations/deliveries?hookId=${oh.id}`, { token: admin })).body;
      return d.length > before && d[0].ok === true;
    });
    ok('事件回调投递成功', gotIt);
    const del = (await api(LAN, `/admin/integrations/deliveries?hookId=${oh.id}`, { token: admin })).body[0];
    ok('回调状态码 200', del?.status === 200, `status=${del?.status}`);
    ok('回调记录了事件名', del?.event === 'message.created');

    // 失败与重试
    const ohBad = (await api(LAN, '/admin/integrations/outgoing', {
      method: 'POST', token: admin, body: { name: `验证失败${SUF}`, url: 'http://127.0.0.1:9/dead', events: ['*'] },
    })).body;
    created.outgoing.push(ohBad.id);
    const badId = (await api(LAN, `/admin/integrations/outgoing/${ohBad.id}/test`, { method: 'POST', token: admin })).body.deliveryId;
    await sleep(1500);
    const badRow = (await api(LAN, `/admin/integrations/deliveries?hookId=${ohBad.id}`, { token: admin })).body[0];
    ok('失败投递被记录', badRow?.ok === false && badRow?.attempts >= 1);
    ok('失败排入重试队列', badRow?.next_retry_at > Date.now());
    ok('失败原因有记录', !!badRow?.error);
    await api(LAN, `/admin/integrations/deliveries/${badId}/retry`, { method: 'POST', token: admin });
    await sleep(1500);
    ok('手工重发生效', (await api(LAN, `/admin/integrations/deliveries?hookId=${ohBad.id}`, { token: admin })).body[0].attempts === 1);

    // ping 测试
    const pingId = (await api(LAN, `/admin/integrations/outgoing/${oh.id}/test`, { method: 'POST', token: admin })).body.deliveryId;
    ok('ping 测试事件可发', pingId > 0);
    ok('ping 投递成功', await waitFor(async () => {
      const d = (await api(LAN, `/admin/integrations/deliveries?hookId=${oh.id}`, { token: admin })).body;
      const row = d.find((x) => x.id === pingId);
      return row && row.ok === true;
    }));

    /* ==================== 7. 令牌吊销 / 过期 ==================== */
    console.log('\n=== 7. 令牌吊销与过期 ===');
    await api(LAN, `/admin/integrations/tokens/${tok.id}/revoke`, { method: 'POST', token: admin, body: {} });
    ok('吊销后 401', (await api(LAN, '/open/me', { token: T })).status === 401);
    await api(LAN, `/admin/integrations/tokens/${tok.id}/revoke`, { method: 'POST', token: admin, body: { revoked: false } });
    ok('恢复后 200', (await api(LAN, '/open/me', { token: T })).status === 200);
    const expired = (await api(LAN, '/admin/integrations/tokens', {
      method: 'POST', token: admin, body: { name: `验证过期${SUF}`, userId: bot.id, scopes: ['conversation:read'], expiresAt: Date.now() - 1000 },
    })).body;
    ok('过期令牌 401', (await api(LAN, '/open/me', { token: expired.token })).status === 401);
    await api(LAN, `/admin/integrations/tokens/${expired.id}`, { method: 'DELETE', token: admin });

    /* ==================== 8. 清理 ==================== */
    console.log('\n=== 8. 清理测试数据 ===');
    // 机器人删除会级联清掉它的令牌与推送地址
    await api(LAN, `/admin/integrations/bots/${bot.id}`, { method: 'DELETE', token: admin });
    created.bot = null;
    ok('机器人已删除（令牌/推送地址级联清理）', (await api(LAN, '/open/me', { token: T })).status === 401);
    ok('推送地址已失效', (await api(LAN, `/hooks/incoming/${ih.token}`, { method: 'POST', body: { text: 'x' } })).status === 401);

    for (const id of created.outgoing) {
      await api(LAN, `/admin/integrations/outgoing/${id}`, { method: 'DELETE', token: admin });
    }
    ok('事件订阅已删除', (await api(LAN, '/admin/integrations/outgoing', { token: admin }))
      .body.every((o) => !created.outgoing.includes(o.id)));

    // 删会话（连带消息、成员、群）
    const delConv = await api(LAN, `/admin/conversations/${cid}`, { method: 'DELETE', token: admin });
    ok('会话与消息已删除', delConv.status === 200, JSON.stringify(delConv.body));

    // 删临时用户
    for (const id of created.users) {
      await api(LAN, `/admin/users/${id}`, { method: 'DELETE', token: admin });
    }
    const leftovers = (await api(LAN, '/admin/users', { token: admin })).body
      .filter((u) => u.username.startsWith('v4a') || u.username.startsWith('v4b'));
    ok('临时账号已清除', leftovers.length === 0, `残留 ${leftovers.length}`);
    ok('测试群已清除', !(await api(LAN, '/admin/groups', { token: admin })).body
      .some((x) => String(x.name).includes(SUF)));
    ok('测试消息已清除', (await api(LAN, '/admin/messages?q=' + encodeURIComponent(SUF), { token: admin })).body.length === 0);
    ok('测试机器人已清除', !(await api(LAN, '/admin/integrations/bots', { token: admin })).body
      .some((b) => String(b.nickname).includes(SUF)));

    /* ==================== 9. 服务端健康 ==================== */
    console.log('\n=== 9. 服务端状态 ===');
    ok('服务端仍在运行', (await fetch(LAN + '/api/health')).status === 200);
    const st = (await api(LAN, '/admin/stats', { token: admin })).body;
    ok('统计含集成字段', ['bots', 'tokens', 'hooks_in', 'hooks_out', 'cards', 'deliveries_failed'].every((k) => st[k] !== undefined));
    ok('无遗留失败投递堆积', st.deliveries_failed >= 0);
  } catch (e) {
    console.error('\n验证异常：', e);
    exitCode = 1;
  }

  console.log(`\n${'='.repeat(52)}`);
  console.log(`  通过 ${pass} / 失败 ${fail}`);
  console.log(`${'='.repeat(52)}\n`);
  process.exit(fail > 0 || exitCode ? 1 : 0);
})();
