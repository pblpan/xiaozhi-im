/**
 * 工作台三件套：分组可配 / 应用配色与挪组 / 顶部公告。
 *
 * 这两个文件的行为都不需要起服务端：apps.js、appgroups.js、appoverrides.js 的
 * 写路径都可以在进程内跑完（只有路由层要起服务，见 apps_admin_e2e.js）。
 *
 * 这里盯的四类**静默失效**（不报错、看着能用，但结果错）：
 *   1. 应用级 group/color 覆盖没合进 listFor 的输出（曾经真踩过：管理台改了，
 *      工作台纹丝不动，且不报任何错）；
 *   2. 分组组名清回出厂时写进 label=NULL（撞 NOT NULL，或者留下一个空名字）；
 *   3. 自定义组删掉时没算上"被挪进来的应用"（那些应用会集体消失）；
 *   4. 公告停用后还下发到客户端。
 */
const os = require('os');
const path = require('path');
const fs = require('fs');

const DATA_DIR = path.join(os.tmpdir(), 'xiaozhi-smoke-wb-' + Date.now());
fs.mkdirSync(DATA_DIR, { recursive: true });
process.env.DATA_DIR = DATA_DIR;
process.env.DB_PATH = path.join(DATA_DIR, 't.db');

const appregistry = require('../src/apps');
const appgroups = require('../src/appgroups');
const appoverrides = require('../src/appoverrides');
const appnotice = require('../src/appnotice');

let fail = 0;
const ok = (name, cond, extra) => {
  if (cond) console.log('  ✓ ' + name);
  else { fail++; console.log('  ✗ ' + name + (extra !== undefined ? '  → ' + JSON.stringify(extra) : '')); }
};

console.log('— 出厂分组 —');
ok('DEFAULT_GROUPS 两项', appregistry.DEFAULT_GROUPS.length === 2, appregistry.DEFAULT_GROUPS);
// 🔴 2026-10-04：库房减货/补货撤出工作台（功能收进盘点页）→ 11 - 2 = 9 个；
// e81e626 智能助手（assistant）加入内置应用 → 10 个。
ok('10 个内置应用都有出厂色', appregistry.BUILTIN_APPS.length === 10
  && appregistry.BUILTIN_APPS.every((a) => a.color), appregistry.BUILTIN_APPS.filter((a) => !a.color).map((a) => a.id));
const colors = appregistry.BUILTIN_APPS.map((a) => a.color);
ok('颜色互不重复', new Set(colors).size === colors.length, colors);

console.log('— 分组覆盖 —');
ok('出厂两组', appgroups.list().map((g) => g.key).join(',') === 'work,custom', appgroups.list());
ok('map() 有 label', appgroups.map().work.label === '工作');

const r1 = appgroups.set('shop', { label: '门店作业', sort: 5 }, 'tester');
ok('新建自定义组', !r1.error && r1.group.label === '门店作业', r1);
ok('新组进入 list()', appgroups.list().some((g) => g.key === 'shop'));
ok('forClient 补齐', appgroups.forClient(['shop']).some((g) => g.key === 'shop'));
ok('未知 key 也被补齐（防组头显示英文）', appgroups.forClient(['zzz']).some((g) => g.key === 'zzz'));
const r2 = appgroups.set('work', { label: '办公协同' }, 'tester');
ok('出厂组改名', !r2.error && appgroups.map().work.label === '办公协同', r2);
const r3 = appgroups.set('work', { label: null }, 'tester');
ok('组名清回出厂（删行不写 NULL）', !r3.error && appgroups.map().work.label === '工作', r3);
const r4 = appgroups.set('work', { label: 'x'.repeat(20) }, 'tester');
ok('组名超长被拦', !!r4.error, r4);
const r5 = appgroups.set('Bad Key!', { label: 'x' }, 'tester');
ok('非法 key 被拦', !!r5.error, r5);
const r6 = appgroups.setHidden('shop', true);
ok('收起组', !r6.error && appgroups.map().shop.hidden === true, r6);
const r7 = appgroups.remove('work');
ok('出厂组删不掉', !!r7.error, r7);
console.log('— 应用级 group/color 覆盖 —');
const s1 = appoverrides.set('inventory', { color: '#123456' }, 'tester');
ok('改配色', !s1.error, s1.error);
const c1 = appregistry.listFor({ friendMode: 'work' }, appoverrides.map(), appgroups.map())
  .find((a) => a.id === 'inventory');
ok('清单带 color', c1.color === '#123456', c1);
ok('清单带 groupLabel', c1.groupLabel === '工作', c1);
const s2 = appoverrides.set('inventory', { color: 'red' }, 'tester');
ok('非法配色被拦', !!s2.error, s2.error);
const s3 = appoverrides.set('inventory', { group: 'shop' }, 'tester');
ok('挪到已存在的自定义组', !s3.error, s3.error);
const c2 = appregistry.listFor({ friendMode: 'work' }, appoverrides.map(), appgroups.map())
  .find((a) => a.id === 'inventory');
ok('已挪组（group=shop）', c2.group === 'shop' && c2.groupLabel === '门店作业', c2);
const s4 = appoverrides.set('inventory', { group: 'nope' }, 'tester');
ok('挪到不存在的组被拦', !!s4.error, s4.error);
const r8 = appgroups.remove('shop', appoverrides.map());
ok('挂了应用的自定义组删不掉', !!r8.error, r8);
ok('usageOf 认得挪过去的应用', appgroups.usageOf(appoverrides.map())['shop'] === 1,
  appgroups.usageOf(appoverrides.map()));
const s5 = appoverrides.set('inventory', { color: null, group: null }, 'tester');
ok('清回出厂后不留覆盖行', s5.override === null, s5);
const r9 = appgroups.remove('custom');
ok('出厂组 custom 删不掉', !!r9.error, r9);

console.log('— 动态模块配色（管理台没填也不能全一个色）—');
{
  const { moduleColorOf, MODULE_COLOR_PALETTE } = appregistry;
  // 🔴 这是线上实测抓到的：`daily_sales` 没配 color，客户端会退回品牌色，
  //    于是"所有没配色的模块长得一模一样"。
  const c = moduleColorOf(undefined, 'daily_sales');
  ok('没填配色也有颜色', /^#[0-9A-Fa-f]{6}$/.test(c), c);
  ok('同一个模块每次都是同一个色（刷新一次变一个色比没有更糟）',
     moduleColorOf(undefined, 'daily_sales') === c);
  ok('不同模块尽量分开色（一排同色就白做了）',
     new Set(['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h'].map((k) => moduleColorOf(undefined, k))).size >= 6,
     [...new Set(['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h'].map((k) => moduleColorOf(undefined, k)))]);
  ok('色板不是只有一个色', MODULE_COLOR_PALETTE.length >= 4, MODULE_COLOR_PALETTE.length + ' 色');
  // 管理台的语义枚举（primary/danger/success/…）也要能落到十六进制，
  // 否则模块"选了红色"在工作台上还是显示成品牌色。
  ok('语义色 danger → 十六进制', moduleColorOf('danger', 'x') !== moduleColorOf(undefined, 'x')
     || /^#[0-9A-Fa-f]{6}$/.test(moduleColorOf('danger', 'x')), moduleColorOf('danger', 'x'));
  ok('自由填的 #RRGGBB 原样用', moduleColorOf('#ABCDEF', 'x') === '#ABCDEF');
  ok('脏值（red）也能给个合法色', /^#[0-9A-Fa-f]{6}$/.test(moduleColorOf('red', 'x')));
}

console.log('— 公告 —');
ok('初始为空', appnotice.listEnabled().length === 0);
const n1 = appnotice.add('明天盘点，9 点前归位', 'tester');
ok('新增公告', !n1.error && !!n1.id, n1);
appnotice.add('这周起改成一天 4 次卡', 'tester');
ok('下发 2 条', appnotice.listEnabled().length === 2);
ok('文本上限被拦', !!appnotice.add('x'.repeat(61), 'tester').error);
ok('空文本被拦', !!appnotice.add('   ', 'tester').error);
const u1 = appnotice.update(n1.id, { enabled: false }, 'tester');
ok('停用后下发只剩 1 条', appnotice.listEnabled().length === 1, appnotice.listEnabled());
ok('listAll 仍保留 2 条（管理台列表）', appnotice.listAll().length === 2);
ok('停用项超过 3 条也只下发 3 条', (() => {
  for (let i = 0; i < 5; i++) appnotice.add('测试' + i, 'tester');
  return appnotice.listEnabled().length <= 3;
})());
ok('删除公告', appnotice.remove(n1.id).removed === true);

console.log(fail === 0 ? '\n全部通过' : `\n失败 ${fail} 项`);
try { fs.rmSync(DATA_DIR, { recursive: true, force: true }); } catch {}
process.exit(fail === 0 ? 0 : 1);
