// 线上实测：容器里跑的这份代码，到底有没有把「库房减货」下发出去
// 由 deploy/_exec_in_container.py 拷进容器后 node 执行。
const fsm = require('fs');

const SRC = '/app/src';
let pass = 0, bad = 0;
const ok = (n, c, d) => { c ? (pass++, console.log('  ✓ ' + n + (d ? ' — ' + d : '')))
                            : (bad++, console.log('  ✗ ' + n + (d ? ' — ' + d : ''))); };

/* ① 容器里的版本 */
let ver = '?';
for (const p of ['/app/package.json', '/app/src/package.json']) {
  try { ver = JSON.parse(fsm.readFileSync(p, 'utf8')).version; console.log('  版本来源 ' + p); break; } catch (e) {}
}
ok('容器内服务端版本 = 0.21.1', ver === '0.21.1', '实际 ' + ver);

/* ② 三个注册表都真的含 warehouse_deduct */
const apps = require(SRC + '/apps.js');
const guard = require(SRC + '/appguard.js');
const data = require(SRC + '/appdata.js');

const def = apps.BUILTIN_APPS.find((a) => a.id === 'warehouse_deduct');
ok('apps.js BUILTIN_APPS 有 warehouse_deduct', !!def, JSON.stringify(def || null));
ok('  名字叫「库房减货」', def && def.title === '库房减货', def && def.title);
ok('  图标 shopping_cart', def && def.icon === 'shopping_cart', def && def.icon);
ok('  分组 work', def && def.group === 'work', def && def.group);

const gi = apps.BUILTIN_APPS.findIndex((a) => a.id === 'warehouse_deduct');
const ii = apps.BUILTIN_APPS.findIndex((a) => a.id === 'inventory');
ok('  排在「盘点」后面一位（工作台顺序）', gi === ii + 1, 'inventory@' + ii + ' warehouse_deduct@' + gi);

ok('appguard.js 有登记（RULES 或 LOCAL_ONLY）',
   Object.prototype.hasOwnProperty.call(guard.RULES, 'warehouse_deduct') ||
   Object.prototype.hasOwnProperty.call(guard.LOCAL_ONLY, 'warehouse_deduct'),
   guard.LOCAL_ONLY.warehouse_deduct ? 'LOCAL_ONLY（纯离线，符合预期）' : JSON.stringify(Object.keys(guard.RULES).filter(k=>k.includes('deduct'))));

const ap = (data.APPS || {}).warehouse_deduct;
ok('appdata.js APPS 有登记', !!ap, ap ? ('localOnly=' + !!ap.localOnly) : '没有');

/* ③ 真走一遍下发逻辑：员工 + 工作模式，看清单里有没有它
 *
 * ⚠️ 入参键是 `friendMode`（值 'work'），**不是 `workMode`** —— `workMode` 是
 *    BUILTIN_APPS 里 need 的字段名，是"定义"；listFor 收的是"状态"。
 *    第一版把状态键写成 workMode，函数收不到 friendMode，于是所有 workMode
 *    应用全被过滤掉、清单为空。**踩坑记录：这回是探针自己错，不是线上错**
 *    —— 所以下面先断言清单非空，否则"停用后消失"就是一句恒真的废话。 */
const EMP = { friendMode: 'work', attendanceEnabled: true, hasOrg: true, role: 'employee' };
const list = apps.listFor(EMP, {});
const ids = list.map((a) => a.id);
console.log('  员工工作台下发清单：' + ids.join(','));
ok('🔴 员工工作台清单非空（后面的判据全靠它，空了就恒真）', ids.length > 0, ids.length + ' 项');
ok('🔴 员工工作台清单里有 warehouse_deduct', ids.includes('warehouse_deduct'),
   ids.includes('warehouse_deduct') ? '有入口' : '**没下发 → 手机上就是找不到**');

/* ④ 停用开关真的只影响入口（后端口径） */
const off = apps.listFor(EMP, { warehouse_deduct: { disabled: true } }).map((a) => a.id);
ok('  管理员停用后它从清单消失（且其余仍在）',
   !off.includes('warehouse_deduct') && off.length === ids.length - 1,
   off.join(','));

/* ⑤ 图标必须在白名单里（否则客户端渲染不出来） */
try {
  const mods = require(SRC + '/appmodules.js');
  const icons = mods.ICONS || {};
  const has = Array.isArray(icons) ? icons.includes('shopping_cart')
                                   : Object.prototype.hasOwnProperty.call(icons, 'shopping_cart');
  ok('appmodules.js 图标白名单含 shopping_cart', has, Array.isArray(icons) ? icons.length + ' 个图标' : Object.keys(icons).length + ' 个图标');
} catch (e) {
  ok('appmodules.js 图标白名单含 shopping_cart', false, e.message);
}

console.log('\n线上实测结果：' + pass + ' / ' + (pass + bad));
process.exit(bad ? 1 : 0);
