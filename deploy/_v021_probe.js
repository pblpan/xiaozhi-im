// v0.21.0（应用中心「管理」）线上只读验收探针
//
//   IM_PASS=<管理台口令> node deploy/_v021_probe.js
//
// 【为什么单独写一个】
// e2e 跑在本地空库上，线上跑在**真库**上 —— 空库能撞巧通过。这个探针只做读，
// 不往生产库写任何东西，但要在真数据上确认这几件事：
//   ① 服务端版本真的换成 0.21.0（不是"文件推上去了但容器还是旧进程"）
//   ② 新接口在线上真的通，且**概览不是全 0**（全 0 往往意味着查询写错了表，
//      而空库上永远看不出来 —— 这正是 M3 那次"空库撞巧通过"的教训）
//   ③ 停用门禁默认**不误拦**：所有应用都是启用状态时，任何接口都不该回 app_disabled
//   ④ dry-run 在真库上真的不删（前后指标必须一致）—— 这条如果错了就是删生产数据
//   ⑤ 部署到线上的管理台产物里**真的有新界面**（照抄 index.html 的 src 取值，
//      自己拼 /assets/... 会拿到 21 字节的 {"error":"not found"}，看着像"没部署"）
//
// 退出码 0 = 全部通过。
const BASE = process.env.IM_BASE || 'http://192.168.31.44:3602';
const PASS = process.env.IM_PASS || '';

let pass = 0;
const bad = [];
function ok(name, cond, detail) {
  if (cond) { pass++; console.log(`  ✓ ${name}${detail ? ' — ' + detail : ''}`); }
  else { bad.push(name + (detail ? ' — ' + detail : '')); console.log(`  ✗ ${name}${detail ? ' — ' + detail : ''}`); }
}

async function raw(path, { method = 'GET', body, token, headers } = {}) {
  const h = { ...(headers || {}) };
  if (body) h['Content-Type'] = 'application/json';
  if (token) h.Authorization = 'Bearer ' + token;
  const r = await fetch(BASE + path, {
    method, headers: h, body: body ? JSON.stringify(body) : undefined,
  });
  return r;
}

async function req(path, opts = {}) {
  const r = await raw(path, opts);
  let j = null;
  try { j = await r.json(); } catch { /* 非 JSON（CSV 导出等） */ }
  return { status: r.status, body: j, res: r };
}

const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);

async function main() {
  console.log(`线上只读验收：${BASE}\n`);

  /* ---------- ① 版本 ---------- */
  // ⚠️ 路径是 /api/client/bootstrap（client 路由挂在 /api/client 下）。
  //    第一版写成 /api/bootstrap 拿到 404，看着像"版本没升上去"，其实是探针自己的错。
  const boot = (await req('/api/client/bootstrap')).body || {};
  ok('服务端版本已升到 0.21.0', boot.serverVersion === '0.21.0', `实际 ${boot.serverVersion}`);
  ok('/api/health 正常', (await req('/api/health')).status === 200);

  /* ---------- ② 未鉴权必须被拦 ---------- */
  ok('未鉴权 /api/admin/apps → 401', (await req('/api/admin/apps')).status === 401);
  ok('未鉴权 /api/admin/apps/attendance → 401', (await req('/api/admin/apps/attendance')).status === 401);

  /* ---------- ③ 登录 ---------- */
  if (!PASS) throw new Error('缺少 IM_PASS（管理台口令）');
  const li = await req('/api/auth/login', { method: 'POST', body: { username: 'admin', password: PASS } });
  const token = li.body?.token;
  ok('管理台登录成功', !!token, `status=${li.status}`);
  if (!token) throw new Error('登录失败，后续检查无意义');

  /* ---------- ④ 管理台清单 ---------- */
  const cat = (await req('/api/admin/apps', { token })).body || {};
  const builtin = cat.builtin || [];
  ok('应用清单含 7 个内置应用', builtin.length === 7, `实际 ${builtin.length}`);
  ok('每行都带"生效值"（界面据此显示已改名/已停用）',
    builtin.every((a) => a.effective && typeof a.effective.title === 'string'),
    JSON.stringify(builtin[0] && builtin[0].effective));
  ok('每行都带"和出厂差几项"', builtin.every((a) => Array.isArray(a.changedFields)),
    JSON.stringify(builtin.map((a) => [a.id, a.changedFields.length])));
  ok('线上目前没有任何应用被停用（否则门禁会开始拦）',
    builtin.every((a) => a.disabled === false),
    JSON.stringify(builtin.filter((a) => a.disabled).map((a) => a.id)));
  ok('参数注册表已随行下发', builtin.every((a) => a.paramCount >= 1),
    JSON.stringify(builtin.map((a) => [a.id, a.paramCount])));

  /* ---------- ⑤ 抽屉接口（app / guard / data） ---------- */
  const att = (await req('/api/admin/apps/attendance', { token })).body || {};
  ok('抽屉接口回四块', !!att.app && !!att.guard && !!att.data && Array.isArray(att.icons),
    JSON.stringify(Object.keys(att)));
  ok('guard 列出了"停用会关掉哪些接口"',
    (att.guard?.items || []).length >= 1 && (att.guard.items[0].paths || []).length >= 4,
    JSON.stringify(att.guard?.items?.map((x) => x.paths?.length)));
  ok('attendance 的规则不是 consoleOnly（否则等于没拦）',
    (att.guard?.items || []).every((x) => x.consoleOnly !== true),
    JSON.stringify(att.guard?.items?.map((x) => x.consoleOnly)));
  const attAdmin = (await req('/api/admin/apps/att_admin', { token })).body || {};
  ok('att_admin 的规则标了 consoleOnly（管理台不被连坐）',
    (attAdmin.guard?.items || []).some((x) => x.consoleOnly === true),
    JSON.stringify(attAdmin.guard?.items?.map((x) => x.consoleOnly)));
  ok('共用接口（审批中心等）已声明', Object.keys(att.data?.shared || {}).length >= 3,
    JSON.stringify(Object.keys(att.data?.shared || {})));

  const st = (await req('/api/admin/apps/stocktake', { token })).body || {};
  ok('扫码枪（纯离线）诚实说明"服务端没有它的数据"',
    st.data?.localOnly === true && /纯离线/.test(st.data?.localOnlyNote || '') && (st.data?.sources || []).length === 0,
    JSON.stringify({ l: st.data?.localOnly, n: (st.data?.localOnlyNote || '').slice(0, 30) }));

  /* ---------- ⑥ 概览：与既有接口**对数**（不是在真库上赌"一定有数据"） ----------
   *
   * 第一版这里写的是"每张表的指标至少一项非 0"，结果线上盘点位/培训课程都是 0 就红了两条。
   * 查清后确认是**判据写错了**：线上确实还没有任何盘点位和培训课程
   * （既有的、e2e 已覆盖的 /api/stocktake/zones 与 /api/training/admin/courses 同样回 0）。
   *
   * 但"全 0 可疑"这个直觉是对的：查询写错了别的表也会全 0，空库上永远看不出来。
   * 所以改成**更强的判据 —— 与既有独立实现对数**：
   * 老的接口（客户端正在用的那套）和新的 appdata 是两条独立代码路径，
   * 两边算出同一个数，才能同时排除"表写错了"和"WHERE 写漏了"。
   * 这样判据在任何数据状态下都成立（有数据时对数、没数据时都 0），不靠数据碰巧存在。
   */
  const num = (v) => (Array.isArray(v) ? v.length : Array.isArray(v?.items) ? v.items.length : null);

  const zones = num((await req('/api/stocktake/zones', { token })).body);
  const invZones = ((await req('/api/admin/apps/inventory', { token })).body?.data?.metrics || [])
    .find((m) => m.key === 'zones')?.value;
  ok('清单点数与既有 /api/stocktake/zones 对数一致（都是 0 也算一致）',
    zones !== null && zones === invZones, JSON.stringify({ 既有接口: zones, appdata: invZones }));

  const courses = num((await req('/api/training/admin/courses', { token })).body);
  const trCourses = ((await req('/api/admin/apps/training', { token })).body?.data?.metrics || [])
    .find((m) => m.key === 'courses')?.value;
  ok('培训课程数与既有 /api/training/admin/courses 对数一致',
    courses !== null && courses === trCourses, JSON.stringify({ 既有接口: courses, appdata: trCourses }));

  const members = num((await req('/api/orgs/my', { token })).body?.members);
  const woMembers = ((await req('/api/admin/apps/work_org', { token })).body?.data?.metrics || [])
    .find((m) => m.key === 'members')?.value;
  ok('在册员工数与既有 /api/orgs/my 对数一致', members !== null && members === woMembers,
    JSON.stringify({ 既有接口: members, appdata: woMembers }));

  // 内部一致性：概览的 total 必须等于明细分页的 total（同一张表的两个查询路径）
  const attApp = (await req('/api/admin/apps/attendance', { token })).body || {};
  const msAll = attApp.data?.metrics || [];
  const recTotal = (await req('/api/admin/apps/attendance/data?source=records&allTime=1&pageSize=1', { token }))
    .body?.total;
  ok('概览 total 与明细 total 一致（同表两条查询路径）',
    msAll.find((m) => m.key === 'total')?.value === recTotal,
    JSON.stringify({ 概览: msAll.find((m) => m.key === 'total')?.value, 明细: recTotal }));

  for (const id of ['attendance', 'inventory', 'training', 'work_org']) {
    const d = (await req('/api/admin/apps/' + id, { token })).body || {};
    const ms = d.data?.metrics || [];
    ok(`「${id}」概览有指标且没有取数告警`,
      ms.length >= 2 && (d.data?.warnings || []).length === 0,
      JSON.stringify({ 指标: ms.map((m) => [m.key, m.value]), 告警: d.data?.warnings }));
  }
  // 有数据的应用（线上确实有）仍要求非 0 —— 这是"查询真的落在正确的表上"的正向证据
  ok('有数据的应用（考勤/通讯录）概览确实非 0',
    ((attApp.data?.metrics || []).find((m) => m.key === 'total')?.value > 0)
    && (woMembers > 0),
    JSON.stringify({ 打卡: attApp.data?.metrics?.find((m) => m.key === 'total')?.value, 员工: woMembers }));
  // 商品档案（盘点要拉的账面数）——线上有 12 万条，顺带确认这条链路没被这轮改坏
  const mc = (await req('/api/master/count', { token })).body || {};
  ok('商品档案条数正常（盘点的账面数来源）', (mc.total || 0) > 0, JSON.stringify(mc.total));

  /* ---------- ⑦ 真库明细 ---------- */
  const attRec = (await req('/api/admin/apps/attendance/data?source=records&allTime=1&pageSize=5', { token })).body || {};
  ok('考勤打卡明细在真库上能翻页', Array.isArray(attRec.items) && typeof attRec.total === 'number',
    JSON.stringify({ n: attRec.items?.length, t: attRec.total }));
  ok('明细带列定义', (attRec.columns || []).length >= 6, JSON.stringify(attRec.columns?.length));
  if ((attRec.items || []).length) {
    ok('卡次是中文名（不是裸 out1）', !/^(in|out)\d$/.test(String(attRec.items[0].punch)),
      JSON.stringify(attRec.items[0].punch));
  }
  const invScans = (await req('/api/admin/apps/inventory/data?source=scans&allTime=1&pageSize=5', { token })).body || {};
  ok('盘点明细在真库上能翻页', typeof invScans.total === 'number', JSON.stringify({ t: invScans.total }));

  /* ---------- ⑧ 导出（BOM 与文本格式要在真产物里验） ---------- */
  const csvRes = await raw('/api/admin/apps/inventory/export?source=scans&allTime=1', { token });
  const csvType = csvRes.headers.get('content-type') || '';
  const bytes = new Uint8Array(await csvRes.arrayBuffer());
  const csv = Buffer.from(bytes).toString('utf8').replace(/^\uFEFF/, '');
  ok('导出 Content-Type 是 text/csv', /text\/csv/.test(csvType), csvType);
  ok('导出带 UTF-8 BOM（看原始字节，不是解码后的字符串）',
    bytes[0] === 0xEF && bytes[1] === 0xBB && bytes[2] === 0xBF, [...bytes.slice(0, 3)].join(','));
  ok('导出表头是中文列名', csv.includes('条码') && csv.includes('单号'), csv.split('\r\n')[0]?.slice(0, 90));
  ok('真库导出里长条码当 Excel 文本（不是裸数字）',
    /"=""\d{9,}"""/.test(csv) || !/\r\n\d{9,},/.test(csv), '未见裸露的长数字条码');

  /* ---------- ⑨ 门禁默认不误拦 + dry-run 真的不删 ---------- */
  const beforeMetrics = ((await req('/api/admin/apps/attendance', { token })).body?.data?.metrics) || [];
  const probePaths = [
    ['GET', '/api/attendance/today'],
    ['GET', '/api/attendance/requests'],
    ['GET', '/api/orgs/my'],
    ['GET', '/api/training/courses'],
    ['GET', '/api/stocktake/zones'],
    ['GET', '/api/admin/attendance/overview'],
    ['GET', '/api/master/count'],
  ];
  let wronglyBlocked = [];
  for (const [m, p] of probePaths) {
    const r = await req(p, { method: m, token });
    if (r.status === 403 && r.body?.code === 'app_disabled') wronglyBlocked.push(`${m} ${p}`);
  }
  ok('🔴 所有应用启用时，门禁不误拦任何接口（没有 403 app_disabled）',
    wronglyBlocked.length === 0, wronglyBlocked.join(', '));

  const dry = await req('/api/admin/apps/attendance/purge',
    { method: 'POST', token, body: { source: 'records', allTime: 1, dryRun: true } });
  ok('清理 dry-run 在真库上可用并返回条数',
    dry.status === 200 && dry.body?.dryRun === true && typeof dry.body?.count === 'number',
    JSON.stringify({ s: dry.status, c: dry.body?.count }));
  const afterMetrics = ((await req('/api/admin/apps/attendance', { token })).body?.data?.metrics) || [];
  ok('🔴 dry-run 前后指标完全一致（它真的没删生产数据）', same(beforeMetrics, afterMetrics),
    JSON.stringify({ before: beforeMetrics.map((x) => x.value), after: afterMetrics.map((x) => x.value) }));

  /* ---------- ⑩ 线上管理台产物里真的有新界面 ---------- */
  // ⚠️ 必须照抄 index.html 里的 src：静态目录挂在 /admin 下，
  //    自己拼 /assets/... 会拿到 21 字节的 {"error":"not found"}，看着像"没部署"
  const idx = await (await raw('/admin/index.html')).text();
  const m = /src="([^"]+\.js)"/.exec(idx);
  ok('能从线上 index.html 抠出 JS 产物路径', !!m, m ? m[1] : idx.slice(0, 80));
  if (m) {
    const url = m[1].startsWith('http') ? m[1] : BASE + (m[1].startsWith('/') ? m[1] : '/' + m[1]);
    const jsRes = await raw(url.replace(BASE, ''));
    const js = await jsRes.text();
    ok('线上 JS 产物大小正常（不是 21 字节的错误页）', js.length > 100000, `${js.length} 字节`);
    const want = ['· 应用管理', '停用与清理', '预览要清理什么', '整应用停用', '共用接口不随停用而关闭'];
    const miss = want.filter((s) => !js.includes(s));
    ok('线上管理台产物含本轮全部新界面串', miss.length === 0, miss.join(' / ') || '全部命中');
    // 反向：换一个本轮**没有**加的串，必须查不到（证明上面的命中不是恒真）
    const absent = '本字符串本轮绝对没有写过zzz';
    ok('反向：本轮没写的串在产物里查不到（证明上面的命中不是恒真）',
      !js.includes(absent), js.includes(absent) ? '竟然命中了 —— 判据没有鉴别力' : '');
  }

  console.log(`\n${bad.length ? '✗' : '✓'} 线上只读验收：通过 ${pass}，失败 ${bad.length}`);
  if (bad.length) { console.log('失败项：'); for (const b of bad) console.log('  · ' + b); }
  process.exit(bad.length ? 1 : 0);
}

main().catch((e) => { console.error('探针异常：', e.message); process.exit(2); });
