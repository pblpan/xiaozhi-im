'use strict';
/**
 * 群功能面板上线验证探针（跑在容器里）。
 * 拿线上真实群打一遍：群文件/相册/视频/群课堂 + 管理员进群。
 * 只读操作为主，最后会把临时挂的课程摘掉，不留脏数据。
 * 用法：python deploy/_exec_in_container.py deploy/_group_panel_probe.js
 */
const { signToken } = require('/app/src/auth');
const { DatabaseSync } = require('node:sqlite');

const db = new DatabaseSync('/data/xiaozhi-im.db', { readOnly: true });
const g = db.prepare(`SELECT g.id, g.name, g.conversation_id,
  (SELECT COUNT(*) FROM group_members gm WHERE gm.group_id = g.id) n
  FROM groups g ORDER BY n DESC LIMIT 1`).get();
const admin = db.prepare("SELECT id FROM users WHERE role='admin' ORDER BY id LIMIT 1").get();
// 群里任意一个成员（不是管理员）用来测"成员可见"
const member = g ? db.prepare('SELECT user_id, role FROM group_members WHERE group_id=? LIMIT 1').get(g.id) : null;
const hasCourse = db.prepare('SELECT id, title FROM tr_course LIMIT 1').get();
const gcTable = db.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name='group_courses'").get();
db.close();

console.log('[schema] group_courses 表:', gcTable ? '✓ 已建' : '✗ 没有');
console.log('[db] 取样群:', JSON.stringify(g));
console.log('[db] 培训中心有没有课:', JSON.stringify(hasCourse));

const BASE = 'http://127.0.0.1:' + (process.env.PORT || 3000);
const tk = (uid, role) => signToken({ uid, role });
async function api(method, p, token, body) {
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
  if (!g || !admin) { console.log('线上数据不足，跳过'); process.exit(0); }
  const tAdmin = tk(admin.id, 'admin');
  const tMember = member ? tk(member.user_id, 'user') : null;

  console.log('\n【线上】群功能面板');

  // 管理员先加入这个群（幂等），后面才能读面板
  let r = await api('POST', `/api/groups/${g.id}/join`, tAdmin);
  ok('管理员进群 → 200', r.status === 200, JSON.stringify(r.body).slice(0, 160));

  r = await api('GET', '/api/groups/all', tAdmin);
  ok('管理员看得到全部群', r.status === 200 && (r.body?.items || []).length >= 1,
    JSON.stringify(r.body?.items?.map((x) => ({ id: x.id, name: x.name, joined: x.joined }))).slice(0, 200));

  for (const [name, path] of [['群文件', 'files'], ['群相册', 'albums'], ['群视频', 'videos']]) {
    r = await api('GET', `/api/groups/${g.id}/${path}`, tAdmin);
    ok(`${name} → 200（${(r.body?.items || []).length} 条）`, r.status === 200 && Array.isArray(r.body?.items),
      JSON.stringify(r.body).slice(0, 160));
  }

  if (tMember) {
    r = await api('GET', `/api/groups/${g.id}/files`, tMember);
    ok('群成员也能读群文件 → 200', r.status === 200, JSON.stringify(r.body).slice(0, 120));
  }

  // ---- 群课堂 ----
  r = await api('GET', `/api/groups/${g.id}/courses`, tAdmin);
  ok('群课堂 → 200', r.status === 200 && Array.isArray(r.body?.items),
    JSON.stringify(r.body).slice(0, 160));

  if (hasCourse) {
    r = await api('POST', `/api/groups/${g.id}/courses`, tAdmin, { courseId: hasCourse.id });
    ok(`挂课程「${hasCourse.title}」→ 200`, r.status === 200, JSON.stringify(r.body).slice(0, 160));
    r = await api('GET', `/api/groups/${g.id}/courses`, tAdmin);
    ok('  群课堂里出现了这门课', (r.body?.items || []).some((c) => c.id === hasCourse.id),
      JSON.stringify(r.body?.items?.map((c) => c.title)));
    ok('  带回 progressPct 字段（不省字段）',
      typeof r.body?.items?.[0]?.progressPct === 'number', JSON.stringify(r.body?.items?.[0]));
    // 探完就摘掉，别在龙哥的群里留下测试课程
    r = await api('DELETE', `/api/groups/${g.id}/courses/${hasCourse.id}`, tAdmin);
    ok('  摘掉（不留脏数据）→ 200', r.status === 200, JSON.stringify(r.body).slice(0, 120));
  } else {
    console.log('  (培训中心还没有课，跳过挂课程实测)');
  }

  // ---- 门禁 ----
  r = await api('GET', `/api/groups/${g.id}/files`, '');
  ok('未登录读群文件 → 401', r.status === 401, String(r.status));

  console.log(`\n通过 ${pass} / ${pass + fail}`);
  process.exit(fail ? 1 : 0);
})();
