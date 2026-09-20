// 客户端「回传盘点单 / 提交审批」载荷 × 真服务端 —— 契约冒烟
//
//   node xiaozhi-im/probes/client_upload_contract.js
//
// ── 这个探针补的是哪条缝 ────────────────────────────────────────
// 两边各自都有测试：客户端 widget 测试钉住了"发出去的 JSON 长什么样"，
// 服务端 e2e 钉住了"这个接口收什么"。但**两份断言各说各话**也可能都对，
// 合起来却对不上（字段名差一个字母、account_qty 拼成 accountQty…）。
// 所以这里把客户端实际构造的那份 JSON **原样**打给真服务端，
// 看它是不是真的收下、真的归档、真的能接着提审。
//
// 判据不是"200 就算过"，而是：
//   · accepted 必须是 2（不是"服务端说 ok 但一行没落"）
//   · 库里真能查到这两行，且 account_qty / loc_code 真的存进去了
//   · bindings 真的把货架位绑上了（bound=1）
//   · 再传一次必须 409 already_uploaded（归档保护真的生效）
//   · 提审后 approvals 里真的有一条 pending，且 ref 是这张单
const { spawn } = require('child_process');
const path = require('path');
const fs = require('fs');
const os = require('os');

const PORT = 3713;
const BASE = `http://127.0.0.1:${PORT}`;
const SERVER_DIR = path.resolve(__dirname, '..', 'server');
const DATA_DIR = path.join(os.tmpdir(), 'xz-upload-contract-' + Date.now());

let passed = 0, failed = 0;
const failures = [];
function ok(name, cond, extra) {
  if (cond) { passed++; console.log(`  \u2713 ${name}`); }
  else { failed++; failures.push(name + (extra ? ` — ${extra}` : '')); console.log(`  \u2717 ${name}${extra ? '  → ' + extra : ''}`); }
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function api(method, p, { token, body } = {}) {
  const res = await fetch(BASE + p, {
    method,
    headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: 'Bearer ' + token } : {}) },
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
    env: { ...process.env, PORT: String(PORT), DATA_DIR, ADMIN_PASSWORD: 'ProbeAdmin_123' },
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

/**
 * 🔴 这份就是客户端 `InventoryRepo.uploadPayload()` 造出来的形状，
 *    逐字段照抄（见 client/test/inventory_upload_test.dart 的断言）。
 *    要改客户端载荷，先来改这里 —— 让探针跟着产物走，而不是跟着记忆走。
 */
function clientPayload(sheetNo) {
  return {
    phase: 1,
    zone: { zone_code: 'Z9', zone_name: '生鲜区', store_code: 'S001' },
    rows: [
      { barcode: '6901', qty: 1, account_qty: 10.0, loc_code: 'Z9-A01', scanned_at: 1758300000000 },
      { barcode: '6902', qty: 3, account_qty: null, scanned_at: 1758300001000 },
    ],
    bindings: [{ barcode: '6901', loc_code: 'Z9-A01' }],
  };
}

(async () => {
  await startServer();
  console.log('[载荷契约] 服务端已就绪 ' + BASE + '\n');

  let r = await api('POST', '/api/auth/login', { body: { username: 'admin', password: 'ProbeAdmin_123' } });
  const admin = r.body?.token;
  ok('管理员登录', !!admin, JSON.stringify(r.body));

  r = await api('POST', '/api/auth/register', { body: { username: 'pda900', password: 'pda900', nickname: '盘点员小张' } });
  const staff = r.body?.token;
  const staffId = r.body?.user?.id;
  ok('盘点员注册', !!staff, JSON.stringify(r.body));

  await api('POST', '/api/stocktake/zone', { token: staff, body: { zone_code: 'Z9', zone_name: '生鲜区', store_code: 'S001' } });
  r = await api('POST', '/api/stocktake/location', { token: staff, body: { loc_code: 'Z9-A01', loc_name: 'A01 货架', zone_code: 'Z9', sort_no: 1 } });
  ok('建点位与货架位', r.status === 200, JSON.stringify(r.body));

  // ============================================================
  // 【一】客户端载荷原样上传
  // ============================================================
  console.log('\n【一】客户端载荷原样上传');
  const SHEET = 'INV-Z9-1-20260920100000';
  const payload = clientPayload(SHEET);
  r = await api('POST', `/api/stocktake/sheet/${SHEET}/upload`, { token: staff, body: payload });
  ok('上传 200', r.status === 200, JSON.stringify(r.body).slice(0, 200));
  // 🔴 不是"200 就算过"：accepted 必须等于我发过去的行数
  ok('accepted == 发出的行数（2）', r.body?.accepted === 2, JSON.stringify(r.body));
  ok('rejected 为空', Array.isArray(r.body?.rejected) && r.body.rejected.length === 0, JSON.stringify(r.body?.rejected));
  ok('bindings 真的绑上了（bound=1）', r.body?.bound === 1, String(r.body?.bound));

  // 库里真能查到，且字段真的存进去了
  r = await api('GET', `/api/stocktake/sheet/${SHEET}`, { token: staff });
  const rows = r.body?.rows || [];
  ok('库里查到 2 行', rows.length === 2, JSON.stringify(rows));
  const r1 = rows.find((x) => x.barcode === '6901') || {};
  ok('account_qty 真的落库了（10）', Number(r1.account_qty) === 10, JSON.stringify(r1));
  ok('loc_code 真的落库了（Z9-A01）', r1.loc_code === 'Z9-A01', JSON.stringify(r1));
  ok('scanned_at 用的是我传的时刻（没被改成上传时刻）',
    Number(r1.scanned_at) === 1758300000000, String(r1.scanned_at));
  ok('单据变成已上传（status=2）', r.body?.sheet?.status === 2, JSON.stringify(r.body?.sheet));

  // 货架位绑定反查 —— 服务端**没有**"按条码查库位"的路由，所以放到【五】
  // 用"重传同一批绑定"来反证（见那里）。这里先不测，免得同一批初盘数据
  // 传两遍、把 6901 的量堆成 2，反而让 6901 变成"有差异"从而合法进清单。

  // ============================================================
  // 【二】重传 → 409，客户端据此归档本地
  // ============================================================
  console.log('\n【二】重传（弱网回执丢失的常态）');
  r = await api('POST', `/api/stocktake/sheet/${SHEET}/upload`, { token: staff, body: payload });
  ok('重传 → 409 already_uploaded', r.status === 409 && r.body?.code === 'already_uploaded', JSON.stringify(r.body));

  // ============================================================
  // 【三】提审 → 真有一条 pending，且 ref 是这张单
  // ============================================================
  console.log('\n【三】提交审批');
  r = await api('POST', '/api/approval/submit', {
    token: staff,
    body: {
      kind: 'stocktake',
      ref: SHEET,
      title: '生鲜区 · 初盘 · ' + SHEET,
      payload: { zone_code: 'Z9', zone_name: '生鲜区', phase: 1, kinds: 2, total_qty: 4, diff_kinds: 0 },
    },
  });
  ok('提审 200 且 pending', r.status === 200 && r.body?.approval?.status === 'pending', JSON.stringify(r.body).slice(0, 200));
  ok('ref 就是盘点单号', r.body?.approval?.ref === SHEET, JSON.stringify(r.body?.approval?.ref));

  r = await api('GET', '/api/approval/mine?status=pending', { token: staff });
  const mine = r.body?.items || [];
  ok('我的待审里能查到这一条', mine.some((a) => a.ref === SHEET), JSON.stringify(mine.map((a) => a.ref)));

  r = await api('POST', '/api/approval/submit', { token: staff, body: { kind: 'stocktake', ref: SHEET } });
  ok('重复提审 → 409 already_pending（客户端据此把文案转成"已提交审批"）',
    r.status === 409 && r.body?.code === 'already_pending', JSON.stringify(r.body));

  // ============================================================
  // 【四】抽盘无授权 → 后端拒（M2 验收那条：
  //        "无授权账号抽盘被后端拒"，而且拒在**上传**这一步）
  // ============================================================
  console.log('\n【四】抽盘准入（后端强制，不是藏按钮）');
  // 🔴 服务端只在**初盘和复盘都已有数据**时才校复核清单（整场断网跑完、
  //    最后一次性上传时它没有前两遍数据，硬校会把整批数据拒掉）。
  //    所以这里必须先把复盘也传上去，否则测的是"跳过校验"那条支路。
  r = await api('POST', '/api/stocktake/sheet/INV-Z9-2-20260920120000/upload', {
    token: staff,
    body: {
      phase: 2,
      zone: { zone_code: 'Z9', zone_name: '生鲜区' },
      rows: [{ barcode: '6901', qty: 1 }, { barcode: '6902', qty: 5 }],
    },
  });
  ok('复盘上传（6902 由 3 改成 5 → 进复核清单）', r.status === 200, JSON.stringify(r.body).slice(0, 160));

  r = await api('POST', '/api/stocktake/sheet/INV-Z9-3-20260920150000/upload', {
    token: staff,
    body: { phase: 3, zone: { zone_code: 'Z9', zone_name: '生鲜区' }, rows: [{ barcode: '6902', qty: 5 }] },
  });
  ok('未授权上传抽盘 → 403（拦在数据落地那一步）', r.status === 403, JSON.stringify(r.body));

  r = await api('POST', '/api/stocktake/zone/Z9/grant', { token: admin, body: { user_id: staffId } });
  ok('管理员授权', r.status === 200, JSON.stringify(r.body));

  r = await api('POST', '/api/stocktake/sheet/INV-Z9-3-20260920150000/upload', {
    token: staff,
    body: { phase: 3, zone: { zone_code: 'Z9', zone_name: '生鲜区' }, rows: [{ barcode: '6902', qty: 5 }] },
  });
  ok('授权后抽盘立刻可传（不是缓存没刷）', r.status === 200, JSON.stringify(r.body).slice(0, 200));
  ok('  这次真的校了复核清单（diff_checked=true）', r.body?.diff_checked === true, JSON.stringify(r.body));

  // 6901 初盘复盘都对得上（都是 1）⇒ 不在复核清单里
  r = await api('POST', '/api/stocktake/sheet/INV-Z9-3-20260920160000/upload', {
    token: staff,
    body: { phase: 3, zone: { zone_code: 'Z9', zone_name: '生鲜区' }, rows: [{ barcode: '6901', qty: 5 }] },
  });
  ok('清单外的商品 → 400 not_in_diff_set（客户端据此列出条码）',
    r.status === 400 && r.body?.code === 'not_in_diff_set', JSON.stringify(r.body));
  ok('  被拒的条码就是 6901', (r.body?.barcodes || []).includes('6901'), JSON.stringify(r.body?.barcodes));

  // ============================================================
  // 【五】货架位绑定的幂等（反证第一次真的落了库）
  // ============================================================
  //
  // 服务端**没有**"按条码查库位"的读取路由，所以换个法子证：
  // `inv_barcode_locations` 的写入是 `ON CONFLICT(barcode, loc_code) DO NOTHING`
  // 并回传 changes。第二次传同一批绑定必须是 0 —— 要是第一次压根没写进去，
  // 第二次照样会报 1（这就是这条断言能失败的地方）。
  //
  // 🔴 用**另一个点位**做：同一批初盘数据传两遍会把数量堆起来，
  //    让本来"两遍对得上"的商品变成"有差异"，把【四】的清单算歪。
  console.log('\n【五】货架位绑定幂等（独立点位，免得污染 Z9 的量）');
  await api('POST', '/api/stocktake/zone', { token: staff, body: { zone_code: 'Z8', zone_name: '日配区' } });
  await api('POST', '/api/stocktake/location', { token: staff, body: { loc_code: 'Z8-A01', zone_code: 'Z8' } });
  const bindBody = (sheet) => ({
    phase: 1,
    zone: { zone_code: 'Z8', zone_name: '日配区' },
    rows: [{ barcode: '6901', qty: 1, loc_code: 'Z8-A01' }],
    bindings: [{ barcode: '6901', loc_code: 'Z8-A01' }],
  });
  r = await api('POST', '/api/stocktake/sheet/Z8-1-A/upload', { token: staff, body: bindBody('Z8-1-A') });
  ok('首次绑定 → bound=1', r.body?.bound === 1, JSON.stringify({ status: r.status, bound: r.body?.bound }));
  r = await api('POST', '/api/stocktake/sheet/Z8-1-B/upload', { token: staff, body: bindBody('Z8-1-B') });
  ok('再传同一批绑定 → bound=0（幂等，反证第一次真落库了）',
    r.status === 200 && r.body?.bound === 0, JSON.stringify({ status: r.status, bound: r.body?.bound }));

  stopServer();
  console.log(`\n[载荷契约] 通过 ${passed} / 失败 ${failed}`);
  if (failures.length) { console.log('失败项：'); for (const f of failures) console.log('  ✗ ' + f); }
  process.exit(failed ? 1 : 0);
})().catch((e) => { console.error(e); stopServer(); process.exit(1); });
