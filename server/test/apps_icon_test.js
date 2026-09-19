// 内置应用图标一致性测试
//
//   node server/test/apps_icon_test.js
//
// ── 为什么要单独钉这一个 ────────────────────────────────────────
// 内置应用的图标名要在**两个地方**同时存在，少一处就静默退化成通用图标：
//   · 服务端 appmodules.js 的 ICONS 白名单（太顺眼的图标名会被 sanitize 掉）
//   · 客户端 widgets/module_renderer.dart 的 kModuleIcons（认不出就 fallback）
// 退化**不报错**，只是图标变丑 —— 属于"错了没人发现"的那类。
// 历史上这条约束只写在注释里（"必须落在…里"），没有任何东西拦着。
//
// ── 这个测试怎么保证自己不是装饰品 ──────────────────────────────
//   ① 正向：每个内置应用的 icon 必须两个表里都有
//   ② 反向断言：一个凭空造的图标名必须**两边都查不到**（证明判据有鉴别力）
//   ③ 变异测试：把某个应用的 icon 换成假名，用同一套判据必须**报错**
//   ④ 抠不到源码就红 —— 防"正则失配 → 判据恒真"这种最阴的假绿

const assert = require('assert');
const fs = require('fs');
const path = require('path');

const { BUILTIN_APPS } = require('../src/apps');
const { ICONS } = require('../src/appmodules');

let failed = 0;
function check(cond, msg) {
  console.log((cond ? '  OK   ' : '  FAIL ') + msg);
  if (!cond) failed++;
}

/** 从客户端 Dart 源码里抠出 kModuleIcons 的 key 集合。抠不到返回 null（= 必须报红）。 */
function clientIcons() {
  const p = path.join(__dirname, '..', '..', 'client', 'lib', 'widgets', 'module_renderer.dart');
  let src;
  try {
    src = fs.readFileSync(p, 'utf8');
  } catch (_) {
    return null;
  }
  const block = src.match(/kModuleIcons\s*=\s*\{([\s\S]*?)\n\};/);
  if (!block) return null;
  const keys = [...block[1].matchAll(/'([a-z0-9_]+)'\s*:/g)].map((m) => m[1]);
  return keys.length ? new Set(keys) : null;
}

console.log('内置应用 %d 个，服务端图标白名单 %d 个', BUILTIN_APPS.length, ICONS.length);

const client = clientIcons();
check(client !== null, '能从 module_renderer.dart 抠出 kModuleIcons（抠不到必须报红，不能静默通过）');
if (client) console.log('       客户端图标 %d 个', client.size);

// ── ① 正向：每个内置应用的图标两边都得有
for (const a of BUILTIN_APPS) {
  check(ICONS.includes(a.icon), `服务端白名单含 '${a.icon}'（${a.id} / ${a.title}）`);
  if (client) {
    check(client.has(a.icon), `客户端 kModuleIcons 含 '${a.icon}'（${a.id} / ${a.title}）`);
  }
}

// ── ② 反向断言：假图标名必须两边都查不到
const BOGUS = 'no_such_icon_zzz';
check(!ICONS.includes(BOGUS), `反向：'${BOGUS}' 不在服务端白名单`);
if (client) check(!client.has(BOGUS), `反向：'${BOGUS}' 不在客户端图标表`);

// ── ③ 变异测试：把 icon 换成假名，同一套判据必须能抓出来
const mutated = BUILTIN_APPS.map((a) => (a.id === 'stocktake' ? { ...a, icon: BOGUS } : a));
const caughtByServer = mutated.some((a) => !ICONS.includes(a.icon));
const caughtByClient = client ? mutated.some((a) => !client.has(a.icon)) : true;
check(caughtByServer, '变异：把 icon 改成假名后，服务端判据报错（说明判据不是恒真）');
check(caughtByClient, '变异：把 icon 改成假名后，客户端判据报错');

// ── ④ 标题不能被改回「盘点」——「盘点」这个名字留给真正的盘点模块
const st = BUILTIN_APPS.find((a) => a.id === 'stocktake');
check(!!st, "存在 id='stocktake' 的内置应用");
if (st) {
  check(st.title === '扫码枪', `stocktake 显示名是「扫码枪」（实际「${st.title}」）`);
  check(!/盘点/.test(st.title), 'stocktake 显示名里不含「盘点」（把名字让给盘点模块）');
}

console.log('\n结果:', failed === 0 ? 'ALL PASS' : `FAILED ${failed}`);
process.exit(failed === 0 ? 0 : 1);
