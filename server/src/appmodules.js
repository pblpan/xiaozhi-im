/**
 * 动态模块中心（SPEC-动态配置与模块.md 第二期）
 *
 * 一句话职责：让管理员在管理台拼出页面，客户端不重装就能出现入口并渲染。
 *
 * 三条硬规矩（违反任何一条都会把"运营能力"变成"攻击面"）：
 * 1. **封闭组件集**：只有 8 种组件，未知组件名直接拒绝发布（客户端侧也会兜底占位，
 *    但服务端必须先挡住，"客户端不崩"不能当成服务端不校验的借口）。
 * 2. **动作白名单 + /api/hooks/ 前缀**：动态页面永远不能指定完整 URL，
 *    否则一个"值班表"页面就能变成 SSRF 跳板。
 * 3. **颜色只允许语义枚举**：不许写死色值，否则深色主题下会出现"黑底黑字"。
 *
 * 另外两个防呆上限（MAX_DEPTH / MAX_COMPONENTS）是为了防"手滑粘贴出 5000 层嵌套"
 * 把客户端渲染线程打死——服务端发布时拦下，比客户端卡死后再排查便宜得多。
 */
const db = require('./db');

/** 8 种封闭组件（SPEC §4.3）。加第 9 种之前先证明这 8 种表达不了 */
const COMPONENTS = ['text', 'divider', 'card', 'list', 'table', 'form', 'action', 'chart'];

/** 容器类组件（可递归包含子组件） */
const CONTAINERS = ['card'];

/** 颜色语义枚举（SPEC §4.3 拍板项 3：深色自适应靠客户端主题令牌映射） */
const COLORS = ['primary', 'muted', 'danger', 'success', 'warning', 'default'];

/** 表单字段类型 */
const FIELD_TYPES = ['text', 'number', 'select', 'date', 'textarea', 'switch'];

/** 动作白名单（SPEC §4.4） */
const ACTIONS = ['api', 'navigate', 'copy', 'openUrl', 'submit'];

/** navigate 只能跳客户端内置页面，避免用动态配置把用户骗进任意界面 */
const NAV_PAGES = ['conversations', 'contacts', 'settings', 'favorites', 'profile', 'about'];

/** 图标白名单：客户端按名字查表，名字不存在就显示默认图标，不会崩 */
const ICONS = [
  'inventory', 'build', 'list', 'table_chart', 'assessment', 'note', 'report',
  'people', 'schedule', 'store', 'factory', 'restaurant', 'local_shipping',
  'attach_money', 'shopping_cart', 'warning', 'info', 'settings', 'dashboard',
  'campaign', 'task', 'engineering', 'handyman', 'receipt_long', 'barcode',
  'school', 'smart_toy',
];

/** 图表类型 */
const CHART_KINDS = ['bar', 'line'];

const MODULE_ID_RE = /^[a-z][a-z0-9_]{1,39}$/;
const VERSION_RE = /^\d+\.\d+\.\d+$/;
const DATAPATH_RE = /^[a-zA-Z0-9_.[\]]{1,64}$/;

const MAX_DEPTH = 4;        // card 嵌套层数上限
const MAX_COMPONENTS = 150; // 单个模块组件总数上限
const MAX_FIELDS = 30;      // 单个表单字段数上限
const MAX_COLUMNS = 12;     // 表格列数上限
const MAX_OPTIONS = 50;     // select 选项数上限
const MAX_TEXT = 2000;      // 长文本上限

function isObj(x) { return x && typeof x === 'object' && !Array.isArray(x); }
function str(x, max) { return typeof x === 'string' ? x.slice(0, max || 200) : ''; }

/** 版本比较：a >= b 返回 true。非法版本一律当作"不满足"，宁可不显示也不冒险 */
function versionGte(a, b) {
  if (!VERSION_RE.test(String(a || '')) || !VERSION_RE.test(String(b || ''))) return false;
  const pa = String(a).split('.').map(Number);
  const pb = String(b).split('.').map(Number);
  for (let i = 0; i < 3; i++) {
    if (pa[i] !== pb[i]) return pa[i] > pb[i];
  }
  return true;
}

/** 校验动作对象。返回 { ok, action } 或 { error } */
function validateAction(raw) {
  if (!isObj(raw)) return { error: '动作必须是一个对象' };
  const kind = String(raw.action || '');
  if (!ACTIONS.includes(kind)) {
    return { error: `不支持的动作：${kind || '(空)'}（允许：${ACTIONS.join('、')}）` };
  }
  const out = { action: kind };

  if (kind === 'api' || kind === 'submit') {
    const path = String(raw.path || '').trim();
    // 关键安全约束：只允许 /api/hooks/ 前缀，杜绝任意 URL 转发（SSRF）
    if (!path.startsWith('/api/hooks/')) {
      return { error: `${kind} 的 path 必须以 /api/hooks/ 开头（当前：${path || '空'}）` };
    }
    if (!/^[A-Za-z0-9_\-/]{1,120}$/.test(path)) return { error: `path 含非法字符：${path}` };
    const method = String(raw.method || 'GET').toUpperCase();
    if (!['GET', 'POST'].includes(method)) return { error: `method 只允许 GET/POST（当前：${method}）` };
    out.path = path;
    out.method = method;
  }

  if (kind === 'navigate') {
    const page = String(raw.page || '').trim();
    if (!NAV_PAGES.includes(page)) {
      return { error: `navigate 的 page 必须是内置页面之一（${NAV_PAGES.join('、')}），当前：${page || '空'}` };
    }
    out.page = page;
  }

  if (kind === 'copy') {
    const text = String(raw.text || '').trim();
    const dataPath = String(raw.dataPath || '').trim();
    if (!text && !dataPath) return { error: 'copy 需要提供 text 或 dataPath' };
    if (text) out.text = text.slice(0, MAX_TEXT);
    if (dataPath) {
      if (!DATAPATH_RE.test(dataPath)) return { error: `dataPath 不合法：${dataPath}` };
      out.dataPath = dataPath;
    }
  }

  if (kind === 'openUrl') {
    const url = String(raw.url || '').trim();
    // 强制 https：http 页面可被中间人替换成钓鱼页
    if (!/^https:\/\//i.test(url)) return { error: 'openUrl 必须以 https:// 开头（不接受 http）' };
    out.url = url.slice(0, 500);
  }

  return { action: out };
}

/** 校验单个组件（depth 用于限制嵌套，stats 用于限制总数） */
function validateComponent(raw, depth, stats) {
  if (!isObj(raw)) return { error: '组件必须是一个对象' };
  const type = String(raw.component || '');
  if (!COMPONENTS.includes(type)) {
    return { error: `不支持的组件：${type || '(空)'}（允许：${COMPONENTS.join('、')}）` };
  }
  stats.count++;
  if (stats.count > MAX_COMPONENTS) return { error: `组件总数超过上限 ${MAX_COMPONENTS}` };

  const out = { component: type };

  if (type === 'text') {
    const t = String(raw.text ?? '').trim();
    if (!t) return { error: 'text 组件的 text 不能为空' };
    out.text = t.slice(0, MAX_TEXT);
    if (raw.size !== undefined) {
      const s = Number(raw.size);
      if (!Number.isFinite(s) || s < 8 || s > 40) return { error: `text 的 size 需在 8~40 之间（当前：${raw.size}）` };
      out.size = s;
    }
    if (raw.color !== undefined) {
      if (!COLORS.includes(raw.color)) return { error: `color 只允许语义枚举：${COLORS.join('、')}` };
      out.color = raw.color;
    }
    if (raw.align !== undefined) {
      if (!['left', 'center', 'right'].includes(raw.align)) return { error: 'align 只允许 left/center/right' };
      out.align = raw.align;
    }
  }

  if (type === 'card') {
    out.title = str(raw.title, 60);
    out.subtitle = str(raw.subtitle, 120);
    if (raw.accent !== undefined) {
      if (!COLORS.includes(raw.accent)) return { error: `accent 只允许语义枚举：${COLORS.join('、')}` };
      out.accent = raw.accent;
    }
    if (!Array.isArray(raw.children)) return { error: 'card 必须有 children 数组（可为空数组）' };
    if (depth + 1 > MAX_DEPTH) return { error: `容器嵌套超过 ${MAX_DEPTH} 层` };
    const kids = [];
    for (const c of raw.children) {
      const r = validateComponent(c, depth + 1, stats);
      if (r.error) return r;
      kids.push(r.component);
    }
    if (kids.length > 30) return { error: 'card 的子组件最多 30 个' };
    out.children = kids;
  }

  if (type === 'list') {
    if (!DATAPATH_RE.test(String(raw.dataPath || ''))) return { error: 'list 需要合法的 dataPath' };
    out.dataPath = raw.dataPath;
    const tpl = raw.itemTemplate;
    if (!isObj(tpl)) return { error: 'list 需要 itemTemplate 对象' };
    out.itemTemplate = {
      title: str(tpl.title, 120),
      subtitle: str(tpl.subtitle, 200),
      trailing: str(tpl.trailing, 80),
    };
    if (!out.itemTemplate.title) return { error: 'list 的 itemTemplate.title 不能为空' };
  }

  if (type === 'table') {
    if (!DATAPATH_RE.test(String(raw.dataPath || ''))) return { error: 'table 需要合法的 dataPath' };
    out.dataPath = raw.dataPath;
    if (!Array.isArray(raw.columns) || !raw.columns.length) return { error: 'table 需要非空 columns 数组' };
    if (raw.columns.length > MAX_COLUMNS) return { error: `表格列数最多 ${MAX_COLUMNS}` };
    out.columns = raw.columns.map((c) => ({
      key: str(c?.key, 40),
      label: str(c?.label || c?.key, 40),
      width: Number.isFinite(Number(c?.width)) ? Number(c.width) : undefined,
    })).filter((c) => c.key);
    if (!out.columns.length) return { error: 'table 的 columns 至少需要一个合法 key' };
  }

  if (type === 'form') {
    if (!Array.isArray(raw.fields) || !raw.fields.length) return { error: 'form 需要非空 fields 数组' };
    if (raw.fields.length > MAX_FIELDS) return { error: `表单字段最多 ${MAX_FIELDS} 个` };
    const fields = [];
    for (const f of raw.fields) {
      const key = str(f?.key, 40);
      if (!/^[a-zA-Z][a-zA-Z0-9_]{0,39}$/.test(key)) return { error: `表单字段名不合法：${f?.key || '(空)'}` };
      if (!FIELD_TYPES.includes(f?.type)) return { error: `字段 ${key} 的类型不支持：${f?.type || '(空)'}（允许：${FIELD_TYPES.join('、')}）` };
      const item = {
        key,
        label: str(f.label || key, 60),
        type: f.type,
        required: !!f.required,
      };
      if (f.placeholder !== undefined) item.placeholder = str(f.placeholder, 80);
      if (f.type === 'select') {
        // 动态下拉（2026-10-18）：options 还能从一个数据源现取 —— 班次、员工、
        // 商品分类这种"会变的清单"不可能写死在模板里（写死的结果是模板建好
        // 三天后就少一项，而没人知道去哪补）。
        //   optionsFrom  取数的接口路径（与 action 同一套白名单：只允许 /api/hooks/）
        //   optionsPath  响应里选项数组的位置（默认 data.rows，与表格组件同口径）
        //   optionLabel / optionValue  每项里哪个字段当显示文本 / 当值（默认 label/value）
        // 声明了 optionsFrom 就不再要求静态 options（二选一），否则维持老规矩。
        if (f.optionsFrom !== undefined) {
          const from = String(f.optionsFrom || '').trim();
          if (!from.startsWith('/api/hooks/')) {
            return { error: `字段 ${key} 的 optionsFrom 必须以 /api/hooks/ 开头（当前：${from || '空'}）` };
          }
          if (!/^[A-Za-z0-9_\-/?=&.]{1,160}$/.test(from)) return { error: `字段 ${key} 的 optionsFrom 含非法字符` };
          item.optionsFrom = from;
          item.optionsPath = DATAPATH_RE.test(String(f.optionsPath || '')) ? f.optionsPath : 'data.rows';
          item.optionLabel = str(f.optionLabel, 40) || 'label';
          item.optionValue = str(f.optionValue, 40) || 'value';
        }
        if (item.optionsFrom && !(Array.isArray(f.options) && f.options.length)) {
          // 动态源自己供选项，静态 options 可省略
        } else {
          if (!Array.isArray(f.options) || !f.options.length) return { error: `字段 ${key} 是 select，必须有 options（或声明 optionsFrom 走动态下拉）` };
          if (f.options.length > MAX_OPTIONS) return { error: `字段 ${key} 的 options 最多 ${MAX_OPTIONS} 个` };
          item.options = f.options.slice(0, MAX_OPTIONS).map((o) => ({
            label: str(o?.label ?? o?.value, 60),
            value: String(o?.value ?? ''),
          })).filter((o) => o.value !== '');
          if (!item.options.length) return { error: `字段 ${key} 的 options 没有合法项` };
        }
      }
      fields.push(item);
    }
    out.fields = fields;
    if (raw.submit !== undefined) {
      const a = validateAction(raw.submit);
      if (a.error) return { error: `form.submit：${a.error}` };
      out.submit = a.action;
    }
  }

  if (type === 'action') {
    const label = String(raw.label ?? '').trim();
    if (!label) return { error: 'action 的 label 不能为空' };
    out.label = label.slice(0, 40);
    if (raw.onTap !== undefined) {
      const a = validateAction(raw.onTap);
      if (a.error) return { error: `action.onTap：${a.error}` };
      out.onTap = a.action;
    }
    if (raw.color !== undefined) {
      if (!COLORS.includes(raw.color)) return { error: `color 只允许语义枚举：${COLORS.join('、')}` };
      out.color = raw.color;
    }
  }

  if (type === 'chart') {
    if (!DATAPATH_RE.test(String(raw.dataPath || ''))) return { error: 'chart 需要合法的 dataPath' };
    out.dataPath = raw.dataPath;
    out.xKey = str(raw.xKey, 40) || 'x';
    out.yKey = str(raw.yKey, 40) || 'y';
    const kind = String(raw.kind || 'bar');
    if (!CHART_KINDS.includes(kind)) return { error: `chart 的 kind 只允许 ${CHART_KINDS.join('、')}` };
    out.kind = kind;
  }

  return { component: out };
}

/** 校验完整模块定义。返回 { module } 或 { error } */
function validate(input, { partial = false } = {}) {
  if (!isObj(input)) return { error: '模块定义必须是一个对象' };

  const out = {};

  if (input.moduleId !== undefined || !partial) {
    const id = String(input.moduleId || '').trim();
    if (!MODULE_ID_RE.test(id)) {
      return { error: `moduleId 不合法：${id || '(空)'}（需小写字母开头，仅含小写字母/数字/下划线，2~40 位）` };
    }
    out.moduleId = id;
  }
  if (input.moduleId !== undefined && partial) out.moduleId = String(input.moduleId).trim();

  if (input.title !== undefined || !partial) {
    const t = String(input.title || '').trim();
    if (!t) return { error: 'title 不能为空' };
    out.title = t.slice(0, 40);
  }

  if (input.icon !== undefined) {
    out.icon = ICONS.includes(input.icon) ? input.icon : 'dashboard';
  } else if (!partial) {
    out.icon = 'dashboard';
  }

  if (input.minClientVersion !== undefined) {
    const v = input.minClientVersion;
    if (v === null || v === '' || v === undefined) out.minClientVersion = null;
    else if (typeof v === 'string' && VERSION_RE.test(v.trim())) out.minClientVersion = v.trim();
    else return { error: 'minClientVersion 必须是 X.Y.Z 格式或为空' };
  } else if (!partial) {
    out.minClientVersion = null;
  }

  if (input.sort !== undefined) {
    const s = Number(input.sort);
    out.sort = Number.isFinite(s) ? Math.max(0, Math.min(9999, Math.trunc(s))) : 0;
  } else if (!partial) {
    out.sort = 0;
  }

  // ── 分组（v0.28.8：自定义模块与内置应用共用同一套工作台分组）──────────────
  // 2026-10-17 之前这里没有 group：客户端把模块一律塞进 custom 组、拼在
  // 内置应用后面，于是"管理台把模块拖到第一行"在手机上一动不动 ——
  // 序号统一了，落脚点却没统一，顺序仍然形同虚设。
  // 现在 group 与内置应用的 app_overrides.group 是同一个字段、同一批 key。
  if (input.group !== undefined) {
    if (input.group === null || input.group === '') {
      out.group = 'custom'; // 清空 = 回默认组，不给 null（列有默认值，NULL 会让客户端兜底猜）
    } else {
      const k = String(input.group).trim();
      // 懒 require：appgroups.js 顶层 require 本文件，顶层互相 require 会拿到
      // 半成品 exports（Node 循环依赖的经典坑），放函数里就只剩"调用时已加载完"。
      const appgroups = require('./appgroups');
      if (!appgroups.exists(k)) {
        return { error: `分组不存在：${k}（先去「工作台版式 → 分组管理」新建，或选一个已有分组）` };
      }
      out.group = k;
    }
  } else if (!partial) {
    out.group = 'custom';
  }

  // ── 图标底色（v0.28.8）──────────────────────────────────────────────
  // 与内置应用的 app_overrides.color 对齐：管理台能显式指定，不指定就走
  // moduleColorOf 的稳定散列兜底（见 apps.js 的说明）。
  if (input.color !== undefined) {
    if (input.color === null || input.color === '') {
      out.color = null; // 显式清空 = 回到按 moduleId 散列的兜底色
    } else {
      const c = String(input.color).trim();
      if (!/^#[0-9A-Fa-f]{6}$/.test(c) && !COLORS.includes(c)) {
        return { error: `color 只能是 #RRGGBB 或语义色（${COLORS.join('、')}）` };
      }
      out.color = c;
    }
  }

  if (input.enabled !== undefined) out.enabled = !!input.enabled;
  else if (!partial) out.enabled = true;

  if (input.visibleTo !== undefined) {
    const v = input.visibleTo;
    if (!isObj(v)) return { error: 'visibleTo 必须是对象' };
    const roles = Array.isArray(v.roles) ? v.roles.map((r) => String(r)).filter((r) => /^[a-z_]{1,20}$/.test(r)) : [];
    const userIds = Array.isArray(v.userIds) ? v.userIds.map(Number).filter(Number.isInteger) : [];
    out.visibleTo = { roles: roles.slice(0, 20), userIds: userIds.slice(0, 200) };
  } else if (!partial) {
    out.visibleTo = { roles: [], userIds: [] };
  }

  if (input.body !== undefined || !partial) {
    if (!Array.isArray(input.body)) return { error: 'body 必须是组件数组（可为空数组）' };
    const stats = { count: 0 };
    const body = [];
    for (const c of input.body) {
      const r = validateComponent(c, 1, stats);
      if (r.error) return { error: r.error };
      body.push(r.component);
    }
    out.body = body;
  }

  if (input.onLoad !== undefined) {
    if (input.onLoad === null) out.onLoad = null;
    else {
      const a = validateAction(input.onLoad);
      if (a.error) return { error: `onLoad：${a.error}` };
      out.onLoad = a.action;
    }
  }

  return { module: out };
}

function rowToModule(r) {
  let schema = {};
  try { schema = JSON.parse(r.schema || '{}'); } catch { schema = {}; }
  let roles = [];
  let userIds = [];
  try { roles = JSON.parse(r.visible_roles || '[]'); } catch { roles = []; }
  try { userIds = JSON.parse(r.visible_user_ids || '[]'); } catch { userIds = []; }
  return {
    moduleId: r.module_id,
    title: r.title,
    icon: r.icon,
    ...schema,
    minClientVersion: r.min_client_version || null,
    enabled: !!r.enabled,
    sort: r.sort || 0,
    // v0.28.8：分组与配色。老库没有这两列，迁移见下面的 ensureColumn。
    group: r.group || 'custom',
    color: r.color || null,
    visibleTo: { roles, userIds },
    updatedAt: r.updated_at,
  };
}

/* ---------------- 表结构迁移（只往后追加列） ---------------- */

/**
 * `group` / `color` 是 v0.28.8 才有的两列（自定义模块与内置应用统一分组、统一配色）。
 * `CREATE TABLE IF NOT EXISTS` 对已存在的表是空操作，老库不会自己补列，
 * 而 `SELECT *` 读出来就少字段 —— 表现是"管理台明明能选分组，工作台一动不动"。
 * 做法照 appoverrides.js 的 ensureColumn：先查 pragma 再 ALTER，幂等。
 * ⚠️ `group` 是 SQLite 关键字，DDL 里必须加双引号。
 */
function ensureColumn(table, column, ddl) {
  const cols = db.prepare('SELECT name FROM pragma_table_info(?)').all(table);
  if (!cols.some((c) => c.name === column)) {
    db.exec(`ALTER TABLE ${table} ADD COLUMN ${ddl}`);
    console.log(`[小智IM] 迁移：${table}.${column} 已添加`);
  }
}
ensureColumn('app_modules', 'group', '"group" TEXT');   // 工作台分组 key（默认 custom）
ensureColumn('app_modules', 'color', 'color TEXT');     // 图标底色 #RRGGBB / 语义色；NULL = 散列兜底

/** 全部模块（管理台用，含未启用） */
function list() {
  return db.prepare('SELECT * FROM app_modules ORDER BY sort ASC, id ASC').all().map(rowToModule);
}

function get(moduleId) {
  const r = db.prepare('SELECT * FROM app_modules WHERE module_id=?').get(String(moduleId));
  return r ? rowToModule(r) : null;
}

/**
 * 下发给客户端的模块列表。
 * 过滤顺序刻意如此：先 enabled → 再版本 → 再可见性。
 * 版本过滤放在可见性之前，是为了让"老客户端看不到新模块"这件事与用户身份无关，
 * 排障时一眼能判断是版本问题还是权限问题。
 */
function listVisible({ userId, role, clientVersion } = {}) {
  return list().filter((m) => {
    if (!m.enabled) return false;
    if (m.minClientVersion && !versionGte(clientVersion, m.minClientVersion)) return false;
    const v = m.visibleTo || { roles: [], userIds: [] };
    // roles/userIds 都为空 = 不限（对所有人可见）
    if (!v.roles.length && !v.userIds.length) return true;
    if (v.userIds.length && userId != null && v.userIds.includes(Number(userId))) return true;
    if (v.roles.length && role && v.roles.includes(String(role))) return true;
    return false;
  });
}

function upsert(input, by) {
  const src = isObj(input) ? input : {};
  const v = validate(src);
  if (v.error) return { error: v.error };
  const m = v.module;
  const { moduleId, visibleTo, ...schemaRest } = m;
  const schema = { body: m.body, onLoad: m.onLoad };
  const now = Date.now();
  // 🔴 group / color 是 v0.28.8 才有的两列，而 validate 对"没给"的字段会补默认值
  //    （custom / null）—— 直接用它写库，等于"用旧编辑器保存一次，分组和配色
  //    就被悄悄打回默认"。所以这里按"没给就不动"的口径先读回原值，
  //    与 appoverrides.set 的 PATCH 语义保持一致。
  const cur = db.prepare('SELECT "group", color FROM app_modules WHERE module_id=?').get(moduleId);
  const group = src.group === undefined ? (cur ? cur.group || 'custom' : 'custom') : m.group;
  const color = src.color === undefined ? (cur ? (cur.color == null ? null : cur.color) : null) : (m.color == null ? null : m.color);
  db.prepare(`
    INSERT INTO app_modules (module_id, title, icon, schema, min_client_version,
      enabled, sort, "group", color, visible_roles, visible_user_ids, updated_at, updated_by)
    VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
    ON CONFLICT(module_id) DO UPDATE SET
      title=excluded.title, icon=excluded.icon, schema=excluded.schema,
      min_client_version=excluded.min_client_version, enabled=excluded.enabled,
      sort=excluded.sort, "group"=excluded."group", color=excluded.color,
      visible_roles=excluded.visible_roles,
      visible_user_ids=excluded.visible_user_ids,
      updated_at=excluded.updated_at, updated_by=excluded.updated_by
  `).run(
    moduleId, m.title, m.icon, JSON.stringify(schema), m.minClientVersion,
    m.enabled ? 1 : 0, m.sort, group, color,
    JSON.stringify(visibleTo.roles), JSON.stringify(visibleTo.userIds),
    now, String(by || 'admin').slice(0, 60),
  );
  return { module: get(moduleId) };
}

/**
 * 局部更新（PATCH 语义：没给的字段不动；给 null = 清回默认）。
 *
 * 🔴 为什么不复用 upsert：upsert 走的是 validate(input) 全量校验，会把没给的
 *    字段补成默认值再整行重写 —— 于是"只改个分组"会把 body / onLoad 悄悄抹掉。
 *    这正是 2026-10-17 之前总览表里模块一旦被保存就丢数据的那类事故，
 *    所以这里单独一条路：只 SET 真正给过的列。
 *
 * body / onLoad 在 schema JSON 里，走"读出→合并→写回"，与列字段分开处理。
 */
function update(moduleId, patch, by) {
  const id = String(moduleId || '');
  const cur = db.prepare('SELECT * FROM app_modules WHERE module_id=?').get(id);
  if (!cur) return { error: '模块不存在' };
  const v = validate({ moduleId: id, ...(patch || {}) }, { partial: true });
  if (v.error) return { error: v.error };
  const m = v.module;
  const now = Date.now();
  const sets = [];
  const args = [];
  const put = (col, val) => { sets.push(`${col}=?`); args.push(val); };

  if (m.title !== undefined) put('title', m.title);
  if (m.icon !== undefined) put('icon', m.icon);
  if (m.minClientVersion !== undefined) put('min_client_version', m.minClientVersion);
  if (m.sort !== undefined) put('sort', m.sort);
  if (m.enabled !== undefined) put('enabled', m.enabled ? 1 : 0);
  if (m.group !== undefined) put('"group"', m.group);
  if (m.color !== undefined) put('color', m.color);
  if (m.visibleTo !== undefined) {
    put('visible_roles', JSON.stringify(m.visibleTo.roles));
    put('visible_user_ids', JSON.stringify(m.visibleTo.userIds));
  }
  // schema 里的 body / onLoad：读出来合并，避免"改分组把页面内容改没了"
  if (m.body !== undefined || m.onLoad !== undefined) {
    let schema = {};
    try { schema = JSON.parse(cur.schema || '{}'); } catch { schema = {}; }
    if (m.body !== undefined) schema.body = m.body;
    if (m.onLoad !== undefined) schema.onLoad = m.onLoad;
    put('schema', JSON.stringify(schema));
  }
  if (!sets.length) return { module: get(id), message: '没有要改的字段' };
  args.push(now, String(by || 'admin').slice(0, 60), id);
  db.prepare(`UPDATE app_modules SET ${sets.join(', ')}, updated_at=?, updated_by=? WHERE module_id=?`)
    .run(...args);
  return { module: get(id) };
}

function remove(moduleId) {
  const r = db.prepare('DELETE FROM app_modules WHERE module_id=?').run(String(moduleId));
  return r.changes > 0;
}

/**
 * 只改排序号（统一排序接口用）。
 *
 * 🔴 刻意**不经过 validate()**：validate 要求 body/moduleId/title 齐全，
 *    而这里只是挪个位子，手上只有一个 id。走 validate 就得先读一遍整个模块
 *    再原样写回去 —— 那是"改一个数字要重写整个文档"，期间还容易被并发覆盖。
 *    排序号本身在 validate 里有 0~9999 的钳制，这里照抄同一个口径。
 */
function setSort(moduleId, sort) {
  let n = Number(sort);
  if (!Number.isFinite(n)) n = 0;
  n = Math.max(0, Math.min(9999, Math.trunc(n)));
  const r = db.prepare('UPDATE app_modules SET sort=?, updated_at=? WHERE module_id=?')
    .run(n, Date.now(), String(moduleId));
  return r.changes > 0;
}

/* ---------------- 提交记录（第二期验收：表单能提交并且能看见结果） ---------------- */

/**
 * 记录一次动态表单提交。
 * 注意：这里**不信任**客户端传来的字段定义——管理台/服务端要展示时读的是提交时
 * 模块 schema 里的字段顺序，客户端多传的字段一律丢弃（见 sanitizeSubmission）。
 */
function recordSubmission(moduleId, userId, payload) {
  const m = get(moduleId);
  if (!m) return { error: `模块 ${moduleId} 不存在` };
  const clean = sanitizeSubmission(m, payload);
  if (clean.error) return clean;
  const r = db.prepare(`INSERT INTO module_submissions (module_id, user_id, payload, created_at)
    VALUES (?,?,?,?)`).run(String(moduleId), userId || null, JSON.stringify(clean.data), Date.now());
  return { id: r.lastInsertRowid, data: clean.data };
}

/** 只保留 schema 里声明过的字段，并做必填与类型校验 */
function sanitizeSubmission(module, payload) {
  if (!isObj(payload)) return { error: '提交内容必须是一个对象' };
  const fields = collectFormFields(module.body || []);
  if (!fields.length) return { error: '该模块没有可提交的表单' };
  const out = {};
  const missing = [];
  for (const f of fields) {
    const v = payload[f.key];
    if (f.required && (v === undefined || v === null || String(v).trim() === '')) {
      missing.push(f.label || f.key);
      continue;
    }
    if (v === undefined) continue;
    if (f.type === 'number') {
      const n = Number(v);
      if (!Number.isFinite(n)) return { error: `字段 ${f.label || f.key} 需要是数字` };
      out[f.key] = n;
    } else if (f.type === 'switch') {
      out[f.key] = !!v;
    } else if (f.type === 'select') {
      const allowed = (f.options || []).map((o) => o.value);
      const s = String(v);
      if (allowed.length && !allowed.includes(s)) return { error: `字段 ${f.label || f.key} 的取值不在选项内` };
      out[f.key] = s;
    } else {
      out[f.key] = String(v).slice(0, MAX_TEXT);
    }
  }
  if (missing.length) return { error: `请填写：${missing.join('、')}` };
  return { data: out };
}

/** 从组件树里收集所有 form 字段（含 card 嵌套） */
function collectFormFields(body, depth = 0) {
  const out = [];
  if (depth > MAX_DEPTH + 1) return out;
  for (const c of body || []) {
    if (!isObj(c)) continue;
    if (c.component === 'form' && Array.isArray(c.fields)) out.push(...c.fields);
    if (c.component === 'card' && Array.isArray(c.children)) out.push(...collectFormFields(c.children, depth + 1));
  }
  return out;
}

function listSubmissions(moduleId, limit = 100, offset = 0) {
  const lim = Math.min(Number(limit) || 100, 500);
  const off = Math.max(Number(offset) || 0, 0);
  const rows = db.prepare(`SELECT s.id, s.module_id, s.user_id, s.payload, s.created_at,
      u.nickname, u.username
    FROM module_submissions s LEFT JOIN users u ON u.id=s.user_id
    WHERE s.module_id=? ORDER BY s.created_at DESC LIMIT ? OFFSET ?`).all(String(moduleId), lim, off);
  return rows.map((r) => {
    let data = {};
    try { data = JSON.parse(r.payload || '{}'); } catch { data = {}; }
    return {
      id: r.id,
      moduleId: r.module_id,
      userId: r.user_id,
      nickname: r.nickname || r.username || (r.user_id ? `用户${r.user_id}` : '匿名'),
      data,
      createdAt: r.created_at,
    };
  });
}

/** 某模块的提交总数（配合 listSubmissions 做分页；原来固定 LIMIT 100 静默截断） */
function countSubmissions(moduleId) {
  return db.prepare('SELECT COUNT(*) n FROM module_submissions WHERE module_id=?').get(String(moduleId)).n;
}

/* ---------------- 模板库（第二期管理台用） ----------------
 *
 * 为什么模板放在服务端而不是管理台前端：
 * 模板就是"一份模块定义"，必须和 validate() 用同一套规则。放在前端的话，
 * 改了校验规则却忘了改模板，管理员点一下模板就会撞到 400，而他根本不知道哪错了。
 * 放这里还可以直接被测试覆盖：每个模板都必须能通过 validate()（见 app_modules_e2e.js）。
 */
const TEMPLATES = [
  {
    id: 'device_repair',
    name: '设备报修',
    desc: '一个可提交的表单，适合车间报修、点检异常上报',
    module: {
      moduleId: 'device_repair',
      title: '设备报修',
      icon: 'build',
      sort: 10,
      enabled: true,
      minClientVersion: null,
      visibleTo: { roles: [], userIds: [] },
      body: [
        { component: 'text', text: '提交后维修班会收到通知', size: 13, color: 'muted', align: 'left' },
        {
          component: 'form',
          fields: [
            { key: 'device', label: '设备名称', type: 'text', required: true, placeholder: '如 3 号包装机' },
            {
              key: 'level', label: '紧急程度', type: 'select', required: true,
              options: [{ label: '一般', value: 'low' }, { label: '紧急', value: 'high' }],
            },
            { key: 'place', label: '所在车间', type: 'text', required: false },
            { key: 'desc', label: '问题描述', type: 'textarea', required: false },
            { key: 'needstop', label: '是否需要停机', type: 'switch', required: false },
          ],
        },
      ],
    },
  },
  {
    id: 'stock_overview',
    name: '商品清单（列表）',
    desc: '列表 + 刷新按钮，直接读本服务器的商品档案（有数据才看得见内容）',
    module: {
      moduleId: 'stock_overview',
      title: '商品清单',
      icon: 'inventory',
      sort: 20,
      enabled: true,
      minClientVersion: null,
      visibleTo: { roles: [], userIds: [] },
      body: [
        {
          component: 'text', text: '数据来源：本服务器 · 盘点 · 商品档案',
          size: 12.5, color: 'muted', align: 'left',
        },
        {
          component: 'list', dataPath: 'data.rows',
          itemTemplate: { title: '{{name}}', subtitle: '{{spec}}', trailing: '{{qtyText}}' },
        },
        {
          component: 'action', label: '刷新数据', color: 'primary',
          onTap: { action: 'api', path: '/api/hooks/local/inventory/products', method: 'GET' },
        },
      ],
      // 🔴 2026-10-16 之前这条路径是 /api/hooks/stock/overview —— 服务器上
      //    根本没有这个接口，管理员点完模板拿到的是一副空列表。
      //    现在一律指向**真的存在**的本服务器数据源。
      onLoad: { action: 'api', path: '/api/hooks/local/inventory/products', method: 'GET' },
    },
  },
  {
    id: 'duty_roster',
    name: '员工名册（表格）',
    desc: '多列表格，直接读本服务器的员工名册',
    module: {
      moduleId: 'duty_roster',
      title: '员工名册',
      icon: 'schedule',
      sort: 30,
      enabled: true,
      minClientVersion: null,
      visibleTo: { roles: [], userIds: [] },
      body: [
        {
          component: 'table', dataPath: 'data.rows',
          columns: [
            { key: 'employeeNo', label: '工号', width: 110 },
            { key: 'who', label: '姓名', width: 110 },
            { key: 'dept', label: '部门', width: 140 },
            { key: 'position', label: '岗位', width: 140 },
            { key: 'roleText', label: '角色', width: 90 },
          ],
        },
        {
          component: 'action', label: '刷新数据', color: 'primary',
          onTap: { action: 'api', path: '/api/hooks/local/work_org/members', method: 'GET' },
        },
      ],
      onLoad: { action: 'api', path: '/api/hooks/local/work_org/members', method: 'GET' },
    },
  },
  {
    id: 'sales_board',
    name: '库存分布（图表）',
    desc: '卡片 + 柱状图，直接读本服务器的商品档案（按账面库存画柱）',
    module: {
      moduleId: 'sales_board',
      title: '库存分布',
      icon: 'assessment',
      sort: 40,
      enabled: true,
      minClientVersion: null,
      visibleTo: { roles: [], userIds: [] },
      body: [
        {
          component: 'card', title: '商品库存', subtitle: '数据来源：本服务器 · 盘点 · 商品档案', accent: 'success',
          children: [
            { component: 'text', text: '柱子高度 = 账面库存数', size: 12, color: 'muted', align: 'left' },
          ],
        },
        { component: 'chart', dataPath: 'data.rows', xKey: 'name', yKey: 'qty', kind: 'bar' },
        {
          component: 'action', label: '刷新数据', color: 'primary',
          onTap: { action: 'api', path: '/api/hooks/local/inventory/products', method: 'GET' },
        },
      ],
      onLoad: { action: 'api', path: '/api/hooks/local/inventory/products', method: 'GET' },
    },
  },
  {
    id: 'punch_flow',
    name: '打卡流水（表格）',
    desc: '多列表格，直接读本服务器的打卡流水（含定位与卡次）',
    module: {
      moduleId: 'punch_flow',
      title: '打卡流水',
      icon: 'receipt_long',
      sort: 50,
      enabled: true,
      minClientVersion: null,
      // 流水里有每个人的坐标 → 只给管理员，跟数据源的 module:'admin' 对齐，
      // 否则员工打开就是 403，看着像"界面坏了"
      visibleTo: { roles: ['admin'], userIds: [] },
      body: [
        {
          component: 'table', dataPath: 'data.rows',
          columns: [
            { key: 'day', label: '日期', width: 100 },
            { key: 'who', label: '员工', width: 120 },
            { key: 'punch', label: '卡次', width: 110 },
            { key: 'atText', label: '打卡时刻', width: 150 },
            { key: 'sourceText', label: '来源', width: 100 },
          ],
        },
        {
          component: 'action', label: '刷新数据', color: 'primary',
          onTap: { action: 'api', path: '/api/hooks/local/attendance/records', method: 'GET' },
        },
      ],
      onLoad: { action: 'api', path: '/api/hooks/local/attendance/records', method: 'GET' },
    },
  },
  {
    id: 'duty_schedule',
    name: '排班表',
    desc: '周表格 + 排班表单：看谁哪天什么班，直接往里加。班次复用考勤班次，创建即有数据',
    module: {
      moduleId: 'duty_schedule',
      title: '排班表',
      icon: 'schedule',
      sort: 10,
      enabled: true,
      minClientVersion: null,
      visibleTo: { roles: [], userIds: [] },
      body: [
        {
          component: 'text', text: '排班（今天起 7 天）。提交即写入，重复提交同一天同一人 = 更新',
          size: 12, color: 'muted', align: 'left',
        },
        {
          component: 'table', dataPath: 'data.rows',
          columns: [
            { key: 'day', label: '日期', width: 100 },
            { key: 'who', label: '员工', width: 100 },
            { key: 'shift', label: '班次', width: 175 },
            { key: 'position', label: '岗位', width: 90 },
            { key: 'note', label: '备注', width: 110 },
          ],
        },
        {
          component: 'form',
          fields: [
            { key: 'day', label: '日期', type: 'date', required: true },
            {
              // 员工下拉走动态源：组织成员会变，写死就等于模板过期
              key: 'userId', label: '员工', type: 'select', required: true,
              optionsFrom: '/api/hooks/local/work_org/members',
              optionsPath: 'data.rows', optionLabel: 'who', optionValue: 'id',
            },
            {
              // 班次下拉同样动态（源的第一行是"休息"哨兵，见 appdata duty/shifts）
              key: 'shiftId', label: '班次', type: 'select', required: true,
              optionsFrom: '/api/hooks/local/duty/shifts',
              optionsPath: 'data.rows', optionLabel: 'label', optionValue: 'value',
            },
            { key: 'position', label: '当班岗位', type: 'text', required: false, placeholder: '如 收银 / 理货' },
            { key: 'note', label: '备注', type: 'text', required: false, placeholder: '如 顶班' },
          ],
          // 🔴 submit 指到排班数据源的 POST（表单即录入）。不配 submit 时
          //    表单仍会走老的 module_submissions（只留痕不落业务表）——
          //    对排班来说那就是"提交成功但班表不变"，是最坏的一种假成功。
          submit: { action: 'api', path: '/api/hooks/local/duty/schedules', method: 'POST' },
        },
        {
          component: 'action', label: '刷新排班', color: 'primary',
          onTap: { action: 'api', path: '/api/hooks/local/duty/schedules', method: 'GET' },
        },
      ],
      onLoad: { action: 'api', path: '/api/hooks/local/duty/schedules', method: 'GET' },
    },
  },
];

module.exports = {
  COMPONENTS, CONTAINERS, COLORS, FIELD_TYPES, ACTIONS, NAV_PAGES, ICONS, CHART_KINDS,
  MAX_DEPTH, MAX_COMPONENTS, TEMPLATES,
  versionGte,
  validate, validateComponent, validateAction, sanitizeSubmission, collectFormFields,
  list, get, listVisible, upsert, update, remove, setSort,
  recordSubmission, listSubmissions, countSubmissions,
};
