/**
 * 导出格式设定 + 导出记录（需求④，龙哥 2026-10-22）
 *
 *   「增加导出记录和格式设定，按照托利多电子秤的格式导出，表格导出等方式」
 *
 * 拆成两件事，各有各的存储理由：
 *
 * ① **格式设定**（本文件的 getSettings/saveSettings）
 *    存在 settings 表的 export_formats 这一个键里（KV）。
 *    为什么不用一张专门的表：它是"本服务器的导出策略"，整体一份、
 *    改一次全生效，没有版本化/回滚的需求 —— 和 company_name/friend_mode
 *    同一个性质（见 settings.js 头部注释）。复杂机制只会让"改个组号"
 *    变得难懂。
 *    ⚠️ 这里**不走 settings.js 的 KEYS/all()**：那个 all() 会被免鉴权的
 *    /api/client/bootstrap 原样铺出去（routes/client.js 里 ...settings.all()）。
 *    导出格式不是密钥、铺出去也没事，但 bootstrap 的职责是"客户端冷启动
 *    握手所需的最小集"，格式设定是用户在「个人中心 → 格式设定」里按需拉的
 *    （GET /api/export/settings），没必要每次冷启动都带上。
 *
 * ② **导出记录**（本文件的 addRecord/listRecords/purge）
 *    单独一张 export_records 表（见 db.js 建表处）—— 流水数据，只增不改。
 *
 * 🔴 服务端只**存参数、不生成文件**。真正的排版在客户端
 *    （client/lib/core/export_format.dart + toledo_plu.dart，纯函数）：
 *    文件在用户设备上生成、设备本地落盘，服务端连文件内容都摸不到，
 *    只记一条"谁在何时导了什么"的账。这样服务端不会变成文件中转站，
 *    也没有"服务端生成一半失败了客户端怎么办"的分裂状态。
 */

const db = require('./db');

const KV_KEY = 'export_formats';

// 记录保留天数：导出台账留半年够追溯（"上个月谁导过盘点"），
// 再老的价值趋近于零，但表会一直长 —— 每次写入时顺手清一次超期行。
// 清理走 created_at 索引（db.js 里建了），表再大也是索引范围删除。
const RETAIN_DAYS = 180;

// ---------------------------------------------------------------------------
// 格式设定的形状与默认值
//
// 默认值 = "什么都没配"时的行为，必须和客户端 export_format.dart / toledo_plu.dart
// 的默认值逐字段一致 —— 两边各有一份是刻意的（服务端要校验、客户端要离线可用），
// 但**改了一边必须改另一边**，否则"服务端存了默认值、客户端按另一套默认解释"
// 就会出现"我没改却生效了"的幽灵配置。
//
// ⚠️ 这里**没有**「文件形态（.plu/.txt）」参数：那由格式 id 决定
//    （toledo_plu / toledo_txt 两个入口本身就说清了），再存一份只会互相矛盾。
// ⚠️ 也**没有** CSV 参数（BOM/条码文本保护/CRLF）：那些在客户端各导出层
//    里已经写死且有单测钉着（stocktake_export/simple_export 的 BOM、
//    csv_fmt 的 ="条码"、toScanDoc 的 CRLF）。再配一份"没人读的参数"
//    只会出现"管理台改了没效果"——那比没有这个配置更糟。
// ---------------------------------------------------------------------------
const TOLEDO_DEFAULTS = Object.freeze({
  // PLU 号怎么来（RL00 必有字段，1~999999）：
  //   'seq'         = 按行序 1,2,3… 生成（默认；换数据会变，但保证合法不撞号）
  //   'barcode_tail'= 取商品条码后 6 位（同一商品每次导出一致；
  //                    ⚠️ 后 6 位可能撞号，SPCT 会按后写入的覆盖先写入的）
  pluMode: 'seq',
  group: 0,            // 组号 0~20（0 = 不分组）
  tare: 0,             // 皮重号 0~16（0 = 无皮重）
  tax: 0,              // 税号 0~9
  shelfLife: 0,        // 保质期（天）0~499
  recommendLife: 0,    // 推荐期（天）0~499
  // 计价方式（RL00 必有字段）：0=计重（元/千克）1=计数（元/个）。
  //   'auto'  = 按商品单位自动判（斤/千克/g → 计重，个/袋/盒 → 计数）
  //   'weight'= 全部按计重   'count' = 全部按计数
  priceMode: 'auto',
  allowReprice: 0,     // 改价标志 0=禁止 1=允许（秤上能不能改价）
  allowDiscount: 0,    // 打折标志 0=禁止 1=允许
});

const DEFAULT_SETTINGS = Object.freeze({
  // 每个模块的默认导出格式（module id → format id）。
  // 空对象 = 全用客户端内置默认（通用 CSV）—— 服务端不强制任何格式，
  // "按托利多导出"是龙哥在格式设定里显式选出来的，不是默认行为。
  moduleFormats: Object.freeze({}),
  toledo: TOLEDO_DEFAULTS,
});

const TOLEDO_RANGES = Object.freeze({
  pluMode: ['seq', 'barcode_tail'],
  group: [0, 20],
  tare: [0, 16],
  tax: [0, 9],
  shelfLife: [0, 499],
  recommendLife: [0, 499],
  priceMode: ['auto', 'weight', 'count'],
  allowReprice: [0, 1],
  allowDiscount: [0, 1],
});

const TOLEDO_LABELS = Object.freeze({
  pluMode: 'PLU 号来源', group: '组号', tare: '皮重号',
  tax: '税号', shelfLife: '保质期', recommendLife: '推荐期',
  priceMode: '计价方式', allowReprice: '改价标志', allowDiscount: '打折标志',
});

// 模块 id 长度/字符集粗校验：格式设定的 key 是模块 id，值格式 id。
// 服务端**不认识**客户端的格式注册表（那份在客户端，见 export_format.dart），
// 所以这里只保证"是个正常的短标识"；客户端遇到不认识的格式 id 会
// 回退到该模块的默认格式 —— 宁可忽略，不要因为服务端瞎校验把合法配置挡在门外。
const ID_RE = /^[a-z0-9_]{1,40}$/;

function rawGet() {
  const row = db.prepare('SELECT value FROM settings WHERE key=?').get(KV_KEY);
  return row ? row.value : null;
}

function rawSet(value, by) {
  db.prepare(`INSERT INTO settings (key,value,updated_at,updated_by) VALUES (?,?,?,?)
    ON CONFLICT(key) DO UPDATE SET value=excluded.value, updated_at=excluded.updated_at, updated_by=excluded.updated_by`)
    .run(KV_KEY, JSON.stringify(value), Date.now(), String(by || 'admin').slice(0, 60));
}

/** 读格式设定（带默认值；坏数据按默认值兜底不抛错） */
function getSettings() {
  const raw = rawGet();
  if (raw === null) return JSON.parse(JSON.stringify(DEFAULT_SETTINGS));
  try {
    const v = JSON.parse(raw);
    if (!v || typeof v !== 'object') return JSON.parse(JSON.stringify(DEFAULT_SETTINGS));
    return {
      moduleFormats: (v.moduleFormats && typeof v.moduleFormats === 'object' && !Array.isArray(v.moduleFormats)) ? v.moduleFormats : {},
      toledo: { ...TOLEDO_DEFAULTS, ...(v.toledo && typeof v.toledo === 'object' ? v.toledo : {}) },
    };
  } catch {
    return JSON.parse(JSON.stringify(DEFAULT_SETTINGS));
  }
}

function cleanInt(v, [lo, hi], label) {
  const n = Number(v);
  if (!Number.isFinite(n) || !Number.isInteger(n)) return { error: `${label} 需为整数` };
  if (n < lo || n > hi) return { error: `${label}需在 ${lo}~${hi} 之间` };
  return { value: n };
}

function cleanEnum(v, allowed, label) {
  const s = String(v ?? '');
  if (!allowed.includes(s)) return { error: `${label} 只能是：${allowed.join(' / ')}` };
  return { value: s };
}

/**
 * 校验并合并格式设定（局部更新：只校验传上来的键，没传的保持原值）。
 * 返回 { ok:true, settings } 或 { error }。
 */
function saveSettings(input, by) {
  if (!input || typeof input !== 'object' || Array.isArray(input)) {
    return { error: '格式设定必须是一个 JSON 对象' };
  }
  const cur = getSettings();
  const next = {
    moduleFormats: { ...cur.moduleFormats },
    toledo: { ...cur.toledo },
  };

  if (input.moduleFormats !== undefined) {
    const mf = input.moduleFormats;
    if (!mf || typeof mf !== 'object' || Array.isArray(mf)) {
      return { error: 'moduleFormats 需为对象，如 {"stocktake":"toledo_plu"}' };
    }
    const out = {};
    for (const k of Object.keys(mf)) {
      if (!ID_RE.test(k)) return { error: `模块 id 不合法：${k}（小写字母/数字/下划线，≤40 字符）` };
      const v = mf[k];
      if (v === null || v === '') continue; // 空值 = 删掉这条覆盖，回落到默认格式
      if (typeof v !== 'string' || !ID_RE.test(v)) {
        return { error: `模块 ${k} 的格式 id 不合法：${v}（小写字母/数字/下划线，≤40 字符）` };
      }
      out[k] = v;
    }
    next.moduleFormats = out;
  }

  if (input.toledo !== undefined) {
    const t = input.toledo;
    if (!t || typeof t !== 'object' || Array.isArray(t)) return { error: 'toledo 需为对象' };
    for (const k of Object.keys(t)) {
      if (!(k in TOLEDO_DEFAULTS)) return { error: `不认识的托利多参数：${k}（允许：${Object.keys(TOLEDO_DEFAULTS).join('、')}）` };
      const label = TOLEDO_LABELS[k];
      const c = Array.isArray(TOLEDO_RANGES[k]) && typeof TOLEDO_RANGES[k][0] === 'string'
        ? cleanEnum(t[k], TOLEDO_RANGES[k], label)
        : cleanInt(t[k], TOLEDO_RANGES[k], label);
      if (c.error) return { error: c.error };
      next.toledo[k] = c.value;
    }
  }

  rawSet(next, by);
  return { ok: true, settings: next };
}

// ---------------------------------------------------------------------------
// 导出记录
// ---------------------------------------------------------------------------

const REC_LIMITS = Object.freeze({
  module: 40, moduleName: 40, docNo: 60,
  formatId: 40, formatName: 40, fileName: 200, ext: 10,
});

function clip(v, max) {
  const s = String(v ?? '').trim();
  // 去掉控制字符（换行/制表符进了台账会让管理台列表错行）
  return s.replace(/[\u0000-\u001f\u007f]/g, ' ').slice(0, max);
}

/**
 * 记一条导出。返回 { ok:true, id } 或 { error }。
 * rows 允许 0（比如只导出了表头），但不允许负数/非数。
 */
function addRecord(rec) {
  const r = rec || {};
  const module = clip(r.module, REC_LIMITS.module);
  const formatId = clip(r.formatId, REC_LIMITS.formatId);
  const fileName = clip(r.fileName, REC_LIMITS.fileName);
  if (!module) return { error: 'module 不能为空' };
  if (!formatId) return { error: 'formatId 不能为空' };
  if (!fileName) return { error: 'fileName 不能为空' };
  const rows = Number(r.rows);
  if (!Number.isFinite(rows) || rows < 0 || !Number.isInteger(rows)) {
    return { error: 'rows 需为不小于 0 的整数' };
  }
  if (rows > 1e9) return { error: 'rows 超出合理范围' };

  const now = Date.now();
  const info = db.prepare(`INSERT INTO export_records
    (user_id, username, module, module_name, doc_no, format_id, format_name, file_name, rows, ext, created_at)
    VALUES (?,?,?,?,?,?,?,?,?,?,?)`)
    .run(
      Number(r.userId) || 0,
      clip(r.username, 40) || 'unknown',
      module,
      clip(r.moduleName, REC_LIMITS.moduleName) || null,
      clip(r.docNo, REC_LIMITS.docNo) || null,
      formatId,
      clip(r.formatName, REC_LIMITS.formatName) || formatId,
      fileName,
      rows,
      clip(r.ext, REC_LIMITS.ext) || null,
      now,
    );

  // 顺手清超期行（RETAIN_DAYS）。放在这里而不是定时器：导出是低频操作，
  // 每次写的时候判一次就够，不值得为它多养一个 timer（还会拖住优雅停机）。
  try {
    db.prepare('DELETE FROM export_records WHERE created_at < ?')
      .run(now - RETAIN_DAYS * 86400 * 1000);
  } catch { /* 清理失败不影响本次记账 */ }

  return { ok: true, id: Number(info.lastInsertRowid) };
}

/** 台账查询。userId 不给 = 全量（管理台用）。 */
function listRecords({ userId, module, limit = 50, offset = 0 } = {}) {
  const lim = Math.min(Math.max(Number(limit) || 50, 1), 200);
  const off = Math.max(Number(offset) || 0, 0);
  const where = [];
  const args = [];
  if (userId) { where.push('user_id=?'); args.push(Number(userId)); }
  if (module) { where.push('module=?'); args.push(String(module).slice(0, 40)); }
  const w = where.length ? `WHERE ${where.join(' AND ')}` : '';
  const total = db.prepare(`SELECT COUNT(*) c FROM export_records ${w}`).get(...args).c;
  const items = db.prepare(`SELECT * FROM export_records ${w} ORDER BY created_at DESC, id DESC LIMIT ? OFFSET ?`)
    .all(...args, lim, off);
  return { items, total, limit: lim, offset: off };
}

/** 清理 N 天前的记录（管理台用）。返回删掉的行数。 */
function purge(days) {
  const d = Math.max(Number(days) || 0, 1);
  const info = db.prepare('DELETE FROM export_records WHERE created_at < ?')
    .run(Date.now() - d * 86400 * 1000);
  return { deleted: Number(info.changes || 0), days: d };
}

module.exports = {
  KV_KEY, RETAIN_DAYS, DEFAULT_SETTINGS,
  getSettings, saveSettings,
  addRecord, listRecords, purge,
};
