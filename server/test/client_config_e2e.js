// 客户端配置中心端到端测试（SPEC-动态配置与模块.md 第一期）
//
// 起隔离服务端实例，覆盖：
//   ① bootstrap 免鉴权 + 默认配置 + 内容红线（不含敏感字段）
//   ② 管理台接口的鉴权（401/403）与当前版本
//   ③ 发布合法配置 → 客户端可见；非法配置逐项拒绝且版本号不动
//   ④ 回滚 = 旧内容发新版本（版本只增不改）
//   ⑤ report-applied 上报 + 管理台同步状态（latest/stale）
//
//   node test/client_config_e2e.js

const { spawn } = require('child_process');
const path = require('path');
const fs = require('fs');
const os = require('os');

const PORT = 3697;
const BASE = `http://127.0.0.1:${PORT}`;
const SERVER_DIR = path.resolve(__dirname, '..');
const DATA_DIR = path.join(os.tmpdir(), 'xiaozhi-cc-e2e-' + Date.now());

let passed = 0;
let failed = 0;
const failures = [];

function ok(name, cond, extra) {
  if (cond) {
    passed++;
    console.log(`  \u2713 ${name}`);
  } else {
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

async function main() {
  fs.mkdirSync(DATA_DIR, { recursive: true });
  const child = spawn(process.execPath, ['src/index.js'], {
    cwd: SERVER_DIR,
    env: {
      ...process.env,
      PORT: String(PORT),
      DATA_DIR,
      DB_PATH: path.join(DATA_DIR, 'test.db'),
      ADMIN_USERNAME: 'admin',
      ADMIN_PASSWORD: 'admin-test-pw',
    },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  child.stdout.on('data', () => {});
  child.stderr.on('data', (d) => process.stderr.write('[server] ' + d));

  const shutdown = () => {
    try { child.kill(); } catch { /* ignore */ }
    try { fs.rmSync(DATA_DIR, { recursive: true, force: true }); } catch { /* ignore */ }
  };
  process.on('exit', shutdown);

  let up = false;
  for (let i = 0; i < 60; i++) {
    try {
      const r = await fetch(BASE + '/api/health');
      if (r.ok) { up = true; break; }
    } catch { /* 还没起来 */ }
    await sleep(200);
  }
  if (!up) throw new Error('服务端未能在 12 秒内启动');

  // ---- 准备：管理员 + 普通用户 ----
  const admin = (await api('POST', '/api/auth/login', {
    body: { username: 'admin', password: 'admin-test-pw' },
  })).body.token;
  ok('管理员登录', !!admin);

  await api('POST', '/api/auth/register', { body: { username: 'zhang', password: 'pass123456', nickname: '小张' } });
  const user = (await api('POST', '/api/auth/login', {
    body: { username: 'zhang', password: 'pass123456' },
  })).body.token;
  ok('普通用户登录', !!user);

  // ---- ① bootstrap 免鉴权 + 默认配置 ----
  const bs0 = await api('GET', '/api/client/bootstrap');
  ok('bootstrap 免鉴权可访问（200 而非 401）', bs0.status === 200, `实际 ${bs0.status}`);
  ok('首版 configVersion = 1', bs0.body?.configVersion === 1, `实际 ${bs0.body?.configVersion}`);
  const p0 = bs0.body?.payload || {};
  ok('默认配置结构齐全（serverAddresses/features/minClientVersion/announcements）',
    Array.isArray(p0.serverAddresses) && typeof p0.features === 'object'
    && 'minClientVersion' in p0 && Array.isArray(p0.announcements));
  ok('返回服务端版本号', typeof bs0.body?.serverVersion === 'string');
  const bsStr = JSON.stringify(bs0.body);
  ok('bootstrap 内容红线：不含敏感字段（password/secret/token）',
    !/password|secret/i.test(bsStr) && !bsStr.includes('"token"'));

  // 未登录走受保护接口：401 而非 404（路由存在，只是要登录）
  const ra0 = await api('POST', '/api/client/report-applied', { body: { configVersion: 1 } });
  ok('report-applied 未登录 → 401', ra0.status === 401, `实际 ${ra0.status}`);
  const cfg0 = await api('GET', '/api/client/config');
  ok('config 未登录 → 401', cfg0.status === 401, `实际 ${cfg0.status}`);

  // ---- ② 管理台接口鉴权 ----
  const a0 = await api('GET', '/api/admin/client-config');
  ok('管理台配置接口未登录 → 401', a0.status === 401, `实际 ${a0.status}`);
  const a1 = await api('GET', '/api/admin/client-config', { token: user });
  ok('管理台配置接口普通用户 → 403', a1.status === 403, `实际 ${a1.status}`);
  const a2 = await api('GET', '/api/admin/client-config', { token: admin });
  ok('管理员能读到当前配置 v1', a2.status === 200 && a2.body?.current?.version === 1);
  ok('历史版本列表返回', Array.isArray(a2.body?.history) && a2.body.history.length === 1);

  // ---- ③ 发布合法配置 ----
  const good = {
    serverAddresses: ['http://192.168.31.44:3602/', 'http://192.168.31.44:3602', 'https://demo.example.com'],
    features: { groupCall: true, moments: false },
    minClientVersion: '0.7.0',
    announcements: [{ text: '今晚 22:00 维护', level: 'warn' }],
  };
  const pub = await api('POST', '/api/admin/client-config', { token: admin, body: { payload: good, note: '第一次发布' } });
  ok('发布合法配置成功 → v2', pub.status === 200 && pub.body?.version === 2, `实际 ${pub.status} ${JSON.stringify(pub.body)}`);
  ok('地址去重 + 去尾斜杠（3 条进 2 条）',
    pub.body?.payload?.serverAddresses?.length === 2
    && pub.body.payload.serverAddresses[0] === 'http://192.168.31.44:3602');

  const bs1 = await api('GET', '/api/client/bootstrap');
  ok('客户端 bootstrap 立刻读到 v2 新内容',
    bs1.body?.configVersion === 2
    && bs1.body?.payload?.features?.groupCall === true
    && bs1.body?.payload?.minClientVersion === '0.7.0');

  // ---- ④ 非法配置逐项拒绝，版本号不动 ----
  const bads = [
    ['未知顶层键', { hacker: true }],
    ['地址缺 scheme', { serverAddresses: ['192.168.1.9:3602'] }],
    ['地址不是数组', { serverAddresses: 'http://x' }],
    ['开关值非布尔', { features: { groupCall: 'yes' } }],
    ['最低版本格式错', { minClientVersion: '0.7' }],
    ['公告空文本', { announcements: [{ text: '  ' }] }],
    ['公告超量', { announcements: Array.from({ length: 6 }, (_, i) => ({ text: 'a' + i })) }],
    ['upgradeUrl 非 http', { upgradeUrl: 'ftp://x' }],
    ['配置不是对象', 'nonsense'],
  ];
  for (const [label, payload] of bads) {
    const r = await api('POST', '/api/admin/client-config', { token: admin, body: { payload } });
    ok(`非法配置拒绝：${label}（400）`, r.status === 400, `实际 ${r.status}`);
  }
  const cur = await api('GET', '/api/admin/client-config', { token: admin });
  ok('全部拒绝后版本号仍是 v2', cur.body?.current?.version === 2, `实际 ${cur.body?.current?.version}`);

  // ---- ⑤ 回滚 = 旧内容发新版本 ----
  const rb = await api('POST', '/api/admin/client-config/rollback', { token: admin, body: { version: 1 } });
  ok('回滚 v1 → 发布为 v3', rb.status === 200 && rb.body?.version === 3, `实际 ${rb.status} ${JSON.stringify(rb.body)}`);
  const bs2 = await api('GET', '/api/client/bootstrap');
  ok('回滚后客户端读到的是 v1 的默认内容',
    bs2.body?.configVersion === 3 && bs2.body?.payload?.features?.groupCall === undefined);
  const rbBad = await api('POST', '/api/admin/client-config/rollback', { token: admin, body: { version: 999 } });
  ok('回滚不存在的版本 → 400', rbBad.status === 400);

  // ---- ⑥ report-applied + 同步状态 ----
  const ra1 = await api('POST', '/api/client/report-applied', {
    token: user, body: { configVersion: 3, deviceId: 'phone-abc' },
  });
  ok('登录用户上报生效版本成功', ra1.status === 200);
  const raBad = await api('POST', '/api/client/report-applied', {
    token: user, body: { configVersion: 'x' },
  });
  ok('上报非法版本号 → 400', raBad.status === 400);

  const st1 = await api('GET', '/api/admin/client-config/applied', { token: admin });
  ok('同步状态：设备 phone-abc 是 latest',
    st1.body?.devices?.some((d) => d.device_id === 'phone-abc' && d.state === 'latest'),
    JSON.stringify(st1.body));

  await api('POST', '/api/client/report-applied', { token: user, body: { configVersion: 2, deviceId: 'old-pc' } });
  const st2 = await api('GET', '/api/admin/client-config/applied', { token: admin });
  ok('同步状态：落后设备标为 stale',
    st2.body?.devices?.some((d) => d.device_id === 'old-pc' && d.state === 'stale')
    && st2.body?.latest === 3);
  const ra2 = await api('POST', '/api/client/report-applied', { token: user, body: { configVersion: 3, deviceId: 'phone-abc' } });
  ok('同一设备重复上报幂等（不报错）', ra2.status === 200);

  // ---- 收尾 ----
  console.log(`\n结果: ${passed} 通过, ${failed} 失败`);
  if (failed) {
    console.log('失败项:\n - ' + failures.join('\n - '));
    process.exitCode = 1;
  }
  child.kill();
  await sleep(100);
}

main().catch((e) => {
  console.error('测试崩溃:', e);
  process.exit(1);
});
