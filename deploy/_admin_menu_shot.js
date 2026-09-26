// 管理台侧栏菜单（分类折叠）真实浏览器渲染 + 断言
//
//   NODE_PATH=C:\Users\pblpa\.workbuddy\binaries\node\workspace\node_modules \
//     node deploy/_admin_menu_shot.js
//
// 为什么要有这个：菜单折叠全是 CSS + Element Plus 内部行为，**光看构建成功没用**。
// 上一版 19 项平铺就是这么翻的车 —— 构建绿、产物里有菜单、但在 900px 高的屏幕上
// 底部 3 项永远点不到。所以这里必须起真浏览器、量真像素。
//
// 做法：本地起一个桩服务把 server/public 挂上，/api/* 一律回桩数据，
// 再把 token 直接塞进 localStorage 跳过登录 —— 不碰线上、不改任何密码。
const http = require('http');
const fs = require('fs');
const path = require('path');
const os = require('os');
const { chromium } = require('playwright-core');

const EDGE = process.env.EDGE_PATH
  || 'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe';
const ROOT = path.resolve(__dirname, '..', 'server', 'public');
const SHOT_DIR = process.env.SHOT_DIR || path.join(os.tmpdir(), 'xz-admin-menu');

// 视口刻意取 1366x768（最常见的笔记本 / 一体机分辨率），
// 就是上一版菜单被截断的那个尺寸。
const VIEWPORT = { width: 1366, height: 768 };

let failed = 0;
const ok = (n, c, x) => {
  console.log((c ? '  \u2713 ' : '  \u2717 ') + n + (c || !x ? '' : '  \u2192 ' + x));
  if (!c) failed++;
};

// ---- 桩数据：够让 App.vue 渲染出侧栏就行，不追求业务正确 ----
function stub(urlPath) {
  if (urlPath === '/license') {
    return {
      ok: true, mode: 'perpetual', perpetual: true, daysLeft: null, machineCode: 'STUB',
      // fingerprint.hint 被授权页直接取用（licenseState.fingerprint.hint），少了会白屏报错
      fingerprint: { hint: '桩数据', machineCode: 'STUB' },
    };
  }
  if (urlPath === '/admin/stats') return { users: 0, groups: 0, messages: 0 };
  if (urlPath === '/admin/info') return { version: '0.21.3', uptime: 1 };
  if (urlPath === '/admin/settings') return { companyName: '', friendMode: 'normal' };
  if (urlPath === '/admin/turn') return { configured: false };
  if (urlPath === '/admin/users/options') return [];
  if (urlPath === '/setup/status') return { needSetup: false };
  // 列表类统一给空分页结构，避免 .map / .filter 炸在 undefined 上
  if (/\/admin\/(users|groups|friendships|orgs|files|messages|integrations|upstreams)/.test(urlPath)) {
    return { items: [], list: [], total: 0, page: 1, pageSize: 20 };
  }
  return {};
}

function serve() {
  const MIME = {
    '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8',
    '.css': 'text/css; charset=utf-8', '.png': 'image/png', '.svg': 'image/svg+xml',
    '.ico': 'image/x-icon', '.woff2': 'font/woff2', '.json': 'application/json',
  };
  return new Promise((resolve) => {
    const srv = http.createServer((req, res) => {
      const urlPath = decodeURIComponent(req.url.split('?')[0]);
      if (urlPath.startsWith('/api/')) {
        res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
        res.end(JSON.stringify(stub(urlPath.slice(4))));
        return;
      }
      let rel = urlPath.replace(/^\/admin\/?/, '') || 'index.html';
      let f = path.join(ROOT, rel);
      if (!fs.existsSync(f) || fs.statSync(f).isDirectory()) f = path.join(ROOT, 'index.html');
      const ext = path.extname(f).toLowerCase();
      res.writeHead(200, { 'Content-Type': MIME[ext] || 'application/octet-stream' });
      res.end(fs.readFileSync(f));
    });
    srv.listen(0, '127.0.0.1', () => resolve(srv));
  });
}

(async () => {
  fs.mkdirSync(SHOT_DIR, { recursive: true });
  const srv = await serve();
  const base = 'http://127.0.0.1:' + srv.address().port;
  console.log('[桩服务] ' + base + '  <- ' + ROOT);

  const browser = await chromium.launch({ executablePath: EDGE, headless: true });
  const ctx = await browser.newContext({ viewport: VIEWPORT });
  const page = await ctx.newPage();

  const errs = [];
  page.on('console', (m) => { if (m.type() === 'error') errs.push('console: ' + m.text()); });
  page.on('pageerror', (e) => errs.push('pageerror: ' + e.message));

  // 跳过登录：直接把 token 写进 localStorage（api.js 只认这个 key）
  await ctx.addInitScript(() => {
    try { localStorage.setItem('xz_token', 'stub-token'); } catch (e) {}
  });
  await page.goto(base + '/admin/', { waitUntil: 'domcontentloaded' });
  await page.waitForSelector('.aside-menu', { timeout: 20000 });
  await page.waitForTimeout(900);

  console.log('\n=== 结构 ===');
  const nSub = await page.locator('.aside .el-sub-menu').count();
  const nItem = await page.locator('.aside .el-menu-item').count();
  const nTop = await page.locator('.aside > .aside-menu > .el-menu > .el-menu-item').count();
  const groups = await page.locator('.aside .el-sub-menu > .el-sub-menu__title > span').allInnerTexts();
  ok('侧栏渲染出来了（.aside-menu 存在）', true);
  ok('分类数 = 5', nSub === 5, '实际 ' + nSub);
  ok('菜单项总数 = 19', nItem === 19, '实际 ' + nItem);
  ok('顶层平铺项只有 1 个（仪表盘）', nTop === 1, '实际 ' + nTop);
  ok('分类标题正确', groups.join('/') === '组织与用户/日常办公/对外对接/业务模块/系统', groups.join('/'));

  console.log('\n=== 19 个页面全都在菜单里（一个都不能少）===');
  const want = ['仪表盘', '用户管理', '群组管理', '好友关系', '组织机构', '考勤管理', '文件管理',
    '消息管理', '集成对接', '上游接口', '客户端配置', '消息推送', '商品档案', '库房减货',
    '动态模块', '培训中心', '系统设置', '授权管理', '系统帮助'];
  const texts = (await page.locator('.aside .el-menu-item').allInnerTexts()).map((s) => s.trim());
  const missing = want.filter((w) => !texts.includes(w));
  ok('19 项全部存在', missing.length === 0, '缺: ' + missing.join(','));
  ok('没有重复项', new Set(texts).size === texts.length);

  console.log('\n=== 首屏高度（上一版就是在这里翻车的）===');
  // ⚠️ 判断"展开"要用 .el-sub-menu.is-opened。`.el-menu--inline` 这个 ul 在折叠时
  //    也照样渲染（靠折叠动画把高度压到 0），拿它计数会永远等于分组数。
  const m0 = await page.evaluate(() => {
    const el = document.querySelector('.aside-menu');
    const items = Array.from(document.querySelectorAll('.aside .el-menu-item'));
    // ⚠️ 必须从 .aside-menu 直下取，不能写 `.aside .el-menu > *` ——
    //    分类展开时内部会生成嵌套的 <ul class="el-menu el-menu--inline">，
    //    那个选择器会把嵌套 ul 的叶项也当成"顶层块"，末块拿到的是折叠项（高 0），
    //    算出来的内容高会变成负数。
    const blocks = Array.from(document.querySelectorAll('.aside .aside-menu > .el-menu > *'));
    const first = blocks[0].getBoundingClientRect();
    const lastB = blocks[blocks.length - 1].getBoundingClientRect();
    return {
      scroll: el.scrollHeight, client: el.clientHeight,
      viewport: window.innerHeight,
      itemCount: items.length,
      visibleItemCount: items.filter((e) => e.offsetParent !== null).length,
      itemH: items.length ? Math.round(items[0].getBoundingClientRect().height) : 0,
      // 内容真实高度 = 首块 top 到末块 bottom。**不能拿 scrollHeight 代** ——
      // 菜单区是 flex:1，放得下时 scrollHeight 恒等于 clientHeight，看着像没变小。
      contentH: Math.round(lastB.bottom - first.top),
      lastBottom: Math.round(lastB.bottom),
      opened: document.querySelectorAll('.aside .el-sub-menu.is-opened').length,
    };
  });
  ok('首屏分组默认全收起', m0.opened === 0, '展开了 ' + m0.opened + ' 组');
  ok('首屏可见项 = 1（只剩仪表盘）', m0.visibleItemCount === 1, '实际 ' + m0.visibleItemCount);
  ok('首屏不需要滚动就放得下', m0.scroll <= m0.client + 2, 'scroll=' + m0.scroll + ' client=' + m0.client);
  ok('最后一个可见项在视口内', m0.lastBottom !== null && m0.lastBottom <= m0.viewport,
    'bottom=' + m0.lastBottom + ' viewport=' + m0.viewport);

  // 旧版（19 项平铺）的高度换算：行高 × 19 + 上下留白。
  // 上一版内容高 ≈ 1084px，而 768px 屏上菜单区只有约 660px —— 差 425px，
  // 正好 7 个菜单项（56px 一个）。这就是"管理都看不到"的量化解释，
  // 留着这行数字，以后谁改小行高都能看到地板在哪。
  const flatH = m0.itemH * 19 + 20;
  const shrink = (1 - m0.contentH / flatH) * 100;
  console.log('   （修复前：19 项平铺 ≈ ' + flatH + 'px ，菜单区只有 ' + m0.client
    + 'px → 约 ' + Math.round((flatH - m0.client) / m0.itemH) + ' 个菜单项被吃掉、点不到）');
  console.log('   （修复后：首屏内容高 ' + m0.contentH + 'px，行高 ' + m0.itemH
    + 'px，收窄 ' + shrink.toFixed(0) + '%，scrollHeight=' + m0.scroll
    + ' clientHeight=' + m0.client + '）');
  ok('修复后内容高不到平铺方案的一半', m0.contentH * 2 < flatH,
    m0.contentH + ' vs ' + flatH);
  ok('修复后连最长的分组展开也塞得下（1+4 行）',
    (m0.itemH * 5 + 20) <= m0.client, '需要 ' + (m0.itemH * 5 + 20) + 'px，只有 ' + m0.client);

  console.log('\n=== 展开「系统」：三项都点得到 ===');
  await page.locator('.aside .el-sub-menu__title', { hasText: '系统' }).first().click();
  await page.waitForTimeout(500);
  const sysVisible = await page.evaluate(() => {
    const out = [];
    document.querySelectorAll('.aside .el-menu-item').forEach((el) => {
      const r = el.getBoundingClientRect();
      const nm = el.innerText.trim();
      if (['系统设置', '授权管理', '系统帮助'].includes(nm)) {
        out.push({ nm, top: Math.round(r.top), bottom: Math.round(r.bottom), h: Math.round(r.height) });
      }
    });
    return out;
  });
  ok('展开后三项都渲染了', sysVisible.length === 3, JSON.stringify(sysVisible));
  const allIn = sysVisible.every((x) => x.top >= 0 && x.bottom <= VIEWPORT.height && x.h > 20);
  ok('三项都完整落在视口内（可见可点）', allIn, JSON.stringify(sysVisible));

  console.log('\n=== unique-opened：同时只展开一组 ===');
  await page.locator('.aside .el-sub-menu__title', { hasText: '业务模块' }).first().click();
  await page.waitForTimeout(500);
  const openedNow = await page.locator('.aside .el-sub-menu.is-opened').count();
  const bizOpen = await page.evaluate(() => {
    const el = document.querySelector('.aside .el-sub-menu.is-opened');
    return el ? el.querySelector('.el-sub-menu__title').innerText.trim() : null;
  });
  ok('展开业务模块后只剩 1 组开着', openedNow === 1, '实际 ' + openedNow + ' 组');
  ok('开着的那组正是业务模块', bizOpen === '业务模块', String(bizOpen));
  // 侧栏总行数恒定，这是"不会再变长"的硬证据
  const rowsNow = await page.evaluate(() =>
    Array.from(document.querySelectorAll('.aside .el-menu-item')).filter((e) => e.offsetParent !== null).length);
  ok('展开后可见项 = 1 平铺 + 4 叶项 = 5', rowsNow === 5, '实际 ' + rowsNow);

  console.log('\n=== 跨页跳转要自动撑开父分组（defaultActive 不负责展开）===');
  // 顶栏授权标签 @click="tab='license'" —— 这是典型的"从别处跳进来"。
  // 如果只靠 :default-active，高亮会到「授权管理」但分组是收着的，看起来像没反应。
  await page.locator('.hdr .el-tag').last().click();
  await page.waitForTimeout(600);
  const jump = await page.evaluate(() => {
    const act = document.querySelector('.aside .el-menu-item.is-active');
    const openTitles = Array.from(document.querySelectorAll('.aside .el-sub-menu.is-opened > .el-sub-menu__title'))
      .map((e) => e.innerText.trim());
    return { active: act ? act.innerText.trim() : null, openTitles };
  });
  ok('高亮跳到了「授权管理」', jump.active === '授权管理', String(jump.active));
  ok('「系统」分组被自动撑开', jump.openTitles.includes('系统'), JSON.stringify(jump.openTitles));
  await page.screenshot({ path: path.join(SHOT_DIR, 'jump-to-license.png') });

  console.log('\n=== 小屏兜底：菜单区必须能滚（或者本来就放得下）===');
  await page.setViewportSize({ width: 1024, height: 600 });
  await page.waitForTimeout(400);
  const small = await page.evaluate(() => {
    const el = document.querySelector('.aside-menu');
    const cs = getComputedStyle(el);
    el.scrollTop = 9999;
    const scrolled = el.scrollTop;
    el.scrollTop = 0;
    const items = Array.from(document.querySelectorAll('.aside .el-menu-item'))
      .filter((e) => e.offsetParent !== null);
    const last = items.length ? items[items.length - 1].getBoundingClientRect() : null;
    return {
      overflowY: cs.overflowY, scrolled,
      scroll: el.scrollHeight, client: el.clientHeight,
      lastBottom: last ? Math.round(last.bottom) : null, vh: window.innerHeight,
    };
  });
  const fits = small.lastBottom !== null && small.lastBottom <= small.vh;
  ok('600px 高时要么放得下、要么滚得到', small.overflowY === 'auto' && (fits || small.scrolled > 0),
    JSON.stringify(small));
  console.log('   ' + (fits ? '（600px 下全部内容仍放得下，滚动条是兜底不是必需）'
    : '（内容超出，靠滚动可达）'));

  await page.setViewportSize(VIEWPORT);
  await page.waitForTimeout(300);
  await page.locator('.aside .el-sub-menu__title', { hasText: '业务模块' }).first().click();
  await page.waitForTimeout(500);
  await page.screenshot({ path: path.join(SHOT_DIR, 'menu-open-biz.png') });
  await page.locator('.aside .el-sub-menu__title', { hasText: '业务模块' }).first().click();
  await page.waitForTimeout(400);
  await page.screenshot({ path: path.join(SHOT_DIR, 'menu-collapsed.png') });
  // 侧栏单独来一张，方便肉眼看缩进/配色
  const aside = page.locator('.aside');
  await aside.screenshot({ path: path.join(SHOT_DIR, 'sidebar-only.png') });

  console.log('\n=== 控制台干净 ===');
  ok('没有 pageerror / console.error', errs.length === 0, errs.slice(0, 5).join(' | '));

  console.log('\n=== 逐项几何（地面真值，排查用）===');
  const geo = await page.evaluate(() => {
    const out = [];
    document.querySelectorAll('.aside .aside-menu > .el-menu > *').forEach((el) => {
      const isSub = el.classList.contains('el-sub-menu');
      const title = isSub ? el.querySelector('.el-sub-menu__title') : el;
      const r = title.getBoundingClientRect();
      out.push({
        kind: isSub ? 'SUB ' : 'ITEM',
        name: title.innerText.trim().replace(/\s+/g, ''),
        open: isSub ? el.classList.contains('is-opened') : '-',
        top: Math.round(r.top), h: Math.round(r.height),
      });
    });
    return out;
  });
  geo.forEach((g) => console.log('   ' + g.kind + '  ' + g.top.toString().padStart(4) + 'px  h=' 
    + g.h + '  ' + String(g.open).padEnd(5) + '  ' + g.name));

  console.log('\n截图目录: ' + SHOT_DIR);
  if (errs.length) console.log(errs.join('\n'));
  console.log(failed === 0 ? '\n全部通过' : '\n失败 ' + failed + ' 项');
  await browser.close();
  srv.close();
  process.exit(failed === 0 ? 0 : 1);
})().catch((e) => { console.error('崩了: ' + e.stack); process.exit(2); });
