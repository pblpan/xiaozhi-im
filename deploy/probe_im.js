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

  // v0.14.0 起 /admin/users、/admin/groups 都分页了（响应 {items,total}）。
  // 探针要看的是"这个实例里到底有什么"，所以：用户走不分页的 options 接口，
  // 群用足够大的 pageSize（上限 200）并提示是否被截断。
  const users = (await api(LAN, '/api/admin/users/options', { token: t })).body;
  console.log('\n=== 用户 (' + (users?.length || 0) + ') ===');
  for (const u of (users || [])) {
    console.log(`  id=${u.id} ${u.username} / ${u.nickname || '-'} role=${u.role}${u.is_bot ? ' [BOT]' : ''}`);
  }

  const groupsBody = (await api(LAN, '/api/admin/groups?pageSize=200', { token: t })).body;
  const groups = groupsBody?.items || (Array.isArray(groupsBody) ? groupsBody : []);
  console.log('\n=== 群组 (' + groups.length + (groupsBody?.total > groups.length ? ` / 共 ${groupsBody.total}` : '') + ') ===');
  for (const g of groups) {
    console.log(`  id=${g.id} ${g.name} conv=${g.conversation_id} 成员=${g.members ?? '?'} 群主=${g.owner_name || g.owner_id || '-'}`);
  }

  const bots = (await api(LAN, '/api/admin/integrations/bots', { token: t })).body;
  console.log('\n=== 机器人 (' + (bots?.length || 0) + ') ===');
  for (const b of (bots || [])) console.log(`  id=${b.id} ${b.username} / ${b.nickname}`);

  const ihs = (await api(LAN, '/api/admin/integrations/incoming', { token: t })).body;
  console.log('\n=== 入站 Webhook (' + (ihs?.length || 0) + ') ===');
  // 字段名以 shapeIncoming 为准：conversation_title / bot_name / signed / revoked
  // （曾经照钉钉的习惯写成 sender_id / active，结果探针一直打印 undefined 还看不出来）
  for (const h of (ihs || [])) {
    console.log(`  id=${h.id} ${h.name} -> conv=${h.conversation_id}(${h.conversation_title || '?'})`
      + ` bot=${h.bot_name || h.bot_id} 签名=${h.signed ? '是' : '否'}`
      + ` 状态=${h.revoked ? '已吊销' : '生效中'}`);
  }

  const convs = (await api(LAN, '/api/conversations', { token: t })).body;
  console.log('\n=== admin 的会话 (' + (convs?.length || 0) + ') ===');
  for (const c of (convs || []).slice(0, 15)) {
    // 这个接口不返回 title / member_count（标题由客户端按成员自己算），
    // 所以这里显示最后一条消息预览更有信息量
    console.log(`  conv=${c.id} type=${c.type} 未读=${c.unread ?? 0}`
      + ` 最后消息=${String(c.last_content ?? '').replace(/\s+/g, ' ').slice(0, 40) || '（无）'}`);
  }
})().catch((e) => { console.error('异常:', e.message); process.exit(1); });
