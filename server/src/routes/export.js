/**
 * 导出记录 + 格式设定的接口（需求④，龙哥 2026-10-22）
 *
 * 员工端（用户令牌，挂 /api/export）：
 *   GET  /settings          读格式设定（客户端「个人中心 → 格式设定」打开时拉）
 *   PUT  /settings          存格式设定（局部更新，没传的键保持原值）
 *   POST /records           导出了一份文件后记一笔账
 *   GET  /records           我的导出记录（本机/换机都能看到同一份历史）
 *
 * 管理端（管理员令牌，挂 /api/admin/export）：
 *   GET  /records           全量台账（可按用户/模块过滤）
 *   POST /records/purge     清理 N 天前的记录
 *   GET  /settings          管理台看格式设定
 *   PUT  /settings          管理台改格式设定
 *
 * 🔴 为什么员工端也能 PUT /settings：格式设定是"这台服务器的导出习惯"
 *    （托利多组号、PLU 来源这些），不是密钥也不是权限 —— 门店里谁需要
 *    谁就改，和"公司名只能管理员改"不同类。想收紧成管理员专属的话，
 *    把员工端 PUT 删掉、只留管理端那一半即可，客户端会自然降级为只读。
 *
 * 文件本身不过服务端：客户端本地生成、本地落盘，这里只记账
 * （理由见 exportfmt.js 头部）。所以 records 里只有文件名与行数，
 * 没有文件内容、也没有下载入口 —— 想再拿一份请到那台设备上重新导出。
 */

const express = require('express');
const db = require('../db');
const { verifyToken } = require('../auth');
const fmt = require('../exportfmt');

const router = express.Router();
const admin = express.Router();

/** 员工端鉴权：返回 { uid, username } 或 null（已回 401） */
function userOf(req, res) {
  const c = verifyToken(String(req.headers.authorization || '').replace('Bearer ', ''));
  if (!c) { res.status(401).json({ error: 'unauthorized' }); return null; }
  const u = db.prepare('SELECT id, username, nickname FROM users WHERE id=?').get(c.uid);
  if (!u) { res.status(401).json({ error: 'unauthorized' }); return null; }
  return { uid: u.id, username: u.username };
}

/** 管理端鉴权（与 duty.js 的 adminGuard 同款） */
function adminOf(req, res) {
  const c = verifyToken(String(req.headers.authorization || '').replace('Bearer ', ''));
  if (!c) { res.status(401).json({ error: 'unauthorized' }); return null; }
  const u = db.prepare('SELECT id, role FROM users WHERE id=?').get(c.uid);
  if (!u || u.role !== 'admin') { res.status(403).json({ error: 'forbidden' }); return null; }
  return { uid: u.id };
}

// ---- 员工端：格式设定 ----
router.get('/settings', (req, res) => {
  const u = userOf(req, res); if (!u) return;
  res.json(fmt.getSettings());
});

router.put('/settings', (req, res) => {
  const u = userOf(req, res); if (!u) return;
  const r = fmt.saveSettings(req.body, u.username);
  if (r.error) return res.status(400).json({ error: r.error });
  res.json({ ok: true, settings: r.settings });
});

// ---- 员工端：导出记录 ----
// body: { module, moduleName, docNo, formatId, formatName, fileName, rows, ext }
router.post('/records', (req, res) => {
  const u = userOf(req, res); if (!u) return;
  const b = req.body || {};
  const r = fmt.addRecord({
    userId: u.uid,
    username: u.username,
    module: b.module,
    moduleName: b.moduleName,
    docNo: b.docNo,
    formatId: b.formatId,
    formatName: b.formatName,
    fileName: b.fileName,
    rows: b.rows,
    ext: b.ext,
  });
  if (r.error) return res.status(400).json({ error: r.error });
  res.json({ ok: true, id: r.id });
});

router.get('/records', (req, res) => {
  const u = userOf(req, res); if (!u) return;
  const { module, limit, offset } = req.query || {};
  res.json(fmt.listRecords({ userId: u.uid, module, limit, offset }));
});

// ---- 管理端 ----
admin.get('/records', (req, res) => {
  const g = adminOf(req, res); if (!g) return;
  const { user, module, limit, offset } = req.query || {};
  const uid = user ? Number(user) : null;
  if (user && !Number.isFinite(uid)) return res.status(400).json({ error: 'user 需为用户 id' });
  res.json(fmt.listRecords({ userId: uid || undefined, module, limit, offset }));
});

// 清理 N 天前的记录。body: { days }，不给按保留期（180 天）清。
admin.post('/records/purge', (req, res) => {
  const g = adminOf(req, res); if (!g) return;
  const days = Number((req.body || {}).days) || fmt.RETAIN_DAYS;
  res.json({ ok: true, ...fmt.purge(days) });
});

admin.get('/settings', (req, res) => {
  const g = adminOf(req, res); if (!g) return;
  res.json(fmt.getSettings());
});

admin.put('/settings', (req, res) => {
  const g = adminOf(req, res); if (!g) return;
  const r = fmt.saveSettings(req.body, String(g.uid));
  if (r.error) return res.status(400).json({ error: r.error });
  res.json({ ok: true, settings: r.settings });
});

module.exports = router;
module.exports.admin = admin;
