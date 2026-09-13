// 局域网发现服务（UDP 3616）—— 端到端测试
//
//   node test/discover_e2e.js
//
// 起隔离实例，模拟客户端发探测包，断言应答内容与协议纪律：
// 只有正确的探测包才有应答；应答里只有公开信息。

const { spawn } = require('child_process');
const dgram = require('dgram');
const path = require('path');
const fs = require('fs');
const os = require('os');

const PORT = 3695;
const DISCOVER_PORT = 13616; // 用环境变量改到测试端口，避免和真实服务冲突
const BASE = `http://127.0.0.1:${PORT}`;
const SERVER_DIR = path.resolve(__dirname, '..');
const DATA_DIR = path.join(os.tmpdir(), 'xiaozhi-discover-e2e-' + Date.now());

let passed = 0;
let failed = 0;
const failures = [];

function ok(name, cond, extra) {
  if (cond) { passed++; console.log(`  \u2713 ${name}`); }
  else {
    failed++;
    failures.push(name + (extra ? ` — ${extra}` : ''));
    console.log(`  \u2717 ${name}${extra ? '  → ' + extra : ''}`);
  }
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function api(method, p, { token, body } = {}) {
  const res = await fetch(BASE + p, {
    method,
    headers: {
      'Content-Type': 'application/json',
      ...(token ? { Authorization: 'Bearer ' + token } : {}),
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  let json = null;
  try { json = await res.json(); } catch { /* 空响应 */ }
  return { status: res.status, body: json };
}

let serverProc = null;
let serverLog = '';

async function startServer() {
  serverProc = spawn(process.execPath, [path.join(SERVER_DIR, 'src', 'index.js')], {
    env: {
      ...process.env,
      PORT: String(PORT),
      DATA_DIR,
      ADMIN_PASSWORD: 'admin123',
      DISCOVER_PORT: String(DISCOVER_PORT),
    },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  serverProc.stdout.on('data', (d) => { serverLog += d.toString(); });
  serverProc.stderr.on('data', (d) => { serverLog += d.toString(); });
  for (let i = 0; i < 60; i++) {
    try {
      const r = await fetch(BASE + '/api/health');
      if (r.ok) return;
    } catch { /* 还没起来 */ }
    await sleep(250);
  }
  throw new Error('服务端启动超时\n' + serverLog);
}

function killServer() {
  if (serverProc) { try { serverProc.kill(); } catch { /* ignore */ } }
}

function stopServer() {
  killServer();
  try { fs.rmSync(DATA_DIR, { recursive: true, force: true }); } catch { /* ignore */ }
}

/** 发一个探测包并等应答；timeout 内没回返回 null */
function probe(payloadStr, timeout = 1500) {
  return new Promise((resolve) => {
    const s = dgram.createSocket({ type: 'udp4' });
    const timer = setTimeout(() => {
      try { s.close(); } catch { /* ignore */ }
      resolve(null);
    }, timeout);
    s.on('message', (msg) => {
      clearTimeout(timer);
      try { s.close(); } catch { /* ignore */ }
      try { resolve(JSON.parse(msg.toString('utf8'))); } catch { resolve(null); }
    });
    s.bind(0, () => {
      const buf = Buffer.from(payloadStr, 'utf8');
      s.send(buf, DISCOVER_PORT, '127.0.0.1');
    });
  });
}

(async () => {
  await startServer();
  console.log('[discover E2E] 服务端已就绪 ' + BASE + '\n');

  // 先设一个公司名，验证应答带出来
  let r = await api('POST', '/api/auth/login', { body: { username: 'admin', password: 'admin123' } });
  await api('PUT', '/api/admin/settings', { token: r.body?.token, body: { companyName: '盛京', friendMode: 'work' } });

  // ---------------- 一：协议纪律 ----------------
  console.log('\n【一】协议纪律');
  const resp = await probe('XIAOZHI_DISCOVER_V1');
  ok('正确探测包有应答', !!resp, serverLog.slice(-200));

  const junk = await probe('HELLO_ARE_YOU_THERE');
  ok('无关探测包被忽略（无应答）', junk === null, JSON.stringify(junk));

  // ---------------- 二：应答内容 ----------------
  console.log('\n【二】应答内容');
  if (resp) {
    ok('app 标识正确', resp.app === 'xiaozhi-im', JSON.stringify(resp));
    ok('httpPort = HTTP 端口', resp.httpPort === PORT, JSON.stringify(resp));
    ok('带公司名', resp.companyName === '盛京', JSON.stringify(resp));
    ok('带好友模式', resp.friendMode === 'work', JSON.stringify(resp));
    ok('带服务端版本', typeof resp.serverVersion === 'string' && !!resp.serverVersion, JSON.stringify(resp));
    ok('不带用户数据（无 token/user 字段）',
      !('token' in resp) && !('user' in resp) && !('users' in resp), JSON.stringify(resp));
  } else {
    ok('正确探测包有应答', false, '无应答，后续断言跳过');
  }

  // ---------------- 三：重启后仍在（进程自启） ----------------
  console.log('\n【三】重启后仍在');
  killServer();
  await sleep(300);
  await startServer();
  const resp2 = await probe('XIAOZHI_DISCOVER_V1');
  ok('服务重启后发现服务仍在', !!resp2 && resp2.app === 'xiaozhi-im', JSON.stringify(resp2));

  // ---------------- 汇总 ----------------
  console.log('\n' + '='.repeat(52));
  console.log(`通过 ${passed} / ${passed + failed}`);
  if (failed) {
    console.log('\n失败项：');
    failures.forEach((f) => console.log('  ✗ ' + f));
  }
  console.log('='.repeat(52));
  stopServer();
  process.exit(failed ? 1 : 0);
})().catch((e) => {
  console.error('\n[E2E] 异常中断:', e);
  stopServer();
  process.exit(1);
});
