'use strict';
/**
 * 为工厂 V2 准备小智 IM 侧资源（幂等：已存在则复用，不重复创建）
 *   1. 建群「工厂管理」，拉入全部管理账号
 *   2. 建机器人「工厂V2助手」，拉进该群
 *   3. 建入站 Webhook「工厂V2推送」→ 指向该群，以机器人身份发言
 * 用法: node deploy/setup_im_for_factory.js
 */
const LAN = process.env.IM_LAN || 'http://192.168.31.44:3602';
const ADMIN = { username: process.env.IM_USER || 'admin', password: process.env.IM_PASS || 'admin123' };
const GROUP_NAME = process.env.GROUP_NAME || '工厂管理';
const BOT_NAME = process.env.BOT_NAME || '工厂V2助手';
const HOOK_NAME = process.env.HOOK_NAME || '工厂V2推送';

async function api(path, opts = {}) {
  const res = await fetch(LAN + path, {
    method: opts.method || 'GET',
    headers: { 'Content-Type': 'application/json', ...(opts.token ? { Authorization: 'Bearer ' + opts.token } : {}) },
    body: opts.body ? JSON.stringify(opts.body) : undefined,
  });
  const txt = await res.text();
  let body; try { body = JSON.parse(txt); } catch { body = txt; }
  if (res.status >= 400) throw new Error(`${opts.method || 'GET'} ${path} -> ${res.status} ${txt.slice(0, 200)}`);
  return body;
}

(async () => {
  const login = await api('/api/auth/login', { method: 'POST', body: ADMIN });
  const t = login.token;
  console.log('✓ 登录成功:', login.user.username);

  // ---------- 1. 群 ----------
  // 注意：/api/admin/groups 不返回 conversation_id，必须从 /api/groups/:id 的 group 字段取
  let groups = await api('/api/admin/groups', { token: t });
  let g = groups.find((x) => x.name === GROUP_NAME);
  if (!g) {
    const r = await api('/api/groups', { method: 'POST', token: t, body: { name: GROUP_NAME } });
    g = { id: r.groupId };
    console.log(`✓ 建群「${GROUP_NAME}」id=${g.id} conv=${r.conversationId}`);
  } else {
    console.log(`✓ 群「${GROUP_NAME}」已存在 id=${g.id}`);
  }
  const detail = await api(`/api/groups/${g.id}`, { token: t });
  const cid = detail.group.conversation_id;
  console.log(`  群会话 conversation_id=${cid}`);

  // ---------- 2. 拉人入群 ----------
  const users = await api('/api/admin/users', { token: t });
  const inGroup = new Set((detail.members || []).map((m) => m.id));
  for (const u of users) {
    if (u.is_bot || inGroup.has(u.id)) continue;
    await api(`/api/groups/${g.id}/members`, { method: 'POST', token: t, body: { userId: u.id } });
    console.log(`  + 拉入成员 ${u.nickname || u.username} (id=${u.id})`);
  }

  // ---------- 3. 机器人 ----------
  let bots = await api('/api/admin/integrations/bots', { token: t });
  let bot = bots.find((b) => b.nickname === BOT_NAME || b.username === BOT_NAME);
  if (bot) {
    console.log(`✓ 机器人「${BOT_NAME}」已存在 id=${bot.id}`);
    await api(`/api/admin/integrations/bots/${bot.id}/conversations`, { method: 'POST', token: t, body: { conversationId: cid } });
  } else {
    bot = await api('/api/admin/integrations/bots', { method: 'POST', token: t, body: { name: BOT_NAME, conversationId: cid } });
    console.log(`✓ 建机器人「${BOT_NAME}」id=${bot.id}（已拉进群）`);
  }

  // ---------- 4. 入站 Webhook ----------
  let hooks = await api('/api/admin/integrations/incoming', { token: t });
  let hook = hooks.find((h) => h.name === HOOK_NAME && h.conversation_id === cid);
  if (hook) {
    console.log(`✓ 入站 Webhook「${HOOK_NAME}」已存在 id=${hook.id}`);
  } else {
    hook = await api('/api/admin/integrations/incoming', {
      method: 'POST', token: t,
      body: { name: HOOK_NAME, botId: bot.id, conversationId: cid },
    });
    console.log(`✓ 建入站 Webhook「${HOOK_NAME}」id=${hook.id}`);
  }

  // ---------- 5. 自检推送 ----------
  const url = `${LAN}/api/hooks/incoming/${hook.token}`;
  console.log('\n=== 对接信息（填到工厂 V2 的「消息推送」里）===');
  console.log('  推送地址 :', url);
  console.log('  目标群   :', GROUP_NAME, '(conv=' + cid + ')');
  console.log('  发言身份 :', BOT_NAME, '(botId=' + bot.id + ')');

  const ping = await fetch(url, {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      title: '工厂 V2 对接测试',
      text: '如果你在群里看到这张卡片，说明推送链路已经打通。',
      color: 'blue',
      fields: [
        { label: '来源', value: '工厂管理系统 V2' },
        { label: '目标群', value: GROUP_NAME },
        { label: '时间', value: new Date().toLocaleString('zh-CN') },
      ],
      footer: '小智 IM · 集成对接',
    }),
  });
  const pj = await ping.json();
  console.log('  自检推送 :', ping.status, JSON.stringify(pj));
  if (!pj.ok) process.exit(1);
  console.log('\n✅ 准备完成');
})().catch((e) => { console.error('❌ 失败:', e.message); process.exit(1); });
