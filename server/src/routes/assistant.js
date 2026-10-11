// 智能助手路由（#314）。
//   /api/assistant/ask          任何登录用户可问（这是"接管帮助"的入口）
//   /api/admin/assistant/*      管理台：看/存配置（Key 只回 hasKey）、试问
'use strict';

const express = require('express');
const db = require('../db');
const { verifyToken } = require('../auth');
const assistant = require('../assistant');

const router = express.Router();
const admin = express.Router();

function uidOf(req, res) {
  const c = verifyToken(req.headers.authorization?.replace('Bearer ', ''));
  if (!c) { res.status(401).json({ error: 'unauthorized' }); return null; }
  if (!db.prepare('SELECT id FROM users WHERE id=?').get(c.uid)) {
    res.status(401).json({ error: 'unauthorized' }); return null;
  }
  return c.uid;
}

function adminOf(req, res) {
  const c = verifyToken(req.headers.authorization?.replace('Bearer ', ''));
  if (!c) { res.status(401).json({ error: 'unauthorized' }); return null; }
  const u = db.prepare('SELECT role FROM users WHERE id=?').get(c.uid);
  if (!u) { res.status(401).json({ error: 'unauthorized' }); return null; }
  if (u.role !== 'admin') { res.status(403).json({ error: 'forbidden' }); return null; }
  return c.uid;
}

/* ==================== 用户侧 ==================== */

router.post('/ask', async (req, res) => {
  if (uidOf(req, res) === null) return;
  const { question } = req.body || {};
  const out = await assistant.ask(question);
  if (out.error) return res.status(400).json(out);
  res.json(out);
});

/* ==================== 管理端 ==================== */

admin.get('/config', (req, res) => {
  if (adminOf(req, res) === null) return;
  const { enabled, apiBase, model, hasKey } = assistant.getConfig();
  res.json({ enabled, apiBase, model, hasKey });
});

admin.put('/config', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  const r = assistant.saveConfig(req.body, 'admin:' + uid);
  if (r.error) return res.status(400).json(r);
  const { enabled, apiBase, model, hasKey } = assistant.getConfig();
  res.json({ ok: true, enabled, apiBase, model, hasKey });
});

/** 试问：LLM 配好了就算总开关没开也真调（force），让管理员配完当场验证 */
admin.post('/test', async (req, res) => {
  if (adminOf(req, res) === null) return;
  const { question } = req.body || {};
  const out = await assistant.ask(question, { force: true });
  if (out.error) return res.status(400).json(out);
  res.json(out);
});

module.exports = router;
module.exports.admin = admin;
