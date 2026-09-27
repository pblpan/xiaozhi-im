'use strict';

/**
 * 应用覆盖层（管理台「应用中心 → 管理」把改动落到哪）
 *
 * ─────────────────────────────────────────────────────────────
 * 为什么要有这一层，而不是直接改 apps.js
 * ─────────────────────────────────────────────────────────────
 * apps.js 里的 BUILTIN_APPS 是**出厂定义**：随安装包发布、id 不可改名、每个应用
 * 为什么可见由业务状态（need）算出来。它是源码，不是数据。管理员在界面上改的东西
 * 如果写回源码，就出现两个后果：
 *   ① 升级安装包时被覆盖 —— 管理员白改；
 *   ② 没人能说出"现在线上这一版和出厂差在哪" —— 排障时最想要的一句话。
 *
 * 所以改成**覆盖层**：出厂定义只读，管理员的改动单独存一行，读的时候合并。
 * 于是"恢复出厂"就是删掉那一行，天然可逆，也不需要给每个字段准备"默认值快照"。
 *
 * ─────────────────────────────────────────────────────────────
 * 三条边界（越界的后果都是"看着能用其实不可控"）
 * ─────────────────────────────────────────────────────────────
 * 1. **只能覆盖内置应用**。动态模块（app_modules）本来就有完整的编辑能力
 *    （title/icon/sort/enabled/visibleTo），再套一层覆盖就是两处能改同一件事，
 *    迟早对不上。管理台对动态模块给的是"去编辑模块"，不是这个抽屉。
 *
 * 2. **`need` 不可覆盖**。它是"为什么这个入口该不该出现"的唯一判据
 *    （没开工作模式就没有考勤…）。放开它等于把可见性变成开关，
 *    必然配出"入口在、点进去报错"的状态 —— 这正是 apps.js 开头拒绝做的事。
 *
 * 3. **参数只登记"真的被读"的**。见 PARAM_SCHEMA：每一项都标了 `enforced`
 *    （server = 服务端当场生效 / client = 随下发生效，客户端下个版本读）。
 *    登记一个没人读的参数，比没有这个参数更糟 —— 管理员改完发现没效果，
 *    就再也不信这个页面上的任何东西了。
 */

const db = require('./db');
const appregistry = require('./apps');
const appmodules = require('./appmodules');
const appgroups = require('./appgroups');

const TITLE_MAX = 12;
const VERSION_RE = /^\d+\.\d+\.\d+$/;

/**
 * 通用参数：每个内置应用都有。
 * 放在 SDK 之外单独一组，是因为它跟"这个应用是干什么的"无关，
 * 是"这个入口发给谁"的策略。
 */
const COMMON_PARAMS = [
  {
    key: 'minClientVersion',
    label: '最低客户端版本',
    type: 'version',
    def: '',
    enforced: 'server',
    desc: '低于这个版本的客户端看不到入口（留空 = 不限）。用于"新功能只给已升级的人"。',
  },
];

/**
 * 各应用自己的参数。**只登记已经被代码读的参数**：
 *   enforced: 'server' → 服务端当场生效，改完下一次请求就能验出来
 *   enforced: 'client' → 服务端已随 /api/client/apps 下发，客户端下个版本开始读
 * 每一项都必须能在代码里指出"谁读它"，否则不要写在这里。
 */
const APP_PARAMS = {
  attendance: [
    {
      key: 'badge', label: '「待打卡」角标', type: 'bool', def: true, enforced: 'server',
      desc: '工作台图标上提示今天已经到点却还没打的卡。关掉就没有提醒，但打卡本身照旧。',
    },
  ],
  my_requests: [
    {
      key: 'badge', label: '待审批角标', type: 'bool', def: true, enforced: 'server',
      desc: '工作台图标上显示自己还没批下来的申请条数。',
    },
  ],
  att_admin: [
    {
      key: 'badge', label: '待审批角标', type: 'bool', def: true, enforced: 'server',
      desc: '工作台图标上显示全组织待处理申请条数（管理员的待办提醒）。',
    },
  ],
  work_org: [
    {
      key: 'showEmployeeNo', label: '显示工号', type: 'bool', def: true, enforced: 'server',
      desc: '关掉后通讯录不再下发工号（只显示姓名、部门、岗位）。',
    },
  ],
  stocktake: [
    {
      key: 'soundOnScan', label: '扫码音效', type: 'bool', def: true, enforced: 'client',
      desc: '扫到条码时播放提示音。',
    },
    {
      key: 'vibrateOnScan', label: '扫码震动', type: 'bool', def: true, enforced: 'client',
      desc: '扫到条码时震动一下（手机端）。',
    },
  ],
  inventory: [
    {
      key: 'soundOnScan', label: '扫码音效', type: 'bool', def: true, enforced: 'client',
      desc: '扫到条码时播放提示音。',
    },
  ],
  //
  // 电子秤码（生鲜称重码）的商品码位数。
  // 🔴 各软件不一样（泰格是 5 位），写在**类别属性**里，所以必须做成参数：
  //    写死 5 的话，换一套软件之后秤码会被解成别的商品、数量也跟着错，
  //    而全程**不报错**（扫出来还是个正常的条码样子）。
  //    谁读它：客户端 replenish 页（补货·生鲜），见 core/scale_code.dart。
  replenish: [
    {
      key: 'scaleCodeLen', label: '电子秤码的商品码位数', type: 'int', def: 5,
      min: 3, max: 8, enforced: 'client',
      desc: '生鲜秤打出来的条码里，"商品码"占几位（泰格是 5 位，13 位码 = 1 标识 + 5 商品码 + 5 重量 + 1 校验）。'
        + '改错的表现是秤码解成别的商品、数量跟着错，而且不报错 —— 按门店那套软件的类别属性填。',
    },
  ],
  training: [
    {
      key: 'showAnswer', label: '交卷后回显正确答案', type: 'bool', def: true, enforced: 'server',
      desc: '关掉后交卷只给分数与及格线，不给正确答案（防"考完就把答案传下去"）。',
    },
  ],
};

/** 某个应用支持的全部参数（通用 + 专属） */
function paramSchemaOf(appId) {
  return [...COMMON_PARAMS, ...(APP_PARAMS[appId] || [])];
}

function paramDefOf(appId, key) {
  return paramSchemaOf(appId).find((p) => p.key === key) || null;
}

function isObj(x) { return x && typeof x === 'object' && !Array.isArray(x); }

/* ---------------- 表 ---------------- */

db.exec(`
CREATE TABLE IF NOT EXISTS app_overrides (
  app_id     TEXT PRIMARY KEY,          -- 内置应用的出厂 id（不可改名，改名等于覆盖丢了）
  title      TEXT,                      -- NULL = 用出厂标题
  icon       TEXT,                      -- NULL = 用出厂图标
  sort       INTEGER,                   -- NULL = 用出厂次序（按 BUILTIN_APPS 数组序）
  disabled   INTEGER NOT NULL DEFAULT 0,-- 1 = 整应用停用（隐藏入口 + 后端每条接口拦）
  params     TEXT,                      -- JSON；只存**改过的键**（增量），没改的不落库
  updated_at INTEGER NOT NULL,
  updated_by TEXT
);
`);

/**
 * 分组 / 配色是 v0.22.0 才有的两列。老库没有它们，而 `CREATE TABLE IF NOT EXISTS`
 * 对已经存在的表是**空操作**（一行都不补），所以这里必须自己 ALTER 兜住 ——
 * 否则老库一启动，下面 `SELECT *` 读出来的行里就没有 group/color，
 * 表现出来是"管理员配了颜色，工作台一点反应没有"，而且不报任何错。
 * ⚠️ 只往后追加，别插到中间（SQLite 的 ALTER 追加列，位置动了会咬到别的迁移）。
 */
function ensureColumn(table, column, ddl) {
  const cols = db.prepare('SELECT name FROM pragma_table_info(?)').all(table);
  if (!cols.some((c) => c.name === column)) {
    db.exec(`ALTER TABLE ${table} ADD COLUMN ${ddl}`);
    console.log(`[小智IM] 迁移：${table}.${column} 已添加`);
  }
}
// ⚠️ `group` 是 SQLite 关键字，SQL 里必须加双引号，否则报 syntax error
ensureColumn('app_overrides', 'group', '"group" TEXT');  // 挪到别的分组（也可以填自定义组名）
ensureColumn('app_overrides', 'color', 'color TEXT');  // 图标底色 #RRGGBB；NULL = 用出厂色

/* ---------------- 读 ---------------- */

function rowToOverride(r) {
  let params = {};
  try { params = JSON.parse(r.params || '{}'); } catch { params = {}; }
  return {
    appId: r.app_id,
    title: r.title || null,
    icon: r.icon || null,
    sort: r.sort == null ? null : Number(r.sort),
    group: r.group || null,
    color: r.color || null,
    disabled: !!r.disabled,
    params: isObj(params) ? params : {},
    updatedAt: r.updated_at,
    updatedBy: r.updated_by || '',
  };
}

/** 全部覆盖（管理台用，含未改动的应用的"没有覆盖"也由调用方自己补） */
function list() {
  return db.prepare('SELECT * FROM app_overrides ORDER BY app_id').all().map(rowToOverride);
}

/** 按 id 取覆盖；没有则 null */
function get(appId) {
  const r = db.prepare('SELECT * FROM app_overrides WHERE app_id=?').get(String(appId));
  return r ? rowToOverride(r) : null;
}

/**
 * 一次取全部、按 id 索引 —— 客户端 /api/client/apps 每次冷启动都要用，
 * 逐条 get() 是 N 次查询（应用只有几个，但没必要）。
 */
function map() {
  const out = {};
  for (const o of list()) out[o.appId] = o;
  return out;
}

/** 是否被整应用停用（appguard 每个请求都要问一次，走主键查询） */
function isDisabled(appId) {
  const r = db.prepare('SELECT disabled FROM app_overrides WHERE app_id=?').get(String(appId));
  return !!(r && r.disabled);
}

/** 某应用的生效参数（出厂默认 + 覆盖），键值对 */
function paramsOf(appId) {
  const ov = get(appId);
  const out = {};
  for (const p of paramSchemaOf(appId)) out[p.key] = p.def;
  if (ov) {
    for (const [k, v] of Object.entries(ov.params)) {
      // 只采纳现在还登记着的键：老版本存过、后来从注册表删掉的参数当作不存在，
      // 免得一个"幽灵参数"一直影响行为而界面上看不见它。
      if (paramDefOf(appId, k)) out[k] = v;
    }
  }
  return out;
}

/** 取单个参数值（带出厂默认兜底） */
function paramOf(appId, key) {
  const def = paramDefOf(appId, key);
  const fallback = def ? def.def : undefined;
  const ov = get(appId);
  if (ov && Object.prototype.hasOwnProperty.call(ov.params, key) && def) return ov.params[key];
  return fallback;
}

/**
 * 把覆盖合并到出厂定义上（纯函数，不查库）。
 * 传 null/undefined 的覆盖 = 原样返回出厂定义。
 */
function applyTo(app, ov) {
  if (!ov) return { ...app, disabled: false };
  return {
    ...app,
    title: ov.title || app.title,
    icon: ov.icon || app.icon,
    sort: ov.sort == null ? app.sort : ov.sort,
    group: ov.group || app.group,
    color: ov.color || app.color || null,
    disabled: !!ov.disabled,
  };
}

/* ---------------- 写 ---------------- */

/** 校验单个参数值。返回 { value } 或 { error } */
function cleanParam(appId, key, raw) {
  const def = paramDefOf(appId, key);
  if (!def) return { error: `应用 ${appId} 没有参数 ${key}` };
  const v = raw;
  if (def.type === 'bool') return { value: !!v };
  if (def.type === 'version') {
    const s = String(v == null ? '' : v).trim();
    // 空 = 不限，是合法值（而且是最常用的那个）
    if (s === '') return { value: '' };
    if (!VERSION_RE.test(s)) return { error: `${def.label} 需要是 X.Y.Z 格式或留空（当前：${s}）` };
    return { value: s };
  }
  if (def.type === 'int') {
    const n = Number(v);
    if (!Number.isFinite(n)) return { error: `${def.label} 需要是数字` };
    const i = Math.trunc(n);
    if (def.min != null && i < def.min) return { error: `${def.label} 不能小于 ${def.min}` };
    if (def.max != null && i > def.max) return { error: `${def.label} 不能大于 ${def.max}` };
    return { value: i };
  }
  if (def.type === 'enum') {
    const s = String(v == null ? '' : v);
    if (!(def.options || []).some((o) => o.value === s)) {
      return { error: `${def.label} 只能是：${(def.options || []).map((o) => o.value).join(' / ')}` };
    }
    return { value: s };
  }
  return { error: `参数 ${key} 的类型 ${def.type} 未实现校验` };
}

/**
 * 写覆盖（PATCH 语义）。
 *
 * 三种"没给"的语义必须分清楚，否则管理台点一次"保存"就会把没碰过的字段清掉：
 *   字段不存在        → 保持原值（不写）
 *   字段 = null       → 清回出厂（title/icon/sort/params 里的某个键都适用）
 *   字段 = 具体值     → 覆盖
 *
 * 返回 { override } 或 { error }。
 */
function set(appId, patch, by) {
  const id = String(appId || '');
  const factory = appregistry.BUILTIN_APPS.find((a) => a.id === id);
  // 只认内置应用：动态模块有自己的编辑能力，两处可改同一件事迟早对不上
  if (!factory) return { error: `不是内置应用：${id || '(空)'}` };
  if (!isObj(patch)) return { error: '提交内容必须是一个对象' };

  const cur = get(id) || { title: null, icon: null, sort: null, group: null, color: null, disabled: false, params: {} };
  let title = cur.title;
  let icon = cur.icon;
  let sort = cur.sort;
  let group = cur.group;
  let color = cur.color;
  let disabled = !!cur.disabled;
  const params = { ...cur.params };

  if ('title' in patch) {
    if (patch.title === null || patch.title === '') title = null;
    else {
      const t = String(patch.title).trim();
      if (!t) title = null;
      else if ([...t].length > TITLE_MAX) return { error: `应用名称最多 ${TITLE_MAX} 个字（当前 ${[...t].length} 个）` };
      else title = t;
    }
  }

  if ('icon' in patch) {
    if (patch.icon === null || patch.icon === '') icon = null;
    else {
      const ic = String(patch.icon);
      // 图标名必须落在白名单里：客户端按名字查表，表里没有就退化成通用图标，
      // 管理员看到的是"改了个没反应的图标"，比报错更难查
      if (!appmodules.ICONS.includes(ic)) {
        return { error: `图标 ${ic} 不在可选清单里（见 /api/admin/modules 的 icons）` };
      }
      icon = ic;
    }
  }

  if ('sort' in patch) {
    if (patch.sort === null || patch.sort === '') sort = null;
    else {
      const n = Number(patch.sort);
      if (!Number.isFinite(n)) return { error: '排序号需要是数字' };
      sort = Math.max(0, Math.min(9999, Math.trunc(n)));
    }
  }

  // 挪分组：清空 = 回到出厂组；填了值就得是个能用的组名
  // （自定义组由管理台先建，这里只校验"这个组存不存在"）。
  // 不校验的话管理员会把应用挪到一个还没人用、也还没建的组里，
  // 结果就是那个应用在工作台彻底消失、管理台列表里却还在 —— 最难查那种。
  if ('group' in patch) {
    if (patch.group === null || patch.group === '') group = null;
    else {
      const g = String(patch.group).trim();
      if (!g) group = null;
      else if (!appgroups.exists(g)) return { error: `分组 ${g} 不存在（请先到「分组管理」新建）` };
      else group = g;
    }
  }

  // 图标底色：必须是个颜色。写错了的表现是图标变成一片黑或透明，
  // 不报错、也不难看，但就是"配了没效果" —— 所以在这里就挡住。
  if ('color' in patch) {
    if (patch.color === null || patch.color === '') color = null;
    else {
      const c = String(patch.color).trim();
      if (!/^#[0-9A-Fa-f]{6}$/.test(c)) return { error: `配色需要是 #RRGGBB 格式（例：#2B6FE0），当前：${c}` };
      color = c.toUpperCase();
    }
  }

  if ('disabled' in patch) disabled = !!patch.disabled;

  if ('params' in patch && patch.params !== null && patch.params !== undefined) {
    if (!isObj(patch.params)) return { error: 'params 必须是对象' };
    for (const [k, v] of Object.entries(patch.params)) {
      const c = cleanParam(id, k, v);
      if (c.error) return { error: c.error };
      const def = paramDefOf(id, k);
      // 值等于出厂默认 = **不覆盖**（把键删掉，而不是存一个"和默认一样的值"）。
      // 两条好处：管理台的「还原」按钮天然可用（送出厂值即可）；
      // 一个参数被还原后，整个应用会自动回到"与出厂一致"的状态，
      // 而不是留一行"看着改了其实没改"的记录。
      if (def && c.value === def.def) delete params[k];
      else params[k] = c.value;
    }
  }
  // params: 'reset' 用显式字符串表达"恢复全部出厂参数"，
  // 因为 null 已经被"整个字段清空"占用，不能再兼一个意思
  if (patch.params === 'reset') {
    for (const k of Object.keys(params)) delete params[k];
  }

  const now = Date.now();
  db.prepare(`
    INSERT INTO app_overrides (app_id, title, icon, sort, "group", color, disabled, params, updated_at, updated_by)
    VALUES (?,?,?,?,?,?,?,?,?,?)
    ON CONFLICT(app_id) DO UPDATE SET
      title=excluded.title, icon=excluded.icon, sort=excluded.sort,
      "group"=excluded."group", color=excluded.color,
      disabled=excluded.disabled, params=excluded.params,
      updated_at=excluded.updated_at, updated_by=excluded.updated_by
  `).run(
    id, title, icon, sort, group, color, disabled ? 1 : 0, JSON.stringify(params),
    now, String(by || 'admin').slice(0, 60),
  );

  // 全出厂 = 没必要留一行"什么都没改"的记录，删掉更干净
  const fresh = get(id);
  if (fresh && isPristine(fresh)) {
    db.prepare('DELETE FROM app_overrides WHERE app_id=?').run(id);
    return { override: null };
  }
  return { override: fresh };
}

/** 这一行是不是跟出厂完全一样（用来决定要不要保留这行） */
function isPristine(ov) {
  return !ov.title && !ov.icon && ov.sort == null && !ov.group && !ov.color && !ov.disabled
    && (!ov.params || Object.keys(ov.params).length === 0);
}

/** 恢复出厂：删行（不是写空值 —— 删了才真的回到"和出厂逐字一致"） */
function reset(appId) {
  const id = String(appId || '');
  if (!appregistry.BUILTIN_APPS.some((a) => a.id === id)) return { error: `不是内置应用：${id}` };
  const r = db.prepare('DELETE FROM app_overrides WHERE app_id=?').run(id);
  return { removed: r.changes > 0 };
}

/* ---------------- 管理台视图 ---------------- */

/**
 * 给管理台的一行完整视图：出厂值 + 覆盖值 + 生效值 + 参数明细。
 * 三列都给出来（factory / override / effective）是刻意的：
 * 管理员最需要回答的问题是"这一版和出厂差在哪"，只给生效值他答不出来。
 */
function view(appId, ctx) {
  const factory = appregistry.BUILTIN_APPS.find((a) => a.id === appId);
  if (!factory) return null;
  const ov = get(appId);
  const merged = applyTo(factory, ov);
  const params = paramSchemaOf(appId).map((p) => {
    const overridden = !!(ov && Object.prototype.hasOwnProperty.call(ov.params, p.key));
    return {
      key: p.key, label: p.label, type: p.type, def: p.def,
      desc: p.desc, enforced: p.enforced,
      options: p.options || null, min: p.min ?? null, max: p.max ?? null,
      value: overridden ? ov.params[p.key] : p.def,
      overridden,
    };
  });
  return {
    id: factory.id,
    factory: {
      title: factory.title, icon: factory.icon, group: factory.group,
      color: factory.color || null,
      desc: factory.desc, sort: null, need: factory.need || null,
    },
    override: ov ? {
      title: ov.title, icon: ov.icon, sort: ov.sort, group: ov.group, color: ov.color,
      disabled: ov.disabled, params: ov.params,
      updatedAt: ov.updatedAt, updatedBy: ov.updatedBy,
    } : null,
    effective: {
      title: merged.title, icon: merged.icon, group: merged.group,
      color: merged.color || null,
      desc: merged.desc, sort: merged.sort, disabled: merged.disabled,
    },
    changed: !!ov,
    changedFields: ov ? changedFieldsOf(factory, ov) : [],
    params,
    visibleForAdmin: ctx ? ctx.visibleIds.includes(factory.id) : null,
  };
}

/** 和出厂的差异清单（管理台在列表上直接显示"已改：名称 / 已停用"） */
function changedFieldsOf(factory, ov) {
  const out = [];
  if (ov.title && ov.title !== factory.title) out.push({ key: 'title', label: '名称', from: factory.title, to: ov.title });
  if (ov.icon && ov.icon !== factory.icon) out.push({ key: 'icon', label: '图标', from: factory.icon, to: ov.icon });
  if (ov.sort != null) out.push({ key: 'sort', label: '排序', from: null, to: ov.sort });
  if (ov.group && ov.group !== factory.group) {
    out.push({ key: 'group', label: '分组', from: factory.group, to: ov.group });
  }
  if (ov.color && ov.color !== (factory.color || null)) {
    out.push({ key: 'color', label: '配色', from: factory.color || null, to: ov.color });
  }
  if (ov.disabled) out.push({ key: 'disabled', label: '停用', from: false, to: true });
  for (const [k, v] of Object.entries(ov.params || {})) {
    const def = paramDefOf(factory.id, k);
    if (!def) continue;
    if (v === def.def) continue;
    out.push({ key: `params.${k}`, label: def.label, from: def.def, to: v });
  }
  return out;
}

module.exports = {
  TITLE_MAX,
  COMMON_PARAMS, APP_PARAMS, paramSchemaOf, paramDefOf,
  list, get, map, isDisabled, paramsOf, paramOf,
  applyTo, set, reset, view, changedFieldsOf,
};
