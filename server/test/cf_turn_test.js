// Cloudflare TURN 下发链路测试
//
//   node server/test/cf_turn_test.js
//
// 不碰真 Cloudflare（没凭据也测不了），用本地 HTTP 服务假装
// /v1/turn/keys/<id>/credentials/generate，验证：
//   ① 配了 key+token → 下发里出现 turn:/turns: 条目
//   ② 凭据带上了 username / credential
//   ③ 第二次调用走缓存，不再打签发接口（客户端 5 分钟一拉，不能每次都签）
//   ④ 签发失败时：不崩、STUN 照发、也不重复刷接口（有缓存就复用旧的）
//   ⑤ 没配 key 时维持原样：只有 STUN，turnConfigured=false
//
// 单独起进程跑，因为 config.js 是模块级读环境变量的。

const http = require('http');
const assert = require('assert');
const path = require('path');
const { spawn } = require('child_process');

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

const CF_BODY = {
  iceServers: {
    urls: [
      'turn:turn.cloudflare.com:3478?transport=udp',
      'turn:turn.cloudflare.com:3478?transport=tcp',
      'turns:turn.cloudflare.com:5349?transport=tcp',
    ],
    username: 'cf-user-abc',
    credential: 'cf-cred-xyz',
  },
};

/** 起一个假 CF 签发接口 */
function fakeCf({ fail = false } = {}) {
  let hits = 0;
  const seen = [];
  const srv = http.createServer((req, res) => {
    hits++;
    seen.push({ url: req.url, auth: req.headers.authorization || '' });
    let body = '';
    req.on('data', (c) => (body += c));
    req.on('end', () => {
      if (fail) {
        res.writeHead(401, { 'Content-Type': 'application/json' });
        return res.end(JSON.stringify({ error: 'bad token' }));
      }
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify(CF_BODY));
    });
  });
  return new Promise((resolve) => {
    srv.listen(0, '127.0.0.1', () =>
      resolve({
        port: srv.address().port,
        get hits() { return hits; },
        get seen() { return seen; },
        close: () => new Promise((r) => srv.close(r)),
      }));
  });
}

/** 在子进程里按给定环境加载 config.js，跑一段脚本，把它打印的 JSON 读回来 */
function loadConfig(env, script) {
  return new Promise((resolve, reject) => {
    const p = spawn(
      process.execPath,
      ['-e', script],
      {
        cwd: path.resolve(__dirname, '..'),
        env: { ...process.env, ...env },
      }
    );
    let out = '', err = '';
    p.stdout.on('data', (d) => (out += d));
    p.stderr.on('data', (d) => (err += d));
    p.on('close', (code) => {
      if (code !== 0) return reject(new Error(err || `exit ${code}`));
      try {
        resolve(JSON.parse(out.trim().split('\n').pop()));
      } catch (e) {
        reject(new Error(`输出不是 JSON: ${out} / ${err}`));
      }
    });
  });
}

const RUN = `
const config = require('./src/config');
(async () => {
  const list = await config.iceServers();
  const list2 = await config.iceServers();   // 第二次，验证缓存
  console.log(JSON.stringify({ list, list2, info: config.turnInfo() }));
})().catch((e) => { console.error(e); process.exit(1); });
`;

(async () => {
  console.log('='.repeat(56));
  console.log('Cloudflare TURN 下发链路');
  console.log('='.repeat(56));

  // ---- ① 正常签发 ----
  const cf = await fakeCf();
  console.log('\n[1] 配了 key+token，假 CF 正常返回');
  let r = await loadConfig(
    {
      CF_TURN_KEY_ID: 'test-key-id',
      CF_TURN_API_TOKEN: 'test-token',
      CF_TURN_API_BASE: `http://127.0.0.1:${cf.port}/v1/turn/keys`,
      ICE_STUN: 'stun:stun.miwifi.com:3478',
    },
    RUN
  );
  const blob = JSON.stringify(r.list);
  ok('下发里有 TURN over UDP', blob.includes('turn:turn.cloudflare.com:3478?transport=udp'));
  ok('下发里有 TURN over TLS(5349)', blob.includes('turns:turn.cloudflare.com:5349?transport=tcp'));
  const cfEntry = r.list.find((s) => JSON.stringify(s.urls).includes('cloudflare'));
  ok('TURN 条目带 username', cfEntry && cfEntry.username === 'cf-user-abc',
    `got=${cfEntry && cfEntry.username}`);
  ok('TURN 条目带 credential', cfEntry && cfEntry.credential === 'cf-cred-xyz');
  ok('STUN 仍在列表里', r.list.some((s) => String(s.urls).includes('stun.miwifi.com')));
  ok('排序：STUN 在前、TURN 在后',
    r.list.findIndex((s) => String(s.urls).includes('stun.miwifi')) <
    r.list.findIndex((s) => JSON.stringify(s.urls).includes('cloudflare')));
  ok('签发接口只被调了 1 次（第二次走缓存）', cf.hits === 1, `hits=${cf.hits}`);
  ok('带上了 Bearer 鉴权', cf.seen[0] && cf.seen[0].auth === 'Bearer test-token',
    `auth=${cf.seen[0] && cf.seen[0].auth}`);
  ok('URL 路径正确', cf.seen[0] && cf.seen[0].url === '/v1/turn/keys/test-key-id/credentials/generate',
    `url=${cf.seen[0] && cf.seen[0].url}`);
  ok('turnInfo.sources 含 cloudflare',
    r.info.sources.includes('cloudflare'), JSON.stringify(r.info));
  ok('turnInfo.cloudflareError 为空', !r.info.cloudflareError, String(r.info.cloudflareError));
  await cf.close();

  // ---- ② 签发失败 ----
  const bad = await fakeCf({ fail: true });
  console.log('\n[2] 假 CF 返回 401（token 写错 / 被吊销）');
  r = await loadConfig(
    {
      CF_TURN_KEY_ID: 'test-key-id',
      CF_TURN_API_TOKEN: 'wrong-token',
      CF_TURN_API_BASE: `http://127.0.0.1:${bad.port}/v1/turn/keys`,
      ICE_STUN: 'stun:stun.miwifi.com:3478',
    },
    RUN
  );
  ok('签发失败不抛异常，STUN 照发',
    r.list.length === 1 && String(r.list[0].urls).includes('stun.miwifi.com'),
    JSON.stringify(r.list));
  ok('没有 turn: 条目', !JSON.stringify(r.list).includes('turn:'));
  ok('错误原因被记下来（方便排障）',
    /401/.test(String(r.info.cloudflareError)), String(r.info.cloudflareError));
  // 失败不缓存 → 第二次仍会重试，但只有 2 次（不是无限刷）
  ok('失败时不写缓存，共请求 2 次（两次 iceServers）', bad.hits === 2, `hits=${bad.hits}`);
  await bad.close();

  // ---- ③ 没配 key（老部署保持原样）----
  console.log('\n[3] 没配 CF key + 没有静态 TURN（升级前的默认状态）');
  r = await loadConfig(
    { CF_TURN_KEY_ID: '', CF_TURN_API_TOKEN: '', TURN_URLS: '', ICE_STUN: 'stun:stun.miwifi.com:3478' },
    RUN
  );
  ok('只有 STUN', r.list.length === 1 && String(r.list[0].urls).includes('stun.miwifi.com'));
  ok('sources 为空', r.info.sources.length === 0, JSON.stringify(r.info.sources));
  ok('cloudflareEnabled=false', r.info.cloudflareEnabled === false);

  // ---- ④ CF + 自建静态 TURN 并存 ----
  console.log('\n[4] CF 与自建 coturn 并存（双保险）');
  const cf2 = await fakeCf();
  r = await loadConfig(
    {
      CF_TURN_KEY_ID: 'k', CF_TURN_API_TOKEN: 't',
      CF_TURN_API_BASE: `http://127.0.0.1:${cf2.port}/v1/turn/keys`,
      TURN_URLS: 'turn:112.99.176.76:3478?transport=udp,turn:112.99.176.76:3478?transport=tcp',
      TURN_USERNAME: 'xiaozhi', TURN_CREDENTIAL: 'xiaozhi-turn-2026',
      ICE_STUN: 'stun:stun.miwifi.com:3478',
    },
    RUN
  );
  ok('两条中继都在（CF + 自建）',
    JSON.stringify(r.list).includes('turn.cloudflare.com') &&
    JSON.stringify(r.list).includes('112.99.176.76'),
    JSON.stringify(r.list.map((s) => s.urls)));
  ok('自建那条带 coturn 账号',
    r.list.some((s) => s.username === 'xiaozhi' && s.credential === 'xiaozhi-turn-2026'));
  ok('sources = [cloudflare, static]',
    JSON.stringify(r.info.sources) === JSON.stringify(['cloudflare', 'static']),
    JSON.stringify(r.info.sources));
  await cf2.close();

  console.log('\n' + '='.repeat(56));
  console.log(process.exitCode ? '有失败项' : `全部通过（${pass} 项）`);
  console.log('='.repeat(56));
})();
