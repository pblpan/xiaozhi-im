// APNs 推送链路测试
//
//   node server/test/apns_push_test.js
//
// 【为什么必须假 APNs】真 APNs 要 Apple 开发者账号 + .p8 密钥 + 真机令牌，
// 而这套代码在 Mac 到位前根本没机会跑。可它恰恰是"最容易写错却看不出错"的一段：
//   · JWT 少写 dsaEncoding → Apple 只回 403 InvalidProviderToken
//   · 少 apns-topic / apns-push-type → 400，但本地不发永远不会知道
//   · 410 该不该把设备下线 → 判错就是"用户再也收不到推送"
// 所以这里起一个本地假 APNs（明文 h2c，省掉自签证书），把请求头/请求体/签名
// 全部逐项断言。**JWT 是拿公钥真验签的**，和 Apple 的校验方式一致。
//
// 每个场景独立起一个子进程（push.js 读的是模块级配置），并给它一个独立 DATA_DIR
// —— 顺便把 apns.env 的读写（含私钥换行转义）一起测了。

const assert = require('assert');
const crypto = require('crypto');
const fs = require('fs');
const http2 = require('node:http2');
const os = require('os');
const path = require('path');
const { spawn } = require('child_process');

const SERVER_DIR = path.resolve(__dirname, '..');

let pass = 0;
const ok = (name, cond, extra = '') => {
  if (cond) {
    pass++;
    console.log(`  \x1b[32m✓\x1b[0m ${name}`);
  } else {
    console.log(`  \x1b[31m✗\x1b[0m ${name} ${extra}`);
    process.exitCode = 1;
  }
};

// ---------------------------------------------------------------------------
// 假 APNs
// ---------------------------------------------------------------------------

/**
 * @param {(rec:object, n:number)=>{status:number, reason?:string, body?:string}} handler
 */
function fakeApns(handler) {
  const seen = [];
  const srv = http2.createServer();
  srv.on('stream', (stream, headers) => {
    let body = '';
    stream.on('data', (c) => { body += c; });
    stream.on('end', () => {
      const rec = { path: headers[':path'], method: headers[':method'], headers, body };
      seen.push(rec);
      const r = (handler && handler(rec, seen.length)) || { status: 200 };
      const payload = r.body !== undefined
        ? r.body
        : (r.status === 200 ? '' : JSON.stringify({ reason: r.reason || 'Error' }));
      stream.respond({ ':status': r.status, 'content-type': 'application/json' });
      stream.end(payload);
    });
  });
  return new Promise((resolve) => {
    srv.listen(0, '127.0.0.1', () => resolve({
      port: srv.address().port,
      seen,
      close: () => new Promise((r) => srv.close(r)),
    }));
  });
}

// ---------------------------------------------------------------------------
// 测试用密钥与 DATA_DIR
// ---------------------------------------------------------------------------

const { privateKey, publicKey } = crypto.generateKeyPairSync('ec', { namedCurve: 'P-256' });
const P8 = privateKey.export({ type: 'pkcs8', format: 'pem' }).toString();
const KEY_ID = 'ABC123DEFG';
const TEAM_ID = 'TEAM999999';
const TOPIC = 'com.pblpa.xiaozhi-im';

const tmpDirs = [];
function freshDataDir({ apns = true, env = 'production', keyP8 = P8 } = {}) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'xz-push-'));
  tmpDirs.push(dir);
  if (apns) {
    // 刻意按 writeApnsEnv 的格式写：私钥换行转义成 \n 存在一行里。
    // 如果 readApnsEnv 忘了还原，子进程里签名会直接崩 —— 这是有意测的。
    const lines = [
      '# test',
      `APNS_KEY_ID=${KEY_ID}`,
      `APNS_TEAM_ID=${TEAM_ID}`,
      `APNS_TOPIC=${TOPIC}`,
      `APNS_KEY_P8=${keyP8.replace(/\r?\n/g, '\\n')}`,
      `APNS_ENV=${env}`,
    ];
    fs.writeFileSync(path.join(dir, 'apns.env'), lines.join('\n') + '\n', { mode: 0o600 });
  }
  return dir;
}

/** 在子进程里跑一段脚本（cwd=server，独立 DATA_DIR），取回它打印的 JSON */
function runInServer(env, script) {
  // 【踩过的坑】stdout 到管道是**异步写**。push.js 把 h2 会话 unref 之后，
  // 事件循环一空进程立刻退出，最后那句 console.log 常常还没刷出去 ——
  // 表现是"子进程退出码 0，但一个 JSON 都没收到"。
  // 所以显式在 beforeExit 里等一拍再退。
  const wrapped = `${script}
process.on('beforeExit', () => setTimeout(() => process.exit(0), 60));
`;
  return new Promise((resolve, reject) => {
    const p = spawn(process.execPath, ['-e', wrapped], {
      cwd: SERVER_DIR,
      env: { ...process.env, ...env },
    });
    let out = '', err = '';
    p.stdout.on('data', (d) => { out += d; });
    p.stderr.on('data', (d) => { err += d; });
    p.on('close', (code) => {
      if (code !== 0) return reject(new Error(err || `exit ${code}`));
      // 启动日志（迁移提示、管理员口令）会和结果混在 stdout 里，
      // 从后往前找第一行"看起来是 JSON"的。
      const lines = out.trim().split('\n').map((s) => s.trim()).filter(Boolean);
      for (let i = lines.length - 1; i >= 0; i--) {
        if (!lines[i].startsWith('{')) continue;
        try { return resolve(JSON.parse(lines[i])); } catch { /* 继续往前找 */ }
      }
      reject(new Error(`输出里没有 JSON: ${out} / ${err}`));
    });
  });
}

const TOKEN_A = 'a1'.repeat(32);
const TOKEN_B = 'b2'.repeat(32);

/** 子进程里通用的一段：把状态打出来 */
const HELPERS = `
const db = require('./src/db');
const dump = () => ({
  devices: db.prepare('SELECT id,user_id,active,fail_count,last_error,env,platform FROM push_devices ORDER BY id').all(),
  logs: db.prepare('SELECT ok,status,reason,title,body,token_tail FROM push_log ORDER BY id').all(),
});
`;

// ===========================================================================
(async () => {
  console.log('='.repeat(60));
  console.log('APNs 推送链路');
  console.log('='.repeat(60));

  // ---- [1] 没配置：什么都别发生 ----
  {
    console.log('\n[1] 没配 Apple 密钥（升级前的默认状态）');
    const d = freshDataDir({ apns: false });
    const apns = await fakeApns();
    const r = await runInServer(
      { DATA_DIR: d, APNS_URL: `http://127.0.0.1:${apns.port}` },
      `${HELPERS}
const push = require('./src/push');
(async () => {
  const reg = push.registerDevice({ userId: 7, token: '${TOKEN_A}', deviceName: 'iPhone' });
  const send = await push.sendToUser(7, { title: 't', body: 'b' });
  console.log(JSON.stringify({ enabled: push.enabled(), reg: reg.error || 'ok', send, ...dump() }));
})();
`
    );
    ok('enabled=false', r.enabled === false);
    ok('令牌仍能登记（客户端不知道服务端配没配）', r.reg === 'ok');
    ok('sendToUser 返回 configured:false / sent:0',
      r.send.configured === false && r.send.sent === 0, JSON.stringify(r.send));
    ok('一次 APNs 请求都没发出去', apns.seen.length === 0, `hits=${apns.seen.length}`);
    ok('push_log 空（没发就没记录）', r.logs.length === 0);
    await apns.close();
  }

  // ---- [2] 正常投递：逐项断言请求长什么样 ----
  let basicSeen = null;
  {
    console.log('\n[2] 配置齐全 + 假 APNs 返回 200');
    const d = freshDataDir();
    const apns = await fakeApns(() => ({ status: 200 }));
    const r = await runInServer(
      { DATA_DIR: d, APNS_URL: `http://127.0.0.1:${apns.port}` },
      `${HELPERS}
const push = require('./src/push');
(async () => {
  push.registerDevice({ userId: 7, token: '${TOKEN_A}', deviceName: 'iPhone 15' });
  const send = await push.sendToUser(7, {
    title: '张三', body: '你好呀', collapseId: 'conv-42', threadId: 'conv-42', badge: 5,
    data: { conversationId: 42, messageId: 99 },
  });
  console.log(JSON.stringify({ enabled: push.enabled(), send, probe: push.probe(), ...dump() }));
})();
`
    );
    basicSeen = apns.seen[0];
    ok('enabled=true', r.enabled === true);
    ok('本地自检通过', r.probe.ok === true, JSON.stringify(r.probe));
    ok('投递结果 sent=1 ok=1', r.send.sent === 1 && r.send.ok === 1, JSON.stringify(r.send));
    ok('请求方法/路径正确',
      basicSeen.method === 'POST' && basicSeen.path === `/3/device/${TOKEN_A}`,
      `${basicSeen.method} ${basicSeen.path}`);
    ok('带 apns-topic', basicSeen.headers['apns-topic'] === TOPIC, String(basicSeen.headers['apns-topic']));
    ok('带 apns-push-type=alert', basicSeen.headers['apns-push-type'] === 'alert');
    ok('apns-priority=10（立即投递）', basicSeen.headers['apns-priority'] === '10');
    ok('带 apns-collapse-id（同会话合并）', basicSeen.headers['apns-collapse-id'] === 'conv-42');
    ok('带 apns-id', /^[0-9a-f-]{36}$/i.test(String(basicSeen.headers['apns-id'])), String(basicSeen.headers['apns-id']));
    ok('apns-expiration 是未来时间戳',
      Number(basicSeen.headers['apns-expiration']) > Math.floor(Date.now() / 1000));
    ok('带 authorization: bearer', /^bearer \S+\.\S+\.\S+$/.test(String(basicSeen.headers.authorization)),
      String(basicSeen.headers.authorization).slice(0, 40));

    // ---- JWT 真验签（与 Apple 的校验方式一致）----
    const jwt = String(basicSeen.headers.authorization).replace(/^bearer /, '');
    const [h, p, s] = jwt.split('.');
    const head = JSON.parse(Buffer.from(h, 'base64url').toString());
    const clm = JSON.parse(Buffer.from(p, 'base64url').toString());
    ok('JWT header: alg=ES256 + kid 正确', head.alg === 'ES256' && head.kid === KEY_ID, JSON.stringify(head));
    ok('JWT claims: iss=Team ID', clm.iss === TEAM_ID, JSON.stringify(clm));
    ok('JWT iat 在 1 小时内', Math.abs(clm.iat - Math.floor(Date.now() / 1000)) < 3600);
    ok('JWT 签名能被公钥验过（ieee-p1363 编码）',
      crypto.verify('sha256', Buffer.from(`${h}.${p}`),
        { key: publicKey, dsaEncoding: 'ieee-p1363' },
        Buffer.from(s, 'base64url')));

    // ---- 请求体 ----
    const body = JSON.parse(basicSeen.body);
    ok('aps.alert.title 正确', body.aps.alert.title === '张三', JSON.stringify(body.aps.alert));
    ok('aps.alert.body 正确', body.aps.alert.body === '你好呀');
    ok('aps.sound=default', body.aps.sound === 'default');
    ok('aps.badge 带上未读数', body.aps.badge === 5);
    ok('aps.thread-id 带上（同一会话来电/消息归组）', body.aps['thread-id'] === 'conv-42');
    ok('自定义 data 用于点击跳转', body.conversationId === 42 && body.messageId === 99,
      JSON.stringify(body));

    // ---- 落库与可观测性 ----
    ok('push_log 有 1 条 ok=1 status=200',
      r.logs.length === 1 && r.logs[0].ok === 1 && r.logs[0].status === 200, JSON.stringify(r.logs));
    ok('日志里的令牌只留尾 8 位',
      r.logs[0].token_tail.length === 8 && r.logs[0].token_tail === TOKEN_A.slice(-8));
    ok('设备标记为有效并记 last_ok',
      r.devices.length === 1 && r.devices[0].active === 1 && r.devices[0].fail_count === 0,
      JSON.stringify(r.devices));
    ok('apns.env 里私钥是多行 PEM（转义已还原）',
      fs.readFileSync(path.join(d, 'apns.env'), 'utf8').includes('BEGIN PRIVATE KEY'));
    await apns.close();

    // ---- [2b] 第二次投递复用同一个 provider JWT ----
    console.log('\n[2b] 同一分钟内的第二条：JWT 应复用（Apple 要求至少每小时换一次，不用每条都签）');
    const apns2 = await fakeApns(() => ({ status: 200 }));
    const r2 = await runInServer(
      { DATA_DIR: d, APNS_URL: `http://127.0.0.1:${apns2.port}` },
      `${HELPERS}
const push = require('./src/push');
(async () => {
  push.registerDevice({ userId: 7, token: '${TOKEN_A}' });
  await push.sendToUser(7, { title: '一', body: '1' });
  await push.sendToUser(7, { title: '二', body: '2' });
  console.log(JSON.stringify({ n: dump().logs.length }));
})();
`
    );
    const auth1 = apns2.seen[0].headers.authorization;
    const auth2 = apns2.seen[1].headers.authorization;
    ok('两条都发出去了', apns2.seen.length === 2);
    ok('两条用的是同一个 JWT（缓存生效）', auth1 === auth2, `${auth1} vs ${auth2}`);
    // 这个 DATA_DIR 与 [2] 共用，所以累计是 [2] 的 1 条 + 这里的 2 条
    ok('push_log 累计 3 条（[2] 1 条 + 这里 2 条）', r2.n === 3, JSON.stringify(r2));
    await apns2.close();
  }

  // ---- [3] 410 Unregistered → 令牌作废，不再投 ----
  {
    console.log('\n[3] APNs 回 410 Unregistered（App 被卸载 / 令牌过期）');
    const d = freshDataDir();
    const apns = await fakeApns(() => ({ status: 410, reason: 'Unregistered' }));
    const r = await runInServer(
      { DATA_DIR: d, APNS_URL: `http://127.0.0.1:${apns.port}` },
      `${HELPERS}
const push = require('./src/push');
(async () => {
  push.registerDevice({ userId: 7, token: '${TOKEN_A}' });
  const first = await push.sendToUser(7, { title: 't', body: 'b' });
  const second = await push.sendToUser(7, { title: 't', body: 'b' });
  console.log(JSON.stringify({ first, second, ...dump() }));
})();
`
    );
    ok('第一次真的发了', r.first.sent === 1);
    ok('第一次 ok=0（失败了）', r.first.ok === 0);
    ok('设备被下架 active=0', r.devices[0].active === 0, JSON.stringify(r.devices));
    ok('last_error 记下 Unregistered', r.devices[0].last_error === 'Unregistered', String(r.devices[0].last_error));
    ok('第二次不再向 APNs 发请求（省掉无用投递）',
      r.second.sent === 0 && apns.seen.length === 1, `hits=${apns.seen.length}`);
    ok('日志里能查到失败原因', r.logs.some((l) => l.ok === 0 && l.reason === 'Unregistered'),
      JSON.stringify(r.logs));
    await apns.close();
  }

  // ---- [4] 400 BadDeviceToken → 同样作废 ----
  {
    console.log('\n[4] APNs 回 400 BadDeviceToken（令牌写错 / 环境不匹配）');
    const d = freshDataDir();
    const apns = await fakeApns(() => ({ status: 400, reason: 'BadDeviceToken' }));
    await runInServer(
      { DATA_DIR: d, APNS_URL: `http://127.0.0.1:${apns.port}` },
      `${HELPERS}
const push = require('./src/push');
(async () => {
  push.registerDevice({ userId: 7, token: '${TOKEN_A}' });
  await push.sendToUser(7, { title: 't', body: 'b' });
  console.log(JSON.stringify(dump()));
})();
`
    );
    const r4 = await runInServer(
      { DATA_DIR: d, APNS_URL: `http://127.0.0.1:${apns.port}` },
      `${HELPERS}
console.log(JSON.stringify(dump()));
`
    );
    ok('设备被下架 active=0', r4.devices[0].active === 0, JSON.stringify(r4.devices));
    ok('last_error 记下 BadDeviceToken', r4.devices[0].last_error === 'BadDeviceToken');
    await apns.close();
  }

  // ---- [5] 500（Apple 侧抖动）→ 绝不作废令牌 ----
  {
    console.log('\n[5] APNs 回 500（服务端抖动）：令牌必须留着，下次还要投');
    const d = freshDataDir();
    const apns = await fakeApns(() => ({ status: 500, reason: 'InternalServerError' }));
    const r = await runInServer(
      { DATA_DIR: d, APNS_URL: `http://127.0.0.1:${apns.port}` },
      `${HELPERS}
const push = require('./src/push');
(async () => {
  push.registerDevice({ userId: 7, token: '${TOKEN_A}' });
  const s1 = await push.sendToUser(7, { title: 't', body: 'b' });
  const s2 = await push.sendToUser(7, { title: 't', body: 'b' });
  console.log(JSON.stringify({ s1, s2, ...dump() }));
})();
`
    );
    ok('设备仍是 active（没被误杀）', r.devices[0].active === 1, JSON.stringify(r.devices));
    ok('fail_count 累加到 2', r.devices[0].fail_count === 2, String(r.devices[0].fail_count));
    ok('第二次仍会重试（两次都发了）', r.s2.sent === 1 && apns.seen.length === 2, `hits=${apns.seen.length}`);
    ok('错误原因落库可查', r.devices[0].last_error === 'InternalServerError');
    await apns.close();
  }

  // ---- [6] 响应体不是 JSON（网关拦截）也不能崩 ----
  {
    console.log('\n[6] APNs 回一段 HTML（中间有网关/代理时的样子）');
    const d = freshDataDir();
    const apns = await fakeApns(() => ({ status: 502, body: '<html>Bad Gateway</html>' }));
    const r = await runInServer(
      { DATA_DIR: d, APNS_URL: `http://127.0.0.1:${apns.port}` },
      `${HELPERS}
const push = require('./src/push');
(async () => {
  push.registerDevice({ userId: 7, token: '${TOKEN_A}' });
  const s = await push.sendToUser(7, { title: 't', body: 'b' });
  console.log(JSON.stringify({ s, ...dump() }));
})();
`
    );
    ok('不抛异常，返回失败计数', r.s.sent === 1 && r.s.ok === 0);
    ok('reason 退化成 HTTP 状态码', /502/.test(String(r.logs[0].reason)), String(r.logs[0].reason));
    ok('设备没被冤杀', r.devices[0].active === 1);
    await apns.close();
  }

  // ---- [7] env 不匹配：sandbox 令牌不该被 production 的服务器投坏 ----
  {
    console.log('\n[7] 设备令牌是 sandbox、服务端配的是 production');
    const d = freshDataDir({ env: 'production' });
    const apns = await fakeApns(() => ({ status: 400, reason: 'BadDeviceToken' }));
    const r = await runInServer(
      { DATA_DIR: d, APNS_URL: `http://127.0.0.1:${apns.port}` },
      `${HELPERS}
const push = require('./src/push');
(async () => {
  push.registerDevice({ userId: 7, token: '${TOKEN_A}', env: 'sandbox' });
  const s = await push.sendToUser(7, { title: 't', body: 'b' });
  console.log(JSON.stringify({ s, ...dump() }));
})();
`
    );
    ok('一条都不发（跳过 env 不匹配的设备）', r.s.sent === 0 && apns.seen.length === 0, `hits=${apns.seen.length}`);
    ok('计数里体现 skipped', r.s.skipped === 1, JSON.stringify(r.s));
    ok('设备保持 active（没被 BadDeviceToken 误杀）', r.devices[0].active === 1);
    await apns.close();
  }

  // ---- [8] 一台设备换人登录：旧账号的推送必须立刻停 ----
  {
    console.log('\n[8] 同一台手机换账号登录（令牌相同，user 变了）');
    const d = freshDataDir();
    const apns = await fakeApns(() => ({ status: 200 }));
    const r = await runInServer(
      { DATA_DIR: d, APNS_URL: `http://127.0.0.1:${apns.port}` },
      `${HELPERS}
const push = require('./src/push');
(async () => {
  push.registerDevice({ userId: 7, token: '${TOKEN_A}' });
  push.registerDevice({ userId: 8, token: '${TOKEN_A}' });      // 换人登录
  await push.sendToUser(7, { title: '给7', body: 'x' });         // 旧账号：不该投
  const s8 = await push.sendToUser(8, { title: '给8', body: 'x' }); // 新账号：该投
  console.log(JSON.stringify({ s8, ...dump() }));
})();
`
    );
    ok('同一令牌只留一行（没有重复设备）', r.devices.length === 1, JSON.stringify(r.devices));
    ok('归属已改成新用户', r.devices[0].user_id === 8, String(r.devices[0].user_id));
    ok('旧账号完全收不到（只发了 1 次）', apns.seen.length === 1, `hits=${apns.seen.length}`);
    ok('投的是新账号那条', r.s8.sent === 1);
    await apns.close();
  }

  // ---- [9] 端到端：发消息 → 该推谁、文案对不对、在线不推 ----
  {
    console.log('\n[9] 端到端：发消息到底推给谁（chat.js 组装文案）');
    const d = freshDataDir();
    const apns = await fakeApns(() => ({ status: 200 }));
    const r = await runInServer(
      { DATA_DIR: d, APNS_URL: `http://127.0.0.1:${apns.port}` },
      `${HELPERS}
const hub = require('./src/hub');
const chat = require('./src/chat');
const push = require('./src/push');

const now = Date.now();
// 注意 Number()：node:sqlite 的 lastInsertRowid 可能是 BigInt，
// 直接拿去当 userId 会被 registerDevice 的 Number.isInteger 判为非法。
const mkUser = (name, nick) => Number(db.prepare(
  'INSERT INTO users (username, password_hash, nickname, role, created_at) VALUES (?,?,?,?,?)')
  .run(name, 'x', nick, 'user', now).lastInsertRowid);
const mkConv = (type) => Number(db.prepare('INSERT INTO conversations (type, created_at) VALUES (?,?)')
  .run(type, now).lastInsertRowid);
const join = (cid, uid) => db.prepare(
  'INSERT INTO conversation_members (conversation_id, user_id, last_read_id) VALUES (?,?,0)').run(cid, uid);

const A = mkUser('u_a', '甲方');
const B = mkUser('u_b', '乙方');
const C = mkUser('u_c', '丙方');

// 单聊 A <-> B
const dm = mkConv('dm');
join(dm, A); join(dm, B);

// 群聊 A/B/C
const gc = mkConv('group');
join(gc, A); join(gc, B); join(gc, C);
db.prepare('INSERT INTO groups (name, owner_id, conversation_id, created_at) VALUES (?,?,?,?)')
  .run('项目群', A, gc, now);

// 只给 B 登记 iOS 设备
push.registerDevice({ userId: B, token: '${TOKEN_B}', deviceName: 'B 的 iPhone' });

(async () => {
  const out = { steps: [] };
  const pushCount = () => dump().logs.length;

  // ① B 离线 → 单聊消息应推 1 条
  chat.sendMessage({ conversationId: dm, senderId: A, kind: 'text', content: '在吗' });
  await new Promise(r => setTimeout(r, 120));
  out.steps.push({ step: 'dm-offline', n: pushCount(), logs: dump().logs });

  // ② B 在线（有 WS）→ 不该推
  const fakeWs = { readyState: 1, OPEN: 1, send() {} };
  hub.addSocket(B, fakeWs);
  chat.sendMessage({ conversationId: dm, senderId: A, kind: 'text', content: '在线时' });
  await new Promise(r => setTimeout(r, 120));
  out.steps.push({ step: 'dm-online', n: pushCount() });
  hub.removeSocket(B, fakeWs);

  // ③ 群里发的 → 标题应是群名，正文带发送者
  chat.sendMessage({ conversationId: gc, senderId: A, kind: 'text', content: '开会了' });
  await new Promise(r => setTimeout(r, 120));
  out.steps.push({ step: 'group', n: pushCount(), logs: dump().logs });

  // ④ 各种类型的预览文案
  const kinds = [['image', '1'], ['audio', '3'], ['file', '1'], ['call', 'x'], ['card', 'x']];
  const f = Number(db.prepare('INSERT INTO files (owner_id, name, mime, size, path, created_at) VALUES (?,?,?,?,?,?)')
    .run(A, '报表.xlsx', 'application/xlsx', 10, 'p/x', now).lastInsertRowid);
  for (const [k, c] of kinds) {
    try {
      chat.sendMessage({ conversationId: dm, senderId: A, kind: k,
        content: k === 'card' ? { title: '库存预警', text: '低于安全库存' } : c,
        fileId: (k === 'image' || k === 'audio' || k === 'file') ? f : null });
    } catch (e) { out.err = k + ':' + e.message; }
    await new Promise(r => setTimeout(r, 120));
  }
  out.steps.push({ step: 'kinds', logs: dump().logs });

  // ⑤ 自己发给自己的会话不推
  const self = mkConv('dm');
  join(self, A); join(self, B);
  push.registerDevice({ userId: A, token: '${TOKEN_A}' });
  chat.sendMessage({ conversationId: self, senderId: B, kind: 'text', content: '给A' });
  await new Promise(r => setTimeout(r, 120));
  out.steps.push({ step: 'toA', logs: dump().logs });

  out.preview = {
    text: chat.previewOf({ kind: 'text', content: '你好' }),
    image: chat.previewOf({ kind: 'image' }),
    audio: chat.previewOf({ kind: 'audio' }),
    file: chat.previewOf({ kind: 'file', file_name: '报表.xlsx' }),
    card: chat.previewOf({ kind: 'card', content: JSON.stringify({ title: '库存预警' }) }),
    call: chat.previewOf({ kind: 'call' }),
    badCard: chat.previewOf({ kind: 'card', content: '{坏 JSON' }),
  };
  console.log(JSON.stringify(out));
})();
`
    );
    const step = (n) => r.steps.find((s) => s.step === n) || {};
    const dm1 = step('dm-offline');
    ok('① 离线时单聊消息推了 1 条', dm1.n === 1, JSON.stringify(dm1));
    ok('① 标题=对方昵称（接收方视角的会话名）', dm1.logs && dm1.logs[0].title === '甲方',
      dm1.logs && dm1.logs[0].title);
    ok('① 正文=消息内容', dm1.logs && dm1.logs[0].body === '在吗');
    ok('② 在线时不推（消息已实时到达，不重复打扰）', step('dm-online').n === 1, JSON.stringify(step('dm-online')));
    const g = step('group');
    ok('③ 群里发的推给了 B（C 没设备）', g.n === 2, String(g.n));
    ok('③ 群消息标题=群名', g.logs && g.logs[1].title === '项目群', JSON.stringify(g.logs && g.logs[1]));
    ok('③ 群消息正文带发送者名', g.logs && /^甲方：/.test(String(g.logs[1].body)), String(g.logs && g.logs[1].body));
    ok('④ 各类型预览正确',
      r.preview.image === '[图片]' && r.preview.audio === '[语音]' &&
      r.preview.file === '[文件] 报表.xlsx' && r.preview.card === '[卡片] 库存预警' &&
      r.preview.call === '[通话]' && r.preview.text === '你好',
      JSON.stringify(r.preview));
    ok('④ 卡片 JSON 坏了也不崩', r.preview.badCard === '[卡片]', r.preview.badCard);
    ok('④ 没有"不支持的消息类型"之类报错', !r.err, String(r.err));
    const kindLogs = step('kinds').logs || [];
    ok('④ 5 种类型各推了 1 条', kindLogs.length === 7, String(kindLogs.length));
    ok('④ 图片/语音/文件/卡片/通话的正文都对',
      kindLogs.slice(2).map((l) => l.body).join('|') ===
      '[图片]|[语音]|[文件] 报表.xlsx|[通话]|[卡片] 库存预警',
      kindLogs.slice(2).map((l) => l.body).join('|'));
    const toA = step('toA').logs || [];
    ok('⑤ 给 A 的消息推到了 A 的设备',
      toA[toA.length - 1].token_tail === TOKEN_A.slice(-8), JSON.stringify(toA[toA.length - 1]));
    ok('⑤ 自己发的不会推给自己（只推了接收方 1 条）',
      toA.filter((l) => l.token_tail === TOKEN_B.slice(-8)).length === 7,
      String(toA.length));
    await apns.close();
  }

  // ---- [10] 配置自检：填错要能当场发现 ----
  {
    console.log('\n[10] 管理台「自检」对错配置的判定');
    const cases = [
      ['缺私钥', { keyP8: '' }, false],
      ['Key ID 位数不对', { keyId: 'abc' }, false],
      ['贴成证书（不是私钥）', { keyP8: '-----BEGIN CERTIFICATE-----\nabc\n-----END CERTIFICATE-----' }, false],
      ['私钥内容不是密钥', { keyP8: '-----BEGIN PRIVATE KEY-----\nbm90YWtleQ==\n-----END PRIVATE KEY-----' }, false],
    ];
    for (const [name, patch, expectOk] of cases) {
      const d = freshDataDir();
      const r = await runInServer(
        { DATA_DIR: d },
        `
const push = require('./src/push');
const p = push.probeWith(${JSON.stringify(patch)});
// 自检不能改动已保存的配置
const info = push.info();
console.log(JSON.stringify({ p, info }));
`
      );
      ok(`「${name}」被判为不可用`, r.p.ok === expectOk, JSON.stringify(r.p));
      ok(`「${name}」自检后配置未被改动（enabled 仍是 true）`, r.info.enabled === true,
        JSON.stringify({ enabled: r.info.enabled }));
    }
    // 正确的应通过
    const d = freshDataDir();
    const r = await runInServer({ DATA_DIR: d },
      `
const push = require('./src/push');
console.log(JSON.stringify({ ok: push.probe().ok, endpoint: push.info().endpoint,
  prod: push.info().env, l: push.info().envLabel }));
`);
    ok('正确配置自检通过', r.ok === true);
    ok('默认接入点是生产（api.push.apple.com）',
      r.endpoint === 'https://api.push.apple.com', r.endpoint);
    ok('环境标签是中文', r.l === '生产（production）', r.l);
  }

  console.log('\n' + '='.repeat(60));
  console.log(process.exitCode ? '有失败项' : `全部通过（${pass} 项）`);
  console.log('='.repeat(60));

  for (const dir of tmpDirs) {
    try { fs.rmSync(dir, { recursive: true, force: true }); } catch { /* 忽略 */ }
  }
})().catch((e) => {
  console.error(e);
  process.exit(1);
});
