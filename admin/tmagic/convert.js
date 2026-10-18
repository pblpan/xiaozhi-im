/*
 * tmagic DSL ↔ 小智 module schema 双向转换层
 *
 * 🔴 字段白名单与 client/lib/core/module_schema.dart 逐字段对齐（权威定义）。
 *    任何一边加字段，两边同步改——这是客户端渲染的合同。
 *
 * 组件类型字段：小智 schema 用 `component` 存类型名；tmagic DSL 用 `type`。
 * chart 的图表类型字段小智叫 `kind`（不是 chartKind）。
 * ModuleAction = {action, path, method, page, text, dataPath, url}。
 */

/** 每组件的扁平字段白名单（不含特例嵌套字段） */
const FIELD_MAP = {
  text: ['text', 'size', 'color', 'align'],
  divider: [],
  card: ['title', 'subtitle', 'accent'],
  list: ['dataPath'],
  table: ['dataPath'],
  form: [],
  action: ['label', 'color'],
  chart: ['kind', 'dataPath', 'xKey', 'yKey', 'color'],
};

/** 已知组件集合（与服务端 validate 白名单一致） */
export const KNOWN_COMPONENTS = Object.keys(FIELD_MAP);

let idSeq = 0;
function genId(type) {
  idSeq += 1;
  return `${type}_${Date.now().toString(36)}${idSeq.toString(36)}${Math.random().toString(36).slice(2, 6)}`;
}

/** 深拷贝专用（普通 JSON 数据，无函数/循环） */
function clone(obj) {
  return obj === undefined ? undefined : JSON.parse(JSON.stringify(obj));
}

/** 从 DSL 节点提取 ModuleAction 形状的对象；无内容返回 undefined */
function pickAction(src) {
  if (!src || typeof src !== 'object') return undefined;
  const out = {};
  for (const k of ['action', 'path', 'method', 'page', 'text', 'dataPath', 'url']) {
    if (src[k] !== undefined && src[k] !== null && src[k] !== '') out[k] = src[k];
  }
  return Object.keys(out).length ? out : undefined;
}

/** 从 DSL 节点提取 fields 数组（form 组件） */
function pickFields(src) {
  if (!Array.isArray(src)) return [];
  const out = [];
  for (const f of src) {
    if (!f || typeof f !== 'object') continue;
    if (!f.key) continue; // 服务端会剔 key 为空的字段，这里提前剔
    const item = {
      key: String(f.key),
      label: String(f.label ?? f.key),
      type: String(f.type ?? 'text'),
      // 🔴 required 列在属性面板是文本单元格，只能产出字符串 'true'/'false'；
      //    initValue 里预填的也是字符串。两种形态都认，否则"必填"静默丢失。
      required: f.required === true || f.required === 'true',
    };
    if (f.placeholder) item.placeholder = String(f.placeholder);
    if (Array.isArray(f.options) && f.options.length) {
      item.options = f.options.map((o) => ({ label: String(o.label ?? ''), value: String(o.value ?? '') }));
    }
    if (f.optionsFrom) {
      // 🔴 服务端红线：optionsFrom 只认 /api/hooks/ 前缀，画布上照写、保存时服务端兜底
      item.optionsFrom = String(f.optionsFrom);
      item.optionsPath = String(f.optionsPath ?? 'data.rows');
      item.optionLabel = String(f.optionLabel ?? 'label');
      item.optionValue = String(f.optionValue ?? 'value');
    }
    out.push(item);
  }
  return out;
}

/** 从 DSL 节点提取 columns 数组（table 组件） */
function pickColumns(src) {
  if (!Array.isArray(src)) return [];
  const out = [];
  for (const c of src) {
    if (!c || typeof c !== 'object' || !c.key) continue;
    const col = { key: String(c.key), label: String(c.label ?? c.key) };
    if (c.width !== undefined && c.width !== null && c.width !== '') {
      const w = Number(c.width);
      if (Number.isFinite(w) && w > 0) col.width = w;
    }
    out.push(col);
  }
  return out;
}

/** 从 DSL 节点提取 itemTemplate（list 组件） */
function pickItemTemplate(src) {
  if (!src || typeof src !== 'object') return { title: '' };
  const t = {
    title: String(src.title ?? ''),
    subtitle: String(src.subtitle ?? ''),
    trailing: String(src.trailing ?? ''),
  };
  return t;
}

/**
 * DSL 节点 → 小智 ModuleComponent JSON（不含 component 字段，由调用方补）
 */
function nodeToComponent(node) {
  if (!node || typeof node !== 'object') return null;
  const type = node.type;
  if (!KNOWN_COMPONENTS.includes(type)) return null;

  const out = { component: type };

  // 扁平白名单字段
  for (const k of FIELD_MAP[type]) {
    if (node[k] === undefined || node[k] === null || node[k] === '') continue;
    if (k === 'size' || k === 'width') {
      const n = Number(node[k]);
      if (Number.isFinite(n)) out[k] = n;
      continue;
    }
    out[k] = clone(node[k]);
  }

  // 特例嵌套字段
  switch (type) {
    case 'action': {
      const onTap = pickAction(node.onTap);
      if (onTap) out.onTap = onTap;
      break;
    }
    case 'form': {
      const fields = pickFields(node.fields);
      if (fields.length) out.fields = fields;
      const submit = pickAction(node.submit);
      if (submit) out.submit = submit;
      break;
    }
    case 'table': {
      const columns = pickColumns(node.columns);
      if (columns.length) out.columns = columns;
      break;
    }
    case 'list': {
      out.itemTemplate = pickItemTemplate(node.itemTemplate);
      break;
    }
    case 'card': {
      // tmagic 容器子节点在 items 里；小智 schema 叫 children
      const kids = Array.isArray(node.items)
        ? node.items.map((c) => nodeToComponent(c)).filter(Boolean)
        : [];
      if (kids.length) out.children = kids;
      break;
    }
    default:
      break;
  }
  return out;
}

/**
 * tmagic DSL（MApp 形状）→ 小智 module body 数组
 * @param {object} dsl { items: [ { type:'page', items:[...] } ] }
 * @returns {Array} ModuleComponent JSON 数组
 */
export function dslToBody(dsl) {
  const page = dsl?.items?.find((n) => n && n.type === 'page') || dsl?.items?.[0];
  if (!page || !Array.isArray(page.items)) return [];
  return page.items.map((c) => nodeToComponent(c)).filter(Boolean);
}

/**
 * 小智 module body 数组 → tmagic DSL（MApp 形状）
 * @param {Array} body ModuleComponent JSON 数组
 * @returns {object} { items: [pageNode] }
 */
export function bodyToDsl(body) {
  if (!Array.isArray(body)) body = [];
  const pageId = genId('page');

  function componentToNode(comp) {
    if (!comp || typeof comp !== 'object') return null;
    const type = String(comp.component || '');
    if (!KNOWN_COMPONENTS.includes(type)) return null;

    const node = { id: genId(type), type };

    for (const k of FIELD_MAP[type]) {
      if (comp[k] === undefined || comp[k] === null || comp[k] === '') continue;
      node[k] = clone(comp[k]);
    }

    switch (type) {
      case 'action': {
        if (comp.onTap) node.onTap = clone(comp.onTap);
        break;
      }
      case 'form': {
        if (Array.isArray(comp.fields)) node.fields = clone(comp.fields);
        if (comp.submit) node.submit = clone(comp.submit);
        break;
      }
      case 'table': {
        if (Array.isArray(comp.columns)) node.columns = clone(comp.columns);
        break;
      }
      case 'list': {
        if (comp.itemTemplate) node.itemTemplate = clone(comp.itemTemplate);
        break;
      }
      case 'card': {
        node.items = Array.isArray(comp.children)
          ? comp.children.map((c) => componentToNode(c)).filter(Boolean)
          : [];
        break;
      }
      default:
        break;
    }
    return node;
  }

  const items = body.map((c) => componentToNode(c)).filter(Boolean);
  return { items: [{ id: pageId, type: 'page', items }] };
}

/**
 * 空 DSL（新模块起点）
 */
export function emptyDsl() {
  return bodyToDsl([]);
}
