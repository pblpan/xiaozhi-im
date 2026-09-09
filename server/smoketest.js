const BASE = 'http://localhost:3602';
const sleep = (ms) => new Promise(r => setTimeout(r, ms));

async function j(method, path, { token, body } = {}) {
  const headers = { 'Content-Type': 'application/json' };
  if (token) headers.Authorization = `Bearer ${token}`;
  const res = await fetch(BASE + path, { method, headers, body: body ? JSON.stringify(body) : undefined });
  const text = await res.text();
  let data; try { data = JSON.parse(text); } catch { data = text; }
  return { status: res.status, data };
}

function assert(cond, msg) { if (!cond) { console.error('❌ FAIL:', msg); process.exitCode = 1; } else console.log('✅', msg); }

(async () => {
  // 1. 注册两个普通用户
  const a = await j('POST', '/api/auth/register', { body: { username: 'alice', password: 'pw12345', nickname: '爱丽丝' } });
  const b = await j('POST', '/api/auth/register', { body: { username: 'bob', password: 'pw12345', nickname: '鲍勃' } });
  assert(a.status === 200 && a.data.token, '注册 alice 成功并拿到 token');
  assert(b.status === 200 && b.data.token, '注册 bob 成功并拿到 token');
  const tA = a.data.token, tB = b.data.token, uidA = a.data.user.id, uidB = b.data.user.id;

  // 2. 管理员登录
  const admin = await j('POST', '/api/auth/login', { body: { username: 'admin', password: 'admin123' } });
  assert(admin.status === 200 && admin.data.token, '管理员登录成功');
  const tAdmin = admin.data.token;

  // 3. 搜索用户
  const search = await j('GET', '/api/users/search?q=bo', { token: tA });
  assert(search.data.some(u => u.username === 'bob'), 'alice 能搜索到 bob');

  // 4. 好友：发起 + 接受
  const req = await j('POST', '/api/friends/request', { token: tA, body: { friendId: uidB } });
  assert(req.status === 200, 'alice 向 bob 发起好友请求');
  const accept = await j('POST', '/api/friends/accept', { token: tB, body: { friendId: uidA } });
  assert(accept.status === 200, 'bob 接受好友请求');
  const friends = await j('GET', '/api/friends', { token: tA });
  assert(friends.data.friends.some(f => f.id === uidB), 'alice 好友列表含 bob');

  // 5. 单聊：建会话 + 发消息
  const dm = await j('GET', `/api/conversations/dm/${uidB}`, { token: tA });
  const cid = dm.data.conversationId;
  assert(cid > 0, `获得单聊会话 id=${cid}`);
  const msg = await j('POST', `/api/conversations/${cid}/messages`, { token: tA, body: { kind: 'text', content: '你好 bob！' } });
  assert(msg.status === 200 && msg.data.id, 'alice 发送文字消息成功');
  const hist = await j('GET', `/api/conversations/${cid}/messages`, { token: tB });
  assert(hist.data.length === 1 && hist.data[0].content === '你好 bob！', 'bob 能拉到该消息');

  // 6. 群聊：建群 + 拉人 + 发群消息
  const g = await j('POST', '/api/groups', { token: tA, body: { name: '门店群' } });
  assert(g.status === 200 && g.data.conversationId, `建群成功 convId=${g.data.conversationId}`);
  const addM = await j('POST', `/api/groups/${g.data.groupId}/members`, { token: tA, body: { userId: uidB } });
  assert(addM.status === 200, 'alice 把 bob 拉进群');
  const gmsg = await j('POST', `/api/conversations/${g.data.conversationId}/messages`, { token: tA, body: { kind: 'text', content: '群里早上好' } });
  assert(gmsg.status === 200, '群消息发送成功');
  const ghist = await j('GET', `/api/conversations/${g.data.conversationId}/messages`, { token: tB });
  assert(ghist.data.some(m => m.content === '群里早上好'), 'bob 能读到群消息');

  // 7. 管理后台统计
  const stats = await j('GET', '/api/admin/stats', { token: tAdmin });
  assert(stats.status === 200 && stats.data.users >= 3, `管理后台统计: users=${stats.data.users}, groups=${stats.data.groups}, messages=${stats.data.messages}`);
  const noAuth = await j('GET', '/api/admin/stats', { token: tA });
  assert(noAuth.status === 403, '普通用户访问管理后台被拒(403)');

  // 8. WebSocket 实时：bob 在线，alice 发消息应实时收到
  let received = null;
  const ws = new WebSocket(`${BASE.replace('http', 'ws')}/ws?token=${tB}`);
  ws.onmessage = (e) => { const f = JSON.parse(e.data); if (f.type === 'message:new') received = f.message; };
  await new Promise(r => ws.onopen = r);
  await sleep(200);
  await j('POST', `/api/conversations/${cid}/messages`, { token: tA, body: { kind: 'text', content: '实时测试' } });
  await sleep(500);
  assert(received && received.content === '实时测试', 'bob 经 WebSocket 实时收到 alice 新消息');
  ws.close();

  console.log('\n=== 冒烟测试完成 ===');
})().catch(e => { console.error('ERROR', e); process.exit(1); });
