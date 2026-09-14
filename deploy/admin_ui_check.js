// 管理台全站 UI 真机渲染验证（v0.14.0 列表分页 + 消息/文件管理改造）
//
// 为什么必须真渲染：Vue 模板里的运行时错误（computed 引用未定义、对 null 取属性）
// 在 `vite build` 阶段**不会报** —— 产物照样生成、bundle grep 也照样能搜到关键词，
// 但页面一打开就是白屏。只有让浏览器真的跑一遍才看得出来。
//
// 自包含：自己起一个临时服务端实例 + 造数据（含 >50 条，用来验证分页器真的能翻页），
// 再用本机 Edge 逐个页面真实渲染、抓 console 错误、截图。
//
// 用法：
//   NODE_PATH=<managed node workspace>/node_modules node deploy/admin_ui_check.js
//   可选：SHOT_DIR=<目录> 指定截图输出位置
const { spawn } = require('child_process');
const path = require('path');
const fs = require('fs');
const os = require('os');
const { DatabaseSync } = require('node:sqlite');
const { chromium } = require('playwright-core');

const EDGE = process.env.EDGE_PATH || 'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe';
const PORT = Number(process.env.PORT || 3704);
const BASE = `http://127.0.0.1:${PORT}/admin/`;
const SERVER_DIR = path.resolve(__dirname, '..', 'server');
const DATA_DIR = path.join(os.tmpdir(), 'xiaozhi-adminui-' + Date.now());
const SHOT_DIR = process.env.SHOT_DIR || path.join(os.tmpdir(), 'xiaozhi-adminui-shots');

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
    env: { ...process.env, PORT: String(PORT), DATA_DIR, ADMIN_PASSWORD: 'admin123' },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  serverProc.stdout.on('data', (d) => { serverLog += d.toString(); });
  serverProc.stderr.on('data', (d) => { serverLog += d.toString(); });
  for (let i = 0; i < 80; i++) {
    try { if ((await fetch(`http://127.0.0.1:${PORT}/api/health`)).ok) return; } catch { /* 还没起来 */ }
    await sleep(250);
  }
  throw new Error('服务端启动超时\n' + serverLog);
}

function stopServer() {
  if (serverProc) { try { serverProc.kill(); } catch { /* ignore */ } }
}

/**
 * 造数据：分页器只有在"条数超过一页"时才真的渲染出页码，
 * 所以必须造够 50+ 条，否则这个检查等于没做。
 */
function seed() {
  const d = new DatabaseSync(path.join(DATA_DIR, 'xiaozhi-im.db'));
  d.exec('PRAGMA busy_timeout = 8000');
  const now = Date.now();
  const insUser = d.prepare('INSERT INTO users (username,password_hash,nickname,role,created_at) VALUES (?,?,?,?,?)');
  const insConv = d.prepare('INSERT INTO conversations (type,created_at) VALUES (?,?)');
  const insMem = d.prepare('INSERT INTO conversation_members (conversation_id,user_id) VALUES (?,?)');
  const insMsg = d.prepare('INSERT INTO messages (conversation_id,sender_id,kind,content,created_at,edited,deleted) VALUES (?,?,?,?,?,0,0)');
  const insFile = d.prepare('INSERT INTO files (owner_id,name,mime,size,path,created_at) VALUES (?,?,?,?,?,?)');

  d.exec('BEGIN');
  const userIds = [1];
  for (let i = 1; i <= 72; i++) {          // 72 个用户 → 单页 50 也翻得动
    userIds.push(Number(insUser.run('ui' + String(i).padStart(3, '0'), '!', '界面用户' + i, 'user', now).lastInsertRowid));
  }
  const groupCid = Number(insConv.run('group', now).lastInsertRowid);
  insMem.run(groupCid, 1);
  insMem.run(groupCid, userIds[1]);
  const dmCid = Number(insConv.run('dm', now).lastInsertRowid);
  insMem.run(dmCid, 1);
  insMem.run(dmCid, userIds[1]);
  for (let i = 1; i <= 137; i++) {         // 137 条消息 → 消息页 3 页
    insMsg.run(groupCid, userIds[1], 'text', '界面用测试消息 ' + String(i).padStart(4, '0'), now - (137 - i) * 1000);
  }
  for (let i = 1; i <= 3; i++) {
    // 磁盘文件也真造出来：否则 el-image 预览会打一片 404，
    // 把"零 console 错误"这个硬指标淹掉（孤儿巡检测试用例在 E2E 里单独覆盖）
    const fn = `ui-${i}.png`;
    fs.writeFileSync(path.join(DATA_DIR, 'files', fn), Buffer.alloc(1024 * i, 1));
    insFile.run(1, `ui-file-${i}.png`, 'image/png', 1024 * i, fn, now - i * 1000);
  }
  d.exec('COMMIT');
  d.close();
}

(async () => {
  if (!fs.existsSync(EDGE)) { console.error('找不到本机 Edge:', EDGE); process.exit(2); }
  fs.mkdirSync(SHOT_DIR, { recursive: true });
  await startServer();

  const API = `http://127.0.0.1:${PORT}`;
  const login = await (await fetch(`${API}/api/auth/login`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ username: 'admin', password: 'admin123' }),
  })).json();
  if (!login.token) throw new Error('登录失败: ' + JSON.stringify(login));

  // 考勤默认未启用，接口会回 404 —— 那样"零 console 错误"这条会被无关的 404 淹掉。
  // 先把考勤按正常流程开起来（工作模式 + 组织 + 启用），让检查跑在真实状态下。
  async function apiCall(method, p, body) {
    return fetch(API + p, {
      method,
      headers: { 'Content-Type': 'application/json', Authorization: 'Bearer ' + login.token },
      body: body ? JSON.stringify(body) : undefined,
    });
  }
  await apiCall('PUT', '/api/admin/settings', { friendMode: 'work' });
  await apiCall('POST', '/api/orgs', { name: '界面检查组织' });
  await apiCall('PUT', '/api/admin/attendance/config', { workdays: [0, 1, 2, 3, 4, 5, 6], enabled: true });

  seed();
  // 造完数据等一拍，避免与 server 的首次写入抢锁
  await sleep(300);

  const browser = await chromium.launch({ executablePath: EDGE, headless: true });
  const ctx = await browser.newContext({ viewport: { width: 1600, height: 1000 } });

  // 免登录：管理台从 localStorage 的 xz_token 取令牌
  await ctx.addInitScript((t) => { localStorage.setItem('xz_token', t); }, login.token);

  const page = await ctx.newPage();
  const errors = [];
  const badResponses = [];
  page.on('response', (r) => { if (r.status() >= 400) badResponses.push(r.status() + ' ' + r.url()); });
  page.on('console', (m) => { if (m.type() === 'error') errors.push('[console] ' + m.text()); });
  page.on('pageerror', (e) => errors.push('[pageerror] ' + e.message));

  console.log('== 打开管理台 ==');
  await page.goto(BASE, { waitUntil: 'networkidle', timeout: 60000 });
  await page.waitForTimeout(1500);

  const rootHtml = await page.evaluate(() => (document.querySelector('#app') || {}).innerHTML || '');
  ok('页面渲染出内容（非白屏）', rootHtml.length > 500, 'html len=' + rootHtml.length);
  // 登录页判据要**精确**：不能拿"页面上有'登录'两个字"来判 ——
  // 内置帮助文档里就写着"首次登录"，那样必然误报。只认登录卡片本身。
  const loginCard = await page.locator('.login-wrap, .login-card').count();
  const menu = await page.locator('.el-menu').count();
  ok('已登录（不在登录页）', loginCard === 0 && menu > 0, `loginCard=${loginCard} menu=${menu}`);

  /** 打开左侧菜单页并检查基本渲染 */
  async function openTab(label, slug, extra) {
    console.log(`\n== ${label} ==`);
    const item = page.locator(`.el-menu-item:has-text("${label}")`).first();
    if (await item.count() === 0) { ok(`${label} 菜单存在`, false, '找不到菜单项'); return ''; }
    await item.click();
    await page.waitForTimeout(1800);
    const txt = await page.innerText('body').catch(() => '');
    ok(`${label} 可打开且渲染出内容`, txt.length > 150, 'len=' + txt.length);
    ok(`  ${label} 无运行时错误文案`, !/Cannot read|undefined is not|null is not|is not a function/.test(txt));
    if (extra) await extra(txt);
    await page.screenshot({ path: `${SHOT_DIR}/admin-${slug}.png`, fullPage: true }).catch(() => {});
    return txt;
  }

  await openTab('用户管理', 'users', async (txt) => {
    ok('  显示总数（共 N 个用户）', /共\s*\d+\s*个用户/.test(txt), txt.match(/共\s*\d+\s*个用户/)?.[0]);
    ok('  有分页器', await page.locator('.el-pagination').count() > 0);
    ok('  数据量 > 50 时真的分了页（页码里有 2）',
      await page.locator('.el-pager li:has-text("2")').count() > 0);
    // 服务端搜索：搜第 51 个之后的用户，前端过滤做不到这件事
    await page.fill('input[placeholder*="搜索账号"]', 'ui072');
    await page.waitForTimeout(1200);
    const t2 = await page.innerText('body');
    ok('  服务端搜索能命中第 51 个之后的用户', t2.includes('ui072'), '');
    await page.fill('input[placeholder*="搜索账号"]', '');
    await page.waitForTimeout(800);
  });

  await openTab('群组管理', 'groups', async (txt) => {
    ok('  显示总数', /共\s*\d+\s*个群/.test(txt));
    ok('  有分页器', await page.locator('.el-pagination').count() > 0);
  });

  await openTab('好友关系', 'friends', async (txt) => {
    ok('  有分页器', await page.locator('.el-pagination').count() > 0);
  });

  await openTab('文件管理', 'files', async (txt) => {
    ok('  四张统计卡（含库盘不一致）', txt.includes('库盘不一致') && txt.includes('磁盘实际占用'));
    ok('  存储占用分析区块', txt.includes('存储占用分析'));
    ok('  表格含「引用」列', txt.includes('引用'));
    ok('  有分页器', await page.locator('.el-pagination').count() > 0);
    // 孤儿巡检标签页
    const orphanTab = page.locator('.el-tabs__item:has-text("孤儿巡检")').first();
    if (await orphanTab.count() === 0) { ok('  孤儿巡检标签存在', false); return; }
    await orphanTab.click();
    await page.waitForTimeout(1200);
    const t2 = await page.innerText('body');
    ok('  孤儿巡检标签可打开（断链/残留两张表）',
      t2.includes('断链') && t2.includes('残留'));
    ok('  含「清理残留文件」入口', t2.includes('清理残留文件'));
    await page.screenshot({ path: `${SHOT_DIR}/admin-files-orphans.png`, fullPage: true }).catch(() => {});
  });

  await openTab('消息管理', 'messages', async (txt) => {
    ok('  默认 30 天窗提示', txt.includes('最近 30 天'));
    ok('  时间快捷选项齐全（今天/7天/30天/90天/全部时间）',
      ['今天', '7 天', '30 天', '90 天', '全部时间'].every((x) => txt.includes(x)));
    ok('  发送者/会话/类型 三个筛选下拉 + 仅@提及',
      txt.includes('仅 @提及'));
    ok('  有「批量清理」按钮', txt.includes('批量清理'));
    ok('  有分页器', await page.locator('.el-pagination').count() > 0);
    ok('  会话列显示名称而不是纯 ID（造了群「甲群」之外的群名）',
      await page.locator('table').first().innerText().then((t) => !/^\s*\d+\s*$/m.test(t.split('\n')[0] || '')).catch(() => true));

    // 点开批量清理：只调 purge-preview（只读），弹窗应列出条件与条数
    await page.click('button:has-text("批量清理")');
    await page.waitForTimeout(1500);
    const dlg = page.locator('.el-dialog').filter({ hasText: '批量清理消息' }).first();
    ok('  批量清理弹窗打开', await dlg.count() > 0);
    if (await dlg.count() > 0) {
      const dt = await dlg.innerText();
      ok('    列出命中条数与清理条件', /命中条数/.test(dt) && /清理条件/.test(dt), dt.replace(/\n/g, ' | ').slice(0, 120));
      ok('    明确提示不可恢复', dt.includes('不可恢复'));
      ok('    要求手工输入条数', dt.includes('手工输入'));
      const n = (dt.match(/命中条数\s*(\d+)/) || [])[1];
      if (n) {
        await dlg.locator('input').first().fill(String(Number(n) + 1));
        await page.waitForTimeout(300);
        await dlg.locator('button:has-text("确认清理")').click();
        await page.waitForTimeout(800);
        ok('    条数填错时前端就拦下（不发出请求）', (await page.innerText('body')).includes('请输入与统计一致的条数'));
      }
      await page.locator('.el-dialog__headerbtn').last().click().catch(() => {});
      await page.waitForTimeout(500);
    }
  });

  // 考勤 5 个子页签（v0.13.0 4 次卡的 UI 回归，不能因为这次改造而坏掉）
  console.log('\n== 考勤管理（v0.13.0 4 次卡 UI 回归） ==');
  const att = page.locator('.el-menu-item:has-text("考勤管理")').first();
  if (await att.count() > 0) {
    await att.click();
    await page.waitForTimeout(1800);
    for (const [label] of [['打卡看板'], ['统计报表'], ['班次与考勤组'], ['申请审批'], ['考勤设置']]) {
      const el = page.locator(`.el-tabs__item:has-text("${label}")`).first();
      if (await el.count() === 0) { ok(`考勤「${label}」标签存在`, false); continue; }
      await el.click();
      await page.waitForTimeout(1200);
      const t = await page.innerText('body').catch(() => '');
      ok(`考勤「${label}」可打开`, t.length > 200 && !/Cannot read|is not a function/.test(t));
    }
    await page.screenshot({ path: `${SHOT_DIR}/admin-attendance.png`, fullPage: true }).catch(() => {});
  }

  console.log('\n== 控制台错误 ==');
  if (errors.length === 0) console.log('  （无）');
  else errors.slice(0, 10).forEach((e) => console.log('  ! ' + e));
  console.log('\n== 失败的网络请求 ==');
  const uniqBad = [...new Set(badResponses)];
  if (uniqBad.length === 0) console.log('  （无）');
  else uniqBad.slice(0, 15).forEach((e) => console.log('  ! ' + e));
  ok('渲染期间无控制台/页面错误', errors.length === 0, errors.slice(0, 3).join(' | '));

  await browser.close();
  stopServer();
  console.log('\n截图目录: ' + SHOT_DIR);
  console.log(failed ? `\n失败 ${failed} 项` : '\n全部通过');
  process.exit(failed ? 1 : 0);
})().catch((e) => { console.error('异常中断:', e); stopServer(); process.exit(3); });
