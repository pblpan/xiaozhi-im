// 「建目录不许用 recursive」回归测试
//
//   node server/test/files_dir_guard_test.js
//
// ── 为什么要单独钉这一个 ────────────────────────────────────────
// 2026-10-05 线上事故：管理台「文件存储」填 `/proc/xz_nope/files`，
// `fs.mkdirSync(p, { recursive: true })` 在 **procfs 上死循环**：
//     mkdir('/proc/xz_nope')     → ENOENT
//     → 往上建父目录 '/proc'      → EEXIST（Node 当成"建成了"）
//     → 回头再建子目录            → 又 ENOENT → 无限循环
// 服务端是**单线程 + 同步 fs**，循环一进去事件循环被彻底占满：
// 容器 CPU 97%、全站 HTTP 超时（TCP 还连得上，最容易被误判成"网络问题"），
// 只能重启容器。实测复现脚本：deploy/_probe_mkdir_loop.js（子进程被 SIGKILL 收场）。
//
// 另一头同样重要：**写坏的路径不能把服务端拖到起不来**。
// paths.env 是持久的 —— 里面存一个已经拔掉的 U 盘路径，如果启动时硬失败，
// 就是"服务端永远起不来，用户还不知道为啥"。所以 config.ensureFilesDir()
// 必须回落到默认目录（deploy/_test_mkdirs_safe.js 的 boot 模式验这条）。
//
// ── 这个测试怎么保证自己不是装饰品 ──────────────────────────────
//   ① 正向：正常多级路径必须能建出来（证明 mkdirsSafe 不是"永远失败"）
//   ② 反向：procfs 这类建不了的地方必须**快速失败**，且绝不能卡住
//   ③ 源码护栏：admin.js 的 validateFilesDir 必须走 config.mkdirsSafe，
//      不许自己再写一个 recursive mkdir（否则这个测试就是空的）
//   ④ 抠不到源码就红 —— 防"正则失配 → 判据恒真"这种最阴的假绿
//
// ⚠️ 为什么 ② 在 Windows 上跳过：这台机器没有 procfs。跳过是**显式打出来**的，
//    不静默 —— 静默的跳过等于没有这条测试。

const assert = require('assert');
const fs = require('fs');
const os = require('os');
const path = require('path');

let failed = 0;
function check(cond, msg) {
  console.log((cond ? '  OK   ' : '  FAIL ') + msg);
  if (!cond) failed++;
}

// 用独立的数据目录，别踩到别的测试
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'xzfilesdir-'));
process.env.DATA_DIR = TMP;
const config = require('../src/config');

function cleanup() {
  try { fs.rmSync(TMP, { recursive: true, force: true }); } catch { /* ignore */ }
}

/* ① 正向：正常路径能建出来 */
console.log('① 正向');
{
  const target = path.join(TMP, 'a', 'b', 'c');
  const t0 = Date.now();
  const r = config.mkdirsSafe(target);
  check(!!(r && r.ok), '多级路径 mkdirsSafe 返回 ok：' + JSON.stringify(r));
  check(fs.existsSync(target), '目录真的建出来了：' + target);
  check(Date.now() - t0 < 2000, '没拖时间（' + (Date.now() - t0) + 'ms）');

  // 幂等：再建一次不能报错（磁盘上/管理台重复提交都很常见）
  const again = config.mkdirsSafe(target);
  check(!!(again && again.ok), '重复调用幂等（EEXIST 视为成功）');
}

/* ② 反向：procfs 必须快速失败，绝不允许卡住 */
console.log('② 反向（procfs）');
if (process.platform !== 'linux') {
  console.log('  跳过  本机不是 Linux（' + process.platform + '），没有 procfs；CI 的 ubuntu runner 上会真跑');
} else {
  const t0 = Date.now();
  const r = config.mkdirsSafe('/proc/xz_nope/files');
  const ms = Date.now() - t0;
  check(!r.ok, 'procfs 路径被拒绝：' + JSON.stringify(r));
  check(ms < 2000, '而且是**快速**拒绝，没有死循环（' + ms + 'ms）');
  check(!fs.existsSync('/proc/xz_nope'), '没有在 /proc 里留下任何东西');
}

/* ③ 源码护栏：不许绕过 mkdirsSafe */
console.log('③ 源码护栏');
{
  const adminSrc = fs.readFileSync(path.join(__dirname, '..', 'src', 'routes', 'admin.js'), 'utf8');
  // 抠出 validateFilesDir 的函数体（大括号配平）
  const start = adminSrc.indexOf('function validateFilesDir(');
  let body = null;
  if (start >= 0) {
    let i = adminSrc.indexOf('{', start);
    let depth = 0;
    for (let j = i; j < adminSrc.length; j++) {
      if (adminSrc[j] === '{') depth++;
      else if (adminSrc[j] === '}') { depth--; if (depth === 0) { body = adminSrc.slice(i, j + 1); break; } }
    }
    if (!body) console.log('  (提示) validateFilesDir 的函数体没配平，下面的护栏会直接判红');
  }
  check(start >= 0, '在 admin.js 里找到了 validateFilesDir（抠不到就说明改了名 → 需要同步改这个测试）');
  check(!!body, '抠出了它的函数体（正则/配平失配会让判据恒真，所以单独断言）');
  // 🔴 必须先把注释剥掉再判。第一版没剥，结果 `body.includes('mkdirsSafe')`
  //    被函数里那句说明注释满足了 —— 把调用真改成 recursive 写法后这条**照样 OK**，
  //    只剩另一条在红。注释满足断言是这类"源码护栏"最典型的假绿。
  const code = (body || '')
    .replace(/\/\*[\s\S]*?\*\//g, '')
    .replace(/\/\/[^\n]*/g, '');
  check(/config\.mkdirsSafe\s*\(/.test(code), 'validateFilesDir 真的**调用了** config.mkdirsSafe（剥掉注释后判）');
  check(!/\{[\s]*recursive:\s*true/.test(code), 'validateFilesDir 里没有 recursive mkdir（这正是事故写法）');
}

/* ④ 顺带：config 得把这两个函数导出，别处才能复用 */
console.log('④ 导出面');
check(typeof config.mkdirsSafe === 'function', 'config.mkdirsSafe 已导出');
check(typeof config.ensureFilesDir === 'function', 'config.ensureFilesDir 已导出');

cleanup();
console.log(failed === 0 ? '\n全部通过' : '\n有 ' + failed + ' 项失败');
process.exit(failed === 0 ? 0 : 1);
