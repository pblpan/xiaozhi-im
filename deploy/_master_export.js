// 从线上 product_master 导出成扫码枪(hyd)能吃的 CSV。
//
// 🔴 为什么要"从库里导"而不是用别的方式拿
//   管理台"商品档案"页的数据源就是这张表，界面上显示的条数/字段与它一一对应。
//   走分页接口要 26 次请求（上限 5000/页），中途失败就得重头拼 ——
//   而漏掉几百条不会报错，只会让某些商品"扫不出来"。直接一条 SQL 导出最稳。
//
// 输出的 CSV 用 **UTF-8 with BOM**：
//   · App 侧 Gbk.decodeSmart 两种都吃，Excel 打开也不乱码；
//   · 表头列名走 MasterCsv.aliases（条码/商品名字/规格/单位/售价/数量）。
//   ⚠️ 列名必须落在 aliases 认得的集合里 —— 认不出来的那列会被**静默丢弃**，
//      界面照样显示"导入成功"，而那一列的数据永远进不了库
//      （见 skill tabular-import-field-integrity）。
const path = require('path');
const fs = require('fs');
process.env.DATA_DIR = process.env.DATA_DIR || '/data';
const db = require(path.join('/app/src', 'db'));

const OUT = process.env.OUT_CSV || '/tmp/builtin_master.csv';

// CSV 转义：含 , " 换行 的要加引号；引号翻倍。
// 🔴 不能只在"有逗号时"才转义 —— 商品名里出现 " 的比逗号更常见
//    （如 500g/ml*24 那种），漏了会把整行列错位，且**不报错**。
function esc(v) {
  if (v === null || v === undefined) return '';
  const s = String(v);
  if (/[",\r\n]/.test(s)) return '"' + s.replace(/"/g, '""') + '"';
  return s;
}

// 与管理台"盘点表不参与实盘数/账面数（表格库存有的库段都是它的）"无关，
// 这里如实导出账面数：它就是库存表里的账面列。
// 数量列语义见 MasterCsv.aliases：导入时是**账面数**，不是实盘数。
const rows = db.prepare(`
  SELECT barcode, name, spec, unit, unit_price, purchase_price, account_qty
    FROM product_master
   ORDER BY barcode ASC
`).all();

// 三个必须报出来的问题（旧 build_builtin_master.py 处理过的脏数据）：
//   ① 条码为空 → 扫不出来
//   ② 条码是 '废'/'*****' 这类占位 → 不是真条码
//   ③ 售价/进价 <= 0 → 盈亏表会算出负金额
// 这里**不丢弃**，但把数量报出来 —— 让龙哥看到"有多少条需要注意"，
// 而不是像以前那样悄悄丢 40 条。
let emptyBarcode = 0, junkBarcode = 0, badPrice = 0;
const junkSamples = [];
for (const r of rows) {
  const b = String(r.barcode ?? '').trim();
  if (!b) { emptyBarcode++; continue; }
  if (!/^\d+$/.test(b)) {
    junkBarcode++;
    if (junkSamples.length < 8) junkSamples.push({ barcode: b, name: r.name });
  }
  if (r.unit_price != null && r.unit_price <= 0) badPrice++;
}

const out = [];
// 表头：全部落在 MasterCsv.aliases 认得的列名上。
out.push(['条码', '商品名字', '规格', '单位', '售价', '进价', '数量'].join(','));
for (const r of rows) {
  out.push([
    esc(r.barcode), esc(r.name), esc(r.spec), esc(r.unit),
    esc(r.unit_price), esc(r.purchase_price), esc(r.account_qty),
  ].join(','));
}
const text = '\uFEFF' + out.join('\r\n') + '\r\n';
fs.writeFileSync(OUT, text, 'utf8');

console.log(JSON.stringify({
  导出行数: rows.length,
  文件: OUT,
  字节: Buffer.byteLength(text, 'utf8'),
  注意项: {
    '条码为空': emptyBarcode,
    '条码非纯数字': junkBarcode,
    '售价非正': badPrice,
  },
  脏条码样例: junkSamples,
}, null, 2));
