// 生产考勤接口只读冒烟：确认 v0.13.0 的接口在真实部署下都活着（不改任何数据）
// 用法：XZ_SECRET=<JWT_SECRET> node _admin_att_api_smoke.js
const crypto = require('crypto');

const BASE = 'http://192.168.31.44:3602';
const SECRET = process.env.XZ_SECRET || '';

function b64url(buf) {
  return Buffer.from(buf).toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}
function mintToken(uid, role) {
  const now = Math.floor(Date.now() / 1000);
  const head = b64url(JSON.stringify({ alg: 'HS256', typ: 'JWT' }));
  const body = b64url(JSON.stringify({ uid, role, iat: now, exp: now + 30 * 86400 }));
  return head + '.' + body + '.' + b64url(crypto.createHmac('sha256', SECRET).update(head + '.' + body).digest());
}

let failed = 0;
const ok = (name, cond, extra) => {
  console.log((cond ? '  ✓ ' : '  ✗ ') + name + (cond || !extra ? '' : '  → ' + extra));
  if (!cond) failed++;
};

(async () => {
  const token = mintToken(1, 'admin');
  const H = { Authorization: 'Bearer ' + token, 'Content-Type': 'application/json' };

  async function get(path) {
    const r = await fetch(BASE + path, { headers: H });
    let j = null;
    try { j = await r.json(); } catch { /* 非 JSON */ }
    return { status: r.status, body: j };
  }
  async function put(path, body) {
    const r = await fetch(BASE + path, { method: 'PUT', headers: H, body: JSON.stringify(body) });
    let j = null;
    try { j = await r.json(); } catch { /* 非 JSON */ }
    return { status: r.status, body: j };
  }

  const day = new Date().toISOString().slice(0, 10);

  console.log('== 只读接口 ==');
  let r = await get('/api/admin/attendance/config');
  ok('GET /config → 200', r.status === 200, JSON.stringify(r.body).slice(0, 120));
  ok('  defaultShift 带午休窗口与分段',
    !!r.body?.defaultShift && 'restStart' in r.body.defaultShift
    && r.body.defaultShift.punchesPerDay === 4, JSON.stringify(r.body?.defaultShift));

  r = await get('/api/admin/attendance/shifts');
  ok('GET /shifts → 200', r.status === 200, JSON.stringify(r.body).slice(0, 120));
  ok('  defaultShift 应出勤 480 分钟', r.body?.defaultShift?.expectedWorkMinutes === 480,
    String(r.body?.defaultShift?.expectedWorkMinutes));

  r = await get('/api/admin/attendance/groups');
  ok('GET /groups → 200', r.status === 200, JSON.stringify(r.body).slice(0, 120));

  r = await get('/api/admin/attendance/overview?day=' + day);
  ok('GET /overview → 200（逐张卡结构）', r.status === 200, JSON.stringify(r.body).slice(0, 160));
  const first = (r.body?.items || [])[0];
  ok('  看板条目带 punches 数组', first === undefined || Array.isArray(first.punches),
    first === undefined ? '(今天没有员工，跳过)' : typeof first.punches);

  const from = new Date(Date.now() - 6 * 86400000).toISOString().slice(0, 10);
  r = await get(`/api/admin/attendance/report?from=${from}&to=${day}`);
  ok('GET /report → 200', r.status === 200, JSON.stringify(r.body).slice(0, 160));
  ok('  totals 含 missingPunches / workedMinutes',
    r.body?.totals && 'missingPunches' in r.body.totals && 'workedMinutes' in r.body.totals,
    JSON.stringify(r.body?.totals));

  r = await get('/api/admin/attendance/requests');
  ok('GET /requests → 200', r.status === 200, JSON.stringify(r.body).slice(0, 120));

  console.log('\n== 校验护栏（期望 400，不落库）==');
  r = await put('/api/admin/attendance/config', { defaultShift: { workStart: '09:00', workEnd: '18:00', restStart: '12:00' } });
  ok('只填午休开始 → 400', r.status === 400, JSON.stringify(r.body));
  r = await put('/api/admin/attendance/config', { defaultShift: { workStart: '09:00', workEnd: '18:00', restStart: '08:00', restEnd: '09:30' } });
  ok('午休早于上班 → 400', r.status === 400, JSON.stringify(r.body));
  r = await put('/api/admin/attendance/config', { defaultShift: { workStart: '22:00', workEnd: '06:00', restStart: '02:00', restEnd: '03:00' } });
  ok('跨天夜班带午休 → 400', r.status === 400, JSON.stringify(r.body));

  console.log('\n== 确认没被上面的护栏用例改坏 ==');
  r = await get('/api/admin/attendance/config');
  ok('默认班次仍是 08:00-12:00 / 13:00-17:00',
    r.body?.defaultShift?.workStart === '08:00' && r.body?.defaultShift?.restStart === '12:00'
    && r.body?.defaultShift?.restEnd === '13:00' && r.body?.defaultShift?.workEnd === '17:00',
    JSON.stringify(r.body?.defaultShift));

  console.log('\n' + (failed ? `失败 ${failed} 项` : '全部通过'));
  process.exit(failed ? 1 : 0);
})().catch((e) => { console.error('异常中断:', e); process.exit(3); });
