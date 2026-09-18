// 线上「上游接口」页取证截图（只读：只调 GET 与两个 POST 探活/试跑接口，不写任何登记数据）
//
// 用途：让龙哥一眼看到——管理台里确实有这一页、试跑确实能拿到真数据、
// 以及 dataPath 该带 data. 前缀这件事在界面上是写着的。
//
// 用法：NODE_PATH=<managed node workspace>/node_modules node deploy/shot_upstreams.js
const fs = require('fs');
const path = require('path');
const { chromium } = require('C:/Users/pblpa/.workbuddy/binaries/node/workspace/node_modules/playwright-core');

const EDGE = 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe';
const BASE = process.env.XZ_BASE || 'http://192.168.31.44:3602';
const OUT_DIR = path.join(__dirname, '_shots');
const PW_FILE = 'D:/Users/pblpa/Desktop/小智 IM/小智管理台新密码-请勿外传.txt';

function adminPassword() {
  const text = fs.readFileSync(PW_FILE, 'utf8');
  const m = text.match(/^新密码\s*[:：]\s*(\S+)\s*$/m);
  if (!m) throw new Error('密码文件里没找到「新密码」那一行');
  return m[1];
}

(async () => {
  fs.mkdirSync(OUT_DIR, { recursive: true });
  const pw = adminPassword();

  const res = await fetch(BASE + '/api/auth/login', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ username: 'admin', password: pw }),
  });
  const lg = await res.json();
  if (!lg.token) throw new Error('登录失败：' + JSON.stringify(lg).slice(0, 200));

  const browser = await chromium.launch({ executablePath: EDGE, headless: true });
  const ctx = await browser.newContext({ viewport: { width: 1500, height: 1000 } });
  await ctx.addInitScript((t) => { localStorage.setItem('xz_token', t); }, lg.token);
  const page = await ctx.newPage();
  const errs = [];
  page.on('pageerror', (e) => errs.push('pageerror: ' + e.message));
  page.on('console', (m) => { if (m.type() === 'error') errs.push(m.text()); });

  console.log('打开线上管理台…');
  await page.goto(BASE + '/admin/', { waitUntil: 'domcontentloaded', timeout: 60000 });
  await page.waitForSelector('.el-menu', { timeout: 30000 });

  console.log('切到「上游接口」…');
  await page.getByRole('menuitem', { name: '上游接口' }).click();
  // 等表格里真的出现 tiger 这一行（等网络空闲对 SPA 不管用）
  await page.locator('tr', { hasText: 'tiger' }).first().waitFor({ timeout: 20000 });
  await page.waitForTimeout(400);
  const p1 = path.join(OUT_DIR, '上游接口页.png');
  await page.screenshot({ path: p1, fullPage: true });
  console.log('  ✓ ' + p1);

  console.log('打开 tiger 的「试跑」并真的跑一次…');
  await page.locator('tr', { hasText: 'tiger' }).first().getByRole('button', { name: '试跑' }).click();
  const dlg = page.locator('.el-dialog');
  await dlg.waitFor({ timeout: 10000 });
  await dlg.locator('input[placeholder^="子路径"]').fill('report/daily');
  await dlg.getByRole('button', { name: '试跑' }).click();
  await dlg.locator('pre.mm-json').waitFor({ timeout: 30000 });
  await page.waitForTimeout(300);

  const pre = await dlg.locator('pre.mm-json').innerText();
  const parsed = JSON.parse(pre);
  const meta = await dlg.locator('.hint').last().innerText();
  console.log('  服务端转发结果：' + meta);
  console.log('  信封字段：' + Object.keys(parsed).join(', '));
  console.log('  data 里的 keys：' + Object.keys(parsed.data || {}).slice(0, 12).join(', '));

  const p2 = path.join(OUT_DIR, '上游接口-试跑结果.png');
  await page.screenshot({ path: p2, fullPage: true });
  console.log('  ✓ ' + p2);

  await browser.close();
  console.log('\n控制台错误：' + (errs.length ? errs.join(' | ') : '无'));
  if (errs.length) process.exitCode = 1;
})().catch((e) => { console.error(e); process.exit(1); });
