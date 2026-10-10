'use strict';

/**
 * 商品档案（商档）接口 —— 挂 /api/master
 *
 * ── 它解决什么 ────────────────────────────────────────────
 * 盘点算差异必须有账面数。原来商档只能从泰格上游钩子拉，那条链路跑在
 * 一台会关机、IP 会漂的机器上（实测过 fetch failed）。断了以后初盘每一行
 * 都是"账上无此商品"，差异集 = 全部商品，三遍制白盘。
 * 这里把商档收进自家服务端：管理台导入一次，所有手机拉同一份。
 *
 * ── 为什么上传要分「写块 + commit」两步 ────────────────────
 * 12 万行一次请求传不完，只能分块。但"写到一半"的商档比没有更危险 ——
 * 店里会拿着一份缺一半的底表去盘。所以：
 *   写块（/upload）只管 UPSERT，全部带同一个 batch 号；
 *   最后调 /commit，才把非本次 batch 的旧数据删掉。
 * 传一半放弃 → 旧商档完好（commit 没被调用）。
 *
 * ── 权限 ──────────────────────────────────────────────────
 * 读（拉商档）任何登录用户都能做 —— 盘点的人不一定有管理台权限。
 * 写（上传 / commit / 清空）必须管理员：商档是底表，谁都能改等于没有底表。
 */
const express = require('express');
const db = require('../db');
const { verifyToken } = require('../auth');

const router = express.Router();

const MAX_BARCODE = 64;
const MAX_TEXT = 120;
const MAX_ROWS_PER_UPLOAD = 2000;   // 单块行数护栏
const DEFAULT_PAGE_SIZE = 2000;
const MAX_PAGE_SIZE = 5000;

function auth(req, res, { needAdmin = false } = {}) {
  const c = verifyToken(req.headers.authorization?.replace('Bearer ', ''));
  if (!c) { res.status(401).json({ error: 'unauthorized' }); return null; }
  const u = db.prepare('SELECT id,username,nickname,role FROM users WHERE id = ?').get(c.uid);
  if (!u) { res.status(401).json({ error: 'unauthorized' }); return null; }
  if (needAdmin && u.role !== 'admin') { res.status(403).json({ error: 'forbidden' }); return null; }
  return u;
}

function code(v, max = MAX_BARCODE) {
  const s = String(v == null ? '' : v).trim();
  if (!s) return null;
  // 条码进查询、进导出，斜杠/空白/控制字符一律不接受
  if (/[\/\\\s\u0000-\u001f]/.test(s)) return null;
  return s.slice(0, max);
}

function text(v) {
  const s = String(v == null ? '' : v).trim();
  return s ? s.slice(0, MAX_TEXT) : null;
}

function num(v) {
  if (v === null || v === undefined || v === '') return null;
  const n = Number(v);
  return Number.isFinite(n) ? n : null;
}

// ============================================================
// 读
// ============================================================

/** 商档总数与最后更新时间（客户端先问这个，决定要不要拉、拉多少） */
router.get('/count', (req, res) => {
  const u = auth(req, res); if (!u) return;
  const r = db.prepare('SELECT COUNT(*) AS n, COALESCE(MAX(updated_at),0) AS updated_at FROM product_master').get();
  res.json({ total: r.n, updated_at: r.updated_at, server_time: Date.now() });
});

/**
 * 分页拉商档。
 *
 * 🔴 12 万行必须分页：一次性返回会把服务端内存和手机内存一起打满，
 *    而且 HTTP 超时了客户端什么也拿不到，表现是"同步一直转圈"。
 * `since` 给增量同步用（只拿更新时间 > since 的行）。
 */
router.get('/', (req, res) => {
  const u = auth(req, res); if (!u) return;
  const pageSize = Math.min(Math.max(Number(req.query.pageSize) || DEFAULT_PAGE_SIZE, 1), MAX_PAGE_SIZE);
  const page = Math.max(Number(req.query.page) || 1, 1);
  const since = num(req.query.since);

  const where = since ? 'WHERE updated_at > ?' : '';
  const params = since ? [since] : [];
  const total = db.prepare(`SELECT COUNT(*) AS n FROM product_master ${where}`).get(...params).n;
  const rows = db.prepare(`
    SELECT barcode, name, spec, unit, unit_price, purchase_price,
           member_price, special_price, account_qty, supplier, updated_at
      FROM product_master ${where}
     ORDER BY barcode ASC
     LIMIT ? OFFSET ?
  `).all(...params, pageSize, (page - 1) * pageSize);

  res.json({
    items: rows,
    total,
    page,
    pageSize,
    has_more: (page - 1) * pageSize + rows.length < total,
  });
});

// ============================================================
// 写（管理员）
// ============================================================

/**
 * 写一块商档。导入的标准格式（龙哥 2026-09-26 定六列，2026-10-06 加会员价/特价，
 *    2026-10-10 加供应商 supplier）：
 *   body: { rows: [{ 商品条码 barcode, 商品名称 name, 规格 spec,
 *                    进价 purchase_price, 售价 unit_price,
 *                    会员价 member_price, 特价 special_price,
 *                    库存 account_qty, 供应商 supplier（可选） }], batch }
 *
 * 🔴 supplier 用 coalesce 保护（同 member_price/special_price）：老格式重导
 *    不带/空串都不清掉已有供应商；要改就传新值（同名 UPSERT 直接覆盖）。
 *
 * 🔴 batch 必填：没有批次号就没法在 commit 时区分新旧，
 *    也就没法做到"传一半不影响店里现有底表"。
 */
router.post('/upload', (req, res) => {
  const u = auth(req, res, { needAdmin: true }); if (!u) return;
  const body = req.body || {};
  const batch = code(body.batch, 40);
  if (!batch) return res.status(400).json({ error: 'batch 不能为空（一次导入用一个批次号）' });
  const rows = body.rows;
  if (!Array.isArray(rows)) return res.status(400).json({ error: 'rows 必须是数组' });
  if (rows.length > MAX_ROWS_PER_UPLOAD) {
    return res.status(400).json({ error: `单块最多 ${MAX_ROWS_PER_UPLOAD} 行，请分块传` });
  }

  const now = Date.now();
  // 🔴 member_price/special_price 用 coalesce：**没带就不覆盖**。
  //    这两列不来自泰格主数据（门店另行维护），而主数据是隔三差五全量重导的 ——
  //    如果"上传行里没这列"就把库里的值清成 NULL，一次老格式重导就把
  //    全店会员价清光，而且不报任何错。宁可不改，不能误删；
  //    真要清除某个会员价，传 0（0 是有效价格，不会被 coalesce 吞掉）。
  const upsert = db.prepare(`
    INSERT INTO product_master
      (barcode, name, spec, unit, unit_price, purchase_price,
       member_price, special_price, account_qty, supplier, batch, updated_at)
    VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
    ON CONFLICT(barcode) DO UPDATE SET
      name = excluded.name,
      spec = excluded.spec,
      unit = excluded.unit,
      unit_price = excluded.unit_price,
      purchase_price = excluded.purchase_price,
      member_price = coalesce(excluded.member_price, product_master.member_price),
      special_price = coalesce(excluded.special_price, product_master.special_price),
      account_qty = excluded.account_qty,
      supplier = coalesce(excluded.supplier, product_master.supplier),
      batch = excluded.batch,
      updated_at = excluded.updated_at
  `);

  let accepted = 0;
  const rejected = [];
  db.exec('BEGIN');
  try {
    for (const raw of rows) {
      const bc = code(raw && raw.barcode);
      if (!bc) { rejected.push({ barcode: raw && raw.barcode, reason: '条码为空或不合法' }); continue; }
      upsert.run(bc, text(raw.name), text(raw.spec), text(raw.unit),
        num(raw.unit_price), num(raw.purchase_price),
        num(raw.member_price), num(raw.special_price),
        num(raw.account_qty), text(raw.supplier), batch, now);
      accepted++;
    }
    db.exec('COMMIT');
  } catch (e) {
    db.exec('ROLLBACK');
    return res.status(500).json({ error: '写入失败：' + e.message });
  }
  res.json({ accepted, rejected: rejected.slice(0, 20), rejected_total: rejected.length, batch });
});

/**
 * 提交本次导入：删掉不属于本批次的旧数据。
 * 到这一步才算"换了一份新商档"。
 */
router.post('/commit', (req, res) => {
  const u = auth(req, res, { needAdmin: true }); if (!u) return;
  const batch = code((req.body || {}).batch, 40);
  if (!batch) return res.status(400).json({ error: 'batch 不能为空' });
  const now = Date.now();
  db.exec('BEGIN');
  try {
    // 本次批次的行统一刷新 updated_at，客户端按 since 增量拉时才不会漏
    db.prepare('UPDATE product_master SET updated_at = ? WHERE batch = ?').run(now, batch);
    const gone = db.prepare('DELETE FROM product_master WHERE batch IS NOT ?').run(batch).changes;
    db.exec('COMMIT');
    res.json({ ok: true, batch, deleted_old: gone });
  } catch (e) {
    db.exec('ROLLBACK');
    res.status(500).json({ error: '提交失败：' + e.message });
  }
});

/** 清空商档（危险操作，只允许管理员） */
router.delete('/', (req, res) => {
  const u = auth(req, res, { needAdmin: true }); if (!u) return;
  const n = db.prepare('DELETE FROM product_master').run().changes;
  res.json({ ok: true, deleted: n });
});

module.exports = router;
