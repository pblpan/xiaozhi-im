// 线上实测：动态模块「本服务器数据源」两条新接口必须拿 200（不能只看 401）
//
// 🔴 红线：401 只能证明"路由注册了"，不能证明"依赖都在"。
//    曾经验证只看 401，结果 settings.get 没注册键 → 一带权限就 500。
//    所以这里直接在容器里签一个管理员 token，真打一次，看 200 和真实数据。
//
//   node /tmp/_live_module_data.js   （经 _exec_in_container.py 在容器里跑）
const http = require('http');

const BASE = 'http://127.0.0.1:' + (process.env.PORT || 3602);

function req(method, path, token, body) {
  return new Promise((resolve, reject) => {
    const data = body ? JSON.stringify(body) : null;
    const r = http.request(BASE + path, {
      method,
      headers: {
        'Content-Type': 'application/json',
        ...(token ? { Authorization: 'Bearer ' + token } : {}),
      },
    }, (res) => {
      let buf = '';
      res.on('data', (d) => (buf += d));
      res.on('end', () => {
        let j = null;
        try { j = JSON.parse(buf); } catch { /* html 错误页 */ }
        resolve({ status: res.statusCode, body: j, raw: buf.slice(0, 200) });
      });
    });
    r.on('error', reject);
    if (data) r.write(data);
    r.end();
  });
}

(async () => {
  const db = require('/app/src/db');
  // 🔴 线上 settings 里没有 setupAdminPassword 这个键 —— settings.get 对
  //    未注册键直接抛"未知设置项"（这正是记忆里那个 500 坑，刚又撞上一次）。
  //    所以不走登录接口，直接用 auth.signToken 现签一个管理员 token。
  const admin = db.prepare("SELECT id, username, role FROM users WHERE role='admin' ORDER BY id LIMIT 1").get();
  if (!admin) { console.log('❌ 容器里没有管理员账号'); process.exit(1); }
  const { signToken } = require('/app/src/auth');
  const token = signToken({ uid: admin.id, role: admin.role });
  console.log('容器内签发 token -> ' + admin.username + ' #' + admin.id + ' OK');

  console.log('\n--- 带权限实测（要 200 + 真数据）---');

  const srcs = await req('GET', '/api/admin/module-sources', token);
  console.log('GET /api/admin/module-sources ->', srcs.status,
    srcs.status === 200
      ? ('local=' + (srcs.body.local || []).length + ' 条, upstreams=' + (srcs.body.upstreams || []).length + ' 条')
      : ('body=' + srcs.raw));

  const prods = await req('GET', '/api/hooks/local/inventory/products', token);
  const rows = (prods.body && prods.body.data && prods.body.data.rows) || [];
  console.log('GET /api/hooks/local/inventory/products ->', prods.status,
    prods.status === 200
      ? ('rows=' + rows.length + '/' + ((prods.body.data || {}).total ?? '?') +
        ' 首行=' + JSON.stringify(rows[0] || null).slice(0, 160))
      : ('body=' + prods.raw));

  const members = await req('GET', '/api/hooks/local/work_org/members', token);
  console.log('GET /api/hooks/local/work_org/members ->', members.status,
    members.status === 200
      ? ('rows=' + ((members.body.data || {}).rows || []).length)
      : ('body=' + members.raw));

  const att = await req('GET', '/api/hooks/local/attendance/records', token);
  console.log('GET /api/hooks/local/attendance/records ->', att.status,
    att.status === 200
      ? ('rows=' + ((att.body.data || {}).rows || []).length)
      : ('body=' + att.raw));

  const mods = await req('GET', '/api/admin/modules', token);
  const tpls = (mods.body && mods.body.capability && mods.body.capability.templates) || [];
  const withData = tpls.filter((t) => JSON.stringify(t.module.body || '').includes('"component":"list"')
    || JSON.stringify(t.module.body || '').includes('"component":"table"')
    || JSON.stringify(t.module.body || '').includes('"component":"chart"'));
  console.log('模板库 ->', mods.status, '共', tpls.length, '份；带数据组件的',
    withData.length, '份，其中自带 onLoad 的',
    withData.filter((t) => t.module.onLoad && t.module.onLoad.path).length, '份');

  const okAll = srcs.status === 200 && prods.status === 200
    && members.status === 200 && att.status === 200
    && withData.length > 0
    && withData.every((t) => t.module.onLoad && t.module.onLoad.path);
  console.log(okAll ? '\n✅ 线上实测通过（全 200，模板全带数据源）' : '\n❌ 有不达标的，见上');
  process.exit(okAll ? 0 : 1);
})().catch((e) => { console.error(e); process.exit(1); });
