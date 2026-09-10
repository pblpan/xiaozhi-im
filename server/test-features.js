/**
 * 小智IM 功能回归测试：撤回 / 编辑 / 已读回执 / 输入中状态
 * 用法：node test-features.js
 */
const { spawn } = require('child_process');
const path = require('path');
const fs = require('fs');
const os = require('os');
const WebSocket = require('ws');
const { DatabaseSync } = require('node:sqlite');

const PORT = 3801;
const BASE = `http://127.0.0.1:${PORT}`;
const DATA = path.join(os.tmpdir(), 'xz-features-test');
const DB_FILE = path.join(DATA, 't.db');

fs.rmSync(DATA, { recursive: true, force: true });
fs.mkdirSync(DATA, { recursive: true });

const env = {
  ...process.env,
  PORT: String(PORT),
  ADMIN_PASSWORD: 'test123',
  JWT_SECRET: 'testsecret',
  DB_PATH: DB_FILE,
  DATA_DIR: DATA,
  FILES_DIR: path.join(DATA, 'files'),
};

let pass = 0, fail = 0;
const ok = (name, cond, extra = '') => {
  if (cond) { pass++; console.log(`  \u2705 ${name}`); }
  else { fail++; console.log(`  \u274c ${name}${extra ? '  -> ' + extra : ''}`); }
};
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function api(p, { method = 'GET', token, body } = {}) {
  const r = await fetch(BASE + '/api' + p, {
    method,
    headers: {
      'Content-Type': 'application/json',
      ...(token ? { Authorization: 'Bearer ' + token } : {}),
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  const j = await r.json().catch(() => null);
  return { status: r.status, body: j };
}

function connectWs(token) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(`ws://127.0.0.1:${PORT}/ws?token=${token}`);
    const frames = [];
    ws.on('message', (d) => { try { frames.push(JSON.parse(d.toString())); } catch { /* ignore */ } });
    ws.on('open', () => resolve({ ws, frames }));
    ws.on('error', reject);
  });
}

async function waitFor(fn, timeout = 2500) {
  const t0 = Date.now();
  while (Date.now() - t0 < timeout) {
    if (fn()) return true;
    await sleep(30);
  }
  return false;
}

const find = (frames, type, pred = () => true) => frames.find((f) => f.type === type && pred(f));

(async () => {
  const srv = spawn(process.execPath, ['src/index.js'], {
    cwd: __dirname, env, stdio: ['ignore', 'pipe', 'pipe'],
  });
  srv.stdout.on('data', (d) => process.stdout.write('  [srv] ' + d));
  srv.stderr.on('data', (d) => {
    const s = d.toString();
    if (!s.includes('ExperimentalWarning') && !s.includes('trace-warnings')) {
      process.stderr.write('  [srv:err] ' + s);
    }
  });

  let exitCode = 0;
  try {
    // 等健康检查通过
    let up = false;
    for (let i = 0; i < 60; i++) {
      try { const r = await fetch(BASE + '/api/health'); if (r.status === 200) { up = true; break; } } catch { /* retry */ }
      await sleep(150);
    }
    if (!up) throw new Error('服务未启动');
    console.log('\n=== 准备：账号与会话 ===');

    const admin = (await api('/auth/login', { method: 'POST', body: { username: 'admin', password: 'test123' } })).body.token;
    const aliceId = (await api('/admin/users', { method: 'POST', token: admin, body: { username: 'alice', password: 'abc123', nickname: '爱丽丝' } })).body.id;
    const bobId = (await api('/admin/users', { method: 'POST', token: admin, body: { username: 'bob', password: 'abc123', nickname: '鲍勃' } })).body.id;
    ok('创建 alice / bob', !!aliceId && !!bobId, `alice=${aliceId} bob=${bobId}`);

    const alice = (await api('/auth/login', { method: 'POST', body: { username: 'alice', password: 'abc123' } })).body.token;
    const bob = (await api('/auth/login', { method: 'POST', body: { username: 'bob', password: 'abc123' } })).body.token;
    ok('alice / bob 登录', !!alice && !!bob);

    const cid = (await api(`/conversations/dm/${bobId}`, { token: alice })).body.conversationId;
    ok('建立单聊会话', !!cid, `cid=${cid}`);

    const A = await connectWs(alice);
    const B = await connectWs(bob);
    ok('双端 WebSocket 连接', A.ws.readyState === 1 && B.ws.readyState === 1);

    // ---------- 1. 发消息 ----------
    console.log('\n=== 1. 发送消息 ===');
    const m1 = (await api(`/conversations/${cid}/messages`, {
      method: 'POST', token: alice, body: { kind: 'text', content: '第一条消息' },
    })).body;
    ok('alice 发消息返回 id', !!m1.id, JSON.stringify(m1).slice(0, 80));
    await waitFor(() => find(B.frames, 'message:new', (f) => f.message.id === m1.id));
    ok('bob 实时收到 message:new', !!find(B.frames, 'message:new', (f) => f.message.id === m1.id));

    // ---------- 2. 输入中状态 ----------
    console.log('\n=== 2. 输入中状态 ===');
    B.ws.send(JSON.stringify({ type: 'typing', conversationId: cid }));
    await waitFor(() => find(A.frames, 'typing'));
    const tFrame = find(A.frames, 'typing');
    ok('alice 收到 typing 事件', !!tFrame);
    ok('typing 带 conversationId + userId', tFrame?.conversationId === cid && tFrame?.userId === bobId, JSON.stringify(tFrame));

    // ---------- 3. 已读回执 ----------
    console.log('\n=== 3. 已读回执 ===');
    const readRes = (await api(`/conversations/${cid}/read`, { method: 'POST', token: bob })).body;
    ok('bob 上报已读', readRes.lastReadId === m1.id, JSON.stringify(readRes));
    await waitFor(() => find(A.frames, 'message:read', (f) => f.lastReadId === m1.id));
    ok('alice 收到 message:read', !!find(A.frames, 'message:read', (f) => f.lastReadId === m1.id));

    const hist1 = (await api(`/conversations/${cid}/messages`, { token: alice })).body;
    ok('历史接口返回 peerLastReadId', hist1.peerLastReadId === m1.id, `peerLastReadId=${hist1.peerLastReadId}`);
    ok('历史接口返回 messages 数组', Array.isArray(hist1.messages) && hist1.messages.length === 1);
    ok('历史接口返回 recallWindowMs=120000', hist1.recallWindowMs === 120000);

    // ---------- 4. 编辑消息 ----------
    console.log('\n=== 4. 编辑消息 ===');
    const editRes = await api(`/conversations/${cid}/messages/${m1.id}`, {
      method: 'PATCH', token: alice, body: { content: '第一条消息（已改）' },
    });
    ok('alice 编辑自己的消息', editRes.status === 200, JSON.stringify(editRes.body));
    await waitFor(() => find(B.frames, 'message:edit', (f) => f.messageId === m1.id));
    ok('bob 实时收到 message:edit', !!find(B.frames, 'message:edit', (f) => f.messageId === m1.id));

    const badEdit = await api(`/conversations/${cid}/messages/${m1.id}`, {
      method: 'PATCH', token: bob, body: { content: '我要改别人的' },
    });
    ok('bob 编辑 alice 的消息被拒', badEdit.status === 400, JSON.stringify(badEdit.body));

    const emptyEdit = await api(`/conversations/${cid}/messages/${m1.id}`, {
      method: 'PATCH', token: alice, body: { content: '   ' },
    });
    ok('编辑为空内容被拒', emptyEdit.status === 400, JSON.stringify(emptyEdit.body));

    const hist2 = (await api(`/conversations/${cid}/messages`, { token: alice })).body;
    ok('编辑后内容与 edited 标记落库',
      hist2.messages[0].content === '第一条消息（已改）' && hist2.messages[0].edited === 1,
      JSON.stringify(hist2.messages[0]));

    // ---------- 5. 撤回超时保护 ----------
    console.log('\n=== 5. 撤回时限 ===');
    const mOld = (await api(`/conversations/${cid}/messages`, {
      method: 'POST', token: alice, body: { kind: 'text', content: '一条老消息' },
    })).body;
    // 直接把创建时间改到 5 分钟前，模拟超时
    const raw = new DatabaseSync(DB_FILE);
    raw.prepare('UPDATE messages SET created_at = ? WHERE id = ?').run(Date.now() - 5 * 60 * 1000, mOld.id);
    raw.close();
    const lateRecall = await api(`/conversations/${cid}/messages/${mOld.id}/recall`, { method: 'POST', token: alice });
    ok('超过 2 分钟撤回被拒', lateRecall.status === 400, JSON.stringify(lateRecall.body));

    // ---------- 6. 撤回消息 ----------
    console.log('\n=== 6. 撤回消息 ===');
    const m2 = (await api(`/conversations/${cid}/messages`, {
      method: 'POST', token: alice, body: { kind: 'text', content: '这条要撤回' },
    })).body;
    await waitFor(() => find(B.frames, 'message:new', (f) => f.message.id === m2.id));

    const badRecall = await api(`/conversations/${cid}/messages/${m2.id}/recall`, { method: 'POST', token: bob });
    ok('bob 撤回 alice 的消息被拒', badRecall.status === 400, JSON.stringify(badRecall.body));

    const rec = await api(`/conversations/${cid}/messages/${m2.id}/recall`, { method: 'POST', token: alice });
    ok('alice 撤回成功', rec.status === 200, JSON.stringify(rec.body));
    await waitFor(() => find(B.frames, 'message:recall', (f) => f.messageId === m2.id));
    ok('bob 实时收到 message:recall', !!find(B.frames, 'message:recall', (f) => f.messageId === m2.id));

    const hist3 = (await api(`/conversations/${cid}/messages`, { token: alice })).body;
    const recalled = hist3.messages.find((m) => m.id === m2.id);
    ok('撤回后 deleted=1 且 content 清空', recalled?.deleted === 1 && recalled?.content === null, JSON.stringify(recalled));

    const twice = await api(`/conversations/${cid}/messages/${m2.id}/recall`, { method: 'POST', token: alice });
    ok('重复撤回被拒', twice.status === 400, JSON.stringify(twice.body));

    // ---------- 7. 会话未读数 ----------
    console.log('\n=== 7. 会话未读数 ===');
    const convs = (await api('/conversations', { token: bob })).body;
    const dm = convs.find((c) => c.id === cid);
    // bob 已读到 m1，m2 已撤回，mOld 是 alice 后来发的 -> 未读 1
    ok('会话列表带 unread 字段', typeof dm?.unread === 'number', JSON.stringify(dm));
    ok('bob 未读数为 1（仅 mOld）', dm?.unread === 1, `unread=${dm?.unread}`);

    // ---------- 8. 群聊已读水位 ----------
    console.log('\n=== 8. 群聊已读水位 ===');
    const gCreated = (await api('/groups', { method: 'POST', token: alice, body: { name: '测试群' } })).body;
    const gid = gCreated.groupId;
    const addBob = await api(`/groups/${gid}/members`, { method: 'POST', token: alice, body: { userId: bobId } });
    ok('bob 入群成功', addBob.status === 200, JSON.stringify(addBob.body));
    const gconv = (await api('/conversations', { token: alice })).body.find((c) => c.title === '测试群');
    ok('群会话创建成功', !!gconv, `gid=${gid} conv=${gconv?.id}`);
    const gm = (await api(`/conversations/${gconv.id}/messages`, {
      method: 'POST', token: alice, body: { kind: 'text', content: '群消息' },
    })).body;
    const gBefore = (await api(`/conversations/${gconv.id}/messages`, { token: alice })).body;
    ok('群消息未被读时 minOtherReadId=0', gBefore.minOtherReadId === 0, `min=${gBefore.minOtherReadId}`);
    const gRead = await api(`/conversations/${gconv.id}/read`, { method: 'POST', token: bob });
    ok('bob 在群里上报已读成功', gRead.status === 200, JSON.stringify(gRead.body));
    const gAfter = (await api(`/conversations/${gconv.id}/messages`, { token: alice })).body;
    ok('群成员已读后 minOtherReadId 推进', gAfter.minOtherReadId === gm.id, `min=${gAfter.minOtherReadId}`);

    // ---------- 9. 语音消息 ----------
    console.log('\n=== 9. 语音消息 ===');
    async function uploadBlob(token, bytes, name, mime) {
      const fd = new FormData();
      fd.append('file', new Blob([bytes], { type: mime }), name);
      const r = await fetch(BASE + '/api/files/upload', {
        method: 'POST', headers: { Authorization: 'Bearer ' + token }, body: fd,
      });
      return { status: r.status, body: await r.json().catch(() => null) };
    }

    const upAudio = await uploadBlob(alice, new Uint8Array(2048).fill(7), 'voice.m4a', 'audio/mp4');
    ok('上传音频文件成功', upAudio.status === 200 && !!upAudio.body?.id, JSON.stringify(upAudio.body));

    const am = (await api(`/conversations/${cid}/messages`, {
      method: 'POST', token: alice,
      body: { kind: 'audio', content: '7', fileId: upAudio.body.id },
    })).body;
    ok('发送语音消息成功', am.kind === 'audio', JSON.stringify(am));
    ok('语音消息带 file_url', !!am.file_url, JSON.stringify(am));
    ok('语音时长保留 content=7', am.content === '7', `content=${am.content}`);
    await waitFor(() => find(B.frames, 'message:new', (f) => f.message.id === am.id));
    ok('bob 实时收到语音消息', !!find(B.frames, 'message:new', (f) => f.message.id === am.id));

    const aZero = (await api(`/conversations/${cid}/messages`, {
      method: 'POST', token: alice, body: { kind: 'audio', content: '0', fileId: upAudio.body.id },
    })).body;
    ok('时长 0 归一化为 1', aZero.content === '1', `content=${aZero.content}`);
    const aHuge = (await api(`/conversations/${cid}/messages`, {
      method: 'POST', token: alice, body: { kind: 'audio', content: '9999', fileId: upAudio.body.id },
    })).body;
    ok('超长时长截断为 600', aHuge.content === '600', `content=${aHuge.content}`);

    const aNoFile = await api(`/conversations/${cid}/messages`, {
      method: 'POST', token: alice, body: { kind: 'audio', content: '3' },
    });
    ok('语音缺文件被拒', aNoFile.status === 400, JSON.stringify(aNoFile.body));
    const badKind = await api(`/conversations/${cid}/messages`, {
      method: 'POST', token: alice, body: { kind: 'video', content: 'x' },
    });
    ok('非法消息类型被拒', badKind.status === 400, JSON.stringify(badKind.body));
    const emptyText = await api(`/conversations/${cid}/messages`, {
      method: 'POST', token: alice, body: { kind: 'text', content: '   ' },
    });
    ok('空白文字消息被拒', emptyText.status === 400, JSON.stringify(emptyText.body));

    const convsVoice = (await api('/conversations', { token: alice })).body;
    const dmVoice = convsVoice.find((c) => c.id === cid);
    ok('会话列表语音预览为 [语音]', dmVoice?.last_content === '[语音]', `last=${dmVoice?.last_content}`);

    // ---------- 10. 消息搜索 ----------
    console.log('\n=== 10. 消息搜索 ===');
    const q1 = await api('/conversations/search?q=' + encodeURIComponent('第一条'), { token: alice });
    ok('搜索命中文字消息', q1.status === 200 && q1.body.total >= 1, JSON.stringify(q1.body).slice(0, 160));
    ok('搜索结果带会话标题', !!q1.body.items?.[0]?.conv_title, JSON.stringify(q1.body.items?.[0]));
    ok('搜索结果带发送者名', !!q1.body.items?.[0]?.sender_name, JSON.stringify(q1.body.items?.[0]));

    const q2 = await api('/conversations/search?q=' + encodeURIComponent('群消息'), { token: alice });
    ok('跨会话搜索命中群消息', q2.body.items?.some((x) => x.conv_type === 'group'),
      JSON.stringify(q2.body.items?.map((x) => x.conv_title)));

    const q3 = await api('/conversations/search?q=' + encodeURIComponent('要撤回'), { token: alice });
    ok('已撤回消息不被搜到', q3.body.total === 0, `total=${q3.body.total}`);

    const q4 = await api('/conversations/search?q=' + encodeURIComponent('语音'), { token: alice });
    ok('非文字消息不参与搜索', q4.body.total === 0, `total=${q4.body.total}`);

    const q5 = await api('/conversations/search?q=' + encodeURIComponent('%'), { token: alice });
    ok('LIKE 通配符已转义（搜 % 不返回全部）', q5.body.total === 0, `total=${q5.body.total}`);

    const q6 = await api('/conversations/search?q=', { token: alice });
    ok('空关键词返回空结果', q6.body.total === 0 && q6.body.items.length === 0);

    const q7 = await api('/conversations/search?q=' + encodeURIComponent('消息') + '&limit=1', { token: alice });
    ok('limit 参数生效', q7.body.items.length <= 1, `n=${q7.body.items.length}`);

    const q8 = await api(`/conversations/search?q=${encodeURIComponent('消息')}&conversationId=${gconv.id}`, { token: alice });
    ok('conversationId 过滤生效', q8.body.items.every((x) => x.conversation_id === gconv.id),
      JSON.stringify(q8.body.items?.map((x) => x.conversation_id)));

    const q9 = await api('/conversations/search?q=' + encodeURIComponent('第一条'));
    ok('搜索未登录被拒', q9.status === 401);

    // ---------- 11. 越权保护 ----------
    console.log('\n=== 11. 越权保护 ===');
    const outsider = (await api('/admin/users', { method: 'POST', token: admin, body: { username: 'eve', password: 'abc123' } })).body.id;
    const eve = (await api('/auth/login', { method: 'POST', body: { username: 'eve', password: 'abc123' } })).body.token;
    const eveRead = await api(`/conversations/${cid}/read`, { method: 'POST', token: eve });
    ok('非成员上报已读被拒', eveRead.status === 403, JSON.stringify(eveRead.body));
    const eveRecall = await api(`/conversations/${cid}/messages/${m1.id}/recall`, { method: 'POST', token: eve });
    ok('非成员撤回被拒', eveRecall.status === 403, JSON.stringify(eveRecall.body));
    const noToken = await api(`/conversations/${cid}/messages`);
    ok('无 token 访问被拒', noToken.status === 401);
    const eveSearch = await api('/conversations/search?q=' + encodeURIComponent('第一条'), { token: eve });
    ok('非成员搜不到别人的消息', eveSearch.body.total === 0, `total=${eveSearch.body.total}`);
    ok('eve 创建成功（对照）', !!outsider && !!eve);

    A.ws.close(); B.ws.close();
    await sleep(200);
  } catch (e) {
    console.error('\n测试异常：', e);
    exitCode = 1;
  } finally {
    srv.kill();
    await sleep(300);
  }

  console.log(`\n${'='.repeat(46)}`);
  console.log(`  通过 ${pass} / 失败 ${fail}`);
  console.log(`${'='.repeat(46)}\n`);
  process.exit(fail > 0 || exitCode ? 1 : 0);
})();
