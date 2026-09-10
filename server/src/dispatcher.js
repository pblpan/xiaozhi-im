// 出站 Webhook 投递器：把 IM 里发生的事件回调给外部系统
//
// 可靠性设计：
//   - 每次投递先落 webhook_deliveries 表（有据可查、可重发）
//   - HMAC-SHA256 签名，外部系统可验真伪
//   - 失败按 30s / 2min / 10min 退避重试，最多 4 次
//   - 投递全程不阻塞主流程（fire-and-forget），IM 不会因为对方服务器挂了而卡住
const crypto = require('crypto');
const db = require('./db');

const TIMEOUT_MS = 10000;
const MAX_ATTEMPTS = 4;
/** 第 n 次失败后的等待时间（毫秒），索引 = 已尝试次数 */
const BACKOFF = [30 * 1000, 2 * 60 * 1000, 10 * 60 * 1000];

function sign(secret, body) {
  return 'sha256=' + crypto.createHmac('sha256', String(secret)).update(body, 'utf8').digest('hex');
}

/** hook 是否订阅了该事件：events 为 '*' 或逗号分隔列表 */
function hookWants(hook, event) {
  const raw = String(hook.events || '*').trim();
  if (!raw || raw === '*') return true;
  return raw.split(',').map((s) => s.trim()).filter(Boolean).includes(event);
}

/** 为某个 hook 建一条投递记录并异步发出，返回 deliveryId */
function enqueue(hook, event, payloadObj) {
  // 先落一条占位记录拿到自增 id，把 id 补进 payload 后再更新回去，
  // 最后才真正发送 —— 这样外部系统收到的 body 与 header 里的 deliveryId 一定一致
  // （若先发送再更新，异步发送可能抢在 UPDATE 之前读到旧的 payload）
  const info = db.prepare(`INSERT INTO webhook_deliveries
    (hook_id, event, payload, attempts, ok, next_retry_at, created_at)
    VALUES (?,?,?,0,0,?,?)`)
    .run(hook.id, event, '{}', Date.now(), Date.now());
  const id = Number(info.lastInsertRowid);

  const body = JSON.stringify({ ...payloadObj, deliveryId: id });
  db.prepare('UPDATE webhook_deliveries SET payload = ? WHERE id = ?').run(body, id);

  // 故意不 await：投递失败不影响 IM 主流程
  void sendNow(id);
  return id;
}

/** 投递一条已有记录（首次发送与重试共用同一条路径） */
async function sendNow(deliveryId) {
  const d = db.prepare('SELECT * FROM webhook_deliveries WHERE id = ?').get(Number(deliveryId));
  if (!d) return { ok: false, error: 'delivery not found' };
  const hook = db.prepare('SELECT * FROM outgoing_hooks WHERE id = ?').get(d.hook_id);
  if (!hook) {
    db.prepare('UPDATE webhook_deliveries SET ok = 0, error = ?, status = NULL, attempts = attempts + 1 WHERE id = ?')
      .run('hook 已删除', d.id);
    return { ok: false, error: 'hook not found' };
  }

  const attempts = (d.attempts || 0) + 1;
  const headers = {
    'Content-Type': 'application/json',
    'User-Agent': 'XiaozhiIM-Webhook/1.0',
    'X-Xiaozhi-Event': d.event,
    'X-Xiaozhi-Delivery': String(d.id),
    'X-Xiaozhi-Attempt': String(attempts),
  };
  if (hook.secret) headers['X-Xiaozhi-Signature'] = sign(hook.secret, d.payload);

  const ac = new AbortController();
  const timer = setTimeout(() => ac.abort(), TIMEOUT_MS);
  let status = null;
  let error = null;
  try {
    const r = await fetch(hook.url, {
      method: 'POST',
      headers,
      body: d.payload,
      signal: ac.signal,
    });
    status = r.status;
    if (!r.ok) error = `HTTP ${r.status}`;
  } catch (e) {
    error = e.name === 'AbortError' ? `超时（${TIMEOUT_MS / 1000}s）` : String(e.message || e);
  } finally {
    clearTimeout(timer);
  }

  const ok = status !== null && status >= 200 && status < 300;
  const now = Date.now();
  if (ok) {
    db.prepare(`UPDATE webhook_deliveries
      SET status = ?, error = NULL, attempts = ?, ok = 1, delivered_at = ?, next_retry_at = 0
      WHERE id = ?`).run(status, attempts, now, d.id);
    return { ok: true, status, attempts };
  }

  const canRetry = attempts < MAX_ATTEMPTS;
  const wait = BACKOFF[Math.min(attempts - 1, BACKOFF.length - 1)];
  db.prepare(`UPDATE webhook_deliveries
    SET status = ?, error = ?, attempts = ?, ok = 0, next_retry_at = ?
    WHERE id = ?`)
    .run(status, error, attempts, canRetry ? now + wait : 0, d.id);
  return { ok: false, status, error, attempts, willRetry: canRetry };
}

/** 扫描到期的失败投递并重试；返回本轮处理条数 */
function runDueRetries(limit = 20) {
  const due = db.prepare(`SELECT id FROM webhook_deliveries
    WHERE ok = 0 AND next_retry_at > 0 AND next_retry_at <= ?
    ORDER BY next_retry_at ASC LIMIT ?`).all(Date.now(), limit);
  for (const row of due) {
    // 先把 next_retry_at 清掉，防止慢投递被下一轮重复捞起
    db.prepare('UPDATE webhook_deliveries SET next_retry_at = 0 WHERE id = ?').run(row.id);
    void sendNow(row.id);
  }
  return due.length;
}

let timer = null;

/** 启动重试巡检（每 15 秒一次）。重复调用安全。 */
function start() {
  if (timer) return;
  timer = setInterval(() => {
    try { runDueRetries(); } catch { /* 巡检失败不影响服务 */ }
  }, 15000);
  if (timer.unref) timer.unref(); // 不阻止进程退出（测试脚本用得上）
}

function stop() {
  if (timer) { clearInterval(timer); timer = null; }
}

module.exports = { enqueue, sendNow, runDueRetries, start, stop, sign, hookWants, MAX_ATTEMPTS };
