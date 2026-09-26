'use strict';
/**
 * 线上「减货参照数」接口体检（跑在容器里）。
 *
 * 🔴 为什么用文件而不是 `node -e "..."`：那串命令里的引号要一层层转义，
 *    在 Python 的 ssh 调用里写出来能闪瞎眼，而且一旦转义错一层，
 *    node 会抛一个看不出来源的错（上次就卡在这，以为是接口没挂上）。
 *
 * 用法：docker exec xiaozhi-im node /app/_ref_probe.js <库文件路径>
 *   例：docker exec xiaozhi-im node /app/_ref_probe.js /data/xiaozhi-im.db
 *
 * 打印：
 *   最近一轮盘点的条码（裸条码，不带引号）
 *   没盘点过就退而取商档里的真实条码
 *   格式：`盘点条码|备选条码`（空 = 库里一样都没有）
 *   然后由调用方拿这个条码去打 /api/deduct/reference 看真数字。
 *
 * 🔴 为什么还要备选条码（2026-09-27 补）：线上如果**一次盘点都没做过**，
 *   只打印空串的话，接口那一句 `hasRef:false` 是"真跑通了"还是"字段写错
 *   导致永远查不到"，从输出上分辨不出来 —— 等于白验。所以退而拿一条
 *   真实存在的商品条码去打，接口必须回一个**字段齐全的 JSON**。
 */
const { DatabaseSync } = require('node:sqlite');

const dbPath = process.argv[2];
if (!dbPath) {
  console.error('用法: node _ref_probe.js <库文件路径>');
  process.exit(2);
}

const db = new DatabaseSync(dbPath);
const row = db.prepare(`
  SELECT r.barcode AS barcode
    FROM inv_scans r
    JOIN inv_sheets s ON s.sheet_no = r.sheet_no
   WHERE r.sheet_type = 'inventory' AND s.sheet_type = 'inventory'
   ORDER BY r.scanned_at DESC, r.id DESC
   LIMIT 1
`).get();

const anyCode = db.prepare(
  'SELECT barcode FROM product_master WHERE barcode IS NOT NULL'
  + ' ORDER BY rowid LIMIT 1'
).get();

const counted = row ? String(row.barcode) : '';
const fallback = anyCode ? String(anyCode.barcode) : '';
console.log('%s|%s', counted, fallback);
db.close();
