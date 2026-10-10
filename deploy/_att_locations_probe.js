'use strict';
/**
 * 考勤「打卡点位 + 围栏防伪」上线验证探针（跑在容器里）。
 * 硬证据三件套：
 *   1. schema：att_locations / att_group_locations 两张新表 + att_records 四个新列
 *   2. HTTP：带现签管理员 token 实打新接口（401 不算数，必须 200）
 *   3. 引擎：线上 attendance.js 里的 validateFence 冒烟
 * 用法：python deploy/_exec_in_container.py deploy/_att_locations_probe.js
 */
const { signToken } = require('/app/src/auth');
const { DatabaseSync } = require('node:sqlite');

const dbPath = process.argv[2] || '/data/xiaozhi-im.db';
const db = new DatabaseSync(dbPath, { readOnly: true });
const u = db.prepare("SELECT id, role FROM users WHERE role='admin' ORDER BY id LIMIT 1").get();
if (!u) { console.error('库里没有 admin，签不出 token'); process.exit(2); }
const token = signToken({ uid: u.id, role: u.role });

/* ---- 1. schema ---- */
const tbls = db.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name IN ('att_locations','att_group_locations')").all().map((t) => t.name);
console.log('[schema] 新表:', tbls.join(', ') || '（一个都没有！）');
const cols = db.prepare('PRAGMA table_info(att_records)').all().map((c) => c.name);
for (const c of ['accuracy', 'mock', 'loc_status', 'matched_location_id']) {
  console.log(`[schema] att_records.${c}:`, cols.includes(c) ? '✓' : '✗ 缺');
}
db.close();

/* ---- 2. HTTP 实测（容器内自打，带 token） ---- */
const PORT = process.env.PORT || 3000;
const BASE = 'http://127.0.0.1:' + PORT;
async function api(method, p, body) {
  const r = await fetch(BASE + p, {
    method,
    headers: { 'Content-Type': 'application/json', Authorization: 'Bearer ' + token },
    body: body ? JSON.stringify(body) : undefined,
  });
  let j = null; try { j = await r.json(); } catch { /* HTML 错误页会走到这 */ }
  return { status: r.status, body: j };
}

(async () => {
  let r = await api('GET', '/api/admin/attendance/locations');
  console.log('[http] GET  /locations ->', r.status, JSON.stringify(r.body).slice(0, 120));
  r = await api('POST', '/api/admin/attendance/locations', { name: '__探针临时点位__', lat: 45.51, lng: 126.95, radius: 100 });
  console.log('[http] POST /locations ->', r.status, JSON.stringify(r.body).slice(0, 120));
  const id = r.body && r.body.id;
  if (id) {
    r = await api('PUT', `/api/admin/attendance/locations/${id}`, { name: '__探针临时点位2__', lat: 45.52, lng: 126.96, radius: 120 });
    console.log('[http] PUT  /locations/:id ->', r.status, JSON.stringify(r.body));
    r = await api('DELETE', `/api/admin/attendance/locations/${id}`);
    console.log('[http] DEL  /locations/:id ->', r.status, JSON.stringify(r.body));
  }

  /* ---- 3. 引擎冒烟（线上模块真实行为） ---- */
  const att = require('/app/src/attendance');
  const locs = [{ id: 1, name: 'X', lat: 45.51, lng: 126.95, radius: 100 }];
  console.log('[engine] 命中:', JSON.stringify(att.validateFence({ mode: 'required', lat: 45.5105, lng: 126.9505, accuracy: 20, mock: false, locations: locs })));
  console.log('[engine] 超围栏:', JSON.stringify(att.validateFence({ mode: 'required', lat: 46.0, lng: 127.5, accuracy: 20, mock: false, locations: locs })).slice(0, 120));
  console.log('[engine] 模拟定位:', JSON.stringify(att.validateFence({ mode: 'required', lat: 45.51, lng: 126.95, accuracy: 20, mock: true, locations: locs })));
  console.log('[engine] 精度阈值:', att.fenceAccuracyMax(), '米');
  console.log('PROBE DONE');
})().catch((e) => { console.error('探针失败:', e.message); process.exit(1); });
