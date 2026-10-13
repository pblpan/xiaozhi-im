// 线上补数：backfill 漏掉的 3 对好友（潘碧龙(2)↔1008/1009/测试）。
// 走真实 HTTP 端点 POST /api/admin/friendships/backfill（管理台那个幂等按钮的
// 同一条路），不直接调内部函数。跑完复验缺口。
// ⚠️ 脚本会跑到 /tmp 下执行，require 一律写绝对路径（/app/...）。
const jwt = require('/app/node_modules/jsonwebtoken');
const config = require('/app/src/config.js');
const db = require('/app/src/db');

const PORT = process.env.PORT || 3602;
const BASE = 'http://127.0.0.1:' + PORT;

(async () => {
  const users = db.prepare('SELECT id,username,nickname,role,org_id,is_bot FROM users ORDER BY id').all();
  const admin = users.find((u) => u.role === 'admin');
  const token = jwt.sign({ uid: admin.id }, config.JWT_SECRET, { expiresIn: '10m' });

  // 1) 补前缺口（真人 = is_bot=0）
  const humans = users.filter((u) => u.is_bot !== 1).map((u) => u.id);
  const gapsOf = () => {
    const gaps = [];
    for (let i = 0; i < humans.length; i++) {
      for (let k = i + 1; k < humans.length; k++) {
        const row = db.prepare(
          'SELECT status FROM friendships WHERE user_id=? AND friend_id=?').get(humans[i], humans[k]);
        if (!row || row.status !== 'accepted') gaps.push(`${humans[i]}↔${humans[k]}`);
      }
    }
    return gaps;
  };
  console.log('补前真人缺口：', JSON.stringify(gapsOf()));

  // 2) 走真实端点补齐
  const r = await fetch(BASE + '/api/admin/friendships/backfill', {
    method: 'POST',
    headers: { Authorization: 'Bearer ' + token },
  });
  console.log('POST /api/admin/friendships/backfill ->', r.status, JSON.stringify(await r.json()));

  // 3) 补后缺口
  console.log('补后真人缺口：', JSON.stringify(gapsOf()));

  // 4) 点名复验：潘碧龙(2) 的好友里必须有 37/38/39
  const f2 = db.prepare(
    "SELECT u.id, u.username FROM friendships f JOIN users u ON u.id=f.friend_id WHERE f.user_id=2 AND f.status='accepted' ORDER BY u.id").all();
  console.log('潘碧龙(2) 的好友：', JSON.stringify(f2.map((x) => x.username)));
})().catch((e) => { console.error('ERR', e); process.exit(1); });
