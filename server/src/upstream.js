/**
 * 上游接口登记与受控转发（动态模块第三期）
 *
 * ── 为什么需要这一层 ────────────────────────────────────────────────
 * 动态模块的 `onLoad` / `action{path}` 只允许 `/api/hooks/` 前缀（防 SSRF）。
 * 但 `/api/hooks` 底下一直只有 `/incoming/:token`（推消息）和 `/ping`，
 * 于是 list / table / chart 三种组件**能发布、能画出框，内容永远是空的** ——
 * 因为它们的 `dataPath` 指向的数据从来没人喂。
 *
 * 这一层就是把"喂数据"补上：管理台登记过的上游，客户端可以通过
 * `GET /api/hooks/up/<name>/<子路径>` 打到，服务端转发并回传。
 *
 * ── 安全边界为什么是"白名单"而不是"禁内网" ─────────────────────────
 * 上游天生就在内网（工厂 V2 / 餐饮 POS / 门店数据桥接器都在 192.168 段），
 * 禁掉内网等于这个功能没用。真正要防的是**客户端能打到任意 URL**：
 *   · 客户端只能给出一个**名字**，真实地址由服务端查表得出 → 给不出任意地址
 *   · 子路径拒绝 `..`、拒绝绝对 URL、拒绝协议相对（`//host`）→ 跳不出 base_url
 *   · 凭证（auth_header）由服务端持有，**不下发、不回显**
 *   · 只允许 GET / POST（不许 PUT/DELETE/PATCH 去打别人的写接口）
 *
 * ── 调用方是谁 ──────────────────────────────────────────────────────
 * 客户端已登录的用户（经 requireAuth）。**不是免鉴权** —— 上游可能返回经营数据。
 * 所以这一层挂在 /api/hooks 下但自带鉴权中间件，与 /incoming/:token 的
 * "地址即凭证"是两种模型，不要混。
 */
const db = require('./db');

const NAME_RE = /^[a-z][a-z0-9_-]{1,31}$/;
const MIN_TIMEOUT = 1000;
const MAX_TIMEOUT = 30000;
const DEFAULT_TIMEOUT = 10000;
const MAX_BODY = 256 * 1024;      // 回传正文上限，防止上游吐一个巨大响应把客户端撑爆
const ALLOWED_METHODS = ['GET', 'POST'];

/** 列表：**绝不回传 auth_header 明文**，只回"配没配" */
function list() {
  return db.prepare(`SELECT id, name, label, base_url, timeout_ms, enabled, allow_roles,
      (auth_header IS NOT NULL AND auth_header <> '') AS has_auth,
      created_at, updated_at, updated_by
    FROM upstreams ORDER BY updated_at DESC`).all()
    .map((r) => ({
      id: r.id,
      name: r.name,
      label: r.label,
      baseUrl: r.base_url,
      timeoutMs: r.timeout_ms,
      enabled: !!r.enabled,
      hasAuth: !!r.has_auth,
      allowRoles: parseRoles(r.allow_roles),
      createdAt: r.created_at,
      updatedAt: r.updated_at,
      updatedBy: r.updated_by,
    }));
}

/** allow_roles 存的是 JSON 数组；坏数据一律当"空"（= 所有登录用户），不抛异常 */
function parseRoles(raw) {
  try {
    const a = JSON.parse(raw || '[]');
    return Array.isArray(a) ? a.map((s) => String(s)).filter(Boolean) : [];
  } catch (_) {
    return [];
  }
}

/**
 * 这个角色能不能通过这条上游取数。
 * 空白名单 = 所有已登录用户（默认，最省事）；
 * 非空 = 只允许列出的角色。**admin 不在列表里也没权限** —— 刻意保持"写什么就是什么"，
 * 免得出现"明明设了白名单，管理员却能绕过"这种要想一会儿才明白的规则。
 */
function canAccess(up, role) {
  const allow = parseRoles(up && up.allow_roles);
  if (!allow.length) return true;
  return allow.includes(String(role || ''));
}

/** 内部用：拿完整行（含凭据）。只给 forward 用，别往外传。 */
function get(name) {
  return db.prepare('SELECT * FROM upstreams WHERE name=?').get(String(name || ''));
}

function cleanUrl(raw) {
  const s = String(raw || '').trim().replace(/\/+$/, '');
  if (!/^https?:\/\//i.test(s)) return { error: '上游地址必须以 http:// 或 https:// 开头' };
  try {
    // 用 URL 解析一次，顺手挡掉 http://a/../.. 这类畸形串
    const u = new URL(s);
    if (!u.hostname) return { error: '上游地址缺少主机名' };
    return { value: u.origin + u.pathname.replace(/\/+$/, '') };
  } catch (_) {
    return { error: `上游地址无法解析：${s}` };
  }
}

/**
 * 校验登记入参。
 *
 * ⚠️ `opts.updating` 这个开关是**必须**的，不是可有可无的宽松选项：
 * 管理台改配置是"只提交动的那个字段"（点「停用」就只发 `enabled:false`），
 * 而 baseUrl 只有新建时才该必填。早先两处用同一个必填规则，结果
 * `POST {name:'report', enabled:false}` 被"上游地址必须以 http:// 开头"400 掉 ——
 * **停用按钮点了没反应，白名单改了不生效**，而且返回的是个看着很合理的报错，
 * 极难往"更新走的是新建的校验"上想。所以这里按"新建/更新"分开要求。
 */
function validate(input, opts) {
  const creating = !(opts && opts.updating);
  const out = {};
  const name = String(input?.name || '').trim().toLowerCase();
  if (!name) return { error: '请填写接口名（用于拼接路径）' };
  if (!NAME_RE.test(name)) {
    return { error: '接口名只能用小写字母开头、包含小写字母/数字/_/-，长度 2~32' };
  }
  out.name = name;

  if (input?.label !== undefined) out.label = String(input.label || '').trim().slice(0, 60) || null;

  // 新建必填；更新时"没提交"= 保持原值（提交了就照样校验）
  if (creating || input?.baseUrl !== undefined) {
    const u = cleanUrl(input?.baseUrl);
    if (u.error) return { error: u.error };
    out.baseUrl = u.value;
  }

  if (input?.authHeader !== undefined) {
    // 空串 = 清掉。整条 Authorization 值原样存（调用方自己带 "Bearer xxx" 前缀）
    const a = String(input.authHeader || '').trim();
    out.authHeader = a ? a.slice(0, 500) : null;
  }

  if (input?.allowRoles !== undefined) {
    // 空数组 = 所有登录用户。角色名与 users.role 一致（admin / user）
    const a = input.allowRoles;
    if (a !== null && !Array.isArray(a)) return { error: '允许的角色必须是数组' };
    const list = (a || []).map((s) => String(s).trim()).filter(Boolean);
    for (const r of list) {
      if (!/^[a-z][a-z0-9_]{0,19}$/.test(r)) return { error: `角色名不合法：${r}` };
    }
    out.allowRoles = JSON.stringify([...new Set(list)]);
  }

  if (input?.timeoutMs !== undefined && input.timeoutMs !== null && input.timeoutMs !== '') {
    const t = Number(input.timeoutMs);
    if (!Number.isFinite(t)) return { error: '超时必须是数字（毫秒）' };
    if (t < MIN_TIMEOUT || t > MAX_TIMEOUT) {
      return { error: `超时必须在 ${MIN_TIMEOUT}~${MAX_TIMEOUT} 毫秒之间` };
    }
    out.timeoutMs = Math.round(t);
  }

  if (input?.enabled !== undefined) out.enabled = input.enabled ? 1 : 0;
  return { out };
}

/**
 * 新增或更新。**按 name 幂等**（name 是 UNIQUE）—— 管理台第一次填某名字是新增，
 * 再提交同一个名字就是改配置，不会因为重复点"保存"冒出两条。
 */
function upsert(input, by) {
  // 先查在不在，是为了把"新建/更新"这个事实喂给 validate ——
  // 顺序反过来的话，改配置会被按新建的规则校验（见 validate 的注释）
  const wantName = String(input?.name || '').trim().toLowerCase();
  const exist = wantName
    ? db.prepare('SELECT * FROM upstreams WHERE name=?').get(wantName)
    : null;

  const v = validate(input, { updating: !!exist });
  if (v.error) return { error: v.error };
  const o = v.out;
  const now = Date.now();

  if (exist) {
    // 未提交的字段保持原值（authHeader 尤其重要：管理台不回显明文，
    // 所以"不改凭据"必须是默认行为，而不是被空值清掉）
    const next = {
      label: o.label !== undefined ? o.label : exist.label,
      base_url: o.baseUrl || exist.base_url,
      auth_header: o.authHeader !== undefined ? o.authHeader : exist.auth_header,
      allow_roles: o.allowRoles !== undefined ? o.allowRoles : exist.allow_roles,
      timeout_ms: o.timeoutMs !== undefined ? o.timeoutMs : exist.timeout_ms,
      enabled: o.enabled !== undefined ? o.enabled : exist.enabled,
    };
    db.prepare(`UPDATE upstreams SET label=?, base_url=?, auth_header=?, allow_roles=?,
        timeout_ms=?, enabled=?, updated_at=?, updated_by=? WHERE id=?`)
      .run(next.label, next.base_url, next.auth_header, next.allow_roles,
        next.timeout_ms, next.enabled, now, String(by || 'admin').slice(0, 60), exist.id);
    return { id: exist.id, name: o.name, updated: true };
  }

  const info = db.prepare(`INSERT INTO upstreams
      (name, label, base_url, auth_header, allow_roles, timeout_ms, enabled, created_at, updated_at, updated_by)
      VALUES (?,?,?,?,?,?,?,?,?,?)`)
    .run(o.name, o.label || null, o.baseUrl,
      o.authHeader !== undefined ? o.authHeader : null,
      o.allowRoles !== undefined ? o.allowRoles : '[]',
      o.timeoutMs !== undefined ? o.timeoutMs : DEFAULT_TIMEOUT,
      o.enabled !== undefined ? o.enabled : 1,
      now, now, String(by || 'admin').slice(0, 60));
  return { id: Number(info.lastInsertRowid), name: o.name, created: true };
}

function remove(id) {
  const r = db.prepare('DELETE FROM upstreams WHERE id=?').run(Number(id));
  return Number(r.changes || 0) > 0;
}

/**
 * 子路径里有没有"往外跳"的写法。
 *
 * 逐层解码后再判，是因为 `%2E%2E%2F` / `%252E%252E` 这种编码在**上游**才被解码，
 * 在这里看着只是一个普通字符串段，放过去之后上游一解码就跳出去了。
 * 解不开（坏编码）一律拒 —— 正常业务路径不需要畸形百分号编码。
 */
function looksEscaping(sub) {
  let s = String(sub || '');
  for (let i = 0; i < 3; i++) {
    if (/^[a-z][a-z0-9+.-]*:\/\//i.test(s)) return true;   // 绝对 URL
    if (s.startsWith('//')) return true;                    // 协议相对
    if (s.split(/[\\/]/).some((seg) => seg === '..')) return true;  // ./..（顺手把反斜杠也算上）
    let d;
    try { d = decodeURIComponent(s); } catch (_) { return true; }
    if (d === s) break;
    s = d;
  }
  return false;
}

/**
 * 拼最终 URL。子路径必须"只能往下走"，不能跳出 base_url。
 * 返回 { url } 或 { error }。
 *
 * ⚠️ 判定必须发生在**去掉前导斜杠之前**：`//evil.example.com/x` 剥掉前导 `/` 之后
 * 就和 `evil.example.com/x` 长得一模一样，那时候再判"是不是以 // 开头"永远为假
 * —— 这条断言就是这么静默失效的，测试里专门留了一条盯着它。
 */
function buildUrl(up, subPath, search) {
  const raw = String(subPath || '').trim();

  if (looksEscaping(raw)) {
    return { error: '子路径不能是完整 URL、不能以 // 开头，也不能包含 ..' };
  }

  const sub = raw.replace(/^\/+/, '');
  if (sub.length > 512) return { error: '子路径过长' };

  const base = String(up.base_url || '').replace(/\/+$/, '');
  const url = sub ? `${base}/${sub}` : base;
  const qs = String(search || '').replace(/^\?/, '');
  return { url: qs ? `${url}?${qs}` : url };
}

/**
 * 转发一次。返回 { ok, status, data } 或 { error }。
 * body 只在 POST 时用；只有对象才作为 JSON 转发。
 */
async function forward(name, subPath, opts) {
  const optsIn = opts || {};
  const method = String(optsIn.method || 'GET').toUpperCase();
  if (!ALLOWED_METHODS.includes(method)) {
    return { error: `只允许 ${ALLOWED_METHODS.join(' / ')}，收到 ${method}` };
  }

  const up = get(name);
  if (!up) return { error: `上游接口「${name}」没有登记` };
  if (!up.enabled) return { error: `上游接口「${name}」已停用` };

  // 角色白名单放在 forward 里判（而不是只放在路由层），是为了"忘了判"不可能发生：
  // 以后有新调用方接进来，只要它传了 role 就一定被同一套规则管住。
  if (optsIn.role !== undefined && !canAccess(up, optsIn.role)) {
    return { error: `没有权限访问上游「${name}」`, forbidden: true };
  }

  const b = buildUrl(up, subPath, optsIn.search);
  if (b.error) return { error: b.error };

  const headers = {
    // 让上游看得见是谁在调（排障用），也让自己的访问日志能认出这类流量
    'User-Agent': 'XiaozhiIM-Upstream/1.0',
    'Accept': 'application/json, text/plain;q=0.9, */*;q=0.8',
  };
  if (up.auth_header) headers['Authorization'] = up.auth_header;

  const init = {
    method,
    headers,
    signal: AbortSignal.timeout(Math.min(Number(up.timeout_ms) || DEFAULT_TIMEOUT, MAX_TIMEOUT)),
  };
  if (method === 'POST' && optsIn.body && typeof optsIn.body === 'object') {
    headers['Content-Type'] = 'application/json';
    init.body = JSON.stringify(optsIn.body);
  }

  const started = Date.now();
  let res;
  try {
    res = await fetch(b.url, init);
  } catch (e) {
    const ms = Date.now() - started;
    // 超时和"连不上"要分清：前者是上游慢，后者是地址/网络不对，处置方式不同
    if (e.name === 'TimeoutError' || e.name === 'AbortError') {
      return { error: `上游「${name}」响应超时（${ms}ms，上限 ${up.timeout_ms}ms）`, url: b.url };
    }
    return { error: `连不上上游「${name}」：${e.message}`, url: b.url };
  }

  const ms = Date.now() - started;
  const ctype = String(res.headers.get('content-type') || '');
  let data = null;
  let truncated = false;
  try {
    const text = await res.text();
    truncated = text.length > MAX_BODY;
    const body = truncated ? text.slice(0, MAX_BODY) : text;
    if (ctype.includes('json')) {
      try {
        data = JSON.parse(body);
      } catch (_) {
        // 声称是 JSON 但解析不了 —— 原样回文本，别吞掉让人以为是空数据
        data = { _raw: body, _note: '上游声明 JSON 但解析失败' };
      }
    } else {
      data = { _raw: body, _contentType: ctype };
    }
  } catch (e) {
    return { error: `读取上游响应失败：${e.message}`, status: res.status, url: b.url };
  }

  return {
    ok: res.ok,
    status: res.status,
    ms,
    url: b.url,
    truncated,
    data,
  };
}

/** 探活：只打 base_url，用来在管理台点一下就知道配得对不对 */
async function probe(idOrName) {
  const up = typeof idOrName === 'number'
    ? db.prepare('SELECT * FROM upstreams WHERE id=?').get(idOrName)
    : get(idOrName);
  if (!up) return { error: '没有这条上游接口' };
  const started = Date.now();
  try {
    const res = await fetch(up.base_url, {
      method: 'GET',
      headers: {
        'User-Agent': 'XiaozhiIM-Upstream/1.0',
        ...(up.auth_header ? { Authorization: up.auth_header } : {}),
      },
      signal: AbortSignal.timeout(Math.min(Number(up.timeout_ms) || DEFAULT_TIMEOUT, MAX_TIMEOUT)),
    });
    return { ok: true, reachable: true, status: res.status, ms: Date.now() - started, url: up.base_url };
  } catch (e) {
    return {
      ok: true, reachable: false, ms: Date.now() - started, url: up.base_url,
      error: (e.name === 'TimeoutError' || e.name === 'AbortError')
        ? '连接超时' : e.message,
    };
  }
}

module.exports = {
  list, get, validate, upsert, remove, buildUrl, forward, probe, canAccess, parseRoles,
  looksEscaping, cleanUrl,
  NAME_RE, ALLOWED_METHODS, DEFAULT_TIMEOUT, MIN_TIMEOUT, MAX_TIMEOUT,
};
