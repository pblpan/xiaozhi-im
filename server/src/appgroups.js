'use strict';

/**
 * 工作台**分组**的可配覆盖（app_groups 表）
 *
 * ─────────────────────────────────────────────────────────────
 * 为什么它是单独一张表，而不是塞进应用覆盖（app_overrides）
 * ─────────────────────────────────────────────────────────────
 * 粒度不一样：
 *   · app_overrides 管的是**一个应用**（改名/换图标/调序/停用/配色）—— 它挂在某应用上；
 *   · 本表管的是**一组应用**（组名/组序/整个组收起/新增一组）—— 它挂在组上。
 * 一个应用可以换组，一个组不能"属于"某个应用，所以不是同一件事。
 *
 * 对齐钉钉 / 企业微信 / 飞书的地方：那三家的分组名都是**企业自己改的**
 * （"办公协同""人事管理""门店作业"）。写死在源码里管理员就改不了，于是
 * 工作台看着永远像别人家的默认模板。
 *
 * ─────────────────────────────────────────────────────────────
 * 一条刻意留的硬约束
 * ─────────────────────────────────────────────────────────────
 * **只能新增、改名、调序、收起，不能删出厂组。**
 * 删掉 work/custom 这两个 key 会让挂在它们上面的应用集体消失，而且
 * 消失得干干净净、不报错 —— 这是最难查的那类问题。要"清掉一个组"，
 * 正确的动作是**把组收起（hidden）**，那还留着记录，随时能放回来。
 * 自定义组倒是允许删（没人挂上去的时候），因为有删除按钮就说明它真能删。
 */

const db = require('./db');
const appregistry = require('./apps');
const appmodules = require('./appmodules');

const LABEL_MAX = 8;
const KEY_RE = /^[a-z][a-z0-9_]{0,23}$/;

/* ---------------- 表 ---------------- */

db.exec(`
CREATE TABLE IF NOT EXISTS app_groups (
  key        TEXT PRIMARY KEY,          -- 分组 key（出厂 work/custom，自定义自取）
  label      TEXT NOT NULL,             -- 组名（改名就改这里）
  sort       INTEGER NOT NULL DEFAULT 100,
  hidden     INTEGER NOT NULL DEFAULT 0,-- 1 = 整个组在工作台收起
  custom     INTEGER NOT NULL DEFAULT 0,-- 1 = 管理台新建的（出厂组不允许删）
  updated_at INTEGER NOT NULL,
  updated_by TEXT
);
`);

/* ---------------- 读 ---------------- */

/**
 * 出厂定义 + 覆盖合并后的**当前**分组清单，按 sort 升序。
 * 出厂组没有覆盖行时也会出现在结果里 —— 否则管理员一次没改过就看不到组名。
 */
function list() {
  const rows = db.prepare('SELECT * FROM app_groups').all();
  const byKey = new Map(rows.map((r) => [r.key, r]));
  const out = appregistry.DEFAULT_GROUPS.map((g) => {
    const r = byKey.get(g.key);
    return {
      key: g.key,
      label: r ? r.label : g.label,
      sort: r ? Number(r.sort) : g.sort,
      hidden: !!(r && r.hidden),
      custom: !!(r && r.custom),
    };
  });
  // 管理台新建的组：出厂清单里没有，直接补在后面
  for (const r of rows) {
    if (!appregistry.DEFAULT_GROUPS.some((g) => g.key === r.key)) {
      out.push({
        key: r.key, label: r.label, sort: Number(r.sort),
        hidden: !!r.hidden, custom: true,
      });
    }
  }
  return out.sort((a, b) => (a.sort - b.sort) || a.key.localeCompare(b.key));
}

/** 这个分组现在存不存在（应用挪组时要先建组） */
function exists(key) {
  const k = String(key || '');
  if (appregistry.DEFAULT_GROUPS.some((g) => g.key === k)) return true;
  return !!db.prepare('SELECT 1 FROM app_groups WHERE key=?').get(k);
}

/** 分组覆盖的索引对象 `{ key: { label, sort, hidden } }`，喂给 appregistry.listFor/catalog */
function map() {
  const out = {};
  for (const g of list()) {
    out[g.key] = { label: g.label, sort: g.sort, hidden: g.hidden };
  }
  return out;
}

/**
 * 给客户端下发的分组：当前清单 + **补齐应用里真的用到的 key**。
 *
 * ⚠️ 为什么要补：管理员可以新建分组然后把应用挪进去。如果某个 key 只存在于
 *    应用行里、missing 在分组清单里，客户端就查不到组名，那个组会显示成
 *    一串英文 key（"extra"）—— 看着像 bug，实际是他自己刚配的。
 */
function forClient(usedKeys) {
  const seen = new Set();
  const extra = [];
  for (const k of usedKeys || []) {
    if (seen.has(k)) continue;
    seen.add(k);
    if (!list().some((g) => g.key === k)) {
      extra.push({ key: k, label: k, sort: 900, hidden: false, custom: false });
    }
  }
  return [...list(), ...extra].sort((a, b) => (a.sort - b.sort) || a.key.localeCompare(b.key));
}

/**
 * 每个组里现在挂了几个应用（管理台显示"这组有几个"，收起前让他知道影响面）。
 * `groupOverrides` 里的应用级 group 覆盖也算进来 —— 管理员可能刚把某应用挪走。
 */
function usageOf(appOverrides, groupOverrides) {
  const counts = {};
  for (const g of list()) counts[g.key] = 0;
  for (const a of appregistry.BUILTIN_APPS) {
    const k = (appOverrides && appOverrides[a.id]?.group) || a.group;
    counts[k] = (counts[k] || 0) + 1;
  }
  // 动态模块的 group 固定是 custom
  counts.custom = (counts.custom || 0) + appmodulesCount();
  return counts;
}

function appmodulesCount() {
  return appmodules.list().filter((m) => m.enabled !== false).length;
}

/* ---------------- 写 ---------------- */

/** 改一个组（PATCH 语义：没给的字段不动；给 null = 清回出厂） */
function set(key, patch, by) {
  const k = String(key || '').trim();
  const isFactory = appregistry.DEFAULT_GROUPS.some((g) => g.key === k);
  const existing = db.prepare('SELECT * FROM app_groups WHERE key=?').get(k);

  if (!isFactory && !existing) {
    // 新增（key 在 set() 里校验过格式，这里只挡"重名"）
    if (!KEY_RE.test(k)) return { error: `分组名只能由小写字母、数字、下划线组成，且以字母开头（当前：${k}）` };
    if (existing) return { error: `分组 ${k} 已存在` };
    const label = String(patch?.label || '').trim();
    if (!label) return { error: '组名不能为空' };
    if ([...label].length > LABEL_MAX) return { error: `组名最多 ${LABEL_MAX} 个字（当前 ${[...label].length} 个）` };
    const sort = Number.isFinite(Number(patch?.sort)) ? Math.max(0, Math.min(9999, Math.trunc(Number(patch.sort)))) : 100;
    const now = Date.now();
    db.prepare('INSERT INTO app_groups (key,label,sort,hidden,custom,updated_at,updated_by) VALUES (?,?,?,?,1,?,?)')
      .run(k, label, sort, patch?.hidden ? 1 : 0, now, String(by || 'admin').slice(0, 60));
    return { group: { key: k, label, sort, hidden: !!patch.hidden, custom: true } };
  }

  if (!isFactory && existing?.custom !== 1) {
    return { error: `出厂分组 ${k} 不允许删除，要收起请把它改成"已隐藏"` };
  }

  const cur = existing || {
    key: k, label: appregistry.groupOf(k).label, sort: appregistry.groupOf(k).sort,
    hidden: 0, custom: isFactory ? 0 : 1,
  };
  let label = cur.label;
  let sort = Number(cur.sort);
  let hidden = !!cur.hidden;

  if ('label' in patch) {
    if (patch.label === null || patch.label === '') label = null;
    else {
      const s = String(patch.label).trim();
      if (!s) label = null;
      else if ([...s].length > LABEL_MAX) return { error: `组名最多 ${LABEL_MAX} 个字（当前 ${[...s].length} 个）` };
      else label = s;
    }
  }
  if ('sort' in patch) {
    if (patch.sort === null || patch.sort === '') sort = appregistry.groupOf(k).sort;
    else {
      const n = Number(patch.sort);
      if (!Number.isFinite(n)) return { error: '排序号需要是数字' };
      sort = Math.max(0, Math.min(9999, Math.trunc(n)));
    }
  }
  if ('hidden' in patch) hidden = !!patch.hidden;

  // 🔴 组名清回"出厂"= 把这一行删掉，而不是写个 label=NULL 进去
  //    （列是 NOT NULL，写 NULL 会直接报错；而且留一行"名字是空的"更糟）。
  if (label === null) {
    db.prepare('DELETE FROM app_groups WHERE key=?').run(k);
    return { group: null, message: `已恢复出厂设置（${k}）` };
  }

  const now = Date.now();
  db.prepare(`
    INSERT INTO app_groups (key,label,sort,hidden,custom,updated_at,updated_by)
    VALUES (?,?,?,?,?,?,?)
    ON CONFLICT(key) DO UPDATE SET
      label=excluded.label, sort=excluded.sort, hidden=excluded.hidden,
      updated_at=excluded.updated_at, updated_by=excluded.updated_by
  `).run(k, label, sort, hidden ? 1 : 0, cur.custom ? 1 : 0, now, String(by || 'admin').slice(0, 60));

  // 完全回到出厂 = 没必要留一行"什么都没改"的记录
  const back = db.prepare('SELECT * FROM app_groups WHERE key=?').get(k);
  const pristine = back && back.label === appregistry.groupOf(k).label
    && Number(back.sort) === appregistry.groupOf(k).sort
    && !back.hidden;
  if (pristine && !isFactory) {
    db.prepare('DELETE FROM app_groups WHERE key=?').run(k);
    return { group: null, message: '已恢复出厂设置' };
  }
  return { group: { key: k, label, sort, hidden, custom: !!cur.custom } };
}

/**
 * 删一个组（**只删管理台新建的**，出厂组删不掉 —— 见文件头）。
 *
 * @param appOverrides 来自 appoverrides.map()。**必须传**：管理员可以把某个应用
 *    "挪"到这个组里（那是应用级覆盖，不在 BUILTIN_APPS.group 上），不传的话
 *    这里数出来是 0，就会把一个"其实挂着应用"的组删掉 —— 那些应用会集体消失。
 */
function remove(key, appOverrides) {
  const k = String(key || '');
  const r = db.prepare('SELECT * FROM app_groups WHERE key=?').get(k);
  if (!r) return { error: `分组不存在：${k}` };
  if (appregistry.DEFAULT_GROUPS.some((g) => g.key === k)) {
    return { error: '出厂分组不能删除。要收起请把它改成「已隐藏」，随时能放回来。' };
  }
  if (r.custom !== 1) return { error: '出厂分组不能删除' };
  const used = usageOf(appOverrides, null)[k] || 0;
  if (used > 0) return { error: `这个组里还有 ${used} 个应用，先把它们挪到别的组再删` };
  db.prepare('DELETE FROM app_groups WHERE key=?').run(k);
  return { removed: true };
}

/** 把某个组整组收起 / 放出来 */
function setHidden(key, hidden) {
  const r = set(key, { hidden: !!hidden }, 'admin');
  if (r.error) return r;
  return { group: r.group };
}

/* ---------------- 管理台视图 ---------------- */

/** 管理台"分组管理"用的一行：当前值 + 是否偏离出厂 + 组里挂了几个 */
function view(appOverrides) {
  const counts = usageOf(appOverrides, null);
  return list().map((g) => {
    const r = db.prepare('SELECT * FROM app_groups WHERE key=?').get(g.key);
    const factory = appregistry.groupOf(g.key);
    return {
      ...g,
      usedBy: counts[g.key] || 0,
      changed: !!(r && (r.label !== factory.label || Number(r.sort) !== factory.sort || r.hidden)),
      factory: { label: factory.label, sort: factory.sort },
    };
  });
}

module.exports = {
  LABEL_MAX,
  list, map, exists, forClient, usageOf,
  set, remove, setHidden, view,
};
