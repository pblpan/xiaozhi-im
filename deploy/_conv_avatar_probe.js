'use strict';
/**
 * 群头像拼接素材上线验证探针（跑在容器里）。
 * 直接拿线上真实群，看会话列表有没有带回 member_avatars / member_count。
 * 用法：python deploy/_exec_in_container.py deploy/_conv_avatar_probe.js
 */
const { signToken } = require('/app/src/auth');
const { DatabaseSync } = require('node:sqlite');

const db = new DatabaseSync('/data/xiaozhi-im.db', { readOnly: true });
// 挑一个成员最多的群：空群看不出效果
const g = db.prepare(`SELECT g.id, g.name, g.conversation_id,
  (SELECT COUNT(*) FROM group_members gm WHERE gm.group_id=g.id) n
  FROM groups g ORDER BY n DESC LIMIT 1`).get();
console.log('[db] 成员最多的群:', JSON.stringify(g));

const owner = g
  ? db.prepare("SELECT user_id FROM group_members WHERE group_id=? AND role='owner'").get(g.id)
  : null;
const u = db.prepare("SELECT id, role FROM users WHERE role='admin' ORDER BY id LIMIT 1").get();
if (!u) { console.error('库里没有 admin，签不出 token'); process.exit(2); }
db.close();

const token = signToken({ uid: u.id, role: u.role });
const BASE = 'http://127.0.0.1:' + (process.env.PORT || 3000);

(async () => {
  if (!g) { console.log('线上还没有任何群，跳过'); process.exit(0); }
  // 会话列表是"我的会话"，用群主身份才看得到这个群
  const ownerRow = owner ? { id: owner.user_id } : null;
  const who = ownerRow || u;
  const tk = signToken({ uid: who.id, role: ownerRow ? 'user' : 'admin' });
  const r = await fetch(BASE + '/api/conversations', {
    headers: { Authorization: 'Bearer ' + tk },
  });
  const list = await r.json();
  const conv = (Array.isArray(list) ? list : []).find((c) => c.id === g.conversation_id);
  console.log('[http] GET /api/conversations ->', r.status);
  if (!conv) {
    console.log('  ✗ 会话列表里找不到这个群（群主可能不是当前签约用户）');
    console.log('  列表里现有的会话:', JSON.stringify((Array.isArray(list) ? list : []).map((c) => ({ id: c.id, type: c.type, is_group: c.is_group }))).slice(0, 300));
    process.exit(1);
  }
  console.log('  is_group      :', conv.is_group);
  console.log('  member_count  :', conv.member_count);
  console.log('  member_avatars:', (conv.member_avatars || []).length, '个 →',
    JSON.stringify((conv.member_avatars || []).map((x) => x.name)));
  const ownerFirst = ownerRow ? conv.member_avatars?.[0]?.id === ownerRow.id : null;
  console.log('  群主排第一格  :', ownerFirst === null ? '(无从判断)' : (ownerFirst ? '✓' : '✗'));

  const okAll = conv.is_group === true
    && conv.member_count === g.n
    && (conv.member_avatars || []).length === Math.min(9, g.n)
    && ownerFirst !== false;
  console.log(okAll ? '\n✓ 群头像素材已上线' : '\n✗ 有问题');
  process.exit(okAll ? 0 : 1);
})();
