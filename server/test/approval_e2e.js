// 通用审批中心（M2/P2）—— 端到端测试
//
//   node test/approval_e2e.js
//
// 覆盖：提交（含归属校验与 payload 上限）、待审唯一、按状态查我的、
// 待我审（can_approve）、批准、驳回（**理由必填**）、
// 重复落决定 409、自提自批 403、撤回、以及业务同步
// （盘点单的 approval_status / reject_reason 有没有真的写上去）。
//
// 【为什么这些断言不是"随手写的"】
// 每条都对应一个会让审批变成摆设的坏情况：
//   · 已批的再点一次若"顺手"成功 → 结论取决于谁最后点，事后说不清；
//   · 驳回不填理由也放过 → 提交人只能反复猜、反复提，审批退化成刁难；
//   · 自提自批不拦 → 等于没有审批；
//   · 落决定不同步业务表 → 列表页显示"待审"、详情页显示"已批"，两套事实。
// 所以这些数字/状态码变了，是规则坏了，要回去改代码而不是改测试。

const { spawn } = require('child_process');
const path = require('path');
const fs = require('fs');
const os = require('os');

const PORT = 3713;
const BASE = `http://127.0.0.1:${PORT}`;
const SERVER_DIR = path.resolve(__dirname, '..');
const DATA_DIR = path.join(os.tmpdir(), 'xiaozhi-appr-e2e-' + Date.now());

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

/** 开一张盘点单（顺带把点位建出来）。 */
async function makeSheet(token, zone, phase = 1) {
  const r = await api('POST', '/api/stocktake/sheet', {
    token,
    body: { zone_code: zone, phase, zone: { zone_code: zone, zone_name: zone + '区' } },
  });
  return r.body && r.body.sheet ? r.body.sheet.sheet_no : null;
}

/** 读盘点单详情（拿 approval_status / reject_reason）。 */
async function readSheet(token, no) {
  const r = await api('GET', `/api/stocktake/sheet/${no}`, { token });
  return r.body && r.body.sheet ? r.body.sheet : null;
}

(async () => {
  await startServer();
  console.log('[approval E2E] 服务端已就绪 ' + BASE + '\n');

  let r = await api('POST', '/api/auth/login', { body: { username: 'admin', password: 'TestAdmin_123' } });
  const admin = r.body?.token;
  ok('管理员登录', !!admin, JSON.stringify(r.body));
  const adminId = r.body?.user?.id;

  r = await api('POST', '/api/auth/register', { body: { username: 'pda001', password: 'pda001', nickname: '盘点员小张' } });
  const staff = r.body?.token;
  const staffId = r.body?.user?.id;
  ok('普通员工注册（提交人）', !!staff, JSON.stringify(r.body));

  r = await api('POST', '/api/auth/register', { body: { username: 'pda009', password: 'pda009', nickname: '无关同事' } });
  const outsider = r.body?.token;
  ok('注册一个无关同事（看别人的审批用）', !!outsider, JSON.stringify(r.body));

  // ============================================================
  console.log('\n【一】门禁与提交');
  r = await api('POST', '/api/approval/submit', { body: { kind: 'stocktake' } });
  ok('未登录提交 → 401', r.status === 401, String(r.status));

  const S1 = await makeSheet(staff, 'ZA1');
  ok('  前置：开出一张盘点单', !!S1, String(S1));

  r = await api('POST', '/api/approval/submit', {
    token: staff, body: { kind: 'stocktake', ref: S1, title: 'ZA1 初盘复核' },
  });
  const appr1 = r.body?.approval?.id;
  ok('提交盘点单审批 → pending', r.status === 200 && r.body.approval.status === 'pending', JSON.stringify(r.body));
  ok('  记下了提交人（谁提的以后要能查）',
    r.body.approval.submitter_id === staffId && r.body.approval.submitter_name === '盘点员小张',
    JSON.stringify({ id: r.body.approval.submitter_id, me: staffId }));

  r = await readSheet(staff, S1);
  ok('🔴 提交后单据的 approval_status 变 1（待审）——列表页据此显示，不必再 join',
    r && r.approval_status === 1, JSON.stringify(r));

  r = await api('POST', '/api/approval/submit', {
    token: staff, body: { kind: 'stocktake', ref: S1 },
  });
  ok('🔴 同一对象重复提交 → 409 already_pending（否则批了一条另一条还挂着）',
    r.status === 409 && r.body.code === 'already_pending', JSON.stringify(r.body));

  r = await api('POST', '/api/approval/submit', {
    token: staff, body: { kind: '不存在的业务', ref: 'X' },
  });
  ok('未知审批类型 → 400（不认的业务不存，免得变僵尸单）', r.status === 400, JSON.stringify(r.body));

  r = await api('POST', '/api/approval/submit', {
    token: staff, body: { kind: 'stocktake', ref: 'INV-不存在-1-20260101000000' },
  });
  ok('ref 指向不存在的单据 → 404', r.status === 404, JSON.stringify(r.body));

  r = await api('POST', '/api/approval/submit', { token: staff, body: { kind: 'stocktake' } });
  ok('缺 ref → 400', r.status === 400, JSON.stringify(r.body));

  const S2 = await makeSheet(admin, 'ZA2');
  r = await api('POST', '/api/approval/submit', {
    token: staff, body: { kind: 'stocktake', ref: S2 },
  });
  ok('🔴 提别人的单 → 403（只能提自己的）', r.status === 403, JSON.stringify(r.body));

  // payload 上限
  r = await api('POST', '/api/approval/submit', {
    token: staff,
    body: { kind: 'stocktake', ref: await makeSheet(staff, 'ZA3'), payload: { big: 'x'.repeat(30000) } },
  });
  ok('payload 过大 → 400（别让一张单把库撑爆）', r.status === 400, JSON.stringify(r.body));

  // ============================================================
  console.log('\n【二】查');
  r = await api('GET', '/api/approval/mine?status=pending', { token: staff });
  ok('mine?status=pending 拿到自己那条',
    r.status === 200 && r.body.items.some((x) => x.id === appr1), JSON.stringify(r.body.items?.map((x) => x.id)));
  r = await api('GET', '/api/approval/mine?status=approved', { token: staff });
  ok('  status=approved 此时为空（筛选真的生效，不是返回全部）',
    r.body.items.length === 0, String(r.body.items?.length));
  r = await api('GET', '/api/approval/mine?status=乱填', { token: staff });
  ok('  非法 status → 400（不静默当成"全部"）', r.status === 400, String(r.status));
  r = await api('GET', '/api/approval/mine', { token: outsider });
  ok('  别人的 mine 里没有这条', r.body.items.length === 0, String(r.body.items?.length));

  r = await api('GET', '/api/approval/pending', { token: staff });
  ok('🔴 普通员工的 pending 列表带回 can_approve=false（界面据此不显示按钮）',
    r.status === 200 && r.body.can_approve === false, JSON.stringify({ can: r.body?.can_approve }));
  r = await api('GET', '/api/approval/pending', { token: admin });
  ok('管理员 can_approve=true 且能看到待审',
    r.body.can_approve === true && r.body.items.some((x) => x.id === appr1),
    JSON.stringify({ can: r.body?.can_approve, ids: r.body?.items?.map((x) => x.id) }));

  r = await api('GET', `/api/approval/${appr1}`, { token: outsider });
  ok('🔴 无关同事看别人的审批详情 → 403', r.status === 403, String(r.status));

  // ============================================================
  console.log('\n【三】批准');
  r = await api('POST', `/api/approval/${appr1}/approve`, { token: staff });
  ok('普通员工批准 → 403（只有管理员能审）', r.status === 403, String(r.status));

  r = await api('POST', `/api/approval/${appr1}/approve`, { token: admin });
  ok('管理员批准 → approved', r.status === 200 && r.body.approval.status === 'approved', JSON.stringify(r.body));
  ok('  记下了审批人与时间',
    r.body.approval.decided_by === adminId && r.body.approval.decided_at > 0, JSON.stringify(r.body.approval));

  r = await readSheet(admin, S1);
  ok('🔴 批准后单据 approval_status 变 2', r && r.approval_status === 2, JSON.stringify(r));

  r = await api('POST', `/api/approval/${appr1}/approve`, { token: admin });
  ok('🔴 重复批准 → 409 already_decided（"最后点的算"会让结论取决于手速）',
    r.status === 409 && r.body.code === 'already_decided', JSON.stringify(r.body));
  r = await api('POST', `/api/approval/${appr1}/reject`, { token: admin, body: { reason: '想反悔' } });
  ok('🔴 批过之后不能再驳回 → 409', r.status === 409 && r.body.code === 'already_decided', JSON.stringify(r.body));

  // ============================================================
  console.log('\n【四】驳回');
  const S4 = await makeSheet(staff, 'ZA4');
  r = await api('POST', '/api/approval/submit', { token: staff, body: { kind: 'stocktake', ref: S4 } });
  const appr4 = r.body?.approval?.id;
  ok('  前置：提交第二条审批', !!appr4, JSON.stringify(r.body));

  r = await api('POST', `/api/approval/${appr4}/reject`, { token: admin, body: {} });
  ok('🔴 驳回不带理由 → 400 reason_required（文案是给现场看的那句）',
    r.status === 400 && r.body.code === 'reason_required', JSON.stringify(r.body));
  r = await api('POST', `/api/approval/${appr4}/reject`, { token: admin, body: { reason: '   ' } });
  ok('  只填空格也算没填（不能被空白绕过）', r.status === 400, JSON.stringify(r.body));

  r = await api('POST', `/api/approval/${appr4}/reject`, { token: admin, body: { reason: '6903 的数量与复盘对不上，请重盘' } });
  ok('带理由驳回 → rejected', r.status === 200 && r.body.approval.status === 'rejected', JSON.stringify(r.body));

  r = await readSheet(admin, S4);
  ok('🔴 驳回后单据 approval_status 变 3，且理由落到单据上（现场不用去翻审批表）',
    r && r.approval_status === 3 && /对不上/.test(r.reject_reason || ''), JSON.stringify(r));

  r = await api('GET', '/api/approval/mine?status=rejected', { token: staff });
  ok('提交人能在"已驳回"里看到它和理由',
    r.body.items.some((x) => x.id === appr4 && /对不上/.test(x.reject_reason || '')),
    JSON.stringify(r.body.items));

  r = await api('POST', `/api/approval/${appr4}/approve`, { token: admin });
  ok('驳回后不能再批 → 409', r.status === 409, String(r.status));

  // 驳回之后可以重新提（同一对象不允许的是"两条待审"，不是"提过就不能再提"）
  r = await api('POST', '/api/approval/submit', {
    token: staff, body: { kind: 'stocktake', ref: S4, title: '重盘后重提' },
  });
  const appr4b = r.body?.approval?.id;
  ok('🔴 驳回后可以重新提交（改了数据就该能再提一次）', r.status === 200 && !!appr4b, JSON.stringify(r.body));
  r = await readSheet(admin, S4);
  ok('  重提后单据回到"待审"，旧的驳回理由清掉（否则界面还挂着上一条驳回的话）',
    r && r.approval_status === 1 && r.reject_reason === null, JSON.stringify(r));

  // ============================================================
  console.log('\n【五】撤回');
  r = await api('POST', `/api/approval/${appr4b}/withdraw`, { token: outsider });
  ok('无关同事撤回 → 403', r.status === 403, String(r.status));
  r = await api('POST', `/api/approval/${appr4b}/withdraw`, { token: staff });
  ok('提交人撤回待审的单 → ok', r.status === 200 && r.body.ok === true, JSON.stringify(r.body));
  r = await readSheet(admin, S4);
  ok('🔴 撤回后单据回到 approval_status=0（不是留在"待审"上）',
    r && r.approval_status === 0, JSON.stringify(r));
  r = await api('GET', `/api/approval/${appr4b}`, { token: staff });
  ok('  撤回后查不到（行被删了，不留幽灵待办）', r.status === 404, String(r.status));

  const S5 = await makeSheet(staff, 'ZA5');
  r = await api('POST', '/api/approval/submit', { token: staff, body: { kind: 'stocktake', ref: S5 } });
  const appr5 = r.body?.approval?.id;
  await api('POST', `/api/approval/${appr5}/approve`, { token: admin });
  r = await api('POST', `/api/approval/${appr5}/withdraw`, { token: staff });
  ok('🔴 已审完的撤不回来 → 409（否则"批过了又能删"，审批记录就没公信力了）',
    r.status === 409 && r.body.code === 'already_decided', JSON.stringify(r.body));

  // ============================================================
  console.log('\n【六】自提自批');
  // 管理员提自己的单，然后自己批 —— 必须被拦
  const S6 = await makeSheet(admin, 'ZA6');
  r = await api('POST', '/api/approval/submit', { token: admin, body: { kind: 'stocktake', ref: S6 } });
  const appr6 = r.body?.approval?.id;
  ok('  前置：管理员提自己的单', r.status === 200 && !!appr6, JSON.stringify(r.body));
  r = await api('POST', `/api/approval/${appr6}/approve`, { token: admin });
  ok('🔴 自己批自己的单 → 403 self_approve（自提自批等于没有审批）',
    r.status === 403 && r.body.code === 'self_approve', JSON.stringify(r.body));
  r = await api('POST', `/api/approval/${appr6}/reject`, { token: admin, body: { reason: '自己驳自己' } });
  ok('  自提自驳也拦（不然"驳回"能当撤回用，绕过撤回的状态检查）',
    r.status === 403 && r.body.code === 'self_approve', JSON.stringify(r.body));

  // ============================================================
  // 盘点单据列表按审批状态筛 —— "根据审批状态获取审批单据"
  console.log('\n【七】按审批状态筛单据');
  r = await api('GET', '/api/stocktake/sheets?zone=ZA4&allTime=1', { token: admin });
  ok('  前置：ZA4 有单', r.status === 200 && r.body.total >= 1, JSON.stringify({ total: r.body?.total }));
  r = await api('GET', '/api/stocktake/sheets?approval=1&allTime=1', { token: admin });
  ok('approval=1 筛出待审的单，且每一条都真的是待审',
    r.status === 200 && r.body.items.length >= 1 &&
      r.body.items.every((x) => x.approval_status === 1),
    JSON.stringify(r.body.items.map((x) => [x.sheet_no, x.approval_status])));
  r = await api('GET', '/api/stocktake/sheets?approval=9&allTime=1', { token: admin });
  ok('  非法 approval → 400（不静默返回全部）', r.status === 400, String(r.status));

  // ============================================================
  console.log(`\n[approval E2E] 通过 ${passed} / 失败 ${failed}`);
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
