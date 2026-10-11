'use strict';
/**
 * 智能助手上线验证探针（跑在容器里，#314）。
 * 验证：/api/assistant/ask 真的能答（未配 LLM → 内置知识库）、
 *       管理端配置接口可用且 Key 不回明文、bootstrap 不泄漏 assistant_* 配置、
 *       内置应用下发清单里有 assistant、管理台新构建带「问一问」。
 * 全程只读 + 一次自清理的配置写读（原值写回）。
 * 用法：python deploy/_exec_in_container.py deploy/_assistant_probe.js
 */
const { signToken } = require('/app/src/auth');
const { DatabaseSync } = require('node:sqlite');

const db = new DatabaseSync('/data/xiaozhi-im.db', { readOnly: true });

let pass = 0, fail = 0;
const ok = (n, c, x) => { if (c) { pass++; console.log('  ✓ ' + n); } else { fail++; console.log('  ✗ ' + n + (x ? '  → ' + x : '')); } };

const admin = db.prepare("SELECT id FROM users WHERE role='admin' ORDER BY id LIMIT 1").get();
db.close();

const BASE = 'http://127.0.0.1:' + (process.env.PORT || 3000);
const token = signToken({ uid: admin.id, role: 'admin' });
async function api(method, p, body, tok) {
  const r = await fetch(BASE + p, {
    method,
    headers: { 'Content-Type': 'application/json', Authorization: 'Bearer ' + (tok || token) },
    body: body ? JSON.stringify(body) : undefined,
  });
  let j = null; try { j = await r.json(); } catch { /* HTML */ }
  return { status: r.status, body: j };
}

(async () => {
  // 1. 用户问答（未配 LLM → 知识库）
  let r = await api('POST', '/api/assistant/ask', { question: '怎么打卡？' });
  ok('POST /assistant/ask → 200', r.status === 200, JSON.stringify(r.body).slice(0, 140));
  ok('  命中内置知识库（source=kb）', r.body?.source === 'kb', JSON.stringify(r.body?.source));
  ok('  答案在讲考勤打卡', /打卡|考勤/.test(r.body?.answer || ''), JSON.stringify((r.body?.answer || '').slice(0, 50)));

  r = await api('POST', '/api/assistant/ask', { question: '手机和电脑怎么传文件' });
  ok('  文件助手问题也命中', r.body?.source === 'kb' && /文件助手|传文件/.test(r.body?.answer || ''),
    JSON.stringify((r.body?.answer || '').slice(0, 50)));

  // 2. 管理端配置
  r = await api('GET', '/api/admin/assistant/config');
  ok('GET admin/assistant/config → 200', r.status === 200, JSON.stringify(r.body));
  const saved = r.body;
  ok('  Key 只回 hasKey（响应里没有 apiKey 字段）', !('apiKey' in (r.body || {})) && typeof r.body?.hasKey === 'boolean',
    JSON.stringify(r.body));
  ok('  开关默认关（不配 AI 也全功能可用）', r.body?.enabled === false, JSON.stringify(r.body?.enabled));

  // 3. 试问（force）
  r = await api('POST', '/api/admin/assistant/test', { question: '怎么建群' });
  ok('admin 试问 → 200 且有答案', r.status === 200 && (r.body?.answer || '').length > 10,
    JSON.stringify(r.body).slice(0, 120));

  // 4. bootstrap 不泄漏助手配置（免鉴权接口！）
  const boot = await (await fetch(BASE + '/api/client/bootstrap')).text();
  ok('🔴 bootstrap 不含 assistant_api_key/base/enabled 键',
    !boot.includes('assistant_api') && !boot.includes('assistantEnabled'), boot.slice(0, 80));

  // 5. 内置应用下发里有 assistant
  r = await api('GET', '/api/client/apps');
  const ids = JSON.stringify(r.body || []);
  ok('内置应用下发含 assistant（带 smart_toy 图标）',
    ids.includes('"assistant"') && ids.includes('smart_toy'), ids.slice(0, 200));

  // 6. 管理台新构建
  const idx = await (await fetch(BASE + '/admin/')).text();
  const m = idx.match(/assets\/index-[\w-]+\.js/);
  if (m) {
    const js = await (await fetch(BASE + '/admin/' + m[0])).text();
    ok('bundle 带「问一问」入口', js.includes('问一问'));
    ok('bundle 带智能助手接入配置', js.includes('智能助手接入'));
  }

  // 7. 停用门禁自检：appguard 认得 assistant
  r = await api('POST', '/api/assistant/ask', { question: 'x' });
  ok('ask 接口活着（非 404）', r.status !== 404, JSON.stringify(r.status));

  console.log(`\n========== 探针结果：${pass} 通过 / ${fail} 失败 ==========`);
  process.exit(fail ? 1 : 0);
})().catch((e) => { console.error('探针异常：', e); process.exit(1); });
