'use strict';

/**
 * 盘点接口（inventory 模块 · P1 盘点内核的服务端部分）
 *
 * ── 🔴 先说一个容易搞混的名字 ──────────────────────────────
 * 路径是 `/api/stocktake/...`（按方案文档 docs/盘点复刻与开放接口方案-v1.md §P1
 * 的接口清单），但**这里的 stocktake 指的是「盘点」**。
 * 客户端里 id 也叫 `stocktake` 的那个模块显示名是「扫码枪」，是**另一个东西**
 * （快速扫码成账）。看到 /api/stocktake 不要以为在改扫码枪。
 * 客户端盘点模块的 id/显示名是 `inventory` / 「盘点」。
 *
 * ── 这一层在离线优先架构里的位置 ────────────────────────────
 * 盘点发生在货架之间，全程可能没网。所以**开单、扫码、算差异都在客户端本地
 * 完成**（client/lib/core/inventory_*.dart），服务端在这里只做两件事：
 *   1. 当系统记录：把客户端传上来的单据/明细/点位/货架位/绑定存下来；
 *   2. 给客户端提供点位与货架位档案（`/pull`），让它离线也能判断
 *      "这个商品属不属于当前盘点位"。
 *
 * 🔴 服务端**没有商品档案**（商档在客户端本地，从泰格上游拉的），
 *    所以 inv_scans 里存了上传时的 `account_qty`。差异集靠它算。
 *    别去 JOIN 一张不存在的 stock_master —— 那会静默返回空差异集。
 *
 * ── 幂等 ─────────────────────────────────────────────────
 * 弱网下客户端会**重传**同一批数据，这是常态而不是异常。
 * 幂等键是 `(sheet_no, phase, barcode)`（inv_scans 上的 UNIQUE），
 * 重传走 UPSERT，不会变成两行。写成两行的后果是"同一个品种被算两遍"，
 * 差异集立刻失真，而且不报错。
 */
const express = require('express');
const db = require('../db');
const { verifyToken } = require('../auth');
const { parseList, timeWhere, envelope } = require('../paging');

const router = express.Router();       // 挂 /api/stocktake
const location = express.Router();     // 挂 /api/location

const MAX_CODE = 64;
const MAX_NAME = 120;
const MAX_ROWS_PER_UPLOAD = 2000;      // 单次上传行数护栏（防止一次把内存打满）
const MAX_BIND_PER_CALL = 500;
const PHASES = [1, 2, 3];
const PHASE_LABEL = { 1: '初盘', 2: '复盘', 3: '抽盘' };

// ============================================================
// 小工具
// ============================================================

function auth(req, res, { needAdmin = false } = {}) {
  const c = verifyToken(req.headers.authorization?.replace('Bearer ', ''));
  if (!c) { res.status(401).json({ error: 'unauthorized' }); return null; }
  const u = db.prepare('SELECT id,username,nickname,role FROM users WHERE id = ?').get(c.uid);
  if (!u) { res.status(401).json({ error: 'unauthorized' }); return null; }
  if (needAdmin && u.role !== 'admin') { res.status(403).json({ error: 'forbidden' }); return null; }
  return u;
}

/**
 * 码值清洗：去空白、限制长度、**禁止斜杠与空白字符**。
 * 这些码会进单号、进导出文件名，带斜杠会把文件名当目录；
 * 中文是允许的（门店里"生鲜区"就是最自然的点位名）。
 */
function code(v, max = MAX_CODE) {
  const s = String(v == null ? '' : v).trim();
  if (!s) return null;
  if (/[\/\\\s\u0000-\u001f]/.test(s)) return null;
  return s.slice(0, max);
}

function name(v, fallback) {
  const s = String(v == null ? '' : v).trim();
  if (!s) return fallback;
  return s.slice(0, MAX_NAME);
}

function num(v) {
  if (v === null || v === undefined || v === '') return null;
  const n = Number(v);
  return Number.isFinite(n) ? n : null;
}

function zoneOf(zc) {
  return db.prepare('SELECT * FROM inv_zones WHERE zone_code = ?').get(zc) || null;
}

function sheetOf(no) {
  return db.prepare('SELECT * FROM inv_sheets WHERE sheet_no = ?').get(no) || null;
}

/** 建或更新点位。[keepLock] = 不改动已有的 locked（默认就如此）。 */
function upsertZone(zc, zn, store) {
  const now = Date.now();
  db.prepare(`
    INSERT INTO inv_zones (zone_code, zone_name, store_code, locked, created_at, updated_at)
    VALUES (?, ?, ?, 0, ?, ?)
    ON CONFLICT(zone_code) DO UPDATE SET
      zone_name = COALESCE(NULLIF(excluded.zone_name,''), inv_zones.zone_name),
      store_code = COALESCE(excluded.store_code, inv_zones.store_code),
      updated_at = excluded.updated_at
  `).run(zc, zn || null, store || null, now, now);
  return zoneOf(zc);
}

/** 该单据的全部明细（含 prev_qty / diff_qty，供界面直接显示）。 */
function scansOf(no) {
  const rows = db.prepare(`
    SELECT id, sheet_no, zone_code, phase, barcode, qty, account_qty, loc_code,
           scanned_at, uploaded_at
      FROM inv_scans
     WHERE sheet_no = ?
     ORDER BY scanned_at ASC, id ASC
  `).all(no);
  if (!rows.length) return rows;

  // 同一张单里同一条码可能扫多次 → 先在本单内汇总，再和上一阶段比
  const zc = rows[0].zone_code;
  const phase = rows[0].phase;
  const prevPhase = PHASES[PHASES.indexOf(phase) - 1];
  if (!prevPhase) return rows.map((r) => ({ ...r, prev_qty: null, diff_qty: null }));

  const prev = zonePhaseQtyMap(zc, prevPhase);
  return rows.map((r) => {
    const p = prev.get(r.barcode);
    return {
      ...r,
      prev_qty: p === undefined ? null : p,
      diff_qty: p === undefined ? null : Number(r.qty) - p,
    };
  });
}

/**
 * 一行是不是差异 —— **比上一阶段的数量**，不比账面。
 *
 * 🔴 为什么换了基准（2026-09-19）：
 *    门店的系统里根本没有可用的库存账面（泰格库所有库存表都是空表），
 *    `account_qty` 全是 0/NULL，于是差异集恒等于"全部商品"，
 *    复盘被迫把所有东西重扫一遍 —— 三遍制退化成"同一个货架扫三遍"。
 *    比优特 PG 的真实口径就是三遍平行数量互比（初盘/复盘/抽盘），这里照它来。
 *    账面数仍然保留在行里，只作参考列显示，不再参与差异判定。
 *
 * 🔴 初盘没有上一阶段可比 → `prev_qty` 为 null → **不算差异**。
 *    这条很容易写错成"没参照就是有差异"，那样初盘自己就变成一个等于全部商品
 *    的差异集，后面的复盘/抽盘会被它一起带偏。
 */
function isDiff(row) {
  if (row.prev_qty === null || row.prev_qty === undefined) return false;
  // 注意："漏盘"（上一轮有、这一轮没扫）**不会**走到这里 ——
  // 那种条码在本阶段压根没有行，行集里挑不出来，必须靠 [diffRowsOf] 补。
  return Number(row.diff_qty) !== 0;
}

/**
 * 该点位某阶段的差异行 = 数量对不上的 + **上一轮盘过这一轮没扫到的（漏盘）**。
 *
 * 🔴 为什么不能直接 `rows.filter(isDiff)`：
 *    漏盘的特征恰恰是**本阶段没有这一行** —— 从一个只含本阶段行的集合里
 *    永远挑不出"少了的那一行"。曾经 `isDiff` 里写了一句
 *    "diff_qty 为 null ⇒ 漏盘"，那是走不到的死代码（prev_qty 为 null 时
 *    先一步 return false 了），于是差异数少算、`diff_rows` 里缺漏盘项。
 *    数量错了至少还显眼，少一行是看不出来的 —— 这一类必须单独补出来。
 */
function diffRowsOf(zc, phase) {
  const prevPhase = PHASES[PHASES.indexOf(phase) - 1];
  if (!prevPhase) return []; // 初盘没有参照，不产生差异
  const rows = zonePhaseRows(zc, phase);
  const cur = new Set(rows.map((r) => r.barcode));
  const missed = [];
  for (const [code, q] of zonePhaseQtyMap(zc, prevPhase)) {
    if (cur.has(code)) continue;
    missed.push({
      barcode: code,
      qty: 0,
      account_qty: null,
      loc_code: null,
      prev_qty: q,
      diff_qty: -q, // 上一轮 q、这一轮 0
      missing: true,
    });
  }
  return [...rows.filter(isDiff), ...missed];
}

/** 某点位某阶段**按条码汇总**的数量表（barcode → qty）。 */
function zonePhaseQtyMap(zc, phase) {
  const m = new Map();
  for (const r of db.prepare(`
    SELECT barcode, SUM(qty) AS qty
      FROM inv_scans
     WHERE zone_code = ? AND phase = ?
     GROUP BY barcode
  `).all(zc, phase)) {
    m.set(r.barcode, Number(r.qty));
  }
  return m;
}

/** 给汇总行补上"上一阶段数量"和"差异"（和客户端 attachPrevDiff 同一口径）。 */
function attachPrevDiff(rows, prev) {
  return rows.map((r) => {
    const p = prev.get(r.barcode);
    return {
      ...r,
      prev_qty: p === undefined ? null : p,
      diff_qty: p === undefined ? null : Number(r.qty) - p,
    };
  });
}

/** 某点位某阶段的行（按条码汇总，跨该阶段的所有单；已补 prev_qty / diff_qty）。 */
function zonePhaseRows(zc, phase) {
  const prevPhase = PHASES[PHASES.indexOf(phase) - 1];
  const rows = db.prepare(`
    SELECT barcode,
           SUM(qty)              AS qty,
           MAX(account_qty)      AS account_qty,
           MAX(loc_code)         AS loc_code
      FROM inv_scans
     WHERE zone_code = ? AND phase = ?
     GROUP BY barcode
     ORDER BY barcode ASC
  `).all(zc, phase);
  return attachPrevDiff(rows, prevPhase ? zonePhaseQtyMap(zc, prevPhase) : new Map());
}

/**
 * 抽盘要复核的集合：数量对不上的 + **上一轮盘过这一轮没扫到的（漏盘）**。
 *
 * 🔴 漏盘必须进来：员工最容易干的事就是绕开不好盘的货架，
 *    而"少一行"在明细里根本看不出来 —— 不像数量错了那么显眼。
 *
 * 🔴 这一套也是抽盘的**准入集合**（`/upload` 里校的就是它），
 *    必须和 [reviewRowsOf] 的复核清单**同一个集合**：
 *    不齐的话会出现"复核清单上列着、上传时却被拒"，
 *    现场就变成"这几件怎么都传不上去"。
 */
function reviewSetOf(a, b) {
  const out = new Set();
  // 初盘有、复盘没扫（漏盘）或数量对不上
  for (const [code, qa] of a) {
    const qb = b.get(code);
    if (qb === undefined || qb !== qa) out.add(code);
  }
  // 复盘新扫出来的（初盘压根没盘到）—— 一样是疑问项，抽盘要看
  for (const [code] of b) {
    if (!a.has(code)) out.add(code);
  }
  return out;
}

function diffSetForNextPhase(zc, phaseA, phaseB) {
  return reviewSetOf(zonePhaseQtyMap(zc, phaseA), zonePhaseQtyMap(zc, phaseB));
}

/** 复核结论（和客户端 InventoryRules.reviewVerdict 同一套取值）。 */
const REVIEW_ALIGNED = 'aligned'; // 本遍 = 上一遍
const REVIEW_CHANGED = 'changed'; // 两边都有数，但不一致
const REVIEW_FILLED = 'filled';   // 上一遍没有、本遍补上了
const REVIEW_PENDING = 'pending'; // 本遍还没扫

function reviewVerdict(curQty, prevQty) {
  if (curQty === undefined) return REVIEW_PENDING;
  if (prevQty === undefined) return REVIEW_FILLED;
  return curQty === prevQty ? REVIEW_ALIGNED : REVIEW_CHANGED;
}

/** 复核清单的计数（一处算，界面/导出/测试共用，免得数字对不上）。 */
function tallyReview(rows) {
  let aligned = 0, changed = 0, filled = 0, pending = 0, baseMissing = 0;
  for (const r of rows) {
    switch (r.review) {
      case REVIEW_ALIGNED: aligned++; break;
      case REVIEW_CHANGED: changed++; break;
      case REVIEW_FILLED: filled++; break;
      default: pending++;
    }
    if (r.base_missing) baseMissing++;
  }
  return {
    total: rows.length,
    aligned, changed, filled, pending, base_missing: baseMissing,
    reviewed: aligned + changed + filled,
  };
}

/**
 * 抽盘的**复核清单**：前两遍（初盘 vs 复盘）对不上的商品，逐行带三遍数量。
 *
 * 🔴 抽盘的差异表**不是**"抽盘 − 复盘"。主管把数量改成跟复盘一致之后，
 *    后者会变成 0，那一行会当场从表上消失 —— 可"改对了"不等于
 *    "这个商品没疑问"，主管要最终核对的恰恰是"前两遍对不上的那批"。
 *    拿它当行集等于"复核得越认真、表越短"，核对台账反而丢了。
 *
 * 每行同时给两件事，别混：
 *   · `base_diff` = 复盘 − 初盘 —— **为什么这个商品进清单**（前两遍的差异）
 *   · `diff_qty`  = 抽盘 − 复盘 —— **复核的结果**（改成一致就是 0）
 *
 * 行集只由前两遍决定，抽盘怎么改都不会让行消失 —— 这就是"最终核对"。
 */
function reviewRowsOf(zc) {
  const q1 = zonePhaseQtyMap(zc, 1);
  const q2 = zonePhaseQtyMap(zc, 2);
  const q3 = zonePhaseQtyMap(zc, 3);
  const out = [];
  for (const barcode of reviewSetOf(q1, q2)) {
    const a = q1.get(barcode);
    const b = q2.get(barcode);
    const t = q3.get(barcode);
    const baseMissing = a !== undefined && b === undefined;
    out.push({
      barcode,
      qty: t === undefined ? 0 : t, // 本遍（抽盘）实际复核到的数
      account_qty: null,
      loc_code: null,
      base_qty: a === undefined ? null : a, // 初盘
      prev_qty: b === undefined ? null : b, // 上一遍（复盘）
      diff_qty: (t === undefined || b === undefined) ? null : t - b, // 复核结果
      base_diff: (a === undefined || b === undefined) ? null : b - a, // 前两遍的差异
      base_missing: baseMissing,
      // 旧字段名的兼容位：复核清单里的「漏盘」指的是"初盘盘过、复盘没扫到"
      // （抽盘自己没扫到是"未复核"，由 review=pending 表达，两者别混）。
      missing: baseMissing,
      review: reviewVerdict(t, b),
      review_missing: t === undefined,
    });
  }
  out.sort((x, y) => (x.barcode < y.barcode ? -1 : x.barcode > y.barcode ? 1 : 0));
  return out;
}

function phaseSummary(zc, phase) {
  const rows = zonePhaseRows(zc, phase);
  const base = {
    phase,
    label: PHASE_LABEL[phase],
    kinds: rows.length,
    total_qty: rows.reduce((s, r) => s + Number(r.qty), 0),
    mistakes: mistakesOf(zc, phase),
  };

  // 🔴 抽盘（第三遍）的头条数字是**待复核数**，不是"本遍 − 上一遍"的差异数：
  //    抽盘的差异表已经是复核清单（行集由前两遍定死），
  //    再报"抽盘 − 复盘"的条数，复核改对之后这个数会掉到 0 ——
  //    看上去像"盘完了没问题"，其实是"刚认真复核完一遍"。
  //    主管在阶段条上要的是"还剩几项没看"。
  if (phase === 3) {
    const review = reviewRowsOf(zc);
    const t = tallyReview(review);
    return {
      ...base,
      diff: t.total,           // 复核清单条数（前两遍对不上的）
      pending_review: t.pending,
      reviewed: t.reviewed,
      review_total: t.total,
      review_tally: t,
      diff_rows: review,
    };
  }

  const diff = diffRowsOf(zc, phase);
  return { ...base, diff: diff.length, diff_rows: diff };
}

/**
 * 失误笔数：该点位在上一阶段扫过、本阶段**被改成不同数量**的条码数。
 * 本阶段没再扫的不算（那是"差异未复核"，另一栏），
 * 否则这个数会虚高，主管拿它考核人就不公平了。
 */
function mistakesOf(zc, phase) {
  const prevPhase = PHASES[PHASES.indexOf(phase) - 1];
  if (!prevPhase) return 0;
  const prev = new Map();
  for (const r of zonePhaseRows(zc, prevPhase)) prev.set(r.barcode, Number(r.qty));
  let n = 0;
  for (const r of zonePhaseRows(zc, phase)) {
    const p = prev.get(r.barcode);
    if (p === undefined) continue;
    if (p !== Number(r.qty)) n++;
  }
  return n;
}

function publicZone(z) {
  return {
    zone_code: z.zone_code,
    zone_name: z.zone_name,
    store_code: z.store_code,
    locked: !!z.locked,
    created_at: z.created_at,
    updated_at: z.updated_at,
  };
}

function publicSheet(s) {
  return {
    sheet_no: s.sheet_no,
    zone_code: s.zone_code,
    phase: s.phase,
    status: s.status,
    operator: s.operator,
    device_id: s.device_id,
    started_at: s.started_at,
    submitted_at: s.submitted_at,
    uploaded_at: s.uploaded_at,
    // 审批状态（0未提审 1待审 2通过 3驳回）——和 status 是两回事，见 db.js 的注释。
    // 用 `?? 0` 兜底：老库刚迁移完这一步可能还没跑到，别把 NULL 当"已通过"。
    approval_status: s.approval_status == null ? 0 : s.approval_status,
    reject_reason: s.reject_reason == null ? null : s.reject_reason,
  };
}

// ============================================================
// 抽盘授权（M2/P2）
//
// 🔴 这是**后端**拦的，不是前端把按钮藏起来。前端隐藏只挡得住老实人：
//    客户端的离线库里抽盘单是能直接造出来的，上传时若服务端不校，
//    没权限的人照样能把抽盘结果写进来 —— 而抽盘恰恰是"主管定案"那一步，
//    被绕过等于盘点结论可以被盘点员自己改。
//    PG 的文案"请联系有权限的管理干部"说明它也是后端拦的。
// ============================================================

/**
 * 某人现在有没有该盘点位的抽盘权。
 *
 * 🔴 管理员**天然持权**。不是"admin 最大"这种想当然，是因为授权这个动作
 *    本身得有人能做：如果连管理员都要先给自己授一次权，新点位建出来
 *    当天就没人开得了抽盘单。
 *
 * 🔴 判据**只看 `revoked_at IS NULL`**。全系统"有没有权"只此一处，
 *    别在别的路由里另写一套 —— 两套判据必然在某个边界（刚解除、刚续授）
 *    给出不同答案，表现出来就是"界面说有权、一提交被拒"，最难查的一种。
 */
function hasGrant(user, zc) {
  if (!user) return false;
  if (user.role === 'admin') return true;
  return !!db.prepare(
    'SELECT 1 FROM inv_grants WHERE zone_code = ? AND user_id = ? AND revoked_at IS NULL'
  ).get(zc, user.id);
}

/**
 * 抽盘门槛的唯一出口：过不了就**把响应写完**并返回 false。
 *
 * 做成"写完响应"而不是"返回布尔让调用方自己回"，是为了让每个调用点
 * 只剩 `if (!requireGrant(...)) return;` 一行 —— 调用点越短，
 * 越不会有人"忘了 return"从而让判断变成装饰品。
 */
function requireGrant(req, res, user, zc) {
  if (hasGrant(user, zc)) return true;
  res.status(403).json({
    error: '您没有抽盘授权权限，请联系有权限的管理干部',
    code: 'no_stocktake_grant',
    zone_code: zc,
  });
  return false;
}

/** 能授权/解除的人：管理员，或者**该点位当前持权的人**（管理干部授权下属）。 */
function canManageGrant(user, zc) {
  return hasGrant(user, zc);
}

/** 抽盘授权现状：谁有（含已解除的留痕）、**我自己有没有**。 */
router.get('/zone/:zcode/grant', (req, res) => {
  const u = auth(req, res); if (!u) return;
  const zc = code(req.params.zcode);
  if (!zc) return res.status(400).json({ error: 'zone_code 不合法' });
  if (!zoneOf(zc)) return res.status(404).json({ error: '盘点位不存在' });

  const rows = db.prepare(`
    SELECT g.user_id, g.granted_by, g.granted_at, g.revoked_at,
           u.username, u.nickname
      FROM inv_grants g
      LEFT JOIN users u ON u.id = g.user_id
     WHERE g.zone_code = ?
     ORDER BY (g.revoked_at IS NULL) DESC, g.granted_at DESC
  `).all(zc);

  res.json({
    zone_code: zc,
    mine: hasGrant(u, zc),          // 客户端据此决定能不能进抽盘
    is_admin: u.role === 'admin',
    can_manage: canManageGrant(u, zc),
    // 生效中的用户 id（界面用来做"这人现在能抽盘吗"的即时判断）
    live_user_ids: rows.filter((r) => r.revoked_at === null).map((r) => r.user_id),
    grants: rows.map((r) => ({ ...r, live: r.revoked_at === null })),
  });
});

/** 我能在哪些点位抽盘（客户端进抽盘前先问一句，免得白扫一批再被拒）。 */
router.get('/grants/mine', (req, res) => {
  const u = auth(req, res); if (!u) return;
  if (u.role === 'admin') {
    // 管理员天然持权 → 返回全部点位，客户端不必再逐个问
    const zones = db.prepare('SELECT zone_code FROM inv_zones ORDER BY zone_code ASC').all();
    return res.json({ all: true, zone_codes: zones.map((z) => z.zone_code) });
  }
  const rows = db.prepare(`
    SELECT zone_code, granted_at FROM inv_grants
     WHERE user_id = ? AND revoked_at IS NULL
     ORDER BY granted_at DESC
  `).all(u.id);
  res.json({ all: false, zone_codes: rows.map((r) => r.zone_code), grants: rows });
});

/**
 * 授权某个用户抽盘（幂等：已生效的再授一次不改原 granted_at）。
 *
 * 🔴 **续授不覆盖原 granted_at** —— 授权时间是要留痕的，
 *    反复点一下就把"什么时候给的"刷新掉，事后追责时这行记录就没意义了。
 *    真正要重新计时，得先解除再授（两步都留痕）。
 */
router.post('/zone/:zcode/grant', (req, res) => {
  const u = auth(req, res); if (!u) return;
  const zc = code(req.params.zcode);
  if (!zc) return res.status(400).json({ error: 'zone_code 不合法' });
  if (!zoneOf(zc)) return res.status(404).json({ error: '盘点位不存在' });
  if (!canManageGrant(u, zc)) {
    return res.status(403).json({ error: '您没有该盘点位的抽盘授权权限，无法授权他人', code: 'no_stocktake_grant' });
  }

  const b = req.body || {};
  let target = null;
  if (b.user_id !== undefined && b.user_id !== null) {
    target = db.prepare('SELECT id,username,nickname,role FROM users WHERE id = ?').get(Number(b.user_id));
  } else if (b.username) {
    target = db.prepare('SELECT id,username,nickname,role FROM users WHERE username = ?').get(String(b.username).trim());
  }
  if (!target) return res.status(404).json({ error: '用户不存在（user_id 或 username 二选一）' });

  const now = Date.now();
  const live = db.prepare(
    'SELECT 1 FROM inv_grants WHERE zone_code = ? AND user_id = ? AND revoked_at IS NULL'
  ).get(zc, target.id);
  if (!live) {
    // 已解除过的老行要复用（PRIMARY KEY 是 zone_code+user_id）
    db.prepare(`
      INSERT INTO inv_grants (zone_code, user_id, granted_by, granted_at, revoked_at)
      VALUES (?,?,?,?,NULL)
      ON CONFLICT(zone_code, user_id) DO UPDATE SET
        granted_by = excluded.granted_by,
        granted_at = excluded.granted_at,
        revoked_at = NULL
    `).run(zc, target.id, u.id, now);
  }
  res.json({
    ok: true,
    already: !!live,
    zone_code: zc,
    user: { id: target.id, username: target.username, nickname: target.nickname },
  });
});

/** 解除抽盘授权（置 revoked_at，**不删行** —— 这行是"当时授没授过"的证据）。 */
router.delete('/zone/:zcode/grant', (req, res) => {
  const u = auth(req, res); if (!u) return;
  const zc = code(req.params.zcode);
  if (!zc) return res.status(400).json({ error: 'zone_code 不合法' });
  if (!zoneOf(zc)) return res.status(404).json({ error: '盘点位不存在' });

  const b = req.body || {};
  const raw = b.user_id !== undefined && b.user_id !== null
    ? b.user_id
    : (req.query.user_id !== undefined ? req.query.user_id : null);
  const uid = Number(raw);
  if (!Number.isInteger(uid) || uid <= 0) return res.status(400).json({ error: 'user_id 必须是正整数' });

  // 自己解除自己：允许（离职前收回、授错了立刻收回，都该自己能做）
  if (!canManageGrant(u, zc) && uid !== u.id) {
    return res.status(403).json({ error: '您没有该盘点位的抽盘授权权限，无法解除他人授权', code: 'no_stocktake_grant' });
  }

  const info = db.prepare(
    'UPDATE inv_grants SET revoked_at = ? WHERE zone_code = ? AND user_id = ? AND revoked_at IS NULL'
  ).run(Date.now(), zc, uid);
  res.json({ ok: true, revoked: info.changes, zone_code: zc, user_id: uid });
});

// ============================================================
// 盘点位
// ============================================================

/** 点位列表（带库位数、单据数、未提交单数） */
router.get('/zones', (req, res) => {
  const u = auth(req, res); if (!u) return;
  const rows = db.prepare(`
    SELECT z.*,
           (SELECT COUNT(*) FROM inv_locations l WHERE l.zone_code = z.zone_code) AS loc_count,
           (SELECT COUNT(*) FROM inv_sheets s WHERE s.zone_code = z.zone_code)    AS sheet_count,
           (SELECT COUNT(*) FROM inv_sheets s WHERE s.zone_code = z.zone_code AND s.status = 0) AS open_sheets
      FROM inv_zones z
     ORDER BY z.locked ASC, z.zone_code ASC
  `).all();
  res.json({ items: rows.map((r) => ({ ...publicZone(r), loc_count: r.loc_count, sheet_count: r.sheet_count, open_sheets: r.open_sheets })) });
});

/** 建/改点位（幂等） */
router.post('/zone', (req, res) => {
  const u = auth(req, res); if (!u) return;
  const body = req.body || {};
  const zc = code(body.zone_code);
  if (!zc) return res.status(400).json({ error: 'zone_code 不合法（不能为空、不能含斜杠或空白）' });
  const z = upsertZone(zc, name(body.zone_name, zc), body.store_code ? code(body.store_code) : null);
  res.json({ zone: publicZone(z) });
});

/** 点位详情（含库位、各阶段小结） */
router.get('/zone/:zcode', (req, res) => {
  const u = auth(req, res); if (!u) return;
  const zc = code(req.params.zcode);
  if (!zc) return res.status(400).json({ error: 'zone_code 不合法' });
  const z = zoneOf(zc);
  if (!z) return res.status(404).json({ error: '盘点位不存在' });
  res.json({
    zone: publicZone(z),
    locations: db.prepare('SELECT loc_code, loc_name, zone_code, sort_no FROM inv_locations WHERE zone_code = ? ORDER BY sort_no ASC, loc_code ASC').all(zc),
    phases: PHASES.map((p) => {
      const s = phaseSummary(zc, p);
      const sheet = db.prepare('SELECT sheet_no, status, started_at, approval_status, reject_reason FROM inv_sheets WHERE zone_code = ? AND phase = ? ORDER BY started_at DESC LIMIT 1').get(zc, p) || null;
      return {
        ...s,
        diff_rows: undefined,
        sheet_no: sheet ? sheet.sheet_no : null,
        status: sheet ? sheet.status : -1,
        approval_status: sheet && sheet.approval_status != null ? sheet.approval_status : 0,
        reject_reason: sheet ? (sheet.reject_reason || null) : null,
      };
    }),
  });
});

/**
 * 抽盘的**复核清单**：前两遍（初盘 vs 复盘）对不上的商品，逐行带三遍数量。
 *
 * 为什么单独开一个端点，而不是塞进 `/zone/:zcode`：
 * 那份响应每次都要把三个阶段一起算完、还要顺带查单据状态，是**给界面画
 * 阶段条**用的；复核清单要带商品名和金额列，行多、字段多，混在一起会让
 * 每次刷阶段条都白算一遍。审批（M2）和管理台要看的就是这一份台账。
 *
 * 行集只由**前两遍**决定，抽盘怎么改都不会让行消失 —— 见 [reviewRowsOf]。
 */
router.get('/zone/:zcode/review', (req, res) => {
  const u = auth(req, res); if (!u) return;
  const zc = code(req.params.zcode);
  if (!zc) return res.status(400).json({ error: 'zone_code 不合法' });
  if (!zoneOf(zc)) return res.status(404).json({ error: '盘点位不存在' });
  const rows = reviewRowsOf(zc);
  const tally = tallyReview(rows);
  res.json({
    zone_code: zc,
    rows,
    tally,
    diff: tally.total,           // 复核清单条数（前两遍对不上的）
    pending_review: tally.pending,
  });
});

/** 锁 / 解锁点位 */router.post('/zone/:zcode/lock', (req, res) => {
  const u = auth(req, res); if (!u) return;
  const zc = code(req.params.zcode);
  if (!zc) return res.status(400).json({ error: 'zone_code 不合法' });
  if (!zoneOf(zc)) return res.status(404).json({ error: '盘点位不存在' });
  const locked = (req.body || {}).locked === false || (req.body || {}).locked === 0 ? 0 : 1;
  db.prepare('UPDATE inv_zones SET locked = ?, updated_at = ? WHERE zone_code = ?').run(locked, Date.now(), zc);
  res.json({ zone: publicZone(zoneOf(zc)) });
});

/** 删点位：级联删库位、绑定、单据、明细、抽盘授权。危险操作 → 只允许管理员。 */
router.delete('/zone/:zcode', (req, res) => {
  const u = auth(req, res, { needAdmin: true }); if (!u) return;
  const zc = code(req.params.zcode);
  if (!zc) return res.status(400).json({ error: 'zone_code 不合法' });
  const z = zoneOf(zc);
  if (!z) return res.status(404).json({ error: '盘点位不存在' });

  db.exec('BEGIN');
  try {
    const locCodes = db.prepare('SELECT loc_code FROM inv_locations WHERE zone_code = ?').all(zc).map((r) => r.loc_code);
    let bound = 0;
    if (locCodes.length) {
      const q = locCodes.map(() => '?').join(',');
      bound = db.prepare(`DELETE FROM inv_barcode_locations WHERE loc_code IN (${q})`).run(...locCodes).changes;
    }
    const locs = db.prepare('DELETE FROM inv_locations WHERE zone_code = ?').run(zc).changes;
    const scans = db.prepare('DELETE FROM inv_scans WHERE zone_code = ?').run(zc).changes;
    const sheets = db.prepare('DELETE FROM inv_sheets WHERE zone_code = ?').run(zc).changes;
    // 抽盘授权要跟着点位一起删：点位都没了，那条授权指向的对象就不存在了。
    // 这里**是**硬删（和"解除授权"不同）—— 解除要留痕是因为点位还在、
    // 还要回答"当时授没授过"；点位都删了，那个问题的答案已经没有意义，
    // 留着只会变成一堆查询里要额外过滤的孤儿行。
    const grants = db.prepare('DELETE FROM inv_grants WHERE zone_code = ?').run(zc).changes;
    db.prepare('DELETE FROM inv_zones WHERE zone_code = ?').run(zc);
    db.exec('COMMIT');
    res.json({ ok: true, deleted: { zone: 1, location: locs, barcode_location: bound, sheet: sheets, scan: scans, grant: grants } });
  } catch (e) {
    db.exec('ROLLBACK');
    res.status(500).json({ error: '删除失败：' + e.message });
  }
});

// ============================================================
// 库位 / 货架位
// ============================================================

router.get('/locations', (req, res) => {
  const u = auth(req, res); if (!u) return;
  const zc = code(req.query.zone);
  if (!zc) return res.status(400).json({ error: '缺 zone 参数' });
  res.json({ items: db.prepare('SELECT loc_code, loc_name, zone_code, sort_no FROM inv_locations WHERE zone_code = ? ORDER BY sort_no ASC, loc_code ASC').all(zc) });
});

router.post('/location', (req, res) => {
  const u = auth(req, res); if (!u) return;
  const body = req.body || {};
  const lc = code(body.loc_code);
  const zc = code(body.zone_code);
  if (!lc) return res.status(400).json({ error: 'loc_code 不合法' });
  if (!zc) return res.status(400).json({ error: 'zone_code 不合法' });
  if (!zoneOf(zc)) return res.status(404).json({ error: '盘点位不存在，请先建盘点位' });
  const now = Date.now();
  db.prepare(`
    INSERT INTO inv_locations (loc_code, loc_name, zone_code, sort_no, created_at, updated_at)
    VALUES (?, ?, ?, ?, ?, ?)
    ON CONFLICT(loc_code) DO UPDATE SET
      loc_name = COALESCE(NULLIF(excluded.loc_name,''), inv_locations.loc_name),
      zone_code = excluded.zone_code,
      sort_no = excluded.sort_no,
      updated_at = excluded.updated_at
  `).run(lc, name(body.loc_name, lc), zc, Number.isFinite(Number(body.sort_no)) ? Number(body.sort_no) : 0, now, now);
  res.json({ location: db.prepare('SELECT loc_code, loc_name, zone_code, sort_no FROM inv_locations WHERE loc_code = ?').get(lc) });
});

/** 删库位：同时解绑它上面的商品（不删商品档案 —— 那在客户端本地） */
router.delete('/location/:lcode', (req, res) => {
  const u = auth(req, res, { needAdmin: true }); if (!u) return;
  const lc = code(req.params.lcode);
  if (!lc) return res.status(400).json({ error: 'loc_code 不合法' });
  db.exec('BEGIN');
  try {
    const bound = db.prepare('DELETE FROM inv_barcode_locations WHERE loc_code = ?').run(lc).changes;
    const loc = db.prepare('DELETE FROM inv_locations WHERE loc_code = ?').run(lc).changes;
    db.exec('COMMIT');
    res.json({ ok: true, deleted: { location: loc, barcode_location: bound } });
  } catch (e) {
    db.exec('ROLLBACK');
    res.status(500).json({ error: '删除失败：' + e.message });
  }
});

// ============================================================
// 商品 ↔ 货架位绑定（挂在 /api/location）
// ============================================================

/** 查商品在哪些货架位 / 属于哪些盘点位 */
location.get('/by-barcode/:barcode', (req, res) => {
  const u = auth(req, res); if (!u) return;
  const bc = code(req.params.barcode);
  if (!bc) return res.status(400).json({ error: 'barcode 不合法' });
  const rows = db.prepare(`
    SELECT b.barcode, b.loc_code, b.bound_at, l.loc_name, l.zone_code, z.zone_name
      FROM inv_barcode_locations b
      LEFT JOIN inv_locations l ON l.loc_code = b.loc_code
      LEFT JOIN inv_zones z ON z.zone_code = l.zone_code
     WHERE b.barcode = ?
     ORDER BY l.zone_code ASC, l.sort_no ASC
  `).all(bc);
  res.json({
    barcode: bc,
    locations: rows,
    // 🔴 zones 为空是"还没建这个商品的货架位档案"，**不是**"它不属于任何点位"。
    //    客户端判定时必须区别对待（没绑过要放行+提醒，绑了别处才拒绝）。
    zones: [...new Set(rows.map((r) => r.zone_code).filter(Boolean))],
  });
});

/** 绑定 / 解绑。body 可传单条 {barcode, loc_code} 或批量 {items:[...]} */
location.post('/bind', (req, res) => {
  const u = auth(req, res); if (!u) return;
  const body = req.body || {};
  const items = Array.isArray(body.items) ? body.items : [{ barcode: body.barcode, loc_code: body.loc_code }];
  if (!items.length) return res.status(400).json({ error: '没有要处理的数据' });
  if (items.length > MAX_BIND_PER_CALL) return res.status(400).json({ error: `单次最多处理 ${MAX_BIND_PER_CALL} 条` });
  const bind = body.bind !== false; // 默认绑定；显式 bind:false 才是解绑

  const now = Date.now();
  const ins = db.prepare('INSERT INTO inv_barcode_locations (barcode, loc_code, bound_at) VALUES (?,?,?) ON CONFLICT(barcode, loc_code) DO NOTHING');
  const del = db.prepare('DELETE FROM inv_barcode_locations WHERE barcode = ? AND loc_code = ?');
  const locExists = db.prepare('SELECT 1 AS x FROM inv_locations WHERE loc_code = ?');

  let done = 0;
  const bad = [];
  db.exec('BEGIN');
  try {
    for (const it of items) {
      const bc = code(it && it.barcode);
      const lc = code(it && it.loc_code);
      if (!bc || !lc) { bad.push({ barcode: it && it.barcode, loc_code: it && it.loc_code, reason: '码值不合法' }); continue; }
      if (bind && !locExists.get(lc)) { bad.push({ barcode: bc, loc_code: lc, reason: '货架位不存在' }); continue; }
      if (bind) ins.run(bc, lc, now); else del.run(bc, lc);
      done++;
    }
    db.exec('COMMIT');
  } catch (e) {
    db.exec('ROLLBACK');
    return res.status(500).json({ error: '绑定失败：' + e.message });
  }
  res.json({ ok: true, bind, applied: done, rejected: bad });
});

// ============================================================
// 盘点单
// ============================================================

/**
 * 开单。
 *
 * 三种调用方式，语义必须分清楚（混在一起就会出现"我明明要开新单，
 * 服务端把我上次那张已归档的单丢回来"）：
 *   1. 不带 sheet_no → 该点位该阶段有**未提交**的单就复用它
 *      （别新开：一进来就开新单，上次扫的数据在界面上"凭空消失"）；
 *   2. 带 sheet_no 且该单**已存在且是这张** → 复用（幂等，客户端重试安全）；
 *   3. 带 sheet_no 但那个号已被**别的**单占用，或者那张单已经归档
 *      （status≠0，不能再往里写）→ 409 sheet_no_taken。
 *      绝不"顺手"把一张写不进去的单当成本次要用的单返回 ——
 *      客户端拿到它会以为可以扫，一扫码就被拒，现场完全没法解释。
 */
router.post('/sheet', (req, res) => {
  const u = auth(req, res); if (!u) return;
  const body = req.body || {};
  const zc = code(body.zone_code);
  if (!zc) return res.status(400).json({ error: 'zone_code 不合法' });
  const phase = Number(body.phase);
  if (!PHASES.includes(phase)) return res.status(400).json({ error: 'phase 只能是 1初盘 / 2复盘 / 3抽盘' });

  let z = zoneOf(zc);
  if (body.zone && body.zone.zone_code) z = upsertZone(zc, name(body.zone.zone_name, zc), body.zone.store_code ? code(body.zone.store_code) : null);
  if (!z) return res.status(404).json({ error: '盘点位不存在，请先建盘点位' });
  if (z.locked) return res.status(409).json({ error: `盘点位「${z.zone_name || zc}」已锁定，请先解除锁定`, code: 'zone_locked' });

  // 🔴 抽盘必须持权（M2/P2）。放在"锁定"检查之后、开单之前：
  //    开单是抽盘的入口，不在这里拦，没权限的人能一路扫完再在上传时被拒 ——
  //    那一整批活白干，而且他到那时才知道自己没权限，比进门就被拦住差得多。
  if (phase === 3 && !requireGrant(req, res, u, zc)) return;

  const want = String(body.sheet_no || '').trim();

  // 指定了单号：走上面第 2/3 条路，不去猜"有没有别的未完成单"
  if (want) {
    const exist = sheetOf(want);
    if (exist) {
      const same = exist.zone_code === zc && exist.phase === phase;
      if (!same || exist.status !== 0) {
        return res.status(409).json({
          error: same
            ? `单号 ${want} 已归档（status=${exist.status}），不能再往里扫`
            : `单号 ${want} 已被占用（属于 ${exist.zone_code}/${exist.phase}）`,
          code: 'sheet_no_taken',
          sheet: publicSheet(exist),
        });
      }
      return res.json({ sheet: publicSheet(exist) });
    }
    const now = Date.now();
    db.prepare(`
      INSERT INTO inv_sheets (sheet_no, zone_code, phase, status, operator, operator_id, device_id, started_at, created_at)
      VALUES (?,?,?,0,?,?,?,?,?)
    `).run(want, zc, phase, u.nickname || u.username, u.id,
      body.device_id ? String(body.device_id).slice(0, 128) : null, now, now);
    return res.json({ sheet: publicSheet(sheetOf(want)) });
  }

  // 没指定：优先复用该点位该阶段已有的未完成单
  let s = db.prepare('SELECT * FROM inv_sheets WHERE zone_code = ? AND phase = ? AND status = 0 ORDER BY started_at DESC LIMIT 1').get(zc, phase);
  if (!s) {
    // 服务端自动生成的单号也要防撞（同一秒两次调用）
    const base = autoSheetNo(zc, phase);
    let no = base;
    for (let i = 1; sheetOf(no) && i <= 50; i++) no = `${base}x${i}`;
    const now = Date.now();
    db.prepare(`
      INSERT INTO inv_sheets (sheet_no, zone_code, phase, status, operator, operator_id, device_id, started_at, created_at)
      VALUES (?,?,?,0,?,?,?,?,?)
    `).run(no, zc, phase, u.nickname || u.username, u.id,
      body.device_id ? String(body.device_id).slice(0, 128) : null, now, now);
    s = sheetOf(no);
  }
  res.json({ sheet: publicSheet(s) });
});

/** `INV-点位-阶段-yyyyMMddHHmmss`（和客户端的 newSheetNo 同一形状，便于对账） */
function autoSheetNo(zc, phase) {
  const d = new Date();
  const p2 = (v) => String(v).padStart(2, '0');
  const z = zc.toUpperCase().replace(/[^A-Z0-9_]/g, '_') || 'Z';
  return `INV-${z}-${phase}-${d.getFullYear()}${p2(d.getMonth() + 1)}${p2(d.getDate())}${p2(d.getHours())}${p2(d.getMinutes())}${p2(d.getSeconds())}`;
}

/** 单据列表（分页） */
router.get('/sheets', (req, res) => {
  const u = auth(req, res); if (!u) return;
  const list = parseList(req.query, { defaultPageSize: 50, windowDays: 3650 });
  if (list.error) return res.status(400).json({ error: list.error });

  const where = [];
  const params = [];
  // 🔴 减货单和盘点单**共用 inv_sheets**（靠 sheet_type 区分），所以盘点侧所有
  //    列表类查询必须显式限定类型 —— 否则管理台的"盘点单列表"里会混进减货单，
  //    点开一看点位是空的、阶段小结全是 0，而减货本来就不看点位不看阶段。
  where.push("sheet_type = 'inventory'");
  const zc = code(req.query.zone);
  if (zc) { where.push('zone_code = ?'); params.push(zc); }
  const phase = Number(req.query.phase);
  if (PHASES.includes(phase)) { where.push('phase = ?'); params.push(phase); }
  const status = req.query.status;
  if (status !== undefined && status !== '' && status !== null) {
    const sv = Number(status);
    if (!Number.isFinite(sv)) return res.status(400).json({ error: 'status 必须是数字' });
    where.push('status = ?'); params.push(sv);
  }
  // 按审批状态筛（0未提审 1待审 2通过 3驳回）——"根据审批状态获取审批单据"。
  // 参数名用 approval 而不是复用 status：这两个是不同的轴，
  // 共用一个名字的话，前端想"待审的单"就只能筛出一个意思来，另一个永远筛不了。
  const approval = req.query.approval;
  if (approval !== undefined && approval !== '' && approval !== null) {
    const av = Number(approval);
    if (![0, 1, 2, 3].includes(av)) {
      return res.status(400).json({ error: 'approval 只能是 0未提审 / 1待审 / 2通过 / 3驳回' });
    }
    where.push('approval_status = ?'); params.push(av);
  }
  where.push(...timeWhere(list, params, 'started_at'));
  const w = where.length ? 'WHERE ' + where.join(' AND ') : '';

  const total = db.prepare(`SELECT COUNT(*) AS n FROM inv_sheets ${w}`).get(...params).n;
  const items = db.prepare(`
    SELECT s.*,
           (SELECT COUNT(*) FROM inv_scans x WHERE x.sheet_no = s.sheet_no) AS rows_count,
           (SELECT COALESCE(SUM(x.qty),0) FROM inv_scans x WHERE x.sheet_no = s.sheet_no) AS total_qty
      FROM inv_sheets s ${w}
     ORDER BY s.started_at ${list.sortDir}
     LIMIT ? OFFSET ?
  `).all(...params, list.pageSize, list.offset);
  res.json(envelope(list, items, total));
});

/** 单据详情：明细 + 差异集 + 该点位各阶段小结 */
router.get('/sheet/:no', (req, res) => {
  const u = auth(req, res); if (!u) return;
  const no = code(req.params.no, 160);
  if (!no) return res.status(400).json({ error: 'sheet_no 不合法' });
  const s = sheetOf(no);
  // 减货单号（JH-…）也可能被传进来 —— 那是另一类单，走 /api/deduct，
  // 这里按"盘点单不存在"回，而不是拿减货的数去算点位的阶段小结。
  if (!s || s.sheet_type !== 'inventory') return res.status(404).json({ error: '盘点单不存在' });

  const rows = scansOf(no);
  // 单据级差异是**行级**的（这张单上扫到的、和上一阶段对不上的），
  // 不含"漏盘"：漏盘要按**阶段**看才有意义（同阶段可能有好几张单，
  // 这一张没有不代表那一张也没有）。阶段口径见下面的 phases[].diff。
  const diff = rows.filter(isDiff);
  const unbound = rows.filter((r) => !r.loc_code);
  res.json({
    sheet: publicSheet(s),
    zone: publicZone(zoneOf(s.zone_code) || {}),
    rows,
    summary: {
      kinds: rows.length,
      total_qty: rows.reduce((a, r) => a + Number(r.qty), 0),
      diff: diff.length,
      unknown: rows.filter((r) => r.account_qty === null).length,
      unbound: unbound.length,
    },
    diff_rows: diff,
    phases: PHASES.map((p) => { const x = phaseSummary(s.zone_code, p); return { ...x, diff_rows: undefined }; }),
  });
});

/**
 * 上传明细（离线优先的主入口；服务端没有这张单就自动建）
 *
 * body: {
 *   rows: [{ barcode, qty, account_qty?, loc_code?, scanned_at? }],
 *   phase?, zone?: {zone_code, zone_name}, device_id?, submitted?,
 *   bindings?: [{barcode, loc_code}],   // 顺带把这次扫出来的货架位绑定带上来
 *   force?,                              // 已上传过的单要覆盖时必须显式传 1
 * }
 *
 * 🔴 重传是常态（弱网），所以这里是 UPSERT 而不是 INSERT。
 * 🔴 已上传的单默认**拒绝覆盖** —— 允许默认覆盖等于"盘点结果可以事后修饰"。
 */
router.post('/sheet/:no/upload', (req, res) => {
  const u = auth(req, res); if (!u) return;
  const no = code(req.params.no, 160);
  if (!no) return res.status(400).json({ error: 'sheet_no 不合法' });

  const body = req.body || {};
  const rows = body.rows;
  if (!Array.isArray(rows)) return res.status(400).json({ error: 'rows 必须是数组' });
  if (rows.length > MAX_ROWS_PER_UPLOAD) return res.status(400).json({ error: `单次上传最多 ${MAX_ROWS_PER_UPLOAD} 行，请分几次传` });

  const force = body.force === true || body.force === 1 || body.force === '1';

  // ── 单 / 点位 / 阶段 ──
  const exist = sheetOf(no);
  if (exist && exist.status === 2 && !force) {
    // 已经上传过了。重传同一批数据是正常的（客户端可能没收到回执）——
    // 但服务端不能凭"看起来一样"就默认放行覆盖，所以交给客户端决定：
    // 客户端收到这个 code 直接标记为已完成（它要的就是"数据在服务端"）。
    return res.status(409).json({ error: '该盘点单已上传过，如需覆盖请显式传 force=1', code: 'already_uploaded', sheet_no: no });
  }

  const zc = code((body.zone && body.zone.zone_code) || (exist && exist.zone_code));
  if (!zc) return res.status(400).json({ error: '缺少 zone_code' });
  const phase = Number(body.phase != null ? body.phase : (exist ? exist.phase : 0));
  if (!PHASES.includes(phase)) return res.status(400).json({ error: 'phase 只能是 1初盘 / 2复盘 / 3抽盘' });

  // 点位：允许随上传带上（离线期间在客户端新建的点位），也允许服务端已有
  let z = zoneOf(zc);
  if (!z) {
    if (!body.zone || !body.zone.zone_code) {
      return res.status(404).json({ error: `盘点位 ${zc} 不存在（请一并上传 zone 信息）`, code: 'zone_not_found' });
    }
    z = upsertZone(zc, name(body.zone.zone_name, zc), body.zone.store_code ? code(body.zone.store_code) : null);
  } else if (body.zone && body.zone.zone_code) {
    z = upsertZone(zc, name(body.zone.zone_name, zc), body.zone.store_code ? code(body.zone.store_code) : null);
  }

  // 🔴 抽盘必须持权（M2/P2）。这是**数据真正落地的那道门**：
  //    客户端的按钮可以藏、开单也可以拦，但离线库里的抽盘单是能直接造的，
  //    只有在这里校，才能保证"没权限的人写不进抽盘结果"。
  //    放在差异集校验**之前** —— 没权限的人不该通过探测错误信息
  //    （"不在差异集内" vs "没权限"）反推出这个点位有哪些商品是差异项。
  if (phase === 3 && !requireGrant(req, res, u, zc)) return;

  // ── 阶段准入校验 ──
  //
  // 🔴 只有**抽盘**限差异集（初盘 vs 复盘 对不上的那些），复盘不限：
  //    复盘的价值就在于不知道哪里会错，先按差异集限制它等于默认初盘是对的。
  //    这和客户端 InventoryRules.requiresDiffSetOnly 必须一致 ——
  //    两边口径不齐，手机让扫、服务端拒收，现场只会得到"传不上去"。
  //
  // 🔴 但**只有服务端已经有前两阶段数据时才校**。整场盘点断网跑完、最后
  //    一次性上传，这时服务端还没有初盘数据，硬校会把整批数据拒掉
  //    （现场表现为"传不上去"）。这时跳过并在回包里明确标 diff_checked:false，
  //    让调用方知道"这次没校"。
  let diffChecked = false;
  if (phase === 3) {
    const has1 = zonePhaseQtyMap(zc, 1).size > 0;
    const has2 = zonePhaseQtyMap(zc, 2).size > 0;
    if (has1 && has2) {
      const allowed = diffSetForNextPhase(zc, 1, 2);
      const bad = [...new Set(rows.map((r) => code(r && r.barcode))
        .filter((b) => b && !allowed.has(b)))];
      if (bad.length) {
        return res.status(400).json({
          error: '抽盘阶段只复核初盘与复盘对不上的商品',
          code: 'not_in_diff_set',
          barcodes: bad.slice(0, 100),
          total_bad: bad.length,
        });
      }
      diffChecked = true;
    }
  }

  // ── 落库（事务） ──
  //
  // 🔴 **上传即归档**：一次成功的上传把单据置成 2（已上传）。
  //    为什么不看 body.submitted：那会让"已提交但没传完"和"已归档"混在
  //    同一个数字里，而覆盖保护（下面那个 already_uploaded 判定）就是靠
  //    status=2 才成立的 —— 不置 2 的话保护永远不生效，
  //    等于"盘点结果可以事后随便改"，这套制度就白做了。
  //    真要改已归档的单，走 force=1（显式、留痕在响应里）。
  const now = Date.now();
  const upsert = db.prepare(`
    INSERT INTO inv_scans (sheet_no, zone_code, phase, barcode, qty, account_qty, loc_code, scanned_at, uploaded_at)
    VALUES (?,?,?,?,?,?,?,?,?)
    ON CONFLICT(sheet_no, phase, barcode) DO UPDATE SET
      qty = excluded.qty,
      account_qty = excluded.account_qty,
      loc_code = excluded.loc_code,
      scanned_at = excluded.scanned_at,
      uploaded_at = excluded.uploaded_at
  `);
  const bindOne = db.prepare('INSERT INTO inv_barcode_locations (barcode, loc_code, bound_at) VALUES (?,?,?) ON CONFLICT(barcode, loc_code) DO NOTHING');

  let accepted = 0;
  const rejected = [];
  db.exec('BEGIN');
  try {
    if (!exist) {
      db.prepare(`
        INSERT INTO inv_sheets (sheet_no, zone_code, phase, status, operator, operator_id, device_id, started_at, created_at)
        VALUES (?,?,?,2,?,?,?,?,?)
        ON CONFLICT(sheet_no) DO NOTHING
      `).run(no, zc, phase, u.nickname || u.username, u.id,
        body.device_id ? String(body.device_id).slice(0, 128) : null, now, now);
    }

    for (const raw of rows) {
      const bc = code(raw && raw.barcode);
      if (!bc) { rejected.push({ barcode: raw && raw.barcode, reason: '条码不合法' }); continue; }
      const q = num(raw.qty);
      if (q === null || q === 0) { rejected.push({ barcode: bc, reason: '数量必须是有效数字且不为 0' }); continue; }
      const aq = num(raw.account_qty);
      const lc = code(raw.loc_code);
      const ts = num(raw.scanned_at);
      upsert.run(no, zc, phase, bc, q, aq, lc, ts === null ? now : Math.floor(ts), now);
      accepted++;
    }

    // 顺带把这次扫出来的货架位绑定补上（门店现场就是这么把档案建起来的）
    let bound = 0;
    if (Array.isArray(body.bindings)) {
      for (const b of body.bindings.slice(0, MAX_BIND_PER_CALL)) {
        const bc = code(b && b.barcode);
        const lc = code(b && b.loc_code);
        if (!bc || !lc) continue;
        if (!db.prepare('SELECT 1 AS x FROM inv_locations WHERE loc_code = ?').get(lc)) continue;
        bound += bindOne.run(bc, lc, now).changes;
      }
    }

    db.prepare(`
      UPDATE inv_sheets SET
        status = 2,
        uploaded_at = ?,
        submitted_at = COALESCE(submitted_at, ?)
       WHERE sheet_no = ?
    `).run(now, now, no);
    db.exec('COMMIT');

    const after = sheetOf(no);
    const all = scansOf(no);
    res.json({
      ok: true,
      sheet: publicSheet(after),
      received: rows.length,
      accepted,
      rejected,
      bound,
      diff_checked: diffChecked,
      summary: {
        kinds: all.length,
        total_qty: all.reduce((a, r) => a + Number(r.qty), 0),
        // 同样是行级口径（本次上传的这张单），漏盘/阶段差异看 /zone/:code
        diff: all.filter(isDiff).length,
      },
    });
  } catch (e) {
    db.exec('ROLLBACK');
    res.status(500).json({ error: '上传失败：' + e.message });
  }
});

/** 提交并锁定（服务端侧；客户端在本地也锁一次，两边一致） */
router.post('/sheet/:no/submit', (req, res) => {
  const u = auth(req, res); if (!u) return;
  const no = code(req.params.no, 160);
  if (!no) return res.status(400).json({ error: 'sheet_no 不合法' });
  const s = sheetOf(no);
  if (!s) return res.status(404).json({ error: '盘点单不存在' });
  if (s.status === 2) return res.status(409).json({ error: '该单已上传归档，不能再改', code: 'already_uploaded' });
  if (s.status === 1) return res.json({ ok: true, sheet: publicSheet(s), already: true });

  const now = Date.now();
  db.prepare('UPDATE inv_sheets SET status = 1, submitted_at = ? WHERE sheet_no = ?').run(now, no);
  res.json({ ok: true, sheet: publicSheet(sheetOf(no)) });
});

/** 撤销提交（主管改口要重扫时的出口） */
router.post('/sheet/:no/reopen', (req, res) => {
  const u = auth(req, res, { needAdmin: true }); if (!u) return;
  const no = code(req.params.no, 160);
  if (!no) return res.status(400).json({ error: 'sheet_no 不合法' });
  const s = sheetOf(no);
  if (!s) return res.status(404).json({ error: '盘点单不存在' });
  if (s.status === 2) return res.status(409).json({ error: '已上传归档的单不能撤销（需要覆盖请走 force 上传）', code: 'already_uploaded' });
  db.prepare('UPDATE inv_sheets SET status = 0, submitted_at = NULL WHERE sheet_no = ?').run(no);
  res.json({ ok: true, sheet: publicSheet(sheetOf(no)) });
});

// ============================================================
// 同步：把点位/货架位/绑定拉给客户端（离线要用）
// ============================================================

router.get('/pull', (req, res) => {
  const u = auth(req, res); if (!u) return;
  const list = parseList(req.query, { defaultPageSize: 200, windowDays: 3650 });
  if (list.error) return res.status(400).json({ error: list.error });

  // since 只对点位/库位生效（它们有 updated_at）；绑定表用 bound_at。
  const since = Number(req.query.since);
  const sinceMs = Number.isFinite(since) && since > 0 ? since : 0;

  const zones = db.prepare('SELECT * FROM inv_zones WHERE updated_at > ? ORDER BY zone_code ASC').all(sinceMs);
  const locs = db.prepare('SELECT * FROM inv_locations WHERE updated_at > ? ORDER BY zone_code ASC, sort_no ASC').all(sinceMs);
  const binds = db.prepare('SELECT barcode, loc_code, bound_at FROM inv_barcode_locations WHERE bound_at > ?').all(sinceMs);

  res.json({
    since: sinceMs,
    server_time: Date.now(),
    zones: zones.map(publicZone),
    locations: locs.map((l) => ({ loc_code: l.loc_code, loc_name: l.loc_name, zone_code: l.zone_code, sort_no: l.sort_no })),
    bindings: binds,
  });
});

module.exports = router;
module.exports.location = location;
