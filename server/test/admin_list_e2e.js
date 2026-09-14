// 管理台列表：分页 / 筛选 / 批量清理 / 存储分析 / 孤儿巡检 —— 端到端测试
//
//   node test/admin_list_e2e.js
//
// 覆盖 SPEC-消息与文件管理.md §8.1 的 18 项用例，外加默认时间窗、排序、文件级联等。
//
// 【为什么造数据用直连 SQLite、断言全走 HTTP】
// 本测试要验的是"翻页不重不漏""purge 三步护栏"这类**接口行为**，断言必须走 HTTP
// 才作数。但准备数据（120 条消息、20001 条大批量、101 个会话、60 个用户）走 HTTP
// 要发上万次请求，跑一次几分钟 —— 所以夹具用批量插入（单个事务，毫秒级），
// 这是常规做法。两者结合：数据是造的，行为是真的。
//
// 【为什么 20000 上限要在最后测】
// 触发"单次清理超上限"必须让命中数 > 20000。造这批数据会把普通分页用例的
// total 全部打乱，所以放在最后，且用独立的会话隔离。

const { spawn } = require('child_process');
const path = require('path');
const fs = require('fs');
const os = require('os');
const { DatabaseSync } = require('node:sqlite');

const PORT = 3702;
const BASE = `http://127.0.0.1:${PORT}`;
const SERVER_DIR = path.resolve(__dirname, '..');
const DATA_DIR = path.join(os.tmpdir(), 'xiaozhi-adminlist-e2e-' + Date.now());
const DB_PATH = path.join(DATA_DIR, 'xiaozhi-im.db');
const FILES_DIR = path.join(DATA_DIR, 'files');

let passed = 0;
let failed = 0;
const failures = [];

function ok(name, cond, extra) {
  if (cond) { passed++; console.log(`  \u2713 ${name}`); }
  else {
    failed++;
    failures.push(name + (extra ? ` — ${extra}` : ''));
    console.log(`  \u2717 ${name}${extra ? '  → ' + extra : ''}`);
  }
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function api(method, p, { token, body } = {}) {
  const res = await fetch(BASE + p, {
    method,
    headers: {
      'Content-Type': 'application/json',
      ...(token ? { Authorization: 'Bearer ' + token } : {}),
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  let json = null;
  try { json = await res.json(); } catch { /* 空响应 */ }
  return { status: res.status, body: json };
}

/** 直连库做夹具（不是被测对象，只用来准备/核对数据） */
function withDb(fn) {
  const d = new DatabaseSync(DB_PATH);
  try {
    d.exec('PRAGMA busy_timeout = 8000');
    return fn(d);
  } finally {
    try { d.close(); } catch { /* ignore */ }
  }
}

function seedMessages(cid, senderId, n, prefix, opts = {}) {
  return withDb((d) => {
    const ins = d.prepare(`INSERT INTO messages (conversation_id,sender_id,kind,content,file_id,created_at,edited,deleted)
      VALUES (?,?,?,?,?,?,0,0)`);
    const now = Date.now();
    const ids = [];
    d.exec('BEGIN');
    for (let i = 1; i <= n; i++) {
      const at = opts.ageMs ? now - opts.ageMs : now - (n - i) * 1000;
      const r = ins.run(cid, senderId, opts.kind || 'text', prefix + String(i).padStart(5, '0'),
        opts.fileId || null, at);
      ids.push(Number(r.lastInsertRowid));
    }
    d.exec('COMMIT');
    return ids;
  });
}

let serverProc = null;
let serverLog = '';

async function startServer() {
  serverProc = spawn(process.execPath, [path.join(SERVER_DIR, 'src', 'index.js')], {
    env: { ...process.env, PORT: String(PORT), DATA_DIR, ADMIN_PASSWORD: 'admin123' },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  serverProc.stdout.on('data', (d) => { serverLog += d.toString(); });
  serverProc.stderr.on('data', (d) => { serverLog += d.toString(); });
  for (let i = 0; i < 80; i++) {
    try {
      const r = await fetch(BASE + '/api/health');
      if (r.ok) return;
    } catch { /* 还没起来 */ }
    await sleep(250);
  }
  throw new Error('服务端启动超时\n' + serverLog);
}

function stopServer() {
  if (serverProc) { try { serverProc.kill(); } catch { /* ignore */ } }
  try { fs.rmSync(DATA_DIR, { recursive: true, force: true }); } catch { /* ignore */ }
}

/** 取完所有页的 id（用于"不重不漏"校验） */
async function allIds(token, base, extra = {}) {
  const ids = [];
  let page = 1;
  let total = null;
  for (;;) {
    const qs = new URLSearchParams({ ...extra, page: String(page), pageSize: '50', allTime: '1' });
    const r = await api('GET', `${base}?${qs}`, { token });
    if (r.status !== 200) return { error: r.body, ids, total };
    if (total === null) total = r.body.total;
    ids.push(...r.body.items.map((x) => x.id));
    if (r.body.items.length < 50) break;
    page++;
    if (page > 200) break;   // 死循环兜底
  }
  return { ids, total };
}

(async () => {
  await startServer();
  console.log('[admin list E2E] 服务端已就绪 ' + BASE + '\n');

  let r = await api('POST', '/api/auth/login', { body: { username: 'admin', password: 'admin123' } });
  const admin = r.body?.token;
  ok('管理员登录', !!admin, JSON.stringify(r.body));

  const adminId = (await api('GET', '/api/admin/users/options', { token: admin }))
    .body.find((u) => u.username === 'admin')?.id;

  // 建两个普通用户
  await api('POST', '/api/admin/users', { token: admin, body: { username: 'u1', password: 'u1pass', nickname: '张三' } });
  await api('POST', '/api/admin/users', { token: admin, body: { username: 'u2', password: 'u2pass', nickname: '李四' } });
  const u1 = (await api('GET', '/api/admin/users/options', { token: admin })).body.find((u) => u.username === 'u1');
  const u2 = (await api('GET', '/api/admin/users/options', { token: admin })).body.find((u) => u.username === 'u2');
  ok('建用户 u1/u2 并出现在 options', !!u1?.id && !!u2?.id, JSON.stringify([u1, u2]));

  // 两个群（admin 为群主，便于测置顶权限）
  await api('POST', '/api/admin/groups', { token: admin, body: { name: '甲群', owner_id: adminId, member_ids: [u1.id, u2.id] } });
  await api('POST', '/api/admin/groups', { token: admin, body: { name: '乙群', owner_id: adminId, member_ids: [u1.id] } });
  const convs = (await api('GET', '/api/admin/conversations/options', { token: admin })).body;
  const convA = convs.find((c) => c.name === '甲群')?.id;
  const convB = convs.find((c) => c.name === '乙群')?.id;
  ok('建群「甲群」「乙群」并在会话 options 中可见', !!convA && !!convB, JSON.stringify(convs.slice(0, 5)));

  // ---------------- 一：分页基础 ----------------
  console.log('\n【一】分页基础（120 条）');
  const A_IDS = seedMessages(convA, u1.id, 120, 'msg-');
  // 特殊字符消息：用来验 LIKE 通配符转义
  const pctIds = seedMessages(convA, u1.id, 3, '折扣50%off');
  const undIds = seedMessages(convA, u1.id, 2, 'a_b_c');
  // 一条 60 天前的消息（在默认 30 天窗之外）
  seedMessages(convA, u1.id, 1, 'ancient-', { ageMs: 60 * 86400000 });

  r = await api('GET', `/api/admin/messages?page=1&pageSize=50&allTime=1`, { token: admin });
  ok('响应是 {items,total,page,pageSize} 对象（不再是裸数组）',
    Array.isArray(r.body?.items) && typeof r.body?.total === 'number'
    && r.body.page === 1 && r.body.pageSize === 50, JSON.stringify(r.body && Object.keys(r.body)));
  const totalA = r.body.total;
  ok('total = 126（120+3+2+1）', totalA === 126, String(totalA));

  const walked = await allIds(admin, '/api/admin/messages', { conversationId: String(convA) });
  ok('逐页取完 126 条，无重复', cameOut(walked, 126), `拿到 ${walked.ids.length} 条, total=${walked.total}`);
  function cameOut(w, expect) {
    const uniq = new Set(w.ids);
    return w.ids.length === expect && uniq.size === expect;
  }
  ok('每页 total 恒等于 126', walked.total === 126, String(walked.total));

  r = await api('GET', '/api/admin/messages?page=0&pageSize=50&allTime=1', { token: admin });
  ok('page=0 → 归一化为第 1 页', r.body?.page === 1, JSON.stringify(r.body?.page));
  r = await api('GET', '/api/admin/messages?page=-1&pageSize=50&allTime=1', { token: admin });
  ok('page=-1 → 归一化为第 1 页', r.body?.page === 1, JSON.stringify(r.body?.page));
  r = await api('GET', '/api/admin/messages?page=abc&pageSize=50&allTime=1', { token: admin });
  ok('page=abc → 归一化为第 1 页', r.body?.page === 1, JSON.stringify(r.body?.page));

  r = await api('GET', '/api/admin/messages?from=200&to=100&allTime=1', { token: admin });
  ok('from > to → 400', r.status === 400, JSON.stringify(r.body));
  r = await api('GET', '/api/admin/messages?from=notatime&allTime=1', { token: admin });
  ok('from 非法时间戳 → 400', r.status === 400, JSON.stringify(r.body));

  // 默认时间窗：60 天前那条不带时间参数应查不到，allTime=1 能查到
  r = await api('GET', `/api/admin/messages?conversationId=${convA}&q=ancient`, { token: admin });
  ok('默认只查最近 30 天：60 天前的消息查不到', r.body?.total === 0, JSON.stringify(r.body?.total));
  r = await api('GET', `/api/admin/messages?conversationId=${convA}&q=ancient&allTime=1`, { token: admin });
  ok('allTime=1 → 能查到 60 天前那条', r.body?.total === 1, JSON.stringify(r.body?.total));

  // ---------------- 二：筛选 ----------------
  console.log('\n【二】筛选');
  r = await api('GET', `/api/admin/messages?conversationId=${convA}&senderId=${u1.id}&allTime=1`, { token: admin });
  ok('按发送者筛选（u1 发的 126 条）', r.body?.total === 126, JSON.stringify(r.body?.total));
  r = await api('GET', `/api/admin/messages?conversationId=${convA}&senderId=${u2.id}&allTime=1`, { token: admin });
  ok('按发送者筛选（u2 没发过 → 0）', r.body?.total === 0, JSON.stringify(r.body?.total));
  r = await api('GET', `/api/admin/messages?conversationId=${convB}&allTime=1`, { token: admin });
  ok('按会话筛选（乙群还没消息 → 0）', r.body?.total === 0, JSON.stringify(r.body?.total));
  r = await api('GET', `/api/admin/messages?q=${encodeURIComponent('msg-00120')}&allTime=1`, { token: admin });
  ok('按关键词筛选命中 1 条', r.body?.total === 1, JSON.stringify(r.body?.total));

  r = await api('GET', `/api/admin/messages?q=${encodeURIComponent('%')}&allTime=1`, { token: admin });
  ok('q="%" 只匹配真的含 % 的 3 条（通配符已转义，不是全表）',
    r.body?.total === 3, JSON.stringify(r.body?.total));
  r = await api('GET', `/api/admin/messages?q=${encodeURIComponent('a_b')}&allTime=1`, { token: admin });
  ok('q="a_b" 不通配（只匹配字面 a_b 的 2 条）', r.body?.total === 2, JSON.stringify(r.body?.total));

  r = await api('GET', `/api/admin/messages?conversationId=${convA}&allTime=1&sort=asc&pageSize=3`, { token: admin });
  ok('sort=asc 返回最早 3 条（id 升序）',
    r.body?.items?.[0]?.id < r.body?.items?.[2]?.id, JSON.stringify(r.body?.items?.map((x) => x.id)));
  r = await api('GET', `/api/admin/messages?conversationId=${convA}&allTime=1&pageSize=3`, { token: admin });
  ok('默认 desc 返回最新 3 条', r.body?.items?.[0]?.id > r.body?.items?.[2]?.id,
    JSON.stringify(r.body?.items?.map((x) => x.id)));

  r = await api('GET', `/api/admin/messages?conversationId=${convA}&allTime=1&pageSize=3`, { token: admin });
  ok('conversation_name 已填充（群名）', r.body?.items?.[0]?.conversation_name === '甲群',
    JSON.stringify(r.body?.items?.[0]?.conversation_name));
  ok('sender_name 用昵称优先', r.body?.items?.[0]?.sender_name === '张三',
    JSON.stringify(r.body?.items?.[0]?.sender_name));

  // ---------------- 三：批量清理（小规模） ----------------
  console.log('\n【三】消息批量清理（三步安全模型）');
  seedMessages(convB, u1.id, 30, 'purge-me-');

  r = await api('GET', `/api/admin/messages/purge-preview?conversationId=${convB}&q=purge-me&allTime=1`, { token: admin });
  const pv = r.body;
  ok('purge-preview 返回 count/oldest/newest 且不删数据',
    pv?.count === 30 && pv.oldest > 0 && pv.newest > 0, JSON.stringify(pv));
  r = await api('GET', `/api/admin/messages?conversationId=${convB}&q=purge-me&allTime=1`, { token: admin });
  ok('  preview 后数据一条没少', r.body?.total === 30, JSON.stringify(r.body?.total));

  r = await api('POST', '/api/admin/messages/purge', {
    token: admin,
    body: { conversationId: convB, q: 'purge-me', allTime: 1, confirm: 29 },
  });
  ok('confirm 传错数字 → 409', r.status === 409, JSON.stringify(r.body));
  ok('  且响应带真实 count 让人重新确认', r.body?.count === 30, JSON.stringify(r.body?.count));
  r = await api('GET', `/api/admin/messages?conversationId=${convB}&q=purge-me&allTime=1`, { token: admin });
  ok('  409 之后数据一条没少', r.body?.total === 30, JSON.stringify(r.body?.total));

  r = await api('POST', '/api/admin/messages/purge', {
    token: admin,
    body: { conversationId: convB, q: 'purge-me', allTime: 1, confirm: 30 },
  });
  ok('confirm 一致 → 删除 30 条', r.status === 200 && r.body?.deleted === 30, JSON.stringify(r.body));
  const backupName = r.body?.backup;
  ok('  返回备份文件名', !!backupName, JSON.stringify(backupName));
  r = await api('GET', `/api/admin/messages?conversationId=${convB}&allTime=1`, { token: admin });
  ok('  删后该会话消息归零', r.body?.total === 0, JSON.stringify(r.body?.total));

  // 备份文件确实落盘，且条数等于删除数
  let bakCount = -1;
  try {
    const p = path.join(DATA_DIR, 'purge-backup', backupName);
    bakCount = JSON.parse(fs.readFileSync(p, 'utf8')).rows.length;
  } catch { /* 读不到就保持 -1 */ }
  ok('备份文件已生成且内容条数 = 删除数 30', bakCount === 30, String(bakCount));
  r = await api('GET', '/api/admin/purge-backups', { token: admin });
  ok('/purge-backups 能列出该备份', (r.body?.items || []).some((x) => x.name === backupName),
    JSON.stringify(r.body?.items?.map((x) => x.name)));
  r = await api('GET', '/api/admin/purge-backups/..%2F..%2Fetc%2Fpasswd', { token: admin });
  ok('  备份下载挡路径穿越', r.status === 400, String(r.status));

  // ---------------- 四：级联删文件 + 悬空引用 ----------------
  console.log('\n【四】文件级联与悬空引用');

  async function upload(name, content, mime) {
    const fd = new FormData();
    fd.append('file', new Blob([content], { type: mime }), name);
    const res = await fetch(BASE + '/api/files/upload', {
      method: 'POST',
      headers: { Authorization: 'Bearer ' + admin },
      body: fd,
    });
    return res.json();
  }
  const fx1 = await upload('solo.png', 'x'.repeat(100), 'image/png');
  const fx2 = await upload('shared.png', 'y'.repeat(200), 'image/png');
  ok('上传两个文件', !!fx1?.id && !!fx2?.id, JSON.stringify([fx1?.id, fx2?.id]));

  // fx1 被 1 条消息引用；fx2 被 2 条消息引用
  // ⚠️ 每条都要断言返回值：文件类消息发失败时不会报错，只会让后面的 refCount
  // 断言"看起来对"（都是 0 也算一致），这类假通过比直接报错更难查
  const send1 = await api('POST', `/api/conversations/${convB}/messages`, {
    token: admin, body: { kind: 'image', content: 'filemsg-solo', fileId: fx1.id },
  });
  ok('发文件消息 1（引用 fx1）成功', send1.status === 200 && !!send1.body?.id, JSON.stringify(send1.body));
  const send2 = await api('POST', `/api/conversations/${convB}/messages`, {
    token: admin, body: { kind: 'image', content: 'keepmsg-one', fileId: fx2.id },
  });
  const send3 = await api('POST', `/api/conversations/${convB}/messages`, {
    token: admin, body: { kind: 'image', content: 'keepmsg-two', fileId: fx2.id },
  });
  ok('发文件消息 2/3（引用 fx2）成功', send2.status === 200 && send3.status === 200,
    JSON.stringify([send2.body, send3.body]));

  r = await api('GET', `/api/admin/files?q=${encodeURIComponent('solo.png')}&allTime=1`, { token: admin });
  ok('文件列表带 refCount（solo.png = 1）',
    r.body?.items?.[0]?.refCount === 1, JSON.stringify(r.body?.items?.[0]));

  const fx1Path = path.join(FILES_DIR, withDb((d) => d.prepare('SELECT path FROM files WHERE id=?').get(fx1.id).path));
  const fx2Path = path.join(FILES_DIR, withDb((d) => d.prepare('SELECT path FROM files WHERE id=?').get(fx2.id).path));
  ok('两个文件确实在磁盘上', fs.existsSync(fx1Path) && fs.existsSync(fx2Path));

  // 删掉引用 fx1 的那条消息 → fx1 无引用，应连行带磁盘一起消失
  r = await api('POST', '/api/admin/messages/purge', {
    token: admin, body: { conversationId: convB, q: 'filemsg-solo', allTime: 1, confirm: 1 },
  });
  ok('批量删掉引用 fx1 的消息', r.status === 200 && r.body?.deleted === 1, JSON.stringify(r.body));
  const fx1Gone = !withDb((d) => d.prepare('SELECT id FROM files WHERE id=?').get(fx1.id));
  ok('无引用的 fx1：files 行已删除', fx1Gone);
  ok('无引用的 fx1：磁盘文件已删除', !fs.existsSync(fx1Path));

  // fx2 仍有 keepmsg-two 引用，必须保留
  const fx2Alive = !!withDb((d) => d.prepare('SELECT id FROM files WHERE id=?').get(fx2.id));
  ok('仍有引用的 fx2：files 行保留', fx2Alive);
  ok('仍有引用的 fx2：磁盘文件保留', fs.existsSync(fx2Path));
  r = await api('GET', `/api/admin/files?q=${encodeURIComponent('shared.png')}&allTime=1`, { token: admin });
  ok('  fx2 仍有 2 条引用（refCount 不变）', r.body?.items?.[0]?.refCount === 2,
    JSON.stringify(r.body?.items?.[0]?.refCount));

  // 再删最后一条引用 → fx2 也应消失
  await api('POST', '/api/admin/messages/purge', {
    token: admin, body: { conversationId: convB, q: 'keepmsg', allTime: 1, confirm: 2 },
  });
  ok('两条引用都删掉后 fx2 连行带磁盘消失',
    !withDb((d) => d.prepare('SELECT id FROM files WHERE id=?').get(fx2.id)) && !fs.existsSync(fx2Path));

  // ---- 悬空引用：收藏 + 置顶 ----
  const dmRes = (await api('GET', `/api/conversations/dm/${u1.id}`, { token: admin })).body;
  const dmCid = dmRes?.conversationId;
  ok('取到与 u1 的单聊会话', !!dmCid, JSON.stringify(dmRes));
  const favMsgIds = seedMessages(dmCid, u1.id, 2, 'favtarget-');
  await api('POST', '/api/favorites', { token: admin, body: { messageId: favMsgIds[0] } });
  await api('POST', '/api/favorites', { token: admin, body: { messageId: favMsgIds[1] } });
  let favRes = (await api('GET', '/api/favorites', { token: admin })).body;
  ok('收藏 2 条：列表长度与 total 一致', favRes.items.length === favRes.total && favRes.total === 2,
    JSON.stringify({ len: favRes.items.length, total: favRes.total }));

  await api('DELETE', `/api/admin/messages/${favMsgIds[1]}`, { token: admin });
  favRes = (await api('GET', '/api/favorites', { token: admin })).body;
  ok('单条删消息后收藏行被清：total 与列表长度仍相等（不再数字虚高）',
    favRes.total === 1 && favRes.items.length === 1,
    JSON.stringify({ len: favRes.items.length, total: favRes.total }));
  ok('  且 favorites 表里确实没有指向已删消息的行',
    withDb((d) => d.prepare('SELECT COUNT(*) n FROM favorites WHERE message_id=?').get(favMsgIds[1]).n) === 0);

  // 批量删路径也要清（走的是另一段 SQL：IN (子查询)）
  r = await api('POST', '/api/admin/messages/purge', {
    token: admin, body: { conversationId: dmCid, q: 'favtarget', allTime: 1, confirm: 1 },
  });
  ok('批量删掉剩下那条被收藏的消息', r.status === 200 && r.body?.deleted === 1, JSON.stringify(r.body));
  favRes = (await api('GET', '/api/favorites', { token: admin })).body;
  ok('批量删路径也会清收藏：收藏总数归零',
    favRes.total === 0 && favRes.items.length === 0,
    JSON.stringify({ len: favRes.items.length, total: favRes.total }));

  // 置顶：在群里置顶一条然后删掉它
  const pinIds = seedMessages(convA, u1.id, 1, 'pintarget-');
  r = await api('POST', `/api/conversations/${convA}/pin`, { token: admin, body: { messageId: pinIds[0] } });
  ok('置顶一条消息', r.status === 200, JSON.stringify(r.body));
  const pinnedBefore = withDb((d) => d.prepare('SELECT pinned_message_id p FROM conversations WHERE id=?').get(convA).p);
  ok('  conversations.pinned_message_id 已写入', pinnedBefore === pinIds[0], String(pinnedBefore));

  await api('DELETE', `/api/admin/messages/${pinIds[0]}`, { token: admin });
  const pinnedAfter = withDb((d) => d.prepare('SELECT pinned_message_id p FROM conversations WHERE id=?').get(convA).p);
  ok('删掉被置顶的消息后 pinned_message_id 变 NULL（不留悬空 id）',
    pinnedAfter === null, JSON.stringify(pinnedAfter));

  // ---------------- 五：文件页（分页 / 存储分析 / 孤儿巡检 / 批量清理） ----------------
  console.log('\n【五】文件管理');
  // 上一节把 fx1/fx2 都级联删掉了，files 表已空 —— 这里补一个样本文件，
  // 否则分页/筛选用例会在空表上跑出"看起来通过"的结果
  await upload('sample.png', 'z'.repeat(300), 'image/png');

  r = await api('GET', '/api/admin/files?page=1&pageSize=1&allTime=1', { token: admin });
  ok('文件列表分页：pageSize=1 只回 1 条且带 total',
    r.body?.items?.length === 1 && r.body.total >= 1,
    JSON.stringify({ n: r.body?.items?.length, total: r.body?.total }));
  r = await api('GET', '/api/admin/files?pageSize=999999&allTime=1', { token: admin });
  ok('pageSize=999999 被截断到 200 且不报错', r.status === 200 && r.body?.pageSize === 200,
    JSON.stringify({ status: r.status, pageSize: r.body?.pageSize }));

  r = await api('GET', '/api/admin/files/storage', { token: admin });
  const st = r.body;
  ok('存储分析：总量/按类型/按上传者三段齐全',
    typeof st?.totalBytes === 'number' && Array.isArray(st.byType) && Array.isArray(st.byOwner),
    JSON.stringify({ keys: st && Object.keys(st) }));
  ok('  按类型降序', (st.byType || []).every((x, i, a) => i === 0 || a[i - 1].bytes >= x.bytes),
    JSON.stringify((st.byType || []).map((x) => x.bytes)));
  r = await api('GET', '/api/admin/files?mime=image&allTime=1', { token: admin });
  ok('按类型前缀筛选（mime=image）', r.body?.total >= 1, JSON.stringify(r.body?.total));

  // 造孤儿：dbOnly（库里有、磁盘没有）+ diskOnly（磁盘有、库里没有）
  const dbOnlyId = withDb((d) => Number(d.prepare(
    `INSERT INTO files (owner_id,name,mime,size,path,created_at) VALUES (?,?,?,?,?,?)`)
    .run(adminId, 'ghost.png', 'image/png', 999, 'ghost-not-on-disk.png', Date.now()).lastInsertRowid));
  fs.writeFileSync(path.join(FILES_DIR, 'orphan-on-disk.bin'), Buffer.alloc(512, 1));

  r = await api('GET', '/api/admin/files/orphans', { token: admin });
  const orph = r.body;
  ok('孤儿巡检：dbOnly 识别出 ghost.png',
    (orph?.dbOnly || []).some((x) => x.id === dbOnlyId), JSON.stringify(orph?.dbOnly?.map((x) => x.name)));
  ok('孤儿巡检：diskOnly 识别出 orphan-on-disk.bin',
    (orph?.diskOnly || []).some((x) => x.path === 'orphan-on-disk.bin'),
    JSON.stringify(orph?.diskOnly?.map((x) => x.path)));
  ok('  counts 与数组长度一致', orph?.counts?.dbOnly === orph?.dbOnly?.length
    && orph?.counts?.diskOnly === orph?.diskOnly?.length, JSON.stringify(orph?.counts));

  r = await api('GET', '/api/admin/files/purge-preview?orphanOnly=1', { token: admin });
  const orphanN = r.body?.count;
  ok('文件清理 preview（orphanOnly）只算不删', orphanN >= 1 && r.body?.orphanOnly === true, JSON.stringify(r.body));
  ok('  preview 后磁盘孤儿仍在', fs.existsSync(path.join(FILES_DIR, 'orphan-on-disk.bin')));

  r = await api('POST', '/api/admin/files/purge', { token: admin, body: { orphanOnly: 1, confirm: orphanN + 1 } });
  ok('文件清理 confirm 不符 → 409', r.status === 409, JSON.stringify(r.body));
  r = await api('POST', '/api/admin/files/purge', { token: admin, body: { orphanOnly: 1, confirm: orphanN } });
  ok('  确认一致 → 清掉残留', r.status === 200 && r.body?.deleted === orphanN, JSON.stringify(r.body));
  ok('  磁盘残留文件确实被删', !fs.existsSync(path.join(FILES_DIR, 'orphan-on-disk.bin')));
  ok('  但 dbOnly（库里有盘上没）不受影响',
    !!withDb((d) => d.prepare('SELECT id FROM files WHERE id=?').get(dbOnlyId)));

  // ---------------- 六：options 接口与服务端搜索 ----------------
  console.log('\n【六】options 接口 / 服务端搜索');
  // 造 60 个用户，验证「第 51 个人」不会因为分页而消失
  withDb((d) => {
    const ins = d.prepare('INSERT INTO users (username,password_hash,nickname,role,created_at) VALUES (?,?,?,?,?)');
    d.exec('BEGIN');
    for (let i = 1; i <= 60; i++) {
      ins.run('bulk' + String(i).padStart(2, '0'), '!', '批量用户' + String(i).padStart(2, '0'), 'user', Date.now());
    }
    d.exec('COMMIT');
  });

  r = await api('GET', '/api/admin/users/options', { token: admin });
  ok('/users/options 返回全部用户（不分页）', r.body?.length >= 63, String(r.body?.length));
  ok('  含第 51 个之后的用户（bulk60）', r.body.some((u) => u.username === 'bulk60'));
  r = await api('GET', '/api/admin/users?pageSize=50', { token: admin });
  ok('/admin/users 已分页：只回 50 条但有 total', r.body?.items?.length === 50 && r.body.total >= 63,
    JSON.stringify({ n: r.body?.items?.length, total: r.body?.total }));
  r = await api('GET', '/api/admin/users?q=bulk60', { token: admin });
  ok('服务端搜索能命中第 51 个之后的用户（前端过滤做不到）',
    r.body?.total === 1 && r.body.items[0].username === 'bulk60', JSON.stringify(r.body));

  // 造 101 个会话，锁住原来 conversationOptions 的 LIMIT 100 截断
  const seedConvs = withDb((d) => {
    const insC = d.prepare('INSERT INTO conversations (type,created_at) VALUES (?,?)');
    const insM = d.prepare('INSERT INTO conversation_members (conversation_id,user_id) VALUES (?,?)');
    const insG = d.prepare('INSERT INTO groups (name,owner_id,conversation_id,created_at) VALUES (?,?,?,?)');
    const ids = [];
    d.exec('BEGIN');
    for (let i = 1; i <= 101; i++) {
      const cid = Number(insC.run('group', Date.now()).lastInsertRowid);
      insM.run(cid, adminId);
      insG.run('批量群' + String(i).padStart(3, '0'), adminId, cid, Date.now());
      ids.push(cid);
    }
    d.exec('COMMIT');
    return ids;
  });
  r = await api('GET', '/api/admin/conversations/options', { token: admin });
  ok('/conversations/options 返回全部 101 个批量群（锁住 LIMIT 100 截断）',
    (r.body || []).filter((c) => /^批量群/.test(c.name)).length === 101,
    String((r.body || []).filter((c) => /^批量群/.test(c.name)).length));
  ok('  且第 101 个也能选到', (r.body || []).some((c) => c.name === '批量群101'));

  r = await api('GET', '/api/admin/groups?pageSize=10', { token: admin });
  ok('/admin/groups 已分页（原来无 LIMIT 全量返回）',
    r.body?.items?.length === 10 && r.body.total >= 103, JSON.stringify({ n: r.body?.items?.length, total: r.body?.total }));

  r = await api('GET', '/api/admin/friendships?pageSize=5', { token: admin });
  ok('/admin/friendships 已分页', Array.isArray(r.body?.items) && typeof r.body?.total === 'number',
    JSON.stringify({ keys: r.body && Object.keys(r.body) }));

  // ---------------- 七：大批量护栏（放最后，避免污染上面的 total） ----------------
  console.log('\n【七】大批量护栏（20000 上限）');
  const convBig = seedConvs[0];
  const bigIds = seedMessages(convBig, u1.id, 20001, 'big-');
  ok('造 20001 条用于触发上限', bigIds.length === 20001, String(bigIds.length));

  r = await api('GET', `/api/admin/messages?conversationId=${convBig}&allTime=1&pageSize=999999`, { token: admin });
  ok('pageSize 截断到 200（items 只回 200，total 仍是 20001）',
    r.body?.items?.length === 200 && r.body?.total === 20001,
    JSON.stringify({ n: r.body?.items?.length, total: r.body?.total }));

  r = await api('GET', `/api/admin/messages/purge-preview?conversationId=${convBig}&allTime=1`, { token: admin });
  ok('preview 标出 tooMany（防止一次删掉整库）',
    r.body?.count === 20001 && r.body?.tooMany === true, JSON.stringify(r.body));

  r = await api('POST', '/api/admin/messages/purge', {
    token: admin, body: { conversationId: convBig, allTime: 1, confirm: 20001 },
  });
  ok('命中数超 20000 → 400 拒绝', r.status === 400, JSON.stringify(r.body));
  r = await api('GET', `/api/admin/messages?conversationId=${convBig}&allTime=1&pageSize=1`, { token: admin });
  ok('  拒绝后一条没删', r.body?.total === 20001, JSON.stringify(r.body?.total));

  // 收窄条件（按时间）后能删，验证"收窄后可行"这条路是通的
  const recent = await api('GET', `/api/admin/messages?conversationId=${convBig}&allTime=1&pageSize=1`, { token: admin });
  const newestAt = recent.body.items[0].created_at;
  r = await api('GET', `/api/admin/messages/purge-preview?conversationId=${convBig}&from=${newestAt}&allTime=1`, { token: admin });
  const narrow = r.body?.count;
  ok('按时间收窄后命中数下降', narrow > 0 && narrow <= 20001, String(narrow));
  if (narrow > 0 && narrow <= 20000) {
    r = await api('POST', '/api/admin/messages/purge', {
      token: admin, body: { conversationId: convBig, from: newestAt, confirm: narrow },
    });
    ok('  收窄后可以正常批量清理', r.status === 200 && r.body?.deleted === narrow, JSON.stringify(r.body));
  }

  // ---------------- 汇总 ----------------
  console.log('\n' + '='.repeat(52));
  console.log(`通过 ${passed} / ${passed + failed}`);
  if (failed) {
    console.log('\n失败项：');
    failures.forEach((f) => console.log('  ✗ ' + f));
  }
  console.log('='.repeat(52));
  stopServer();
  process.exit(failed ? 1 : 0);
})().catch((e) => {
  console.error('\n[E2E] 异常中断:', e);
  stopServer();
  process.exit(1);
});
