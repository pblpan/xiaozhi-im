// 应用中心「管理」端到端测试（v0.21.0：覆盖层 + 停用拦截 + 应用数据）
//
//   node server/test/apps_admin_e2e.js
//
// ── 这个测试守的是什么 ─────────────────────────────────────────
// 这轮加的能力有三个"看着能用其实不可控"的风险点，测试全部对着它们：
//   ① **停用必须拦后端**。只藏入口的话，老客户端/缓存页面还能打卡、还能上传，
//      而管理员以为已经停用了 —— 两边都"看着正常"，最难查。
//   ② **停用不能连坐**。三个考勤应用共用 /api/attendance 与 /api/admin/attendance
//      两棵路由树；按前缀一把抓会把"停用我的申请"误伤成"打卡也不能用了"。
//      管理台自己的「考勤管理」页跟客户端「考勤记录」应用调的是同一批路径，
//      也不能被一起关掉。
//   ③ **参数必须真的被读**。登记一个没人读的参数，比没有这个参数更糟：
//      管理员改完发现没效果，就再也不信这个页面上的任何东西。
//      所以三个 server 参数都做**真实判据**（不是"接口回 200"）。
//
// ── 这个测试怎么保证自己不是装饰品 ────────────────────────────
//   · 注册表自检：RULES 的可读清单 paths 必须逐条能被 test 匹配（防清单过期），
//     并且**每个内置应用要么有规则、要么显式登记为纯离线**（防漏登记）
//   · 反向断言：造一个不属于任何应用的路径，必须不被任何规则命中
//   · 停用判据带反向：停 A 之后 A 的接口 403 **且** B 的接口照常 200
//   · 参数判据全部读**真实响应体里的字段**，不看状态码
//   · 清理走完三步，并断言"条数对不上必须中止"

const { spawn } = require('child_process');
const path = require('path');
const fs = require('fs');
const os = require('os');
const assert = require('assert');

const { BUILTIN_APPS } = require('../src/apps');
const appguard = require('../src/appguard');
const appdata = require('../src/appdata');
const appoverrides = require('../src/appoverrides');

const PORT = 3697;
const BASE = `http://127.0.0.1:${PORT}`;
const SERVER_DIR = path.resolve(__dirname, '..');
const DATA_DIR = path.join(os.tmpdir(), 'xiaozhi-appsadmin-e2e-' + Date.now());

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

async function api(method, p, { token, body, headers } = {}) {
  const res = await fetch(BASE + p, {
    method,
    headers: {
      'Content-Type': 'application/json',
      ...(token ? { Authorization: 'Bearer ' + token } : {}),
      ...(headers || {}),
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  let json = null;
  try { json = await res.json(); } catch { /* 空响应 */ }
  return { status: res.status, body: json };
}

/* ============================================================
 * 零：注册表自检（纯函数，不依赖服务端）
 * ============================================================ */
console.log('\n【零】路由归属注册表自检');

{
  // paths 是给人看的清单，test 是真正生效的判据。两者一旦漂移，
  // 管理台上"停用会关掉这些接口"就变成一段过期文案 —— 比没有更误导。
  let drift = [];
  for (const r of appguard.RULES) {
    for (const line of r.paths) {
      // 'GET  /api/attendance/today' → 方法 + 路径（ANY 表示任意方法）
      const m = /^([A-Z]+)\s+(\S+)$/.exec(line.trim());
      if (!m) { drift.push(`路径写法不合法：${line}`); continue; }
      // 把 :id / * 之类的占位换成具体值，再喂给 test
      const concrete = m[2].replace(/:id/g, '123').replace(/\*$/, 'abc');
      if (!r.test(concrete)) drift.push(`${r.app} 的 "${line}" 不被 test 命中`);
    }
  }
  ok('RULES 的可读清单与真正的匹配函数一致（无漂移）', drift.length === 0, drift.join(' | '));

  // 反向断言：不属于任何应用的路径必须不被命中，否则判据是"恒真"
  const outsiders = ['/api/auth/login', '/api/admin/apps', '/api/client/apps', '/api/health', '/api/messages'];
  const hit = outsiders.filter((p) => appguard.resolveRule(p));
  ok('反向：与内置应用无关的路径不被任何规则命中', hit.length === 0, hit.join(','));

  // 每个内置应用要么有拦截规则、要么显式登记为纯离线 —— 防"新加了个应用忘了登记"
  const missing = BUILTIN_APPS
    .filter((a) => !appguard.RULES.some((r) => r.app === a.id) && !appguard.LOCAL_ONLY[a.id])
    .map((a) => a.id);
  ok('每个内置应用都已登记（有规则 / 或标记纯离线）', missing.length === 0, missing.join(','));

  // 反向断言：LOCAL_ONLY 不能变成"漏登记的垃圾桶"——
  // 有服务端接口的应用不该被标成纯离线
  ok('反向：有接口的应用没有被误标为纯离线',
    !appguard.LOCAL_ONLY.attendance && !appguard.LOCAL_ONLY.training && !appguard.LOCAL_ONLY.inventory,
    Object.keys(appguard.LOCAL_ONLY).join(','));

  // 参数注册表：每个登记的参数都必须标了强制方（server / client），
  // 否则"改完会不会生效"这个最基本的问题答不出来
  let unlabeled = [];
  for (const a of BUILTIN_APPS) {
    for (const p of appoverrides.paramSchemaOf(a.id)) {
      if (!['server', 'client'].includes(p.enforced)) unlabeled.push(`${a.id}.${p.key}`);
    }
  }
  ok('每个参数都标注了强制方（server/client）', unlabeled.length === 0, unlabeled.join(','));

  // 反向断言：没登记过的参数键必须被拒 —— 否则任何人都能往 params 里塞垃圾
  const fake = appdata.APPS.attendance && appoverrides.paramDefOf('attendance', 'not_a_real_param');
  ok('反向：未登记的参数键查不到定义（校验会拒它）', fake === null, JSON.stringify(fake));

  // 每个内置应用都要在 appdata 里有登记（哪怕是"纯离线，没有数据"）
  const noData = BUILTIN_APPS.filter((a) => !appdata.APPS[a.id]).map((a) => a.id);
  ok('每个内置应用都在数据源注册表里（哪怕是显式声明"没有数据"）', noData.length === 0, noData.join(','));
  ok('纯离线应用显式声明了"没有数据"而不是留空',
    !!appdata.APPS.stocktake?.localOnly && /纯离线/.test(appdata.APPS.stocktake.localOnlyNote || ''),
    JSON.stringify(appdata.APPS.stocktake?.localOnly));
  // 共用同一批表的应用必须写出来（否则两个页面一对照就是一次"数据不一致"排查）
  ok('共用表的应用显式声明了"数据是同一批"',
    /同一批表/.test(appdata.APPS.att_admin?.overviewNote || ''),
    appdata.APPS.att_admin?.overviewNote);

  // CSV 单元格：长数字要写成文本公式，短数字**不能**被写（否则看着像坏了）
  ok('CSV 长数字列写成 Excel 文本',
    appdata.csvCell('1234567890123', true) === '"=""1234567890123"""',
    appdata.csvCell('1234567890123', true));
  ok('CSV 前导零编码写成文本', appdata.csvCell('007', true) === '"=""007"""', appdata.csvCell('007', true));
  ok('反向：短数字列不改写（避免满屏 ="1"）', appdata.csvCell('12', true) === '12', appdata.csvCell('12', true));
  ok('反向：非文本列的长数字不改写', appdata.csvCell('1234567890123', false) === '1234567890123',
    appdata.csvCell('1234567890123', false));
  ok('CSV 含逗号的值按 RFC4180 加引号', appdata.csvCell('a,b', false) === '"a,b"', appdata.csvCell('a,b', false));
}

/* ============================================================
 * 起服务端
 * ============================================================ */

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

  const admin = (await api('POST', '/api/auth/login',
    { body: { username: 'admin', password: 'admin-test-pw' } })).body?.token;
  ok('管理员登录', !!admin);

  // ---- 环境：工作模式 + 组织 + 一个长工号员工（导出文本格式要用它）----
  await api('PUT', '/api/admin/settings', { token: admin, body: { friendMode: 'work' } });
  const orgId = (await api('POST', '/api/orgs', { token: admin, body: { name: '测试门店' } })).body?.id;
  const deptId = (await api('POST', '/api/orgs/depts', { token: admin, body: { name: '生鲜部', sort: 1 } })).body?.id;
  // 🔴 工号故意做成 13 位纯数字：Excel 默认会把这种值写成科学计数法，
  //    正好用来验"导出时当文本"这条真的在真实产物里生效（不是单元测试自嗨）
  const LONG_NO = '1234567890123';
  const empRes = await api('POST', `/api/orgs/${orgId}/members`,
    { token: admin, body: { employeeNo: LONG_NO, nickname: '长工号', deptId } });
  const empId = empRes.body?.user?.id;
  const emp = (await api('POST', '/api/auth/login',
    { body: { username: LONG_NO, password: LONG_NO } })).body?.token;
  const empPlain = (await api('POST', `/api/orgs/${orgId}/members`,
    { token: admin, body: { employeeNo: 'emp01', nickname: '张三', deptId } })).body?.user?.id;
  const empT = (await api('POST', '/api/auth/login', { body: { username: 'emp01', password: 'emp01' } })).body?.token;
  ok('组织 / 部门 / 员工就绪', !!orgId && !!deptId && !!empId && !!emp && !!empT && !!empPlain);
  await api('PUT', '/api/admin/attendance/config', {
    token: admin, body: { workdays: [0, 1, 2, 3, 4, 5, 6], enabled: true },
  });
  // 打两次卡，给清理用例留数据
  await api('POST', '/api/attendance/clock', { token: empT, body: { type: 'in', slot: 1 } });
  await api('POST', '/api/attendance/clock', { token: empT, body: { type: 'out', slot: 1 } });

  /* ============================================================
   * 一：覆盖层（改名 / 图标 / 排序 / 停用 / 参数）
   * ============================================================ */
  console.log('\n【一】应用覆盖层');

  let r = await api('GET', '/api/admin/apps', { token: admin });
  const attRow = (r.body?.builtin || []).find((a) => a.id === 'attendance');
  ok('管理台清单带出厂默认排序与生效值', !!attRow && attRow.defaultSort === 0 && attRow.effective.title === '考勤打卡',
    JSON.stringify(attRow && { d: attRow.defaultSort, e: attRow.effective }));

  // 改名 + 换图标 + 调排序
  r = await api('PATCH', '/api/admin/apps/attendance',
    { token: admin, body: { title: '上班打卡', icon: 'task', sort: 55 } });
  ok('改名/换图标/调排序被接受', r.status === 200 && r.body?.ok, JSON.stringify(r.body).slice(0, 160));
  ok('  差异清单列出了三项', (r.body?.app?.changedFields || []).length === 3,
    JSON.stringify(r.body?.app?.changedFields));
  ok('  生效值已经是新的', r.body?.app?.effective.title === '上班打卡'
    && r.body?.app?.effective.icon === 'task' && r.body?.app?.effective.sort === 55,
    JSON.stringify(r.body?.app?.effective));
  // PATCH 的回包里 visibleForAdmin 必须是真的判据（不是写死的 false）——
  // 它是"管理员自己能不能看到这个入口"，考勤打卡对管理员本来就是不可见的
  // （管理员不参与打卡，他看的是「考勤记录」）
  ok('回包里的 visibleForAdmin 是真实判据：考勤打卡对管理员不可见',
    r.body?.app?.visibleForAdmin === false, JSON.stringify(r.body?.app?.visibleForAdmin));
  const trView = (await api('GET', '/api/admin/apps/training', { token: admin })).body;
  ok('  反向：培训中心对管理员可见（证明上一条不是恒 false）',
    trView?.app?.visibleForAdmin === true, JSON.stringify(trView?.app?.visibleForAdmin));

  // 客户端清单必须跟着变（改服务端下发即生效，客户端一行不用改）
  let apps = (await api('GET', '/api/client/apps?clientVersion=0.16.0', { token: empT })).body?.apps || [];
  let mine = apps.find((a) => a.id === 'attendance');
  ok('客户端清单里的标题/图标跟着变', mine?.title === '上班打卡' && mine?.icon === 'task', JSON.stringify(mine));

  // 排序真的生效（内置应用之间按 sort 重排）
  await api('PATCH', '/api/admin/apps/training', { token: admin, body: { sort: 1 } });
  apps = (await api('GET', '/api/client/apps?clientVersion=0.16.0', { token: empT })).body?.apps || [];
  const builtinOrder = apps.filter((a) => a.kind === 'builtin').map((a) => a.id);
  ok('🔴 排序真的生效（training 排到最前）', builtinOrder[0] === 'training', builtinOrder.join(','));

  // 非法值必须被拒（否则界面上的"改不动"会变成"改坏了"）
  r = await api('PATCH', '/api/admin/apps/attendance', { token: admin, body: { icon: 'no_such_icon' } });
  ok('拒绝：不在白名单里的图标名', r.status === 400, JSON.stringify(r.body).slice(0, 120));
  r = await api('PATCH', '/api/admin/apps/attendance', { token: admin, body: { title: '这个名字实在是太长了放不下' } });
  ok('拒绝：标题超长', r.status === 400, JSON.stringify(r.body).slice(0, 120));
  r = await api('PATCH', '/api/admin/apps/attendance', { token: admin, body: { params: { not_a_real_param: 1 } } });
  ok('拒绝：未登记的参数键', r.status === 400, JSON.stringify(r.body).slice(0, 120));
  r = await api('PATCH', '/api/admin/apps/attendance', { token: admin, body: { params: { minClientVersion: 'v1' } } });
  ok('拒绝：版本号格式错', r.status === 400, JSON.stringify(r.body).slice(0, 120));
  // 动态模块不能走这个抽屉（它有自己的编辑器，两处能改同一件事迟早对不上）
  r = await api('PATCH', '/api/admin/apps/work_org_x', { token: admin, body: { title: 'x' } });
  ok('拒绝：不是内置应用（动态模块走自己的编辑器）',
    r.status === 404 && r.body?.code === 'not_builtin', JSON.stringify(r.body));

  // need 不可覆盖 —— 它是"这个入口该不该出现"的唯一判据
  r = await api('PATCH', '/api/admin/apps/attendance', { token: admin, body: { need: { workMode: false } } });
  ok('提交 need 不会改掉出厂条件', r.status === 200
    && r.body?.app?.factory?.need?.workMode === true
    && r.body?.app?.effective?.title === '上班打卡',
    JSON.stringify(r.body?.app?.factory?.need));

  // PATCH 语义：没给的字段不能被清掉
  r = await api('PATCH', '/api/admin/apps/attendance', { token: admin, body: { sort: 60 } });
  ok('🔴 PATCH 语义：只给 sort 时 title/icon 不被清掉',
    r.body?.app?.effective?.title === '上班打卡' && r.body?.app?.effective?.icon === 'task'
    && r.body?.app?.effective?.sort === 60,
    JSON.stringify(r.body?.app?.effective));

  // 恢复出厂
  r = await api('DELETE', '/api/admin/apps/attendance', { token: admin });
  ok('恢复出厂', r.status === 200 && r.body?.removed === true && r.body?.app?.changed === false,
    JSON.stringify(r.body).slice(0, 160));
  r = await api('DELETE', '/api/admin/apps/attendance', { token: admin });
  ok('  再点一次是幂等的（本来就是出厂）', r.status === 200 && r.body?.removed === false, JSON.stringify(r.body));
  apps = (await api('GET', '/api/client/apps?clientVersion=0.16.0', { token: empT })).body?.apps || [];
  ok('  客户端清单回到出厂标题', apps.find((a) => a.id === 'attendance')?.title === '考勤打卡',
    JSON.stringify(apps.find((a) => a.id === 'attendance')));
  await api('DELETE', '/api/admin/apps/training', { token: admin });

  /* ============================================================
   * 二：停用 = 隐藏入口 + 后端每条接口都拦
   * ============================================================ */
  console.log('\n【二】停用拦截（含"不能连坐"）');

  // 未停用时的基线 —— 没有这个基线，后面的 403 说明不了是"停用拦的"
  r = await api('GET', '/api/attendance/today', { token: empT });
  ok('基线：未停用时 today 正常', r.status === 200, `实际 ${r.status}`);
  r = await api('GET', '/api/attendance/requests', { token: empT });
  ok('基线：未停用时 申请列表 正常', r.status === 200, `实际 ${r.status}`);
  r = await api('GET', '/api/orgs/my', { token: empT });
  ok('基线：未停用时 通讯录 正常', r.status === 200, `实际 ${r.status}`);
  r = await api('GET', '/api/training/courses', { token: empT });
  ok('基线：未停用时 课程列表 正常', r.status === 200, `实际 ${r.status}`);
  r = await api('GET', '/api/stocktake/zones', { token: empT });
  ok('基线：未停用时 盘点接口 有响应（非 404 路由缺失）', r.status !== 404, `实际 ${r.status}`);

  // ── 停用「考勤打卡」：它的接口必须 403，而「我的申请」不能受影响
  await api('PATCH', '/api/admin/apps/attendance', { token: admin, body: { disabled: true } });
  r = await api('GET', '/api/attendance/today', { token: empT });
  ok('🔴 停用考勤打卡 → today 被拦（403 app_disabled）',
    r.status === 403 && r.body?.code === 'app_disabled' && r.body?.app === 'attendance', JSON.stringify(r.body));
  r = await api('POST', '/api/attendance/clock', { token: empT, body: { type: 'in', slot: 1 } });
  ok('🔴 停用后打卡接口也被拦（不能只藏入口）',
    r.status === 403 && r.body?.code === 'app_disabled', JSON.stringify(r.body));
  r = await api('GET', '/api/attendance/records', { token: empT });
  ok('  卡流水同样被拦', r.status === 403, `实际 ${r.status}`);
  r = await api('GET', '/api/attendance/requests', { token: empT });
  ok('🔴 但「我的申请」不受连坐（共用 /api/attendance 前缀）', r.status === 200, `实际 ${r.status}`);
  apps = (await api('GET', '/api/client/apps?clientVersion=0.16.0', { token: empT })).body?.apps || [];
  ok('  客户端清单里考勤打卡消失', !apps.some((a) => a.id === 'attendance'),
    apps.map((a) => a.id).join(','));

  // ── 恢复，再停用「我的申请」
  await api('DELETE', '/api/admin/apps/attendance', { token: admin });
  r = await api('GET', '/api/attendance/today', { token: empT });
  ok('恢复出厂后 today 立刻可用', r.status === 200, `实际 ${r.status}`);

  await api('PATCH', '/api/admin/apps/my_requests', { token: admin, body: { disabled: true } });
  r = await api('GET', '/api/attendance/requests', { token: empT });
  ok('🔴 停用我的申请 → 申请接口被拦', r.status === 403 && r.body?.code === 'app_disabled', JSON.stringify(r.body));
  r = await api('POST', '/api/attendance/clock', { token: empT, body: { type: 'in', slot: 1 } });
  ok('🔴 但打卡不受连坐（同一棵路由树）', r.status === 200, `实际 ${r.status} ${JSON.stringify(r.body).slice(0, 80)}`);
  await api('DELETE', '/api/admin/apps/my_requests', { token: admin });

  // ── 停用「组织通讯录」
  await api('PATCH', '/api/admin/apps/work_org', { token: admin, body: { disabled: true } });
  r = await api('GET', '/api/orgs/my', { token: empT });
  ok('🔴 停用组织通讯录 → /api/orgs/my 被拦', r.status === 403 && r.body?.code === 'app_disabled', JSON.stringify(r.body));
  r = await api('GET', '/api/orgs/depts', { token: admin });
  ok('  但部门管理（管理台在用，共用 /api/orgs）不受影响', r.status === 200, `实际 ${r.status}`);
  await api('DELETE', '/api/admin/apps/work_org', { token: admin });

  // ── 停用「培训中心」：管理端不能被连坐（同一棵路由树，靠路径前缀区分）
  await api('PATCH', '/api/admin/apps/training', { token: admin, body: { disabled: true } });
  r = await api('GET', '/api/training/courses', { token: empT });
  ok('🔴 停用培训中心 → 学员端课程被拦', r.status === 403 && r.body?.code === 'app_disabled', JSON.stringify(r.body));
  r = await api('GET', '/api/training/admin/courses', { token: admin });
  ok('  但 /api/training/admin/* 放行（管理端在自己的前缀下）', r.status === 200, `实际 ${r.status}`);
  await api('DELETE', '/api/admin/apps/training', { token: admin });

  // ── 停用「盘点」：走 /api/stocktake 与 /api/location
  await api('PATCH', '/api/admin/apps/inventory', { token: admin, body: { disabled: true } });
  r = await api('GET', '/api/stocktake/zones', { token: empT });
  ok('🔴 停用盘点 → /api/stocktake/* 被拦', r.status === 403 && r.body?.code === 'app_disabled', JSON.stringify(r.body));
  r = await api('GET', '/api/location/bind?barcode=1', { token: empT });
  ok('  /api/location/* 同样被拦', r.status === 403, `实际 ${r.status}`);
  await api('DELETE', '/api/admin/apps/inventory', { token: admin });

  // ── 停用「考勤记录」：客户端调 /api/admin/attendance/* 要拦，管理台调不能拦
  await api('PATCH', '/api/admin/apps/att_admin', { token: admin, body: { disabled: true } });
  r = await api('GET', '/api/admin/attendance/overview', { token: admin });
  ok('🔴 停用考勤记录 → 客户端走的 /api/admin/attendance/* 被拦',
    r.status === 403 && r.body?.code === 'app_disabled', JSON.stringify(r.body));
  r = await api('GET', '/api/admin/attendance/overview', { token: admin, headers: { 'X-Console': '1' } });
  ok('🔴 但管理台（带 X-Console 头）照常可用 —— 同一批路径两拨调用方',
    r.status === 200, `实际 ${r.status} ${JSON.stringify(r.body).slice(0, 80)}`);
  r = await api('GET', '/api/admin/attendance/config', { token: admin, headers: { 'X-Console': '1' } });
  ok('  管理台「考勤管理」页的配置接口同样可用', r.status === 200, `实际 ${r.status}`);
  // 反向断言：X-Console 不是权限后门 —— 普通员工带这个头也拿不到管理端数据
  r = await api('GET', '/api/admin/attendance/overview', { token: empT, headers: { 'X-Console': '1' } });
  ok('🔴 反向：员工带 X-Console 头也拿不到管理端数据（403 forbidden）',
    r.status === 403 && r.body?.error === 'forbidden', JSON.stringify(r.body));
  await api('DELETE', '/api/admin/apps/att_admin', { token: admin });

  // 停用不改业务开关（两者语义不同，不能互相遮蔽）
  r = await api('GET', '/api/admin/attendance/config', { token: admin, headers: { 'X-Console': '1' } });
  ok('停用/恢复不会动到「考勤设置」的业务开关', r.body?.enabled === true, JSON.stringify(r.body?.enabled));

  /* ============================================================
   * 三：参数真的被服务端读（三条真实判据）
   * ============================================================ */
  console.log('\n【三】参数真的生效（读响应体字段，不看状态码）');

  // ① work_org.showEmployeeNo —— 工号是登录账号，只藏不拦等于发给了所有人
  r = await api('GET', '/api/orgs/my', { token: empT });
  ok('基线：通讯录默认带工号',
    r.body?.members?.some((m) => m.employee_no === LONG_NO) && r.body?.employeeNoShown === true,
    JSON.stringify(r.body?.members?.map((m) => m.employee_no)));
  await api('PATCH', '/api/admin/apps/work_org', { token: admin, body: { params: { showEmployeeNo: false } } });
  r = await api('GET', '/api/orgs/my', { token: empT });
  ok('🔴 关掉「显示工号」→ 服务端抹掉 employee_no（不是让客户端别显示）',
    r.body?.employeeNoShown === false && r.body?.members?.length > 0
    && r.body.members.every((m) => m.employee_no === null),
    JSON.stringify(r.body?.members?.map((m) => m.employee_no)));
  await api('PATCH', '/api/admin/apps/work_org', { token: admin, body: { params: { showEmployeeNo: true } } });
  r = await api('GET', '/api/orgs/my', { token: empT });
  ok('  改回来立刻恢复', r.body?.members?.some((m) => m.employee_no === LONG_NO), '工号没回来');

  // ② my_requests.badge —— 角标（管理台可关，避免"没做也要弹红点"）
  await api('POST', '/api/attendance/requests', {
    token: empT, body: { kind: 'leave', startDay: '2026-09-01', endDay: '2026-09-02', leaveType: 'personal', reason: '测试' },
  });
  apps = (await api('GET', '/api/client/apps?clientVersion=0.16.0', { token: empT })).body?.apps || [];
  ok('基线：有待审申请时「我的申请」带角标',
    apps.find((a) => a.id === 'my_requests')?.badge === '1',
    JSON.stringify(apps.find((a) => a.id === 'my_requests')));
  await api('PATCH', '/api/admin/apps/my_requests', { token: admin, body: { params: { badge: false } } });
  apps = (await api('GET', '/api/client/apps?clientVersion=0.16.0', { token: empT })).body?.apps || [];
  ok('🔴 关掉角标 → 清单里不再有 badge 字段',
    apps.find((a) => a.id === 'my_requests')?.badge === undefined,
    JSON.stringify(apps.find((a) => a.id === 'my_requests')));
  ok('  但入口本身还在（关角标不是停用）', !!apps.find((a) => a.id === 'my_requests'), '入口没了');
  await api('PATCH', '/api/admin/apps/my_requests', { token: admin, body: { params: { badge: true } } });

  // ③ minClientVersion —— 新功能只给已升级的人
  await api('PATCH', '/api/admin/apps/training', { token: admin, body: { params: { minClientVersion: '0.16.0' } } });
  apps = (await api('GET', '/api/client/apps?clientVersion=0.15.0', { token: empT })).body?.apps || [];
  ok('🔴 低于最低版本 → 老客户端看不到该应用', !apps.some((a) => a.id === 'training'),
    apps.map((a) => a.id).join(','));
  apps = (await api('GET', '/api/client/apps?clientVersion=0.16.0', { token: empT })).body?.apps || [];
  ok('  达到最低版本 → 看得到', apps.some((a) => a.id === 'training'), apps.map((a) => a.id).join(','));
  apps = (await api('GET', '/api/client/apps', { token: empT })).body?.apps || [];
  ok('🔴 没带 clientVersion 的老客户端**照旧放行**（不制造集体断供）',
    apps.some((a) => a.id === 'training'), apps.map((a) => a.id).join(','));
  // 下发的是"生效值"（出厂默认 + 覆盖），客户端不用自己猜缺省
  const tr = apps.find((a) => a.id === 'training');
  ok('  客户端拿到的参数是生效值（含 showAnswer 默认 true）',
    tr?.params?.showAnswer === true && tr?.params?.minClientVersion === '0.16.0',
    JSON.stringify(tr?.params));
  await api('DELETE', '/api/admin/apps/training', { token: admin });

  // ④ training.showAnswer —— 交卷后是否回显正确答案
  console.log('  · 搭一门课 + 一场考试（验 showAnswer）');
  const courseId = (await api('POST', '/api/training/admin/courses',
    { token: admin, body: { title: '参数测试课', published: true } })).body?.id;
  const chapterId = (await api('POST', '/api/training/admin/chapters',
    { token: admin, body: { courseId, title: '第一章', sort: 1 } })).body?.id;
  const lessonId = (await api('POST', '/api/training/admin/lessons',
    { token: admin, body: { chapterId, title: '课时一', kind: 'video', durationSec: 60, sort: 1 } })).body?.id;
  await api('POST', '/api/training/progress', { token: empT, body: { lessonId, positionSec: 60, done: true } });
  const examId = (await api('POST', '/api/training/admin/exams', {
    token: admin,
    body: {
      chapterId, title: '第一章考试', passScore: 60, attemptLimit: 5, minProgress: 100,
      questions: [{ type: 'single', stem: '选哪个？', score: 10, options: [{ content: '甲', correct: true }, { content: '乙' }] }],
    },
  })).body?.id;
  ok('  课程/章节/课时/考试就绪', !!courseId && !!chapterId && !!lessonId && !!examId,
    JSON.stringify([courseId, chapterId, lessonId, examId]));

  let started = await api('POST', `/api/training/exams/${examId}/start`, { token: empT });
  const sheet1 = started.body?.sheetId;
  const q1 = (started.body?.questions || [])[0];
  r = await api('POST', `/api/training/sheets/${sheet1}/submit`, { token: empT, body: { answers: [{ questionId: q1.id, chosen: 'B' }] } });
  ok('基线：默认交卷回显正确答案（rightLabels 是字符串）',
    typeof r.body?.detail?.[0]?.rightLabels === 'string' && r.body?.answerHidden === false,
    JSON.stringify(r.body?.detail));

  await api('PATCH', '/api/admin/apps/training', { token: admin, body: { params: { showAnswer: false } } });
  started = await api('POST', `/api/training/exams/${examId}/start`, { token: empT });
  const sheet2 = started.body?.sheetId;
  const q2 = (started.body?.questions || [])[0];
  r = await api('POST', `/api/training/sheets/${sheet2}/submit`, { token: empT, body: { answers: [{ questionId: q2.id, chosen: 'A' }] } });
  ok('🔴 关掉后不回答案（rightLabels 为 null，不是空串）',
    r.body?.detail?.[0]?.rightLabels === null && r.body?.answerHidden === true,
    JSON.stringify(r.body?.detail));
  ok('  但成绩与每题对错照给（那是成绩单，不是答案）',
    r.body?.score === 10 && r.body?.detail?.[0]?.correct === true, JSON.stringify({ s: r.body?.score, d: r.body?.detail }));
  await api('DELETE', '/api/admin/apps/training', { token: admin });

  /* ============================================================
   * 四：应用数据（概览 / 明细 / 导出 / 三步清理）
   * ============================================================ */
  console.log('\n【四】应用数据（概览 / 明细 / 导出 / 清理）');

  r = await api('GET', '/api/admin/apps/attendance', { token: admin });
  ok('抽屉接口回四块（app / guard / data / icons）',
    !!r.body?.app && !!r.body?.guard && !!r.body?.data && Array.isArray(r.body?.icons),
    JSON.stringify(Object.keys(r.body || {})));
  const metrics = r.body?.data?.metrics || [];
  ok('概览有指标且不是全 0（说明真的在查库）',
    metrics.length >= 4 && metrics.some((m) => m.key === 'total' && m.value > 0),
    JSON.stringify(metrics));
  ok('guard 块说清了"停用会关掉哪些接口"',
    Array.isArray(r.body?.guard?.items) && r.body.guard.items.length >= 1
    && r.body.guard.items[0].paths.length >= 4,
    JSON.stringify(r.body?.guard));
  // 反向断言：不能所有规则都标成 consoleOnly（那就等于谁都不拦）
  ok('反向：考勤打卡的规则**不是** consoleOnly（否则等于没拦）',
    r.body.guard.items.every((x) => x.consoleOnly !== true),
    JSON.stringify(r.body?.guard?.items?.map((x) => x.consoleOnly)));
  r = await api('GET', '/api/admin/apps/att_admin', { token: admin });
  ok('🔴 考勤记录的 guard 标出了"管理台不受影响"的那条',
    r.body?.guard?.items?.some((x) => x.consoleOnly === true),
    JSON.stringify(r.body?.guard?.items?.map((x) => x.consoleOnly)));
  r = await api('GET', '/api/admin/apps/attendance', { token: admin });
  ok('data 块说明了共用接口不随应用停用而关闭', !!r.body?.data?.shared, JSON.stringify(Object.keys(r.body?.data?.shared || {})));
  ok('探针不动数据：抽屉接口是只读的（再拉一次指标不变）',
    JSON.stringify((await api('GET', '/api/admin/apps/attendance', { token: admin })).body?.data?.metrics) === JSON.stringify(metrics),
    '两次指标不一致');

  // 纯离线应用要诚实说明"没有数据"
  r = await api('GET', '/api/admin/apps/stocktake', { token: admin });
  ok('纯离线应用（扫码枪）明说"服务端没有它的数据"',
    r.body?.data?.localOnly === true && /纯离线/.test(r.body?.data?.localOnlyNote || '')
    && (r.body?.data?.sources || []).length === 0,
    JSON.stringify({ l: r.body?.data?.localOnly, n: r.body?.data?.localOnlyNote?.slice(0, 40) }));
  ok('  且 guard 块也说明只有入口会被隐藏',
    r.body?.guard?.localOnly === true, JSON.stringify(r.body?.guard));

  // 明细
  r = await api('GET', '/api/admin/apps/attendance/data?source=records&pageSize=10', { token: admin });
  ok('明细：分页信封（items/total/page/pageSize）',
    Array.isArray(r.body?.items) && r.body.total >= 1 && r.body.page === 1 && r.body.pageSize === 10,
    JSON.stringify({ t: r.body?.total, p: r.body?.page }));
  ok('  明细带列定义（界面据此渲染表头）', (r.body?.columns || []).length >= 6, JSON.stringify(r.body?.columns?.length));
  ok('🔴 行里带中文卡次名，不是裸 out1（且 4 次卡标出了第几段）',
    typeof r.body.items[0]?.punch === 'string'
    && /^第[12]段\s*(上班|下班)$/.test(r.body.items[0].punch),
    JSON.stringify(r.body?.items?.[0]?.punch));

  // 关键词筛选
  r = await api('GET', `/api/admin/apps/attendance/data?source=records&q=${encodeURIComponent('张三')}`, { token: admin });
  ok('明细：关键词筛选生效', r.body?.total >= 1 && r.body.items.every((x) => /张三/.test(x.who)),
    JSON.stringify({ t: r.body?.total, w: r.body?.items?.map((x) => x.who) }));
  r = await api('GET', '/api/admin/apps/attendance/data?source=records&q=' + encodeURIComponent('不存在的关键词zzz'), { token: admin });
  ok('反向：筛不中时 total 为 0（不是"忽略筛选返回全部"）', r.body?.total === 0, JSON.stringify(r.body?.total));

  // 时间窗：数据源有时间列 → timeFiltered=true，且"只有未来"应筛掉全部
  ok('明细：有时间列的数据源 timeFiltered=true', r.body?.timeFiltered === true, JSON.stringify(r.body?.timeFiltered));
  r = await api('GET', `/api/admin/apps/attendance/data?source=records&allTime=1`, { token: admin });
  const allTotal = r.body?.total;
  r = await api('GET', '/api/admin/apps/attendance/data?source=records&from=' + (Date.now() + 86400000), { token: admin });
  ok('🔴 时间窗真的在过滤（from=明天 → 0 条）', r.body?.total === 0 && allTotal > 0,
    JSON.stringify({ future: r.body?.total, all: allTotal }));
  r = await api('GET', '/api/admin/apps/work_org/data?source=depts', { token: admin });
  ok('反向：没有时间列的数据源 timeFiltered=false（不受时间筛选影响）',
    r.body?.timeFiltered === false && r.body?.total >= 1, JSON.stringify({ t: r.body?.timeFiltered, n: r.body?.total }));

  // 导出 CSV
  const csvRes = await fetch(BASE + '/api/admin/apps/work_org/export?source=members&allTime=1',
    { headers: { Authorization: 'Bearer ' + admin, 'X-Console': '1' } });
  // ⚠️ BOM 必须看**原始字节**：`res.text()` 的 UTF-8 解码会顺手把 U+FEFF 吃掉，
  //    拿解码后的字符串判 BOM 只会得出"没有 BOM"这个错误结论
  //    （本测试第一版就是这么写的，白红了一条）。
  const csvBytes = new Uint8Array(await csvRes.arrayBuffer());
  const csvText = Buffer.from(csvBytes).toString('utf8').replace(/^\uFEFF/, '');
  ok('导出：Content-Type 是 text/csv', /text\/csv/.test(csvRes.headers.get('content-type') || ''),
    csvRes.headers.get('content-type'));
  ok('导出：带 UTF-8 BOM（不带的话 Excel 打开中文全是乱码）',
    csvBytes[0] === 0xEF && csvBytes[1] === 0xBB && csvBytes[2] === 0xBF,
    [...csvBytes.slice(0, 3)].join(','));
  ok('导出：表头是中文列名', csvText.includes('工号') && csvText.includes('姓名'), csvText.slice(0, 120));
  ok('🔴 导出：13 位纯数字工号写成 Excel 文本（否则变科学计数法）',
    csvText.includes(`"=""${LONG_NO}"""`),
    csvText.split('\r\n').find((l) => l.includes(LONG_NO)) || '(没找到这一行)');
  ok('导出：行数对得上（表头 + 员工行）',
    csvText.trim().split('\r\n').length === 1 + 2, String(csvText.trim().split('\r\n').length));
  // 空结果：导出必须给一行说明，而不是一个"看着坏了"的空文件
  const csvEmpty = await (await fetch(BASE + '/api/admin/apps/attendance/export?source=records&from=' + (Date.now() + 86400000),
    { headers: { Authorization: 'Bearer ' + admin } })).text();
  ok('导出：空结果写一行"（当前筛选条件下没有任何数据）"', /没有任何数据/.test(csvEmpty),
    csvEmpty.replace(/^\uFEFF/, '').slice(0, 100));
  // 反向断言：上一条不能是恒真 —— 有数据时**不该**出现这句
  ok('反向：有数据时不会出现"没有任何数据"那句', !/没有任何数据/.test(csvText),
    csvText.slice(-80));

  // 清理：三步安全模型
  r = await api('GET', '/api/admin/apps/attendance', { token: admin });
  const beforeTotal = (r.body?.data?.metrics || []).find((m) => m.key === 'total')?.value;
  ok('清理前基线：打卡流水 > 0', beforeTotal >= 2, String(beforeTotal));

  // 第一步：dryRun
  r = await api('POST', '/api/admin/apps/attendance/purge',
    { token: admin, body: { source: 'records', allTime: 1, dryRun: true } });
  const expect = r.body?.count;
  ok('清理第 1 步：dry-run 只算条数 + 给样例，不删',
    r.body?.dryRun === true && expect >= 2 && (r.body?.sample || []).length >= 1,
    JSON.stringify({ c: expect, s: r.body?.sample?.length }));
  r = await api('GET', '/api/admin/apps/attendance', { token: admin });
  ok('  且数据真的没动', (r.body?.data?.metrics || []).find((m) => m.key === 'total')?.value === beforeTotal,
    'dry-run 竟然改了数据');

  // 反向断言：条数对不上必须中止
  r = await api('POST', '/api/admin/apps/attendance/purge',
    { token: admin, body: { source: 'records', allTime: 1, dryRun: false, expectCount: expect + 7 } });
  ok('🔴 清理第 3 步：条数对不上 → 409 中止（防"看着 300 条实际删 305 条"）',
    r.status === 409 && r.body?.code === 'count_changed', JSON.stringify(r.body).slice(0, 160));
  r = await api('POST', '/api/admin/apps/attendance/purge',
    { token: admin, body: { source: 'records', allTime: 1, dryRun: false } });
  ok('🔴 不带确认条数 → 400（必须先预览）',
    r.status === 400 && r.body?.code === 'need_confirm', JSON.stringify(r.body));

  // 第三步：正确执行
  r = await api('POST', '/api/admin/apps/attendance/purge',
    { token: admin, body: { source: 'records', allTime: 1, dryRun: false, expectCount: expect } });
  ok('清理第 3 步：执行成功并落备份',
    r.status === 200 && r.body?.deleted === expect && !!r.body?.backup,
    JSON.stringify({ d: r.body?.deleted, b: r.body?.backup }));
  const backupPath = path.join(DATA_DIR, 'purge-backup', r.body?.backup || '');
  ok('  备份文件真的落到了盘上（不是只回了个名字）', fs.existsSync(backupPath), backupPath);
  if (fs.existsSync(backupPath)) {
    const bk = JSON.parse(fs.readFileSync(backupPath, 'utf8'));
    ok('  备份内容含被删的行 + 元信息',
      bk.count === expect && bk.rows.length === expect && bk.app === 'attendance' && bk.truncated === false,
      JSON.stringify({ c: bk.count, n: bk.rows?.length, t: bk.truncated }));
  }
  r = await api('GET', '/api/admin/apps/attendance', { token: admin });
  ok('  删完指标归零（数据真的删掉了）',
    (r.body?.data?.metrics || []).find((m) => m.key === 'total')?.value === 0,
    JSON.stringify((r.body?.data?.metrics || []).map((m) => [m.key, m.value])));

  // 反向：不可清理的数据源必须明确拒绝（并说清为什么）
  r = await api('POST', '/api/admin/apps/inventory/purge',
    { token: admin, body: { source: 'sheets', dryRun: true } });
  ok('反向：只读数据源不允许清理', r.status === 400 && /不支持清理/.test(r.body?.error || ''), JSON.stringify(r.body));
  r = await api('GET', '/api/admin/apps/inventory', { token: admin });
  ok('  只读原因写给了管理台（不是无理由拒绝）',
    /凭据|复原/.test(r.body?.data?.readOnlyReason || ''), r.body?.data?.readOnlyReason);
  ok('  只读应用的可清理清单为空', (r.body?.data?.purgeables || []).length === 0,
    JSON.stringify(r.body?.data?.purgeables));
  ok('  可清理应用的可清理清单非空（说明这个字段有鉴别力）',
    ((await api('GET', '/api/admin/apps/attendance', { token: admin })).body?.data?.purgeables || []).length === 1,
    '考勤打卡应恰好有 1 个可清理来源');

  /* ============================================================
   * 五：鉴权
   * ============================================================ */
  console.log('\n【五】鉴权');
  const endpoints = [
    ['GET', `/api/admin/apps`],
    ['GET', `/api/admin/apps/attendance`],
    ['GET', `/api/admin/apps/attendance/data?source=records`],
    ['GET', `/api/admin/apps/attendance/export?source=records`],
  ];
  for (const [m, p] of endpoints) {
    r = await api(m, p, { token: empT });
    ok(`员工访问 ${m} ${p.split('?')[0]} → 403`, r.status === 403, `实际 ${r.status}`);
    r = await api(m, p);
    ok(`  未登录 → 401`, r.status === 401, `实际 ${r.status}`);
  }
  r = await api('PATCH', '/api/admin/apps/attendance', { token: empT, body: { disabled: true } });
  ok('员工改应用设置 → 403', r.status === 403, `实际 ${r.status}`);
  r = await api('POST', '/api/admin/apps/attendance/purge', { token: empT, body: { source: 'records', dryRun: true } });
  ok('员工调清理接口 → 403', r.status === 403, `实际 ${r.status}`);
  // 反向：员工的越权尝试不能已经改掉了东西
  r = await api('GET', '/api/admin/apps', { token: admin });
  ok('  且越权请求没有产生副作用（考勤打卡仍在）',
    r.body?.builtin?.find((a) => a.id === 'attendance')?.disabled === false,
    JSON.stringify(r.body?.builtin?.find((a) => a.id === 'attendance')?.disabled));

  /* ---------------- 收尾 ---------------- */
  console.log(`\n${failed ? '\u2717' : '\u2713'} 通过 ${passed} / ${passed + failed}`);
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
