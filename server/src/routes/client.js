/**
 * 客户端配置接口（SPEC §6）
 *
 * /bootstrap 免鉴权的原因：App 冷启动时可能还没登录，此时恰恰最需要拿到
 * 地址候选与维护公告。要求鉴权会变成"连不上 → 拿不到配置 → 永远连不上"死锁。
 * 代价是内容对未授权者可见，所以这里只能返回公开信息（地址/公告/开关/版本策略），
 * 绝不能混入 token、密钥、用户数据 —— 见 SPEC §6.1 的硬边界。
 */
const router = require('express').Router();
const { verifyToken } = require('../auth');
const clientconfig = require('../clientconfig');
const appmodules = require('../appmodules');
const db = require('../db');
const pkg = require('../../package.json');

function uidOf(req, res) {
  const c = verifyToken(req.headers.authorization?.replace('Bearer ', ''));
  if (!c) { res.status(401).json({ error: 'unauthorized' }); return null; }
  return c.uid;
}

/** 取用户角色（用于按角色下发模块）；查不到当作普通 user，不因此报错 */
function roleOf(uid) {
  const u = db.prepare('SELECT role FROM users WHERE id=?').get(uid);
  return u?.role || 'user';
}

/** 冷启动拉取（未登录可访问）
 *  注意：这里只下发"对所有人可见"的模块（visibleTo 为空），
 *  用户定向模块必须走 /config（需登录），否则免鉴权接口会泄露"谁有权看什么"。 */
router.get('/bootstrap', (req, res) => {
  const cur = clientconfig.current();
  const cv = String(req.query.clientVersion || '');
  const allModules = appmodules.listVisible({ clientVersion: cv })
    .filter((m) => !(m.visibleTo?.roles?.length || m.visibleTo?.userIds?.length));
  res.json({
    configVersion: cur.version,
    serverVersion: pkg.version,
    payload: cur.payload,
    modules: allModules,
    ts: Date.now(),
  });
});

/** 已登录拉取：完整配置 + 按角色/用户过滤后的动态模块 */
router.get('/config', (req, res) => {
  const uid = uidOf(req, res); if (uid === null) return;
  const cur = clientconfig.current();
  const cv = String(req.query.clientVersion || '');
  res.json({
    configVersion: cur.version,
    serverVersion: pkg.version,
    payload: cur.payload,
    modules: appmodules.listVisible({ userId: uid, role: roleOf(uid), clientVersion: cv }),
    ts: Date.now(),
  });
});

/** 客户端上报已生效版本（写 config_applied，管理台"同步状态"的数据来源） */
router.post('/report-applied', (req, res) => {
  const uid = uidOf(req, res); if (uid === null) return;
  const ok = clientconfig.reportApplied(uid, req.body?.deviceId, req.body?.configVersion);
  if (!ok) return res.status(400).json({ error: 'configVersion 不合法' });
  res.json({ ok: true });
});

/** 单个模块定义（打开动态页面时拉取，保证拿到的是最新一版，不吃冷启动缓存） */
router.get('/modules/:id', (req, res) => {
  const uid = uidOf(req, res); if (uid === null) return;
  const cv = String(req.query.clientVersion || '');
  const m = appmodules.get(req.params.id);
  if (!m || !m.enabled) return res.status(404).json({ error: '模块不存在或已停用' });
  const visible = appmodules.listVisible({ userId: uid, role: roleOf(uid), clientVersion: cv })
    .some((x) => x.moduleId === m.moduleId);
  if (!visible) return res.status(403).json({ error: '无权访问该模块' });
  res.json({ module: m, ts: Date.now() });
});

/**
 * 动态表单提交。
 * 安全要点：字段白名单取自**服务端存的 schema**，不是客户端传的定义——
 * 否则客户端可以自己发明字段往库里塞任何东西（见 sanitizeSubmission）。
 */
router.post('/modules/:id/submit', (req, res) => {
  const uid = uidOf(req, res); if (uid === null) return;
  const cv = String((req.body && req.body.clientVersion) || req.query.clientVersion || '');
  const m = appmodules.get(req.params.id);
  if (!m || !m.enabled) return res.status(404).json({ error: '模块不存在或已停用' });
  const visible = appmodules.listVisible({ userId: uid, role: roleOf(uid), clientVersion: cv })
    .some((x) => x.moduleId === m.moduleId);
  if (!visible) return res.status(403).json({ error: '无权访问该模块' });
  const r = appmodules.recordSubmission(req.params.id, uid, req.body?.data);
  if (r.error) return res.status(400).json({ error: r.error });
  res.json({ ok: true, id: r.id });
});

module.exports = router;
