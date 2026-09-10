'use strict';
/**
 * 清理「工厂管理」群里的测试噪音消息（管理员接口）。
 *
 * 背景：工厂 V2 v1.0.08 首版有个 bug——无库存预警时定时巡检没有更新 last_stock_at，
 * 调度器每分钟判"超过间隔"，于是每分钟往群里推一条「库存巡检正常」，刷了 12 条。
 * bug 已修，但群里残留的噪音消息需要清掉。
 *
 * 用法:
 *   node clean_test_messages.js                       # 只列出，不删（dry-run）
 *   node clean_test_messages.js --apply               # 真的删除（按关键词）
 *   node clean_test_messages.js --q "关键词" --apply
 *   node clean_test_messages.js --all                 # 列出该群全部消息
 *   node clean_test_messages.js --all --apply         # 清空该群（危险：物理删除）
 *
 * 删除前会把被删消息完整导出到 ./_deleted_messages_<时间>.json 留档（可回溯）。
 */
const fs = require('fs');
const path = require('path');
const BASE = process.env.IM_BASE || 'http://192.168.31.44:3602';
const ADMIN = { username: process.env.IM_USER || 'admin', password: process.env.IM_PASS || 'admin123' };
const APPLY = process.argv.includes('--apply');
const ALL = process.argv.includes('--all');
const qIdx = process.argv.indexOf('--q');
const Q = qIdx >= 0 ? process.argv[qIdx + 1] : '库存巡检正常';

async function api(p, opts = {}) {
  const res = await fetch(BASE + p, {
    method: opts.method || 'GET',
    headers: { 'Content-Type': 'application/json', ...(opts.token ? { Authorization: 'Bearer ' + opts.token } : {}) },
    body: opts.body ? JSON.stringify(opts.body) : undefined,
  });
  const txt = await res.text();
  let body; try { body = JSON.parse(txt); } catch { body = txt; }
  if (!res.ok) throw new Error(`${opts.method || 'GET'} ${p} → HTTP ${res.status} ${txt.slice(0, 200)}`);
  return body;
}

(async () => {
  console.log(`目标: ${BASE}   筛选: ${ALL ? '该群全部消息' : `关键词 "${Q}"`}   模式: ${APPLY ? '【删除】' : '只读预览'}\n`);
  const login = await api('/api/auth/login', { method: 'POST', body: ADMIN });
  const t = login.token;
  console.log('✓ 管理员登录:', login.user.username);

  // 定位「工厂管理」群
  const groups = await api('/api/admin/groups', { token: t });
  const list = Array.isArray(groups) ? groups : (groups.groups || []);
  const g = list.find((x) => (x.name || x.nickname) === '工厂管理');
  if (!g) { console.log('✗ 未找到「工厂管理」群，现有群:', list.map((x) => x.name || x.nickname)); return; }
  const detail = await api(`/api/groups/${g.id}`, { token: t });
  const cid = (detail.group || detail).conversation_id;
  console.log(`✓ 找到群「工厂管理」 id=${g.id} conversation_id=${cid}\n`);

  // 拉该群最近消息
  const qs = ALL ? '?limit=1000' : `?limit=1000&q=${encodeURIComponent(Q)}`;
  const msgs = await api(`/api/admin/messages${qs}`, { token: t });
  const hit = msgs
    .filter((m) => Number(m.conversation_id) === Number(cid))
    .sort((a, b) => a.id - b.id);
  console.log(`匹配到 ${hit.length} 条消息:`);
  for (const m of hit) {
    console.log(`  id=${m.id}  ${new Date(Number(m.created_at)).toLocaleString('zh-CN')}  ${m.kind}  ${String(m.content).replace(/\s+/g, ' ').slice(0, 70)}`);
  }

  if (!hit.length) { console.log('\n没有需要清理的消息。'); return; }
  if (!APPLY) { console.log('\n（只读预览，未删除。加 --apply 真正执行删除）'); return; }

  // 删除前留档，便于回溯
  const dump = path.join(__dirname, `_deleted_messages_${new Date().toISOString().replace(/[:.]/g, '-')}.json`);
  fs.writeFileSync(dump, JSON.stringify(hit, null, 2), 'utf-8');
  console.log(`\n已留档: ${dump}`);

  let okN = 0; let failN = 0;
  for (const m of hit) {
    try { await api(`/api/admin/messages/${m.id}`, { method: 'DELETE', token: t }); okN++; }
    catch (e) { failN++; console.log('  ✗ 删除失败 id=' + m.id, e.message); }
  }
  console.log(`\n=== 删除完成：成功 ${okN} / 失败 ${failN} ===`);
})().catch((e) => { console.error('异常:', e.message); process.exit(1); });
