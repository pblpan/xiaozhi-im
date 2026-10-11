'use strict';

/**
 * 应用停用门禁（「整应用停用」的后端那一半）
 *
 * ─────────────────────────────────────────────────────────────
 * 为什么必须拦后端，不能只让管理台把入口藏起来
 * ─────────────────────────────────────────────────────────────
 * 只藏入口的话，会出现最难查的一类状态：
 *   · 手机上入口不见了，但接口还通 —— 老客户端/缓存页面仍能打卡、仍能上传；
 *   · 管理员以为"停用了"，报表里却继续冒出新数据；
 *   · 排障时两边都"看着正常"：入口确实没了（前端的活干了），数据也确实在动（后端没拦）。
 * 所以停用是一个**后端口径**：入口隐藏只是它的视觉表现。
 *
 * ─────────────────────────────────────────────────────────────
 * 三件必须做对的事
 * ─────────────────────────────────────────────────────────────
 * 1. **路径归属要逐条写清**，不能"按前缀一把抓"。三个考勤应用（考勤打卡 / 我的申请 /
 *    考勤记录）共用 `/api/attendance` 与 `/api/admin/attendance` 两棵路由树：
 *    按前缀拦会把「停用我的申请」误伤成"打卡也不能用了"。
 *
 * 2. **管理台自己不能被自己的规则拦死**。管理台的「考勤管理」页要调
 *    `/api/admin/attendance/*`，而客户端「考勤记录」应用调的是同一批路径 ——
 *    同一棵路由树，两拨调用方。用 `X-Console: 1`（管理台 axios 统一带）区分：
 *    带这个头的放行。**这不是权限，是区分**：那些接口本来就要 admin 身份，
 *    员工伪造这个头也拿不到任何东西（下面那层仍会回 403 forbidden）。
 *
 * 3. **没有接口的应用要显式登记**（LOCAL_ONLY），否则下一个人会以为"忘了拦"。
 *    「扫码枪」纯离线，服务端本来就没有它的接口 —— 停用它只能藏入口，
 *    这是个诚实的答案，但要写下来。
 */

const appoverrides = require('./appoverrides');
const appregistry = require('./apps');

/**
 * 路由归属表。每一条都必须有：
 *   app    内置应用 id（与 apps.js / appoverrides.js 一致）
 *   scope  给管理员看的"这一段是什么"
 *   paths  **人的可读清单**（管理台显示"停用后会关掉哪些接口"）
 *   test   真正的匹配函数（正则）
 *   exempt 例外（同属这条路径但属于管理台/别人，不该被拦）
 *   consoleOnly  true = 只拦非管理台请求（同一路径两拨调用方的场景）
 *
 * 🔴 `paths` 与 `test` 必须同步：server/test/apps_admin_e2e.js 里有一条断言
 *    逐条把 paths 喂给 test，对不上就报红 —— 否则清单迟早变成一段过期的文案。
 */
const RULES = [
  {
    app: 'attendance',
    scope: '员工端打卡',
    label: '今日打卡计划 / 打卡 / 我的考勤 / 我的卡流水',
    paths: [
      'GET  /api/attendance/today',
      'POST /api/attendance/clock',
      'GET  /api/attendance/my',
      'GET  /api/attendance/records',
    ],
    test: (p) => /^\/api\/attendance\/(today|clock|my|records)$/.test(p),
  },
  {
    app: 'my_requests',
    scope: '员工端申请',
    label: '申请列表 / 提交申请 / 撤销申请',
    paths: [
      'GET  /api/attendance/requests',
      'POST /api/attendance/requests',
      'POST /api/attendance/requests/:id/cancel',
    ],
    test: (p) => /^\/api\/attendance\/requests(\/|$)/.test(p),
  },
  {
    app: 'att_admin',
    scope: '主管看板（客户端「考勤记录」应用调的那批）',
    label: '今日出勤看板 / 打卡明细 / 审批 / 代补卡',
    paths: [
      'GET    /api/admin/attendance/overview',
      'GET    /api/admin/attendance/records',
      'POST   /api/admin/attendance/records',
      'DELETE /api/admin/attendance/records/:id',
      'GET    /api/admin/attendance/requests',
      'POST   /api/admin/attendance/requests/:id/review',
    ],
    test: (p) => /^\/api\/admin\/attendance\//.test(p),
    // 管理台「考勤管理」页调的是同一批路径 —— 它不该被客户端应用的停用连坐
    consoleOnly: true,
  },
  {
    app: 'work_org',
    scope: '员工端通讯录',
    label: '我的组织（部门 / 岗位 / 同事名单）',
    paths: ['GET  /api/orgs/my'],
    test: (p) => p === '/api/orgs/my',
  },
  {
    app: 'inventory',
    scope: '盘点单据',
    label: '点位 / 库位货架位 / 单据 / 明细上传与差异',
    paths: [
      'ANY  /api/stocktake/*',
      'ANY  /api/location/*',
    ],
    test: (p) => /^\/api\/(stocktake|location)\//.test(p),
  },
  {
    app: 'inventory',
    scope: '商品档案取数（管理台「商品档案」页共用同一批接口）',
    label: '拉取商品档案 / 档案条数',
    paths: ['GET  /api/master', 'GET  /api/master/count'],
    test: (p) => p === '/api/master' || p === '/api/master/count',
    consoleOnly: true,
  },
  {
    // 减货单接口。🔴 2026-10-04 起归 **inventory** 名下：库房减货不再是有
    //   独立图标的内置应用（工作台图标撤了，功能从盘点页进 —— 龙哥定的），
    //   这批接口跟着盘点走：停用「盘点」= 减货上传/对账一并拦下。
    //   员工端上传、管理台列表/详情/对账**共用这一批接口**，所以不设 consoleOnly：
    //   设了的话员工就传不上来了，而"传不上来"在现场只会表现为"点了没反应"。
    app: 'inventory',
    scope: '减货单据（盘点页内的库房减货：员工上传 / 管理台对账）',
    label: '减货单上传 / 列表 / 明细 / 按商品对账',
    paths: [
      'POST /api/deduct/sheet/:no/upload',
      'GET  /api/deduct/sheets',
      'GET  /api/deduct/sheet/:no',
      'GET  /api/deduct/reconcile',
    ],
    test: (p) => /^\/api\/deduct\//.test(p),
  },
  {
    app: 'training',
    scope: '学员端',
    label: '课程 / 章节 / 看视频记进度 / 考试与交卷',
    paths: [
      'GET    /api/training/courses',
      'GET    /api/training/courses/:id',
      'POST   /api/training/courses/:id/join',
      'DELETE /api/training/courses/:id/join',
      'POST   /api/training/progress',
      'GET    /api/training/lessons/:id/media',
      'POST   /api/training/exams/:id/start',
      'POST   /api/training/sheets/:id/submit',
      'GET    /api/training/sheets/:id',
    ],
    test: (p) => /^\/api\/training\//.test(p),
    // 管理端在自己的前缀下（/api/training/admin/*），本来就要求 admin 身份，
    // 按路径排除即可，不需要再看头
    exempt: [/^\/api\/training\/admin\//],
  },
  {
    app: 'assistant',
    scope: '智能助手问答',
    label: '问一句（使用问题问答）',
    paths: [
      'POST   /api/assistant/ask',
    ],
    test: (p) => /^\/api\/assistant\/ask$/.test(p),
    // 管理台的配置/试问接口在 /api/admin/assistant/*（要求 admin 身份），
    // 停用员工问答不能把管理员"重新启用"的入口也拦死
    exempt: [/^\/api\/admin\/assistant\//],
  },
];

/**
 * 纯离线应用：服务端没有它的接口，"停用"只能作用于入口。
 * 显式写下来，是为了让"没有 RULES"这件事看起来是**决定**而不是**遗漏**。
 */
const LOCAL_ONLY = {
  stocktake: '「扫码枪」纯离线运行：扫码数据只存在手机上，服务端没有任何它的接口。'
    + '停用后客户端不再显示入口，但手机上已经采集的数据还在，导出照旧可用。',
  // 🔴 replenish（补货）2026-10-04 起不再注册：功能从盘点页进（工作台图标已撤）。
  simple_stocktake: '「简易盘点」也是**纯离线**：待盘清单（simple_task / simple_item）、'
    + '节点（stocktake_sheet，sheet_type=simple）和扫码明细全在手机本地，'
    + '服务端没有它的任何接口。停用只影响入口，已导的清单与盘过的数据、导出照旧可用。',
  price_tag: '「价签打印」是纯离线里最彻底的一个：它**不打也不存任何数据** —— '
    + '扫到什么码、打了多少钱，全在手机上过一遍就印出去了，服务端既没有接口也没有记录。'
    + '所以停用它只影响入口，不影响任何别处的数据。',
};

/**
 * 共用接口：被多个应用/管理台同时使用，不随单个应用停用而关闭。
 * 同样必须显式登记，否则会被当成"漏拦"。
 */
const SHARED = {
  '/api/approval': '通用审批中心（盘点单审批走它，后面别的业务也会挂上来）—— 属于平台能力，不归某一个应用。',
  '/api/orgs/depts': '部门管理：管理台「组织机构」页在用，员工端不调它。',
  '/api/orgs/positions': '岗位管理：同上。',
  '/api/files': '文件服务：消息、头像、培训课件共用。',
};

/** 判定请求是否来自管理台（由 admin/src/api.js 统一加头） */
function isConsole(req) {
  return String(req.get ? req.get('x-console') : '') === '1';
}

/** 找出这个路径归哪个应用管（没命中返回 null） */
function resolveRule(pathname) {
  for (const r of RULES) {
    if (!r.test(pathname)) continue;
    if ((r.exempt || []).some((x) => x.test(pathname))) continue;
    return r;
  }
  return null;
}

/** 管理台用：把"停用这个应用会关掉什么"讲清楚 */
function rulesOf(appId) {
  const mine = RULES.filter((r) => r.app === appId);
  if (LOCAL_ONLY[appId]) {
    return { appId, localOnly: true, note: LOCAL_ONLY[appId], items: [] };
  }
  return {
    appId,
    localOnly: false,
    note: mine.length
      ? '停用后下列接口一律回 403（code=app_disabled），不只是隐藏入口。'
      : '这个应用没有登记服务端接口 —— 若它确实有，说明注册表漏了一条，请补上。',
    items: mine.map((r) => ({
      scope: r.scope,
      label: r.label,
      paths: r.paths,
      consoleOnly: !!r.consoleOnly,
    })),
  };
}

/**
 * Express 中间件。**挂在所有业务路由之前**（见 index.js）。
 * 注意用 `app.use(fn)` 不挂前缀，这样 req.path 是完整路径（含 /api），
 * 规则里写的路径就是"浏览器里看到的那条"，两边对照不用脑内转换。
 */
function middleware(req, res, next) {
  // CORS 预检不带业务语义，拦下来会让浏览器报"跨域失败"这种误导性错误
  if (req.method === 'OPTIONS') return next();
  const rule = resolveRule(req.path);
  if (!rule) return next();
  if (rule.consoleOnly && isConsole(req)) return next();
  if (!appoverrides.isDisabled(rule.app)) return next();

  const app = appregistry.BUILTIN_APPS.find((a) => a.id === rule.app);
  res.status(403).json({
    error: `「${app ? app.title : rule.app}」已被管理员停用`,
    code: 'app_disabled',
    app: rule.app,
  });
}

module.exports = { RULES, LOCAL_ONLY, SHARED, resolveRule, rulesOf, isConsole, middleware };
