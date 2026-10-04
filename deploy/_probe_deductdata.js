const jwt = require('/app/src/auth.js');
const db  = require('/app/src/db.js');
const cfg = require('/app/src/config.js');
const admin = db.prepare('SELECT id,username,role FROM users WHERE username=?').get(cfg.ADMIN_USERNAME);
const token = jwt.signToken({ uid: admin.id, role: admin.role });
const H = { Authorization: 'Bearer ' + token };
const J = 'http://127.0.0.1:3602';
(async () => {
  // 抽屉数据页：减货单明细（allTime 全量）
  for (const src of ['sheets', 'scans']) {
    const r = await fetch(J + '/api/admin/apps/warehouse_deduct/data?source=' + src + '&allTime=1&pageSize=5', { headers: H });
    const body = await r.text();
    console.log('  data/' + src + ': ' + r.status + '  ' + body.slice(0, 200));
  }
  // CSV 导出烟测
  const r2 = await fetch(J + '/api/admin/apps/warehouse_deduct/export?source=scans&allTime=1', { headers: H });
  console.log('  export/scans: ' + r2.status + '  head=' + (await r2.text()).slice(0, 80).replace(/\n/g, '\\n'));
})();
