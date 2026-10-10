// 线上验证 0.24.0：商档会员价/特价（#274）+ 进价开关（#273）
const jwt = require('/app/src/auth.js');
const db  = require('/app/src/db.js');
const cfg = require('/app/src/config.js');
const admin = db.prepare('SELECT id,username,role FROM users WHERE username=?').get(cfg.ADMIN_USERNAME);
const token = jwt.signToken({ uid: admin.id, role: admin.role });
const H = { Authorization: 'Bearer ' + token };
const J = 'http://127.0.0.1:3602';
(async () => {
  // ① product_master 表结构：member_price / special_price 两列必须存在
  const cols = db.prepare('PRAGMA table_info(product_master)').all().map(c => c.name);
  console.log('① product_master 列: ' + cols.join(','));
  console.log('   member_price 在? ' + cols.includes('member_price')
    + ' / special_price 在? ' + cols.includes('special_price'));

  // ② 带 token 打商档接口（必须 200 且行里带两字段）—— 401 只能证明路由挂上
  const r = await fetch(J + '/api/master', { headers: H });
  const body = await r.json();
  const rows = Array.isArray(body) ? body : (body.items || body.rows || body.data || []);
  console.log('② GET /api/master -> ' + r.status + '，行数 ' + rows.length);
  if (rows.length) {
    const k = Object.keys(rows[0]);
    console.log('   字段: ' + k.join(','));
    console.log('   member_price 字段在? ' + k.includes('member_price')
      + ' / special_price 在? ' + k.includes('special_price'));
    const withPrice = rows.find(x => x.member_price != null || x.special_price != null);
    if (withPrice) console.log('   样例: ' + withPrice.barcode + ' 会员价=' + withPrice.member_price + ' 特价=' + withPrice.special_price);
  }

  // ③ 服务端版本号（package.json 应为 0.24.0）
  console.log('③ 服务端版本: ' + require('/app/package.json').version);
})();
