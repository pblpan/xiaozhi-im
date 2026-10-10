// 线上只读探针：列出容器里工作台的真实应用清单（内置 + 自定义模块 + 覆盖 + 分组）。
// 目的：确认是否存在一个叫「超市拣货」的独立入口（内置 / 自定义模块 / 改名覆盖）。
//   python deploy/_exec_in_container.py _probe_live_apps.js
const db = require('/app/src/db');
const apps = require('/app/src/apps.js');

const all = (sql) => { try { return db.prepare(sql).all(); } catch (e) { return ['ERR: ' + e.message]; } };

let ver = '?';
try { ver = JSON.parse(require('fs').readFileSync('/app/package.json', 'utf8')).version; } catch (e) {}
console.log('容器内服务端版本 =', ver);

console.log('\n【内置应用 BUILTIN_APPS】');
for (const a of apps.BUILTIN_APPS) console.log('  ', a.id, '|', a.title, '| icon=' + a.icon, '| group=' + a.group);

console.log('\n【app_modules 自定义模块】rows =', all('SELECT COUNT(*) c FROM app_modules')[0].c);
for (const r of all('SELECT module_id,title,icon,enabled,sort FROM app_modules'))
  console.log('  ', JSON.stringify(r));

console.log('\n【app_overrides 覆盖】rows =', all('SELECT COUNT(*) c FROM app_overrides')[0].c);
for (const r of all('SELECT app_id,title,icon,"group",color,disabled,sort FROM app_overrides'))
  console.log('  ', JSON.stringify(r));

console.log('\n【app_groups 分组】rows =', all('SELECT COUNT(*) c FROM app_groups')[0].c);
for (const r of all('SELECT key,label,sort,hidden,custom FROM app_groups'))
  console.log('  ', JSON.stringify(r));

console.log('\n【workbench_notices 公告】rows =', all('SELECT COUNT(*) c FROM workbench_notices')[0].c);
for (const r of all('SELECT id,text,enabled,sort FROM workbench_notices'))
  console.log('  ', JSON.stringify(r));
