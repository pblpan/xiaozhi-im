// 线上终验：撤图标后的工作台下发 + 参数迁移 + 抽屉状态
const jwt = require('/app/src/auth.js');
const db  = require('/app/src/db.js');
const cfg = require('/app/src/config.js');
const apps = require('/app/src/apps.js');
const admin = db.prepare('SELECT id,username,role FROM users WHERE username=?').get(cfg.ADMIN_USERNAME);
const token = jwt.signToken({ uid: admin.id, role: admin.role });
const H = { Authorization: 'Bearer ' + token };
const J = 'http://127.0.0.1:3602';
(async () => {
  // ① 员工工作台下发（用 admin token 调 client/apps 也能拿清单）
  const r = await fetch(J + '/api/client/apps?clientVersion=0.22.2', { headers: H });
  const list = (await r.json()).apps || [];
  console.log('下发 ' + list.length + ' 个: ' + list.map(a => a.id).join(','));
  console.log('  warehouse_deduct 还在? ' + list.some(a => a.id === 'warehouse_deduct'));
  console.log('  replenish 还在? ' + list.some(a => a.id === 'replenish'));
  const inv = list.find(a => a.id === 'inventory');
  console.log('  inventory.params = ' + JSON.stringify(inv && inv.params));
  // ② 抽屉：撤掉的两个应 404（不是内置应用），其余 200
  for (const id of [...apps.BUILTIN_APPS.map(a => a.id), 'warehouse_deduct', 'replenish']) {
    const rr = await fetch(J + '/api/admin/apps/' + id, { headers: H });
    console.log('  drawer ' + id + ': ' + rr.status);
  }
  // ③ 覆盖层迁移结果
  const rows = db.prepare('SELECT app_id, params FROM app_overrides').all();
  console.log('  app_overrides rows: ' + rows.map(r2 => r2.app_id + '(' + r2.params + ')').join(' | '));
})();
