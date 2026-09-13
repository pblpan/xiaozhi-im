// 远程协助：访问码管理 + 会话审计查询
//
// 注意这里**不放任何屏幕画面 / 键鼠数据** —— 那些全走 WebRTC P2P，
// 服务端一根手指都不碰。服务端只做三件事：访问码、会话记录、以及在必要时通告。
const router = require('express').Router();
const { verifyToken } = require('../auth');
const remote = require('../remote');

function uidOf(req, res) {
  const c = verifyToken(req.headers.authorization?.replace('Bearer ', ''));
  if (!c) { res.status(401).json({ error: 'unauthorized' }); return null; }
  return c.uid;
}

// ---- 访问码 ----

// 我名下的访问码列表。
// ⚠️ 只回 metadata，**永不回明文**（库里本来就只有哈希，明文是一次性给出去的）。
router.get('/codes', (req, res) => {
  const uid = uidOf(req, res); if (uid === null) return;
  res.json({ items: remote.listCodes(uid) });
});

// 生成一个新访问码。body: { label, singleUse, ttlMinutes }
// 返回的 code 是**唯一一次**能看到明文的机会，之后连自己也查不到。
router.post('/codes', (req, res) => {
  const uid = uidOf(req, res); if (uid === null) return;
  const b = req.body || {};
  const r = remote.createCode({
    userId: uid,
    label: b.label,
    singleUse: !!b.singleUse,
    ttlMinutes: b.ttlMinutes,
  });
  if (r.error) return res.status(400).json({ error: r.error });
  res.json(r);
});

// 吊销访问码。吊销后立刻失效 —— 这是"怀疑码泄漏"时唯一的止损手段。
router.delete('/codes/:id', (req, res) => {
  const uid = uidOf(req, res); if (uid === null) return;
  // Number('abc') 是 NaN，NaN 绑定进 SQL 会变成 NULL，`id = NULL` 永远
  // 不成立 —— 那倒是"安全"的（删不掉），但会返回一个让人困惑的 404。
  // 提前挡掉，让"参数非法"和"不是你的码"是两种可区分的错误。
  const id = Number(req.params.id);
  if (!Number.isInteger(id) || id <= 0) {
    return res.status(400).json({ error: '访问码 id 不合法' });
  }
  const r = remote.revokeCode({ userId: uid, id });
  if (!r.ok) return res.status(404).json({ error: '访问码不存在或不属于你' });
  res.json({ ok: true });
});

// ---- 会话 ----

// 我参与过的远程协助会话（被控 + 控制都算），按时间倒序。
router.get('/sessions', (req, res) => {
  const uid = uidOf(req, res); if (uid === null) return;
  res.json({ items: remote.history(uid, req.query.limit) });
});

// 当前进行中的会话。App 重启 / 重连后靠它恢复控制界面，
// 不用对方重新敲门。
router.get('/current', (req, res) => {
  const uid = uidOf(req, res); if (uid === null) return;
  res.json({ session: remote.currentOf(uid) });
});

module.exports = router;
