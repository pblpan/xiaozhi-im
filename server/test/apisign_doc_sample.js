// 文档示例的**可执行性**探针（M3）
//
//   node test/apisign_doc_sample.js
//
// 【补的是哪个缝】
// `apisign_e2e.js` 里算签名的是一段 **Node** 代码 —— 它过了，只证明"协议"是对的。
// 但对接方真正照抄的是 INTEGRATION.md 里那段 **bash + openssl**。
// 这两份完全可以一个对一个错：换行多一个少一个、`echo` 尾巴上多吐一个 `\n`、
// query 那一行漏了 —— 每一样都能让对接方卡在"签名永远不对"，而且看不出为什么。
//
// 所以这里把文档里的 bash 片段**原样抽出来真跑一遍**，对着真实服务端发一条消息。
// 判据不是"命令没报错"，是**消息真发进去了**（落库、能读回来）。
//
// 🔴 改文档里的示例，就必须同步改这里 —— 否则文档会悄悄烂掉。

const { spawn, execFileSync } = require('child_process');
const path = require('path');
const fs = require('fs');
const os = require('os');

const PORT = 3717;
const BASE = `http://127.0.0.1:${PORT}`;
const SERVER_DIR = path.resolve(__dirname, '..');
const DATA_DIR = path.join(os.tmpdir(), 'xz-apisign-doc-' + Date.now());

let passed = 0;
let failed = 0;
const failures = [];
const ok = (name, cond, extra) => {
  if (cond) { passed++; console.log(`  \u2713 ${name}`); }
  else {
    failed++; failures.push(name + (extra ? ` — ${extra}` : ''));
    console.log(`  \u2717 ${name}${extra ? `  → ${extra}` : ''}`);
  }
};
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function api(method, p, { headers, body } = {}) {
  const res = await fetch(BASE + p, {
    method,
    headers: { ...(body != null ? { 'Content-Type': 'application/json' } : {}), ...(headers || {}) },
    body: body == null ? undefined : JSON.stringify(body),
  });
  let json = null;
  try { json = await res.json(); } catch { /* 空响应 */ }
  return { status: res.status, body: json };
}

let serverProc = null;
let serverLog = '';
async function startServer() {
  serverProc = spawn(process.execPath, [path.join(SERVER_DIR, 'src', 'index.js')], {
    env: { ...process.env, PORT: String(PORT), DATA_DIR, ADMIN_PASSWORD: 'DocAdmin_123' },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  serverProc.stdout.on('data', (d) => { serverLog += d.toString(); });
  serverProc.stderr.on('data', (d) => { serverLog += d.toString(); });
  for (let i = 0; i < 60; i++) {
    try { const r = await fetch(BASE + '/api/health'); if (r.ok) return; } catch { /* 等 */ }
    await sleep(250);
  }
  throw new Error('服务端启动超时\n' + serverLog);
}
function stopServer() {
  if (serverProc) { try { serverProc.kill(); } catch { /* ignore */ } }
  try { fs.rmSync(DATA_DIR, { recursive: true, force: true }); } catch { /* ignore */ }
}

/* ============================================================
   文档里那段 bash，原样搬过来
   ============================================================ */

const DOC_SNIPPET = `
set -e
PATH_URL="$DOC_PATH"
QUERY=""
BODY='{"text":"来自门店系统的告警"}'

TS=$(date +%s)
NONCE=$(openssl rand -hex 12)
BODY_HASH=$(printf '%s' "$BODY" | openssl dgst -sha256 -hex | awk '{print $NF}')

CANON=$(printf '%s\\n%s\\n%s\\n%s\\n%s\\n%s' \\
  "POST" "$PATH_URL" "$QUERY" "$TS" "$NONCE" "$BODY_HASH")
SIGN=$(printf '%s' "$CANON" | openssl dgst -sha256 -hmac "$APP_SECRET" -hex | awk '{print $NF}')

curl -sS -X POST "$BASE$PATH_URL" \\
  -H 'Content-Type: application/json' \\
  -H "X-App-Id: $APP_ID" \\
  -H "X-Timestamp: $TS" \\
  -H "X-Nonce: $NONCE" \\
  -H "X-Sign: $SIGN" \\
  -d "$BODY"
`;

(async () => {
  await startServer();
  console.log('[文档示例探针] 服务端已就绪 ' + BASE + '\n');

  let r = await api('POST', '/api/auth/login', { body: { username: 'admin', password: 'DocAdmin_123' } });
  const ADMIN = { Authorization: 'Bearer ' + r.body?.token };

  // 建一个机器人当身份，再开一个会话，让"发消息"有地方落
  r = await api('POST', '/api/admin/integrations/bots', {
    headers: ADMIN, body: { name: '文档示例机器人' },
  });
  const botId = r.body?.id ?? r.body?.bot?.id;
  ok('建机器人', !!botId, JSON.stringify(r.body).slice(0, 160));

  r = await api('POST', '/api/admin/integrations/clients', {
    headers: ADMIN,
    body: { name: '文档示例对接方', userId: botId, scopes: ['conversation:read', 'message:send', 'message:read'] },
  });
  const APP_ID = r.body?.client?.appId;
  const APP_SECRET = r.body?.secret;
  ok('发一对凭据', !!APP_ID && !!APP_SECRET, JSON.stringify(r.body).slice(0, 160));

  // 建个群并把机器人拉进去 —— 不然"发消息"没有目的地，
  // 只能探到 `{"items":[]}`，那样测的是"空列表"不是"签名"。
  r = await api('POST', '/api/admin/groups', {
    headers: ADMIN, body: { name: '文档示例群', member_ids: [botId] },
  });
  const groupId = r.body?.id;
  //
  // 🔴 群 id 和会话 id 是**两个号**：`id` 是群，`conversationId` 才是发消息要用的那个。
  // 空库上两者都从 1 开始，拿错也能"撞巧通过"；等库里有了历史数据，
  // 号一错开就变成一个很难查的 403。（这就是服务端顺手把 conversationId 一起回出来的原因。）
  const convId = r.body?.conversationId;
  ok('建群并把机器人拉进去（用的是**会话** id，不是群 id）',
    convId != null && convId !== undefined, JSON.stringify({ groupId, convId }));
  // 交叉验一次：群里查回来的 conversation_id 必须和接口回的一致
  const gl = await api('GET', '/api/admin/groups?q=' + encodeURIComponent('文档示例群'), { headers: ADMIN });
  const fromList = (gl.body?.items || []).find((g) => g.id === groupId)?.conversation_id;
  ok('  与群列表里的 conversation_id 对得上（防"两个号搞混"）',
    fromList === convId, JSON.stringify({ convId, fromList }));

  const convPath = '/api/open/conversations';
  r = await api('GET', convPath, {
    headers: (() => {
      // 这里借 Node 签一次只为探路；真正被测的是下面的 bash 片段
      const crypto = require('crypto');
      const ts = String(Math.floor(Date.now() / 1000));
      const nonce = crypto.randomBytes(12).toString('hex');
      const bodyHash = crypto.createHash('sha256').update(Buffer.alloc(0)).digest('hex');
      const canon = ['GET', convPath, '', ts, nonce, bodyHash].join('\n');
      return {
        'X-App-Id': APP_ID, 'X-Timestamp': ts, 'X-Nonce': nonce,
        'X-Sign': crypto.createHmac('sha256', APP_SECRET).update(canon).digest('hex'),
      };
    })(),
  });
  ok('签名通道能读会话列表', r.status === 200, JSON.stringify(r.body).slice(0, 200));
  const seen = (r.body?.conversations || r.body?.items || r.body || []) || [];
  ok('  列表里能看到刚建的那个群（说明 scope/身份都对）',
    seen.some((c) => c.id === convId), JSON.stringify(r.body).slice(0, 200));

  // ===== 正主：把文档里那段 bash 原样跑一遍 =====
  console.log('\n【跑文档里的 bash 片段】');
  let out = '';
  try {
    out = execFileSync('bash', ['-c', DOC_SNIPPET], {
      encoding: 'utf8',
      env: {
        ...process.env,
        APP_ID, APP_SECRET, BASE,
        DOC_PATH: `/api/open/conversations/${convId}/messages`,
        PATH: process.env.PATH, // 被上面展开的 $PATH 覆盖前先留住
      },
      stdio: ['ignore', 'pipe', 'pipe'],
    });
  } catch (e) {
    ok('bash 片段执行成功', false, (e.stdout || '') + (e.stderr || ''));
  }
  if (out) {
    let parsed = null;
    try { parsed = JSON.parse(out); } catch { /* 不是 JSON */ }
    ok('🔴 文档示例真把消息发出去了（不只是没报错）',
      !!parsed && (parsed.ok === true || parsed.id != null), out.slice(0, 300));

    // 反过来读一次，确认真的落库了（而不是"返回 200 但没写进去"）
    if (parsed && parsed.id != null) {
      const back = await api('GET', `/api/open/conversations/${convId}/messages?limit=5`, {
        headers: (() => {
          const crypto = require('crypto');
          const p = `/api/open/conversations/${convId}/messages`;
          const q = 'limit=5';
          const ts = String(Math.floor(Date.now() / 1000));
          const nonce = crypto.randomBytes(12).toString('hex');
          const bodyHash = crypto.createHash('sha256').update(Buffer.alloc(0)).digest('hex');
          const canon = ['GET', p, q, ts, nonce, bodyHash].join('\n');
          return {
            'X-App-Id': APP_ID, 'X-Timestamp': ts, 'X-Nonce': nonce,
            'X-Sign': crypto.createHmac('sha256', APP_SECRET).update(canon).digest('hex'),
          };
        })(),
      });
      const msgs = back.body?.messages || back.body?.items
        || (Array.isArray(back.body) ? back.body : []);
      ok('  消息能读回来（真落库了，且带 query 的签名也对）',
        msgs.some((m) => m.id === parsed.id), JSON.stringify(back.body).slice(0, 200));
    }
  }

  // ===== 反向：文档里特意提醒的两个坑，各打一枪 =====
  console.log('\n【文档里点名的两个坑，反向验证】');
  const crypto = require('crypto');
  const signWith = (canon) => crypto.createHmac('sha256', APP_SECRET).update(canon).digest('hex');
  const p = `/api/open/conversations/${convId}/messages`;
  // 两个键，这样"重新序列化"才可能换键序；单键的话两种序列化字节一样，
  // 那一枪就打空了（第一版就栽在这里：JSON.stringify(JSON.parse(x)) 原样返回）。
  const body = '{"text":"坑1","kind":"text"}';
  const bodyHash = crypto.createHash('sha256').update(Buffer.from(body)).digest('hex');

  // 坑 ①：query 那一行漏了（六段变五段）
  let ts = String(Math.floor(Date.now() / 1000));
  let nonce = crypto.randomBytes(12).toString('hex');
  const shortCanon = ['POST', p, ts, nonce, bodyHash].join('\n'); // 少了 query
  r = await fetch(BASE + p, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json', 'X-App-Id': APP_ID,
      'X-Timestamp': ts, 'X-Nonce': nonce, 'X-Sign': signWith(shortCanon),
    },
    body,
  });
  let j = null; try { j = await r.json(); } catch { /* ignore */ }
  ok('① query 空行漏掉（拼成 5 段）→ 401 bad_sign（所以文档才强调"这行不能少"）',
    r.status === 401 && j?.code === 'bad_sign', JSON.stringify(j));

  // 坑 ②：body 哈希算错（模拟"用 JSON.stringify 重新序列化"导致的字节差异）
  ts = String(Math.floor(Date.now() / 1000));
  nonce = crypto.randomBytes(12).toString('hex');
  // 照真实踩法：pretty-print 之后再算哈希（JSON.stringify(v, null, 2)），字节必然不同
  const wrongHash = crypto.createHash('sha256')
    .update(Buffer.from(JSON.stringify(JSON.parse(body), null, 2))).digest('hex');
  const canon2 = ['POST', p, '', ts, nonce, wrongHash].join('\n');
  r = await fetch(BASE + p, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json', 'X-App-Id': APP_ID,
      'X-Timestamp': ts, 'X-Nonce': nonce, 'X-Sign': signWith(canon2),
    },
    body,
  });
  j = null; try { j = await r.json(); } catch { /* ignore */ }
  // 这一枪的用意：如果 body 被重新序列化后字节**恰好**一致，那说明这条不是有效反向用例
  const hashDiffers = wrongHash !== bodyHash;
  ok(`② body 哈希按"重新序列化"算 → ${
    hashDiffers ? '401 bad_sign（字节确实不同，文档那条提醒站得住）' : '字节竟然一致，这条用例无效'}`,
    hashDiffers ? (r.status === 401 && j?.code === 'bad_sign') : false,
    JSON.stringify(j));

  stopServer();
  console.log(`\n[文档示例探针] 通过 ${passed} / 失败 ${failed}`);
  if (failures.length) { console.log('失败项：'); for (const f of failures) console.log('  ✗ ' + f); }
  process.exit(failed ? 1 : 0);
})().catch((e) => { console.error(e); stopServer(); process.exit(1); });
