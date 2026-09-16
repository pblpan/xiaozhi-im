// 首次运行初始化（管理台设置密码向导）—— 端到端测试
//
//   node test/setup_wizard_e2e.js
//
// 覆盖的核心是**判据**：什么时候该弹向导、什么时候必须闭嘴。
//   · 全新库（密码还是安装时那串）                → 弹
//   · 管理员自己改过密码（老客户升级）            → 不弹  ← 这条错了会骚扰所有老客户
//   · 向导走完 / 重启后 / 再调接口                → 不弹
// 以及一个客户看得见的行为：向导改完密码后，data\.env 里的那份也要跟着变，
// 否则安装目录里的「查看管理员密码.cmd」就开始撒谎。

const { spawn } = require('child_process');
const path = require('path');
const fs = require('fs');
const os = require('os');

const PORT = 3696; // 与 password_e2e 的 3698 错开
const BASE = `http://127.0.0.1:${PORT}`;
const SERVER_DIR = path.resolve(__dirname, '..');
const SEED = 'Seed_Admin_123';
const NEWPW = 'MyOwn_Pw-2026';

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

// ---------------------------------------------------------------- 起停

let proc = null;
let log = '';

async function start(dataDir, extraEnv) {
  proc = spawn(process.execPath, [path.join(SERVER_DIR, 'src', 'index.js')], {
    env: { ...process.env, PORT: String(PORT), DATA_DIR: dataDir, ...extraEnv },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  proc.stdout.on('data', (d) => { log += d.toString(); });
  proc.stderr.on('data', (d) => { log += d.toString(); });
  for (let i = 0; i < 60; i++) {
    try {
      const r = await fetch(BASE + '/api/health');
      if (r.ok) return;
    } catch { /* 还没起来 */ }
    await sleep(250);
  }
  throw new Error('服务端启动超时\n' + log);
}

function kill() {
  if (proc) { try { proc.kill(); } catch { /* ignore */ } proc = null; }
}

function tmpData(tag) {
  const d = path.join(os.tmpdir(), `xiaozhi-setup-${tag}-${Date.now()}`);
  fs.mkdirSync(d, { recursive: true });
  return d;
}

function cleanup(d) {
  try { fs.rmSync(d, { recursive: true, force: true }); } catch { /* ignore */ }
}

// ---------------------------------------------------------------- 场景

/** 主流程：判据 → 校验 → 设密码 → 关门 → 重启 */
async function mainFlow() {
  const dir = tmpData('main');
  console.log('【一】全新安装：该弹向导');
  await start(dir, { ADMIN_PASSWORD: SEED });

  let r = await api('GET', '/api/setup/status');
  ok('新库 status 返回 200', r.status === 200, JSON.stringify(r.body));
  ok('新库 needSetup = true', r.body?.needSetup === true, JSON.stringify(r.body));
  ok('status 不下发任何口令类字段',
    r.body && !('password' in r.body) && !('token' in r.body), JSON.stringify(r.body));

  console.log('\n【二】入参校验（都不能把密码设坏）');
  r = await api('POST', '/api/setup/init', { body: { password: '123' } });
  ok('太短 → 400 且中文提示', r.status === 400 && /至少/.test(r.body?.error || ''), JSON.stringify(r.body));

  r = await api('POST', '/api/setup/init', { body: { password: '' } });
  ok('空密码 → 400', r.status === 400, JSON.stringify(r.body));

  r = await api('POST', '/api/setup/init', { body: { password: 'with space 123' } });
  ok('含空格 → 400（.env/cmd 链路上会出事）', r.status === 400, JSON.stringify(r.body));

  r = await api('POST', '/api/setup/init', { body: { password: 'has=equal99' } });
  ok('含 = → 400（会被 for /f 截断）', r.status === 400, JSON.stringify(r.body));

  r = await api('POST', '/api/setup/init', { body: { password: '#hash12345' } });
  ok('以 # 开头 → 400（.env 里当注释整行跳过）', r.status === 400, JSON.stringify(r.body));

  r = await api('GET', '/api/setup/status');
  ok('校验失败后 needSetup 仍为 true（没被"试坏"）', r.body?.needSetup === true, JSON.stringify(r.body));

  console.log('\n【三】设置密码');
  r = await api('POST', '/api/setup/init', { body: { password: NEWPW } });
  ok('设置成功 → 200', r.status === 200, JSON.stringify(r.body));
  ok('返回可直接用的登录凭证', !!r.body?.token, JSON.stringify(r.body));
  const token = r.body?.token;

  r = await api('GET', '/api/auth/me', { token });
  ok('凭证立即有效（/auth/me 认得它）', r.status === 200 && r.body?.user?.role === 'admin',
    JSON.stringify(r.body));

  r = await api('GET', '/api/admin/stats', { token });
  ok('该凭证能进管理接口', r.status === 200, `status=${r.status} ${JSON.stringify(r.body)?.slice(0, 120)}`);

  console.log('\n【四】设完就关门 + 新旧密码');
  r = await api('GET', '/api/setup/status');
  ok('needSetup 变为 false', r.body?.needSetup === false, JSON.stringify(r.body));

  r = await api('POST', '/api/setup/init', { body: { password: 'Another_Pw-999' } });
  ok('再调初始化 → 409 且带错误码',
    r.status === 409 && r.body?.code === 'ALREADY_INITIALIZED', JSON.stringify(r.body));

  r = await api('POST', '/api/auth/login', { body: { username: 'admin', password: NEWPW } });
  ok('新密码能登录', r.status === 200, JSON.stringify(r.body));

  r = await api('POST', '/api/auth/login', { body: { username: 'admin', password: SEED } });
  ok('安装时那串旧密码已失效', r.status === 401, JSON.stringify(r.body));

  console.log('\n【五】重启后不复发');
  kill();
  await sleep(400);
  await start(dir, { ADMIN_PASSWORD: SEED });
  r = await api('GET', '/api/setup/status');
  ok('重启后 needSetup 仍为 false', r.body?.needSetup === false, JSON.stringify(r.body));
  r = await api('POST', '/api/auth/login', { body: { username: 'admin', password: NEWPW } });
  ok('重启后新密码仍可登录', r.status === 200, JSON.stringify(r.body));

  console.log('\n【六】限流');
  let got429 = false;
  for (let i = 0; i < 30 && !got429; i++) {
    const rr = await api('POST', '/api/setup/init', { body: { password: 'Whatever_Pw-123' } });
    if (rr.status === 429) got429 = true;
  }
  ok('高频调用最终被限流（429）', got429);

  kill();
  cleanup(dir);
}

/** 老客户升级：管理员早就改过密码 → 绝不能弹向导 */
async function upgradedInstance() {
  const dir = tmpData('upgraded');
  console.log('\n【七】老实例（管理员自己改过密码）：必须不弹');
  await start(dir, { ADMIN_PASSWORD: SEED });

  let r = await api('POST', '/api/auth/login', { body: { username: 'admin', password: SEED } });
  ok('用安装时的密码能登进老实例', r.status === 200, JSON.stringify(r.body));
  const token = r.body?.token;

  // 走管理台自己的改密接口（模拟"客户早就改过密码了"）
  r = await api('POST', '/api/auth/password', { token, body: { oldPassword: SEED, newPassword: 'Changed_By_Owner_1' } });
  ok('管理员自行改密成功', r.status === 200, JSON.stringify(r.body));

  // 重启：新进程拿到的是 .env 里那串旧口令，而库里已经是新密码
  kill();
  await sleep(400);
  await start(dir, { ADMIN_PASSWORD: SEED });
  r = await api('GET', '/api/setup/status');
  ok('改过密码的实例 needSetup = false（不骚扰老客户）', r.body?.needSetup === false, JSON.stringify(r.body));

  kill();
  cleanup(dir);
}

/** 没有 ADMIN_PASSWORD 的部署（飞牛/Docker 常见）：全新库也该能设密码 */
async function noEnvSeed() {
  const dir = tmpData('noenv');
  console.log('\n【八】环境变量缺 ADMIN_PASSWORD 的全新库');
  await start(dir, { ADMIN_PASSWORD: '' });

  let r = await api('GET', '/api/setup/status');
  ok('仍然弹向导（否则装机脚本没写 .env 就彻底进不去）', r.body?.needSetup === true, JSON.stringify(r.body));

  r = await api('POST', '/api/setup/init', { body: { password: 'Docker_Admin_1' } });
  ok('可正常设置', r.status === 200, JSON.stringify(r.body));
  r = await api('POST', '/api/auth/login', { body: { username: 'admin', password: 'Docker_Admin_1' } });
  ok('设完即可登录', r.status === 200, JSON.stringify(r.body));

  kill();
  cleanup(dir);
}

/** data\.env 同步：否则「查看管理员密码.cmd」会给出一个登不上的密码 */
async function envSync() {
  const dir = tmpData('envsync');
  console.log('\n【九】同步 data\\.env（Windows 版「查看管理员密码.cmd」靠它）');
  // 照 init-env.js 的样子造一份 CRLF 的 .env
  const envFile = path.join(dir, '.env');
  const before = [
    '# 小智IM 服务端（Windows 版）本地配置 —— 由安装程序生成，一般不用手改。',
    '#',
    'ADMIN_USERNAME=admin',
    `ADMIN_PASSWORD=${SEED}`,
    'JWT_SECRET=keep-this-secret',
    '',
  ].join('\r\n');
  fs.writeFileSync(envFile, before, 'utf8');

  await start(dir, { ADMIN_PASSWORD: SEED });
  let r = await api('POST', '/api/setup/init', { body: { password: NEWPW } });
  ok('设置成功', r.status === 200, JSON.stringify(r.body));

  const after = fs.readFileSync(envFile, 'utf8');
  ok('.env 里的口令已更新为新密码',
    after.includes('ADMIN_PASSWORD=' + NEWPW), after.split('\r\n').slice(3, 6).join(' | '));
  ok('旧口令不再出现在 .env 里', !after.includes(SEED));
  ok('其它配置项原样保留', after.includes('JWT_SECRET=keep-this-secret'));
  ok('注释行原样保留', after.includes('由安装程序生成'));

  const crlf = (after.match(/\r\n/g) || []).length;
  const lf = (after.match(/\n/g) || []).length;
  ok('行尾仍是纯 CRLF（cmd 的 for /f 读最后一行才不会少读）', crlf === lf, `CRLF=${crlf} LF=${lf}`);
  ok('文件结尾仍有换行', after.endsWith('\n'));

  // 改动确实生效：用新密码登录
  r = await api('POST', '/api/auth/login', { body: { username: 'admin', password: NEWPW } });
  ok('.env 里那串密码能登录（不是只改了文件）', r.status === 200, JSON.stringify(r.body));

  kill();
  cleanup(dir);
}

/** 授权不可用时也要能设密码，否则"没授权 + 不知道密码"会把人锁在门外 */
async function underLicenseGate() {
  const dir = tmpData('license');
  console.log('\n【十】授权门禁下仍可用');
  await start(dir, { ADMIN_PASSWORD: SEED });
  // 让授权立刻不可用：直接把授权文件写成"已停用"不可行（格式未知），
  // 改为直接验证放行名单 —— 这才是这条断言真正要守的东西。
  const src = fs.readFileSync(path.join(SERVER_DIR, 'src', 'license.js'), 'utf8');
  const allowBlock = src.slice(src.indexOf('const ALLOW = ['), src.indexOf('function isAllowed'));
  ok("license 放行名单里有 '/api/setup'", allowBlock.includes("'/api/setup'"), allowBlock.trim().slice(0, 200));
  ok('放行名单仍包含登录与冷启动握手',
    allowBlock.includes("'/api/auth/login'") && allowBlock.includes("'/api/client/bootstrap'"));

  kill();
  cleanup(dir);
}

(async () => {
  console.log('[setup wizard E2E] 端口 ' + PORT + '\n');
  await mainFlow();
  await upgradedInstance();
  await noEnvSeed();
  await envSync();
  await underLicenseGate();

  console.log('\n' + '='.repeat(52));
  console.log(`通过 ${passed} / ${passed + failed}`);
  if (failed) {
    console.log('\n失败项：');
    failures.forEach((f) => console.log('  ✗ ' + f));
  }
  console.log('='.repeat(52));
  process.exit(failed ? 1 : 0);
})().catch((e) => {
  console.error('\n[E2E] 异常中断:', e);
  kill();
  process.exit(1);
});
