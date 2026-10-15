// 动态模块「取到真数据」+「排序统一管理」端到端测试（第四期）
//
// 这一期解决两件事：
//   ① 内容：list / table / chart 之前只有 dataPath 没有生产者，
//      现在的生产者有两条路 —— 上游接口（第三期）和**本服务器数据源**（本期）。
//   ② 排序：内置应用的 sort 在 app_overrides、自定义模块的 sort 在 app_modules，
//      两组各排各的序号，落到客户端就是交错。本期改成一处发号。
//
// 所以这里的重点不是"接口通不通"，而是：
//   · **能不能真的取到行**（不是返回一个空数组假装成功）
//   · **权限边界**（数据源声明了 admin 的，普通用户必须取不到）
//   · **默认最严**（没声明过的数据源一律 404，而不是"反正你猜不到路径"）
//   · **排序真的落到两张表**（只改一边 = 客户端顺序没变）
//
//   node test/module_data_e2e.js

const { spawn } = require('child_process');
const path = require('path');
const fs = require('fs');
const os = require('os');

const PORT = 3721;
const BASE = `http://127.0.0.1:${PORT}`;
const SERVER_DIR = path.resolve(__dirname, '..');
const DATA_DIR = path.join(os.tmpdir(), 'xiaozhi-md-e2e-' + Date.now());

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

/** 一个最小合法模块 */
function mod(over = {}) {
  return {
    moduleId: 'demo_mod',
    title: '演示模块',
    icon: 'dashboard',
    enabled: true,
    sort: 0,
    minClientVersion: null,
    visibleTo: { roles: [], userIds: [] },
    body: [{ component: 'text', text: 'hello' }],
    ...over,
  };
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

  // ---- 准备 ----
  const adminLogin = (await api('POST', '/api/auth/login', {
    body: { username: 'admin', password: 'admin-test-pw' },
  })).body;
  const admin = adminLogin.token;
  ok('管理员登录', !!admin);

  // 🔴 账号至少 3 个字符（服务端 auth.js 的硬约束）。曾经这里写 'li'（2 字符），
  //    注册 400 → 登录 401 → 下面 4 条权限断言**全部**报 401，
  //    看日志会以为是权限没做对，其实是测试自己没造出这个用户。
  //    所以注册也单独立一条断言：失败时根因就摆在第一行，不会连锁成 5 条红。
  const reg = await api('POST', '/api/auth/register', {
    body: { username: 'xiaoli', password: 'pass123456', nickname: '小李' },
  });
  ok('普通用户注册', reg.status === 200 || reg.status === 409,
    `实际 ${reg.status} ${reg.body?.error || ''}`);
  const userLogin = (await api('POST', '/api/auth/login', {
    body: { username: 'xiaoli', password: 'pass123456' },
  })).body;
  const user = userLogin.token;
  ok('普通用户登录', !!user, `实际 ${userLogin?.error || '无 token'}`);

  // 真商档两条：不插数据的话，取数接口返回空数组也"算成功" ——
  // 那正是这一期要消灭的"光有界面没有内容"，测试自己不能犯同一个错。
  const up1 = await api('POST', '/api/master/upload', {
    token: admin,
    body: {
      batch: 'b1',
      rows: [
        { barcode: '6900000000001', name: '康师傅红烧牛肉面', spec: '桶装105g', unit: '桶', unit_price: 5.5, purchase_price: 4.2, account_qty: 120, supplier: '顶益' },
        { barcode: '6900000000002', name: '农夫山泉饮用水', spec: '550ml', unit: '瓶', unit_price: 2, purchase_price: 1.4, account_qty: 300, supplier: '农夫' },
      ],
    },
  });
  ok('商档导入两条（取数要有真数据可取）',
    up1.status === 200 && up1.body?.accepted === 2,
    `实际 ${up1.status} accepted=${up1.body?.accepted}`);

  console.log('\n① 管理台「数据来源」清单');
  const srcRes = await api('GET', '/api/admin/module-sources', { token: admin });
  const srcs = srcRes.body;
  ok('管理员能拿到清单', srcRes.status === 200 && !!srcs, `实际 ${srcRes.status}`);
  ok('清单里有本服务器数据源', Array.isArray(srcs?.local) && srcs.local.length > 0,
    `实际 ${srcs?.local?.length}`);
  const prod = (srcs?.local || []).find((s) => s.appId === 'inventory' && s.key === 'products');
  ok('清单里有「商品档案」（工作台库存类模块最需要的那份）', !!prod);
  ok('每条都带可直接填进模块的路径（不用手敲）',
    (srcs?.local || []).every((s) => String(s.path || '').startsWith('/api/hooks/local/')),
    `反例 ${JSON.stringify((srcs?.local || [])[0]?.path)}`);
  ok('每条都带列（选完就能一键填好表格列）',
    (srcs?.local || []).every((s) => Array.isArray(s.columns) && s.columns.length > 0));
  ok('应用名是中文（下拉里不能显示 inventory）',
    (srcs?.local || []).every((s) => !!s.appTitle && s.appTitle !== s.appId));
  ok('上游清单不回 base_url（管理台用不上，多回就是多一条泄露通道）',
    (srcs?.upstreams || []).every((u) => u.baseUrl === undefined && u.hasAuth === undefined));
  ok('dataPath 约定下发给了管理台', srcs?.dataPath === 'data.rows');
  ok('普通用户拿不到清单（这是管理台接口）',
    (await api('GET', '/api/admin/module-sources', { token: user })).status === 403);

  console.log('\n② 取数：能不能真的取到行');
  const noAuth = await api('GET', '/api/hooks/local/inventory/products');
  ok('未登录 → 401（本库真数据没有"地址即凭证"这回事）', noAuth.status === 401,
    `实际 ${noAuth.status}`);

  const asAdmin = await api('GET', '/api/hooks/local/inventory/products', { token: admin });
  ok('管理员取商档 → 200', asAdmin.status === 200, `实际 ${asAdmin.status}`);
  const rows = asAdmin.body?.data?.rows;
  ok('真的取到了 2 行（不是空数组假装成功）', Array.isArray(rows) && rows.length === 2,
    `实际 ${rows?.length}`);
  ok('回包形状是 data.rows（与客户端 dataPath 约定一致）', Array.isArray(asAdmin.body?.data?.rows));
  const first = (rows || []).find((r) => r.barcode === '6900000000001');
  ok('取到的行带着商品名', first?.name === '康师傅红烧牛肉面', `实际 ${first?.name}`);
  ok('取到的行带着售价与进价', first?.saleText === '5.50' && first?.costText === '4.20',
    `实际 ${first?.saleText}/${first?.costText}`);
  ok('取到的行带着供应商', first?.supplier === '顶益', `实际 ${first?.supplier}`);
  ok('total 与行数对得上', asAdmin.body?.data?.total === 2, `实际 ${asAdmin.body?.data?.total}`);

  console.log('\n③ 权限：数据源自己声明了谁能取');
  const asUser = await api('GET', '/api/hooks/local/inventory/products', { token: user });
  ok('普通用户取含进价的商档 → 403（进价是采购成本）', asUser.status === 403,
    `实际 ${asUser.status}`);
  const dept = await api('GET', '/api/hooks/local/work_org/depts', { token: user });
  ok('普通用户取「部门」（module:all）→ 200', dept.status === 200, `实际 ${dept.status}`);
  const notExist = await api('GET', '/api/hooks/local/inventory/nope', { token: admin });
  ok('不存在的数据源 → 404', notExist.status === 404, `实际 ${notExist.status}`);
  // 没声明过 module 的数据源 = 404，而不是"你猜不到路径就算了"
  const priceTag = await api('GET', '/api/hooks/local/price_tag/whatever', { token: admin });
  ok('没对动态模块开放的应用 → 404（默认最严）', priceTag.status === 404,
    `实际 ${priceTag.status}`);
  const badPath = await api('GET', '/api/hooks/local/Inventory/products', { token: admin });
  ok('路径含大写 → 400（挡路径遍历）', badPath.status === 400, `实际 ${badPath.status}`);
  const noKey = await api('GET', '/api/hooks/local/inventory', { token: admin });
  ok('缺数据源名 → 400', noKey.status === 400, `实际 ${noKey.status}`);

  console.log('\n④ 排序：一处发号，两张表一起落');
  await api('POST', '/api/admin/modules', { token: admin, body: mod({ moduleId: 'sales_daily', title: '日销', sort: 0 }) });
  await api('POST', '/api/admin/modules', { token: admin, body: mod({ moduleId: 'repair_mod', title: '报修', sort: 0 }) });

  const ord = await api('POST', '/api/admin/order', {
    token: admin,
    body: {
      // 自定义模块必须带 module: 前缀，内置应用不带 ——
      // 前缀是显式的，改错对象立刻看得见
      order: ['attendance', 'module:sales_daily', 'module:repair_mod'],
    },
  });
  ok('统一排序 → 200', ord.status === 200 && ord.body?.ok, `实际 ${ord.status}`);
  ok('三个条目都排上了', ord.body?.moved === 3, `实际 ${ord.body?.moved}`);

  const after = (await api('GET', '/api/admin/modules', { token: admin })).body;
  const sales = (after?.modules || []).find((m) => m.moduleId === 'sales_daily');
  const repair = (after?.modules || []).find((m) => m.moduleId === 'repair_mod');
  ok('模块 sales_daily 排到 20', sales?.sort === 20, `实际 ${sales?.sort}`);
  ok('模块 repair_mod 排到 30', repair?.sort === 30, `实际 ${repair?.sort}`);
  ok('两个模块共用一组序号（不是各自 10/20）',
    sales?.sort !== repair?.sort && sales?.sort === 20,
    `实际 ${sales?.sort}/${repair?.sort}`);

  // 🔴 只改模块那一边是不算数的 —— 内置应用必须同时落库，
  //    否则客户端看到的还是"内置应用按老顺序、模块按新顺序"。
  const appsRes = (await api('GET', '/api/admin/apps', { token: admin })).body;
  const att = (appsRes?.builtin || []).find((a) => a.id === 'attendance');
  ok('内置应用 attendance 也排到了 10（两边共用一个序号空间）',
    att?.effective?.sort === 10, `实际 ${att?.effective?.sort}`);

  const withJunk = await api('POST', '/api/admin/order', {
    token: admin,
    body: { order: ['attendance', 'no_such_app', 'module:ghost_mod'] },
  });
  ok('未知条目被跳过而不是整批失败',
    withJunk.status === 200 && withJunk.body?.moved === 1 && withJunk.body?.skipped?.length === 2,
    `实际 moved=${withJunk.body?.moved} skipped=${JSON.stringify(withJunk.body?.skipped)}`);

  ok('未登录调排序 → 401', (await api('POST', '/api/admin/order', { body: { order: ['attendance'] } })).status === 401);
  ok('普通用户调排序 → 403',
    (await api('POST', '/api/admin/order', { token: user, body: { order: ['attendance'] } })).status === 403);
  ok('空清单 → 400（不给静默成功）',
    (await api('POST', '/api/admin/order', { token: admin, body: { order: [] } })).status === 400);

  // ------------------------------------------------------------------
  // ⑤ 模板本身必须自带内容
  //
  // 🔴 这一组是"光有界面没有内容"的守门员。
  //    2026-10-16 之前，模板库 4 份里有 3 份带着 list/table/chart 却没有 onLoad ——
  //    管理员点完模板得到一副空架子，而**没有一条测试会红**（接口都是通的）。
  //    这里就把"有数据组件 ⇒ 必须有取数入口"钉成硬约束。
  //    更进一步：不只看它写了路径，还要**真拿一次**，证明那条路径不是凭空编的。
  // ------------------------------------------------------------------
  console.log('\n⑤ 模板本身自带内容（不是空架子）');
  const caps = (await api('GET', '/api/admin/modules', { token: admin })).body;
  const tpls = caps?.capability?.templates || caps?.templates || [];
  ok('能力清单里带模板库', tpls.length > 0, `实际 ${tpls.length}`);

  const hasData = (body) => (body || []).some((c) => (
    ['list', 'table', 'chart'].includes(c.component)
    || (c.component === 'card' && hasData(c.children))));

  const dataTpls = tpls.filter((t) => hasData(t.module?.body));
  ok('模板库里确实有带数据组件的模板（否则本组形同虚设）',
    dataTpls.length > 0, `实际 ${dataTpls.length}`);
  ok('带数据组件的模板**每一个**都自带 onLoad',
    dataTpls.every((t) => !!t.module?.onLoad?.path),
    dataTpls.filter((t) => !t.module?.onLoad?.path).map((t) => t.name).join('、') || '');
  ok('每条 onLoad 路径都是 /api/hooks/ 开头（防 SSRF 的同一条约束）',
    dataTpls.every((t) => String(t.module?.onLoad?.path || '').startsWith('/api/hooks/')),
    dataTpls.map((t) => t.module?.onLoad?.path).join(' '));

  // 「商品清单（列表）」：模板说从哪取，就照那条路径取一次
  const listTpl = tpls.find((t) => t.module?.moduleId === 'stock_overview');
  ok('存在「商品清单（列表）」模板', !!listTpl);
  if (listTpl) {
    const got = await api('GET', listTpl.module.onLoad.path, { token: admin });
    ok('照模板的 onLoad 路径真的取到了 2 行（不是空数组假装成功）',
      got.status === 200 && Array.isArray(got.body?.data?.rows) && got.body.data.rows.length === 2,
      `实际 ${got.status} rows=${got.body?.data?.rows?.length}`);
  }

  // 「库存分布（图表）」：图表的 yKey 必须是**数字**，
  // 拿到字符串（比如带「—」的展示文本）画出来的柱子全是一样高
  const chartTpl = tpls.find((t) => t.module?.moduleId === 'sales_board');
  ok('存在「库存分布（图表）」模板', !!chartTpl);
  if (chartTpl) {
    const got = await api('GET', chartTpl.module.onLoad.path, { token: admin });
    const row0 = got.body?.data?.rows?.[0];
    ok('图表模板的 yKey「qty」取到的是数字（不然画不出柱子）',
      typeof row0?.qty === 'number', `实际 ${JSON.stringify(row0?.qty)}`);
    ok('图表模板的 xKey「name」取到的是商品名',
      typeof row0?.name === 'string' && row0.name.length > 0, `实际 ${JSON.stringify(row0?.name)}`);
  }

  console.log('\n──────────────────────────────');
  console.log(`通过 ${passed} 项，失败 ${failed} 项`);
  if (failed > 0) {
    for (const f of failures) console.log(`  ✗ ${f}`);
    console.log('❌ 有失败项');
    shutdown();
    process.exit(1);
  }
  console.log('✅ 全部通过');
  shutdown();
  process.exit(0);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
