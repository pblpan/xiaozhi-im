// 线上只读探针：查 product_master（管理台"商品档案"）的真实条数与分布。
// 🔴 只读，不写任何东西 —— 目的是确认"要导出的这份"就是截图里那份。
const path = require('path');
process.env.DATA_DIR = process.env.DATA_DIR || '/data';
const db = require(path.join('/app/src', 'db'));

const total = db.prepare('SELECT COUNT(*) AS n FROM product_master').get().n;
const withQty = db.prepare(
  'SELECT COUNT(*) AS n FROM product_master WHERE account_qty IS NOT NULL').get().n;
const withSpec = db.prepare(
  "SELECT COUNT(*) AS n FROM product_master WHERE spec IS NOT NULL AND spec <> ''").get().n;
const withUnit = db.prepare(
  "SELECT COUNT(*) AS n FROM product_master WHERE unit IS NOT NULL AND unit <> ''").get().n;
const withPrice = db.prepare(
  'SELECT COUNT(*) AS n FROM product_master WHERE unit_price IS NOT NULL').get().n;
const withCost = db.prepare(
  'SELECT COUNT(*) AS n FROM product_master WHERE purchase_price IS NOT NULL').get().n;
const last = db.prepare(
  'SELECT MAX(updated_at) AS m, MIN(updated_at) AS n FROM product_master').get();
const batches = db.prepare(
  'SELECT batch, COUNT(*) AS n FROM product_master GROUP BY batch ORDER BY n DESC LIMIT 5').all();

const fmt = (v) => (v == null ? 'n/a' : new Date(v * 1000).toISOString().slice(0, 19).replace('T', ' '));

console.log(JSON.stringify({
  total,
  字段覆盖: {
    有账面数: withQty, 有规格: withSpec, 有单位: withUnit,
    有售价: withPrice, 有进价: withCost,
  },
  最后更新: fmt(last.m),
  最早更新: fmt(last.n),
  批次: batches,
}, null, 2));

// 顺带看 5 条真实数据（验字段名与截图的"商品档案"表对得上）
const sample = db.prepare(
  'SELECT barcode, name, spec, unit, unit_price, purchase_price, account_qty' +
  ' FROM product_master ORDER BY barcode LIMIT 5').all();
console.log('--- 样例 ---');
for (const r of sample) console.log(JSON.stringify(r));
