/**
 * 排班管理接口（管理台「排班管理」周视图 + 模块数据底座的后台一半）
 *
 *   GET  /api/admin/duty/week?day=YYYY-MM-DD   周视图数据（行=员工 列=7天 + 班次色板）
 *   POST /api/admin/duty/cell                  存一个格子（upsert）
 *   POST /api/admin/duty/batch                 整列批量填充（一天一批人）
 *   POST /api/admin/duty/clear-day             清空一整天
 *   POST /api/admin/duty/clear-range           清空一段日期
 *   DELETE /api/admin/duty/cell?day=&userId=   删一个格子
 *
 * 与手机端表单（POST /api/hooks/local/duty/schedules）**共用 duty.js 引擎**：
 * 校验规则、班次口径、upsert 语义只有一份。这里只多做三件事：
 *   ① 身份：管理员 + 组织存在（attendance.js 的 adminGuard 同款，不要求工作模式 ——
 *      管理员要能在还没切工作模式时先把班表配好）；
 *   ② 批量：整列填充/清空是管理台独有的操作（手机表单一次只动一格）；
 *   ③ 周视图的一页数据：员工行 + 7 天格子 + 班次清单一次给全，
 *      管理台页打开只要一个请求。
 *
 * 🔴 为什么不复用 /api/hooks/local/duty/schedules 的 GET：那条路被
 *    LOCAL_ROWS_MAX=200 截断、且窗口写死"某周起 7 天"。管理台要翻到
 *    几个月后排班、要看到全量，口径不同就不能共用一个出口。
 */

const express = require('express');
const db = require('../db');
const { verifyToken } = require('../auth');
const att = require('../attendance');
const duty = require('../duty');

const router = express.Router();

function adminGuard(req, res) {
  const c = verifyToken(String(req.headers.authorization || '').replace('Bearer ', ''));
  if (!c) { res.status(401).json({ error: 'unauthorized' }); return null; }
  const u = db.prepare('SELECT id, role FROM users WHERE id=?').get(c.uid);
  if (!u || u.role !== 'admin') { res.status(403).json({ error: 'forbidden' }); return null; }
  const org = db.prepare('SELECT id, name FROM orgs LIMIT 1').get();
  if (!org) { res.status(404).json({ error: '尚未创建组织，排班不可用' }); return null; }
  return { uid: u.id, org };
}

/** 周视图一页数据：员工行 + 7 天格子 + 班次清单（格子编辑器要画班次按钮）
 *
 * ?day= 不给时默认**今天所在周**（从今天起 7 天）：管理台点开菜单就该看到
 * "眼前这一周"，而不是一张要求先选日期的空表。
 */
router.get('/week', (req, res) => {
  const g = adminGuard(req, res); if (!g) return;
  const w = duty.week(g.org.id, req.query.day || att.today());
  if (w.error) return res.status(400).json({ error: w.error });
  // 班次清单给管理台的格子编辑器用：与表单下拉同一份（att_shifts），
  // 但**包含停用的**（历史上排了停用班，管理台要能看见并改掉）
  const shifts = att.listShifts(g.org.id).map((s) => ({
    id: s.id,
    name: s.name,
    text: duty.shiftText(s),
    enabled: s.enabled,
    crossDay: s.crossDay,
  }));
  res.json({
    ok: true,
    org: { id: g.org.id, name: g.org.name },
    days: w.days,
    users: w.users,
    cells: w.cells,
    workedDays: w.workedDays,
    shifts,
  });
});

/** 存一个格子。body 与手机表单完全同构（day/userId/shiftId/position/note） */
router.post('/cell', (req, res) => {
  const g = adminGuard(req, res); if (!g) return;
  const r = duty.save(g.org.id, g.uid, req.body || {});
  if (r.error) return res.status(r.code || 400).json({ error: r.error });
  res.json(r);
});

/** 整列批量填充。userIds 不传 = 全员 */
router.post('/batch', (req, res) => {
  const g = adminGuard(req, res); if (!g) return;
  const r = duty.batchFill(g.org.id, g.uid, req.body || {});
  if (r.error) return res.status(r.code || 400).json({ error: r.error });
  res.json(r);
});

/** 清空一整天（整列清空） */
router.post('/clear-day', (req, res) => {
  const g = adminGuard(req, res); if (!g) return;
  const r = duty.removeDay(g.org.id, (req.body || {}).day);
  if (r.error) return res.status(400).json({ error: r.error });
  res.json(r);
});

/** 清空一段日期（清空本周/本月） */
router.post('/clear-range', (req, res) => {
  const g = adminGuard(req, res); if (!g) return;
  const b = req.body || {};
  const r = duty.removeRange(g.org.id, b.from, b.to);
  if (r.error) return res.status(400).json({ error: r.error });
  res.json(r);
});

/** 删一个格子（某人某天改回"没排"） */
router.delete('/cell', (req, res) => {
  const g = adminGuard(req, res); if (!g) return;
  const r = duty.remove(g.org.id, req.query.day, req.query.userId);
  if (r.error) return res.status(400).json({ error: r.error });
  res.json(r);
});

module.exports = router;
