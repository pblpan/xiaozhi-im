'use strict';
/**
 * 授权相关接口。
 *
 * 挂载在 /api/license 之下，且在 license.gate 的放行名单里 —— 这是刻意的：
 * 授权到期后，管理员仍然要能被前端告知「发生了什么、机器码是多少、去哪填码」。
 * 只放行这几条，业务接口照拦不误。
 */
const router = require('express').Router();
const db = require('../db');
const { verifyToken } = require('../auth');
const license = require('../license');

/** 校验管理员身份（与 admin.js 的 adminOf 同一套判定） */
function adminOf(req, res) {
  const c = verifyToken(req.headers.authorization?.replace('Bearer ', ''));
  if (!c) { res.status(401).json({ error: 'unauthorized' }); return null; }
  const u = db.prepare('SELECT role FROM users WHERE id=?').get(c.uid);
  if (!u || u.role !== 'admin') { res.status(403).json({ error: 'forbidden' }); return null; }
  return c.uid;
}

/** 当前授权状态（免鉴权）。
 *  登录页在用户还没登录时就要显示「这台服务器是谁、授权还剩几天」，
 *  带上机器码也不泄露任何用户数据 —— 它本来就是给管理员抄去出码的。 */
router.get('/', (req, res) => {
  res.json(license.publicState());
});

/** 激活 / 换码。需管理员。 */
router.post('/activate', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  const token = req.body?.token;
  if (!token || typeof token !== 'string') return res.status(400).json({ error: '请填写授权码' });
  const r = license.activate(token, uid);
  if (r.error) {
    // 400 而不是 403：这是「填错了」，不是「没权限」。
    // 前端按 403 会去清 token 跳登录页，把管理员踢出去，体验很糟。
    return res.status(400).json(r);
  }
  res.json(r);
});

/** 解绑本机授权（排查/换机前使用）。需管理员。 */
router.post('/deactivate', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  const r = license.deactivate(uid);
  if (r.error) return res.status(400).json(r);
  res.json(r);
});

module.exports = router;
