'use strict';
/**
 * 线上「家底」探针：一张表一张表数行数，顺便把商档那几张表抽样打出来。
 *
 * 🔴 为什么要有这个：判断"商档到底存哪了"不能靠猜 —— 服务端有
 *    product_master，客户端本地还有 stock_master（source 分 tiger / server
 *    两种），两边都可能写着"商品档案"。数一遍行数，空的、有数的、什么时候
 *    的，一眼看清。
 *
 * 用法：docker exec xiaozhi-im node /app/_tables_probe.js /data/xiaozhi-im.db
 */
const { DatabaseSync } = require('node:sqlite');

const dbPath = process.argv[2];
if (!dbPath) {
  console.error('用法: node _tables_probe.js <库文件路径>');
  process.exit(2);
}

const db = new DatabaseSync(dbPath);
const tables = db.prepare(
  "SELECT name FROM sqlite_master WHERE type='table'"
  + " AND name NOT LIKE 'sqlite_%' ORDER BY name"
).all().map((r) => r.name);

const out = [];
for (const t of tables) {
  let n = -1;
  try {
    n = db.prepare('SELECT COUNT(*) AS n FROM "%s"'.replace('"%s"', '"' + t + '"')).get().n;
  } catch (e) {
    out.push('%s : 读不了 (%s)', t, e.message);
    continue;
  }
  if (n !== 0) out.push('%s : %d 行', t, n);
}
console.log('=== 非空表 ===');
console.log(out.length ? out.join('\n') : '(一张非空表都没有 —— 这是个空库)');

for (const t of ['product_master']) {
  if (!tables.includes(t)) { console.log('\n%s 表不存在', t); continue; }
  const n = db.prepare('SELECT COUNT(*) AS n FROM product_master').get().n;
  console.log('\n=== %s ===', t);
  console.log('行数: %d', n);
  if (!n) continue;
  const byBatch = db.prepare(
    'SELECT batch, COUNT(*) AS n, MAX(updated_at) AS at FROM product_master'
    + ' GROUP BY batch ORDER BY n DESC LIMIT 5'
  ).all();
  for (const b of byBatch) {
    console.log('  batch=%s : %d 行, 最新 %s',
                b.batch, b.n, b.at ? new Date(b.at).toISOString() : '(无)');
  }
  const sample = db.prepare(
    'SELECT barcode, name, spec, unit, account_qty FROM product_master'
    + ' ORDER BY rowid LIMIT 3'
  ).all();
  console.log('  样例:');
  for (const s of sample) {
    console.log('    %s | %s | %s | %s | 账面 %s',
                s.barcode, s.name || '(无名)', s.spec || '', s.unit || '', s.account_qty);
  }

  // 字段完整度：导进来的商档**到底带了几列**。
  // 🔴 这直接决定下游能不能用：补货的"两套单位"（非称重按最小单位、
  //    称重按公斤）认的是 `unit`，减货/价签显示的规格认的是 `spec`。
  //    名字有、单位空 → 员工知道这是什么货，却不知道该按箱还是按公斤减。
  const fill = db.prepare(`
    SELECT COUNT(*) AS n,
           SUM(CASE WHEN name   IS NOT NULL AND name   <> '' THEN 1 ELSE 0 END) AS has_name,
           SUM(CASE WHEN spec   IS NOT NULL AND spec   <> '' THEN 1 ELSE 0 END) AS has_spec,
           SUM(CASE WHEN unit   IS NOT NULL AND unit   <> '' THEN 1 ELSE 0 END) AS has_unit,
           SUM(CASE WHEN account_qty IS NOT NULL THEN 1 ELSE 0 END) AS has_qty
      FROM product_master
  `).get();
  const pct = (x) => (fill.n ? ((Number(x) / Number(fill.n)) * 100).toFixed(1) : '0');
  console.log('  字段完整度（共 %d 行）:', fill.n);
  console.log('    有名称 : %d (%s%%)', fill.has_name, pct(fill.has_name));
  console.log('    有规格 : %d (%s%%)', fill.has_spec, pct(fill.has_spec));
  console.log('    有单位 : %d (%s%%)', fill.has_unit, pct(fill.has_unit));
  console.log('    有账面 : %d (%s%%)', fill.has_qty, pct(fill.has_qty));
}
db.close();
