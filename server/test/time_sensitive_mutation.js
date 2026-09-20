// **时间敏感判据**的变异测试
//
//   node server/test/time_sensitive_mutation.js
//
// 【它回答的问题】
// 2026-09-21 早上 7 点跑批量回归，红了两条：
//   · admin_stats_e2e  「[鉴别力] 按 UTC 窗口重算只得到 1 条」
//   · attendance_e2e   「今日状态：未到点只报已确定的问题（pending 或 late）」
// 两条都不是产品坏了，是**判据本身跟跑的钟点绑定**：写死了白天才成立的前提。
// 修的时候有个陷阱：把判据放宽到"任何时候都过"很容易，但那样就把真 bug 一起放过了。
// 这个文件就是给那次修复上的锁 —— 把判据要防的两种坏代码真的改回去，看它红不红。
//
// 【纪律】（与 apisign_mutation / training_mutation / import_training_mutation 同一套）
//   · 锚点必须是**源码原文**；锚点失效当失败报出来（静默跳过 = 那轮白跑）
//   · 每轮无条件还原，最后校验字节一致（用 Buffer，不走文本模式）
//   · 跑测试必须是 **node**，不能用"当前解释器"变量
//   · 报红时必须能看出**是哪条判据抓到的** —— 这里的 mustMatch 就是这个用途：
//     红是红了，但不是预期那条判据抓的，说明判据没在防它该防的东西（要单独标出来）
//
// ⚠️ 路径一律相对本文件（__dirname），不要用 process.cwd()：
//    从仓库根和从 server/ 下跑，cwd 不一样（import_training_mutation 就栽在这上面）。
//
// ⚠️ 锚点**一律用单行**，不要在 from 里写 '\n' 跨行：
//    这些源文件是 CRLF 行尾，`'a;\nb;'` 里的 '\n' 对不上 '\r\n'，
//    跨行锚点必然"锚点失效"（2026-09-21 真踩到）。要多行就写成数组，一次一行。

const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const SERVER_DIR = path.resolve(__dirname, '..');

const CASES = [
  {
    name: '仪表盘"今日"窗口退回 UTC 口径（北京时间凌晨的算成昨天）',
    file: 'src/routes/admin.js',
    from: ["const dayStart = att.tsOfDay(day, '00:00');",
           "const dayEnd = att.tsOfDay(att.addDays(day, 1), '00:00');"],
    to: ['const dayStart = Math.floor(Date.now() / 86400000) * 86400000;',
         'const dayEnd = dayStart + 86400000;'],
    test: 'test/admin_stats_e2e.js',
    mustMatch: /鉴别力|msgsToday = 3/,
  },
  {
    name: '去掉"未到点不判早退"闸门（上午打的下班卡 → 早退几百分钟）',
    file: 'src/attendance.js',
    from: '      const earlyMin = due ? Math.max(0, (expectMin - shift.earlyGrace) - m) : 0;',
    to: '      const earlyMin = Math.max(0, (expectMin - shift.earlyGrace) - m);',
    test: 'test/attendance_e2e.js',
    mustMatch: /今日不判早退/,
  },
  {
    name: '早到被记成迟到（09:00 前打卡 lateMinutes > 0）',
    file: 'src/attendance.js',
    from: '      item.lateMinutes = Math.max(0, m - (expectMin + flex + shift.lateGrace));',
    to: '      item.lateMinutes = Math.max(0, Math.abs(m - (expectMin + flex + shift.lateGrace)));',
    test: 'test/attendance_e2e.js',
    mustMatch: /今日状态|迟到分钟数/,
  },
];

function readBuf(rel) { return fs.readFileSync(path.join(SERVER_DIR, rel)); }

function runTest(rel) {
  try {
    const out = execFileSync(process.execPath, [path.join(SERVER_DIR, rel)], {
      cwd: SERVER_DIR, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], timeout: 180000,
    });
    return { code: 0, out };
  } catch (e) {
    return { code: e.status == null ? -1 : e.status, out: `${e.stdout || ''}${e.stderr || ''}` };
  }
}

/** 只取"失败项"那一段，用来判断是哪条判据抓到的 */
function failureBlock(out) {
  const i = out.indexOf('失败项');
  return i < 0 ? '' : out.slice(i);
}

let caught = 0;
const missed = [];

for (const cs of CASES) {
  const file = path.join(SERVER_DIR, cs.file);
  const orig = readBuf(cs.file);
  let text = orig.toString('utf8');

  const froms = Array.isArray(cs.from) ? cs.from : [cs.from];
  const tos = Array.isArray(cs.to) ? cs.to : [cs.to];
  const miss = froms.findIndex((f) => text.indexOf(f) < 0);
  if (miss >= 0) {
    console.log(`  ✗ 锚点失效（源码里没这段，本轮白跑）：${cs.name}\n      ${cs.file} ← ${froms[miss]}`);
    missed.push(cs.name);
    continue;
  }
  froms.forEach((f, i) => { text = text.replace(f, tos[i]); });

  fs.writeFileSync(file, Buffer.from(text, 'utf8'));
  let res;
  try {
    res = runTest(cs.test);
  } finally {
    fs.writeFileSync(file, orig);          // 无条件还原
  }

  const restored = Buffer.compare(readBuf(cs.file), orig) === 0;
  if (!restored) {
    console.log(`  ✗ 还原失败！${cs.file} 已不是原样，中止后续用例`);
    process.exit(2);
  }

  if (res.code === 0) {
    console.log(`  ✗ 漏网（改坏了还全绿）：${cs.name}`);
    missed.push(cs.name);
    continue;
  }
  if (res.code === -1) {
    console.log(`  ✗ 测试进程异常退出（不算抓住）：${cs.name}`);
    missed.push(cs.name);
    continue;
  }
  const blk = failureBlock(res.out);
  if (!cs.mustMatch.test(blk)) {
    console.log(`  ~ 红了，但不是预期判据抓的：${cs.name}`);
    console.log(`      预期含 ${cs.mustMatch}，实际失败项：${(blk.split('\n').filter((l) => l.trim()).slice(0, 6).join(' | ') || '（无失败项输出）')}`);
    missed.push(cs.name);
    continue;
  }
  caught++;
  const hit = blk.split('\n').filter((l) => l.trim() && cs.mustMatch.test(l))[0] || '';
  console.log(`  ✔ 报红  ${cs.name}`);
  console.log(`      抓到: ${hit.trim().slice(0, 160)}`);
}

console.log('\n' + '='.repeat(56));
if (missed.length) {
  console.log(`变异报红 ${caught} / ${CASES.length}`);
  console.log('漏掉/无效：');
  for (const m of missed) console.log('  · ' + m);
  process.exit(1);
}
console.log(`变异报红 ${caught} / ${CASES.length}（全部由预期判据抓到，源码已逐字节还原）`);
console.log('='.repeat(56));
