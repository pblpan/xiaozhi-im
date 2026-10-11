'use strict';
/**
 * 「门店日报推了群里看不到」排查探针（只读，不写任何数据）。
 * 查：钩子指向哪个会话 → 那个会话的成员名单（有没有真人）→
 *     最新落库消息（卡片真的进来了吗、什么形状）。
 * 用法：python deploy/_exec_in_container.py deploy/_dailyreport_debug.js
 */
const { signToken } = require('/app/src/auth');
const { DatabaseSync } = require('node:sqlite');

const db = new DatabaseSync('/data/xiaozhi-im.db', { readOnly: true });
const admin = db.prepare("SELECT id FROM users WHERE role='admin' ORDER BY id LIMIT 1").get();
db.close();

const BASE = 'http://127.0.0.1:' + (process.env.PORT || 3000);
const token = signToken({ uid: admin.id, role: 'admin' });
async function api(p) {
  const r = await fetch(BASE + p, { headers: { Authorization: 'Bearer ' + token } });
  let j = null; try { j = await r.json(); } catch { /* ignore */ }
  return { status: r.status, body: j };
}

(async () => {
  // 1. 钩子清单：门店日报 / 泰格POS日报 指向谁
  const hooks = (await api('/api/admin/integrations/incoming')).body || [];
  for (const name of ['门店日报', '泰格POS日报']) {
    const h = hooks.find((x) => x.name === name);
    if (!h) { console.log(`[hook] 「${name}」不存在`); continue; }
    console.log(`\n[hook] ${name}: id=${h.id} bot=${h.bot_name}(#${h.bot_id}) conv=#${h.conversation_id}「${h.conversation_title}」revoked=${h.revoked} last_used=${h.last_used_at ? new Date(h.last_used_at).toLocaleString('zh-CN', { timeZone: 'Asia/Shanghai' }) : 'never'}`);

    // 2. 会话成员（🔴 头号排查点：除了机器人还有没有真人）
    const g = await api(`/api/groups/${h.conversation_id}`);
    if (g.status !== 200) {
      console.log(`  会话详情 HTTP ${g.status}: ${JSON.stringify(g.body).slice(0, 120)}`);
    } else {
      const members = (g.body.members || []).map((m) =>
        `${m.nickname || m.username}#${m.id}${m.is_bot ? '[机器人]' : ''}${m.role === 'owner' ? '[群主]' : ''}`);
      console.log(`  群「${g.body.group?.name}」成员 ${members.length} 人: ${members.join('、')}`);
      const real = (g.body.members || []).filter((m) => !m.is_bot);
      console.log(`  🔴 真人数量: ${real.length}${real.length === 0 ? ' —— 推得再勤也没人看得到！' : ''}`);
    }

    // 3. 最新落库消息（卡片真的进来了吗）
    const ms = await api(`/api/conversations/${h.conversation_id}/messages?limit=5`);
    const list = Array.isArray(ms.body) ? ms.body : (ms.body?.messages || []);
    console.log(`  最新 ${list.length} 条消息:`);
    for (const m of list.slice(-5)) {
      const sender = m.sender_id || m.senderId;
      const kind = m.kind || m.type;
      let content = m.content ?? '';
      if (typeof content === 'object') content = JSON.stringify(content).slice(0, 100);
      else content = String(content).slice(0, 80);
      console.log(`    [${new Date(m.created_at || m.ts || 0).toLocaleString('zh-CN', { timeZone: 'Asia/Shanghai' })}] from#${sender} kind=${kind} deleted=${m.deleted ?? 0} :: ${content.replace(/\n/g, ' | ')}`);
    }
  }

  // 4. 管理员自己加入的群（对照：龙哥手机登录的账号在哪些群）
  console.log('\n[me] 管理员(#' + admin.id + ') 的会话:');
  const convs = (await api('/api/conversations')).body || [];
  for (const c of convs.slice(0, 15)) {
    console.log(`  #${c.id} type=${c.type} title=${c.title || '(单聊)'}`);
  }
  console.log('\n[done] 只读排查完成');
  process.exit(0);
})().catch((e) => { console.error('探针异常：', e); process.exit(1); });
