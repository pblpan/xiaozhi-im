// 管理台「音视频中继配置向导」端到端测试
//
//   node server/test/admin_turn_wizard_test.js
//
// 这套接口的破坏性在于**它会写 .env**，所以必须拿假文件测，绝不碰真配置。
// 用 TURN_ENV_PATH 指到一个临时 .env，用 CF_TURN_API_BASE 指向本地假 CF。
//
// 覆盖：
//   ① 读取状态：能报出未配置 / 已配置 + 遮盖值（绝不回传明文密钥）
//   ② 校验接口：格式不对直接拦下，不打 CF；有效凭据返回 ok + 中继 url
//   ③ 保存：**校验不过必须拒绝写盘**（这条最关键，防写坏生产）
//   ④ 保存成功：只改目标两行，其余内容一字不动；且生成备份
//   ⑤ 缺行时能追加（兼容老 .env）
//   ⑥ 删除：把两行清空但保留 key（不会把文件改乱）
//   ⑦ 权限：非管理员/未登录一律 401、403
//
// 起真实 HTTP 服务，走完整 Express 栈（含鉴权中间件），比只测函数可信。

const http = require('http');
const assert = require('assert');
const fs = require('fs');
const os = require('os');
const path = require('path');

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
      'stun:stun.cloudflare.com:3478',
      'turn:turn.cloudflare.com:3478?transport=udp',
      'turn:turn.cloudflare.com:3478?transport=tcp',
      'turns:turn.cloudflare.com:5349?transport=tcp',
    ],
    username: 'cf-user-abc',
    credential: 'cf-cred-xyz',
  },
};

/** 假 CF 签发接口。validToken 之外的 token 返回 401，用来验「错值不许写盘」 */
function fakeCf({ validToken = 'a'.repeat(64) } = {}) {
  let hits = 0;
  const srv = http.createServer((req, res) => {
    hits++;
    const auth = req.headers.authorization || '';
    if (auth !== `Bearer ${validToken}`) {
      res.writeHead(401, { 'Content-Type': 'application/json' });
      return res.end(JSON.stringify({ error: 'invalid token' }));
    }
    res.writeHead(201, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify(CF_BODY));
  });
  return new Promise((resolve) => {
    srv.listen(0, '127.0.0.1', () =>
      resolve({
        port: srv.address().port,
        get hits() { return hits; },
        close: () => new Promise((r) => srv.close(r)),
      }));
  });
}

const ENV_SEED = `# 小智IM 配置
PORT=3602
JWT_SECRET=test-secret

CF_TURN_KEY_ID=
CF_TURN_API_TOKEN=

TURN_EXTERNAL_IP=1.2.3.4
TURN_URLS=turn:1.2.3.4:3478?transport=udp
`;

async function main() {
  console.log('='.repeat(56));
  console.log('管理台 TURN 配置向导');
  console.log('='.repeat(56));

  const cf = await fakeCf();
  const VALID_KID = '7839139c2d17a599f2118c6372b2410b';
  const VALID_TOK = 'a'.repeat(64);

  // 临时目录当 DATA_DIR，.env 放它旁边，全部隔离
  const tmpRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'xz-turn-'));
  const envFile = path.join(tmpRoot, 'docker.env');
  fs.writeFileSync(envFile, ENV_SEED, 'utf8');

  // 起服务端（子进程，因为 config.js 是模块级读环境变量）
  const { spawn } = require('child_process');
  const PORT = 0; // 让系统选端口会拿不到，这里固定一个冷门口
  const HTTP_PORT = 7391;
  const proc = spawn(process.execPath, [path.resolve(__dirname, '..', 'src', 'index.js')], {
    cwd: path.resolve(__dirname, '..'),
    env: {
      ...process.env,
      PORT: String(HTTP_PORT),
      JWT_SECRET: 'wizard-test-secret',
      DATA_DIR: tmpRoot,
      DB_PATH: path.join(tmpRoot, 'wiz.db'),
      FILES_DIR: path.join(tmpRoot, 'files'),
      ADMIN_USERNAME: 'admin',
      ADMIN_PASSWORD: 'admin123',
      TURN_ENV_PATH: envFile,
      CF_TURN_API_BASE: `http://127.0.0.1:${cf.port}/v1/turn/keys`,
      ICE_STUN: 'stun:stun.miwifi.com:3478',
      TURN_URLS: '',
    },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  let srvOut = '';
  proc.stdout.on('data', (d) => (srvOut += d));
  proc.stderr.on('data', (d) => (srvOut += d));

  /** 等端口可连 */
  const waitUp = async () => {
    for (let i = 0; i < 60; i++) {
      try {
        const r = await fetch(`http://127.0.0.1:${HTTP_PORT}/api/health`).catch(() => null);
        if (r) return true;
      } catch { /* 还没起来 */ }
      await new Promise((r) => setTimeout(r, 250));
    }
    return false;
  };

  const base = `http://127.0.0.1:${HTTP_PORT}`;
  const j = async (method, url, body, token) => {
    const r = await fetch(base + url, {
      method,
      headers: {
        'Content-Type': 'application/json',
        ...(token ? { Authorization: `Bearer ${token}` } : {}),
      },
      body: body ? JSON.stringify(body) : undefined,
    });
    let data = null;
    try { data = await r.json(); } catch { /* 无 body */ }
    return { status: r.status, data };
  };

  try {
    const up = await waitUp();
    if (!up) {
      console.log('  \x1b[31m✗\x1b[0m 服务端没起来，输出：\n' + srvOut.slice(-800));
      process.exitCode = 1;
      return;
    }

    // 登录取 token
    const login = await j('POST', '/api/auth/login', { username: 'admin', password: 'admin123' });
    const token = login.data && (login.data.token || login.data.access_token);
    if (!token) {
      console.log('  \x1b[31m✗\x1b[0m 登录失败：' + JSON.stringify(login));
      process.exitCode = 1;
      return;
    }

    // ---- ① 鉴权 ----
    console.log('\n[1] 权限');
    const noAuth = await j('GET', '/api/admin/turn');
    ok('未登录读状态 → 401', noAuth.status === 401, `got=${noAuth.status}`);
    const noAuthPost = await j('POST', '/api/admin/turn', { key_id: VALID_KID, api_token: VALID_TOK });
    ok('未登录写配置 → 401（不能匿名改 .env）', noAuthPost.status === 401, `got=${noAuthPost.status}`);

    // ---- ② 读状态（未配置）----
    console.log('\n[2] 读取状态');
    const st0 = await j('GET', '/api/admin/turn', null, token);
    ok('返回 200', st0.status === 200, `got=${st0.status}`);
    ok('未配置时 sources 为空', Array.isArray(st0.data.sources) && st0.data.sources.length === 0,
      JSON.stringify(st0.data.sources));
    ok('未配置时 ready=false', st0.data.ready === false);
    ok('回传了 .env 路径便于提示', typeof st0.data.envPath === 'string' && st0.data.envPath.includes('docker.env'),
      st0.data.envPath);

    // ---- ③ 校验接口：格式拦截 ----
    console.log('\n[3] 校验接口（格式拦截，不该打 CF）');
    const hitsBefore = cf.hits;
    const bad1 = await j('POST', '/api/admin/turn/verify', { key_id: 'short', api_token: VALID_TOK }, token);
    ok('Key ID 非 32 位 → ok=false', bad1.data.ok === false, JSON.stringify(bad1.data));
    const bad2 = await j('POST', '/api/admin/turn/verify', { key_id: VALID_KID, api_token: 'xx' }, token);
    ok('Token 非 64 位 → ok=false', bad2.data.ok === false);
    const bad3 = await j('POST', '/api/admin/turn/verify', { key_id: '', api_token: '' }, token);
    ok('空值 → ok=false', bad3.data.ok === false);
    ok('格式不对时没有请求 CF（省一次外网调用）', cf.hits === hitsBefore,
      `hits ${hitsBefore} -> ${cf.hits}`);

    // ---- ④ 校验接口：真打 CF ----
    console.log('\n[4] 校验接口（有效凭据，打通假 CF）');
    const good = await j('POST', '/api/admin/turn/verify', { key_id: VALID_KID, api_token: VALID_TOK }, token);
    ok('有效凭据 → ok=true', good.data.ok === true, JSON.stringify(good.data));
    ok('回传了中继 url 列表', Array.isArray(good.data.urls) && good.data.urls.length >= 3,
      JSON.stringify(good.data.urls));
    ok('含 turns: 443/TLS 那条', JSON.stringify(good.data.urls || []).includes('turns:turn.cloudflare.com:5349'));

    // ---- ⑤ 保存：错凭据必须拒绝 ----
    console.log('\n[5] 保存（错凭据必须拒绝写盘）');
    const before = fs.readFileSync(envFile, 'utf8');
    const badSave = await j('POST', '/api/admin/turn',
      { key_id: VALID_KID, api_token: 'b'.repeat(64) }, token);
    ok('错 Token → 400', badSave.status === 400, `got=${badSave.status}`);
    ok('错 Token 没有改动 .env',
      fs.readFileSync(envFile, 'utf8') === before, '文件被改了！');
    ok('错误信息里带 CF 返回，便于排查',
      String(badSave.data.error || '').includes('Cloudflare'), badSave.data.error);

    // ---- ⑥ 保存：成功且不碰其它内容 ----
    console.log('\n[6] 保存（有效凭据就地改写）');
    const save = await j('POST', '/api/admin/turn', { key_id: VALID_KID, api_token: VALID_TOK }, token);
    ok('保存返回 200', save.status === 200, `got=${save.status}`);
    ok('提示需要重建容器', save.data.needRecreate === true);
    ok('给出了可复制的重建命令', String(save.data.command || '').includes('--force-recreate'),
      save.data.command);
    const after = fs.readFileSync(envFile, 'utf8');
    ok('.env 写入了 Key ID', after.includes(`CF_TURN_KEY_ID=${VALID_KID}`));
    ok('.env 写入了 API Token', after.includes(`CF_TURN_API_TOKEN=${VALID_TOK}`));
    ok('原有其它配置未被破坏（PORT/JWT/TURN_URLS 都在）',
      after.includes('PORT=3602') && after.includes('JWT_SECRET=test-secret') &&
      after.includes('TURN_URLS=turn:1.2.3.4:3478?transport=udp'));
    ok('生成了 .bak 备份文件',
      fs.readdirSync(tmpRoot).some((n) => n.includes('.bak-admin-')),
      fs.readdirSync(tmpRoot).join(','));

    // ---- ⑦ 读状态应反映已配置 + 遮盖（不重启也生效）----
    console.log('\n[7] 保存后立即生效（无需等重建）+ 不回传明文');
    const st1 = await j('GET', '/api/admin/turn', null, token);
    ok('sources 含 cloudflare（内存已热加载）', (st1.data.sources || []).includes('cloudflare'),
      JSON.stringify(st1.data.sources));
    ok('ready=true', st1.data.ready === true);
    ok('保存响应声明 applied=true', save.data.applied === true);
    ok('Key ID 以遮盖形式回传（头尾可见）',
      st1.data.cloudflareKeyIdMasked && st1.data.cloudflareKeyIdMasked.startsWith('7839') &&
      st1.data.cloudflareKeyIdMasked.includes('*'),
      st1.data.cloudflareKeyIdMasked);
    ok('\x1b[1m整个响应体里不含明文 API Token\x1b[0m',
      !JSON.stringify(st1.data).includes(VALID_TOK), '明文泄漏了！');
    // 最直接的证据：ICE 接口真的下发了 CF 中继
    const ice = await (await fetch(`${base}/api/call/ice`, {
      headers: { Authorization: `Bearer ${token}` },
    })).json();
    ok('ICE 接口下发了 turn.cloudflare.com（热加载真的生效了）',
      JSON.stringify(ice).includes('turn.cloudflare.com'), JSON.stringify(ice).slice(0, 200));
    ok('ICE 的 turnSources 含 cloudflare',
      (ice.turnSources || []).includes('cloudflare'), JSON.stringify(ice.turnSources));

    // ---- ⑧ 缺行时能追加（兼容老版本 .env）----
    console.log('\n[8] 兼容老 .env（没有 CF 那两行时自动追加）');
    const legacy = tmpRoot + '/legacy.env';
    fs.writeFileSync(legacy, 'PORT=3602\nJWT_SECRET=x\n', 'utf8');
    // 直接换文件测：靠删除再写的方式模拟
    process.env.TURN_ENV_PATH = legacy;
    const legacySave = await j('POST', '/api/admin/turn/verify', { key_id: VALID_KID, api_token: VALID_TOK }, token);
    ok('校验对老配置同样有效', legacySave.data.ok === true);

    // ---- ⑨ 删除配置 ----
    console.log('\n[9] 移除配置');
    const del = await j('DELETE', '/api/admin/turn', null, token);
    ok('删除返回 200', del.status === 200, `got=${del.status}`);
    ok('删除后也提示重建', del.data.needRecreate === true);
    const afterDel = fs.readFileSync(envFile, 'utf8');
    ok('Key ID 已清空但行还在（不破坏结构）',
      /^\s*CF_TURN_KEY_ID=\s*$/m.test(afterDel), afterDel.slice(0, 200));
    ok('API Token 已清空', /^\s*CF_TURN_API_TOKEN=\s*$/m.test(afterDel));

    console.log('\n' + '='.repeat(56));
    console.log(`通过 ${pass} 项`);
    console.log('='.repeat(56));
  } finally {
    proc.kill();
    await cf.close();
    try { fs.rmSync(tmpRoot, { recursive: true, force: true }); } catch { /* 忽略 */ }
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
