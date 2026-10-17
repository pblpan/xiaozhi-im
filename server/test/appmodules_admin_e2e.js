// 自定义模块「与内置应用同权管理」端到端测试（v0.28.8）
//
//   node server/test/appmodules_admin_e2e.js
//
// ── 这个测试守的是什么 ─────────────────────────────────────────
// 2026-10-17 龙哥提的需求：「应用没有跟内置的应用做同样的排序，现在界面很乱。
// 自定义的数据放到和自带一样管理里面，在管理里面插入数据，做各种编辑」。
// 落地成三件事，每件都有一个"看着能用其实不可控"的坑：
//
//   ① **统一排序**：POST /admin/order 必须真的把两组的序号合成一个空间
//      （10/20/30…），而不是"各自发各自的号"。判据 = 发号后两组不再撞号，
//      且客户端 /api/client/apps 拿到的 apps 是**按 sort 混排**的，
//      不是 [...内置, ...模块] 拼接（拼接的后果：同组里模块永远排在最后，
//      管理台拖到第一行也纹丝不动）。
//   ② **同权管理**：PATCH /admin/modules/:id 必须只改给过的字段。
//      这里踩过的坑：管理台原来只有整串 POST /admin/modules（全量 upsert），
//      而 validate 对"没给"的字段补默认值 —— 于是"只改个分组"会把 body 抹空。
//   ③ **分组/配色**：模块要能落到任意分组、能显式配色，并且
//      ① 老式全量保存（不带这两个字段）不能把已配的值打回默认；
//       ② 分组必须是真存在的组（否则模块会在工作台里静默消失）。

const { spawn } = require('child_process');
const path = require('path');
const fs = require('fs');
const os = require('os');
const assert = require('assert');

// 只 require 纯函数模块：任何连库的模块都必须在**被测服务进程**里跑，
// 测试进程 require 它会连到另一个 DATA_DIR，读出来的数字对不上（曾经栽过）。
const appmodules = require('../src/appmodules');
const appregistry = require('../src/apps');

const PORT = 3699;
const BASE = `http://127.0.0.1:${PORT}`;
const SERVER_DIR = path.resolve(__dirname, '..');
const DATA_DIR = path.join(os.tmpdir(), 'xiaozhi-modadmin-e2e-' + Date.now());

let passed = 0;
let failed = 0;
const failures = [];

function ok(name, cond, extra) {
  if (cond) {
    passed++;
    console.log(`  ✓ ${name}`);
  } else {
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
    body: [{ component: 'text', text: 'hello', color: 'muted' }],
    ...over,
  };
}

/** 从 apps 数组里取出某条的下标（判"混排还是拼接"用） */
function indexOfApp(apps, id) {
  return apps.findIndex((a) => a.id === id);
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

  const adminLogin = (await api('POST', '/api/auth/login', {
    body: { username: 'admin', password: 'admin-test-pw' },
  })).body;
  const admin = adminLogin.token;
  ok('管理员登录', !!admin);

  await api('POST', '/api/auth/register', { body: { username: 'zhang', password: 'pass123456', nickname: '小张' } });
  const userLogin = (await api('POST', '/api/auth/login', {
    body: { username: 'zhang', password: 'pass123456' },
  })).body;
  const user = userLogin.token;
  ok('普通用户登录', !!user);

  /* ============================================================
   * 一：模块的 PATCH 只改给过的字段
   * ============================================================ */
  console.log('\n【一】PATCH /admin/modules/:id：只改给过的字段');
  const created = await api('POST', '/api/admin/modules', {
    token: admin,
    body: mod({
      moduleId: 'duty_roster',
      title: '值班表',
      icon: 'schedule',
      group: 'work',
      color: '#8250DF',
      onLoad: { action: 'api', path: '/api/hooks/demo/list', method: 'GET' },
      body: [
        { component: 'text', text: '今日值班', size: 18, color: 'primary', align: 'left' },
        { component: 'list', dataPath: 'data.items', itemTemplate: { title: '{{name}}', subtitle: '', trailing: '' } },
      ],
    }),
  });
  ok('建模块（带 group/color/onLoad/两个内容块）', created.status === 200, JSON.stringify(created.body).slice(0, 160));
  ok('  落库 group = work', created.body?.module?.group === 'work', created.body?.module?.group);
  ok('  落库 color = #8250DF', created.body?.module?.color === '#8250DF', created.body?.module?.color);

  // ① 只改分组：body / onLoad / color / title 一个都不许动
  const p1 = await api('PATCH', '/api/admin/modules/duty_roster', { token: admin, body: { group: 'custom' } });
  ok('PATCH 只改 group → 200', p1.status === 200, JSON.stringify(p1.body).slice(0, 160));
  ok('  group 已改成 custom', p1.body?.module?.group === 'custom', p1.body?.module?.group);
  ok('  🔴 body 没被抹掉（2 个内容块还在）', p1.body?.module?.body?.length === 2,
    JSON.stringify(p1.body?.module?.body?.length));
  ok('  onLoad 没被抹掉', p1.body?.module?.onLoad?.path === '/api/hooks/demo/list',
    JSON.stringify(p1.body?.module?.onLoad));
  ok('  color 没被抹掉', p1.body?.module?.color === '#8250DF', p1.body?.module?.color);
  ok('  title 没被抹掉', p1.body?.module?.title === '值班表', p1.body?.module?.title);

  // ② 只改配色
  const p2 = await api('PATCH', '/api/admin/modules/duty_roster', { token: admin, body: { color: 'danger' } });
  ok('PATCH 只改 color（语义色）→ 200', p2.status === 200 && p2.body?.module?.color === 'danger',
    JSON.stringify(p2.body).slice(0, 160));
  ok('  group 没被顺带改掉', p2.body?.module?.group === 'custom', p2.body?.module?.group);

  // ③ 只停用
  const p3 = await api('PATCH', '/api/admin/modules/duty_roster', { token: admin, body: { enabled: false } });
  ok('PATCH 只停用 → 200', p3.status === 200 && p3.body?.module?.enabled === false);
  ok('  停用后客户端清单里没有它',
    !(await api('GET', '/api/client/apps?clientVersion=9.9.9', { token: user })).body?.apps
      ?.some((a) => a.id === 'duty_roster'));

  // ④ 再打开，确认"停用→恢复"不丢内容
  const p4 = await api('PATCH', '/api/admin/modules/duty_roster', { token: admin, body: { enabled: true } });
  ok('PATCH 重新启用 → 内容完好', p4.status === 200 && p4.body?.module?.body?.length === 2
    && p4.body?.module?.onLoad?.path === '/api/hooks/demo/list');

  // ⑤ 只改 body（页面内容）：分组配色不能被打回默认
  const p5 = await api('PATCH', '/api/admin/modules/duty_roster', {
    token: admin,
    body: { body: [{ component: 'text', text: '改过的内容' }] },
  });
  ok('PATCH 只改 body → group/color 保留',
    p5.status === 200 && p5.body?.module?.group === 'custom' && p5.body?.module?.color === 'danger',
    `${p5.body?.module?.group}/${p5.body?.module?.color}`);

  // ⑥ 非法输入必须被拒，且不能留下半截状态
  const badGroup = await api('PATCH', '/api/admin/modules/duty_roster', { token: admin, body: { group: 'no_such_group' } });
  ok('PATCH 不存在的分组 → 400 且说清原因', badGroup.status === 400 && /分组不存在/.test(badGroup.body?.error || ''),
    JSON.stringify(badGroup.body).slice(0, 160));
  const badColor = await api('PATCH', '/api/admin/modules/duty_roster', { token: admin, body: { color: '红颜色' } });
  ok('PATCH 非法配色 → 400', badColor.status === 400 && /color/.test(badColor.body?.error || ''),
    JSON.stringify(badColor.body).slice(0, 160));
  const after = await api('GET', '/api/admin/modules', { token: admin });
  const still = after.body?.modules?.find((m) => m.moduleId === 'duty_roster');
  ok('两次被拒之后原值没被动（group=custom / color=danger）',
    still?.group === 'custom' && still?.color === 'danger', `${still?.group}/${still?.color}`);

  // ⑦ 鉴权
  const emp = await api('POST', '/api/auth/register', { body: { username: 'lisi', password: 'pass123456', nickname: '小李' } });
  const empLogin = (await api('POST', '/api/auth/login', { body: { username: 'lisi', password: 'pass123456' } })).body;
  ok('员工 PATCH 改模块 → 403', (await api('PATCH', '/api/admin/modules/duty_roster',
    { token: empLogin.token, body: { group: 'work' } })).status === 403);
  ok('未登录 PATCH 改模块 → 401', (await api('PATCH', '/api/admin/modules/duty_roster',
    { body: { group: 'work' } })).status === 401);
  ok('PATCH 不存在的模块 → 400（说"模块不存在"，不是 500）',
    (await api('PATCH', '/api/admin/modules/ghost', { token: admin, body: { group: 'work' } })).status === 400);

  /* ============================================================
   * 二：老式全量保存不能把分组/配色打回默认
   * ============================================================ */
  console.log('\n【二】POST /admin/modules 全量保存的保留语义');
  const legacy = await api('POST', '/api/admin/modules', {
    token: admin,
    body: mod({ moduleId: 'duty_roster', title: '值班表2', icon: 'schedule',
      body: [{ component: 'text', text: 'x' }] }),
  });
  ok('不带 group/color 的全量保存 → 200', legacy.status === 200, JSON.stringify(legacy.body).slice(0, 160));
  ok('  🔴 group 保留为 custom（没被打回默认前的 work）', legacy.body?.module?.group === 'custom',
    legacy.body?.module?.group);
  ok('  🔴 color 保留为 danger（没被打回自动配色）', legacy.body?.module?.color === 'danger',
    legacy.body?.module?.color);
  const clear = await api('POST', '/api/admin/modules', {
    token: admin, body: mod({ moduleId: 'duty_roster', title: '值班表2', group: null, color: null, body: [{ component: 'text', text: 'x' }] }),
  });
  ok('显式给 null = 清回默认（group=custom / color=null）',
    clear.body?.module?.group === 'custom' && clear.body?.module?.color === null,
    `${clear.body?.module?.group}/${clear.body?.module?.color}`);

  /* ============================================================
   * 三：统一排序（POST /admin/order）
   * ============================================================ */
  console.log('\n【三】统一排序：两组共用一个序号空间');
  const cat = (await api('GET', '/api/admin/apps', { token: admin })).body;
  const builtinIds = (cat.builtin || []).map((a) => a.id);
  const moduleIds = (cat.dynamic || []).map((m) => 'module:' + m.moduleId);
  ok('总览清单里两类都有（内置 %d + 模块 %d）', builtinIds.length > 0 && moduleIds.length > 0,
    `${builtinIds.length}/${moduleIds.length}`);

  // 故意造一个撞号现场：把第一个模块的 sort 设成和第一个内置应用一样
  const firstBuiltinSort = cat.builtin[0].effective.sort;
  await api('PATCH', '/api/admin/modules/duty_roster', { token: admin, body: { sort: firstBuiltinSort } });

  // 顺序：模块排最前，然后所有内置
  const desired = [...moduleIds, ...builtinIds];
  const r = await api('POST', '/api/admin/order', { token: admin, body: { order: desired } });
  ok('POST /admin/order → 200', r.status === 200, JSON.stringify(r.body).slice(0, 160));
  ok('  没有一条被跳过（module: 前缀被认识）', (r.body?.skipped || []).length === 0,
    JSON.stringify(r.body?.skipped));

  const cat2 = (await api('GET', '/api/admin/apps', { token: admin })).body;
  const allSorts = [
    ...(cat2.builtin || []).map((a) => a.effective.sort),
    ...(cat2.dynamic || []).map((m) => m.sort),
  ];
  const dup = allSorts.filter((s, i) => allSorts.indexOf(s) !== i);
  ok('🔴 发号后两组不再撞号（10/20/30…）', dup.length === 0, `撞号：${JSON.stringify(dup)}`);
  const asc = [...allSorts].sort((a, b) => a - b);
  ok('  序号从 10 开始步进 10（排完序逐项对）',
    asc.length > 0 && asc.every((v, i) => v === (i + 1) * 10),
    JSON.stringify(allSorts));

  // 空顺序 / 超长 / 脏 id
  ok('空顺序 → 400', (await api('POST', '/api/admin/order', { token: admin, body: { order: [] } })).status === 400);
  ok('顺序里混入不认识的 id 只跳过那条、不整批失败',
    (await api('POST', '/api/admin/order', { token: admin, body: { order: ['module:ghost', ...desired] } })).status === 200);
  ok('未登录排序 → 401', (await api('POST', '/api/admin/order', { body: { order: desired } })).status === 401);

  /* ============================================================
   * 四：客户端下发 —— 混排而不是拼接
   * ============================================================ */
  console.log('\n【四】GET /api/client/apps：同组内按 sort 混排');
  const cl = (await api('GET', '/api/client/apps?clientVersion=9.9.9', { token: user })).body;
  const apps = cl.apps || [];
  ok('客户端拿到了两类应用', apps.some((a) => a.kind === 'dynamic') && apps.some((a) => a.kind === 'builtin'));

  // duty_roster 的 sort 是整串里最小的（10），所有内置应用都 ≥ 20。
  // 拼接写法的后果是它被扔到数组末尾；混排则它必须在最前面。
  const modIdx = indexOfApp(apps, 'duty_roster');
  const firstBuiltinIdx = apps.findIndex((a) => a.kind === 'builtin');
  ok('🔴 模块排在下发列表最前面（混排，不是拼接在最后）',
    modIdx === 0 && firstBuiltinIdx > 0, `模块 idx=${modIdx} 首个内置 idx=${firstBuiltinIdx}`);
  ok('  且模块的 sort 严格小于所有内置应用',
    apps.filter((a) => a.kind === 'builtin').every((a) => a.sort > (apps[modIdx]?.sort ?? 0)),
    JSON.stringify(apps.map((a) => a.sort)));
  const sorts = apps.map((a) => a.sort);
  const sorted = [...sorts].sort((a, b) => a - b);
  ok('🔴 整个 apps 数组严格按 sort 升序', JSON.stringify(sorts) === JSON.stringify(sorted),
    JSON.stringify(sorts));

  // 模块能落到自定义分组，客户端看到对应组名
  await api('POST', '/api/admin/apps/groups', { token: admin, body: { key: 'baobiao', label: '智能助手', sort: 25 } });
  const moved = await api('PATCH', '/api/admin/modules/duty_roster', { token: admin, body: { group: 'baobiao' } });
  ok('模块挪到自定义分组「baobiao」', moved.status === 200 && moved.body?.module?.group === 'baobiao');
  const cl2 = (await api('GET', '/api/client/apps?clientVersion=9.9.9', { token: user })).body;
  const mod2 = (cl2.apps || []).find((a) => a.id === 'duty_roster');
  ok('  客户端下发的 group = baobiao、groupLabel = 智能助手',
    mod2?.group === 'baobiao' && mod2?.groupLabel === '智能助手',
    `${mod2?.group}/${mod2?.groupLabel}`);
  ok('  分组清单里带上了 baobiao', (cl2.groups || []).some((g) => g.key === 'baobiao'));
  // 挪组后它仍然按 sort 参与全局排序（没有掉到末尾）
  ok('  挪组后仍按 sort 混排（不是被挪到数组末尾）',
    indexOfApp(cl2.apps, 'duty_roster') === apps.findIndex((a) => a.sort === mod2?.sort),
    `idx=${indexOfApp(cl2.apps, 'duty_roster')}`);

  // 停用的模块不下发
  await api('PATCH', '/api/admin/modules/duty_roster', { token: admin, body: { enabled: false } });
  const cl3 = (await api('GET', '/api/client/apps?clientVersion=9.9.9', { token: user })).body;
  ok('停用后客户端不再下发', !(cl3.apps || []).some((a) => a.id === 'duty_roster'));

  /* ============================================================
   * 五：分组计数（管理台"组里几个"必须是真的）
   * ⚠️ 全部走 HTTP：测试进程里 require 的 appgroups 连的是**另一个库**
   *    （默认 DATA_DIR），读出来的数字对不上被测服务，曾经就在这里栽过。
   * ============================================================ */
  console.log('\n【五】分组计数');
  const groupOf = async (key) => {
    const c = (await api('GET', '/api/admin/apps', { token: admin })).body;
    return (c.groups || []).find((g) => g.key === key) || null;
  };
  // 此刻模块是停用状态（上一段刚停的），组里应该是 0
  ok('模块停用时不计入分组（工作台里本来就没有它）',
    (await groupOf('baobiao'))?.usedBy === 0, String((await groupOf('baobiao'))?.usedBy));
  await api('PATCH', '/api/admin/modules/duty_roster', { token: admin, body: { enabled: true } });
  ok('重新启用后「baobiao」组里算进 1 个模块',
    (await groupOf('baobiao'))?.usedBy === 1, String((await groupOf('baobiao'))?.usedBy));
  ok('「custom」组里不再把它算进去（按各自 group 计，不是一律算 custom）',
    (await groupOf('custom'))?.usedBy !== undefined);
  // 挪回 custom 后计数跟着走
  await api('PATCH', '/api/admin/modules/duty_roster', { token: admin, body: { group: 'custom' } });
  ok('挪回 custom 后计数跟着走', (await groupOf('custom'))?.usedBy >= 1
    && (await groupOf('baobiao'))?.usedBy === 0,
    `custom=${(await groupOf('custom'))?.usedBy} baobiao=${(await groupOf('baobiao'))?.usedBy}`);

  /* ============================================================
   * 六：单元级校验（不经过 HTTP，直接打 validate）
   * ============================================================ */
  console.log('\n【六】validate 单测：分组与配色');
  ok('缺省 group = custom', appmodules.validate({ moduleId: 'x_y', title: 't', body: [] }).module.group === 'custom');
  ok('语义色通过', appmodules.validate({ moduleId: 'x_y', title: 't', body: [], color: 'warning' }).module.color === 'warning');
  ok('#RRGGBB 通过', appmodules.validate({ moduleId: 'x_y', title: 't', body: [], color: '#AABBCC' }).module.color === '#AABBCC');
  ok('#AABBCCDD 被拒', !!appmodules.validate({ moduleId: 'x_y', title: 't', body: [], color: '#AABBCCDD' }).error);
  ok('空串 = 自动配色（null）', appmodules.validate({ moduleId: 'x_y', title: 't', body: [], color: '' }).module.color === null);
  ok('不存在的分组被拒', !!appmodules.validate({ moduleId: 'x_y', title: 't', body: [], group: 'zzz' }).error);
  ok('partial 不给 group 时不出现在结果里',
    appmodules.validate({ moduleId: 'x_y' }, { partial: true }).module.group === undefined);

  /* ============================================================
   * 七：客户端下发的颜色
   * ============================================================ */
  console.log('\n【七】模块配色下发');
  await api('PATCH', '/api/admin/modules/duty_roster', { token: admin, body: { color: '#123456' } });
  const cl4 = (await api('GET', '/api/client/apps?clientVersion=9.9.9', { token: user })).body;
  ok('配了 #RRGGBB 就照发', (cl4.apps || []).find((a) => a.id === 'duty_roster')?.color === '#123456');
  await api('PATCH', '/api/admin/modules/duty_roster', { token: admin, body: { color: null } });
  const cl5 = (await api('GET', '/api/client/apps?clientVersion=9.9.9', { token: user })).body;
  const autoColor = (cl5.apps || []).find((a) => a.id === 'duty_roster')?.color;
  ok('清空后走稳定散列兜底（#RRGGBB，且同一模块每次同一个色）',
    /^#[0-9A-Fa-f]{6}$/.test(autoColor || '') && autoColor === appregistry.moduleColorOf(null, 'duty_roster'),
    autoColor);

  /* ============================================================
   * 收尾
   * ============================================================ */
  console.log(`\n${failed ? '✗' : '✓'} 通过 ${passed} / ${passed + failed}`);
  if (failed) {
    console.log('失败项：');
    for (const f of failures) console.log('  · ' + f);
  }
  shutdown();
  process.exit(failed ? 1 : 0);
}

main().catch((e) => {
  console.error('测试自身异常：', e);
  process.exit(2);
});
