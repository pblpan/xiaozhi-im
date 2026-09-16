// 对**龙哥正在跑的那台实例**（127.0.0.1:3602）做一次真实的浏览器渲染
//
//   NODE_PATH=<managed node workspace>/node_modules node deploy/live_wizard_shot.js
//
// 只渲染 + 截图 + 断言文案，**绝不提交表单** —— 那会把他的管理密码改成我这边造的值。
const { chromium } = require('playwright-core');
const fs = require('fs');
const path = require('path');

const EDGE = process.env.EDGE_PATH || 'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe';
const URL = process.env.URL || 'http://127.0.0.1:3602/admin/';
const SHOT_DIR = process.env.SHOT_DIR || path.join(require('os').tmpdir(), 'xiaozhi-live-shot');

let failed = 0;
const ok = (n, c, x) => { console.log((c ? '  ✓ ' : '  ✗ ') + n + (c || !x ? '' : '  → ' + x)); if (!c) failed++; };

(async () => {
  fs.mkdirSync(SHOT_DIR, { recursive: true });
  const browser = await chromium.launch({ executablePath: EDGE, headless: true });
  const ctx = await browser.newContext({ viewport: { width: 1180, height: 760 } });
  const page = await ctx.newPage();
  const errs = [];
  page.on('console', (m) => { if (m.type() === 'error') errs.push('console: ' + m.text()); });
  page.on('pageerror', (e) => errs.push('pageerror: ' + e.message));

  console.log('[真机渲染] ' + URL);
  await page.goto(URL, { waitUntil: 'domcontentloaded' });
  await page.waitForSelector('.login-card', { timeout: 20000 }).catch(() => {});
  await page.waitForTimeout(1200);

  let t = await page.evaluate(() => document.body.innerText || '');
  ok('页面不是白屏', t.length > 50, '长度 ' + t.length);
  ok('出的是「首次运行」向导，不是登录页', t.includes('首次运行 · 初始化'), t.slice(0, 120).replace(/\n/g, ' '));
  ok('有设密码按钮', t.includes('完成初始化并进入管理台'));
  ok('没有报错', errs.length === 0, errs.slice(0, 2).join(' ; '));
  await page.screenshot({ path: path.join(SHOT_DIR, 'live-wizard.png') });

  // 点一下"我已经知道密码，直接登录"，确认能退回普通登录页（不改任何密码）
  const link = page.locator('a', { hasText: '我已经知道密码' }).first();
  if (await link.count()) {
    await link.click();
    await page.waitForTimeout(500);
    t = await page.evaluate(() => document.body.innerText || '');
    ok('点「直接登录」能退回普通登录页',
      t.includes('服务端可视化管理后台') && !t.includes('首次运行 · 初始化'), t.slice(0, 100).replace(/\n/g, ' '));
    await page.screenshot({ path: path.join(SHOT_DIR, 'live-login.png') });
  } else {
    ok('有「直接登录」入口', false);
  }

  await browser.close();
  console.log('\n截图：' + SHOT_DIR);
  console.log(failed ? ('失败 ' + failed + ' 项') : '全部通过');
  process.exit(failed ? 1 : 0);
})().catch((e) => { console.error('异常：', e); process.exit(1); });
