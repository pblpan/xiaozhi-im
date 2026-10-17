'use strict';

/**
 * 动态模块的「本服务器数据源」
 *   GET /api/hooks/local/<应用>/<数据源>
 *
 * ─────────────────────────────────────────────────────────────
 * 它解决的是"光有界面没有内容"
 * ─────────────────────────────────────────────────────────────
 * 动态模块的 list / table / chart 三种组件，天生只有 `dataPath`（如 `data.rows`）
 * 这个**指向**，没有生产者。之前唯一的生产者是第三期的「上游接口」：
 * 管理员得先在服务器上登记一个外部 HTTP 桥接，再在模块里手填
 * `/api/hooks/up/<name>/<子路径>`，最后还得猜上游返回的字段名去拼表格列。
 *
 * 但绝大多数时候，数据**就在本服务器里** —— 商档、盘点单、课程、部门名册，
 * 全是本库的现成数据。为了在工作台上看它们，先去搭一个外部桥接，
 * 是让人绕地球一圈去拿床头柜上的东西。
 *
 * 所以这一层直接把本库的数据喂给动态模块，接口形状与上游**完全一致**
 * （`{ ok, data }`），客户端的模块渲染器一个字都不用改。
 *
 * ─────────────────────────────────────────────────────────────
 * 安全：默认最严，逐个放行
 * ─────────────────────────────────────────────────────────────
 * 本库里有打卡坐标、请假理由、考试成绩、采购进价。这些绝不能因为
 * "有人在工作台上建了个模块"就变成全员可读。
 *
 * 所以能不能取，不看路径能不能猜到，而看**数据源自己声明过没有**
 * （appdata.js 里数据源上的 `module` 字段）：
 *   · 没声明              → 404，且明说是"没对动态模块开放"
 *   · module:'admin'      → 只有管理员取得到，普通用户 403
 *   · module:'all'        → 所有已登录用户
 *
 * 🔴 默认必须是"没声明 = 不给"。反过来（默认都给）的后果是：
 *    有人建了一个「今日出勤」模块想看"谁没打卡"，全公司就都能看到
 *    每个人的打卡坐标了 —— 而建模块的人根本没意识到自己做了什么。
 */

const appdata = require('./appdata');
const apps = require('./apps');
const paging = require('./paging');

/**
 * 一次最多取多少行。
 *
 * 🔴 必须限：模块是手机上一屏看完的东西，一次塞 2000 行过去，
 *    轻则列表卡死，重则 WebRTC/WS 那边的帧被堵住。
 *    200 行足够看"最近的情况"，要全量请走管理台的导出。
 */
const LOCAL_ROWS_MAX = 200;

/** 应用 id → 中文标题（管理台下拉里要显示"盘点"而不是 inventory） */
const APP_TITLES = Object.create(null);
for (const a of apps.BUILTIN_APPS) APP_TITLES[a.id] = a.title;
// 「排班」不是内置应用（没有工作台入口），但它的数据源要给自定义模块用，
// 下拉里必须显示"排班"而不是裸 id —— 否则管理员不知道 duty 是个啥
APP_TITLES.duty = '排班';

function findSource(appId, key) {
  const def = appdata.APPS[appId];
  if (!def) return null;
  return (def.sources || []).find((s) => s.key === key) || null;
}

/** 这个数据源对动态模块开放吗？对当前角色开放吗？ */
function canUse(src, role) {
  if (!src || !src.module) return false;
  if (src.module === 'admin') return role === 'admin';
  return true;
}

/**
 * 这个数据源**可写**吗？谁能写？
 *
 * 与读权限分开两道门，因为"能看"和"能改"从来不是一回事：
 * 排班表全员可看（公示），但只有管理员能改（否则全公司互相改班表）。
 * 数据源不声明 write = 只读 —— 和读一样默认最严。
 */
function canWrite(src, role) {
  if (!src || !src.write) return false;
  if (src.write === 'admin') return role === 'admin';
  if (src.write === 'all') return true;
  return false;
}

/** 当前角色能选的数据源清单（管理台下拉用） */
function sourcesFor(role) {
  const out = [];
  for (const appId of Object.keys(appdata.APPS)) {
    const def = appdata.APPS[appId];
    for (const s of (def.sources || [])) {
      if (!canUse(s, role)) continue;
      out.push({
        appId,
        appTitle: APP_TITLES[appId] || appId,
        key: s.key,
        name: s.name,
        desc: s.desc || '',
        path: `/api/hooks/local/${appId}/${s.key}`,
        // 列一起给：管理台选了数据源就能一键把表格列填好，
        // 不用管理员对着字段名一个个敲（敲错一个字母就是一列空白）
        columns: (s.columns || []).map((c) => ({
          key: c.key,
          label: c.label,
          width: c.width || 120,
        })),
      });
    }
  }
  return out;
}

/**
 * 取一个数据源的行。
 * 返回 { rows, total } 或 { error, code }。
 */
function rows(appId, key, role, query) {
  const src = findSource(appId, key);
  if (!src) {
    return { error: `没有这个数据源：${appId}/${key}`, code: 404 };
  }
  if (!canUse(src, role)) {
    return {
      error: `数据源「${src.name}」没有对动态模块开放（它含经营数据，只有管理员可见）`,
      code: 403,
    };
  }

  // 🔴 默认**不按时间过滤**（allTime=1）。
  //    paging.parseList 的默认行为是"最近 N 天"，那是给**流水**设计的；
  //    但商档、部门、岗位这类**档案型**数据没有"最近"的概念 ——
  //    套上默认时间窗的结果就是"上周同步的商档今天全看不见了"，
  //    而界面上只会显示"没有数据"，谁也想不到是时间窗在作怪。
  const q = Object.assign({}, query || {}, {
    allTime: (query && query.allTime != null) ? query.allTime : '1',
  });

  const list = paging.parseList(q, { defaultPageSize: 100 });
  if (list.error) return { error: list.error, code: 400 };

  // 上限由这里钉死，不指望调用方自觉
  if (list.pageSize > LOCAL_ROWS_MAX) list.pageSize = LOCAL_ROWS_MAX;

  // query 原样带给 detail：排班这种按文本日期开窗的源要读 ?day=
  const r = appdata.detail(appId, key, list, q.q, q);
  if (r.error) return { error: r.error, code: 400 };

  return { rows: r.items || [], total: Number(r.total) || 0, truncated: r.total > (r.items || []).length };
}

/**
 * 写一个数据源（表单即录入的那一半）。
 *
 * 流程与读完全对称：先找源 → 再查读权限 → 再查写权限 → 最后才调
 * 数据源自己的 writeHandler。**校验不在这一层**：各引擎（duty.save 等）
 * 自己校验输入，这里只判"这个人能不能碰这个源"。
 *
 * 返回 { ok, ... } 或 { error, code }。
 */
function write(appId, key, role, uid, body) {
  const src = findSource(appId, key);
  if (!src) {
    return { error: `没有这个数据源：${appId}/${key}`, code: 404 };
  }
  if (!canUse(src, role)) {
    return {
      error: `数据源「${src.name}」没有对动态模块开放（它含经营数据，只有管理员可见）`,
      code: 403,
    };
  }
  if (!src.writeHandler) {
    return { error: `数据源「${src.name}」是只读的，不能往里写`, code: 405 };
  }
  if (!canWrite(src, role)) {
    // 403 而不是 405：这个人就是不该改排班，不是"这个功能没做"
    return { error: `数据源「${src.name}」只有管理员能修改`, code: 403 };
  }
  try {
    const r = src.writeHandler({ orgId: appdata.orgIdOf(), uid, role }, body || {});
    if (r && r.error) return { error: r.error, code: r.code || 400 };
    return r || { ok: true };
  } catch (e) {
    return { error: '写入失败：' + e.message, code: 500 };
  }
}

module.exports = { sourcesFor, rows, write, LOCAL_ROWS_MAX, canUse, canWrite, findSource };
