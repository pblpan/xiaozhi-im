// 集成管理接口（管理后台专用，JWT + 管理员角色）
//
// 挂在 /api/admin/integrations 下。管理动作（建机器人、发令牌、配 Webhook）都在这里，
// 与 /api/open（程序运行时调用）严格分开，避免"令牌能自己给自己提权"。
const express = require('express');
const db = require('../db');
const { verifyToken } = require('../auth');
const {
  SCOPES, createBot, listBots, getBot, deleteBot, ensureBotInConversation,
  createApiToken, listApiTokens, revokeApiToken, deleteApiToken,
  newHookToken, newSecret,
} = require('../integration');
const { EVENTS } = require('../events');
const dispatcher = require('../dispatcher');

const router = express.Router();

function adminOf(req, res) {
  const c = verifyToken(req.headers.authorization?.replace('Bearer ', ''));
  if (!c) { res.status(401).json({ error: 'unauthorized' }); return null; }
  const u = db.prepare('SELECT role FROM users WHERE id=?').get(c.uid);
  if (!u || u.role !== 'admin') { res.status(403).json({ error: 'forbidden' }); return null; }
  return c.uid;
}

/** 会话下拉选项：给"推到哪个群"用 */
function conversationOptions() {
  const groups = db.prepare(`SELECT c.id, g.name, g.id AS group_id,
      (SELECT COUNT(*) FROM conversation_members cm WHERE cm.conversation_id=c.id) members
    FROM conversations c JOIN groups g ON g.conversation_id = c.id
    ORDER BY g.id DESC`).all();
  const dms = db.prepare(`SELECT c.id,
      (SELECT GROUP_CONCAT(COALESCE(u.nickname,u.username), ' ↔ ') FROM conversation_members cm
        JOIN users u ON u.id=cm.user_id WHERE cm.conversation_id=c.id) AS name,
      (SELECT COUNT(*) FROM conversation_members cm WHERE cm.conversation_id=c.id) members
    FROM conversations c WHERE c.type='dm' ORDER BY c.id DESC LIMIT 100`).all();
  return [
    ...groups.map((g) => ({ id: g.id, type: 'group', title: g.name, members: g.members })),
    ...dms.map((d) => ({ id: d.id, type: 'dm', title: d.name, members: d.members })),
  ];
}

/* ==================== 元信息 ==================== */

router.get('/meta', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  res.json({
    scopes: Object.entries(SCOPES).map(([name, desc]) => ({ name, desc })),
    events: EVENTS,
    conversations: conversationOptions(),
    maxAttempts: dispatcher.MAX_ATTEMPTS,
  });
});

/* ==================== 机器人 ==================== */

router.get('/bots', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  res.json(listBots());
});

router.post('/bots', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  const { name, avatar, conversationId } = req.body || {};
  try {
    const bot = createBot({ name, ownerId: uid, avatar });
    // 建机器人时可直接拉进一个会话，省得再去群里加
    if (conversationId) ensureBotInConversation(bot.id, conversationId);
    res.json(bot);
  } catch (e) { res.status(400).json({ error: e.message }); }
});

router.post('/bots/:id/conversations', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  const bot = getBot(req.params.id);
  if (!bot) return res.status(404).json({ error: '机器人不存在' });
  try {
    const cid = ensureBotInConversation(bot.id, (req.body || {}).conversationId);
    res.json({ ok: true, botId: bot.id, conversationId: cid });
  } catch (e) { res.status(400).json({ error: e.message }); }
});

router.delete('/bots/:id', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  try { res.json(deleteBot(req.params.id)); }
  catch (e) { res.status(400).json({ error: e.message }); }
});

/* ==================== API 令牌 ==================== */

router.get('/tokens', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  res.json(listApiTokens());
});

router.post('/tokens', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  const { name, userId, scopes, expiresAt } = req.body || {};
  try {
    // 未指定身份时默认以当前管理员自己行事（最不容易出权限事故）
    res.json(createApiToken({ name, userId: userId || uid, scopes, expiresAt, createdBy: uid }));
  } catch (e) { res.status(400).json({ error: e.message }); }
});

router.post('/tokens/:id/revoke', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  try { res.json(revokeApiToken(req.params.id, (req.body || {}).revoked !== false)); }
  catch (e) { res.status(400).json({ error: e.message }); }
});

router.delete('/tokens/:id', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  try { res.json(deleteApiToken(req.params.id)); }
  catch (e) { res.status(400).json({ error: e.message }); }
});

/* ==================== 入站 Webhook ==================== */

function shapeIncoming(h) {
  return {
    id: h.id,
    name: h.name,
    token: h.token,
    path: `/api/hooks/incoming/${h.token}`,
    signed: !!h.secret,
    secret: h.secret || '',
    bot_id: h.bot_id,
    bot_name: h.bot_name || null,
    conversation_id: h.conversation_id,
    conversation_title: h.conversation_title || null,
    last_used_at: h.last_used_at || 0,
    revoked: !!h.revoked,
    created_at: h.created_at,
  };
}

const INCOMING_SELECT = `SELECT h.*, u.nickname AS bot_name,
    COALESCE(g.name, (SELECT GROUP_CONCAT(COALESCE(u2.nickname,u2.username), ' ↔ ')
      FROM conversation_members cm JOIN users u2 ON u2.id=cm.user_id
      WHERE cm.conversation_id=h.conversation_id)) AS conversation_title
  FROM incoming_hooks h
  LEFT JOIN users u ON u.id = h.bot_id
  LEFT JOIN groups g ON g.conversation_id = h.conversation_id`;

router.get('/incoming', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  res.json(db.prepare(`${INCOMING_SELECT} ORDER BY h.id DESC`).all().map(shapeIncoming));
});

router.post('/incoming', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  const { name, botId, conversationId, signed, secret } = req.body || {};
  const label = String(name || '').trim().slice(0, 64);
  if (!label) return res.status(400).json({ error: '名称不能为空' });
  if (!getBot(botId)) return res.status(400).json({ error: '请选择一个机器人' });
  try {
    ensureBotInConversation(botId, conversationId);
  } catch (e) { return res.status(400).json({ error: e.message }); }

  const info = db.prepare(`INSERT INTO incoming_hooks
    (name, token, secret, bot_id, conversation_id, created_by, created_at)
    VALUES (?,?,?,?,?,?,?)`)
    .run(label, newHookToken(), signed ? newSecret() : '', Number(botId),
      Number(conversationId), uid, Date.now());
  res.json(shapeIncoming(db.prepare(`${INCOMING_SELECT} WHERE h.id = ?`).get(info.lastInsertRowid)));
});

router.post('/incoming/:id/revoke', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  const id = Number(req.params.id);
  if (!db.prepare('SELECT id FROM incoming_hooks WHERE id=?').get(id)) {
    return res.status(404).json({ error: '不存在' });
  }
  db.prepare('UPDATE incoming_hooks SET revoked = ? WHERE id = ?')
    .run((req.body || {}).revoked === false ? 0 : 1, id);
  res.json({ ok: true, id });
});

router.delete('/incoming/:id', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  db.prepare('DELETE FROM incoming_hooks WHERE id = ?').run(Number(req.params.id));
  res.json({ ok: true });
});

/** 后台一键试推：省得为了验证地址去写 curl */
router.post('/incoming/:id/send', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  const h = db.prepare('SELECT * FROM incoming_hooks WHERE id = ?').get(Number(req.params.id));
  if (!h) return res.status(404).json({ error: '不存在' });
  const { sendMessage } = require('../chat');
  const b = req.body || {};
  try {
    const msg = sendMessage({
      conversationId: h.conversation_id,
      senderId: h.bot_id,
      kind: b.kind || 'text',
      content: b.content !== undefined ? b.content : (b.text || '这是一条来自管理后台的测试消息'),
      mentions: b.mentions,
    });
    db.prepare('UPDATE incoming_hooks SET last_used_at = ? WHERE id = ?').run(Date.now(), h.id);
    res.json({ ok: true, messageId: msg.id });
  } catch (e) { res.status(400).json({ error: e.message }); }
});

/* ==================== 出站 Webhook ==================== */

function shapeOutgoing(h) {
  return { ...h, active: !!h.active };
}

router.get('/outgoing', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  res.json(db.prepare(`SELECT o.*, g.name AS conversation_title
    FROM outgoing_hooks o LEFT JOIN groups g ON g.conversation_id = o.conversation_id
    ORDER BY o.id DESC`).all().map(shapeOutgoing));
});

router.post('/outgoing', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  const { name, url, events, conversationId, active } = req.body || {};
  const label = String(name || '').trim().slice(0, 64);
  const target = String(url || '').trim();
  if (!label) return res.status(400).json({ error: '名称不能为空' });
  if (!/^https?:\/\/.+/i.test(target)) return res.status(400).json({ error: '回调地址必须是 http(s):// 开头' });

  // events 为空 = 订阅全部
  const evs = (Array.isArray(events) ? events : [])
    .map((s) => String(s).trim())
    .filter((s) => EVENTS.some((e) => e.name === s));

  const info = db.prepare(`INSERT INTO outgoing_hooks
    (name, url, secret, events, conversation_id, active, created_by, created_at)
    VALUES (?,?,?,?,?,?,?,?)`)
    .run(label, target, newSecret(), evs.length ? evs.join(',') : '*',
      conversationId ? Number(conversationId) : null,
      active === false ? 0 : 1, uid, Date.now());
  res.json(shapeOutgoing(db.prepare('SELECT * FROM outgoing_hooks WHERE id = ?').get(info.lastInsertRowid)));
});

router.patch('/outgoing/:id', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  const id = Number(req.params.id);
  const h = db.prepare('SELECT * FROM outgoing_hooks WHERE id = ?').get(id);
  if (!h) return res.status(404).json({ error: '不存在' });
  const b = req.body || {};
  const sets = [];
  const args = [];
  if (typeof b.name === 'string' && b.name.trim()) { sets.push('name = ?'); args.push(b.name.trim().slice(0, 64)); }
  if (typeof b.url === 'string' && /^https?:\/\/.+/i.test(b.url.trim())) { sets.push('url = ?'); args.push(b.url.trim()); }
  if (b.active !== undefined) { sets.push('active = ?'); args.push(b.active ? 1 : 0); }
  if (b.events !== undefined) {
    const evs = (Array.isArray(b.events) ? b.events : [])
      .map((s) => String(s).trim()).filter((s) => EVENTS.some((e) => e.name === s));
    sets.push('events = ?'); args.push(evs.length ? evs.join(',') : '*');
  }
  if (b.conversationId !== undefined) {
    sets.push('conversation_id = ?'); args.push(b.conversationId ? Number(b.conversationId) : null);
  }
  if (b.rotateSecret) { sets.push('secret = ?'); args.push(newSecret()); }
  if (!sets.length) return res.status(400).json({ error: '没有要修改的内容' });
  args.push(id);
  db.prepare(`UPDATE outgoing_hooks SET ${sets.join(', ')} WHERE id = ?`).run(...args);
  res.json(shapeOutgoing(db.prepare('SELECT * FROM outgoing_hooks WHERE id = ?').get(id)));
});

router.delete('/outgoing/:id', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  const id = Number(req.params.id);
  db.prepare('DELETE FROM webhook_deliveries WHERE hook_id = ?').run(id);
  db.prepare('DELETE FROM outgoing_hooks WHERE id = ?').run(id);
  res.json({ ok: true });
});

/** 发一条 ping 事件，验证地址可达 + 签名正确 */
router.post('/outgoing/:id/test', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  const h = db.prepare('SELECT * FROM outgoing_hooks WHERE id = ?').get(Number(req.params.id));
  if (!h) return res.status(404).json({ error: '不存在' });
  const id = dispatcher.enqueue(h, 'ping', {
    event: 'ping',
    ts: Date.now(),
    conversation: null,
    data: { message: '小智 IM 测试事件', operatorId: uid },
  });
  res.json({ ok: true, deliveryId: id, note: '已投递，稍后可在投递日志查看结果' });
});

/* ==================== 投递日志 ==================== */

router.get('/deliveries', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  const limit = Math.min(Math.max(Number(req.query.limit) || 100, 1), 500);
  const where = [];
  const args = [];
  if (req.query.hookId) { where.push('d.hook_id = ?'); args.push(Number(req.query.hookId)); }
  if (req.query.ok === '1') where.push('d.ok = 1');
  if (req.query.ok === '0') where.push('d.ok = 0');
  args.push(limit);

  const rows = db.prepare(`SELECT d.id,d.hook_id,d.event,d.status,d.error,d.attempts,d.ok,
      d.next_retry_at,d.created_at,d.delivered_at, o.name AS hook_name, o.url AS hook_url
    FROM webhook_deliveries d LEFT JOIN outgoing_hooks o ON o.id = d.hook_id
    ${where.length ? 'WHERE ' + where.join(' AND ') : ''}
    ORDER BY d.id DESC LIMIT ?`).all(...args);
  res.json(rows.map((r) => ({ ...r, ok: !!r.ok })));
});

router.post('/deliveries/:id/retry', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  const id = Number(req.params.id);
  const d = db.prepare('SELECT id FROM webhook_deliveries WHERE id = ?').get(id);
  if (!d) return res.status(404).json({ error: '不存在' });
  // 手工重发不受重试次数限制：清空计数重新来
  db.prepare('UPDATE webhook_deliveries SET attempts = 0, next_retry_at = 0 WHERE id = ?').run(id);
  void dispatcher.sendNow(id);
  res.json({ ok: true, id, note: '已重新投递' });
});

/* ==================== 公钥接入 ==================== */

const crypto = require('crypto');

function newKeyId() {
  return [...crypto.randomBytes(6)].map((b) =>
    'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789'[b % 62]).join('');
}

function fingerprintOf(pem) {
  const der = Buffer.from(
    pem.replace(/-----BEGIN [^-]+-----/g, '')
       .replace(/-----END [^-]+-----/g, '')
       .replace(/\s+/g, ''), 'base64');
  return 'sha256:' + crypto.createHash('sha256').update(der).digest('hex');
}

function parsePublicKey(pem) {
  const key = crypto.createPublicKey(pem);
  const detail = key.asymmetricKeyDetails || {};
  const type = key.asymmetricKeyType;
  let algo;
  if (type === 'ec') {
    const nc = detail.namedCurve || '';
    if (nc === 'prime256v1' || nc === 'P-256' || nc === '1.2.840.10045.3.1.7') algo = 'ECDSA-SHA256';
    else throw new Error(`暂不支持的椭圆曲线：${nc}（推荐 P-256 / prime256v1）`);
  } else if (type === 'rsa') {
    algo = 'RSA-SHA256';
  } else {
    throw new Error(`暂不支持的密钥类型：${type}（支持 RSA / EC P-256）`);
  }
  return { key, algo };
}

router.get('/publickeys', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  const rows = db.prepare(`SELECT id, key_id, name, algorithm, fingerprint, created_at, last_used_at, revoked
    FROM public_keys ORDER BY id DESC LIMIT 500`).all();
  res.json(rows.map((r) => ({ ...r, revoked: !!r.revoked })));
});

router.post('/publickeys', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  const { name, publicKey } = req.body || {};
  if (!name || !name.trim()) return res.status(400).json({ error: '请填用途名' });
  if (!publicKey || !publicKey.includes('BEGIN')) return res.status(400).json({ error: '请粘贴 PEM 格式的公钥（含 BEGIN/END 标记）' });
  let parsed;
  try { parsed = parsePublicKey(publicKey); }
  catch (e) { return res.status(400).json({ error: '公钥解析失败：' + e.message }); }
  let keyId;
  for (let i = 0; i < 10; i++) {
    keyId = newKeyId();
    const ex = db.prepare('SELECT 1 FROM public_keys WHERE key_id=?').get(keyId);
    if (!ex) break;
    keyId = null;
  }
  if (!keyId) return res.status(500).json({ error: 'key_id 分配失败，请重试' });
  const fp = fingerprintOf(publicKey);
  const r = db.prepare(`INSERT INTO public_keys (key_id, name, public_key, algorithm, fingerprint, created_at)
    VALUES (?,?,?,?,?,?)`).run(keyId, name.trim(), publicKey.trim(), parsed.algo, fp, Date.now());
  res.json({
    id: r.lastInsertRowid, key_id: keyId, name: name.trim(),
    algorithm: parsed.algo, fingerprint: fp, created_at: Date.now(),
  });
});

router.delete('/publickeys/:id', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  const r = db.prepare('DELETE FROM public_keys WHERE id=?').run(Number(req.params.id));
  res.json({ ok: true, deleted: r.changes });
});

router.post('/publickeys/:id/revoke', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  const revoked = (req.body || {}).revoked !== false;
  const r = db.prepare('UPDATE public_keys SET revoked=? WHERE id=?').run(revoked ? 1 : 0, Number(req.params.id));
  res.json({ ok: true, revoked, changes: r.changes });
});

/** 验签测试：客户粘贴 body 原文 + signature(base64)，服务端用公钥验签 */
router.post('/publickeys/:id/test', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  const id = Number(req.params.id);
  const row = db.prepare('SELECT * FROM public_keys WHERE id=?').get(id);
  if (!row) return res.status(404).json({ error: '公钥不存在' });
  const { body, signature, algorithm } = req.body || {};
  if (typeof body !== 'string' || !signature) return res.status(400).json({ error: '请提供 body(字符串原文) 和 signature(base64 签名)' });
  try {
    const verifier = crypto.createVerify(algorithm || row.algorithm);
    verifier.update(body);
    verifier.end();
    const ok = verifier.verify(row.public_key, Buffer.from(signature, 'base64'));
    if (ok) {
      db.prepare('UPDATE public_keys SET last_used_at=? WHERE id=?').run(Date.now(), id);
      res.json({ ok: true, note: '验签通过 ✅' });
    } else {
      res.json({ ok: false, error: '签名不匹配（公钥 / 算法 / body 之一不一致）' });
    }
  } catch (e) {
    res.status(400).json({ ok: false, error: '验签失败：' + e.message });
  }
});

module.exports = router;
