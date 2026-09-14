'use strict';

/**
 * 全站统一的列表分页 / 筛选约定（设计见 SPEC-消息与文件管理.md §2）。
 *
 * 为什么要有这个文件：以前每个列表接口各写一套写死的 LIMIT，没有 offset、
 * 没有总数，数据一多就**静默截断** —— 管理员看到"最近 500 条"，界面上却
 * 没有任何东西告诉他被截断了，"以为没有"和"真的没有"分不出来。
 * 现在把参数解析、护栏、时间窗、响应形状收敛到一处，避免每个页面各写一套口径。
 */

const MAX_PAGE_SIZE = 200;        // pageSize 硬上限（超过截断，不报错）
const DEFAULT_PAGE_SIZE = 50;
const DEFAULT_WINDOW_DAYS = 30;   // 不传时间范围时默认只看最近 30 天
const DAY_MS = 86400000;

/**
 * 时间参数转毫秒时间戳。
 * 三种返回值语义不同，调用方必须区分：
 *   null → 没传（后续按"默认 30 天窗"或"不限"处理）
 *   NaN  → 传了但不是合法时间戳（要 400）
 *   数字 → 正常值
 */
function toMs(raw) {
  if (raw === undefined || raw === null || raw === '') return null;
  const n = Number(raw);
  if (!Number.isFinite(n) || n < 0) return NaN;
  return Math.floor(n);
}

/** 整数解析：失败或非正数一律回落，不抛错 */
function toPositiveInt(raw, fallback) {
  const n = Number.parseInt(raw, 10);
  if (!Number.isFinite(n) || n < 1) return fallback;
  return n;
}

/**
 * 解析列表请求的通用参数。
 *
 * 返回 `{ error }` 表示参数自相矛盾（路由应回 400）；否则返回：
 *   { page, pageSize, offset, from, to, allTime, sortDir }
 * 其中 `from`/`to` 是**最终生效**的时间边界，null 表示该端不限。
 *
 * `from`/`to` 语义（不定义清楚每个实现者会各写一套）：
 *   from + to → 闭区间 [from, to]
 *   只传 from → 从 from 到现在
 *   只传 to   → 从最早到 to
 *   都不传    → 最近 30 天（不是全部！）
 *   allTime=1 → 不限时间（前端「全部时间」走这个，不靠"不传"表达）
 */
function parseList(query, opts = {}) {
  const q = query || {};
  const defSize = toPositiveInt(opts.defaultPageSize, DEFAULT_PAGE_SIZE);

  // page 归一到 >=1：前端状态没初始化好时传 0/负数/乱码是常态，容错优先
  const page = toPositiveInt(q.page, 1);

  // pageSize 超上限**截断而不是报错**：报错会让整个列表页挂掉，
  // 而超限往往是前端传参失误，帮它兜住更合适
  let pageSize = toPositiveInt(q.pageSize, defSize);
  if (pageSize > MAX_PAGE_SIZE) pageSize = MAX_PAGE_SIZE;

  const fromRaw = toMs(q.from);
  const toRaw = toMs(q.to);
  if (Number.isNaN(fromRaw)) return { error: 'from 不是合法的时间戳' };
  if (Number.isNaN(toRaw)) return { error: 'to 不是合法的时间戳' };
  // 这一条与 pageSize 相反，是**报错**：矛盾条件来自用户操作，
  // 必须明确告诉他，而不是悄悄替他改一个边界
  if (fromRaw !== null && toRaw !== null && fromRaw > toRaw) {
    return { error: 'from 不能晚于 to' };
  }

  const allTime = String(q.allTime == null ? '' : q.allTime) === '1';
  let from = fromRaw;
  let to = toRaw;
  if (!allTime && from === null && to === null) {
    from = (opts.now || Date.now()) - (opts.windowDays || DEFAULT_WINDOW_DAYS) * DAY_MS;
  }

  return {
    page,
    pageSize,
    offset: (page - 1) * pageSize,
    from,
    to,
    allTime,
    sortDir: String(q.sort || '').toLowerCase() === 'asc' ? 'ASC' : 'DESC',
  };
}

/**
 * 把时间条件追加到 where 数组（改 params 数组）。
 * 调用方拿到的是可直接拼进 SQL 的条件片段。
 */
function timeWhere(list, params, column = 'created_at') {
  const parts = [];
  if (list.from !== null) { parts.push(`${column} >= ?`); params.push(list.from); }
  if (list.to !== null) { parts.push(`${column} <= ?`); params.push(list.to); }
  return parts;
}

/**
 * 统一响应结构。`total` 是**当前筛选条件下**的总数 —— 分页器基于它，
 * 所以界面上永远知道"一共翻得到多少"。
 */
function envelope(list, items, total) {
  return { items, total, page: list.page, pageSize: list.pageSize };
}

/** 转义 LIKE 通配符：不转义的话输入 % 就变成"匹配全部"、_ 匹配任意单字符 */
function escapeLike(s) {
  return String(s == null ? '' : s).replace(/[\\%_]/g, (ch) => '\\' + ch);
}

/** 包成 `%关键词%` 参数（配合 `LIKE ? ESCAPE '\'` 使用） */
function likeParam(q) {
  return '%' + escapeLike(q) + '%';
}

module.exports = {
  MAX_PAGE_SIZE,
  DEFAULT_PAGE_SIZE,
  DEFAULT_WINDOW_DAYS,
  DAY_MS,
  parseList,
  timeWhere,
  envelope,
  escapeLike,
  likeParam,
};
