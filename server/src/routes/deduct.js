'use strict';

/**
 * 库房减货单接口（deduct 模块）
 *
 * ── 它和「盘点」的关系 ──────────────────────────────────────
 * 共用 inv_sheets / inv_scans 两张表，靠 `sheet_type='deduct'` 区分
 * （见 db.js 里那两行 ensureColumn 的注释，写了为什么共用而不是另建表）。
 *
 * 🔴 减货**不看点位、不看阶段**：
 *    · zone_code 一律写 DEDUCT_ZONE（'-'），那只是"inv_sheets.zone_code NOT NULL"
 *      逼出来的占位值，**不是盘点位**；
 *    · phase 一律写 1，那是"这列 NOT NULL DEFAULT 1"的中性值，**不是初盘**。
 *    谁在减货上做"阶段互比""差异集"都是错的 —— 减货只有一趟，没有互比对象。
 *
 * ── 为什么要有这一层（原来它是纯本机的）──────────────────────
 * 龙哥 2026-09-25 定：减货单要**上传管理台**，因为要对账 ——
 * "库房减了多少货"现在只存在于员工手机里，人一换、手机一丢，这笔账就没了，
 * 而且管理台永远看不到"这个月一共减了多少"。
 *
 * ── 幂等与覆盖保护 ─────────────────────────────────────────
 * 与盘点同口径：幂等键 (sheet_no, phase, barcode)，重传走 UPSERT；
 * 已上传（status=2）的单默认拒绝覆盖，要覆盖必须显式 force=1。
 * 理由同盘点：**允许默认覆盖 = 减货结果可以事后随便改**，对账就失去意义。
 */
const express = require('express');
const db = require('../db');
const { verifyToken } = require('../auth');
const { parseList, timeWhere, envelope } = require('../paging');

const router = express.Router();      // 挂 /api/deduct

const MAX_CODE = 64;
const MAX_NAME = 120;
const MAX_ROWS_PER_UPLOAD = 2000;
const SHEET_TYPE = 'deduct';
/** 减货单在 inv_sheets.zone_code 上的占位值（见文件头说明：不是盘点位）。 */
const DEDUCT_ZONE = '-';
const NEUTRAL_PHASE = 1;

// ============================================================
// 小工具（与盘点侧同口径，别改出一分叉）
// ============================================================

function auth(req, res, { needAdmin = false } = {}) {
  const c = verifyToken(req.headers.authorization?.replace('Bearer ', ''));
  if (!c) { res.status(401).json({ error: 'unauthorized' }); return null; }
  const u = db.prepare('SELECT id,username,nickname,role FROM users WHERE id = ?').get(c.uid);
  if (!u) { res.status(401).json({ error: 'unauthorized' }); return null; }
  if (needAdmin && u.role !== 'admin') { res.status(403).json({ error: 'forbidden' }); return null; }
  return u;
}

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

function sheetOf(no) {
  return db.prepare('SELECT * FROM inv_sheets WHERE sheet_no = ?').get(no) || null;
}

function onlyDeduct(s) {
  // 🔴 防串：按单号查出来的东西可能是盘点的单（同名前缀不同但接口是相通的）。
  //    拿着一张盘点单走减货接口 = 用减货的口径去改盘点的数，必须挡在最前面。
  return s && s.sheet_type === SHEET_TYPE ? s : null;
}

/** 单据的明细（LEFT JOIN 商档：管理台要显示商品名、对账要按名查）。 */
function scansOf(no) {
  return db.prepare(`
    SELECT r.id, r.sheet_no, r.barcode, r.qty, r.scanned_at, r.uploaded_at, r.sheet_type,
           m.name AS name, m.spec AS spec, m.unit AS unit
      FROM inv_scans r
      LEFT JOIN product_master m ON m.barcode = r.barcode
     WHERE r.sheet_no = ? AND r.sheet_type = ?
     ORDER BY r.id ASC
  `).all(no, SHEET_TYPE);
}

function publicSheet(s) {
  if (!s) return null;
  return {
    sheet_no: s.sheet_no,
    sheet_type: s.sheet_type,
    status: s.status,
    operator: s.operator,
    device_id: s.device_id,
    started_at: s.started_at,
    submitted_at: s.submitted_at,
    uploaded_at: s.uploaded_at,
    created_at: s.created_at,
  };
}

// ============================================================
// 上传
// ============================================================

/**
 * 上传减货明细（服务端没有这张单就自动建）
 *
 * body: { rows: [{ barcode, qty, scanned_at? }], device_id?, operator?, force? }
 *
 * 🔴 已提交（客户端 submit）不是这里的准入条件：和盘点一样，
 *    "上传即归档"（status=2）。客户端那边必须先提交才让传，
 *    但服务端不能依赖客户端的自觉 —— 覆盖保护靠 status=2 才成立。
 */
router.post('/sheet/:no/upload', (req, res) => {
  const u = auth(req, res); if (!u) return;
  const no = code(req.params.no, 160);
  if (!no) return res.status(400).json({ error: 'sheet_no 不合法' });

  const body = req.body || {};
  const rows = body.rows;
  if (!Array.isArray(rows)) return res.status(400).json({ error: 'rows 必须是数组' });
  if (rows.length > MAX_ROWS_PER_UPLOAD) {
    return res.status(400).json({ error: `单次上传最多 ${MAX_ROWS_PER_UPLOAD} 行，请分几次传` });
  }

  const exist = sheetOf(no);
  if (exist && exist.sheet_type !== SHEET_TYPE) {
    return res.status(409).json({ error: '该单号属于盘点单，不能用减货接口上传', code: 'wrong_sheet_type' });
  }

  const force = body.force === true || body.force === 1 || body.force === '1';
  if (exist && exist.status === 2 && !force) {
    // 已经传过了。重传同一批数据是常态（客户端可能没收到回执），
    // 所以 409 由客户端当成成功处理 —— 它要的就是"数据在服务端"。
    return res.status(409).json({
      error: '该减货单已上传过，如需覆盖请显式传 force=1',
      code: 'already_uploaded',
      sheet_no: no,
    });
  }

  const now = Date.now();
  const upsert = db.prepare(`
    INSERT INTO inv_scans (sheet_no, zone_code, phase, barcode, qty, loc_code, scanned_at, uploaded_at, sheet_type)
    VALUES (?,?,?,?,?,NULL,?,?,?)
    ON CONFLICT(sheet_no, phase, barcode) DO UPDATE SET
      qty = excluded.qty,
      scanned_at = excluded.scanned_at,
      uploaded_at = excluded.uploaded_at,
      sheet_type = excluded.sheet_type
  `);

  let accepted = 0;
  const rejected = [];
  db.exec('BEGIN');
  try {
    if (!exist) {
      db.prepare(`
        INSERT INTO inv_sheets (sheet_no, zone_code, phase, status, operator, operator_id,
                                device_id, started_at, created_at, sheet_type)
        VALUES (?,?,?,2,?,?,?,?,?,?)
        ON CONFLICT(sheet_no) DO NOTHING
      `).run(
        no, DEDUCT_ZONE, NEUTRAL_PHASE,
        name(body.operator, u.nickname || u.username), u.id,
        body.device_id ? String(body.device_id).slice(0, 128) : null,
        num(body.started_at) ?? now, now, SHEET_TYPE,
      );
    }

    for (const raw of rows) {
      const bc = code(raw && raw.barcode);
      if (!bc) { rejected.push({ barcode: raw && raw.barcode, reason: '条码不合法' }); continue; }
      const q = num(raw.qty);
      // 减货数量必须 > 0：0 表示"没减"，负数没有业务含义（要加回来是另一张单）。
      if (q === null || q <= 0) { rejected.push({ barcode: bc, reason: '数量必须是正数' }); continue; }
      const ts = num(raw.scanned_at);
      upsert.run(no, DEDUCT_ZONE, NEUTRAL_PHASE, bc, q, ts === null ? now : Math.floor(ts), now, SHEET_TYPE);
      accepted++;
    }

    db.prepare(`
      UPDATE inv_sheets SET
        status = 2,
        uploaded_at = ?,
        submitted_at = COALESCE(submitted_at, ?)
       WHERE sheet_no = ?
    `).run(now, now, no);
    db.exec('COMMIT');

    const after = onlyDeduct(sheetOf(no));
    const all = scansOf(no);
    res.json({
      ok: true,
      sheet: publicSheet(after),
      received: rows.length,
      accepted,
      rejected,
      summary: {
        kinds: all.length,
        total_qty: all.reduce((a, r) => a + Number(r.qty), 0),
      },
    });
  } catch (e) {
    db.exec('ROLLBACK');
    res.status(500).json({ error: '上传失败：' + e.message });
  }
});

// ============================================================
// 管理台：列表 / 详情 / 对账
// ============================================================

/** 减货单列表（分页） */
router.get('/sheets', (req, res) => {
  const u = auth(req, res); if (!u) return;
  const list = parseList(req.query, { defaultPageSize: 50, windowDays: 3650 });
  if (list.error) return res.status(400).json({ error: list.error });

  const where = ["sheet_type = ?"];
  const params = [SHEET_TYPE];
  const status = req.query.status;
  if (status !== undefined && status !== '' && status !== null) {
    const sv = Number(status);
    if (!Number.isFinite(sv)) return res.status(400).json({ error: 'status 必须是数字' });
    where.push('status = ?'); params.push(sv);
  }
  const q = code(req.query.q, MAX_CODE);
  if (q) { where.push('sheet_no LIKE ?'); params.push(`%${q}%`); }
  where.push(...timeWhere(list, params, 'started_at'));
  const w = 'WHERE ' + where.join(' AND ');

  const total = db.prepare(`SELECT COUNT(*) AS n FROM inv_sheets ${w}`).get(...params).n;
  const items = db.prepare(`
    SELECT s.*,
           (SELECT COUNT(*) FROM inv_scans x WHERE x.sheet_no = s.sheet_no) AS rows_count,
           (SELECT COALESCE(SUM(x.qty),0) FROM inv_scans x WHERE x.sheet_no = s.sheet_no) AS total_qty
      FROM inv_sheets s ${w}
     ORDER BY s.started_at ${list.sortDir}
     LIMIT ? OFFSET ?
  `).all(...params, list.pageSize, list.offset);
  res.json(envelope(list, items.map(publicSheet), total));
});

/** 单据详情 */
router.get('/sheet/:no', (req, res) => {
  const u = auth(req, res); if (!u) return;
  const no = code(req.params.no, 160);
  if (!no) return res.status(400).json({ error: 'sheet_no 不合法' });
  const s = onlyDeduct(sheetOf(no));
  if (!s) return res.status(404).json({ error: '减货单不存在' });

  const rows = scansOf(no);
  res.json({
    sheet: publicSheet(s),
    rows,
    summary: {
      kinds: rows.length,
      total_qty: rows.reduce((a, r) => a + Number(r.qty), 0),
      unknown: rows.filter((r) => !r.name).length,
    },
  });
});

/**
 * 对账：按商品汇总"这段时间一共减了多少"。
 *
 * 这才是"要对账"真正要的那张表 —— 单据列表只能回答"张三减了一单"，
 * 回答不了"这个月这个品一共减了多少、是谁减的、分几次减的"。
 * 管理台的减货面板靠它，所以**按条码聚合**而不是按单。
 */
router.get('/reconcile', (req, res) => {
  const u = auth(req, res); if (!u) return;
  const list = parseList(req.query, { defaultPageSize: 100, windowDays: 3650 });
  if (list.error) return res.status(400).json({ error: list.error });

  const where = ['r.sheet_type = ?'];
  const params = [SHEET_TYPE];
  const q = code(req.query.q, MAX_CODE);
  if (q) {
    // 条码或商品名都能搜：管理台的人手里往往只有名字。
    //
    // 🔴 商品名那半句**不能**写成 `COALESCE(m.name, ?) LIKE ?`：
    //    那样没有商档的行（m.name 为 NULL）会被 COALESCE 补成搜索串本身，
    //    于是 `NULL LIKE '%x%'` 变成 `'%x%' LIKE '%x%'` = 恒真，
    //    搜一个条码会把**所有没名字的行**全捞出来（实测命中 4 个而不是 1 个）。
    //    NULL LIKE 的结果就是 NULL（不匹配），这正是我们要的。
    where.push('(r.barcode LIKE ? OR m.name LIKE ?)');
    params.push(`%${q}%`, `%${q}%`);
  }
  where.push(...timeWhere(list, params, 'r.scanned_at'));
  const w = 'WHERE ' + where.join(' AND ');

  const total = db.prepare(`
    SELECT COUNT(DISTINCT r.barcode) AS n
      FROM inv_scans r LEFT JOIN product_master m ON m.barcode = r.barcode ${w}
  `).get(...params).n;

  const items = db.prepare(`
    SELECT r.barcode AS barcode,
           MAX(COALESCE(m.name,'')) AS name,
           MAX(COALESCE(m.spec,'')) AS spec,
           MAX(COALESCE(m.unit,'')) AS unit,
           SUM(r.qty)               AS total_qty,
           COUNT(*)                 AS rows_count,
           COUNT(DISTINCT r.sheet_no) AS sheets_count,
           MAX(r.scanned_at)        AS last_at
      FROM inv_scans r
      LEFT JOIN product_master m ON m.barcode = r.barcode
      ${w}
     GROUP BY r.barcode
     ORDER BY total_qty DESC, r.barcode ASC
     LIMIT ? OFFSET ?
  `).all(...params, list.pageSize, list.offset);

  const overall = db.prepare(`
    SELECT COUNT(DISTINCT r.sheet_no) AS sheets,
           COUNT(*)                   AS rows_count,
           COALESCE(SUM(r.qty), 0)    AS total_qty
      FROM inv_scans r
      LEFT JOIN product_master m ON m.barcode = r.barcode
      ${w}
  `).get(...params);

  res.json({ ...envelope(list, items, total), overall });
});

module.exports = router;
