// 线上验证：/orgs/my 成员口径（管理员可见）+ 拉群候选数据面。
// 在容器里跑：用同一把 JWT_SECRET 现签 admin token，带权限打接口。
// ⚠️ 脚本会跑到 /tmp 下执行，模块解析从 /tmp 往上找 node_modules 找不到，
//    所以 require 一律写绝对路径（/app/...）。
const jwt = require('/app/node_modules/jsonwebtoken');
const config = require('/app/src/config.js');
const db = require('/app/src/db');

(async () => {
  // 1) 用户清单（带 org_id / role）—— 先看清线上数据
  const users = db.prepare('SELECT id,username,nickname,role,org_id,employee_no FROM users ORDER BY id').all();
  console.log('== 用户 ==');
  users.forEach((u) => console.log(`  id=${u.id} ${u.username}(${u.nickname}) role=${u.role} org=${u.org_id} no=${u.employee_no}`));

  // 2) 签 admin token（取第一个 admin）
  const admin = users.find((u) => u.role === 'admin');
  if (!admin) { console.log('!! 没有 admin 账号'); return; }
  const token = jwt.sign({ uid: admin.id }, config.JWT_SECRET, { expiresIn: '10m' });

  // 3) 带权限打 /orgs/my
  const r = await fetch('http://127.0.0.1:' + (process.env.PORT || 3602) + '/api/orgs/my', {
    headers: { Authorization: 'Bearer ' + token },
  });
  const j = await r.json();
  console.log('\n== GET /api/orgs/my (admin ' + admin.id + ') status=' + r.status + ' ==');
  console.log('  org:', JSON.stringify(j.org));
  (j.members || []).forEach((m) =>
    console.log(`  成员 id=${m.id} ${m.username}(${m.nickname}) role=${m.role} dept=${m.dept_name || '-'} no=${m.employee_no}`));

  // 4) 好友关系缺口：backfill 之后还有没有漏的真人两两
  const real = users.filter((u) => u.role !== 'bot' && u.is_bot !== 1);
  const gaps = [];
  for (let i = 0; i < real.length; i++) {
    for (let k = i + 1; k < real.length; k++) {
      const a = real[i].id, b = real[k].id;
      const row = db.prepare(
        "SELECT status FROM friendships WHERE user_id=? AND friend_id=?").get(a, b);
      if (!row || row.status !== 'accepted') gaps.push(`${a}↔${b}`);
    }
  }
  console.log('\n== 好友缺口（真人两两未 accepted）==');
  console.log(gaps.length ? gaps.map((g) => '  ' + g).join('\n') : '  无（全员两两 accepted）');
})().catch((e) => { console.error('ERR', e); process.exit(1); });
