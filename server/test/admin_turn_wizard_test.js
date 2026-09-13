// 管理台「音视频中继配置向导」端到端测试
//
//   node server/test/admin_turn_wizard_test.js
//
// 这套接口会**写文件**，所以必须拿临时目录测，绝不碰真配置。
// 临时目录当 DATA_DIR（turn.env 也落在它里面），用 CF_TURN_API_BASE 指向本地假 CF。
//
// 覆盖：
//   ① 读取状态：能报出未配置 / 已配置 + 遮盖值（绝不回传明文密钥）
//   ② 校验接口：格式不对直接拦下，不打 CF；有效凭据返回 ok + 中继 url
//   ③ 保存：**校验不过必须拒绝写盘**（这条最关键，防写坏生产）
//   ④ 保存成功：写进 ${DATA_DIR}/turn.env、只写白名单键、立即生效不用重建容器
//   ⑤ 缺行时能追加（兼容老配置）
//   ⑥ 删除：把两行清空但保留 key（不会把文件改乱）
//   ⑦ 权限：非管理员/未登录一律 401、403
//   ⑧ **重启后凭据仍在**（当初"看似存住了其实没存过"的事故回归用例）
//
// 起真实 HTTP 服务，走完整 Express 栈（含鉴权中间件），比只测函数可信。

const http = require('http');
const assert = require('assert');
const { spawnSync } = require('child_process');

/**
 * 在一个**全新的 Node 进程**里重新加载 config.js 并返回结果。
 *
 * 为什么必须新进程：config.js 在模块加载那一刻就读了 turn.env，
 * 同一个进程里 require 第二次只会命中缓存 —— 那样跑出来的"重启后仍在"
 * 是假通过。当初"凭据看似存住了其实从没写过"那次事故，就是因为没人
 * 真正重新加载过一次。这条用例必须贵，它才有用。
 */
function withFreshConfig(fnSrc, extraEnv) {
  const cfgPath = path.resolve(__dirname, '..', 'src', 'config.js');
  const script = [
    `const c = require(${JSON.stringify(cfgPath)});`,
    `const f = ${fnSrc};`,
    'process.stdout.write(JSON.stringify(f(c)));',
  ].join('\n');
  const p = spawnSync(process.execPath, ['-e', script], {
    cwd: path.resolve(__dirname, '..'),
    env: { ...process.env, ...extraEnv },
    encoding: 'utf8',
  });
  if (p.status !== 0) {
    throw new Error('子进程加载 config 失败：' + (p.stderr || '').slice(0, 500));
  }
  return JSON.parse(String(p.stdout || '').trim());
}
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
  // ⚠️ 一律用**假凭据**。测试只关心"格式是否正确"，用真实 KEY_ID 会把它
  //    永久留在公开仓库里（踩过：本仓库是 Public，等同自曝凭据）。
  const VALID_KID = '0123456789abcdef0123456789abcdef';
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
    // v0.8.0 起持久化文件是 ${DATA_DIR}/turn.env（共享目录），不再是 compose 的 .env
    ok('回传的持久化路径是 turn.env', typeof st0.data.envPath === 'string' &&
      st0.data.envPath.endsWith('turn.env'), st0.data.envPath);

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
    const badSave = await j('POST', '/api/admin/turn',
      { key_id: VALID_KID, api_token: 'b'.repeat(64) }, token);
    ok('错 Token → 400', badSave.status === 400, `got=${badSave.status}`);
    // 关键：写失败时**不该凭空创建**持久化文件，更不能落下半成品
    ok('错 Token 没有生成 turn.env（写盘被拒）',
      !fs.existsSync(path.join(tmpRoot, 'turn.env')), '不该存在却被创建了');
    ok('错误信息里带 CF 返回，便于排查',
      String(badSave.data.error || '').includes('Cloudflare'), badSave.data.error);

    // ---- ⑥ 保存：成功且不碰其它内容 ----
    console.log('\n[6] 保存（有效凭据就地改写）');
    const save = await j('POST', '/api/admin/turn', { key_id: VALID_KID, api_token: VALID_TOK }, token);
    ok('保存返回 200', save.status === 200, `got=${save.status}`);
    // v0.8.0 起：写共享目录的 turn.env，改完立即热加载，**不需要重建容器**。
    // 以前这一节断言 needRecreate=true 并给出 --force-recreate 命令，那是老行为。
    ok('保存后不需要重建容器', save.data.needRecreate === false, save.data.needRecreate);

    const turnEnvFile = path.join(tmpRoot, 'turn.env');
    ok('持久化文件确实建出来了', fs.existsSync(turnEnvFile), turnEnvFile);
    const after = fs.readFileSync(turnEnvFile, 'utf8');
    ok('turn.env 写入了 Key ID', after.includes(`CF_TURN_KEY_ID=${VALID_KID}`), after);
    ok('turn.env 写入了 API Token', after.includes(`CF_TURN_API_TOKEN=${VALID_TOK}`), after);
    // 只有白名单里的键能进这个文件，别的一概不该被写进来
    ok('没有夹杂其它环境变量（白名单生效）',
      Object.keys(after.split(/\r?\n/).filter((l) => l.includes('='))
        .reduce((a, l) => ((a[l.slice(0, l.indexOf('='))] = 1), a), {}))
        .every((k) => ['TURN_URLS', 'TURN_USERNAME', 'TURN_CREDENTIAL',
          'CF_TURN_KEY_ID', 'CF_TURN_API_TOKEN'].includes(k)), after);

    // ---- ⑥b 杀掉进程重开，凭据必须还在（当初的事故就是"看似存住了其实没存"）----
    console.log('\n[6b] 模拟容器重启后凭据仍在（回归用例）');
    const restarted = withFreshConfig(
      '(c) => ({ sources: c.turnInfo().sources, ready: c.turnInfo().sources.length > 0 })',
      { DATA_DIR: tmpRoot },
    );
    ok('重启后 CF 中继仍然在线', (restarted.sources || []).includes('cloudflare'),
      JSON.stringify(restarted));

    // ---- ⑦ 读状态应反映已配置 + 遮盖（不重启也生效）----
    console.log('\n[7] 保存后立即生效（无需等重建）+ 不回传明文');
    const st1 = await j('GET', '/api/admin/turn', null, token);
    ok('sources 含 cloudflare（内存已热加载）', (st1.data.sources || []).includes('cloudflare'),
      JSON.stringify(st1.data.sources));
    ok('ready=true', st1.data.ready === true);
    ok('保存响应声明 applied=true', save.data.applied === true);
    // ⚠️ 期望值**必须从 VALID_KID 推导**。曾经这里硬写成某个真实 Key ID 的前
    // 四位，等于把生产凭据的片段永久留在了公开仓库里 —— 用变量推导就没有
    // 这个风险，换任何一组假凭据测试都照样成立。
    const expectHead = VALID_KID.slice(0, 4);
    const expectTail = VALID_KID.slice(-4);
    ok('Key ID 以遮盖形式回传（头尾可见）',
      st1.data.cloudflareKeyIdMasked === `${expectHead}************${expectTail}`,
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

    // ---- ⑧ 缺行时能追加（兼容老版本配置）----
    console.log('\n[8] 兼容老配置（turn.env 只写了别的中继键时也能追加）');
    fs.writeFileSync(turnEnvFile, 'TURN_URLS=turn:1.2.3.4:3478?transport=udp\n', 'utf8');
    const legacySave = await j('POST', '/api/admin/turn',
      { key_id: VALID_KID, api_token: VALID_TOK }, token);
    ok('在已有中继配置上追加 CF 凭据成功', legacySave.status === 200, `got=${legacySave.status}`);
    const legacyAfter = fs.readFileSync(turnEnvFile, 'utf8');
    ok('原有 TURN_URLS 被保留', legacyAfter.includes('turn:1.2.3.4:3478'), legacyAfter);
    ok('CF 凭据被追加进来', legacyAfter.includes(`CF_TURN_KEY_ID=${VALID_KID}`), legacyAfter);

    // ---- ⑨ 删除配置 ----
    console.log('\n[9] 移除配置');
    const del = await j('DELETE', '/api/admin/turn', null, token);
    ok('删除返回 200', del.status === 200, `got=${del.status}`);
    ok('删除后不需要重建（立即抹除）', del.data.needRecreate === false, del.data.needRecreate);
    const afterDel = fs.readFileSync(path.join(tmpRoot, 'turn.env'), 'utf8');
    ok('turn.env 里已不含 CF 凭据',
      !afterDel.includes(VALID_KID) && !afterDel.includes(VALID_TOK), afterDel.slice(0, 200));
    // DELETE 响应里本来就没有 sources 字段，靠"字段缺失"来断言等于假通过 ——
    // 必须真去查一次状态接口。
    const st2 = await j('GET', '/api/admin/turn', null, token);
    ok('删除后状态回到未配置', (st2.data.sources || []).length === 0,
      JSON.stringify(st2.data.sources));
    ok('删除后 ready=false', st2.data.ready === false, st2.data.ready);

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
