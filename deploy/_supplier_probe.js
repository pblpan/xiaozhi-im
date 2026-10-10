'use strict';
/** 验「商档供应商列」是否真的可用：打印列 + 抽一条带 supplier 的样本。 */
const { DatabaseSync } = require('node:sqlite');
const dbPath = process.argv[2];
if (!dbPath) { console.error('用法: node _supplier_probe.js <库文件路径>'); process.exit(2); }
const db = new DatabaseSync(dbPath);
const cols = db.prepare('PRAGMA table_info(product_master)').all().map((c) => c.name);
console.log('product_master 列: ' + cols.join(','));
console.log('supplier 列存在: ' + (cols.includes('supplier') ? '是' : '否'));
const row = db.prepare(
  'SELECT barcode, name, account_qty, supplier FROM product_master LIMIT 1'
).get();
console.log('样本行: ' + JSON.stringify(row));
const n = db.prepare('SELECT COUNT(*) c FROM product_master WHERE supplier IS NOT NULL AND supplier <> ?', ['']).get();
console.log('已有供应商非空记录数: ' + (n ? n.c : '?'));
db.close();
