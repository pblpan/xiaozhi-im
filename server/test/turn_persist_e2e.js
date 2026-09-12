/**
 * 中继配置持久化回归测试（v0.8.0 修复）
 *
 * 背景（真事，生产上跨网通话突然打不通）：
 *   管理台向导保存 CF 凭据时，写入路径是 `${DATA_DIR}/../docker/.env`。
 *   容器里 DATA_DIR=/data，于是拼成 `/docker/.env` —— 既不存在也没挂载。
 *   结果：内存里生效（探针看到 cloudflare 已启用），
 *        **容器一重启凭据全丢**，而 .env 从没被写过，永远恢复不了。
 *
 * 这个测试锁死两件事：
 *   ① 凭据写进去以后，**重新加载模块**（模拟容器重启）仍然生效；
 *   ② 配置文件落在 DATA_DIR 里（共享目录），而不是容器可写层的某个角落。
 *
 * 用子进程起独立进程验证 ①，避免 require 缓存在同一进程里自欺欺人。
 */
const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFileSync } = require('child_process');

const CFG = path.resolve(__dirname, '..', 'src', 'config.js');

let pass = 0;
let fail = 0;

function ok(name, cond, extra = '') {
  if (cond) {
    pass++;
    console.log('  ✓ ' + name);
  } else {
    fail++;
    console.log('  ✗ ' + name + (extra ? '  → ' + extra : ''));
  }
}

/** 在一个干净的临时 DATA_DIR 下加载 config，返回 turnInfo 快照 */
function loadIn(dir, env = {}) {
  const script = `
    const c = require(${JSON.stringify(CFG)});
    const t = c.turnInfo();
    console.log(JSON.stringify({
      file: c.turnEnvPath(),
      cfEnabled: c.CF_TURN_ENABLED(),
      sources: t.sources,
      urls: t.staticTurnUrls,
      username: c.TURN_USERNAME,
    }));
  `;
  const out = execFileSync(process.execPath, ['-e', script], {
    env: { ...process.env, DATA_DIR: dir, ...env },
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  return JSON.parse(out.trim().split('\n').pop());
}

function main() {
  console.log('=' * 0 + '='.repeat(56));
  console.log('中继配置持久化测试');
  console.log('='.repeat(56));

  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'xz-turn-'));

  // ---- ① 初始化：什么都没配 ----
  console.log('\n[1] 初始状态（未配置任何中继）');
  let s = loadIn(dir);
  ok('turn.env 落在 DATA_DIR 里', s.file === path.join(dir, 'turn.env'), s.file);
  ok('未配置时 CF 关闭', s.cfEnabled === false);
  ok('未配置时没有中继来源', Array.isArray(s.sources) && s.sources.length === 0,
    JSON.stringify(s.sources));

  // ---- ② 环境变量仍要能用（老部署方式不能废）----
  console.log('\n[2] 环境变量方式仍然生效（向后兼容）');
  s = loadIn(dir, { TURN_URLS: 'turn:1.2.3.4:3478?transport=udp' });
  ok('TURN_URLS 从环境变量读出', s.urls.length === 1 && s.urls[0].includes('1.2.3.4'),
    JSON.stringify(s.urls));
  ok('静态中继进入 sources', s.sources.includes('static'), JSON.stringify(s.sources));

  // ---- ③ 写 turn.env 后，重启（重新加载）仍生效 —— 这正是以前丢失的场景 ----
  console.log('\n[3] 写入后"重启"仍生效（关键回归点）');
  const writeScript = `
    const c = require(${JSON.stringify(CFG)});
    c.writeTurnEnv({
      CF_TURN_KEY_ID: 'test-key-id',
      CF_TURN_API_TOKEN: 'test-api-token',
      TURN_URLS: 'turn:9.9.9.9:3478?transport=udp',
      TURN_USERNAME: 'xz-user',
    });
  `;
  execFileSync(process.execPath, ['-e', writeScript], {
    env: { ...process.env, DATA_DIR: dir },
    stdio: ['ignore', 'ignore', 'pipe'],
  });
  ok('turn.env 已生成', fs.existsSync(path.join(dir, 'turn.env')));

  // 模拟容器重启：新进程、只带环境变量（不含刚才写的值）
  s = loadIn(dir);
  ok('重启后 CF 凭据仍在（以前这里会丢）', s.cfEnabled === true,
    'cfEnabled=' + s.cfEnabled);
  ok('重启后 cloudflare 进 sources', s.sources.includes('cloudflare'),
    JSON.stringify(s.sources));
  ok('重启后 TURN_URLS 仍是写进去的那个', s.urls.length === 1 && s.urls[0].includes('9.9.9.9'),
    JSON.stringify(s.urls));
  ok('重启后 TURN_USERNAME 仍是写进去的', s.username === 'xz-user', s.username);
  ok('turn.env 优先于环境变量（文件 9.9.9.9 覆盖 env 1.2.3.4）',
    !s.urls.join().includes('1.2.3.4'), JSON.stringify(s.urls));

  // ---- ④ 敏感值不能被别的东西污染 ----
  console.log('\n[4] 白名单：不认识的键写不进去');
  const evilScript = `
    const c = require(${JSON.stringify(CFG)});
    c.writeTurnEnv({ JWT_SECRET: 'hacked', CF_TURN_KEY_ID: 'kept' });
  `;
  execFileSync(process.execPath, ['-e', evilScript], {
    env: { ...process.env, DATA_DIR: dir },
    stdio: ['ignore', 'ignore', 'pipe'],
  });
  const text = fs.readFileSync(path.join(dir, 'turn.env'), 'utf8');
  ok('JWT_SECRET 没被写进 turn.env', !text.includes('hacked'), text.slice(0, 200));
  ok('合法的 CF_TURN_KEY_ID 写进去了', text.includes('CF_TURN_KEY_ID=kept'), text.slice(0, 200));

  // ---- ⑤ 清除 ----
  console.log('\n[5] 清除凭据');
  const clearScript = `
    const c = require(${JSON.stringify(CFG)});
    c.clearTurnCredentials();
    console.log('cfAfterClear=' + c.CF_TURN_ENABLED());
  `;
  const co = execFileSync(process.execPath, ['-e', clearScript], {
    env: { ...process.env, DATA_DIR: dir },
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  ok('清除后 CF 立即关闭', co.includes('cfAfterClear=false'), co.trim());
  s = loadIn(dir);
  ok('清除后重启 CF 仍是关的（不会复活）', s.cfEnabled === false);

  fs.rmSync(dir, { recursive: true, force: true });

  console.log('\n' + '='.repeat(56));
  console.log(`结果: ${pass} 通过, ${fail} 失败`);
  console.log('='.repeat(56));
  process.exit(fail ? 1 : 0);
}

main();
