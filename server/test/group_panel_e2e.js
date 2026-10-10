// 群功能面板（群文件 / 群相册 / 群视频 / 群课堂）+ 管理员进群 —— 端到端测试
//
//   node test/group_panel_e2e.js
//
// 起一个隔离实例（独立 DATA_DIR + 端口），跑真实 HTTP。
//
// 【为什么前三样不建表这件事值得专门测】
// 群文件/相册/视频是从**消息流聚合**出来的，不复制数据。这带来一条必须钉住
// 的性质：消息被撤回后，它必须**同时从群文件里消失**。复制一份到"群文件表"
// 的实现过不了这条断言 —— 那里的文件会永远留着，包括被撤回的。

const { spawn } = require('child_process');
const path = require('path');
const fs = require('fs');
const os = require('os');

const PORT = 3731;
const BASE = `http://127.0.0.1:${PORT}`;
const SERVER_DIR = path.resolve(__dirname, '..');
const DATA_DIR = path.join(os.tmpdir(), 'xiaozhi-group-panel-e2e-' + Date.now());

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

/** 上传一个文件，返回 files 表里的 id（发文件消息要用） */
async function upload(token, filename, mime, content) {
  const fd = new FormData();
  fd.append('file', new Blob([content], { type: mime }), filename);
  const res = await fetch(BASE + '/api/files/upload', {
    method: 'POST',
    headers: { Authorization: 'Bearer ' + token },
    body: fd,
  });
  return { status: res.status, body: await res.json().catch(() => null) };
}

let serverProc = null;
let serverLog = '';

async function startServer() {
  serverProc = spawn(process.execPath, [path.join(SERVER_DIR, 'src', 'index.js')], {
    env: { ...process.env, PORT: String(PORT), DATA_DIR, ADMIN_PASSWORD: 'TestAdmin_123' },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  serverProc.stdout.on('data', (d) => { serverLog += d.toString(); });
  serverProc.stderr.on('data', (d) => { serverLog += d.toString(); });
  for (let i = 0; i < 60; i++) {
    try { const r = await fetch(BASE + '/api/health'); if (r.ok) return; } catch { /* 还没起来 */ }
    await sleep(250);
  }
  throw new Error('服务端启动超时\n' + serverLog);
}

function stopServer() {
  if (serverProc) { try { serverProc.kill(); } catch { /* ignore */ } }
  try { fs.rmSync(DATA_DIR, { recursive: true, force: true }); } catch { /* ignore */ }
}

// ------------------------------------------------------------------ 主流程

(async () => {
  await startServer();
  console.log('[群功能面板 E2E] 服务端已就绪 ' + BASE + '\n');

  const reg = async (u) => {
    const r = await api('POST', '/api/auth/register', { body: { username: u, password: 'pw123456', nickname: u } });
    if (!r.body?.token) throw new Error(`注册 ${u} 失败: ${JSON.stringify(r)}`);
    return r.body;
  };
  const A = await reg('alice');
  const B = await reg('bob');
  const ta = A.token, tb = B.token;
  const aId = A.user.id, bId = B.user.id;

  // 系统管理员（首次启动播种的 admin 账号）
  const lg = await api('POST', '/api/auth/login', { body: { username: 'admin', password: 'TestAdmin_123' } });
  const tAdmin = lg.body?.token;
  ok('管理员登录成功', !!tAdmin, JSON.stringify(lg.body).slice(0, 160));

  // ---------------- 一：建群并发内容 ----------------
  console.log('\n【一】建群 + 发图片/文件/视频');
  let r = await api('POST', '/api/groups', { token: ta, body: { name: '面板群' } });
  const gid = r.body?.groupId, cid = r.body?.conversationId;
  ok('建群 → 200', r.status === 200 && Number.isInteger(gid), JSON.stringify(r.body));
  await api('POST', `/api/groups/${gid}/members`, { token: ta, body: { userId: bId } });

  // 图片消息也要挂真文件（服务端会校验"image 消息缺少文件"），
  // 所以先传一张再发 —— 不然后面群相册一条都没有，测不出来
  const pic = await upload(ta, 'pic.png', 'image/png', 'PNGDATA');
  ok('上传一张图片 → 200', pic.status === 200 && Number.isInteger(pic.body?.id), JSON.stringify(pic.body));
  r = await api('POST', `/api/conversations/${cid}/messages`,
    { token: ta, body: { kind: 'image', fileId: pic.body.id } });
  ok('发一张图片 → 200', r.status === 200, JSON.stringify(r.body).slice(0, 160));

  const doc = await upload(ta, '盘点表.txt', 'text/plain', 'hello');
  ok('上传一个文件 → 200', doc.status === 200 && Number.isInteger(doc.body?.id), JSON.stringify(doc.body));
  r = await api('POST', `/api/conversations/${cid}/messages`,
    { token: ta, body: { kind: 'file', fileId: doc.body.id, content: '盘点表.txt' } });
  const docMsgId = r.body?.id;
  ok('发文件消息 → 200', r.status === 200, JSON.stringify(r.body).slice(0, 160));

  const vid = await upload(ta, '培训.mp4', 'video/mp4', '0123456789');
  r = await api('POST', `/api/conversations/${cid}/messages`,
    { token: ta, body: { kind: 'file', fileId: vid.body.id, content: '培训.mp4' } });
  ok('发视频文件 → 200', r.status === 200, JSON.stringify(r.body).slice(0, 160));

  // ---------------- 二：三个面板各归各位 ----------------
  console.log('\n【二】群文件 / 群相册 / 群视频');
  r = await api('GET', `/api/groups/${gid}/files`, { token: ta });
  ok('群文件有 2 条（文件 + 视频）', r.body?.total === 2, JSON.stringify(r.body?.items?.map((x) => x.name)));
  ok('  群文件里不含图片', !(r.body?.items || []).some((x) => x.kind === 'image'),
    JSON.stringify(r.body?.items?.map((x) => x.kind)));
  ok('  带上传者与访问地址', !!r.body?.items?.[0]?.sender?.name && !!r.body?.items?.[0]?.url,
    JSON.stringify(r.body?.items?.[0]).slice(0, 200));
  ok('  不外泄磁盘路径（url 是 /files/ 开头，不带目录）',
    (r.body?.items || []).every((x) => !x.url || x.url.startsWith('/files/')),
    JSON.stringify(r.body?.items?.map((x) => x.url)));

  r = await api('GET', `/api/groups/${gid}/albums`, { token: ta });
  ok('群相册只有那 1 张图', r.body?.total === 1 && r.body?.items?.[0]?.kind === 'image',
    JSON.stringify(r.body?.items?.map((x) => x.kind)));

  r = await api('GET', `/api/groups/${gid}/videos`, { token: ta });
  ok('群视频只有 mp4 那条（按 mime 前缀筛）',
    r.body?.total === 1 && r.body?.items?.[0]?.name === '培训.mp4',
    JSON.stringify(r.body?.items?.map((x) => x.name)));

  // 🔴 撤回后必须从群文件里一起消失 —— 聚合实现的核心性质
  r = await api('POST', `/api/conversations/${cid}/messages/${docMsgId}/recall`, { token: ta });
  ok('撤回那条文件消息 → 200', r.status === 200, JSON.stringify(r.body).slice(0, 120));
  r = await api('GET', `/api/groups/${gid}/files`, { token: ta });
  ok('撤回后群文件只剩 1 条（没复制数据，天然跟着撤回走）',
    r.body?.total === 1 && !r.body.items.some((x) => x.name === '盘点表.txt'),
    JSON.stringify(r.body?.items?.map((x) => x.name)));

  // 成员可见、非成员 403
  r = await api('GET', `/api/groups/${gid}/files`, { token: tb });
  ok('群成员也能看群文件', r.status === 200, JSON.stringify(r.body).slice(0, 120));
  r = await api('GET', `/api/groups/${gid}/files`, { token: tAdmin });
  ok('不在群里 → 403', r.status === 403, JSON.stringify(r.body));
  r = await api('GET', `/api/groups/${gid}/albums`);
  ok('未登录 → 401', r.status === 401, JSON.stringify(r.body));

  // ---------------- 三：群课堂 ----------------
  console.log('\n【三】群课堂（复用培训中心课程）');
  r = await api('POST', '/api/training/admin/courses', {
    token: tAdmin, body: { title: '生鲜陈列', intro: '群课堂测试课', category: '生鲜陈列', published: true },
  });
  const courseId = r.body?.id;
  ok('管理员建一门课 → 200', r.status === 200 && Number.isInteger(courseId), JSON.stringify(r.body).slice(0, 160));

  r = await api('POST', `/api/groups/${gid}/courses`, { token: ta, body: { courseId } });
  ok('群主挂课程 → 200', r.status === 200, JSON.stringify(r.body));
  r = await api('POST', `/api/groups/${gid}/courses`, { token: ta, body: { courseId } });
  ok('  重复挂幂等（不算错）', r.status === 200 && r.body?.duplicated === true, JSON.stringify(r.body));

  r = await api('GET', `/api/groups/${gid}/courses`, { token: ta });
  ok('群课堂列表有这门课', r.body?.items?.length === 1 && r.body.items[0].id === courseId,
    JSON.stringify(r.body?.items).slice(0, 200));
  ok('  即使没课时也回 progressPct=0（不省字段）',
    r.body?.items?.[0]?.progressPct === 0, JSON.stringify(r.body?.items?.[0]));
  ok('  群主看到 canManage=true', r.body?.canManage === true, JSON.stringify(r.body?.canManage));

  r = await api('GET', `/api/groups/${gid}/courses`, { token: tb });
  ok('  普通成员 canManage=false', r.body?.canManage === false, JSON.stringify(r.body?.canManage));
  r = await api('POST', `/api/groups/${gid}/courses`, { token: tb, body: { courseId } });
  ok('  普通成员挂课程 → 403', r.status === 403, JSON.stringify(r.body));
  r = await api('POST', `/api/groups/${gid}/courses`, { token: ta, body: { courseId: 99999 } });
  ok('  挂不存在的课 → 404', r.status === 404, JSON.stringify(r.body));
  r = await api('POST', `/api/groups/${gid}/courses`, { token: ta, body: { courseId: 'abc' } });
  ok('  课程 id 非法 → 400', r.status === 400, JSON.stringify(r.body));

  // ---------------- 四：管理员可进所有群 ----------------
  console.log('\n【四】系统管理员进入并加入任意群');
  r = await api('GET', '/api/groups/all', { token: tAdmin });
  ok('管理员能看到全部群', r.status === 200 && r.body?.items?.length === 1, JSON.stringify(r.body?.items).slice(0, 200));
  ok('  还没进群时 joined=false', r.body?.items?.[0]?.joined === false, JSON.stringify(r.body?.items?.[0]));
  ok('  带群主名与人数', r.body?.items?.[0]?.owner_name === 'alice' && r.body?.items?.[0]?.members === 2,
    JSON.stringify(r.body?.items?.[0]));

  r = await api('GET', '/api/groups/all', { token: ta });
  ok('普通用户看全部群 → 403', r.status === 403, JSON.stringify(r.body));
  r = await api('POST', `/api/groups/${gid}/join`, { token: ta });
  ok('普通用户直接进群 → 403', r.status === 403, JSON.stringify(r.body));

  r = await api('POST', `/api/groups/${gid}/join`, { token: tAdmin });
  ok('管理员进群 → 200', r.status === 200, JSON.stringify(r.body));
  r = await api('GET', '/api/groups/all', { token: tAdmin });
  ok('  进群后 joined=true', r.body?.items?.[0]?.joined === true, JSON.stringify(r.body?.items?.[0]));
  ok('  人数变成 3', r.body?.items?.[0]?.members === 3, JSON.stringify(r.body?.items?.[0]?.members));

  // 关键：进群后必须**能正常收发**，不是"进得去、发不出"的半残状态
  r = await api('GET', `/api/groups/${gid}/files`, { token: tAdmin });
  ok('  管理员进群后能读群文件（不再是 403）', r.status === 200, JSON.stringify(r.body).slice(0, 120));
  r = await api('POST', `/api/conversations/${cid}/messages`,
    { token: tAdmin, body: { kind: 'text', content: '管理员来了' } });
  ok('  管理员进群后能发消息', r.status === 200, JSON.stringify(r.body).slice(0, 160));
  r = await api('GET', '/api/conversations', { token: tAdmin });
  ok('  会话列表里出现这个群', (r.body || []).some((c) => c.id === cid), JSON.stringify((r.body || []).map((c) => c.id)));

  // 🔴 管理员是以 member 角色进群的，但必须**有管理权**：
  //    否则就是"进得去、管不了"，比进不去更让人困惑
  r = await api('GET', `/api/groups/${gid}/courses`, { token: tAdmin });
  ok('  管理员在群里 canManage=true（不是只看群内角色）',
    r.body?.canManage === true, JSON.stringify(r.body?.canManage));
  r = await api('POST', `/api/groups/${gid}/courses`, { token: tAdmin, body: { courseId } });
  ok('  管理员能挂课程', r.status === 200, JSON.stringify(r.body));
  await api('DELETE', `/api/groups/${gid}/courses/${courseId}`, { token: tAdmin });
  // 但**不能**把群主转走 —— isOwner 不跟着升
  r = await api('POST', `/api/groups/${gid}/transfer`, { token: tAdmin, body: { userId: bId } });
  ok('  管理员不能转让别人的群（isOwner 不跟着升）', r.status === 403, JSON.stringify(r.body));

  r = await api('POST', `/api/groups/${gid}/join`, { token: tAdmin });
  ok('  重复进群不报错（幂等）', r.status === 200, JSON.stringify(r.body));
  r = await api('GET', '/api/groups/all', { token: tAdmin });
  ok('  重复进群不会变成 4 人', r.body?.items?.[0]?.members === 3, JSON.stringify(r.body?.items?.[0]?.members));

  // ---------------- 五：摘课程 ----------------
  console.log('\n【五】摘掉群课程');
  r = await api('DELETE', `/api/groups/${gid}/courses/${courseId}`, { token: tb });
  ok('普通成员摘课程 → 403', r.status === 403, JSON.stringify(r.body));
  r = await api('DELETE', `/api/groups/${gid}/courses/${courseId}`, { token: ta });
  ok('群主摘课程 → 200', r.status === 200, JSON.stringify(r.body));
  r = await api('GET', `/api/groups/${gid}/courses`, { token: ta });
  ok('  群课堂已空', r.body?.items?.length === 0, JSON.stringify(r.body?.items));
  r = await api('GET', '/api/training/courses', { token: ta });
  ok('  只解关联，课程本身还在培训中心',
    (r.body?.items || []).some((c) => c.id === courseId), JSON.stringify(r.body?.items?.map((c) => c.id)));

  // ---------------- 结果 ----------------
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
  console.error(serverLog.slice(-2000));
  stopServer();
  process.exit(1);
});
