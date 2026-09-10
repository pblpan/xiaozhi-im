'use strict';
/**
 * 探测小智 IM 生产环境现状：有哪些用户、哪些群、哪些机器人
 * 用法: node deploy/probe_im.js
 */
const LAN = process.env.IM_LAN || 'http://192.168.31.44:3602';
const ADMIN = { username: process.env.IM_USER || 'admin', password: process.env.IM_PASS || 'admin123' };

async function api(base, path, opts = {}) {
  const res = await fetch(base + path, {
    method: opts.method || 'GET',
    headers: { 'Content-Type': 'application/json', ...(opts.token ? { Authorization: 'Bearer ' + opts.token } : {}) },
    body: opts.body ? JSON.stringify(opts.body) : undefined,
  });
  const txt = await res.text();
  let body; try { body = JSON.parse(txt); } catch { body = txt; }
  return { status: res.status, body };
}

(async () => {
  const login = await api(LAN, '/api/auth/login', { method: 'POST', body: ADMIN });
  if (!login.body?.token) { console.error('登录失败', login.status, login.body); process.exit(1); }
  const t = login.body.token;
  console.log('登录成功, 用户:', JSON.stringify(login.body.user || {}));

  const users = (await api(LAN, '/api/admin/users', { token: t })).body;
  console.log('\n=== 用户 (' + (users?.length || 0) + ') ===');
  for (const u of (users || [])) {
    console.log(`  id=${u.id} ${u.username} / ${u.nickname || '-'} role=${u.role}${u.is_bot ? ' [BOT]' : ''}`);
  }

  const groups = (await api(LAN, '/api/admin/groups', { token: t })).body;
  console.log('\n=== 群组 (' + (groups?.length || 0) + ') ===');
  for (const g of (groups || [])) {
    console.log(`  id=${g.id} ${g.name} conv=${g.conversation_id} 成员=${g.member_count ?? '?'} 群主=${g.owner_name || g.owner_id || '-'}`);
  }

  const bots = (await api(LAN, '/api/admin/integrations/bots', { token: t })).body;
  console.log('\n=== 机器人 (' + (bots?.length || 0) + ') ===');
  for (const b of (bots || [])) console.log(`  id=${b.id} ${b.username} / ${b.nickname}`);

  const ihs = (await api(LAN, '/api/admin/integrations/incoming', { token: t })).body;
  console.log('\n=== 入站 Webhook (' + (ihs?.length || 0) + ') ===');
  for (const h of (ihs || [])) console.log(`  id=${h.id} ${h.name} -> conv=${h.conversation_id} sender=${h.sender_id} active=${h.active}`);

  const convs = (await api(LAN, '/api/conversations', { token: t })).body;
  console.log('\n=== admin 的会话 (' + (convs?.length || 0) + ') ===');
  for (const c of (convs || []).slice(0, 15)) {
    console.log(`  conv=${c.id} type=${c.type} title=${c.title || '(无名)'} 成员=${c.member_count ?? '?'}`);
  }
})().catch((e) => { console.error('异常:', e.message); process.exit(1); });
