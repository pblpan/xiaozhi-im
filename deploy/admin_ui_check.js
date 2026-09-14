// 管理台「考勤管理」真机渲染验证（v0.13.0 一天 4 次卡）
//
// 为什么必须真渲染：Vue 模板里的运行时错误（computed 引用未定义、null 取属性）
// 在 `vite build` 阶段**不会报**，产物照样生成、bundle grep 也照样能搜到关键词，
// 但页面一打开就是白屏。只有让浏览器真的跑一遍才看得出来。
//
// 用法：
//   XZ_SECRET=<JWT_SECRET> NODE_PATH=<workspace>/node_modules node _admin_att_ui_check.js
const { chromium } = require('playwright-core');

const EDGE = 'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe';
const BASE = 'http://192.168.31.44:3602/admin/';
const SECRET = process.env.XZ_SECRET || '';
const SHOT_DIR = process.env.SHOT_DIR || '.';

// 与 server/src/auth.js 一致：HS256，payload { uid, role }
function b64url(buf) {
  return Buffer.from(buf).toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}
function mintToken(uid, role) {
  const crypto = require('crypto');
  const now = Math.floor(Date.now() / 1000);
  const head = b64url(JSON.stringify({ alg: 'HS256', typ: 'JWT' }));
  const body = b64url(JSON.stringify({ uid, role, iat: now, exp: now + 30 * 86400 }));
  const sig = b64url(crypto.createHmac('sha256', SECRET).update(head + '.' + body).digest());
  return head + '.' + body + '.' + sig;
}

const TABS = [
  ['打卡看板', 'tab-board'],
  ['统计报表', 'tab-report'],
  ['班次与考勤组', 'tab-shift'],
  ['申请审批', 'tab-review'],
  ['考勤设置', 'tab-config'],
];

(async () => {
  if (!SECRET) { console.error('缺 XZ_SECRET'); process.exit(2); }
  const token = mintToken(1, 'admin');

  const browser = await chromium.launch({ executablePath: EDGE, headless: true });
  const ctx = await browser.newContext({ viewport: { width: 1560, height: 1000 } });
  // 免登录：管理台从 localStorage 的 xz_token 取令牌
  await ctx.addInitScript((t) => { localStorage.setItem('xz_token', t); }, token);
  const page = await ctx.newPage();

  const errors = [];
  page.on('console', (m) => { if (m.type() === 'error') errors.push('[console] ' + m.text()); });
  page.on('pageerror', (e) => errors.push('[pageerror] ' + e.message));

  let failed = 0;
  const ok = (name, cond, extra) => {
    console.log((cond ? '  ✓ ' : '  ✗ ') + name + (cond || !extra ? '' : '  → ' + extra));
    if (!cond) failed++;
  };

  console.log('== 打开管理台 ==');
  await page.goto(BASE, { waitUntil: 'networkidle', timeout: 60000 });
  await page.waitForTimeout(1200);

  // 白屏判据：根节点里有没有真实渲染出来的元素
  const rootHtml = await page.evaluate(() => (document.querySelector('#app') || {}).innerHTML || '');
  ok('页面渲染出内容（非白屏）', rootHtml.length > 500, 'html len=' + rootHtml.length);
  // 登录页判据要**精确**：不能拿"页面上有'登录'两个字"来判 ——
  // 内置帮助文档里就写着"首次登录"，那样必然误报。只认登录卡片本身。
  const loginCard = await page.locator('.login-wrap, .login-card').count();
  const aside = await page.locator('.aside, .el-menu').count();
  ok('已登录（不在登录页）', loginCard === 0 && aside > 0,
    `loginCard=${loginCard} menu=${aside}`);

  console.log('\n== 进入「考勤管理」 ==');
  await page.click('text=考勤管理');
  await page.waitForTimeout(1500);
  const body0 = await page.innerText('body').catch(() => '');
  ok('考勤管理页已打开', /考勤管理/.test(body0) && !/Cannot read|undefined is not/.test(body0));

  for (const [label, slug] of TABS) {
    console.log('\n== 标签页：' + label + ' ==');
    const el = page.locator(`.el-tabs__item:has-text("${label}")`).first();
    if (await el.count() === 0) { ok(label + ' 标签存在', false, '找不到标签'); continue; }
    await el.click();
    await page.waitForTimeout(1600);
    const txt = await page.innerText('body').catch(() => '');
    ok(label + ' 标签可点开且渲染出内容', txt.length > 200, 'len=' + txt.length);
    // 4 次卡的关键 UI 证据
    if (label === '班次与考勤组') {
      ok('  含「一天几次卡」列', txt.includes('一天几次卡'), '');
      ok('  含午休窗口提示', txt.includes('午休'), '');
    }
    if (label === '打卡看板') ok('  含「今日打卡」列', txt.includes('今日打卡'), '');
    if (label === '统计报表') ok('  含「漏打卡」列', txt.includes('漏打卡'), '');
    if (label === '考勤设置') {
      ok('  含「默认班次 午休」字段', txt.includes('午休'), '');
      ok('  含「清空（改回 2 次卡）」按钮', txt.includes('清空'), '');
    }
    await page.screenshot({ path: `${SHOT_DIR}/admin-${slug}.png`, fullPage: true }).catch(() => {});
  }

  console.log('\n== 控制台错误 ==');
  if (errors.length === 0) console.log('  （无）');
  else errors.forEach((e) => console.log('  ! ' + e));
  ok('渲染期间无控制台/页面错误', errors.length === 0, errors.slice(0, 4).join(' | '));

  await browser.close();
  console.log('\n' + (failed ? `失败 ${failed} 项` : '全部通过'));
  process.exit(failed ? 1 : 0);
})().catch((e) => { console.error('异常中断:', e); process.exit(3); });
