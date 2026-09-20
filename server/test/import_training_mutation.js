// 培训中心**素材导入器**的变异测试
//
//   node server/test/import_training_mutation.js
//
// 【它回答的问题】
// import_training_test.js 全绿只说明"这些用例没被触发失败"。
// 把判据逐个改坏，看测试会不会红 —— 改坏了还全绿，说明那条判据没人看着。
//
// 【纪律】（与 apisign_mutation / training_mutation 同一套，别自己再发明一遍）
//   · 锚点必须是**源码原文**；锚点失效当**失败**报出来
//     （静默跳过 = 那轮白跑，而且看起来还像"过了"，是最坏的假象）
//   · 每轮无条件还原，最后校验字节一致（用 Buffer，不走文本模式）
//   · 🔴 跑测试必须是 **node**。不能用任何"当前解释器"变量：
//     python 里的 sys.executable 是 python 自己，拿它跑 .js 必然语法错退出 1，
//     看起来像"全部报红"，其实一条都没跑（这个假红真的出现过）。
//   · 🔴 报红时要能看出**抓到了哪几条用例**。一条都抓不到又没有总结行，
//     说明进程是抛异常退的 —— 这种"红"要单独标出来，不能跟真红混在一起
//     （否则"崩溃"会被当成"判据生效"）。
//
// ⚠️ 锚点里含正则时，JS 字符串里的 `\s` 会被吞成 `s`（无效转义只保留字面量），
//    必须写成 `\\s` 才对得上源码。改锚点后**务必看输出有没有"锚点失效"**。

const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

// ⚠️ 路径必须相对**本文件**，不能用 process.cwd()：
//    从仓库根跑（node server/test/import_training_mutation.js）时 cwd = xiaozhi-im/，
//    拿它去 resolve('tools/...') 会指向不存在的 xiaozhi-im/tools/ →
//    本文件在 require 阶段就 ENOENT 崩掉，被批量回归记成 FAIL。
//    （2026-09-21 真踩到：单跑绿、进批量回归红，唯一差别就是 cwd。）
const SRC = path.resolve(__dirname, '../tools/import_training.js');
const T = path.resolve(__dirname, 'import_training_test.js');
const ORIG = fs.readFileSync(SRC);

const M = [
  ['幂等键改成不判重（每次都新建一份）',
    'SELECT * FROM tr_course WHERE category = ? AND title = ?',
    'SELECT * FROM tr_course WHERE 0'],
  ['垃圾文件过滤去掉（Office 临时文件变成课时）',
    "return name.startsWith('.') || name === 'Thumbs.db' || name.startsWith('~$');",
    'return false;'],
  // ⚠️ 这条锚点只能落**一行**（`stripped` 的赋值），不要试图跨那两行正则去锚：
  //    第一行 `const m = ...` 后面拖着一串注释，跨行锚点必然对不上。
  //    而只把第一条正则换成 null 是**假变异**："01 门店日常管理" 还会被第二条
  //    （≤2 位数字）剥掉，行为一模一样 —— 测试全绿完全正常，却看起来像
  //    "这条判据没人看着"。第一次就是这么误判的（锚点失效时脚本会报出来，别忽略）。
  ['序号前缀不去掉（课程名带 01）',
    'const stripped = m ? base.slice(m[0].length).trim() : base;',
    'const stripped = base;'],
  ['序号去得太狠（「2024年新规」被吃成「年新规」）',
    'const m = /^\\s*\\d{1,4}[._\\-、\\s]\\s*/.exec(base)',
    'const m = /^\\s*\\d+/.exec(base)'],
  ['未知参数不报错（打错一个字母安静变成预览）',
    '  if (a.unknown) {',
    '  if (false) {'],
  ['root 自己就是课程的情况去掉（指到课程目录扫出 0 门）',
    'if (rootFiles.length) {',
    'if (false) {'],
];

let red = 0;
let anchorFail = 0;
let dirtyRed = 0;
for (const [name, a, b] of M) {
  const t = ORIG.toString('utf8');
  if (!t.includes(a)) { console.log('  ❌ 锚点失效: ' + name); anchorFail++; continue; }
  fs.writeFileSync(SRC, Buffer.from(t.replace(a, b), 'utf8'));
  let code = 0;
  let out = '';
  try {
    out = execFileSync(process.execPath, [T], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
  } catch (e) { code = e.status == null ? -1 : e.status; out = (e.stdout || '') + (e.stderr || ''); }
  const m = out.match(/通过\s+(\d+)\s*\/\s*失败\s+(\d+)/);
  const cases = [...new Set(out.split('\n').map((l) => l.trim())
    .filter((l) => l.startsWith('\u2717 ')).map((l) => l.slice(2).split('  → ')[0]))];
  if (code !== 0) {
    red++;
    if (!m || !cases.length) {
      dirtyRed++;
      const last = out.split('\n').map((l) => l.trim()).filter((l) => l).slice(-1)[0] || '';
      console.log('  ✔ 报红  ' + name + '  ⚠️ 无总结行/无用例明细，最后一行: ' + last.slice(0, 110));
    } else {
      console.log('  ✔ 报红  ' + name + '  ' + m[0]);
      console.log('      抓到: ' + cases.join(' / '));
    }
  } else {
    console.log('  ❌ 仍然全绿  ' + name + ' — 这条判据没人看着！');
  }
  fs.writeFileSync(SRC, ORIG);
}

const restored = ORIG.equals(fs.readFileSync(SRC));
console.log('\n还原字节一致: ' + restored);
console.log('变异报红 ' + red + ' / ' + M.length
  + (dirtyRed ? `（其中 ${dirtyRed} 条红得不够干净：靠崩溃而非断言）` : ''));
if (anchorFail) console.log('锚点失效 ' + anchorFail + ' 条（必须修锚点，不能当通过）');
if (!restored) console.log('❌ 源码没还原干净，先手动 diff！');
process.exit(restored && !anchorFail && red === M.length && !dirtyRed ? 0 : 1);
