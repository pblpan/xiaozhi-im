// 验证线上容器里「部署向导」这条路真的能跑 —— 不是看 401，而是把模块**真加载一遍**。
//
//   python deploy/_exec_in_container.py _probe_ssh2_load.js
//
// 为什么必须真 require 而不是猜：
//   index.js:139 `app.use('/api/admin/deploy', require('./routes/deploy_wizard'))`
//   是启动时同步加载，而 deploy_wizard → deploylib 顶层就 `require('ssh2')`。
//   只要容器里缺 ssh2，这条 require 链一断，**整个服务端起不来**。
//   另外 npm ci 在 CI 上刚爆过「ssh2 不在 lock 里」，所以容器是不是真有它值得坐实。
//
// ⚠️ 本脚本必须"必自杀"：容器是无 kill/ps 的 slim 镜像，
//   一旦进程残留并持有 SQLite 连接，node:sqlite 会忙等把 1 核打满（2026-10-04 踩过）。
'use strict';

// 硬看门狗：无论卡在哪一步，8 秒后自己走人
const WATCHDOG = setTimeout(() => {
  process.stdout.write('[watchdog] 超时，强制退出\n');
  process.exit(9);
}, 8000);
WATCHDOG.unref && WATCHDOG.unref();

const say = (s) => process.stdout.write(s + '\n');
let bad = 0;
const ok = (n, c, d) => { c ? say('  ✓ ' + n + (d ? ' — ' + d : '')) : (bad++, say('  ✗ ' + n + (d ? ' — ' + d : ''))); };

say('=== 部署向导依赖链（容器内 /app/src）===');

/* ① ssh2 模块本身（按 /app/src 的解析路径找，不是 /tmp） */
try {
  const p = require.resolve('ssh2', { paths: ['/app/src', '/app'] });
  ok('ssh2 模块可解析', true, p);
  // 注意：必须用 path 解析到 ssh2 目录再读 package.json —— 直接
  // require('ssh2/package.json') 会按 /tmp 往上找，永远找不到（第一版就报了这个假红）。
  const pathmod = require('path');
  const v = JSON.parse(require('fs').readFileSync(pathmod.join(pathmod.dirname(p), '..', 'package.json'), 'utf8')).version;
  ok('ssh2 版本', true, v + '（package.json 要求 ^1.17.0）');
} catch (e) {
  ok('ssh2 模块可解析', false, e.message);
}

/* ② deploylib 真加载（顶层 require('ssh2') + 导出 sshExec/tcpProbe） */
try {
  const lib = require('/app/src/deploylib.js');
  const fns = ['sshExec', 'tcpProbe', 'mergeTurnUrls'].filter((k) => typeof lib[k] === 'function');
  ok('deploylib.js 加载成功', true, '导出: ' + fns.join(', '));
  ok('导出函数齐', fns.length === 3, fns.join(', '));
} catch (e) {
  ok('deploylib.js 加载成功', false, e.message);
}

/* ③ 路由模块真加载（这才是 index.js 启动时走的那一步） */
try {
  const r = require('/app/src/routes/deploy_wizard.js');
  ok('routes/deploy_wizard.js 加载成功', true, 'type=' + typeof r);
} catch (e) {
  ok('routes/deploy_wizard.js 加载成功', false, e.message);
}

/* ④ 反面对照：文件存储自定义那块的配置文件也顺带确认在（同批热更的） */
try {
  const cfg = require('/app/src/config.js');
  ok('config.js 有 FILES_DIR', !!cfg.FILES_DIR, 'FILES_DIR=' + cfg.FILES_DIR);
  ok('config.js 导出 writePathsEnv', typeof cfg.writePathsEnv === 'function');
} catch (e) {
  ok('config.js 加载成功', false, e.message);
}

say(bad === 0 ? '\n结论：部署向导依赖链完整（' + '4/4 组）' : '\n结论：有 ' + bad + ' 项不通过');
process.exit(0);
