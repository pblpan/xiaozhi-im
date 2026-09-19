// 盘点接口（inventory 模块 · P1 盘点内核服务端部分）—— 端到端测试
//
//   node test/inventory_e2e.js
//
// 覆盖：门禁（未登录 / 普通盘点员能盘但删不了点位）、点位与库位 CRUD、
// 锁定点位不让开单、商品↔货架位绑定与反查、单据上传的**幂等与覆盖保护**、
// 单据详情的差异集（含"账上没有"这一类）、复盘的服务端差异集校验
// （以及"服务端还没初盘数据时不硬校"这条边界）、阶段小结与失误笔数、
// 单据列表分页、同步拉取、删点位级联与权限。
//
// 【几个数字为什么写成断言】
// 这些不是"随手写个 3"，每一个都对应一条会静默出错的规则：
//   · 重传后行数必须不变（变成 6 行 = 同一品种被算两遍，差异集立刻失真）；
//   · account_qty 为 NULL 的行必须算差异（SQL 里 qty - NULL 求值是 NULL 不是 TRUE，
//     这批行会被静默丢掉，而它们恰恰是最严重的差异）；
//   · 已归档的单不传 force 必须 409（默认放行 = 盘点结果可以事后修饰）。
// 所以这些数字变了，说明规则坏了，要回头改代码而不是改数字。
//
// 【为什么每个用例用独立的点位】
// 阶段小结/差异集是**按"点位 × 阶段"跨该阶段所有单汇总**的（一张单被拆成几张
// 是常态）。所以往同一个点位里反复灌数据，前一个用例的数字会渗到后一个用例里，
// 断言就得跟着改 —— 那不是测试，那是给自己挖坑。每个用例一个干净的 Zxx。

const { spawn } = require('child_process');
const path = require('path');
const fs = require('fs');
const os = require('os');

const PORT = 3712;
const BASE = `http://127.0.0.1:${PORT}`;
const SERVER_DIR = path.resolve(__dirname, '..');
const DATA_DIR = path.join(os.tmpdir(), 'xiaozhi-inv-e2e-' + Date.now());

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

/** 上传的公共外壳 */
function uploadBody(zone, phase, rows, extra = {}) {
  return { zone: { zone_code: zone, zone_name: zone + '区' }, phase, rows, ...extra };
}

(async () => {
  await startServer();
  console.log('[inventory E2E] 服务端已就绪 ' + BASE + '\n');

  let r = await api('POST', '/api/auth/login', { body: { username: 'admin', password: 'TestAdmin_123' } });
  const admin = r.body?.token;
  ok('管理员登录', !!admin, JSON.stringify(r.body));

  r = await api('POST', '/api/auth/register', { body: { username: 'pda001', password: 'pda001', nickname: '盘点员小张' } });
  const staff = r.body?.token;
  ok('普通员工注册（盘点员）', !!staff, JSON.stringify(r.body));

  // ============================================================
  console.log('\n【一】门禁');
  r = await api('GET', '/api/stocktake/zones');
  ok('未登录 → 401', r.status === 401, String(r.status));
  r = await api('POST', '/api/stocktake/zone', { body: { zone_code: 'Z01' } });
  ok('未登录建点位 → 401', r.status === 401, String(r.status));

  // ============================================================
  console.log('\n【二】点位与库位');
  r = await api('POST', '/api/stocktake/zone', { token: staff, body: { zone_code: 'Z01', zone_name: '生鲜区', store_code: 'S001' } });
  ok('员工能建点位（盘点员就该能干）', r.status === 200 && r.body.zone.zone_code === 'Z01', JSON.stringify(r.body));
  ok('  新建的点位未锁定', r.body?.zone?.locked === false);

  r = await api('POST', '/api/stocktake/zone', { token: staff, body: { zone_code: 'Z/01' } });
  ok('点位码含斜杠 → 400（带斜杠会把导出文件名当目录）', r.status === 400, String(r.status));

  r = await api('POST', '/api/stocktake/location', { token: staff, body: { loc_code: 'Z02-A01', zone_code: 'Z02' } });
  ok('库位挂到不存在的点位 → 404（不静默建孤儿库位）', r.status === 404, String(r.status));

  r = await api('POST', '/api/stocktake/location', { token: staff, body: { loc_code: 'Z01-A01', loc_name: 'A01 货架', zone_code: 'Z01', sort_no: 1 } });
  ok('建库位', r.status === 200 && r.body.location.loc_code === 'Z01-A01', JSON.stringify(r.body));

  r = await api('GET', '/api/stocktake/locations?zone=Z01', { token: staff });
  ok('库位列表按点位过滤', r.status === 200 && r.body.items.length === 1, JSON.stringify(r.body));

  r = await api('GET', '/api/stocktake/zones', { token: staff });
  const z01 = (r.body?.items || []).find((z) => z.zone_code === 'Z01');
  ok('点位列表带库位数', z01 && z01.loc_count === 1, JSON.stringify(r.body));

  r = await api('POST', '/api/stocktake/zone/Z01/lock', { token: staff, body: { locked: true } });
  ok('锁定点位', r.status === 200 && r.body.zone.locked === true, JSON.stringify(r.body));
  r = await api('POST', '/api/stocktake/sheet', { token: staff, body: { zone_code: 'Z01', phase: 1 } });
  ok('锁定点位开单 → 409 zone_locked', r.status === 409 && r.body.code === 'zone_locked', JSON.stringify(r.body));
  await api('POST', '/api/stocktake/zone/Z01/lock', { token: staff, body: { locked: false } });

  // ============================================================
  console.log('\n【三】商品 ↔ 货架位绑定');
  r = await api('POST', '/api/location/bind', { token: staff, body: { barcode: '6901111111111', loc_code: 'Z01-A01' } });
  ok('绑定商品到货架位', r.status === 200 && r.body.applied === 1, JSON.stringify(r.body));

  r = await api('GET', '/api/location/by-barcode/6901111111111', { token: staff });
  ok('反查：能查到货架位', r.status === 200 && r.body.locations.length === 1, JSON.stringify(r.body));
  ok('  且能推出所属盘点位', r.body?.zones?.includes('Z01'), JSON.stringify(r.body.zones));

  r = await api('GET', '/api/location/by-barcode/0000000000000', { token: staff });
  ok('没绑过的条码：locations 与 zones 都为空（不是"不属于任何点位"）',
    r.status === 200 && r.body.locations.length === 0 && r.body.zones.length === 0, JSON.stringify(r.body));

  r = await api('POST', '/api/location/bind', { token: staff, body: { barcode: '6901111111111', loc_code: 'Z01-NOPE' } });
  ok('绑到不存在的货架位 → 进 rejected，不算成功', r.status === 200 && r.body.applied === 0 && r.body.rejected.length === 1, JSON.stringify(r.body));

  r = await api('POST', '/api/location/bind', { token: staff, body: { barcode: '6901111111111', loc_code: 'Z01-A01' } });
  ok('重复绑定幂等（不报错、不多一行）', r.status === 200, JSON.stringify(r.body));
  r = await api('GET', '/api/location/by-barcode/6901111111111', { token: staff });
  ok('  反查仍只有 1 条', r.body.locations.length === 1, JSON.stringify(r.body));

  // ============================================================
  console.log('\n【四】上传与幂等（点位 Z01）');
  const S1 = 'INV-Z01-1-20260919100000';
  const rows1 = [
    { barcode: '6901111111111', qty: 12, account_qty: 10, loc_code: 'Z01-A01', scanned_at: 1758000000000 },
    { barcode: '6902222222222', qty: 10, account_qty: 10, loc_code: 'Z01-A01' },
    { barcode: '6903333333333', qty: 1, account_qty: null, loc_code: null },   // 账上没有这个商品
  ];
  r = await api('POST', `/api/stocktake/sheet/${S1}/upload`, { token: staff, body: uploadBody('Z01', 1, rows1, { device_id: 'pda-01' }) });
  ok('上传 3 行全部接收', r.status === 200 && r.body.accepted === 3, JSON.stringify(r.body));
  ok('  差异 2 条（12≠10 与"账上没有"）', r.body?.summary?.diff === 2, JSON.stringify(r.body?.summary));
  ok('  上传即归档：status=2', r.body?.sheet?.status === 2, JSON.stringify(r.body?.sheet));

  r = await api('GET', `/api/stocktake/sheet/${S1}`, { token: staff });
  ok('单据详情：明细 3 行', r.status === 200 && r.body.rows.length === 3, JSON.stringify(r.body?.summary));
  ok('  差异集 2 行', r.body?.diff_rows?.length === 2, JSON.stringify(r.body?.diff_rows));
  ok('  🔴 "账上没有"的条码在差异集里（SQL 的 NULL 陷阱）',
    (r.body?.diff_rows || []).some((x) => x.barcode === '6903333333333'), JSON.stringify(r.body?.diff_rows));
  ok('  summary.unknown 计到 1 条', r.body?.summary?.unknown === 1, JSON.stringify(r.body?.summary));
  ok('  未绑货架位的行计到 1 条', r.body?.summary?.unbound === 1, JSON.stringify(r.body?.summary));

  // 重传同一批：必须还是 3 行
  r = await api('POST', `/api/stocktake/sheet/${S1}/upload`, { token: staff, body: uploadBody('Z01', 1, rows1, { force: 1 }) });
  ok('强制重传同一批：成功', r.status === 200, JSON.stringify(r.body));
  r = await api('GET', `/api/stocktake/sheet/${S1}`, { token: staff });
  ok('🔴 重传后仍是 3 行 —— 幂等键生效，没有变成 6 行',
    r.body.rows.length === 3, `实际 ${r.body.rows.length} 行`);

  // 重传改数量：UPSERT 覆盖
  const rows1b = rows1.map((x) => (x.barcode === '6901111111111' ? { ...x, qty: 15 } : x));
  await api('POST', `/api/stocktake/sheet/${S1}/upload`, { token: staff, body: uploadBody('Z01', 1, rows1b, { force: 1 }) });
  r = await api('GET', `/api/stocktake/sheet/${S1}`, { token: staff });
  const row6901 = r.body.rows.find((x) => x.barcode === '6901111111111');
  ok('重传改数量 → 覆盖而不是新增', r.body.rows.length === 3 && Number(row6901.qty) === 15,
    JSON.stringify({ n: r.body.rows.length, qty: row6901 && row6901.qty }));

  // 覆盖保护：不传 force 必须 409
  const S1b = 'INV-Z01-1-20260919110000';
  await api('POST', `/api/stocktake/sheet/${S1b}/upload`, { token: staff, body: uploadBody('Z01', 1, [rows1[1]]) });
  r = await api('POST', `/api/stocktake/sheet/${S1b}/upload`, { token: staff, body: uploadBody('Z01', 1, [rows1[1]]) });
  ok('🔴 已归档的单再上传、不传 force → 409 already_uploaded',
    r.status === 409 && r.body.code === 'already_uploaded', JSON.stringify(r.body));
  r = await api('POST', `/api/stocktake/sheet/${S1b}/upload`, { token: staff, body: uploadBody('Z01', 1, [rows1[1]], { force: 1 }) });
  ok('  传 force=1 才允许覆盖', r.status === 200, JSON.stringify(r.body));

  // 坏行：数量 0 / 条码空
  r = await api('POST', '/api/stocktake/sheet/INV-Z01-1-20260919120000/upload', {
    token: staff,
    body: uploadBody('Z01', 1, [{ barcode: '6909', qty: 0 }, { barcode: '', qty: 3 }, { barcode: '6910', qty: 2 }]),
  });
  ok('坏行被挑出来、好行照收', r.status === 200 && r.body.accepted === 1 && r.body.rejected.length === 2, JSON.stringify(r.body));

  // 缺 zone_code：用一个全新的单号，别撞上"已归档"那道保护（那样测的是另一条规则）
  r = await api('POST', '/api/stocktake/sheet/INV-ZXX-1-20260919190000/upload', { token: staff, body: { phase: 1, rows: [{ barcode: '1', qty: 1 }] } });
  ok('上传缺 zone_code → 400', r.status === 400, String(r.status));

  // ============================================================
  console.log('\n【五】复盘的服务端差异集校验（点位 Z20）');
  await api('POST', '/api/stocktake/sheet/INV-Z20-1-20260919100000/upload', {
    token: staff,
    body: uploadBody('Z20', 1, [
      { barcode: '6901111111111', qty: 12, account_qty: 10 },  // 12≠10 → 差异
      { barcode: '6902222222222', qty: 10, account_qty: 10 },  // 10=10 → 无差异
    ]),
  });
  r = await api('POST', '/api/stocktake/sheet/INV-Z20-2-20260919130000/upload', {
    token: staff, body: uploadBody('Z20', 2, [{ barcode: '6902222222222', qty: 9 }]),
  });
  ok('🔴 复盘上报"非差异商品" → 400 not_in_diff_set',
    r.status === 400 && r.body.code === 'not_in_diff_set', JSON.stringify(r.body));
  ok('  回包里点名是哪个条码', (r.body?.barcodes || []).includes('6902222222222'), JSON.stringify(r.body?.barcodes));

  r = await api('POST', '/api/stocktake/sheet/INV-Z20-2-20260919130000/upload', {
    token: staff, body: uploadBody('Z20', 2, [{ barcode: '6901111111111', qty: 15 }]),
  });
  ok('复盘上报差异商品 → 通过，且标 diff_checked:true',
    r.status === 200 && r.body.diff_checked === true, JSON.stringify(r.body));

  // 边界：服务端还没有初盘数据的点位 → 不硬校
  r = await api('POST', '/api/stocktake/sheet/INV-Z09-2-20260919140000/upload', {
    token: staff, body: uploadBody('Z09', 2, [{ barcode: '6909999999999', qty: 3 }]),
  });
  ok('🔴 服务端还没有初盘数据时不硬校（整场断网跑完再一起传的场景），标 diff_checked:false',
    r.status === 200 && r.body.diff_checked === false, JSON.stringify(r.body));

  // ============================================================
  console.log('\n【六】阶段小结与失误笔数（点位 Z10）');
  await api('POST', '/api/stocktake/sheet/INV-Z10-1-20260919100000/upload', {
    token: staff,
    body: uploadBody('Z10', 1, [
      { barcode: '6901111111111', qty: 12, account_qty: 10 },  // 差异
      { barcode: '6902222222222', qty: 10, account_qty: 10 },  // 无差异
      { barcode: '6903333333333', qty: 1, account_qty: null }, // 账上没有 → 差异
    ]),
  });
  r = await api('GET', '/api/stocktake/zone/Z10', { token: staff });
  let p1 = r.body.phases.find((x) => x.phase === 1);
  ok('点位详情返回三个阶段', r.status === 200 && r.body.phases.length === 3, JSON.stringify(r.body?.phases));
  ok('初盘：3 个品种、差异 2、失误 0', p1.kinds === 3 && p1.diff === 2 && p1.mistakes === 0, JSON.stringify(p1));

  await api('POST', '/api/stocktake/sheet/INV-Z10-2-20260919130000/upload', {
    token: staff, body: uploadBody('Z10', 2, [{ barcode: '6901111111111', qty: 15 }]),
  });
  r = await api('GET', '/api/stocktake/zone/Z10', { token: staff });
  p1 = r.body.phases.find((x) => x.phase === 1);
  const p2 = r.body.phases.find((x) => x.phase === 2);
  const p3 = r.body.phases.find((x) => x.phase === 3);
  ok('复盘：1 个品种、差异 1', p2.kinds === 1 && p2.diff === 1, JSON.stringify(p2));
  ok('🔴 复盘失误笔数 = 1（6901 初盘 12 → 复盘 15；没复核的两条不算）',
    p2.mistakes === 1, JSON.stringify(p2));
  ok('初盘失误 0（没有上一阶段）', p1.mistakes === 0, String(p1.mistakes));
  ok('抽盘还没开 → 状态 -1', p3.status === -1, JSON.stringify(p3));

  // 复盘数量与初盘一致时不算失误（反向断言：不能把"复核过"记成失误）
  const S10c = 'INV-Z10-3-20260919140000';
  await api('POST', `/api/stocktake/sheet/${S10c}/upload`, {
    token: staff, body: uploadBody('Z10', 3, [
      { barcode: '6901111111111', qty: 15, account_qty: 10 },  // 与复盘 15 相同 → 不算失误
      { barcode: '6902222222222', qty: 10, account_qty: 10 },  // 复盘没盘过 → 也不算失误
    ]),
  });
  r = await api('GET', '/api/stocktake/zone/Z10', { token: staff });
  const p3b = r.body.phases.find((x) => x.phase === 3);
  ok('抽盘可上报非差异商品（抽盘不限差异集）', p3b.kinds === 2, JSON.stringify(p3b));
  ok('🔴 抽盘复核没改数 → 失误 0（"复核过"不等于"失误"）',
    p3b.mistakes === 0, JSON.stringify(p3b));

  // 真改一个数 → 失误才该 +1
  await api('POST', `/api/stocktake/sheet/${S10c}/upload`, {
    token: staff, body: uploadBody('Z10', 3, [
      { barcode: '6901111111111', qty: 13, account_qty: 10 },  // 复盘 15 → 抽盘 13
      { barcode: '6902222222222', qty: 10, account_qty: 10 },
    ], { force: 1 }),
  });
  r = await api('GET', '/api/stocktake/zone/Z10', { token: staff });
  const p3c = r.body.phases.find((x) => x.phase === 3);
  ok('🔴 抽盘改了数量 → 失误 1', p3c.mistakes === 1, JSON.stringify(p3c));

  // ============================================================
  console.log('\n【七】提交 / 撤销');
  const S4 = 'INV-Z01-1-20260919170000';
  await api('POST', '/api/stocktake/sheet', { token: staff, body: { zone_code: 'Z01', phase: 1, sheet_no: S4 } });
  r = await api('POST', '/api/stocktake/sheet/INV-Z01-1-20260919180000/submit', { token: staff });
  ok('提交不存在的单 → 404', r.status === 404, String(r.status));

  r = await api('POST', `/api/stocktake/sheet/${S1}/submit`, { token: staff });
  ok('已归档的单提交 → 409（不能再改）', r.status === 409 && r.body.code === 'already_uploaded', JSON.stringify(r.body));

  r = await api('POST', `/api/stocktake/sheet/${S4}/submit`, { token: staff });
  ok('提交进行中的单 → status=1', r.status === 200 && r.body.sheet.status === 1, JSON.stringify(r.body));
  r = await api('POST', `/api/stocktake/sheet/${S4}/submit`, { token: staff });
  ok('  重复提交幂等（already=true）', r.status === 200 && r.body.already === true, JSON.stringify(r.body));
  r = await api('POST', `/api/stocktake/sheet/${S4}/reopen`, { token: staff });
  ok('普通员工撤销提交 → 403（管理员动作）', r.status === 403, String(r.status));
  r = await api('POST', `/api/stocktake/sheet/${S4}/reopen`, { token: admin });
  ok('管理员撤销提交 → status 回到 0', r.status === 200 && r.body.sheet.status === 0, JSON.stringify(r.body));

  r = await api('POST', `/api/stocktake/sheet/${S4}/submit`, { token: staff });
  ok('  （已撤销的单可以再提交）', r.status === 200 && r.body.sheet.status === 1, JSON.stringify(r.body));

  r = await api('POST', '/api/stocktake/sheet', { token: staff, body: { zone_code: 'Z01', phase: 4 } });
  ok('非法阶段 → 400', r.status === 400, String(r.status));

  r = await api('POST', '/api/stocktake/sheet', { token: staff, body: { zone_code: 'Z01', phase: 1, sheet_no: S1 } });
  ok('🔴 拿别人（已归档）的单号开单 → 409，绝不把旧单当成本次结果返回',
    r.status === 409 && r.body.code === 'sheet_no_taken', JSON.stringify(r.body));

  // ============================================================
  console.log('\n【八】单据列表分页');
  r = await api('GET', '/api/stocktake/sheets?page=1&pageSize=2&allTime=1', { token: staff });
  ok('分页返回 {items,total,page,pageSize}', r.status === 200 && Array.isArray(r.body.items) && typeof r.body.total === 'number',
    JSON.stringify({ status: r.status, keys: r.body && Object.keys(r.body) }));
  ok('  总单数 >= 5', r.body.total >= 5, String(r.body.total));
  ok('  pageSize 生效（最多 2 条）', r.body.items.length <= 2, String(r.body.items.length));
  r = await api('GET', '/api/stocktake/sheets?zone=Z20&phase=2&allTime=1', { token: staff });
  ok('按点位+阶段筛选（且不是空集假通过）',
    r.body.items.length >= 1 && r.body.items.every((x) => x.zone_code === 'Z20' && x.phase === 2),
    JSON.stringify(r.body.items));
  r = await api('GET', '/api/stocktake/sheets?from=999&to=1', { token: staff });
  ok('from 晚于 to → 400（矛盾条件不悄悄替用户改）', r.status === 400, String(r.status));

  // ============================================================
  console.log('\n【九】同步拉取');
  r = await api('GET', '/api/stocktake/pull', { token: staff });
  ok('pull 返回点位/库位/绑定三份', r.status === 200 && Array.isArray(r.body.zones) && Array.isArray(r.body.locations) && Array.isArray(r.body.bindings),
    JSON.stringify(r.body && Object.keys(r.body)));
  ok('  含 Z01 点位', r.body.zones.some((z) => z.zone_code === 'Z01'));
  ok('  含绑定记录', r.body.bindings.length >= 1, String(r.body.bindings.length));
  r = await api('GET', `/api/stocktake/pull?since=${Date.now()}`, { token: staff });
  ok('since=现在 → 三份都空（增量口径对）',
    r.body.zones.length === 0 && r.body.locations.length === 0 && r.body.bindings.length === 0, JSON.stringify(r.body));

  // ============================================================
  console.log('\n【十】删点位（级联 + 权限）');
  r = await api('DELETE', '/api/stocktake/zone/Z01', { token: staff });
  ok('普通员工删点位 → 403', r.status === 403, String(r.status));
  r = await api('DELETE', '/api/stocktake/zone/Z09', { token: admin });
  ok('管理员删点位 → 级联计数', r.status === 200 && r.body.deleted.sheet >= 1 && r.body.deleted.scan >= 1, JSON.stringify(r.body));
  r = await api('GET', '/api/stocktake/zone/Z09', { token: admin });
  ok('  删完查不到', r.status === 404, String(r.status));

  await api('POST', '/api/stocktake/location', { token: admin, body: { loc_code: 'Z20-A01', zone_code: 'Z20' } });
  await api('POST', '/api/location/bind', { token: admin, body: { barcode: '6901111111111', loc_code: 'Z20-A01' } });
  r = await api('DELETE', '/api/stocktake/location/Z20-A01', { token: admin });
  ok('删库位同时解绑', r.status === 200 && r.body.deleted.location === 1 && r.body.deleted.barcode_location === 1, JSON.stringify(r.body));

  r = await api('DELETE', '/api/stocktake/zone/Z20', { token: admin });
  ok('删点位带库位/绑定/单据/明细的级联计数', r.status === 200 && r.body.deleted.sheet >= 2, JSON.stringify(r.body));

  // ============================================================
  console.log(`\n[inventory E2E] 通过 ${passed} / 失败 ${failed}`);
  if (failed) {
    console.log('\n失败清单：');
    for (const f of failures) console.log('  · ' + f);
  }
  stopServer();
  process.exit(failed ? 1 : 0);
})().catch((e) => {
  console.error('测试崩溃：', e);
  try { console.error(serverLog.slice(-3000)); } catch { /* ignore */ }
  stopServer();
  process.exit(1);
});
