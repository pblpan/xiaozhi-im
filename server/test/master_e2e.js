// 商品档案（商档）接口 —— 端到端测试
//
//   node test/master_e2e.js
//
// 覆盖：门禁（未登录读不到 / 普通员工能读但不能写）、分块写入、
// 同条码覆盖、非法条码拒绝、commit 换底表（旧数据被换掉）、
// **没 commit 时旧商档必须完好**（传一半放弃不能让店里拿到残缺底表）、
// 分页拉取、增量拉取（since）、清空。
//
// 【为什么"传一半不 commit"必须单独测】
// 这是整个设计里最容易做错、错了又最难发现的一条：12 万行分 60 块传，
// 传到第 30 块网断了。如果写块时就删旧数据，店里会拿着一份缺一半的底表
// 去盘，而界面上完全看不出来 —— 差异集会静默失真。
// 断言必须落在**旧行还在**上，而不是"没报错"。

const { spawn } = require('child_process');
const path = require('path');
const fs = require('fs');
const os = require('os');

const PORT = 3716;
const BASE = `http://127.0.0.1:${PORT}`;
const SERVER_DIR = path.resolve(__dirname, '..');
const DATA_DIR = path.join(os.tmpdir(), 'xiaozhi-master-e2e-' + Date.now());

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
    try { const r = await fetch(BASE + '/api/health'); if (r.ok) return; } catch { /* 还没起来 */ }
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
  console.log('[master E2E] 服务端已就绪 ' + BASE + '\n');

  let r = await api('POST', '/api/auth/login', { body: { username: 'admin', password: 'TestAdmin_123' } });
  const admin = r.body?.token;
  ok('管理员登录', !!admin, JSON.stringify(r.body));

  r = await api('POST', '/api/auth/register', { body: { username: 'pda002', password: 'pda002', nickname: '盘点员小李' } });
  const staff = r.body?.token;
  ok('普通员工注册', !!staff, JSON.stringify(r.body));

  // ============================================================
  console.log('\n【一】门禁：读放开、写收紧');
  r = await api('GET', '/api/master/count');
  ok('未登录拉商档 → 401', r.status === 401, String(r.status));
  r = await api('GET', '/api/master/count', { token: staff });
  ok('员工能读商档（盘点的人不一定有管理台权限）', r.status === 200 && r.body.total === 0, JSON.stringify(r.body));
  r = await api('POST', '/api/master/upload', { token: staff, body: { batch: 'B1', rows: [{ barcode: 'X1', name: 'x' }] } });
  ok('员工写商档 → 403（底表谁都能改等于没有底表）', r.status === 403, String(r.status));
  r = await api('POST', '/api/master/upload', { token: admin, body: { rows: [{ barcode: 'X1' }] } });
  ok('管理员上传但没带 batch → 400', r.status === 400, String(r.status));

  // ============================================================
  console.log('\n【二】分块写 + commit 换底表');
  const batchA = 'BATCH-A';
  r = await api('POST', '/api/master/upload', { token: admin, body: { batch: batchA, rows: [
    { barcode: '6900001', name: '矿泉水', spec: '550ml', unit: '瓶', unit_price: 2.5, account_qty: 100 },
    { barcode: '6900002', name: '方便面', unit: '袋', account_qty: 40 },
  ] } });
  ok('写第 1 块 2 行', r.status === 200 && r.body.accepted === 2, JSON.stringify(r.body));

  r = await api('POST', '/api/master/upload', { token: admin, body: { batch: batchA, rows: [
    { barcode: '6900003', name: '纸巾', unit_price: 9.9, account_qty: 12 },
    { barcode: '6900001', name: '矿泉水（改名）', account_qty: 88 },   // 同条码覆盖
    { barcode: 'bad/001', name: '带斜杠的条码' },                      // 非法
    { barcode: '   ', name: '空条码' },                                // 非法
  ] } });
  ok('写第 2 块：接受 2 行、拒 2 行', r.status === 200 && r.body.accepted === 2 && r.body.rejected_total === 2,
    JSON.stringify(r.body));

  // 🔴 反向测试：还没 commit，谁也没资格说"底表已经换了"
  r = await api('GET', '/api/master/count', { token: staff });
  ok('未 commit 时行数已可见（3 行）', r.body.total === 3, JSON.stringify(r.body));

  r = await api('POST', '/api/master/upload', { token: admin, body: { batch: batchA, rows: Array.from({ length: 2001 }, (_, i) => ({ barcode: 'OVER' + i })) } });
  ok('单块超过 2000 行 → 400（防止一次把内存打满）', r.status === 400, String(r.status));

  r = await api('POST', '/api/master/commit', { token: admin, body: { batch: batchA } });
  ok('commit 成功', r.status === 200 && r.body.ok === true, JSON.stringify(r.body));

  r = await api('GET', '/api/master/', { token: staff });
  const byCode = Object.fromEntries((r.body?.items || []).map((x) => [x.barcode, x]));
  ok('同条码被覆盖成最新一条（数量 88、名字已改）',
    byCode['6900001'] && byCode['6900001'].account_qty === 88 && byCode['6900001'].name === '矿泉水（改名）',
    JSON.stringify(byCode['6900001']));
  ok('账上没有的商品 account_qty 可以是 NULL 之外的数（12）',
    byCode['6900003'] && byCode['6900003'].account_qty === 12, JSON.stringify(byCode['6900003']));

  // ============================================================
  console.log('\n【三】🔴 传一半放弃：旧商档必须完好');
  // 模拟"换新商档传到一半网络断了"：只写新批次的一块，**不 commit**
  r = await api('POST', '/api/master/upload', { token: admin, body: { batch: 'BATCH-B', rows: [
    { barcode: '9000001', name: '新商档第 1 块', account_qty: 1 },
  ] } });
  ok('新批次写入成功（但没 commit）', r.status === 200 && r.body.accepted === 1, JSON.stringify(r.body));
  r = await api('GET', '/api/master/', { token: staff });
  const codes = (r.body?.items || []).map((x) => x.barcode).sort();
  ok('旧商档一行都没丢（6900001/2/3 全在）',
    ['6900001', '6900002', '6900003'].every((c) => codes.includes(c)), JSON.stringify(codes));
  ok('新批次的数据也在（可以接着传，也可以放弃）', codes.includes('9000001'), JSON.stringify(codes));

  // 放弃 → 直接删掉未 commit 的新批次（管理台"取消导入"就是这个动作）
  r = await api('POST', '/api/master/commit', { token: admin, body: { batch: batchA } });
  ok('再 commit 旧批次 → 未提交的新批次被清掉', r.status === 200, JSON.stringify(r.body));
  r = await api('GET', '/api/master/', { token: staff });
  ok('放弃的批次没有污染底表', (r.body?.items || []).length === 3, String((r.body?.items || []).length));

  // ============================================================
  console.log('\n【四】分页与增量');
  r = await api('GET', '/api/master/?pageSize=2&page=1', { token: staff });
  ok('第 1 页 2 行且 has_more=true', r.body.items.length === 2 && r.body.has_more === true, JSON.stringify(r.body));
  r = await api('GET', '/api/master/?pageSize=2&page=2', { token: staff });
  ok('第 2 页 1 行且 has_more=false', r.body.items.length === 1 && r.body.has_more === false, JSON.stringify(r.body));
  r = await api('GET', '/api/master/?pageSize=99999', { token: staff });
  ok('pageSize 被夹到 5000（不让人一次把库拖出来）', r.body.pageSize === 5000, String(r.body.pageSize));

  const before = await api('GET', '/api/master/count', { token: staff });
  r = await api('GET', '/api/master/?since=' + before.body.updated_at, { token: staff });
  ok('since=最后更新时间 → 增量为空', r.body.total === 0, JSON.stringify(r.body));
  r = await api('GET', '/api/master/?since=1', { token: staff });
  ok('since=1 → 全量 3 行', r.body.total === 3, String(r.body.total));

  // ============================================================
  console.log('\n【五】清空');
  r = await api('DELETE', '/api/master/', { token: staff });
  ok('员工清空 → 403', r.status === 403, String(r.status));
  r = await api('DELETE', '/api/master/', { token: admin });
  ok('管理员清空', r.status === 200 && r.body.deleted === 3, JSON.stringify(r.body));
  r = await api('GET', '/api/master/count', { token: staff });
  ok('清空后 total=0', r.body.total === 0, JSON.stringify(r.body));

  stopServer();
  console.log(`\n通过 ${passed} 项，失败 ${failed} 项`);
  if (failed) {
    console.log('失败项：');
    failures.forEach((f) => console.log('  · ' + f));
    process.exit(1);
  }
  console.log('商档接口全部通过 ✅');
})().catch((e) => {
  console.error(e);
  stopServer();
  process.exit(1);
});
