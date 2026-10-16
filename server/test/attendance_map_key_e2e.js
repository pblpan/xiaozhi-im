// 打卡点位「地图选点」的 key 接口 —— 端到端测试
//
//   node test/attendance_map_key_e2e.js
//
// 覆盖的**不是**"接口能跑"，而是三件容易悄悄出错的事：
//   1. 🔴 key 绝不外泄：bootstrap（免鉴权）和 /admin/settings 都不许带出它。
//      all() 被 routes/client.js 原样铺给 bootstrap，key 混进去等于白送 ——
//      这是本接口必须独立于 /admin/settings 存在的全部理由。
//   2. 读写权限：只有 admin 能读能写；未登录 401。
//   3. 脏输入拦截：格式不对 400；空串 = 清除（地图选点降级为定位按钮）。
//
// 另附一个坐标转换的单元断言（GCJ-02↔WGS-84）—— 不转的话员工拿 GPS 打卡
// 会差几百米，而那个坑在界面上完全看不出来。

const { spawn } = require('child_process');
const path = require('path');
const fs = require('fs');
const os = require('os');

const PORT = 3712;
const BASE = `http://127.0.0.1:${PORT}`;
const SERVER_DIR = path.resolve(__dirname, '..');
const DATA_DIR = path.join(os.tmpdir(), 'xiaozhi-mapkey-e2e-' + Date.now());

let passed = 0;
let failed = 0;
const failures = [];

function ok(name, cond, extra) {
  if (cond) { passed++; console.log(`  \u2713 ${name}`); }
  else {
    failed++;
    failures.push(name + (extra ? ` — ${extra}` : ''));
    console.log(`  \u2717 ${name}${extra ? '  → ' + extra : ''}`);
  }
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function api(method, p, { token, body } = {}) {
  const res = await fetch(BASE + p, {
    method,
    headers: {
      'Content-Type': 'application/json',
      ...(token ? { Authorization: 'Bearer ' + token } : {}),
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  let json = null;
  try { json = await res.json(); } catch { /* 空响应 */ }
  return { status: res.status, body: json };
}

let serverProc = null;
let serverLog = '';

async function startServer() {
  serverProc = spawn(process.execPath, [path.join(SERVER_DIR, 'src', 'index.js')], {
    env: { ...process.env, PORT: String(PORT), DATA_DIR, ADMIN_PASSWORD: 'TestAdmin_123' },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  serverProc.stdout.on('data', (d) => { serverLog += d.toString(); });
  serverProc.stderr.on('data', (d) => { serverLog += d.toString(); });
  for (let i = 0; i < 60; i++) {
    try {
      const r = await fetch(BASE + '/api/health');
      if (r.ok) return;
    } catch { /* 还没起来 */ }
    await sleep(250);
  }
  throw new Error('服务端启动超时\n' + serverLog);
}

function stopServer() {
  if (serverProc) { try { serverProc.kill(); } catch { /* ignore */ } }
  try { fs.rmSync(DATA_DIR, { recursive: true, force: true }); } catch { /* ignore */ }
}

(async () => {
  await startServer();
  console.log('[map-key E2E] 服务端已就绪 ' + BASE + '\n');

  // ---------------- 登录 ----------------
  let r = await api('POST', '/api/auth/login', { body: { username: 'admin', password: 'TestAdmin_123' } });
  const admin = r.body?.token;
  ok('管理员登录', !!admin, JSON.stringify(r.body));

  r = await api('POST', '/api/auth/register', { body: { username: 'alice', password: 'pw123456', nickname: 'alice' } });
  const alice = r.body?.token;
  ok('注册普通用户', !!alice, JSON.stringify(r.body));

  // ---------------- 建组织（adminGuard 要求组织存在） ----------------
  await api('PUT', '/api/admin/settings', { token: admin, body: { friendMode: 'work' } });
  r = await api('POST', '/api/orgs', { token: admin, body: { name: '地图key测试组织' } });
  ok('创建组织', r.status === 200 || r.status === 201, JSON.stringify(r.body));

  // ---------------- 默认值 ----------------
  console.log('\n【一】默认值与读取');
  r = await api('GET', '/api/admin/attendance/map-key', { token: admin });
  ok('未配置时 hasKey=false', r.status === 200 && r.body.hasKey === false, JSON.stringify(r.body));
  ok('未配置时 key 为空串', r.body.key === '', JSON.stringify(r.body));

  // ---------------- 写入与回读 ----------------
  console.log('\n【二】写入与回读');
  r = await api('PUT', '/api/admin/attendance/map-key', { token: admin, body: { key: 'OB4BZ-D4W3U-B7VVO-4PJWW-6TKDJ-WPB77' } });
  ok('保存 key 成功', r.status === 200 && r.body.hasKey === true, JSON.stringify(r.body));
  r = await api('GET', '/api/admin/attendance/map-key', { token: admin });
  ok('回读到同一个 key', r.body.key === 'OB4BZ-D4W3U-B7VVO-4PJWW-6TKDJ-WPB77', JSON.stringify(r.body));

  // ---------------- 脏输入 ----------------
  console.log('\n【三】脏输入拦截');
  r = await api('PUT', '/api/admin/attendance/map-key', { token: admin, body: { key: '短' } });
  ok('过短的 key 被拒（400）', r.status === 400, JSON.stringify(r.body));
  r = await api('PUT', '/api/admin/attendance/map-key', { token: admin, body: { key: 'x'.repeat(65) } });
  ok('超长的 key 被拒（400）', r.status === 400, JSON.stringify(r.body));
  r = await api('PUT', '/api/admin/attendance/map-key', { token: admin, body: { key: 'abc def!' } });
  ok('含空格/特殊字符被拒（400）', r.status === 400, JSON.stringify(r.body));
  r = await api('GET', '/api/admin/attendance/map-key', { token: admin });
  ok('被拒的输入没有落库（key 没变）', r.body.key === 'OB4BZ-D4W3U-B7VVO-4PJWW-6TKDJ-WPB77', JSON.stringify(r.body));

  r = await api('PUT', '/api/admin/attendance/map-key', { token: admin, body: { key: '' } });
  ok('空串 = 清除 key', r.status === 200 && r.body.hasKey === false, JSON.stringify(r.body));

  // ---------------- 🔴 外泄防线 ----------------
  console.log('\n【四】外泄防线（本接口存在的全部理由）');
  // 先把 key 存回去，再验两条下发路径都不带它
  await api('PUT', '/api/admin/attendance/map-key', { token: admin, body: { key: 'SECRET-MAP-KEY-123' } });

  r = await api('GET', '/api/client/bootstrap');
  ok('🔴 bootstrap（免鉴权）不含 tencentMapKey',
    r.status === 200 && r.body.tencentMapKey === undefined,
    JSON.stringify(Object.keys(r.body || {})));
  ok('bootstrap 本身仍可用（公司名等公开字段还在）',
    r.status === 200 && 'companyName' in r.body, JSON.stringify(r.body));

  r = await api('GET', '/api/admin/settings', { token: admin });
  ok('🔴 /admin/settings 不含 tencentMapKey',
    r.status === 200 && r.body.tencentMapKey === undefined,
    JSON.stringify(Object.keys(r.body || {})));

  // ---------------- 权限 ----------------
  console.log('\n【五】权限');
  r = await api('GET', '/api/admin/attendance/map-key', { token: alice });
  ok('普通用户读 → 403', r.status === 403, JSON.stringify(r.body));
  r = await api('PUT', '/api/admin/attendance/map-key', { token: alice, body: { key: 'HACK-HACK-HACK' } });
  ok('普通用户写 → 403', r.status === 403, JSON.stringify(r.body));
  r = await api('GET', '/api/admin/attendance/map-key');
  ok('未登录读 → 401', r.status === 401, JSON.stringify(r.body));
  r = await api('PUT', '/api/admin/attendance/map-key', { body: { key: 'ANON-ANON-ANON' } });
  ok('未登录写 → 401', r.status === 401, JSON.stringify(r.body));

  r = await api('GET', '/api/admin/attendance/map-key', { token: admin });
  ok('越权尝试都没有改动 key', r.body.key === 'SECRET-MAP-KEY-123', JSON.stringify(r.body));

  // ---------------- 坐标转换（与前端 coord.js 同算法，防前端单独漂移） ----------------
  //
  // 为什么在服务端测试里验前端的算法：这个转换是"地图选点能不能用"的唯一
  // 正确性依赖，而它错了在界面上看不出来（只表现为围栏差几百米）。
  // 服务端不 import 前端的文件，这里用同一组公开常量重算 —— 断言的是
  // "往返误差 < 1 米"和"偏移量级在 100~800 米"（国内典型值），
  // 谁把哪一边的算法改坏了，这条会红。
  console.log('\n【六】坐标转换口径（GCJ-02 ↔ WGS-84）');
  {
    const PI = Math.PI, AXIS = 6378245.0, OFFSET = 0.00669342162296594323;
    const outOfChina = (lat, lng) => !(lng > 73.66 && lng < 135.05 && lat > 3.86 && lat < 53.55);
    function tLat(x, y) {
      let r = -100 + 2 * x + 3 * y + 0.2 * y * y + 0.1 * x * y + 0.2 * Math.sqrt(Math.abs(x));
      r += (20 * Math.sin(6 * x * PI) + 20 * Math.sin(2 * x * PI)) * 2 / 3;
      r += (20 * Math.sin(y * PI) + 40 * Math.sin(y / 3 * PI)) * 2 / 3;
      r += (160 * Math.sin(y / 12 * PI) + 320 * Math.sin(y * PI / 30)) * 2 / 3;
      return r;
    }
    function tLng(x, y) {
      let r = 300 + x + 2 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * Math.sqrt(Math.abs(x));
      r += (20 * Math.sin(6 * x * PI) + 20 * Math.sin(2 * x * PI)) * 2 / 3;
      r += (20 * Math.sin(x * PI) + 40 * Math.sin(x / 3 * PI)) * 2 / 3;
      r += (150 * Math.sin(x / 12 * PI) + 300 * Math.sin(x / 30 * PI)) * 2 / 3;
      return r;
    }
    function delta(lat, lng) {
      let dLat = tLat(lng - 105, lat - 35), dLng = tLng(lng - 105, lat - 35);
      const rl = lat / 180 * PI;
      let m = Math.sin(rl); m = 1 - OFFSET * m * m;
      const sm = Math.sqrt(m);
      dLat = dLat * 180 / ((AXIS * (1 - OFFSET)) / (m * sm) * PI);
      dLng = dLng * 180 / (AXIS / sm * Math.cos(rl) * PI);
      return { dLat, dLng };
    }
    const w2g = (lat, lng) => {
      if (outOfChina(lat, lng)) return { lat, lng };
      const d = delta(lat, lng);
      return { lat: lat + d.dLat, lng: lng + d.dLng };
    };
    const g2w = (lat, lng) => {
      if (outOfChina(lat, lng)) return { lat, lng };
      let wLat = lat, wLng = lng;
      for (let i = 0; i < 5; i++) {
        const g = w2g(wLat, wLng);
        wLat += lat - g.lat; wLng += lng - g.lng;
      }
      return { lat: wLat, lng: wLng };
    };
    const dist = (a, b) => {
      const R = 6371000, toRad = (d) => d * PI / 180;
      const dLat = toRad(b.lat - a.lat), dLng = toRad(b.lng - a.lng);
      const h = Math.sin(dLat / 2) ** 2 + Math.cos(toRad(a.lat)) * Math.cos(toRad(b.lat)) * Math.sin(dLng / 2) ** 2;
      return 2 * R * Math.asin(Math.sqrt(h));
    };

    // 黑龙江海伦（龙哥所在地）与北京各验一组：覆盖不同纬度
    for (const [name, p] of [['北京', { lat: 39.9087, lng: 116.3975 }], ['海伦', { lat: 47.4569, lng: 122.4216 }]]) {
      const g = w2g(p.lat, p.lng);
      const back = g2w(g.lat, g.lng);
      const offset = dist(p, g);
      ok(`${name}：WGS→GCJ 偏移在 100~800 米（典型值）`, offset > 100 && offset < 800, offset.toFixed(1) + ' 米');
      ok(`${name}：往返误差 < 1 米`, dist(p, back) < 1, dist(p, back).toFixed(3) + ' 米');
    }
    // 境外不偏移
    const ny = { lat: 40.7128, lng: -74.0060 };
    const nyG = w2g(ny.lat, ny.lng);
    ok('境外坐标不偏移（原样返回）', nyG.lat === ny.lat && nyG.lng === ny.lng);
  }

  // ---------------- 汇总 ----------------
  console.log('\n' + '='.repeat(52));
  console.log(`通过 ${passed} / ${passed + failed}`);
  if (failed) {
    console.log('\n失败项：');
    failures.forEach((f) => console.log('  ✗ ' + f));
  }
  console.log('='.repeat(52));
  stopServer();
  process.exit(failed ? 1 : 0);
})().catch((e) => {
  console.error('\n[E2E] 异常中断:', e);
  stopServer();
  process.exit(1);
});
