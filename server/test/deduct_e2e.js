// 库房减货单接口（deduct 模块）—— 端到端测试
//
//   node test/deduct_e2e.js
//
// 覆盖：门禁、上传与幂等、覆盖保护、非法行被拒、**与盘点单不串**（这是共用
// inv_sheets 之后最大的风险）、列表/详情、按商品对账。
//
// 【几个数字为什么写成断言】
//   · 重传后行数必须不变（变 6 = 同一品种被算两遍，对账直接失真）；
//   · 已归档的单不传 force 必须 409（默认放行 = 减货结果可以事后随便改，
//     而"要对账"这个需求就是冲着"不能随便改"来的）；
//   · 减货单**不能**出现在盘点单列表里（它不挂点位、不看阶段，
//     混进去的结果是一张点位为空、阶段小结全 0 的"盘点单"）；
//   · 数量 0 和负数必须被拒（0 = 没减，负数在减货里没有业务含义）。
// 数字变了说明规则坏了，改代码不要改数字。
//
// 【为什么每个用例用独立的单号】
// 对账是**跨单据按条码聚合**的，往同一批单里反复灌会互相污染，
// 断言就得跟着改 —— 那就不是测试了。

const { spawn } = require('child_process');
const path = require('path');
const fs = require('fs');
const os = require('os');

const PORT = 3713;
const BASE = `http://127.0.0.1:${PORT}`;
const SERVER_DIR = path.resolve(__dirname, '..');
const DATA_DIR = path.join(os.tmpdir(), 'xiaozhi-deduct-e2e-' + Date.now());

let passed = 0;
let failed = 0;
const failures = [];

function ok(name, cond, extra) {
  if (cond) { passed++; console.log(`  ✓ ${name}`); }
  else {
    failed++;
    failures.push(name + (extra ? ` — ${extra}` : ''));
    console.log(`  ✗ ${name}${extra ? '  → ' + extra : ''}`);
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
  console.log('[deduct E2E] 服务端已就绪 ' + BASE + '\n');

  let r = await api('POST', '/api/auth/login', { body: { username: 'admin', password: 'TestAdmin_123' } });
  const admin = r.body?.token;
  ok('管理员登录', !!admin, JSON.stringify(r.body));

  r = await api('POST', '/api/auth/register', { body: { username: 'kf001', password: 'kf001', nickname: '库管老李' } });
  const staff = r.body?.token;
  ok('普通员工注册（库管）', !!staff, JSON.stringify(r.body));

  // ============================================================
  console.log('\n【一】门禁');
  r = await api('POST', '/api/deduct/sheet/JH-1/upload', { body: { rows: [] } });
  ok('未登录上传 → 401', r.status === 401, String(r.status));
  r = await api('GET', '/api/deduct/sheets');
  ok('未登录看列表 → 401', r.status === 401, String(r.status));
  r = await api('GET', '/api/deduct/reconcile');
  ok('未登录看对账 → 401', r.status === 401, String(r.status));

  // ============================================================
  console.log('\n【二】上传');
  const S1 = 'JH-20260101090000';
  r = await api('POST', `/api/deduct/sheet/${S1}/upload`, {
    token: staff,
    body: {
      rows: [
        { barcode: '6901234500017', qty: 3 },
        { barcode: '6901234500024', qty: 5 },
        { barcode: '6901234500031', qty: 2 },
      ],
      device_id: 'PDA-01',
    },
  });
  ok('上传成功', r.status === 200 && r.body.ok === true, JSON.stringify(r.body));
  ok('  accepted = 3', r.body?.accepted === 3, JSON.stringify(r.body?.accepted));
  ok('  rejected 为空', Array.isArray(r.body?.rejected) && r.body.rejected.length === 0, JSON.stringify(r.body?.rejected));
  ok('  summary.kinds = 3', r.body?.summary?.kinds === 3, JSON.stringify(r.body?.summary));
  ok('  summary.total_qty = 10', r.body?.summary?.total_qty === 10, JSON.stringify(r.body?.summary));
  ok('  上传即归档（status=2）', r.body?.sheet?.status === 2, JSON.stringify(r.body?.sheet));
  ok('  sheet_type = deduct', r.body?.sheet?.sheet_type === 'deduct', JSON.stringify(r.body?.sheet));
  ok('  记下了设备号（两台机器各传一半时能排查）', r.body?.sheet?.device_id === 'PDA-01', JSON.stringify(r.body?.sheet?.device_id));

  // ============================================================
  console.log('\n【三】幂等：重传不能变成两行');
  r = await api('POST', `/api/deduct/sheet/${S1}/upload`, {
    token: staff, body: { rows: [{ barcode: '6901234500017', qty: 3 }], force: 1 },
  });
  ok('force 重传 → 200', r.status === 200, String(r.status));
  r = await api('GET', `/api/deduct/sheet/${S1}`, { token: admin });
  ok('  明细仍是 3 行（不是 6 行）', r.body?.rows?.length === 3, JSON.stringify(r.body?.rows?.length));
  ok('  total_qty 仍是 10（同一品种没被算两遍）', r.body?.summary?.total_qty === 10, JSON.stringify(r.body?.summary));

  // ============================================================
  console.log('\n【四】覆盖保护');
  r = await api('POST', `/api/deduct/sheet/${S1}/upload`, {
    token: staff, body: { rows: [{ barcode: '6901234500017', qty: 99 }] },
  });
  // 客户端口径：409 当成功处理（它要的就是"数据在服务端"），但必须说清楚没覆盖
  ok('已上传的单不传 force → 409', r.status === 409, String(r.status));
  ok('  错误码是 already_uploaded（客户端靠它判定，不是靠文案）', r.body?.code === 'already_uploaded', JSON.stringify(r.body));
  r = await api('GET', `/api/deduct/sheet/${S1}`, { token: admin });
  const q1 = r.body?.rows?.find((x) => x.barcode === '6901234500017')?.qty;
  ok('  数量**没被改成 99**（默认不许覆盖）', q1 === 3, String(q1));

  r = await api('POST', `/api/deduct/sheet/${S1}/upload`, {
    token: staff, body: { rows: [{ barcode: '6901234500017', qty: 99 }], force: 1 },
  });
  ok('force=1 覆盖 → 200', r.status === 200, String(r.status));
  r = await api('GET', `/api/deduct/sheet/${S1}`, { token: admin });
  const q2 = r.body?.rows?.find((x) => x.barcode === '6901234500017')?.qty;
  ok('  显式覆盖后数量变成 99', q2 === 99, String(q2));

  // ============================================================
  console.log('\n【五】非法行被拒（且不牵连同批的合法行）');
  const S2 = 'JH-20260101100000';
  r = await api('POST', `/api/deduct/sheet/${S2}/upload`, {
    token: staff,
    body: {
      rows: [
        { barcode: '6901234500048', qty: 7 },   // 合法
        { barcode: '6901234500055', qty: 0 },   // 0 = 没减
        { barcode: '6901234500062', qty: -2 },  // 负数没业务含义
        { barcode: 'bad code', qty: 1 },        // 含空格
        { barcode: 'a/b', qty: 1 },             // 含斜杠（会把文件名当目录）
      ],
    },
  });
  ok('accepted = 1（只收下那一行合法的）', r.body?.accepted === 1, JSON.stringify(r.body?.accepted));
  ok('rejected = 4', r.body?.rejected?.length === 4, JSON.stringify(r.body?.rejected));
  const reasons = (r.body?.rejected || []).map((x) => x.reason);
  ok('  0 被拒的理由是"数量必须是正数"', reasons.filter((x) => x === '数量必须是正数').length === 2, JSON.stringify(reasons));
  ok('  非法条码被拒的理由是"条码不合法"', reasons.filter((x) => x === '条码不合法').length === 2, JSON.stringify(reasons));

  r = await api('POST', '/api/deduct/sheet/JH-x/upload', { token: staff, body: { rows: 'nope' } });
  ok('rows 不是数组 → 400', r.status === 400, String(r.status));

  // ============================================================
  console.log('\n【六】🔴 与盘点单不串（共用 inv_sheets 之后最大的风险）');
  // 先造一张真的盘点单
  r = await api('POST', '/api/stocktake/sheet/INV-ZD1-1-20260101110000/upload', {
    token: staff,
    body: { zone: { zone_code: 'ZD1', zone_name: '减货防串测试区' }, phase: 1, rows: [{ barcode: '6901234500079', qty: 4 }] },
  });
  ok('造一张盘点单成功', r.status === 200, JSON.stringify(r.body));

  r = await api('GET', '/api/stocktake/sheets', { token: admin });
  const invNos = (r.body?.items || []).map((s) => s.sheet_no);
  ok('盘点单列表里有那张盘点单', invNos.some((n) => String(n).startsWith('INV-')), JSON.stringify(invNos));
  ok('  🔴 盘点单列表里**没有**减货单', !invNos.some((n) => String(n).startsWith('JH-')), JSON.stringify(invNos));

  r = await api('GET', `/api/stocktake/sheet/${S1}`, { token: admin });
  ok('  🔴 拿减货单号去查盘点详情 → 404', r.status === 404, String(r.status));

  r = await api('POST', '/api/deduct/sheet/INV-ZD1-1-20260101110000/upload', {
    token: staff, body: { rows: [{ barcode: '6901234500017', qty: 1 }] },
  });
  ok('  🔴 拿盘点单号走减货上传 → 409', r.status === 409, String(r.status));
  ok('    错误码是 wrong_sheet_type', r.body?.code === 'wrong_sheet_type', JSON.stringify(r.body));

  r = await api('GET', '/api/deduct/sheets', { token: admin });
  const dedNos = (r.body?.items || []).map((s) => s.sheet_no);
  ok('减货列表里只有减货单', dedNos.length >= 2 && dedNos.every((n) => String(n).startsWith('JH-')), JSON.stringify(dedNos));

  // ============================================================
  console.log('\n【七】对账（跨单据按商品聚合 —— 这才是"要对账"真正要的表）');
  const S3 = 'JH-20260101120000';
  r = await api('POST', `/api/deduct/sheet/${S3}/upload`, {
    token: staff,
    body: { rows: [{ barcode: '6901234500017', qty: 6 }, { barcode: '6901234500024', qty: 1 }] },
  });
  ok('再传一张单（同一条码 6，另一个 1）', r.status === 200, String(r.status));

  r = await api('GET', '/api/deduct/reconcile', { token: admin });
  const byCode = Object.fromEntries((r.body?.items || []).map((x) => [x.barcode, x]));
  ok('对账表里有 6901234500017', !!byCode['6901234500017'], JSON.stringify(Object.keys(byCode)));
  // S1 覆盖后是 99，S3 是 6 → 105
  ok('  同一条码跨单累加 = 105（99 + 6）', byCode['6901234500017']?.total_qty === 105, JSON.stringify(byCode['6901234500017']));
  ok('  涉及单数 sheets_count = 2', byCode['6901234500017']?.sheets_count === 2, JSON.stringify(byCode['6901234500017']));
  ok('  6901234500024 = 6（5 + 1）', byCode['6901234500024']?.total_qty === 6, JSON.stringify(byCode['6901234500024']));
  ok('  盘点单的行**没有**混进对账', !byCode['6901234500079'], JSON.stringify(Object.keys(byCode)));
  ok('  总览有 sheets / rows_count / total_qty', r.body?.overall && typeof r.body.overall.total_qty === 'number', JSON.stringify(r.body?.overall));

  r = await api('GET', '/api/deduct/reconcile?q=6901234500017', { token: admin });
  ok('按条码搜 → 只剩 1 个品', (r.body?.items || []).length === 1, JSON.stringify((r.body?.items || []).length));

  console.log('\n【八】详情');
  r = await api('GET', `/api/deduct/sheet/${S3}`, { token: admin });
  ok('详情有 2 行', r.body?.rows?.length === 2, JSON.stringify(r.body?.rows?.length));
  ok('  明细带得上 sheet_type', r.body?.rows?.[0]?.sheet_type === 'deduct', JSON.stringify(r.body?.rows?.[0]));
  r = await api('GET', '/api/deduct/sheet/JH-nope', { token: admin });
  ok('不存在的减货单 → 404', r.status === 404, String(r.status));

  // ============================================================
  // 龙哥 2026-09-26 的质疑："库房减货不是盘点的一个流程吗？"
  // 正确的业务链是 **盘点 → 盘点完再拿货销售 → 账实对不上 → 用减货往下减**。
  // 所以减货的判据来自上一次盘点。这一段钉住"参照数"三条口径：
  //   ① 只读、不回写盘点；② 不强制先盘点（没盘过照样能减）；
  //   ③ 参照看的是盘点，"已减"看的是减货自己，两码事别混。
  console.log('\n【九】参照数（减货凭什么减这么多 —— 龙哥那条业务链的落点）');
  r = await api('GET', '/api/deduct/reference?barcode=6901234500079');
  ok('未登录查参照 → 401', r.status === 401, String(r.status));
  r = await api('GET', '/api/deduct/reference');
  ok('未登录 → 401（门禁在最前面）', r.status === 401, String(r.status));
  r = await api('GET', '/api/deduct/reference', { token: admin });
  ok('登录了但没带 barcode → 400', r.status === 400, String(r.status));
  r = await api('GET', '/api/deduct/reference?barcode=%20', { token: admin });
  ok('  只有空格也不合法 → 400', r.status === 400, String(r.status));
  r = await api('GET', '/api/deduct/reference?barcode=a%2Fb%3F', { token: admin });
  ok('  条码里带斜杠/问号也不合法 → 400', r.status === 400, String(r.status));

  // 先记下盘点单现在的样子，稍后比对 —— 参照接口**一个字都不许改它**
  const INV1 = 'INV-ZD1-1-20260101110000';
  const invBefore = await api('GET', `/api/stocktake/sheet/${INV1}`, { token: admin });

  // 6901234500079 在【六】的盘点单里盘到 4，之后没减过
  r = await api('GET', '/api/deduct/reference?barcode=6901234500079', { token: admin });
  ok('盘过的码 → countedQty = 4', r.body?.countedQty === 4, JSON.stringify(r.body));
  ok('  记着是哪一轮盘点（员工要能翻回去核对）', r.body?.countedSheet === INV1, JSON.stringify(r.body?.countedSheet));
  ok('  没减过 → deductedQty = 0', r.body?.deductedQty === 0, JSON.stringify(r.body?.deductedQty));
  ok('  剩 = 4 - 0 = 4', r.body?.remaining === 4, JSON.stringify(r.body?.remaining));
  ok('  hasRef = true', r.body?.hasRef === true, JSON.stringify(r.body?.hasRef));

  // 🔴 只读验证：查完参照，盘点单必须一个字节都没变
  const invAfter = await api('GET', `/api/stocktake/sheet/${INV1}`, { token: admin });
  ok('  🔴 查参照**没有回写盘点**（明细/合计原样）',
    JSON.stringify(invBefore.body?.rows) === JSON.stringify(invAfter.body?.rows)
    && invBefore.body?.summary?.total_qty === invAfter.body?.summary?.total_qty,
    `${JSON.stringify(invBefore.body?.summary)} → ${JSON.stringify(invAfter.body?.summary)}`);

  // 再盘一轮、时间更晚：取的是**最近一次**，不是第一盘
  const INV2 = 'INV-ZD1-2-20260101110000';
  r = await api('POST', `/api/stocktake/sheet/${INV2}/upload`, {
    token: staff,
    body: {
      zone: { zone_code: 'ZD1', zone_name: '减货防串测试区' },
      phase: 2,
      rows: [
        { barcode: '6901234500079', qty: 11, scanned_at: Date.now() + 120000 },
        { barcode: '6901234500024', qty: 9, account_qty: 12, scanned_at: Date.now() + 120000 },
      ],
    },
  });
  ok('再造一轮更晚的盘点（同一码 4 → 11）', r.status === 200, JSON.stringify(r.body));

  r = await api('GET', '/api/deduct/reference?barcode=6901234500079', { token: admin });
  ok('  🔴 取最近那一轮 = 11（不是第一盘的 4）', r.body?.countedQty === 11, JSON.stringify(r.body?.countedQty));
  ok('  指向的是第二轮那张单', r.body?.countedSheet === INV2, JSON.stringify(r.body?.countedSheet));

  // 6901234500024：盘到 9，减过 6（S1 的 5 + S3 的 1）→ 剩 3
  r = await api('GET', '/api/deduct/reference?barcode=6901234500024', { token: admin });
  ok('盘 9 又减了 6 → countedQty = 9', r.body?.countedQty === 9, JSON.stringify(r.body));
  ok('  deductedQty = 6（跨两张减货单累加）', r.body?.deductedQty === 6, JSON.stringify(r.body?.deductedQty));
  ok('  deductedSheets = 2', r.body?.deductedSheets === 2, JSON.stringify(r.body?.deductedSheets));
  ok('  🔴 剩 = 9 - 6 = 3', r.body?.remaining === 3, JSON.stringify(r.body?.remaining));
  ok('  带得出那轮盘点的账面数 12', r.body?.accountQty === 12, JSON.stringify(r.body?.accountQty));

  // 🔴 减货减得再多也不算"上一轮盘点"：6901234500017 在减货里被减了 105，
  //    但它从没盘过 —— 参照数必须是 null。混了的话，下一轮盘点的初盘
  //    数就会被"历史减货"污染，这个污染是找不回来的。
  r = await api('GET', '/api/deduct/reference?barcode=6901234500017', { token: admin });
  ok('  🔴 只减过、没盘过 → countedQty 是 null', r.body?.countedQty === null, JSON.stringify(r.body));
  ok('    但 deductedQty = 105（减货自己的账照给）', r.body?.deductedQty === 105, JSON.stringify(r.body?.deductedQty));
  ok('    remaining 是 null（没有盘点数可减，算"剩"没有意义）', r.body?.remaining === null, JSON.stringify(r.body?.remaining));
  ok('    hasRef 仍为 true（减货自己的账也算参照）', r.body?.hasRef === true, JSON.stringify(r.body?.hasRef));

  // 临时减货（没盘过、也没减过）不该被拦
  r = await api('GET', '/api/deduct/reference?barcode=6901234500999', { token: admin });
  ok('🔴 完全没盘过也没减过 → hasRef = false（不拦人，界面 hide 参照卡）',
    r.body?.hasRef === false, JSON.stringify(r.body));
  ok('  这种时候 countedQty / remaining 都是 null',
    r.body?.countedQty === null && r.body?.remaining === null, JSON.stringify(r.body));
  console.log(`\n[deduct E2E] 通过 ${passed} / 失败 ${failed}`);
  if (failures.length) { console.log('\n失败项：'); failures.forEach((f) => console.log('  - ' + f)); }
  stopServer();
  process.exit(failed ? 1 : 0);
})().catch((e) => { console.error(e); stopServer(); process.exit(1); });
