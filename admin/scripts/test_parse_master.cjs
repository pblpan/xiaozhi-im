/**
 * 商档 CSV 解析回归测试（真源码，不是抄本）。
 *
 *   cd admin && node scripts/test_parse_master.cjs
 *
 * 🔴 为什么直接从 `src/App.vue` 里抽函数来跑，而不是在测试里另抄一份逻辑：
 *    抄本和真身一旦漂移，测试会给出**假安心** —— 测的是那个不存在的解析器。
 *    这条规矩本地库里（longterm/local_db.dart）已经吃过一次亏，抄本必须钉在真源码上。
 *
 * 覆盖的是 2026-09-26/27 这两轮真踩过的坑：
 *   · 只读三列，规格/单位/价格被静默丢弃（线上 12.6 万行规格单位全是 0%）
 *   · 英文表头下 `unit` 命中 `unit_price` —— 单位串到售价上
 */
const fs = require('fs');
const path = require('path');

const vue = fs.readFileSync(path.join(__dirname, '..', 'src', 'App.vue'), 'utf8');

/** 从 App.vue 里抽一个顶层 function 的完整源码。 */
function grab(name) {
  const re = new RegExp('\\nfunction ' + name + '\\([^)]*\\) \\{[\\s\\S]*?\\n\\}\\n');
  const m = vue.match(re);
  if (!m) {
    console.error('✗ 没能从 App.vue 里抽到 ' + name + ' —— 函数被改名或挪走了，'
      + '测试失去意义，先修这个测试再改业务代码');
    process.exit(1);
  }
  return m[0].trim();
}

// 抽**真源码**来跑，连依赖一起放进同一个作用域
// eslint-disable-next-line no-eval
const parseMasterCsv = eval('(function(){'
  + grab('splitCsvLine') + '\n' + grab('parseMasterCsv')
  + '\nreturn parseMasterCsv;})()');

let passed = 0;
const failures = [];
function ok(name, cond, detail) {
  if (cond) { passed++; console.log('  ✓ ' + name); }
  else { failures.push(name + (detail ? ' → ' + detail : '')); console.log('  ✗ ' + name + (detail ? ' → ' + detail : '')); }
}

console.log('\n【一】龙哥 2026-09-27 截图里的表头（七列，中文）');
{
  const csv = [
    '条码,名称,规格,单位,进价,售价,库存',
    '6927573123513,中沃体质能600ml,600ml,瓶,3.66,4.8,1',
    '6927573129812,中沃体质能420ml,420ml,瓶,2,5.8,1',
    '6927574207779,强哥扑克,个,个,1.11,1.5,1',
    '6927574208189,顶星扑克（自营）,,盒,1,2,1',
  ].join('\n');
  const rows = parseMasterCsv(csv);
  ok('解析出 4 行', rows.length === 4, JSON.stringify(rows.length));
  const r0 = rows[0];
  ok('🔴 单位读出来了（=瓶）', r0.unit === '瓶', JSON.stringify(r0));
  ok('🔴 规格读出来了（=600ml）', r0.spec === '600ml', JSON.stringify(r0));
  ok('🔴 进价读出来了（=3.66）', r0.purchase_price === 3.66, JSON.stringify(r0));
  ok('🔴 售价读出来了（=4.8）', r0.unit_price === 4.8, JSON.stringify(r0));
  ok('  库存读出来了（=1）', r0.account_qty === 1, JSON.stringify(r0));
  ok('  名称 = 中沃体质能600ml', r0.name === '中沃体质能600ml', JSON.stringify(r0.name));
  ok('  空规格不炸（第 4 行规格是空的）', rows[3].spec === '', JSON.stringify(rows[3]));
  ok('  第 4 行单位仍是盒', rows[3].unit === '盒', JSON.stringify(rows[3]));
}

console.log('\n【二】英文表头：unit 不许被 unit_price 抢走');
{
  const csv = [
    'barcode,name,spec,unit,unit_price,account_qty',
    '6901234567890,测试商品,1×12,箱,12,300',
  ].join('\n');
  const r = parseMasterCsv(csv)[0];
  ok('🔴 unit = 箱（不是 12）', r.unit === '箱', JSON.stringify(r));
  ok('🔴 unit_price = 12', r.unit_price === 12, JSON.stringify(r));
  ok('  account_qty = 300', r.account_qty === 300, JSON.stringify(r));
}

console.log('\n【三】顺序颠倒的英文表头（unit 在后面）也不能串');
{
  const csv = [
    'barcode,name,unit_price,unit,account_qty',
    '6901234567890,测试商品,12,箱,300',
  ].join('\n');
  const r = parseMasterCsv(csv)[0];
  ok('🔴 unit_price = 12', r.unit_price === 12, JSON.stringify(r));
  ok('🔴 unit = 箱', r.unit === '箱', JSON.stringify(r));
}

console.log('\n【四】制表符分隔（从 Excel 直接复制出来的那种）');
{
  const csv = '条码\t名称\t规格\t单位\t进价\t售价\t库存\n690123\t货\t1×1\t袋\t1\t2\t3';
  const r = parseMasterCsv(csv)[0];
  ok('Tab 分隔也能解析', r.barcode === '690123' && r.unit === '袋' && r.unit_price === 2,
    JSON.stringify(r));
}

console.log('\n【五】价格带 ¥ / 千分位，必须加引号才不切错（CSV 规范）');
{
  // ⚠️ 含逗号的字段**必须**写成 "¥1,280.00"。Excel 另存 CSV 会自动加引号，
  //    直接从表格里复制粘贴则不会 —— 这正是下面第八组要警告的情况。
  const csv = ['条码,名称,规格,单位,进价,售价,库存',
    '690124,货,1×1,袋,"¥1,280.00","¥1,500",11'].join('\n');
  const r = parseMasterCsv(csv)[0];
  ok('"¥1,280.00" → 1280', r.purchase_price === 1280, JSON.stringify(r.purchase_price));
  ok('"¥1,500" → 1500', r.unit_price === 1500, JSON.stringify(r.unit_price));
  ok('库存 11', r.account_qty === 11, JSON.stringify(r.account_qty));
  ok('  单位仍是袋（没被价格挤走）', r.unit === '袋', JSON.stringify(r));
  ok('  列数齐 → 不报错位', (parseMasterCsv(csv).colMismatch || 0) === 0,
    String(parseMasterCsv(csv).colMismatch));
}

console.log('\n【五之二】🔴 千分位不加引号 → 必须报"整列错位"（而不是默默错）');
{
  const csv = ['条码,名称,规格,单位,进价,售价,库存',
    '690124,货,1×1,袋,¥1,280.00,¥1,500,11'].join('\n');
  const rows = parseMasterCsv(csv);
  ok('🔴 数出了列数不齐的行（界面上会红字警告）',
    (rows.colMismatch || 0) === 1, String(rows.colMismatch));
}

console.log('\n【六】没有表头的老文件：只认旧四列，绝不猜列位');
{
  const csv = ['1,690123,货,3', '2,690124,货B,5'].join('\n');
  const rows = parseMasterCsv(csv);
  ok('序号列被识别，条码是第二列', rows[0].barcode === '690123', JSON.stringify(rows[0]));
  ok('  数量落在 account_qty', rows[0].account_qty === 3, JSON.stringify(rows[0]));
  ok('  单位不猜（留空）', rows[0].unit === '', JSON.stringify(rows[0]));
}

console.log('\n【七】列名不认识时不能"猜一列顶上"');
{
  // 表头全是自定义名字：只有条码能认出来，其余都该是空，而不是胡乱对上
  const csv = ['商品编码,别的东西,另一个,啥,某某,未知,数目',
    '690125,甲,乙,丙,1,2,3'].join('\n');
  const r = parseMasterCsv(csv)[0];
  ok('条码认出来了', r.barcode === '690125', JSON.stringify(r));
  ok('  单位留空（没乱认）', r.unit === '', JSON.stringify(r));
  ok('  进价留空（没乱认）', r.purchase_price === null, JSON.stringify(r));
}

console.log('\n[parseMasterCsv] 通过 ' + passed + ' / 失败 ' + failures.length);
if (failures.length) {
  console.log('\n失败项：');
  failures.forEach((f) => console.log('  - ' + f));
  process.exit(1);
}
