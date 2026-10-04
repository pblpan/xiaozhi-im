// 线上实测：管理台「应用管理」抽屉为什么报「加载应用信息失败」。
// 在容器里用同一把 JWT_SECRET 现签 admin token，逐个打 GET /api/admin/apps/:id，
// 看状态码与错误体 —— 401 不算数（只证明路由在），必须 200 才是真好用。
const jwt = require('/app/src/auth.js');
const db  = require('/app/src/db.js');
const cfg = require('/app/src/config.js');
const apps = require('/app/src/apps.js');

const admin = db.prepare('SELECT id,username,role FROM users WHERE username=?').get(cfg.ADMIN_USERNAME);
if (!admin) { console.log('no admin user'); process.exit(0); }
const token = jwt.signToken({ uid: admin.id, role: admin.role });
const H = { Authorization: 'Bearer ' + token };
const J = 'http://127.0.0.1:3602';

(async () => {
  const ids = apps.BUILTIN_APPS.map(a => a.id);
  for (const id of ids) {
    try {
      const r = await fetch(J + '/api/admin/apps/' + id, { headers: H });
      const body = await r.text();
      if (r.status === 200) {
        console.log('  ' + r.status + '  ' + id);
      } else {
        console.log('  ' + r.status + '  ' + id + '  BODY: ' + body.slice(0, 300));
      }
    } catch (e) {
      console.log('  ERR  ' + id + '  ' + (e && e.message));
    }
  }
  // 顺带：应用中心清单接口（抽屉外的列表页用）
  try {
    const r = await fetch(J + '/api/admin/apps/catalog', { headers: H });
    console.log('  catalog: ' + r.status + ' len=' + (await r.text()).length);
  } catch (e) { console.log('  catalog ERR ' + (e && e.message)); }
})();
