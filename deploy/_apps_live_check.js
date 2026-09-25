// 线上实测：容器里跑的这份代码，内置应用有没有**注册齐**、有没有**下发到员工工作台**。
//
//   python deploy/_exec_in_container.py _apps_live_check.js
//
// 为什么不测 HTTP 而是直接 require('/app/src/*')：
// 验的是"容器里跑的就是这份代码"（版本、注册表、下发逻辑），不需要管理台口令。
// 判据不是"接口回 200"，而是**员工工作台清单里真的出现了那个 id**。
//
// ⚠️ 入参键是 `friendMode`（值 'work'），**不是 `workMode`** —— `workMode` 是
//    BUILTIN_APPS 里 need 的字段名，是"定义"；listFor 收的是"状态"。
//    踩过：状态键写成 workMode → 函数收不到 → 所有 workMode 应用被过滤 → 清单为空，
//    探针报了个"没下发"的假红。所以下面先断言清单非空，否则后面的判据全是恒真的废话。
const fsm = require('fs');

const SRC = '/app/src';
let pass = 0, bad = 0;
const ok = (n, c, d) => { c ? (pass++, console.log('  ✓ ' + n + (d ? ' — ' + d : '')))
                            : (bad++, console.log('  ✗ ' + n + (d ? ' — ' + d : ''))); };

/* ① 容器里的版本 */
let ver = '?';
for (const p of ['/app/package.json', '/app/src/package.json']) {
  try { ver = JSON.parse(fsm.readFileSync(p, 'utf8')).version; console.log('  版本来源 ' + p); break; } catch (e) { /* 换下一个 */ }
}
console.log('  容器内服务端版本 = ' + ver);

const apps = require(SRC + '/apps.js');
const guard = require(SRC + '/appguard.js');
const data = require(SRC + '/appdata.js');
const mods = require(SRC + '/appmodules.js');

const ICONS = mods.ICONS || [];
const APPS = data.APPS || {};
const DEFS = apps.BUILTIN_APPS;

/* ② 每个内置应用：路由归属 + 数据登记 + 图标白名单 —— 一个都不能漏 */
console.log('\n【注册齐不齐】共 ' + DEFS.length + ' 个内置应用');
for (const a of DEFS) {
  // 🔴 `RULES` 是**数组**（元素长这样：{app, scope, label, paths, test}），
  //    不是以 app id 为键的对象 —— 用 hasOwnProperty(RULES, id) 判必然全 false，
  //    第一版就是这么写的，结果给 6 个正常应用报了"没登记"的假红。
  //    判据照抄服务端自检（test/apps_admin_e2e.js）：RULES.some(r => r.app === a.id)。
  const inRules = guard.RULES.some((r) => r.app === a.id);
  const inLocal = Object.prototype.hasOwnProperty.call(guard.LOCAL_ONLY, a.id);
  ok(`${a.id} 有路由归属（RULES 或 LOCAL_ONLY）`, inRules || inLocal,
     inRules ? 'RULES（有服务端接口）' : (inLocal ? 'LOCAL_ONLY（纯离线）' : '**两处都没有 → 停用开关对它无效**'));
  ok(`  ${a.id} 在 appdata 里登记了数据来源`, Object.prototype.hasOwnProperty.call(APPS, a.id),
     APPS[a.id] && APPS[a.id].localOnly ? '纯离线（已在说明里写清为什么没数据）' : '有数据页');
  ok(`  ${a.id} 的图标在服务端白名单里`, ICONS.includes(a.icon),
     ICONS.includes(a.icon) ? a.icon : `**${a.icon} 不在白名单 → 客户端画不出来**`);
}

/* ③ 真走一遍下发逻辑：员工 + 工作模式 */
const EMP = { friendMode: 'work', attendanceEnabled: true, hasOrg: true, role: 'employee' };
const list = apps.listFor(EMP, {});
const ids = list.map((a) => a.id);
console.log('\n【员工工作台下发清单】');
console.log('  ' + ids.join(','));
ok('🔴 清单非空（后面的判据全靠它，空了就恒真）', ids.length > 0, ids.length + ' 项');
for (const a of DEFS) {
  const n = a.need || {};
  // 只对"员工在工作模式下该看到"的那些断言；adminOnly / employee 专属的另说
  if (n.adminOnly) { ok(`  ${a.id}（管理员专属）不下发给员工`, !ids.includes(a.id), ''); continue; }
  ok(`🔴 ${a.id} 下发给员工`, ids.includes(a.id),
     ids.includes(a.id) ? '' : `**没下发 → 手机上就是找不到入口**`);
}

/* ④ 顺序：简易盘点必须紧跟盘点 */
{
  const inv = ids.indexOf('inventory');
  const ss = ids.indexOf('simple_stocktake');
  ok('🔴「简易盘点」紧跟在「盘点」后面（两个都叫盘点，挨着才分得清）',
     inv >= 0 && ss === inv + 1, `inventory@${inv} simple_stocktake@${ss}`);
}

/* ⑤ 停用只是入口口径：停用后从清单消失，且其余仍在（后端口径，不是前端藏图标） */
for (const id of ['warehouse_deduct', 'simple_stocktake']) {
  const off = apps.listFor(EMP, { [id]: { disabled: true } }).map((a) => a.id);
  ok(`  停用 ${id} 后它从清单消失（且其余仍在）`,
     !off.includes(id) && off.length === ids.length - 1,
     `${ids.length} → ${off.length}`);
  const renamed = apps.listFor(EMP, { [id]: { title: '改个名试试' } }).find((a) => a.id === id);
  ok(`  改标题覆盖层对 ${id} 生效（管理台改完客户端零改动就能看到）`,
     renamed && renamed.title === '改个名试试', renamed && renamed.title);
}

console.log('\n线上实测结果：' + pass + ' / ' + (pass + bad));
process.exit(bad ? 1 : 0);
