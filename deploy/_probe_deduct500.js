// 复现：GET /admin/apps/warehouse_deduct 500 的根因。
// 逐块调用路由里的每个依赖，看哪一块抛异常。
const appdata = require('/app/src/appdata.js');
const appguard = require('/app/src/appguard.js');
const appoverrides = require('/app/src/appoverrides.js');
const appmodules = require('/app/src/appmodules.js');

function tryStep(name, fn) {
  try {
    const r = fn();
    console.log('  OK   ' + name);
    return r;
  } catch (e) {
    console.log('  THROW ' + name + '  → ' + e.message);
    return null;
  }
}

const m = tryStep('appdata.metricsOf("warehouse_deduct")', () => appdata.metricsOf('warehouse_deduct'));
if (m) console.log('       metrics=' + JSON.stringify(m.items.map(i => i.key)) + ' warnings=' + m.warnings.length);

tryStep('appguard.rulesOf("warehouse_deduct")', () => appguard.rulesOf('warehouse_deduct'));
tryStep('appoverrides.view("warehouse_deduct")', () => appoverrides.view('warehouse_deduct', { visibleIds: ['warehouse_deduct'] }));

const s = tryStep('appdata.sourcesOf("warehouse_deduct")', () => appdata.sourcesOf('warehouse_deduct'));
if (s) console.log('       sources=' + JSON.stringify(s));
else {
  // 把原始条目打出来看形状
  const raw = (appdata.APPS['warehouse_deduct'] || {}).sources;
  console.log('       raw sources = ' + JSON.stringify(raw));
}
tryStep('appdata.purgeablesOf("warehouse_deduct")', () => appdata.purgeablesOf('warehouse_deduct'));
