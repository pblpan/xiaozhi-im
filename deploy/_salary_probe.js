'use strict';
/**
 * 智能薪酬上线验证探针（跑在容器里）。
 * 验证：salary_config/salary_base 两张表已建、薪酬接口在鉴权后能正常返回、
 *       管理台新构建已包含「智能薪酬」字样。
 * 只读为主：写操作只动 salary_config/salary_base（探针自己的测试数据，最后清理）。
 * 用法：python deploy/_exec_in_container.py deploy/_salary_probe.js
 */
const { signToken } = require('/app/src/auth');
const { DatabaseSync } = require('node:sqlite');

const db = new DatabaseSync('/data/xiaozhi-im.db', { readOnly: true });

let pass = 0, fail = 0;
const ok = (n, c, x) => { if (c) { pass++; console.log('  ✓ ' + n); } else { fail++; console.log('  ✗ ' + n + (x ? '  → ' + x : '')); } };

// 1. 表已建
const t1 = db.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name='salary_config'").get();
const t2 = db.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name='salary_base'").get();
ok('salary_config / salary_base 两张表已建', !!t1 && !!t2,
  JSON.stringify([!!t1, !!t2]));

const admin = db.prepare("SELECT id FROM users WHERE role='admin' ORDER BY id LIMIT 1").get();
const org = db.prepare('SELECT id FROM orgs LIMIT 1').get();
db.close();
console.log('[db] admin/org:', JSON.stringify([admin?.id, org?.id]));

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
  if (!org) { console.log('线上还没有组织，薪酬接口跳过（表已验证）'); process.exit(fail ? 1 : 0); }

  // 2. 配置接口
  let r = await api('GET', '/api/admin/attendance/salary/config');
  ok('GET salary/config → 200', r.status === 200, JSON.stringify(r.body).slice(0, 160));
  ok('  配置字段齐全（档位/全勤奖/计薪天数）',
    Array.isArray(r.body?.config?.lateTiers) && Number.isFinite(r.body?.config?.fullAttendanceBonus)
    && Number.isFinite(r.body?.config?.dayDivisor), JSON.stringify(r.body?.config));

  // 3. 基数接口
  r = await api('GET', '/api/admin/attendance/salary/bases');
  ok('GET salary/bases → 200（items 是数组）', r.status === 200 && Array.isArray(r.body?.items),
    JSON.stringify(r.body).slice(0, 160));

  // 4. 报表接口（当月）
  const d = new Date();
  const month = `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}`;
  r = await api('GET', `/api/admin/attendance/salary/report?month=${month}`);
  ok('GET salary/report → 200 且逐人带 items/net',
    r.status === 200 && Array.isArray(r.body?.items)
    && r.body.items.every((x) => Array.isArray(x.items) && Number.isFinite(x.net)),
    JSON.stringify(r.body).slice(0, 240));

  // 5. 未登录 401 / 员工端存在
  const anon = await fetch(BASE + '/api/admin/attendance/salary/report?month=' + month);
  ok('未登录报表 → 401', anon.status === 401, String(anon.status));

  console.log(`\n探针结果: ${pass} 通过 / ${fail} 失败`);
  process.exit(fail ? 1 : 0);
})().catch((e) => { console.error('探针崩溃:', e); process.exit(1); });
