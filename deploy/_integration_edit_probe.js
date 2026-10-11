'use strict';
/**
 * 集成对接「编辑」上线验证探针（跑在容器里，#313）。
 * 验证：PATCH /bots/:id、PATCH /incoming/:id 在线上真的可用（带 token 拿 200，
 *       不能只看 401）；管理台新构建带「泰格 POS 日报对接」入口。
 * 写操作只建探针自己的机器人/推送地址，最后全部删除（自清理）。
 * 用法：python deploy/_exec_in_container.py deploy/_integration_edit_probe.js
 */
const { signToken } = require('/app/src/auth');
const { DatabaseSync } = require('node:sqlite');

const db = new DatabaseSync('/data/xiaozhi-im.db', { readOnly: true });

let pass = 0, fail = 0;
const ok = (n, c, x) => { if (c) { pass++; console.log('  ✓ ' + n); } else { fail++; console.log('  ✗ ' + n + (x ? '  → ' + x : '')); } };

const admin = db.prepare("SELECT id FROM users WHERE role='admin' ORDER BY id LIMIT 1").get();
const conv = db.prepare(`SELECT c.id FROM conversations c JOIN groups g ON g.conversation_id=c.id
  WHERE c.type='group' ORDER BY c.id DESC LIMIT 1`).get();
db.close();
console.log('[db] admin/conv:', JSON.stringify([admin?.id, conv?.id]));

const BASE = 'http://127.0.0.1:' + (process.env.PORT || 3000);
const token = signToken({ uid: admin.id, role: 'admin' });
async function api(method, p, body) {
  const r = await fetch(BASE + p, {
    method,
    headers: { 'Content-Type': 'application/json', Authorization: 'Bearer ' + token },
    body: body ? JSON.stringify(body) : undefined,
  });
  let j = null; try { j = await r.json(); } catch { /* HTML */ }
  return { status: r.status, body: j };
}

(async () => {
  let botId = null, hookId = null;
  try {
    // 1. 机器人改名
    let r = await api('POST', '/api/admin/integrations/bots', { name: '探针-编辑测试' });
    ok('建探针机器人 → 200', r.status === 200 && !!r.body?.id, JSON.stringify(r.body).slice(0, 120));
    botId = r.body?.id;

    r = await api('PATCH', `/api/admin/integrations/bots/${botId}`, { name: '探针-改名成功' });
    ok('PATCH /bots/:id 改名 → 200 且生效',
      r.status === 200 && r.body?.nickname === '探针-改名成功', JSON.stringify(r.body).slice(0, 140));

    // 2. 入站推送编辑（若无群会话则跳过建钩子部分）
    if (conv?.id) {
      r = await api('POST', '/api/admin/integrations/incoming', {
        name: '探针-推送测试', botId, conversationId: conv.id });
      ok('建探针推送地址 → 200', r.status === 200 && !!r.body?.token, JSON.stringify(r.body).slice(0, 140));
      hookId = r.body?.id;
      const origPath = r.body?.path;

      r = await api('PATCH', `/api/admin/integrations/incoming/${hookId}`, { name: '探针-改名成功' });
      ok('PATCH /incoming/:id 改名 → 200 且地址不变',
        r.status === 200 && r.body?.name === '探针-改名成功' && r.body?.path === origPath,
        JSON.stringify(r.body).slice(0, 160));

      r = await api('PATCH', `/api/admin/integrations/incoming/${hookId}`, { signed: true });
      ok('开签名 → secret 非空', r.status === 200 && r.body?.signed === true && !!r.body?.secret,
        JSON.stringify({ s: r.body?.signed, sec: !!r.body?.secret }));
      r = await api('PATCH', `/api/admin/integrations/incoming/${hookId}`, { signed: false });
      ok('关签名 → secret 清空', r.status === 200 && r.body?.signed === false && !r.body?.secret,
        JSON.stringify({ s: r.body?.signed, sec: r.body?.secret }));
    } else {
      console.log('  （线上没有群会话，入站推送编辑跳过）');
    }

    // 3. 管理台新构建带泰格向导
    const idx = await (await fetch(BASE + '/admin/')).text();
    const m = idx.match(/assets\/index-[\w-]+\.js/);
    ok('管理台 index.html 拿到 bundle 名', !!m, idx.slice(0, 120));
    if (m) {
      const js = await (await fetch(BASE + '/admin/' + m[0])).text();
      ok('bundle 含「泰格 POS 日报对接」入口', js.includes('泰格 POS 日报对接'));
      ok('bundle 含向导说明（编辑不改变地址）', js.includes('推送地址（token）不变'));
      ok('bundle 含帮助 FAQ（泰格日报怎么接）', js.includes('泰格 POS 日报怎么对接到群里'));
    }
  } finally {
    // 自清理：探针数据一个不留
    if (hookId) await api('DELETE', `/api/admin/integrations/incoming/${hookId}`);
    if (botId) await api('DELETE', `/api/admin/integrations/bots/${botId}`);
    console.log('[cleanup] 探针机器人/推送地址已删除');
  }

  console.log(`\n========== 探针结果：${pass} 通过 / ${fail} 失败 ==========`);
  process.exit(fail ? 1 : 0);
})().catch((e) => { console.error('探针异常：', e); process.exit(1); });
