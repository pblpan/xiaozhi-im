// 复现并定位「fs.mkdirSync(recursive:true) 死循环」的触发条件。
//
//   python deploy/_exec_in_container.py deploy/_probe_mkdir_loop.js
//
// 背景：线上 POST /api/admin/files-dir {dir:'/proc/xz_nope/files'} 把**整个服务端**
//       打死（容器 CPU 97.6%，HTTP 全超时）。服务端是单线程 + 同步 fs 调用，
//       一旦 mkdirSync 内部死循环，事件循环被占满 → 全站无响应。
//
// 🔴 安全前提：每个试验都跑在**子进程**里，父进程用 spawnSync 的 timeout + SIGKILL
//    强杀。sync 死循环没法被 setTimeout 打断，只能靠内核把进程杀掉。
//    子进程死了不会牵连同容器的服务端进程。
'use strict';

const WATCHDOG = setTimeout(() => { process.stdout.write('\n[watchdog] 退出\n'); process.exit(9); }, 30000);

const cp = require('child_process');

function trial(label, code, opts) {
  const o = Object.assign({ recursive: true }, opts || {});
  const src = "const fs=require('fs');const t=Date.now();try{" +
    "fs.mkdirSync(" + JSON.stringify(code[0]) + ",{recursive:" + o.recursive + "});" +
    "console.log('OK '+(Date.now()-t)+'ms');" +
    "}catch(e){console.log('ERR '+e.code+' '+(Date.now()-t)+'ms '+(e.message||'').slice(0,80));}";
  const r = cp.spawnSync(process.execPath, ['-e', src], {
    timeout: o.timeout || 4000, killSignal: 'SIGKILL', encoding: 'utf8',
  });
  const out = (r.stdout || '').trim();
  const killed = !!r.error || r.signal === 'SIGKILL';
  console.log('  ' + (killed ? '❌ 杀掉' : '✅ 返回') + '  ' + label
    + '  →  ' + (out || '(无输出)')
    + (r.signal ? '  signal=' + r.signal : '')
    + (r.error ? '  err=' + r.error.code : ''));
  return killed;
}

console.log('node ' + process.version + '\n');

console.log('【试验组】哪些路径会让 recursive mkdir 卡住');
trial("A  /proc/xz_nope/files  recursive", ['/proc/xz_nope/files']);
trial("B  /proc/xz_nope        recursive", ['/proc/xz_nope']);
trial("C  /proc/xz_nope        *非*recursive", ['/proc/xz_nope'], { recursive: false });
trial("D  /data/_xz_tmp/a/b    recursive（正常盘，对照）", ['/data/_xz_tmp/a/b']);
trial("E  /sys/xz_nope         recursive", ['/sys/xz_nope']);
trial("F  /dev/xz_nope         recursive", ['/dev/xz_nope']);

console.log('\n【逐级创建法（修复方案）】—— 一次只建一层，任何一层失败立刻退出');
function mkdirEachLevel(p) {
  const path = require('path');
  const fs = require('fs');
  const parts = path.resolve(p).split(path.sep).filter(Boolean);
  let cur = path.sep;
  const t = Date.now();
  for (const seg of parts) {
    cur = path.join(cur, seg);
    try { fs.mkdirSync(cur); } catch (e) {
      if (e.code === 'EEXIST') continue;      // 已存在，继续往下
      return 'ERR ' + e.code + ' at ' + cur + ' (' + (Date.now() - t) + 'ms)';
    }
  }
  return 'OK ' + cur + ' (' + (Date.now() - t) + 'ms)';
}
for (const p of ['/proc/xz_nope/files', '/sys/xz_nope', '/dev/xz_nope', '/data/_xz_tmp/a/b']) {
  const r = cp.spawnSync(process.execPath, ['-e',
    "const f=" + mkdirEachLevel.toString() + ";console.log(f(process.argv[1]));", p],
    { timeout: 4000, killSignal: 'SIGKILL', encoding: 'utf8' });
  const killed = !!r.error || r.signal === 'SIGKILL';
  console.log('  ' + (killed ? '❌ 杀掉' : '✅ 返回') + '  ' + p + '  →  ' + (r.stdout || '').trim()
    + (r.error ? '  err=' + r.error.code : ''));
}

console.log('\n【清理】');
console.log('  ' + (mkdirEachLevel('/data/_xz_tmp') .startsWith('OK') ? '临时目录已建（/data/_xz_tmp，稍后手工删）' : '（无需清理）'));

clearTimeout(WATCHDOG);
process.exit(0);
