// 生产仪表盘「只读」渲染取证（v0.15.0）
//
// 为什么单独写一个：本机 admin_ui_check.js 会**播种数据**（fake hook + 失败投递）来
// 验证异常提醒条，跑在生产上会写脏数据。这里只做 GET + 截图，**不落任何写操作**。
//
// 用法：XZ_SECRET=<生产 JWT_SECRET> node deploy/prod_dashboard_shot.js
//
// 取证目的（针对本次"仪表盘重做"）：
//   1. 确认线上管理台静态产物真的是新版（分组卡 / 今日新增 / 近 7 天活跃是否存在）
//   2. 确认真实渲染无 JS 报错（bundle 里 grep 到 ≠ 页面能渲染）
//   3. 留一张真实数据的截图给人看
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

const { chromium } = require('C:/Users/pblpa/.workbuddy/binaries/node/workspace/node_modules/playwright-core');

const EDGE = 'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe';
const BASE = process.env.XZ_BASE || 'http://192.168.31.44:3602';
const SECRET = process.env.XZ_SECRET || '';
const OUT_DIR = path.join(__dirname, '_prod_shots');

function b64url(buf) {
  return Buffer.from(buf).toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}
function mintToken(uid, role) {
  const now = Math.floor(Date.now() / 1000);
  const head = b64url(JSON.stringify({ alg: 'HS256', typ: 'JWT' }));
  const body = b64url(JSON.stringify({ uid, role, iat: now, exp: now + 3600 }));
  return head + '.' + body + '.' + b64url(crypto.createHmac('sha256', SECRET).update(head + '.' + body).digest());
}

let failed = 0;
const ok = (name, cond, extra) => {
  console.log((cond ? '  ✓ ' : '  ✗ ') + name + (cond || !extra ? '' : '  → ' + extra));
  if (!cond) failed++;
};

(async () => {
  if (!SECRET) { console.error('缺 XZ_SECRET'); process.exit(2); }
  fs.mkdirSync(OUT_DIR, { recursive: true });

  const browser = await chromium.launch({ executablePath: EDGE, headless: true });
  const ctx = await browser.newContext({ viewport: { width: 1500, height: 1200 } });
  const page = await ctx.newPage();
  const pageErrors = [];
  const consoleErrors = [];
  const httpErrors = [];
  page.on('pageerror', (e) => pageErrors.push('pageerror: ' + e.message));
  page.on('console', (m) => { if (m.type() === 'error') consoleErrors.push(m.text()); });
  page.on('response', (r) => { if (r.status() >= 400) httpErrors.push(r.status() + ' ' + r.url()); });

  const token = mintToken(1, 'admin');
  await ctx.addInitScript((t) => { localStorage.setItem('xz_token', t); }, token);

  // 先问一次「是不是工作模式」：
  // 「组织与考勤」这一组是**工作模式下才 unshift 进分组列表**的，而 mode 来自异步的
  // /admin/settings。若只等 .mtile（stats 一到就出现），会在设置接口还没回来时
  // 把"少一组"当成功能缺失 —— 实测就出现过一次这种假失败，比真失败更危险。
  const sres = await fetch(BASE + '/api/admin/settings', { headers: { Authorization: 'Bearer ' + token } });
  const cfg = await sres.json().catch(() => ({}));
  const isWork = (cfg.friendMode || cfg.mode) === 'work';
  const wantGroups = isWork
    ? ['组织与考勤', '人员', '消息', '文件', '集成']
    : ['人员', '消息', '文件', '集成'];
  console.log(`  服务器模式: ${isWork ? 'work（工作）' : 'normal（普通）'}，预期分组 ${wantGroups.length} 个`);

  console.log('\n== 打开生产管理台（只读） ==');
  await page.goto(BASE + '/admin/', { waitUntil: 'domcontentloaded', timeout: 60000 });
  // 等分组卡按**预期数量**渲染齐（不是等网络空闲 —— SPA 等不到）
  await page.waitForFunction(
    (n) => document.querySelectorAll('.mgroup').length >= n,
    wantGroups.length,
    { timeout: 30000 },
  );
  await page.waitForSelector('.mtile', { timeout: 30000 });

  const groups = await page.locator('.mgroup-title').allInnerTexts();
  const tiles = await page.locator('.mtile').count();
  const alerts = await page.locator('.dash-alert').count();
  const bodyText = await page.locator('.dash-groups').innerText();

  console.log('\n== 分组卡 ==');
  ok(`分组数 = ${wantGroups.length}`, groups.length === wantGroups.length, JSON.stringify(groups));
  ok('指标卡数 ≥ 12', tiles >= 12, String(tiles));
  for (const t of wantGroups) {
    ok('  含分组「' + t + '」', groups.some((g) => g.includes(t)), JSON.stringify(groups));
  }

  console.log('\n== 今日新增 / 近 7 天活跃（本次新能力） ==');
  ok('出现「今日」字样', /今日/.test(bodyText));
  ok('出现「近 7 天活跃」', /近 ?7 ?天活跃/.test(bodyText), bodyText.slice(0, 0) || '');

  console.log('\n== 异常提醒条（无异常时不该占位） ==');
  console.log(`  当前提醒条数量: ${alerts}${alerts ? '（生产确实有异常，会显示）' : '（无异常，符合预期）'}`);

  console.log('\n== 系统说明（默认收起，展开后校验） ==');
  await page.locator('.dash-doc').getByRole('button', { name: /展开/ }).click();
  await page.waitForSelector('.doc-body .doc-card', { timeout: 10000 });
  const docText = await page.locator('.doc-body').innerText();
  const docCards = await page.locator('.doc-card').count();
  const docIcons = await page.locator('.doc-body .mgroup-ic').count();
  ok('展开后 4 张说明卡（客户端 / 管理台 / 上手 / 注意点）', docCards === 4, String(docCards));
  ok('图标块 4 个（复用仪表盘视觉语言）', docIcons === 4, String(docIcons));
  // 逐条对着"这次为什么说它跟不上"来验：导航形态、内容/存储管理、考勤、iOS 表述
  ok('  内容已更新 · 提到导航形态（标签栏/导航条）', /标签栏|导航条/.test(docText));
  ok('  内容已更新 · 提到消息/文件批量清理', /批量清理/.test(docText));
  ok('  内容已更新 · 提到考勤打卡', /考勤/.test(docText));
  ok('  内容已更新 · iOS 说法准确（开发中，非"后续扩展 Mac"）',
    /iOS/.test(docText) && !/后续扩展/.test(docText));
  ok('  保留上手路径（上手向导 + 分模式开户）', /上手向导/.test(docText) && /工号/.test(docText));
  ok('  保留两个高频注意点', /注意点/.test(docText));
  const docShot = path.join(OUT_DIR, 'sysdoc-prod.png');
  await page.locator('.dash-doc').screenshot({ path: docShot });
  console.log('系统说明区域截图: ' + docShot);

  console.log('\n== 渲染健康度 ==');
  ok('无 JS 运行时异常（白屏就靠这个抓）', pageErrors.length === 0, pageErrors.join(' | '));
  ok('无 console.error', consoleErrors.length === 0, consoleErrors.slice(0, 3).join(' | '));
  ok('无 4xx/5xx 资源', httpErrors.length === 0, httpErrors.slice(0, 3).join(' | '));

  const shot = path.join(OUT_DIR, 'dashboard-v0.15.0-prod.png');
  await page.screenshot({ path: shot, fullPage: true });
  console.log('\n截图: ' + shot);

  await browser.close();
  console.log('\n' + '='.repeat(52));
  console.log(failed ? `失败 ${failed} 项` : '全部通过');
  console.log('='.repeat(52));
  process.exit(failed ? 1 : 0);
})().catch((e) => { console.error('异常中断:', e); process.exit(3); });
