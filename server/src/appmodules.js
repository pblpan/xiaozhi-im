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
  'campaign', 'task', 'engineering', 'handyman', 'receipt_long',
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
        if (!Array.isArray(f.options) || !f.options.length) return { error: `字段 ${key} 是 select，必须有 options` };
        if (f.options.length > MAX_OPTIONS) return { error: `字段 ${key} 的 options 最多 ${MAX_OPTIONS} 个` };
        item.options = f.options.slice(0, MAX_OPTIONS).map((o) => ({
          label: str(o?.label ?? o?.value, 60),
          value: String(o?.value ?? ''),
        })).filter((o) => o.value !== '');
        if (!item.options.length) return { error: `字段 ${key} 的 options 没有合法项` };
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
    visibleTo: { roles, userIds },
    updatedAt: r.updated_at,
  };
}

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
  const v = validate(input);
  if (v.error) return { error: v.error };
  const m = v.module;
  const { moduleId, visibleTo, ...schemaRest } = m;
  const schema = { body: m.body, onLoad: m.onLoad };
  const now = Date.now();
  db.prepare(`
    INSERT INTO app_modules (module_id, title, icon, schema, min_client_version,
      enabled, sort, visible_roles, visible_user_ids, updated_at, updated_by)
    VALUES (?,?,?,?,?,?,?,?,?,?,?)
    ON CONFLICT(module_id) DO UPDATE SET
      title=excluded.title, icon=excluded.icon, schema=excluded.schema,
      min_client_version=excluded.min_client_version, enabled=excluded.enabled,
      sort=excluded.sort, visible_roles=excluded.visible_roles,
      visible_user_ids=excluded.visible_user_ids,
      updated_at=excluded.updated_at, updated_by=excluded.updated_by
  `).run(
    moduleId, m.title, m.icon, JSON.stringify(schema), m.minClientVersion,
    m.enabled ? 1 : 0, m.sort, JSON.stringify(visibleTo.roles), JSON.stringify(visibleTo.userIds),
    now, String(by || 'admin').slice(0, 60),
  );
  return { module: get(moduleId) };
}

function remove(moduleId) {
  const r = db.prepare('DELETE FROM app_modules WHERE module_id=?').run(String(moduleId));
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

function listSubmissions(moduleId, limit = 100) {
  const lim = Math.min(Number(limit) || 100, 500);
  const rows = db.prepare(`SELECT s.id, s.module_id, s.user_id, s.payload, s.created_at,
      u.nickname, u.username
    FROM module_submissions s LEFT JOIN users u ON u.id=s.user_id
    WHERE s.module_id=? ORDER BY s.created_at DESC LIMIT ?`).all(String(moduleId), lim);
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
    name: '库存概览（列表）',
    desc: '列表 + 刷新按钮，数据由服务端 /api/hooks 算好后下发',
    module: {
      moduleId: 'stock_overview',
      title: '库存概览',
      icon: 'inventory',
      sort: 20,
      enabled: true,
      minClientVersion: null,
      visibleTo: { roles: [], userIds: [] },
      body: [
        { component: 'text', text: '数据由服务端算好后下发', size: 12.5, color: 'muted', align: 'left' },
        {
          component: 'list', dataPath: 'data.items',
          itemTemplate: { title: '{{name}}', subtitle: '{{spec}}', trailing: '{{qty}}' },
        },
        {
          component: 'action', label: '刷新数据', color: 'primary',
          onTap: { action: 'api', path: '/api/hooks/stock/overview', method: 'GET' },
        },
      ],
      onLoad: { action: 'api', path: '/api/hooks/stock/overview', method: 'GET' },
    },
  },
  {
    id: 'duty_roster',
    name: '值班表（表格）',
    desc: '多列表格，适合值班、排班、对账明细',
    module: {
      moduleId: 'duty_roster',
      title: '值班表',
      icon: 'schedule',
      sort: 30,
      enabled: true,
      minClientVersion: null,
      visibleTo: { roles: [], userIds: [] },
      body: [
        {
          component: 'table', dataPath: 'data.rows',
          columns: [
            { key: 'date', label: '日期', width: 110 },
            { key: 'shift', label: '班次', width: 90 },
            { key: 'who', label: '值班人' },
            { key: 'phone', label: '联系电话', width: 140 },
          ],
        },
      ],
    },
  },
  {
    id: 'sales_board',
    name: '销售看板（图表）',
    desc: '卡片 + 柱状图，适合门店日销、产量趋势',
    module: {
      moduleId: 'sales_board',
      title: '销售看板',
      icon: 'assessment',
      sort: 40,
      enabled: true,
      minClientVersion: null,
      visibleTo: { roles: [], userIds: [] },
      body: [
        {
          component: 'card', title: '本周销售', subtitle: '数据来源：服务端统计', accent: 'success',
          children: [{ component: 'text', text: '点右上角刷新可重新取数', size: 12, color: 'muted', align: 'left' }],
        },
        { component: 'chart', dataPath: 'data.rows', xKey: 'day', yKey: 'amount', kind: 'bar' },
      ],
    },
  },
];

module.exports = {
  COMPONENTS, CONTAINERS, COLORS, FIELD_TYPES, ACTIONS, NAV_PAGES, ICONS, CHART_KINDS,
  MAX_DEPTH, MAX_COMPONENTS, TEMPLATES,
  versionGte,
  validate, validateComponent, validateAction, sanitizeSubmission, collectFormFields,
  list, get, listVisible, upsert, remove,
  recordSubmission, listSubmissions,
};
