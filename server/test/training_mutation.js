// 培训中心的**变异测试**（M4）
//
//   node server/test/training_mutation.js
//
// 【它回答的是哪个问题】
// training_e2e.js 全绿，只说明"这些用例没被触发失败"。它同样可能在
// **没有门禁、没有机会限制**的情况下全绿。所以这里把判据逐个改坏，
// 看 e2e 会不会红 —— 改坏了还全绿，说明那条判据根本没人看着。
//
// 【纪律】（和 apisign_mutation.js 同一套，别自己再发明一遍）
//   · 锚点必须是**源码原文**，找不到就当失败报出来（静默跳过 = 那轮白跑，
//     而且看起来还像"过了"，是最坏的假象）
//   · 每轮结束无条件还原，最后校验字节一致
//   · 用 Buffer 读写，不走文本模式（python 文本模式会把 LF 翻成 CRLF，还原后全文件 diff）
//   · 🔴 跑测试的命令必须是 **node**。别用任何"当前解释器"的变量：
//     python 里的 sys.executable 是 python 自己，拿它跑 .js 必然语法错退出 1，
//     看起来像"全部报红"，其实一条都没跑（这个假红真的出现过）。

const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const SERVER_DIR = path.resolve(__dirname, '..');
const SRC = path.join(SERVER_DIR, 'src', 'routes', 'training.js');
const E2E = path.join(__dirname, 'training_e2e.js');

const ORIG = fs.readFileSync(SRC);

const MUTATIONS = [
  {
    name: '进度门禁去掉（没学完也能考）',
    from: 'if (pct < e.min_progress) {',
    to: 'if (false && pct < e.min_progress) {',
  },
  {
    name: '考试机会限制去掉（可以无限重考）',
    from: 'if (used >= e.attempt_limit) {',
    to: 'if (false && used >= e.attempt_limit) {',
  },
  {
    name: '重复交卷检查去掉（交一次看分再改）',
    from: 'if (sheet.submitted_at > 0) {',
    to: 'if (false && sheet.submitted_at > 0) {',
  },
  {
    name: '"不在本卷的题不算分"这条去掉（拿别场题刷分）',
    from: 'if (!inSheet) continue;',
    to: 'if (false) continue;',
  },
  {
    name: '多选题改成"选对一个就给分"（漏选也得分）',
    from: "const correct = right.size > 0 && got.size === right.size && [...right].every((x) => got.has(x));",
    to: 'const correct = right.size > 0 && [...got].some((x) => right.has(x));',
  },
  {
    name: '题目下发时把正确答案也带出去（变开卷）',
    from: "SELECT id, label, content FROM tr_option WHERE question_id = ? ORDER BY id",
    to: "SELECT id, label, content, correct FROM tr_option WHERE question_id = ? ORDER BY id",
  },
  {
    name: '未发布课程也对学员可见',
    from: "let where = 'WHERE c.published = 1';",
    to: "let where = 'WHERE 1 = 1';",
  },
  {
    name: 'Range 支持去掉（永远整文件下发，拖进度条会重下整个视频）',
    from: 'const range = req.headers.range;',
    to: 'const range = null;',
  },
  {
    name: '进度 done 改成可降（看完再报一次没看完就掉回去）',
    from: 'done = MAX(done, excluded.done),',
    to: 'done = excluded.done,',
  },
  {
    name: '成绩默认只给最近 30 天（考完三个月再查就查不到了）',
    from: "const from = req.query.from === undefined || req.query.from === '' ? null : num(req.query.from, NaN);",
    to: 'const from = Date.now() - 30 * 86400000;',
  },
  {
    name: '成绩的"只看及格"过滤失效',
    from: "if (req.query.passed === '1') where.push('s.pass = 1');",
    to: "if (false) where.push('s.pass = 1');",
  },
  {
    name: '删课时不删进度（留下孤儿进度行）',
    from: "  db.prepare('DELETE FROM tr_progress WHERE lesson_id = ?').run(id);\n  db.prepare('DELETE FROM tr_lesson WHERE id = ?').run(id);",
    to: "  db.prepare('DELETE FROM tr_lesson WHERE id = ?').run(id);",
  },
  {
    name: '课件路径只按绝对路径解析（上传的相对路径课件播不了）',
    from: "  return path.isAbsolute(p) ? p : path.join(require('../config').FILES_DIR, p);",
    to: '  return path.resolve(p);',
  },
];

function runE2E() {
  try {
    const out = execFileSync(process.execPath, [E2E], {
      cwd: SERVER_DIR, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'],
    });
    return { code: 0, out };
  } catch (e) {
    return { code: e.status == null ? -1 : e.status, out: (e.stdout || '') + (e.stderr || '') };
  }
}

const summaryOf = (out) => {
  const m = out.match(/通过\s+(\d+)\s*\/\s*失败\s+(\d+)/);
  return m ? `通过 ${m[1]} / 失败 ${m[2]}` : '(没拿到总结行 — 多半是进程抛异常退的，那是假红)';
};
const failedCases = (out) => out.split('\n').map((l) => l.trim())
  .filter((l) => l.startsWith('\u2717 '))
  .map((l) => l.slice(2).split('  → ')[0].split(' — ')[0]);

console.log('[培训中心·变异测试] 逐条把判据改坏，看 e2e 会不会红\n');

let red = 0;
const notRed = [];
for (const m of MUTATIONS) {
  const text = ORIG.toString('utf8');
  if (!text.includes(m.from)) {
    console.log(`  ❌ 锚点失效（变异没生效，这条算失败）: ${m.name}`);
    notRed.push(m.name + '（锚点失效）');
    continue;
  }
  fs.writeFileSync(SRC, Buffer.from(text.replace(m.from, m.to), 'utf8'));
  const r = runE2E();
  const cases = [...new Set(failedCases(r.out))];
  if (r.code !== 0) {
    red++;
    console.log(`  ✔ 报红  ${m.name}`);
    console.log(`          ${summaryOf(r.out)} — 抓到: ${cases.join(' / ') || '(无明细，警惕假红)'}`);
  } else {
    notRed.push(m.name);
    console.log(`  ❌ 仍然全绿  ${m.name} — 这条判据没人看着！`);
  }
  fs.writeFileSync(SRC, ORIG);
}

const restored = ORIG.equals(fs.readFileSync(SRC));
console.log(`\n还原字节一致: ${restored}`);
console.log(`变异报红 ${red} / ${MUTATIONS.length}`);
if (notRed.length) {
  console.log('没报红的（必须修）:');
  for (const n of notRed) console.log('  ✗ ' + n);
}
if (!restored) console.log('❌ 源码没还原干净，先手动 diff！');
process.exit(restored && red === MUTATIONS.length ? 0 : 1);
