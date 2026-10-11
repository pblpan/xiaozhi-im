// 智能助手端到端测试（#314：智能助手接管帮助 + 接入智能体）
//
//   node test/assistant_e2e.js
//
// 起两个服务：主服务（隔离 DATA_DIR）+ **假 LLM 服务器**（OpenAI 兼容形状）。
// LLM 链路是"调外部 API"，必须真调一次才算验过 —— 用假服务器逐字段核对
// 请求形状（Bearer Key / model / system 里带 KB 上下文），别只看返回 200。
//
// 【四条必须钉住的性质】
//   ① 降级链：LLM 挂了/没配 → 内置知识库兜底，绝不能把异常裸抛给用户。
//   ② 🔴 API Key 永不回明文 —— 配置接口只回 hasKey 布尔。这是所有"存密钥"
//      接口的底线，回归测试必须钉死（响应里 grep 不到 Key 才算过）。
//   ③ 管理台「试问」用 force：总开关没开但 LLM 配好了，也要能真调一次。
//   ④ /ask 是登录用户接口：未登录 401，但不能要求管理员 —— 帮助是给所有人的。

const { spawn } = require('child_process');
const path = require('path');
const fs = require('fs');
const os = require('os');
const http = require('http');

const PORT = 3736;
const LLM_PORT = 3737;
const BASE = `http://127.0.0.1:${PORT}`;
const SERVER_DIR = path.resolve(__dirname, '..');
const DATA_DIR = path.join(os.tmpdir(), 'xiaozhi-assistant-e2e-' + Date.now());

let passed = 0, failed = 0;
const failures = [];
const ok = (n, c, x) => {
  if (c) { passed++; console.log(`  \u2713 ${n}`); }
  else { failed++; failures.push(n + (x ? ` — ${x}` : '')); console.log(`  \u2717 ${n}${x ? '  → ' + x : ''}`); }
};
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function api(method, p, { token, body } = {}) {
  const res = await fetch(BASE + p, {
    method,
    headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: 'Bearer ' + token } : {}) },
    body: body ? JSON.stringify(body) : undefined,
  });
  let json = null; try { json = await res.json(); } catch { /* 空响应 */ }
  return { status: res.status, body: json };
}

// ---------------- 假 LLM 服务器 ----------------

let llmHits = 0;             // 被调次数
let lastReq = null;          // 最后一次收到的 {auth, body}
const LLM_MARKER = '这是假大模型的回答：打卡请在应用中心使用考勤。';

const llmServer = http.createServer((req, res) => {
  let raw = '';
  req.on('data', (c) => { raw += c; });
  req.on('end', () => {
    llmHits++;
    lastReq = { auth: req.headers.authorization || '', body: null };
    try { lastReq.body = JSON.parse(raw); } catch { /* keep null */ }
    res.setHeader('Content-Type', 'application/json');
    res.end(JSON.stringify({
      choices: [{ message: { role: 'assistant', content: LLM_MARKER } }],
    }));
  });
});

let serverProc = null;
let serverLog = '';

async function startServer() {
  serverProc = spawn(process.execPath, [path.join(SERVER_DIR, 'src', 'index.js')], {
    env: { ...process.env, PORT: String(PORT), DATA_DIR, ADMIN_PASSWORD: 'TestAdmin_123' },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  serverProc.stdout.on('data', (d) => { serverLog += d.toString(); });
  serverProc.stderr.on('data', (d) => { serverLog += d.toString(); });
  for (let i = 0; i < 60; i++) {
    try { const r = await fetch(BASE + '/api/health'); if (r.ok) return; } catch { /* 还没起来 */ }
    await sleep(250);
  }
  throw new Error('服务端启动超时\n' + serverLog);
}

function stopAll() {
  if (serverProc) { try { serverProc.kill(); } catch { /* ignore */ } }
  try { llmServer.close(); } catch { /* ignore */ }
  try { fs.rmSync(DATA_DIR, { recursive: true, force: true }); } catch { /* ignore */ }
}

// ------------------------------------------------------------------ 主流程

(async () => {
  await new Promise((r) => llmServer.listen(LLM_PORT, r));
  await startServer();
  console.log('[智能助手 E2E] 主服务 ' + BASE + ' · 假LLM :' + LLM_PORT + '\n');

  const login = await api('POST', '/api/auth/login', { body: { username: 'admin', password: 'TestAdmin_123' } });
  ok('管理员登录', login.status === 200, `got=${login.status}`);
  const ta = login.body.token;
  const reg = await api('POST', '/api/auth/register', { body: { username: 'alice', password: 'pw123456', nickname: 'alice' } });
  const tu = reg.body?.token;
  ok('普通用户注册', !!tu, JSON.stringify(reg.body).slice(0, 80));

  // ---------------- 一：未配置时（纯知识库） ----------------
  console.log('\n【一】未配置 LLM —— 纯内置知识库');

  let r = await api('POST', '/api/assistant/ask', { body: { question: '怎么打卡' } });
  ok('未登录 → 401', r.status === 401, JSON.stringify(r.body));

  r = await api('POST', '/api/assistant/ask', { token: tu, body: { question: '怎么打卡' } });
  ok('普通用户可问（帮助给所有人用，不要求管理员）', r.status === 200, JSON.stringify(r.body).slice(0, 120));
  ok('  命中知识库（source=kb）', r.body?.source === 'kb', JSON.stringify(r.body?.source));
  ok('  答案里讲打卡', /打卡/.test(r.body?.answer || ''), JSON.stringify(r.body?.answer?.slice(0, 60)));
  ok('  还给出相关问法', Array.isArray(r.body?.related), JSON.stringify(r.body?.related));

  r = await api('POST', '/api/assistant/ask', { token: tu, body: { question: '   ' } });
  ok('空问题 → 400', r.status === 400, JSON.stringify(r.body));

  r = await api('POST', '/api/assistant/ask', { token: tu, body: { question: 'x'.repeat(501) } });
  ok('超长问题不炸（截断后照答）', r.status === 200, JSON.stringify(r.status));

  // ---------------- 二：配置 ----------------
  console.log('\n【二】管理端配置');

  r = await api('GET', '/api/admin/assistant/config', { token: tu });
  ok('非管理员看配置 → 403', r.status === 403, JSON.stringify(r.body));

  r = await api('GET', '/api/admin/assistant/config', { token: ta });
  ok('GET config → 默认关 + hasKey=false', r.status === 200 && r.body?.enabled === false && r.body?.hasKey === false,
    JSON.stringify(r.body));

  r = await api('PUT', '/api/admin/assistant/config', {
    token: ta, body: { enabled: true, apiBase: `http://127.0.0.1:${LLM_PORT}`,
      apiKey: 'sk-test-secret-123', model: 'fake-model' } });
  ok('PUT config → 200 且 hasKey=true', r.status === 200 && r.body?.hasKey === true, JSON.stringify(r.body));
  ok('🔴 Key 不回明文', !JSON.stringify(r.body).includes('sk-test-secret-123'), JSON.stringify(r.body));

  r = await api('PUT', '/api/admin/assistant/config', { token: ta, body: { apiBase: '不是地址' } });
  ok('非法 apiBase → 400', r.status === 400, JSON.stringify(r.body));

  // ---------------- 三：LLM 链路（真调假服务器） ----------------
  console.log('\n【三】LLM 链路（假服务器逐字段核对）');

  r = await api('POST', '/api/assistant/ask', { token: tu, body: { question: '怎么打卡' } });
  ok('启用后用户提问 → source=llm', r.body?.source === 'llm', JSON.stringify(r.body).slice(0, 160));
  ok('  回答是假 LLM 的标记文本', r.body?.answer === LLM_MARKER, JSON.stringify(r.body?.answer?.slice(0, 60)));

  ok('🔴 假 LLM 收到 Bearer Key', lastReq?.auth === 'Bearer sk-test-secret-123', JSON.stringify(lastReq?.auth));
  ok('🔴 请求带 model', lastReq?.body?.model === 'fake-model', JSON.stringify(lastReq?.body?.model));
  const sysMsg = lastReq?.body?.messages?.find((m) => m.role === 'system')?.content || '';
  ok('🔴 system 里带 KB 参考上下文（防模型编口径）', sysMsg.includes('参考资料') && sysMsg.includes('考勤'), sysMsg.slice(0, 80));

  // 试问 force：关掉开关后再试 —— LLM 配好了就必须真调
  r = await api('PUT', '/api/admin/assistant/config', { token: ta, body: { enabled: false } });
  ok('临时关掉总开关', r.status === 200 && r.body?.enabled === false, JSON.stringify(r.body));
  const hitsBefore = llmHits;
  r = await api('POST', '/api/admin/assistant/test', { token: ta, body: { question: '怎么建群' } });
  ok('🔴 试问 force：开关没开也真调 LLM', r.status === 200 && r.body?.source === 'llm' && llmHits === hitsBefore + 1,
    JSON.stringify(r.body).slice(0, 140));
  r = await api('POST', '/api/assistant/ask', { token: tu, body: { question: '怎么建群' } });
  ok('开关关了，用户问走知识库（不调 LLM）', r.body?.source === 'kb' && llmHits === hitsBefore + 1,
    JSON.stringify(r.body).slice(0, 140));

  // ---------------- 四：降级链 ----------------
  console.log('\n【四】降级链 —— LLM 挂了不能裸抛');

  // 把 apiBase 指到一个没人听的端口
  await api('PUT', '/api/admin/assistant/config', {
    token: ta, body: { enabled: true, apiBase: 'http://127.0.0.1:9', apiKey: 'sk-x' } });
  r = await api('POST', '/api/assistant/ask', { token: tu, body: { question: '怎么打卡' } });
  ok('🔴 LLM 连不上 → 降级知识库并带说明', r.status === 200 && r.body?.source === 'kb'
    && /暂不可用/.test(r.body?.note || ''), JSON.stringify(r.body).slice(0, 200));

  // LLM 配好但问知识库也没有的 —— LLM 层应该兜住（假 LLM 什么都能答）
  await api('PUT', '/api/admin/assistant/config', {
    token: ta, body: { enabled: true, apiBase: `http://127.0.0.1:${LLM_PORT}`, apiKey: 'sk-x' } });
  r = await api('POST', '/api/assistant/ask', { token: tu, body: { question: '明天天气怎么样' } });
  ok('知识库没命中但 LLM 配好 → LLM 作答（不回兜底话术）',
    r.body?.source === 'llm' && r.body?.answer === LLM_MARKER, JSON.stringify(r.body).slice(0, 140));

  // 清 Key（''=清除），退回纯 KB
  r = await api('PUT', '/api/admin/assistant/config', { token: ta, body: { apiKey: '' } });
  ok("apiKey 传 '' → 清除（hasKey=false）", r.status === 200 && r.body?.hasKey === false, JSON.stringify(r.body));
  // apiKey 不传 = 沿用（这里 hasKey 已是 false，重点是不报错）
  r = await api('PUT', '/api/admin/assistant/config', { token: ta, body: { model: 'another' } });
  ok('apiKey 不传 → 沿用已存值（不误清）', r.status === 200 && r.body?.hasKey === false, JSON.stringify(r.body));

  // ------------------------------------------------------------------ 结果
  console.log(`\n========== 结果：${passed} 通过 / ${failed} 失败 ==========`);
  if (failures.length) { console.log('失败项：'); for (const f of failures) console.log('  ✗ ' + f); }
  stopAll();
  process.exit(failed ? 1 : 0);
})().catch((e) => { console.error('测试执行异常：', e); stopAll(); process.exit(1); });
