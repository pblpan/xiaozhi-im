// 审计：对全部内置应用跑 sourcesOf / purgeablesOf / metricsOf，抓出所有会抛异常的条目。
const appdata = require('/app/src/appdata.js');
const apps = require('/app/src/apps.js');
let bad = 0;
for (const a of apps.BUILTIN_APPS) {
  try { appdata.metricsOf(a.id); } catch (e) { bad++; console.log('THROW metricsOf ' + a.id + ' → ' + e.message); }
  try {
    const s = appdata.sourcesOf(a.id);
    for (const one of s) {
      if (!one.key || !one.name || !Array.isArray(one.columns)) {
        bad++; console.log('BADSHAPE sourcesOf ' + a.id + ' → ' + JSON.stringify(one).slice(0, 120));
      }
    }
  } catch (e) { bad++; console.log('THROW sourcesOf ' + a.id + ' → ' + e.message); }
  try { appdata.purgeablesOf(a.id); } catch (e) { bad++; console.log('THROW purgeablesOf ' + a.id + ' → ' + e.message); }
}
console.log(bad === 0 ? 'ALL CLEAN' : ('BAD=' + bad));
