// 用管理台 App.vue 的真 parseMasterCsv 验证无表头九列导入（2026-10-06）
const fs = require('fs');
const path = require('path');
const vue = fs.readFileSync(path.join(__dirname, 'src', 'App.vue'), 'utf8');
function grab(name) {
  const start = vue.indexOf('function ' + name);
  if (start < 0) throw new Error('找不到 ' + name);
  let i = vue.indexOf('{', start), depth = 0, end = -1;
  for (; i < vue.length; i++) {
    if (vue[i] === '{') depth++;
    else if (vue[i] === '}') { depth--; if (depth === 0) { end = i + 1; break; } }
  }
  return vue.slice(start, end);
}
const parseMasterCsv = new Function(grab('splitCsvLine') + '\n' + grab('parseMasterCsv') + '\nreturn parseMasterCsv;')();

let fail = 0;
const check = (label, cond) => { console.log((cond ? '✅' : '❌') + ' ' + label); if (!cond) fail++; };

// ① 龙哥原始文件：GBK 无表头九列、售价在前
const raw = fs.readFileSync('D:/Users/pblpa/Desktop/商品信息.csv');
const r1 = parseMasterCsv(raw.toString('latin1'));
check('① 解析 126829 行（' + r1.length + '）', r1.length === 126829);
check('① 嗅探到售价在前并自动对调', r1.noHeadPriceSwapped === true);
check('① 第1行 售价24.8/进价19.84',
  r1[0].unit_price === 24.8 && r1[0].purchase_price === 19.84);
check('① 第1行 规格300g/库存0（unit/name 中文按 latin1 读必乱码，只查非空）',
  r1[0].spec === '300g' && r1[0].account_qty === 0
  && (r1[0].unit ?? '').length > 0 && (r1[0].name ?? '').length > 0);
const m = r1.filter((x) => x.member_price > 0).length;
const s = r1.filter((x) => x.special_price > 0).length;
check(`① 会员价>0 ${m}（期望14523）/ 特价>0 ${s}（期望2895）`, m === 14523 && s === 2895);

// ② 带表头版回归（上一轮交付的那份）
const r2 = parseMasterCsv(fs.readFileSync('D:/Users/pblpa/Desktop/商品信息-带表头.csv', 'utf8'));
check('② 带表头版解析 ' + r2.length + ' 行、不触发对调',
  r2.length === 126829 && r2.noHeadPriceSwapped === false);
check('② 第1行 售价24.8/进价19.84 落对列',
  r2[0].unit_price === 24.8 && r2[0].purchase_price === 19.84);

// ③ 老四列（有序号）：序号,条码,名,数量
const r3 = parseMasterCsv('1,A001,可乐,10\n2,A002,薯片,5\n3,A003,泡面,8\n');
check('③ 老四列(有序号) 3 行', r3.length === 3 && r3[0].barcode === 'A001' && r3[0].account_qty === 10);

// ④ 老四列（无序号）：条码,名,数量
const r4 = parseMasterCsv('A001,可乐,10\nA002,薯片,5\n');
check('④ 老四列(无序号) 2 行', r4.length === 2 && r4[0].barcode === 'A001' && r4[1].account_qty === 5);

// ⑤ 无表头九列但进价在前（定版顺序）→ 不应对调
const r5 = parseMasterCsv(
  Array.from({ length: 30 }, (_, i) => `69${i},商品${i},个,瓶,${(10 + i).toFixed(2)},${(15 + i).toFixed(2)},0,0,5`).join('\n') + '\n');
check('⑤ 进价在前(定版顺序) 不对调', r5.noHeadPriceSwapped === false);
check('⑤ 第1行 进价10/售价15', r5[0].purchase_price === 10 && r5[0].unit_price === 15);

// ⑥ 无表头九列但样本不足 20 行有效价 → 不嗅探（保守，按定版顺序）
const r6 = parseMasterCsv('691,甲,个,瓶,10,15,0,0,5\n692,乙,个,瓶,12,18,0,0,3\n');
check('⑥ 样本不足不对调（保持定版顺序）', r6.noHeadPriceSwapped === false && r6[0].purchase_price === 10);

console.log(fail ? `❌ ${fail} 项失败` : '✅ 全部通过');
process.exit(fail ? 1 : 0);
