// 签名通道的**变异测试**（M3）
//
//   node test/apisign_mutation.js
//
// 【它回答的是哪个问题】
// `apisign_e2e.js` 全绿，只说明"这些用例没被触发失败"。它同样可能在
// "签名根本没校"的情况下全绿 —— 那时 e2e 里"正确签名 → 200"依然过，
// 而"篡改签名 → 401"之所以没写就没得红。
//
// 所以这里做的事是：**故意把判据改坏**，看 e2e 会不会红。
//   · 改坏了还全绿 ⇒ 那条判据根本没有被任何用例覆盖（用例是装饰品）
//   · 改坏了就红     ⇒ 这条判据真有人在看着
//
// 【纪律】
//   · 每一轮都必须在**改之前**确认锚点存在（锚点失效 = 变异悄悄变成空操作）
//   · 每一轮结束无条件还原，最后再校验字节一致
//   · 用 fs 读写 Buffer，不走文本模式 —— 文本模式会顺手把 LF 改成 CRLF，
//     还原后 diff 全文件，白吓一跳（真踩过）
//
// 【一个已经踩过的坑，写在这免得重犯】
// 第一版这个脚本是用 python 调 subprocess 写的，里面写了 `sys.executable`
// 去执行 .js —— python 里的 sys.executable 是 **python 自己**，
// 于是变成"用 python 解析 js"，必然语法错退出 1，看起来像"全部报红"。
// **假红比不红更危险**：它会让人以为防护有效。判断红得对不对，
// 要看失败的是**哪几条用例**（这里会把失败项打印出来）。

const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const SERVER_DIR = path.resolve(__dirname, '..');
const SRC = path.join(SERVER_DIR, 'src', 'apisign.js');
const E2E = path.join(__dirname, 'apisign_e2e.js');

const ORIG = fs.readFileSync(SRC); // Buffer，字节级

/** 每一条变异：名字 + 原文锚点 + 替换成什么 */
const MUTATIONS = [
  {
    name: '时间窗判据改成恒真（10 分钟前的请求也能过）',
    from: 'if (Math.abs(nowSec - tsSec) > SIGN_WINDOW_SEC) {',
    to: 'if (false && Math.abs(nowSec - tsSec) > SIGN_WINDOW_SEC) {',
  },
  {
    name: '签名比对改成恒真（任何签名都过）',
    from: 'let okSign = safeEqual(signWith(secret, o), signHex);',
    to: 'let okSign = true;',
  },
  {
    name: 'nonce 重放检查去掉（INSERT OR REPLACE，重复不再报）',
    from: "db.prepare('INSERT INTO api_nonce (nonce, app_id, at) VALUES (?,?,?)')",
    to: "db.prepare('INSERT OR REPLACE INTO api_nonce (nonce, app_id, at) VALUES (?,?,?)')",
  },
  {
    name: '停用判据去掉（停用了还能调）',
    from: "if (!row || !row.enabled) return deny(401, 'app_id 无效', 'app_invalid');",
    to: "if (!row) return deny(401, 'app_id 无效', 'app_invalid');",
  },
  {
    name: '主体哈希改成永远空串（body 改包不再被抓）',
    from: 'return crypto.createHash(\'sha256\').update(raw).digest(\'hex\');',
    to: 'return crypto.createHash(\'sha256\').update(Buffer.alloc(0)).digest(\'hex\');',
  },
  {
    name: 'query 不签进去（改 ?limit= 不再被抓）',
    from: 'return [o.method, o.path, o.query, o.timestamp, o.nonce, o.bodyHashHex].join(\'\\n\');',
    to: 'return [o.method, o.path, \'\', o.timestamp, o.nonce, o.bodyHashHex].join(\'\\n\');',
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

function summaryOf(out) {
  const m = out.match(/通过\s+(\d+)\s*\/\s*失败\s+(\d+)/);
  return m ? `通过 ${m[1]} / 失败 ${m[2]}` : '(没拿到总结行)';
}

function failedCases(out) {
  return out.split('\n')
    .map((l) => l.trim())
    .filter((l) => l.startsWith('\u2717 '))
    .map((l) => l.slice(2).split('  → ')[0].split(' — ')[0]);
}

console.log('[变异测试] 逐条把判据改坏，看 e2e 会不会红\n');

let red = 0;
const notRed = [];

for (const m of MUTATIONS) {
  const text = ORIG.toString('utf8');
  if (!text.includes(m.from)) {
    // 锚点失效必须当成失败报出来 —— 静默跳过等于这一轮白跑，
    // 而且看起来还像"过了"。
    console.log(`  ❌ 锚点失效（变异没生效，这条算失败）: ${m.name}`);
    notRed.push(m.name + '（锚点失效）');
    continue;
  }
  fs.writeFileSync(SRC, Buffer.from(text.replace(m.from, m.to), 'utf8'));
  const r = runE2E();
  const cases = failedCases(r.out);
  if (r.code !== 0) {
    red++;
    console.log(`  ✔ 报红  ${m.name}`);
    console.log(`          ${summaryOf(r.out)} — 抓到: ${[...new Set(cases)].join(' / ') || '(无明细)'}`);
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
