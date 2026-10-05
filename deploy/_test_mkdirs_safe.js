// 本地验证 mkdirsSafe / ensureFilesDir 的边界与回落行为（Windows 上跑，不碰 procfs）
//
//   node deploy/_test_mkdirs_safe.js          # 模式①：边界用例
//   node deploy/_test_mkdirs_safe.js boot     # 模式②：启动回落（需独立进程，见下）
//
// ⚠️ 为什么要分两个进程：本机安全策略拦 node 派生子进程（spawnSync 回 EBUSY），
//    所以「换一个 DATA_DIR 再 require config」没法在同一个进程里做 —— config.js
//    在 require 时就定死了 DATA_DIR。两段各跑一次进程即可，行为等价。
'use strict';
const fs = require('fs');
const os = require('os');
const path = require('path');

const SRV = path.resolve(__dirname, '..', 'server', 'src');
const MODE = process.argv[2] || 'edge';

let pass = 0, bad = 0;
const ok = (n, c, d) => { c ? (pass++, console.log('  ✓ ' + n + (d ? ' — ' + d : ''))) : (bad++, console.log('  ✗ ' + n + (d ? ' — ' + d : ''))); };

if (MODE === 'boot') {
  /* ===== 模式②：paths.env 指向一个建不出来的目录时，启动必须回落而不是卡死/崩 ===== */
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'xzboot-'));
  // 造一个"挡路的文件"，让 <tmp>/blocked/files 这个目录永远建不出来
  fs.writeFileSync(path.join(tmp, 'blocked'), 'x');
  const impossible = path.join(tmp, 'blocked', 'files');
  fs.writeFileSync(path.join(tmp, 'paths.env'), '# test\nFILESDIR=' + impossible + '\n', 'utf8');
  process.env.DATA_DIR = tmp;
  const t0 = Date.now();
  const cfg = require(path.join(SRV, 'config.js'));
  const ms = Date.now() - t0;

  console.log('  DATA_DIR   = ' + tmp);
  console.log('  paths.env 里写的 FILESDIR = ' + impossible + '（父路径是文件 → 建不出来）');
  console.log('  FILES_DIR  = ' + cfg.FILES_DIR + '   (require 耗时 ' + ms + 'ms)');
  console.log('  DEFAULT    = ' + cfg.DEFAULT_FILES_DIR);
  ok('require 没卡住（<3s）', ms < 3000, ms + 'ms');
  ok('回落到了默认目录', cfg.FILES_DIR === cfg.DEFAULT_FILES_DIR, cfg.FILES_DIR);
  ok('回落后的目录真的建出来了', fs.existsSync(cfg.FILES_DIR));
  ok('没有采用坏路径', cfg.FILES_DIR !== impossible);

  console.log('\n结论：通过 ' + pass + ' 项，失败 ' + bad + ' 项');
  try { fs.rmSync(tmp, { recursive: true, force: true }); } catch { /* ignore */ }
  process.exit(bad === 0 ? 0 : 1);
}

/* ===== 模式①：边界用例 ===== */
const tmpRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'xzedge-'));
process.env.DATA_DIR = tmpRoot;
const cfg = require(path.join(SRV, 'config.js'));
const ms = () => Date.now() - t0;
const t0 = Date.now();

/**
 * 🚨 硬护栏：本脚本只允许在 os.tmpdir() 里造/删目录。
 *
 * 为什么加这条 —— 2026-10-05 踩过：原用例写的是"不存在的盘 Z:\no_such_drive\files"，
 * 结果这台机器 **Z: 是真实在用的数据盘**，mkdirsSafe 老老实实把
 * Z:\no_such_drive\files 建出来了（测试红了一条，同时在用户盘上留了两个空目录）。
 * 教训：凡是"故意造一个不存在的路径"的测试，都必须先证明它落点安全。
 */
function assertInsideTmp(p) {
  const a = path.resolve(p).toLowerCase();
  const b = path.resolve(os.tmpdir()).toLowerCase();
  if (!a.startsWith(b)) throw new Error('拒绝操作临时目录之外的路径：' + a);
  return p;
}

console.log('【边界用例】（只动 ' + tmpRoot + '）');

let r = cfg.mkdirsSafe(assertInsideTmp(path.join(tmpRoot, 'a', 'b', 'c')));
ok('正常多级路径可建', r.ok && fs.existsSync(path.join(tmpRoot, 'a', 'b', 'c')), r.dir + '  ' + ms() + 'ms');

r = cfg.mkdirsSafe(assertInsideTmp(path.join(tmpRoot, 'a', 'b', 'c')));
ok('重复调用幂等（EEXIST 视为成功）', r.ok);

// 「建不出来」用两种与盘符无关的造法，避免依赖"某个盘不存在"这种随时会变的前提
const asFile = path.join(tmpRoot, 'iamafile');
fs.writeFileSync(asFile, 'x');
r = cfg.mkdirsSafe(assertInsideTmp(path.join(asFile, 'child', 'deeper')));
ok('父路径是文件 → 不抛异常、明确报错', !r.ok, r.code + ' ' + r.error);

r = cfg.mkdirsSafe(path.join(tmpRoot, 'bad<name>', 'files'));
ok('含非法字符 → 明确报错（不是卡住）', !r.ok, r.code + ' ' + r.error);

r = cfg.mkdirsSafe('C:\\' + Array.from({ length: 40 }, (_, i) => 'd' + i).join('\\'));
ok('层级过深被拦（EDEPTH）', !r.ok && r.code === 'EDEPTH', r.error);

r = cfg.mkdirsSafe('');
ok('空串 → 不崩', r.ok, r.dir);

// Windows 盘符不能被拆坏（第一版就是这里红的：拼出 \C:）
r = cfg.mkdirsSafe(tmpRoot);
ok('Windows 盘符路径正常（root 用 path.parse）', r.ok, r.dir);

console.log('\n【说明】');
console.log('    Windows 没有 procfs，recursive mkdir 在这台机器上不会卡，所以本地测不出');
console.log('    真正的死循环 —— 钉住它的是容器里的 deploy/_probe_mkdir_loop.js（已复现 SIGKILL）。');
console.log('    本脚本负责另一头：边界与回落逻辑对不对。');

console.log('\n结论：通过 ' + pass + ' 项，失败 ' + bad + ' 项');
try { fs.rmSync(tmpRoot, { recursive: true, force: true }); } catch { /* ignore */ }
process.exit(bad === 0 ? 0 : 1);
