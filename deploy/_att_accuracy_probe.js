'use strict';
/**
 * 「定位精度阈值后台可配」上线验证探针（跑在容器里）。
 * 硬证据：
 *   1. GET  /api/admin/attendance/config 带回 fenceAccuracyMax
 *   2. PUT  改成 350 → 回显 350，且引擎现读到的阈值同步变成 350（改完即生效）
 *   3. PUT  越界值（5 / 9999 / 'abc'）→ 400，且没污染配置
 *   4. 免鉴权 /api/client/bootstrap 里搜不到任何 fence 字样
 *   5. 复位成 200
 * 用法：python deploy/_exec_in_container.py deploy/_att_accuracy_probe.js
 */
const { signToken } = require('/app/src/auth');
const { DatabaseSync } = require('node:sqlite');

const db = new DatabaseSync('/data/xiaozhi-im.db', { readOnly: true });
const u = db.prepare("SELECT id, role FROM users WHERE role='admin' ORDER BY id LIMIT 1").get();
if (!u) { console.error('库里没有 admin，签不出 token'); process.exit(2); }
const row = db.prepare("SELECT value FROM settings WHERE key='att_fence_accuracy_max'").get();
console.log('[db] settings.att_fence_accuracy_max 原始值:', row ? row.value : '(未落库=走默认 200)');
db.close();

const token = signToken({ uid: u.id, role: u.role });
const BASE = 'http://127.0.0.1:' + (process.env.PORT || 3000);
async function api(method, p, body) {
  const r = await fetch(BASE + p, {
    method,
    headers: { 'Content-Type': 'application/json', Authorization: 'Bearer ' + token },
    body: body ? JSON.stringify(body) : undefined,
  });
  let j = null; try { j = await r.json(); } catch { /* HTML 错误页 */ }
  return { status: r.status, body: j };
}

let pass = 0, fail = 0;
function ok(name, cond, extra) {
  if (cond) { pass++; console.log('  ✓ ' + name); }
  else { fail++; console.log('  ✗ ' + name + (extra ? '  → ' + extra : '')); }
}

(async () => {
  console.log('\n【线上】定位精度阈值后台可配');

  let r = await api('GET', '/api/admin/attendance/config');
  console.log('  GET /config fenceAccuracyMax =', r.body && r.body.fenceAccuracyMax);
  ok('配置接口带回 fenceAccuracyMax', r.status === 200 && typeof r.body?.fenceAccuracyMax === 'number', JSON.stringify(r.body).slice(0, 160));
  const before = r.body?.fenceAccuracyMax;

  r = await api('PUT', '/api/admin/attendance/config', { fenceAccuracyMax: 350 });
  ok('改成 350 → 200 且回显', r.status === 200 && r.body?.fenceAccuracyMax === 350, JSON.stringify(r.body).slice(0, 160));

  const att = require('/app/src/attendance');
  ok('引擎现读阈值同步为 350（改完即生效，不用重启）', att.fenceAccuracyMax() === 350, String(att.fenceAccuracyMax()));

  r = await api('PUT', '/api/admin/attendance/config', { fenceAccuracyMax: 5 });
  ok('阈值 5（<10）→ 400', r.status === 400, JSON.stringify(r.body).slice(0, 160));
  r = await api('PUT', '/api/admin/attendance/config', { fenceAccuracyMax: 9999 });
  ok('阈值 9999（>2000）→ 400', r.status === 400, JSON.stringify(r.body).slice(0, 160));
  r = await api('PUT', '/api/admin/attendance/config', { fenceAccuracyMax: '很准' });
  ok('阈值非数字 → 400', r.status === 400, JSON.stringify(r.body).slice(0, 160));

  r = await api('GET', '/api/admin/attendance/config');
  ok('非法值没污染配置（仍是 350）', r.body?.fenceAccuracyMax === 350, String(r.body?.fenceAccuracyMax));

  // 防伪参数不能从免鉴权接口漏出去
  const boot = await fetch(BASE + '/api/client/bootstrap');
  const bootText = boot.ok ? JSON.stringify(await boot.json()) : '';
  ok('免鉴权 bootstrap 不含 fence 字样', boot.status === 200 && !/fence/i.test(bootText), bootText.slice(0, 160));

  r = await api('PUT', '/api/admin/attendance/config', { fenceAccuracyMax: before || 200 });
  ok('复位为 ' + (before || 200) + ' → 200', r.status === 200 && r.body?.fenceAccuracyMax === (before || 200), JSON.stringify(r.body).slice(0, 160));

  console.log(`\n通过 ${pass} / ${pass + fail}`);
  process.exit(fail ? 1 : 0);
})();
