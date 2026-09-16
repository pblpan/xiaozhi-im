'use strict';
/**
 * 推送相关接口。
 *
 * 分两半：
 *   · 客户端侧（挂在 /api/push，需登录）：登记/注销本机设备令牌、查我的设备
 *   · 管理台侧（挂在 /api/admin/push，需管理员）：配置 Apple 密钥、自检、发测试推送、看投递日志
 *
 * 【为什么设备令牌由客户端上报而不是服务端嗅探】令牌是 APNs 在**装机后**
 * 交给这台设备的，只有设备自己知道；它还会在重装/恢复备份后变化。
 * 所以只能"客户端拿到就上报，退出登录就注销"。
 *
 * 【为什么注销要删行而不是置 inactive】同一台手机换人登录时，令牌是同一个。
 * 留着旧行只会让"上一任用户的推送"继续投到这台手机上 —— 那是最严重的一类
 * 隐私事故（别人拿到你手机前，先收到你同事发来的私聊内容）。删除最干净。
 */

const router = require('express').Router();
const db = require('../db');
const { verifyToken } = require('../auth');
const push = require('../push');

function uidOf(req, res) {
  const c = verifyToken(req.headers.authorization?.replace('Bearer ', ''));
  if (!c) { res.status(401).json({ error: 'unauthorized' }); return null; }
  return c.uid;
}

function adminOf(req, res) {
  const c = verifyToken(req.headers.authorization?.replace('Bearer ', ''));
  if (!c) { res.status(401).json({ error: 'unauthorized' }); return null; }
  const u = db.prepare('SELECT role FROM users WHERE id=?').get(c.uid);
  if (!u || u.role !== 'admin') { res.status(403).json({ error: 'forbidden' }); return null; }
  return c.uid;
}

// ---------------------------------------------------------------------------
// 客户端
// ---------------------------------------------------------------------------

/**
 * POST /api/push/register
 * body: { token, platform?, env?, topic?, deviceName? }
 *
 * 幂等：同一台设备重复上报只是刷新 updated_at 并把 active 置回 1
 * （令牌从"被判失效"回到"有效"的唯一途径就是重新上报）。
 */
router.post('/register', (req, res) => {
  const uid = uidOf(req, res); if (uid === null) return;
  const b = req.body || {};
  const r = push.registerDevice({
    userId: uid,
    token: b.token,
    platform: b.platform || 'ios',
    env: b.env,
    topic: b.topic,
    deviceName: b.deviceName,
  });
  if (r.error) return res.status(400).json({ error: r.error });
  res.json({
    ok: true,
    device: { id: r.device.id, env: r.device.env, platform: r.device.platform, active: !!r.device.active },
    // 告诉客户端"服务端到底会不会推"：没配密钥时上报成功但不会有推送，
    // 客户端可以据此在设置页显示"服务器未开启推送"，而不是让用户干等。
    serverEnabled: push.enabled(),
  });
});

/** POST /api/push/unregister  body: { token } —— 退出登录 / 关通知开关时调 */
router.post('/unregister', (req, res) => {
  const uid = uidOf(req, res); if (uid === null) return;
  const r = push.unregisterDevice({ userId: uid, token: req.body?.token });
  if (r.error) return res.status(400).json({ error: r.error });
  res.json(r);
});

/** GET /api/push/devices —— 我登记过的设备（令牌只回尾号） */
router.get('/devices', (req, res) => {
  const uid = uidOf(req, res); if (uid === null) return;
  res.json({ serverEnabled: push.enabled(), devices: push.devicesOf(uid) });
});

// ---------------------------------------------------------------------------
// 管理台
// ---------------------------------------------------------------------------

const admin = require('express').Router();

/** GET /api/admin/push —— 状态 + 统计 + 最近投递 */
admin.get('/', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  res.json({
    info: push.info(),
    stats: push.stats(),
    logs: push.recentLogs(req.query.limit || 50),
  });
});

/**
 * POST /api/admin/push/probe —— 本地自检
 *
 * 可以带上"还没保存"的凭据：服务端只在内存里临时试签一次就还原，
 * **绝不落盘**。所以管理员可以先试再存，试错不会把线上配置改坏。
 */
admin.post('/probe', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  const b = req.body || {};
  const any = ['keyId', 'teamId', 'topic', 'keyP8', 'env'].some((k) => b[k] !== undefined);
  res.json(any ? push.probeWith(b) : push.probe());
});

/** POST /api/admin/push/config —— 保存并**立即生效**（同时落盘 apns.env） */
admin.post('/config', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  const b = req.body || {};
  push.applyConfig({
    keyId: b.keyId, teamId: b.teamId, topic: b.topic, keyP8: b.keyP8, env: b.env,
  });
  const p = push.probe();
  res.json({ ok: true, info: push.info(), probe: p });
});

/** POST /api/admin/push/clear —— 清空配置（换 App / 排障） */
admin.post('/clear', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  res.json({ ok: true, info: push.clearConfig() });
});

/**
 * POST /api/admin/push/test  body: { userId?, token? }
 *
 * 发一条真推送。这是**唯一**能证明"Apple 认这对密钥"的办法 ——
 * 本地自检只能证明私钥能签名。
 */
admin.post('/test', async (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  if (!push.enabled()) return res.status(400).json({ error: '还没配置推送（缺 Key ID / Team ID / Bundle ID / .p8 私钥）' });

  const token = String(req.body?.token || '').replace(/[\s<>]/g, '').toLowerCase();
  const targetUser = Number(req.body?.userId) || uid;

  let device;
  if (token) {
    device = db.prepare('SELECT * FROM push_devices WHERE token = ?').get(token);
  } else {
    device = db.prepare(
      "SELECT * FROM push_devices WHERE user_id = ? AND active = 1 AND platform = 'ios' ORDER BY updated_at DESC LIMIT 1"
    ).get(targetUser);
  }
  if (!device) {
    return res.status(400).json({
      error: '这台设备上没有已登记的 iOS 令牌。先在 iPhone 上打开 App 并允许通知，再回来发测试。',
    });
  }
  if (device.env !== push.info().env) {
    return res.status(400).json({
      error: `令牌是 ${device.env} 环境的，而服务端当前配的是 ${push.info().env}：`
        + `用真机装出来的包一般走 production，Xcode 直连调试走 sandbox。两边要一致。`,
    });
  }

  const r = await push.sendToUser(device.user_id, {
    title: '小智 IM 测试推送',
    body: '看到这条说明服务端到你手机的推送链路是通的。',
    collapseId: 'push-test',
    data: { type: 'push-test' },
  });
  const log = push.recentLogs(1)[0] || null;
  res.json({ ok: (r.ok || 0) > 0, result: r, lastLog: log });
});

/** POST /api/admin/push/sweep —— 手动清老日志 */
admin.post('/sweep', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  res.json({ ok: true, removed: push.sweep(Number(req.body?.days) || 30) });
});

module.exports = router;
module.exports.admin = admin;
