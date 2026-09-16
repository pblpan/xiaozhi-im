// 「首次运行 · 初始化」向导 —— 浏览器真渲染验证
//
//   NODE_PATH=<managed node workspace>/node_modules node deploy/setup_wizard_ui_check.js
//
// 为什么必须真渲染：bundle 里 grep 到「首次运行 · 初始化」这几个字，只能说明字符串
// 被打包进去了；Vue 模板里的运行时错误（引用未定义、对 null 取属性）在 vite build
// 阶段不报错，产物照出，但页面一打开就是白屏。只有让浏览器真跑一遍才认得出来。
//
// 自包含：自己起一个全新实例（数据目录是空的 → 服务端判定 needSetup=true），
// 用本机 Edge 走完"看到向导 → 输入校验 → 设密码 → 进管理台 → 退出后不再弹"整条链路。

const { spawn } = require('child_process');
const path = require('path');
const fs = require('fs');
const os = require('os');
const { chromium } = require('playwright-core');

const EDGE = process.env.EDGE_PATH || 'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe';
const PORT = Number(process.env.PORT || 3707);
const ORIGIN = `http://127.0.0.1:${PORT}`;
const BASE = ORIGIN + '/admin/';
const SERVER_DIR = path.resolve(__dirname, '..', 'server');
const DATA_DIR = path.join(os.tmpdir(), 'xiaozhi-wizard-ui-' + Date.now());
const SHOT_DIR = process.env.SHOT_DIR || path.join(os.tmpdir(), 'xiaozhi-wizard-shots');

const SEED = 'Seed_Admin_123';
const NEWPW = 'MyOwn_Pw-2026';

let failed = 0;
const ok = (name, cond, extra) => {
  console.log((cond ? '  ✓ ' : '  ✗ ') + name + (cond || !extra ? '' : '  → ' + extra));
  if (!cond) failed++;
};
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

let serverProc = null;
let serverLog = '';

async function startServer() {
  serverProc = spawn(process.execPath, [path.join(SERVER_DIR, 'src', 'index.js')], {
    env: { ...process.env, PORT: String(PORT), DATA_DIR, ADMIN_PASSWORD: SEED },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  serverProc.stdout.on('data', (d) => { serverLog += d.toString(); });
  serverProc.stderr.on('data', (d) => { serverLog += d.toString(); });
  for (let i = 0; i < 80; i++) {
    try { if ((await fetch(`${ORIGIN}/api/health`)).ok) return; } catch { /* 还没起来 */ }
    await sleep(250);
  }
  throw new Error('服务端启动超时\n' + serverLog);
}

function stopServer() {
  if (serverProc) { try { serverProc.kill(); } catch { /* ignore */ } }
}

/** 收集页面报错：白屏的根因几乎总在这里 */
function watch(page, bucket) {
  page.on('console', (m) => { if (m.type() === 'error') bucket.push('console: ' + m.text()); });
  page.on('pageerror', (e) => bucket.push('pageerror: ' + e.message));
}

(async () => {
  fs.mkdirSync(SHOT_DIR, { recursive: true });
  await startServer();
  console.log('[向导 UI 验证] 实例已就绪 ' + BASE + '\n');

  const browser = await chromium.launch({ executablePath: EDGE, headless: true });
  const ctx = await browser.newContext({ viewport: { width: 1280, height: 820 } });
  const page = await ctx.newPage();
  const errs = [];
  watch(page, errs);

  // ---------------- 一、全新实例该看到向导 ----------------
  console.log('【一】全新实例：打开管理台先看到向导');
  await page.goto(BASE, { waitUntil: 'domcontentloaded' });
  await page.waitForSelector('text=首次运行 · 初始化', { timeout: 15000 }).catch(() => {});

  const bodyText = await page.evaluate(() => document.body.innerText || '');
  ok('页面不是白屏', bodyText.length > 50, `innerText 长度 ${bodyText.length}`);
  ok('显示向导标题', bodyText.includes('首次运行 · 初始化'), bodyText.slice(0, 120).replace(/\n/g, ' '));
  ok('显示"设密码"按钮', bodyText.includes('完成初始化并进入管理台'));
  ok('给出字符集说明（否则设完登不上会一头雾水）', bodyText.includes('6~64 位'));
  ok('没有同时显示登录按钮（两张卡只能出一张）', !/^登录$/m.test(bodyText), bodyText.slice(0, 200).replace(/\n/g, ' | '));
  ok('无 console / pageerror 报错', errs.length === 0, errs.slice(0, 3).join(' ; '));

  const acct = page.locator('.login-card input[disabled]').first();
  ok('账号框是只读的且预填 admin', (await acct.inputValue()) === 'admin', await acct.inputValue());
  await page.screenshot({ path: path.join(SHOT_DIR, '1-wizard.png') });

  // ---------------- 二、输入校验（本地就该挡住，不用往返服务端） ----------------
  console.log('\n【二】输入校验');
  const pw1 = page.locator('.login-card input[placeholder="设置密码"]').first();
  const pw2 = page.locator('.login-card input[placeholder="再输一遍确认"]').first();

  await pw1.fill('abc');
  await pw2.fill('abc');
  await page.getByRole('button', { name: '完成初始化并进入管理台' }).click();
  await sleep(350);
  let t = await page.evaluate(() => document.body.innerText || '');
  ok('太短 → 当场提示，且还留在向导页', t.includes('6~64 位') && t.includes('完成初始化并进入管理台'));

  await pw1.fill('Has#Hash99');
  await pw2.fill('Has#Hash99');
  await page.getByRole('button', { name: '完成初始化并进入管理台' }).click();
  await sleep(350);
  t = await page.evaluate(() => document.body.innerText || '');
  ok('含不允许的符号 → 当场提示', t.includes('只能用字母、数字'), t.slice(0, 160).replace(/\n/g, ' '));

  await pw1.fill(NEWPW);
  await pw2.fill(NEWPW + 'x');
  await page.getByRole('button', { name: '完成初始化并进入管理台' }).click();
  await sleep(350);
  t = await page.evaluate(() => document.body.innerText || '');
  ok('两次不一致 → 提示不一致', t.includes('两次输入的密码不一致'));
  await page.screenshot({ path: path.join(SHOT_DIR, '2-validate.png') });

  // ---------------- 三、设密码 → 直接进管理台 ----------------
  console.log('\n【三】设置成功即进管理台');
  await pw1.fill(NEWPW);
  await pw2.fill(NEWPW);
  await page.getByRole('button', { name: '完成初始化并进入管理台' }).click();
  await page.waitForSelector('text=仪表盘', { timeout: 15000 }).catch(() => {});
  t = await page.evaluate(() => document.body.innerText || '');
  ok('进入管理台（侧栏出现）', t.includes('仪表盘') && t.includes('用户管理'), t.slice(0, 120).replace(/\n/g, ' '));
  ok('token 已落到 localStorage', !!(await page.evaluate(() => localStorage.getItem('xz_token'))));
  ok('全程无 console / pageerror 报错', errs.length === 0, errs.slice(0, 3).join(' ; '));
  await page.screenshot({ path: path.join(SHOT_DIR, '3-inside.png') });

  // ---------------- 四、退出后不再弹向导 ----------------
  console.log('\n【四】退出后应回到普通登录页');
  await ctx.clearCookies();
  await page.evaluate(() => localStorage.removeItem('xz_token'));
  await page.goto(BASE, { waitUntil: 'domcontentloaded' });
  await page.reload({ waitUntil: 'domcontentloaded' });
  await page.waitForSelector('text=服务端可视化管理后台', { timeout: 15000 }).catch(() => {});
  t = await page.evaluate(() => document.body.innerText || '');
  ok('不再显示向导', !t.includes('首次运行 · 初始化'), t.slice(0, 120).replace(/\n/g, ' '));
  // 注意：'管理员账号' 是 input 的 placeholder，**不进 innerText**，
  // 只能查属性（第一版这里写成查 innerText，白白报了一次假失败）
  ok('显示普通登录页',
    t.includes('服务端可视化管理后台')
    && (await page.locator('input[placeholder="管理员账号"]').count()) === 1
    && (await page.locator('.login-card input[disabled]').count()) === 0);
  ok('登录页提示了密码去哪查', t.includes('查看管理员密码'));

  // ---------------- 五、用刚设的密码登录 ----------------
  console.log('\n【五】用刚设的密码登录');
  await page.locator('input[placeholder="管理员账号"]').fill('admin');
  await page.locator('input[placeholder="密码"]').fill(NEWPW);
  await page.getByRole('button', { name: '登录' }).click();
  await page.waitForSelector('text=仪表盘', { timeout: 15000 }).catch(() => {});
  t = await page.evaluate(() => document.body.innerText || '');
  ok('登录成功进管理台', t.includes('仪表盘') && t.includes('用户管理'), t.slice(0, 120).replace(/\n/g, ' '));
  ok('仍然没有报错', errs.length === 0, errs.slice(0, 3).join(' ; '));
  await page.screenshot({ path: path.join(SHOT_DIR, '4-login.png') });

  // ---------------- 六、旧密码应被拒 ----------------
  console.log('\n【六】安装时那串旧密码应被拒（并且不弹向导）');
  await page.evaluate(() => localStorage.removeItem('xz_token'));
  await page.goto(BASE, { waitUntil: 'domcontentloaded' });
  await page.locator('input[placeholder="管理员账号"]').fill('admin');
  await page.locator('input[placeholder="密码"]').fill(SEED);
  await page.getByRole('button', { name: '登录' }).click();
  await sleep(1200);
  t = await page.evaluate(() => document.body.innerText || '');
  ok('旧密码登不进去，仍停在登录页', t.includes('服务端可视化管理后台'), t.slice(0, 120).replace(/\n/g, ' '));

  await browser.close();
  stopServer();

  console.log('\n截图：' + SHOT_DIR);
  console.log('='.repeat(52));
  console.log(failed ? `失败 ${failed} 项` : '全部通过');
  console.log('='.repeat(52));
  process.exit(failed ? 1 : 0);
})().catch((e) => {
  console.error('\n[UI 验证] 异常中断:', e);
  stopServer();
  process.exit(1);
});
