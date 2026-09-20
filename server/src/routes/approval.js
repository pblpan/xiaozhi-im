'use strict';
/**
 * 通用审批中心（M2/P2）。
 *
 * 挂在 `/api/approval`，需登录。
 *
 * 【为什么是"一套通用审批"而不是"盘点专用审批表"】
 * 审批这件事全系统只有一套语义：待审 → 通过 / 驳回（+ 理由）。
 * 做成通用的，后面请假、调价、报废、退货都能直接挂上来，
 * 不必每加一类业务就把"三态 + 它的一堆边界"（能不能重复批、驳回要不要理由、
 * 提交人能不能撤）重写一遍 —— 那些边界写歪一次就是一个事故。
 * `kind`（哪类业务）+ `ref`（哪条记录）两个字段足够表达归属。
 *
 * 【三个刻意的设计】
 *  1. **驳回理由必填**。驳回不说理由，提交人只能反复猜、反复提，
 *     审批就退化成刁难；PG 的文案"请输入驳回理由"说明它也是硬拦的。
 *  2. **只有 pending 能落决定**。重复批准/先批后驳一律 409。
 *     否则"最后点的那个算"会让审批结论取决于手速，事后完全说不清。
 *  3. **payload 存 JSON 快照**。审批针对的是"当时提交的东西"，
 *     关联记录事后被改或删掉，这条审批意见就成了对不上的空话。
 *     快照让这份意见永远有据可依（所以它**不是**外键）。
 *  4. **不能审自己的单**。自提自批等于没有审批。
 */

const router = require('express').Router();
const db = require('../db');
const { verifyToken } = require('../auth');

const MAX_TITLE = 200;
const MAX_REF = 200;
const MAX_REASON = 500;
const MAX_PAYLOAD = 20000;   // 快照序列化后的字节上限，别让整张单据把库撑爆
const KINDS = ['stocktake'];  // 已知业务类型；未知的也收，但要能查到（见 submit）

function auth(req, res, { needAdmin = false } = {}) {
  const c = verifyToken(req.headers.authorization?.replace('Bearer ', ''));
  if (!c) { res.status(401).json({ error: 'unauthorized' }); return null; }
  const u = db.prepare('SELECT id,username,nickname,role FROM users WHERE id = ?').get(c.uid);
  if (!u) { res.status(401).json({ error: 'unauthorized' }); return null; }
  if (needAdmin && u.role !== 'admin') { res.status(403).json({ error: 'forbidden' }); return null; }
  return u;
}

const text = (v, max) => {
  const s = String(v == null ? '' : v).trim();
  return s ? s.slice(0, max) : null;
};

function publicApproval(a) {
  return {
    id: a.id,
    kind: a.kind,
    title: a.title,
    ref: a.ref,
    payload: a.payload ? safeParse(a.payload) : null,
    status: a.status,
    submitter_id: a.submitter_id,
    submitter_name: a.submitter_name,
    decided_by: a.decided_by,
    decided_by_name: a.decided_by_name,
    decided_at: a.decided_at,
    reject_reason: a.reject_reason,
    created_at: a.created_at,
  };
}

/** payload 是我们自己写进去的 JSON，但**读的时候也要防一手** —— 手改过库、老版本写坏过都发生过。 */
function safeParse(s) {
  try { return JSON.parse(s); } catch { return null; }
}

/**
 * 业务挂钩：审批落定后同步业务表。
 *
 * 🔴 盘点为什么要同步 `inv_sheets.approval_status`：
 *    单据列表、导出、后续报表都要按"批没批"筛，每次去 join 审批表既慢又容易
 *    在某个查询里漏掉 → 出现"这张单在列表里是待审、详情里已批"的分家。
 *    所以在落定时**一次写死**到单据上，读的地方只读单据。
 */
function syncBusiness(approval) {
  if (approval.kind !== 'stocktake' || !approval.ref) return;
  const no = approval.ref;
  if (approval.status === 'approved') {
    db.prepare('UPDATE inv_sheets SET approval_status = 2, reject_reason = NULL WHERE sheet_no = ?').run(no);
  } else if (approval.status === 'rejected') {
    db.prepare('UPDATE inv_sheets SET approval_status = 3, reject_reason = ? WHERE sheet_no = ?')
      .run(approval.reject_reason, no);
  }
}

// ============================================================
// 提交审批
// ============================================================

router.post('/submit', (req, res) => {
  const u = auth(req, res); if (!u) return;
  const b = req.body || {};
  const kind = text(b.kind, 40);
  if (!kind) return res.status(400).json({ error: 'kind 不能为空' });
  if (!KINDS.includes(kind)) {
    // 不认识的业务类型**要拦**，而不是"先存着"：
    // 存进来没人知道怎么审、审完也不知道该同步哪张表，只会变成一堆僵尸单。
    return res.status(400).json({ error: `未知的审批类型 ${kind}` });
  }

  const ref = text(b.ref, MAX_REF);
  const title = text(b.title, MAX_TITLE);

  // 盘点单的归属校验：只能提自己的单（管理员不限）
  if (kind === 'stocktake') {
    if (!ref) return res.status(400).json({ error: 'stocktake 审批必须带 ref（盘点单号）' });
    const sheet = db.prepare('SELECT sheet_no, zone_code, phase, status, operator_id FROM inv_sheets WHERE sheet_no = ?').get(ref);
    if (!sheet) return res.status(404).json({ error: `盘点单 ${ref} 不存在` });
    if (u.role !== 'admin' && sheet.operator_id !== u.id) {
      return res.status(403).json({ error: '只能提交自己的盘点单审批' });
    }
  }

  // 同一对象不允许有两条待审（否则批了一条另一条还挂着，谁都不知道该看哪条）
  const dup = db.prepare(
    "SELECT id FROM approvals WHERE kind = ? AND ref IS ? AND status = 'pending'"
  ).get(kind, ref);
  if (dup) {
    return res.status(409).json({ error: '这个对象已经有一条待审批了', code: 'already_pending', id: dup.id });
  }

  let payload = null;
  if (b.payload !== undefined && b.payload !== null) {
    payload = typeof b.payload === 'string' ? b.payload : JSON.stringify(b.payload);
    if (Buffer.byteLength(payload, 'utf8') > MAX_PAYLOAD) {
      return res.status(400).json({ error: `payload 过大（上限 ${MAX_PAYLOAD} 字节）` });
    }
  }

  const now = Date.now();
  const info = db.prepare(`
    INSERT INTO approvals (kind, title, ref, payload, status, submitter_id, submitter_name, created_at)
    VALUES (?,?,?,?, 'pending', ?,?,?)
  `).run(kind, title, ref, payload, u.id, u.nickname || u.username, now);

  // 单据同步标"待审批"：列表页据此显示，不必再 join
  if (kind === 'stocktake' && ref) {
    db.prepare('UPDATE inv_sheets SET approval_status = 1, reject_reason = NULL WHERE sheet_no = ?').run(ref);
  }

  const row = db.prepare('SELECT * FROM approvals WHERE id = ?').get(info.lastInsertRowid);
  res.json({ approval: publicApproval(row) });
});

// ============================================================
// 查
// ============================================================

/** 我提交的（`?status=pending|approved|rejected`） */
router.get('/mine', (req, res) => {
  const u = auth(req, res); if (!u) return;
  const st = text(req.query.status, 20);
  if (st && !['pending', 'approved', 'rejected'].includes(st)) {
    return res.status(400).json({ error: 'status 只能是 pending / approved / rejected' });
  }
  const rows = st
    ? db.prepare('SELECT * FROM approvals WHERE submitter_id = ? AND status = ? ORDER BY created_at DESC').all(u.id, st)
    : db.prepare('SELECT * FROM approvals WHERE submitter_id = ? ORDER BY created_at DESC').all(u.id);
  res.json({ items: rows.map(publicApproval) });
});

/**
 * 待我审的。
 *
 * 🔴 现在只有管理员能审（这个系统的角色就只有 user/admin 两种）。
 *    真要做"部门主管审本部门"，得先把角色体系铺开 —— 那属于后面的事，
 *    这里不假装支持：`can_approve` 明确回给客户端，界面据此显示按钮。
 */
router.get('/pending', (req, res) => {
  const u = auth(req, res); if (!u) return;
  const rows = db.prepare("SELECT * FROM approvals WHERE status = 'pending' ORDER BY created_at ASC").all();
  res.json({
    can_approve: u.role === 'admin',
    items: rows.map(publicApproval),
  });
});

router.get('/:id', (req, res) => {
  const u = auth(req, res); if (!u) return;
  const id = Number(req.params.id);
  if (!Number.isInteger(id) || id <= 0) return res.status(400).json({ error: 'id 不合法' });
  const row = db.prepare('SELECT * FROM approvals WHERE id = ?').get(id);
  if (!row) return res.status(404).json({ error: '审批单不存在' });
  // 只有提交人、审批人（管理员）能看
  if (u.role !== 'admin' && row.submitter_id !== u.id) return res.status(403).json({ error: 'forbidden' });
  res.json({ approval: publicApproval(row) });
});

// ============================================================
// 落决定
// ============================================================

function decide(req, res, verdict) {
  const u = auth(req, res, { needAdmin: true }); if (!u) return;
  const id = Number(req.params.id);
  if (!Number.isInteger(id) || id <= 0) return res.status(400).json({ error: 'id 不合法' });

  const row = db.prepare('SELECT * FROM approvals WHERE id = ?').get(id);
  if (!row) return res.status(404).json({ error: '审批单不存在' });

  // 🔴 只有待审能落决定。已批的再点一次若"顺手"成功，
  //    审批结论就取决于谁最后点，事后完全说不清是批还是驳。
  if (row.status !== 'pending') {
    return res.status(409).json({
      error: row.status === 'approved' ? '这条已经批准过了' : '这条已经驳回过了',
      code: 'already_decided',
      status: row.status,
      decided_by_name: row.decided_by_name,
      decided_at: row.decided_at,
    });
  }

  // 🔴 自提自批 = 没有审批
  if (row.submitter_id === u.id) {
    return res.status(403).json({ error: '不能审批自己提交的单', code: 'self_approve' });
  }

  let reason = null;
  if (verdict === 'rejected') {
    reason = text((req.body || {}).reason, MAX_REASON);
    if (!reason) {
      return res.status(400).json({ error: '请输入驳回理由', code: 'reason_required' });
    }
  }

  const now = Date.now();
  db.prepare(`
    UPDATE approvals
       SET status = ?, decided_by = ?, decided_by_name = ?, decided_at = ?, reject_reason = ?
     WHERE id = ? AND status = 'pending'
  `).run(verdict, u.id, u.nickname || u.username, now, reason, id);

  const after = db.prepare('SELECT * FROM approvals WHERE id = ?').get(id);
  syncBusiness(after);
  res.json({ approval: publicApproval(after) });
}

router.post('/:id/approve', (req, res) => decide(req, res, 'approved'));
router.post('/:id/reject', (req, res) => decide(req, res, 'rejected'));

/**
 * 撤回（提交人自己，且只在待审时）。
 *
 * 提错了、数还没确认就点提交了 —— 不给撤回，人只能去找管理员驳回，
 * 那条审批记录上就永远挂着一个"被驳回"，不是他的错却记在他头上。
 */
router.post('/:id/withdraw', (req, res) => {
  const u = auth(req, res); if (!u) return;
  const id = Number(req.params.id);
  if (!Number.isInteger(id) || id <= 0) return res.status(400).json({ error: 'id 不合法' });
  const row = db.prepare('SELECT * FROM approvals WHERE id = ?').get(id);
  if (!row) return res.status(404).json({ error: '审批单不存在' });
  if (row.submitter_id !== u.id && u.role !== 'admin') return res.status(403).json({ error: 'forbidden' });
  if (row.status !== 'pending') {
    return res.status(409).json({ error: '已经审完了，撤不回来', code: 'already_decided', status: row.status });
  }
  db.prepare('DELETE FROM approvals WHERE id = ?').run(id);
  if (row.kind === 'stocktake' && row.ref) {
    db.prepare('UPDATE inv_sheets SET approval_status = 0 WHERE sheet_no = ?').run(row.ref);
  }
  res.json({ ok: true, id });
});

module.exports = router;
