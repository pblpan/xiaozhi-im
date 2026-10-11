// 智能助手（#314 龙哥：智能助手接管帮助 + 接入智能体）。
//
// 两层设计：
//   · 内置帮助知识库（helpkb.js）—— 永远可用，零依赖，答"系统怎么用"。
//   · 可选 LLM 层 —— 管理台配 OpenAI 兼容接口（DeepSeek 等）后，
//     把 KB 命中作为上下文让模型组织成人话再回。Key 只存服务端，
//     接口只回 hasKey 布尔，绝不回明文。
//
// 降级链（每一层失败都有下家，绝不把异常裸抛给用户）：
//   LLM 配好且启用 → LLM；LLM 失败 → KB；KB 无命中 → 兜底话术。
'use strict';

const settings = require('./settings');
const helpkb = require('./helpkb');

const Q_MAX = 500;              // 问题长度上限（防灌）
const LLM_TIMEOUT_MS = 30000;
const KB_CONTEXT_MAX = 3;       // 带给 LLM 的 KB 条数上限

function getConfig() {
  const apiKey = String(settings.get('assistantApiKey') || '');
  return {
    enabled: !!settings.get('assistantEnabled'),
    apiBase: String(settings.get('assistantApiBase') || '').trim(),
    model: String(settings.get('assistantModel') || '').trim() || 'deepseek-chat',
    hasKey: !!apiKey,
    _apiKey: apiKey,
  };
}

/** 保存配置。apiKey undefined = 沿用已存（前端不回明文，编辑时留空即沿用）；'' = 清除 */
function saveConfig(input, by) {
  const b = input || {};
  const out = {};
  if (b.enabled !== undefined) out.enabled = !!b.enabled;
  if (b.apiBase !== undefined) {
    const base = String(b.apiBase || '').trim();
    if (base && !/^https?:\/\/.+/i.test(base)) return { error: '接口地址要以 http:// 或 https:// 开头' };
    out.apiBase = base.replace(/\/+$/, '');
  }
  if (b.model !== undefined) {
    const m = String(b.model || '').trim();
    if (m.length > 80) return { error: '模型名太长' };
    out.model = m;
  }
  if (b.apiKey !== undefined) {
    const k = String(b.apiKey || '').trim();
    if (k.length > 200) return { error: 'API Key 太长' };
    out.apiKey = k;
  }
  for (const [k, v] of Object.entries(out)) {
    const r = settings.setRaw(
      { enabled: 'assistantEnabled', apiBase: 'assistantApiBase',
        model: 'assistantModel', apiKey: 'assistantApiKey' }[k], v, by);
    if (r.error) return r;
  }
  return { ok: true };
}

/** OpenAI 兼容地址归一：填 https://api.deepseek.com 或 .../v1 或完整 /chat/completions 都认 */
function completionsUrl(apiBase) {
  const b = apiBase.replace(/\/+$/, '');
  if (/\/chat\/completions$/.test(b)) return b;
  if (/\/v\d+$/.test(b)) return b + '/chat/completions';
  return b + '/v1/chat/completions';
}

async function llmAnswer(question, hits, cfg) {
  const kbBlock = hits.length
    ? '参考资料（内置帮助库命中，优先采用其中的口径，不要编造）：\n' +
      hits.map((h, i) => `[${i + 1}] 问：${h.q}\n答：${h.a}`).join('\n\n')
    : '（内置帮助库没有命中条目，请基于常识回答，并提示用户可联系管理员。）';
  const sys = [
    '你是「小智 IM」的智能助手，回答这个软件的使用问题。',
    '规则：① 口径以参考资料为准，没提到的功能不要编；',
    '② 回答用简体中文、口语化、分点短句，别超过 200 字；',
    '③ 涉及管理台操作的，写清楚菜单路径；',
    '④ 解决不了的（数据/账目/权限类），让用户找管理员。',
  ].join('\n');

  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), LLM_TIMEOUT_MS);
  try {
    const res = await fetch(completionsUrl(cfg.apiBase), {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: 'Bearer ' + cfg._apiKey,
      },
      signal: ctrl.signal,
      body: JSON.stringify({
        model: cfg.model,
        temperature: 0.3,
        stream: false,
        messages: [
          { role: 'system', content: sys + '\n\n' + kbBlock },
          { role: 'user', content: question },
        ],
      }),
    });
    if (!res.ok) {
      const t = (await res.text().catch(() => '')).slice(0, 200);
      throw new Error(`LLM HTTP ${res.status}: ${t}`);
    }
    const j = await res.json();
    const text = j?.choices?.[0]?.message?.content;
    if (typeof text !== 'string' || !text.trim()) throw new Error('LLM 返回空内容');
    return text.trim();
  } finally {
    clearTimeout(timer);
  }
}

const FALLBACK = '这个问题我还没学过。可以换个问法试试（比如"怎么打卡""怎么建群"），'
  + '或到管理台「系统帮助」页搜索；解决不了请联系管理员。';

/**
 * 回答一个使用问题。
 * opts.force = 管理台「试问」用：即使总开关没开，只要 LLM 配好了就真调一次
 *              （否则"配好地址但没启用时想试一下"都做不到）。
 */
async function ask(question, opts = {}) {
  const q = String(question || '').trim().slice(0, Q_MAX);
  if (!q) return { error: '问题不能为空' };

  const hits = helpkb.search(q);
  const cfg = getConfig();
  const wantLlm = (cfg.enabled || opts.force) && cfg.apiBase && cfg.hasKey;

  if (wantLlm) {
    try {
      return { answer: await llmAnswer(q, hits.slice(0, KB_CONTEXT_MAX), cfg), source: 'llm', model: cfg.model };
    } catch (e) {
      const note = 'AI 服务暂不可用（' + String(e.message || e).slice(0, 120) + '），以下来自内置帮助库';
      if (hits.length) return { answer: hits[0].a, source: 'kb', related: hits.slice(1).map((h) => h.q), note };
      return { answer: FALLBACK, source: 'fallback', note };
    }
  }
  if (hits.length) {
    return { answer: hits[0].a, source: 'kb', related: hits.slice(1).map((h) => h.q),
      note: cfg.enabled && !cfg.hasKey ? '已启用 AI 但还没填 API Key，当前为内置帮助库回答' : undefined };
  }
  return { answer: FALLBACK, source: 'fallback' };
}

module.exports = { getConfig, saveConfig, ask, completionsUrl, FALLBACK };
