// 文件日志镜像（filelog）单元测试
//
// 覆盖 Windows 服务模式（无控制台）下的日志落盘：
//   ① 不设 XZ_LOG_FILE（传 null）→ 不启用、console 行为不变
//   ② 设了 → console.log/warn/error 都镜像进文件
//   ③ 首写带 UTF-8 BOM（记事本直接打开不乱码）
//   ④ 超过 5MB 自动轮转成 .1
//   ⑤ 目标目录不存在等失败 → 返回 enabled=false，不抛异常
//
//   node test/filelog_test.js

const fs = require('fs');
const os = require('os');
const path = require('path');

let passed = 0;
let failed = 0;
const failures = [];

function ok(name, cond, extra) {
  if (cond) {
    passed++;
    console.log(`  ✓ ${name}`);
  } else {
    failed++;
    failures.push(name + (extra ? ` — ${extra}` : ''));
    console.log(`  ✗ ${name}${extra ? '  → ' + extra : ''}`);
  }
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'xz-filelog-'));
process.on('exit', () => {
  try { fs.rmSync(TMP, { recursive: true, force: true }); } catch { /* ignore */ }
});

// 留一份原始 console，测完还原（不影响后续测试文件 —— 每个测试是独立进程）
const origLog = console.log;
const origWarn = console.warn;
const origError = console.error;

function freshFilelog() {
  delete require.cache[require.resolve('../src/filelog')];
  return require('../src/filelog');
}

function restoreConsole() {
  console.log = origLog;
  console.warn = origWarn;
  console.error = origError;
}

async function main() {
  // ============================================ ① 未启用
  console.log('\n[场景1] 未设 XZ_LOG_FILE（null）→ 不启用');
  {
    const fl = freshFilelog();
    const r = fl.init(null);
    ok('返回 enabled=false', r.enabled === false, JSON.stringify(r));
    ok('不碰 console', console.log === origLog && console.warn === origWarn);
  }

  // ============================================ ② 基本镜像
  console.log('\n[场景2] 设了 XZ_LOG_FILE → console 输出镜像进文件');
  {
    const fl = freshFilelog();
    const file = path.join(TMP, 'svc.log');
    const r = fl.init(file);
    ok('返回 enabled=true', r.enabled === true && r.file === file, JSON.stringify(r));

    console.log('[小智IM] 服务端已启动: http://localhost:3602');
    console.warn('一条警告');
    console.error('一条错误', { code: 42 });

    // ⚠️ 等待必须让出事件循环（setTimeout），不能 Atomics.wait 阻塞 ——
    //    后者会把 Node 单线程事件循环卡死，fs 写流的异步回调永远没机会跑。
    let text = '';
    for (let i = 0; i < 40; i++) {
      text = fs.readFileSync(file, 'utf8');
      if (text.includes('一条错误')) break;
      await sleep(50);
    }
    ok('console.log 进了文件', text.includes('服务端已启动'), text.slice(0, 120));
    ok('console.warn 进了文件', text.includes('一条警告'));
    ok('console.error 进了文件', text.includes('一条错误'));
    ok('非字符串参数被序列化', text.includes('"code":42'), text.slice(0, 200));
    ok('首字节是 UTF-8 BOM',
      Buffer.from(fs.readFileSync(file)).slice(0, 3).equals(Buffer.from('\ufeff', 'utf8')));

    restoreConsole();
  }

  // ============================================ ③ 轮转
  console.log('\n[场景3] 超过 5MB 自动轮转');
  {
    const fl = freshFilelog();
    const file = path.join(TMP, 'rotate.log');
    // 先造一个 6MB 的旧文件
    fs.writeFileSync(file, 'x'.repeat(6 * 1024 * 1024));
    fl.init(file);
    console.log('轮转后的第一行');
    for (let i = 0; i < 40; i++) {
      if (fs.existsSync(file + '.1')) break;
      await sleep(50);
    }
    ok('旧日志被改名成 .1', fs.existsSync(file + '.1'));
    ok('新日志从零开始（远小于旧体积）', fs.statSync(file).size < 1024 * 1024,
      `size=${fs.statSync(file).size}`);
    restoreConsole();
  }

  // ============================================ ④ 失败不抛
  console.log('\n[场景4] 目标不可写 → enabled=false，不抛异常');
  {
    const fl = freshFilelog();
    // 指向一个"目录"当文件 → 同步 open 直接失败（懒打开的 WriteStream 不会）
    const dirAsFile = path.join(TMP, 'adir');
    fs.mkdirSync(dirAsFile, { recursive: true });
    let threw = false;
    let r;
    try { r = fl.init(dirAsFile); } catch (e) { threw = true; }
    ok('不抛异常', !threw);
    ok('返回 enabled=false', r && r.enabled === false, JSON.stringify(r));
    ok('console 保持原样', console.log === origLog);
  }

  restoreConsole();
  console.log('\n' + '='.repeat(52));
  console.log(`通过 ${passed} 项，失败 ${failed} 项`);
  console.log('='.repeat(52));
  if (failures.length) {
    console.log('\n失败明细：');
    for (const f of failures) console.log('  · ' + f);
  }
  process.exit(failed === 0 ? 0 : 1);
}

main().catch((e) => {
  restoreConsole();
  console.error('\n测试异常终止：', e);
  process.exit(1);
});
