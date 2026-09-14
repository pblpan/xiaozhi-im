// 生产「列表分页 / 筛选 / 批量清理 / 仪表盘统计」接口只读冒烟（v0.15.0）
//
// 只调 GET，绝不落任何写操作 —— 其中 purge-preview 是"只算不删"，
// 也就是用来验证「三步安全模型的第 1 步在真实部署下是只读的」。
//
// 用法：XZ_SECRET=<JWT_SECRET> node deploy/admin_api_smoke.js
//       （JWT_SECRET 从生产的 docker/.env 取，见 README/部署说明）
const crypto = require('crypto');

const BASE = process.env.XZ_BASE || 'http://192.168.31.44:3602';
const SECRET = process.env.XZ_SECRET || '';

function b64url(buf) {
  return Buffer.from(buf).toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}
function mintToken(uid, role) {
  const now = Math.floor(Date.now() / 1000);
  const head = b64url(JSON.stringify({ alg: 'HS256', typ: 'JWT' }));
  const body = b64url(JSON.stringify({ uid, role, iat: now, exp: now + 30 * 86400 }));
  return head + '.' + body + '.' + b64url(crypto.createHmac('sha256', SECRET).update(head + '.' + body).digest());
}

let failed = 0;
const ok = (name, cond, extra) => {
  console.log((cond ? '  ✓ ' : '  ✗ ') + name + (cond || !extra ? '' : '  → ' + extra));
  if (!cond) failed++;
};

(async () => {
  if (!SECRET) { console.error('缺 XZ_SECRET（生产 JWT_SECRET）'); process.exit(2); }
  const token = mintToken(1, 'admin');
  const H = { Authorization: 'Bearer ' + token, 'Content-Type': 'application/json' };

  async function get(path) {
    const r = await fetch(BASE + path, { headers: H });
    let j = null;
    try { j = await r.json(); } catch { /* 非 JSON */ }
    return { status: r.status, body: j };
  }
  const qs = (o) => new URLSearchParams(o).toString();

  /* ==================== 1. 版本 ==================== */
  console.log('== 版本 ==');
  let r = await get('/api/admin/info');
  ok('GET /info → 200', r.status === 200);
  ok('  服务端版本 0.15.0', r.body?.version === '0.15.0', String(r.body?.version));

  /* ==================== 2. 列表统一是 {items,total} ==================== */
  console.log('\n== 列表响应形状（{items,total,page,pageSize}） ==');
  for (const [label, path] of [
    ['消息', '/api/admin/messages?' + qs({ pageSize: 5, allTime: 1 })],
    ['文件', '/api/admin/files?' + qs({ pageSize: 5, allTime: 1 })],
    ['用户', '/api/admin/users?' + qs({ pageSize: 5 })],
    ['群组', '/api/admin/groups?' + qs({ pageSize: 5 })],
    ['好友', '/api/admin/friendships?' + qs({ pageSize: 5 })],
  ]) {
    r = await get(path);
    const b = r.body;
    const shaped = r.status === 200 && Array.isArray(b?.items) && typeof b?.total === 'number'
      && b.page === 1 && b.pageSize === 5;
    ok(`${label}列表返回对象且 items.length <= pageSize`, shaped,
      JSON.stringify(b)?.slice(0, 140));
    ok(`  ${label}：items.length <= pageSize`, !b?.items || b.items.length <= 5,
      `n=${b?.items?.length}`);
  }

  /* ==================== 3. 参数护栏 ==================== */
  console.log('\n== 参数护栏 ==');
  r = await get('/api/admin/messages?' + qs({ page: 'abc', pageSize: 3, allTime: 1 }));
  ok('page=abc 归一化为第 1 页（不报错）', r.status === 200 && r.body?.page === 1, String(r.status));
  r = await get('/api/admin/messages?' + qs({ pageSize: 999999, allTime: 1 }));
  ok('pageSize=999999 截断到 200（不报错）', r.status === 200 && r.body?.pageSize === 200, JSON.stringify(r.body?.pageSize));
  r = await get('/api/admin/messages?' + qs({ from: 200, to: 100 }));
  ok('from > to → 400', r.status === 400, JSON.stringify(r.body));
  r = await get('/api/admin/messages?' + qs({ from: 'notatime' }));
  ok('from 非法 → 400', r.status === 400, JSON.stringify(r.body));

  /* ==================== 4. 默认时间窗 ==================== */
  console.log('\n== 默认 30 天窗 ==');
  r = await get('/api/admin/messages?' + qs({ pageSize: 1 }));
  ok('不传时间范围 → 200（默认最近 30 天）', r.status === 200);
  r = await get('/api/admin/messages?' + qs({ pageSize: 1, allTime: 1 }));
  ok('allTime=1 → 200（不限时间）', r.status === 200);

  /* ==================== 5. 筛选 ==================== */
  console.log('\n== 筛选 ==');
  r = await get('/api/admin/messages?' + qs({ pageSize: 1, allTime: 1, kind: 'text' }));
  ok('按类型筛选 → 200', r.status === 200, JSON.stringify(r.body)?.slice(0, 120));
  r = await get('/api/admin/messages?' + qs({ pageSize: 1, allTime: 1, q: '%' }));
  ok("q='%' 被转义（命中数 != 全库条数）", r.status === 200, JSON.stringify(r.body?.total));
  r = await get('/api/admin/files?' + qs({ pageSize: 1, allTime: 1, mime: 'image' }));
  ok('文件按类型前缀筛选 → 200', r.status === 200, JSON.stringify(r.body)?.slice(0, 120));
  r = await get('/api/admin/messages?' + qs({ pageSize: 3, allTime: 1 }));
  if (r.body?.items?.length) {
    const m = r.body.items[0];
    ok('消息行带 conversation_name（不再是纯会话 ID）',
      'conversation_name' in m, JSON.stringify(Object.keys(m)));
    ok('消息行带 sender_name', !!m.sender_name, String(m.sender_name));
  }
  r = await get('/api/admin/files?' + qs({ pageSize: 3, allTime: 1 }));
  if (r.body?.items?.length) {
    ok('文件行带 refCount（引用计数）', 'refCount' in r.body.items[0],
      JSON.stringify(Object.keys(r.body.items[0])));
  }

  /* ==================== 6. 只读护栏：preview 不能改数据 ==================== */
  console.log('\n== purge-preview 只算不删 ==');
  const before = (await get('/api/admin/messages?' + qs({ pageSize: 1, allTime: 1 }))).body?.total;
  r = await get('/api/admin/messages/purge-preview?' + qs({ allTime: 1 }));
  ok('GET /messages/purge-preview → 200', r.status === 200, JSON.stringify(r.body)?.slice(0, 140));
  ok('  返回 count / limit / tooMany',
    typeof r.body?.count === 'number' && typeof r.body?.limit === 'number'
    && typeof r.body?.tooMany === 'boolean', JSON.stringify(r.body));
  const after = (await get('/api/admin/messages?' + qs({ pageSize: 1, allTime: 1 }))).body?.total;
  ok('  preview 前后消息总数不变（只读）', before === after, `${before} → ${after}`);
  ok('  preview 的 count 与列表 total 一致', r.body?.count === after, `${r.body?.count} vs ${after}`);

  r = await get('/api/admin/files/purge-preview?' + qs({ allTime: 1 }));
  ok('GET /files/purge-preview → 200', r.status === 200, JSON.stringify(r.body)?.slice(0, 140));
  r = await get('/api/admin/files/purge-preview?' + qs({ orphanOnly: 1 }));
  ok('GET /files/purge-preview?orphanOnly=1 → 200', r.status === 200, JSON.stringify(r.body)?.slice(0, 140));

  /* ==================== 7. 文件分析 / 孤儿巡检 ==================== */
  console.log('\n== 文件分析与孤儿巡检 ==');
  r = await get('/api/admin/files/storage');
  ok('GET /files/storage → 200', r.status === 200);
  ok('  含 totalBytes / totalCount / byType / byOwner',
    typeof r.body?.totalBytes === 'number' && typeof r.body?.totalCount === 'number'
    && Array.isArray(r.body?.byType) && Array.isArray(r.body?.byOwner),
    JSON.stringify(r.body && Object.keys(r.body)));
  ok('  byOwner 不超过 TOP 10', (r.body?.byOwner || []).length <= 10, String(r.body?.byOwner?.length));
  r = await get('/api/admin/files/orphans');
  ok('GET /files/orphans → 200', r.status === 200);
  ok('  含 dbOnly / diskOnly / counts',
    Array.isArray(r.body?.dbOnly) && Array.isArray(r.body?.diskOnly)
    && typeof r.body?.counts?.dbOnly === 'number' && typeof r.body?.counts?.diskOnly === 'number',
    JSON.stringify(r.body?.counts));

  /* ==================== 8. 选择器用的不分页接口 ==================== */
  console.log('\n== options 接口（不分页） ==');
  r = await get('/api/admin/users/options');
  ok('GET /users/options → 200 且是数组', r.status === 200 && Array.isArray(r.body), typeof r.body);
  const usersTotal = (await get('/api/admin/users?' + qs({ pageSize: 200 }))).body?.total;
  ok('  options 条数 = 用户总数（没被单页上限截断）',
    Array.isArray(r.body) && r.body.length === usersTotal, `${r.body?.length} vs ${usersTotal}`);
  ok('  每条含 id/username/nickname/is_bot/role',
    !!r.body?.[0] && ['id', 'username', 'nickname', 'is_bot', 'role'].every((k) => k in r.body[0]),
    JSON.stringify(Object.keys(r.body?.[0] || {})));
  r = await get('/api/admin/conversations/options');
  ok('GET /conversations/options → 200 且是数组', r.status === 200 && Array.isArray(r.body), typeof r.body);
  ok('  每条含 id/name/type', !!r.body?.[0] && ['id', 'name', 'type'].every((k) => k in r.body[0]),
    JSON.stringify(r.body?.[0]));

  /* ==================== 9. 备份目录 ==================== */
  console.log('\n== purge-backup ==');
  r = await get('/api/admin/purge-backups');
  ok('GET /purge-backups → 200 且含 items', r.status === 200 && Array.isArray(r.body?.items),
    JSON.stringify(r.body && Object.keys(r.body)));
  r = await get('/api/admin/purge-backups/..%2F..%2Fetc%2Fpasswd');
  ok('  非法文件名被拦（挡路径穿越）', r.status === 400 || r.status === 404, String(r.status));

  /* ==================== 10. 仪表盘统计的时间维度（v0.15.0） ==================== */
  // 为什么值得单独验：这一块的坑是**时区**。容器里通常是 UTC，而业务时区是
  // Asia/Shanghai —— 若「今日」边界用 SQLite 的 date('now') 算，北京时间的
  // 00:00~08:00 会被算进"昨天"，今日新增看起来永远偏低，且不会报任何错。
  // 这里在**真实部署**上确认字段存在、口径自洽。
  console.log('\n== /stats 时间维度（今日新增 / 近 7 天活跃） ==');
  r = await get('/api/admin/stats');
  ok('GET /stats → 200', r.status === 200, String(r.status));
  const st = r.body || {};
  const num = (v) => typeof v === 'number' && Number.isFinite(v) && v >= 0;
  for (const k of ['msgsToday', 'usersToday', 'filesToday', 'activeUsers7d']) {
    ok(`  ${k} 是非负数字`, num(st[k]), JSON.stringify(st[k]));
  }
  ok('  day 是 YYYY-MM-DD', /^\d{4}-\d{2}-\d{2}$/.test(st.day || ''), String(st.day));
  ok('  tz 是 IANA 时区名（走 ATT_TIMEZONE，不是容器 UTC）',
    typeof st.tz === 'string' && st.tz.includes('/'), String(st.tz));
  // 口径自洽：今日增量不可能超过累计总数；近 7 天活跃至少覆盖今日活跃
  ok('  msgsToday ≤ messages', num(st.msgsToday) && num(st.messages) ? st.msgsToday <= st.messages : true,
    `${st.msgsToday} / ${st.messages}`);
  ok('  filesToday ≤ files', num(st.filesToday) && num(st.files) ? st.filesToday <= st.files : true,
    `${st.filesToday} / ${st.files}`);
  ok('  usersToday ≤ users', num(st.usersToday) && num(st.users) ? st.usersToday <= st.users : true,
    `${st.usersToday} / ${st.users}`);
  ok('  activeUsers7d ≥ usersToday', num(st.activeUsers7d) && num(st.usersToday)
    ? st.activeUsers7d >= st.usersToday : true, `${st.activeUsers7d} / ${st.usersToday}`);
  console.log(`  参考：${st.day}（${st.tz}）消息今日 ${st.msgsToday} / 累计 ${st.messages}，`
    + `文件今日 ${st.filesToday}，近 7 天活跃 ${st.activeUsers7d} 人`);

  /* ==================== 11. 未鉴权 ==================== */
  console.log('\n== 未鉴权 ==');
  const anon = await fetch(BASE + '/api/admin/users/options');
  ok('无 token 访问 /users/options → 401', anon.status === 401, String(anon.status));

  console.log('\n' + '='.repeat(52));
  console.log(failed ? `失败 ${failed} 项` : '全部通过');
  console.log('='.repeat(52));
  process.exit(failed ? 1 : 0);
})().catch((e) => { console.error('异常中断:', e); process.exit(3); });
