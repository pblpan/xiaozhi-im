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
const pkg = require('../../package.json');

function uidOf(req, res) {
  const c = verifyToken(req.headers.authorization?.replace('Bearer ', ''));
  if (!c) { res.status(401).json({ error: 'unauthorized' }); return null; }
  return c.uid;
}

/** 冷启动拉取（未登录可访问） */
router.get('/bootstrap', (req, res) => {
  const cur = clientconfig.current();
  res.json({
    configVersion: cur.version,
    serverVersion: pkg.version,
    payload: cur.payload,
    ts: Date.now(),
  });
});

/** 已登录拉取（Phase 1 内容与 bootstrap 相同，预留用户定向配置的扩展位） */
router.get('/config', (req, res) => {
  const uid = uidOf(req, res); if (uid === null) return;
  const cur = clientconfig.current();
  res.json({
    configVersion: cur.version,
    serverVersion: pkg.version,
    payload: cur.payload,
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

module.exports = router;
