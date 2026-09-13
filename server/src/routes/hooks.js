// 入站 Webhook：让任何软件「一个 POST 就能往群里推消息」
//
//   POST /api/hooks/incoming/<token>
//   { "text": "库存预警：东北大米只剩 3 袋" }
//
// 设计要点：
//   - 不需要登录、不需要 API Token，URL 里的 token 就是凭证（可随时在后台吊销）
//   - 可选 HMAC 签名（hook.secret 非空时强制校验），防止地址外泄后被滥用
//   - 消息以「机器人」身份发出，群里能看出是系统推的，不会冒充真人
const express = require('express');
const crypto = require('crypto');
const db = require('../db');
const { sendMessage } = require('../chat');

const router = express.Router();

/** 简易内存限流：每个 hook 每分钟 120 次，防误配置导致刷屏 */
const RATE_WINDOW_MS = 60 * 1000;
const RATE_MAX = 120;
const hits = new Map();

function rateLimited(token) {
  const now = Date.now();
  const rec = hits.get(token);
  if (!rec || now > rec.resetAt) {
    hits.set(token, { count: 1, resetAt: now + RATE_WINDOW_MS });
    return false;
  }
  rec.count++;
  return rec.count > RATE_MAX;
}

function safeEqual(a, b) {
  const ba = Buffer.from(String(a));
  const bb = Buffer.from(String(b));
  if (ba.length !== bb.length) return false;
  return crypto.timingSafeEqual(ba, bb);
}

/** 校验签名：header `X-Xiaozhi-Signature: sha256=<hex>`，也接受裸 hex */
function verifySignature(secret, rawBody, header) {
  const got = String(header || '').trim().replace(/^sha256=/i, '');
  if (!got) return false;
  const want = crypto.createHmac('sha256', String(secret)).update(rawBody, 'utf8').digest('hex');
  return safeEqual(got.toLowerCase(), want);
}

function loadHook(token) {
  return db.prepare(`SELECT h.*, u.nickname AS bot_name, u.avatar AS bot_avatar
    FROM incoming_hooks h LEFT JOIN users u ON u.id = h.bot_id
    WHERE h.token = ?`).get(String(token || ''));
}

/**
 * 把各种写法的请求体归一成 { kind, content, mentions }。
 * 兼容三类写法，降低对接方的心智负担：
 *   1. { text }                        —— 最简，一行字
 *   2. { title, text, fields, ... }    —— 卡片（工厂日报/预警就用这个）
 *   3. { kind, content }               —— 完全显式控制
 */
/**
 * 把可能是对象的"文本字段"取出来。
 *
 * 【为什么必须显式拦住对象】之前这里是 `String(v)`：
 * 对接方若照抄钉钉/企微/飞书的报文格式（`{"msgtype":"text","text":{"content":"..."}}`），
 * `String({content:'x'})` 得到的是字符串 `"[object Object]"` —— 于是**返回 200 成功**，
 * 群里却出现一条内容是 `[object Object]` 的消息。发送方看到 200 以为通了，
 * 接收方看到乱码不知道哪来的，是最难排查的一类"假成功"。
 * 宁可 400 并说清楚，也不要让垃圾进群。
 */
function coerceText(v, field) {
  if (v === undefined || v === null) return undefined;
  if (typeof v === 'object') {
    const kind = Array.isArray(v) ? '数组' : '对象';
    throw new Error(
      `${field} 必须是字符串，收到的是${kind}。`
      + '如果你在对接钉钉/企微/飞书的报文格式（如 {"msgtype":"text","text":{"content":"..."}}），'
      + `请把纯文本提到顶层：{"text":"..."} —— IM 不解析各家的嵌套结构。`,
    );
  }
  return String(v);
}

function normalizeBody(body) {
  const b = body && typeof body === 'object' && !Array.isArray(body) ? body : {};
  const mentions = Array.isArray(b.mentions) ? b.mentions : [];

  if (b.kind) {
    return { kind: String(b.kind), content: b.content, mentions };
  }
  const hasCardShape = b.title !== undefined || b.fields !== undefined
    || b.color !== undefined || b.footer !== undefined;
  if (hasCardShape) {
    // 具体到字段的类型检查交给 normalizeCard（它更清楚每个字段的上限）
    return { kind: 'card', content: b, mentions };
  }
  // 三个别名按优先级取第一个出现的；报错时用真实字段名，别让对接方去猜是哪个键
  const [field, raw] = b.text !== undefined ? ['text', b.text]
    : b.markdown !== undefined ? ['markdown', b.markdown]
      : ['message', b.message];
  const text = coerceText(raw, field);
  if (text === undefined || text.trim() === '') {
    throw new Error('请求体需要 text / title+fields / kind+content 之一');
  }
  return { kind: 'text', content: text, mentions };
}

/** @ 提及：允许传用户 id、用户名、昵称，或 'all'；最终仍由 chat 层按群成员二次过滤 */
function resolveMentions(list, conversationId) {
  const out = [];
  for (const v of list) {
    const s = String(v).trim();
    if (!s) continue;
    if (s.toLowerCase() === 'all' || s === '-1') { out.push('all'); continue; }
    if (/^\d+$/.test(s)) { out.push(Number(s)); continue; }
    const u = db.prepare('SELECT id FROM users WHERE username = ? OR nickname = ?')
      .get(s, s);
    if (u) out.push(u.id);
  }
  return out;
}

// 回调链路自检地址：把出站 Webhook 指向这里，能收到 200 就说明服务端出口是通的。
// 刻意不落任何数据、不需要鉴权 —— 它只是"回声"，不含任何业务信息。
router.all('/ping', (req, res) => {
  res.json({
    ok: true,
    ts: Date.now(),
    method: req.method,
    echo: req.method === 'GET' ? null : (req.body || null),
    note: '小智 IM 回调自检地址，收到本响应说明服务端出口网络正常',
  });
});

// 用 GET 打开地址可自检（浏览器里直接访问就能确认地址对不对）
router.get('/incoming/:token', (req, res) => {
  const hook = loadHook(req.params.token);
  if (!hook || hook.revoked) return res.status(404).json({ error: 'hook not found' });
  const conv = db.prepare('SELECT id, type FROM conversations WHERE id = ?').get(hook.conversation_id);
  res.json({
    ok: true,
    hook: hook.name,
    bot: hook.bot_name,
    conversationId: hook.conversation_id,
    conversationType: conv ? conv.type : null,
    signed: !!hook.secret,
    usage: 'POST 到此地址，body 支持 { text } / { title, text, fields } / { kind, content }',
  });
});

router.post('/incoming/:token', (req, res) => {
  const token = String(req.params.token || '');
  const hook = loadHook(token);
  if (!hook || hook.revoked) return res.status(401).json({ error: 'invalid hook token' });

  if (rateLimited(token)) {
    return res.status(429).json({ error: '推送过于频繁（每分钟上限 120 条）' });
  }

  // 签名校验：secret 非空才要求，留空即"地址即凭证"的简易模式
  if (hook.secret) {
    const raw = req.rawBody ? req.rawBody.toString('utf8') : JSON.stringify(req.body || {});
    if (!verifySignature(hook.secret, raw, req.headers['x-xiaozhi-signature'])) {
      return res.status(401).json({ error: '签名校验失败（X-Xiaozhi-Signature）' });
    }
  }

  let payload;
  try {
    payload = normalizeBody(req.body);
  } catch (e) {
    return res.status(400).json({ error: e.message });
  }

  try {
    const mentions = resolveMentions(payload.mentions, hook.conversation_id);
    const msg = sendMessage({
      conversationId: hook.conversation_id,
      senderId: hook.bot_id,
      kind: payload.kind,
      content: payload.content,
      mentions,
    });
    db.prepare('UPDATE incoming_hooks SET last_used_at = ? WHERE id = ?').run(Date.now(), hook.id);
    res.json({
      ok: true,
      messageId: msg.id,
      conversationId: msg.conversation_id,
      kind: msg.kind,
      bot: hook.bot_name,
    });
  } catch (e) {
    res.status(400).json({ error: e.message });
  }
});

module.exports = router;
