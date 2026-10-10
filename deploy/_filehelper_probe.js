'use strict';
/**
 * 「文件助手」上线验证探针（跑在容器里）。
 * 验证：filehelper 接口存在且幂等、会话列表形态正确、能发能撤、未读恒 0。
 * 发的消息随即撤回，不留脏数据。
 * 用法：python deploy/_exec_in_container.py deploy/_filehelper_probe.js
 */
const { signToken } = require('/app/src/auth');
const { DatabaseSync } = require('node:sqlite');

const db = new DatabaseSync('/data/xiaozhi-im.db', { readOnly: true });
// 取一个真实用户（最早注册的，一定是活人账号）
const u = db.prepare('SELECT id, username, role FROM users ORDER BY id ASC LIMIT 1').get();
db.close();

console.log('[db] 取样用户:', JSON.stringify(u));

const BASE = 'http://127.0.0.1:' + (process.env.PORT || 3000);
const token = signToken({ uid: u.id, role: u.role });
async function api(method, p, body) {
  const r = await fetch(BASE + p, {
    method,
    headers: { 'Content-Type': 'application/json', Authorization: 'Bearer ' + token },
    body: body ? JSON.stringify(body) : undefined,
  });
  let j = null; try { j = await r.json(); } catch { /* HTML */ }
  return { status: r.status, body: j };
}

let pass = 0, fail = 0;
const ok = (n, c, x) => { if (c) { pass++; console.log('  ✓ ' + n); } else { fail++; console.log('  ✗ ' + n + (x ? '  → ' + x : '')); } };

(async () => {
  if (!u) { console.log('线上没有用户，跳过'); process.exit(0); }

  // 1. filehelper 接口存在且幂等（每个用户永远只有一个）
  let r = await api('GET', '/api/conversations/filehelper');
  const cid = r.body?.conversationId;
  ok('GET /api/conversations/filehelper → 200 且返回会话 id',
    r.status === 200 && Number.isInteger(cid), JSON.stringify(r.body));
  r = await api('GET', '/api/conversations/filehelper');
  ok('重复调用幂等（同一个 id，不会越点越多）',
    r.status === 200 && r.body?.conversationId === cid, JSON.stringify(r.body));

  // 2. 会话列表里的形态
  r = await api('GET', '/api/conversations');
  const mine = (r.body || []).find((c) => c.id === cid);
  ok('会话列表出现文件助手（title=文件助手 / type=filehelper / is_filehelper=true）',
    !!mine && mine.title === '文件助手' && mine.type === 'filehelper' && mine.is_filehelper === true,
    JSON.stringify(mine));

  // 3. 发一条 → 撤回（不留垃圾数据）
  r = await api('POST', `/api/conversations/${cid}/messages`, { kind: 'text', content: '探针-' + Date.now() });
  const mid = r.body?.id;
  ok('往文件助手发文字 → 200', r.status === 200 && Number.isInteger(mid), JSON.stringify(r.body).slice(0, 140));
  r = await api('POST', `/api/conversations/${cid}/messages/${mid}/recall`);
  ok('撤回 → 200', r.status === 200, JSON.stringify(r.body).slice(0, 140));

  // 4. 未读恒为 0（自己发的不给自己刷红点）
  r = await api('GET', '/api/conversations');
  const m2 = (r.body || []).find((c) => c.id === cid);
  ok('自己发的不算未读', m2?.unread === 0, JSON.stringify(m2?.unread));

  console.log(`\n探针结果: ${pass} 通过 / ${fail} 失败`);
  process.exit(fail ? 1 : 0);
})().catch((e) => { console.error('探针崩溃:', e); process.exit(1); });
