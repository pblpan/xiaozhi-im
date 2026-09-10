/**
 * 小智IM v0.3.0 功能回归测试：@提及 / 转发 / 收藏 / 置顶 / 群管理
 * 用法：node test-v030.js
 */
const { spawn } = require('child_process');
const path = require('path');
const fs = require('fs');
const os = require('os');
const WebSocket = require('ws');

const PORT = 3803;
const BASE = `http://127.0.0.1:${PORT}`;
const DATA = path.join(os.tmpdir(), 'xz-v030-test');
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
    let up = false;
    for (let i = 0; i < 60; i++) {
      try { const r = await fetch(BASE + '/api/health'); if (r.status === 200) { up = true; break; } } catch { /* retry */ }
      await sleep(150);
    }
    if (!up) throw new Error('服务未启动');

    console.log('\n=== 准备：账号 / 单聊 / 群 ===');
    const admin = (await api('/auth/login', { method: 'POST', body: { username: 'admin', password: 'test123' } })).body.token;
    const mk = async (u, n) => (await api('/admin/users', { method: 'POST', token: admin, body: { username: u, password: 'abc123', nickname: n } })).body.id;
    const aliceId = await mk('alice', '爱丽丝');
    const bobId = await mk('bob', '鲍勃');
    const carolId = await mk('carol', '卡罗尔');
    const daveId = await mk('dave', '戴夫');
    ok('创建 4 个账号', !!(aliceId && bobId && carolId && daveId));

    const login = async (u) => (await api('/auth/login', { method: 'POST', body: { username: u, password: 'abc123' } })).body.token;
    const alice = await login('alice');
    const bob = await login('bob');
    const carol = await login('carol');
    ok('三方登录', !!(alice && bob && carol));

    const cid = (await api(`/conversations/dm/${bobId}`, { token: alice })).body.conversationId;
    const g = (await api('/groups', { method: 'POST', token: alice, body: { name: '测试群' } })).body;
    const gid = g.groupId, gcid = g.conversationId;
    ok('单聊 + 群建立', !!cid && !!gid, `cid=${cid} gid=${gid} gcid=${gcid}`);

    await api(`/groups/${gid}/members`, { method: 'POST', token: alice, body: { userId: bobId } });
    await api(`/groups/${gid}/members`, { method: 'POST', token: alice, body: { userId: carolId } });
    const gm = (await api(`/groups/${gid}`, { token: alice })).body;
    ok('拉 bob / carol 入群', gm.members.length === 3, `members=${gm.members.length}`);

    const A = await connectWs(alice);
    const B = await connectWs(bob);

    // ---------- 1. @提及 ----------
    console.log('\n=== 1. @提及 ===');
    const mBob = (await api(`/conversations/${gcid}/messages`, {
      method: 'POST', token: alice, body: { kind: 'text', content: '你好 @鲍勃', mentions: [bobId] },
    })).body;
    ok('@某人：mentions 落库为该成员 id',
      Array.isArray(mBob.mentions) && mBob.mentions.includes(bobId), JSON.stringify(mBob.mentions));

    await waitFor(() => find(B.frames, 'message:new', (f) => f.message.id === mBob.id));
    const bFrame = find(B.frames, 'message:new', (f) => f.message.id === mBob.id);
    ok('WebSocket 实时帧透传 mentions', !!bFrame && Array.isArray(bFrame.message.mentions));

    const bobConvs = (await api('/conversations', { token: bob })).body;
    const bobGroup = bobConvs.find((c) => c.id === gcid);
    ok('被 @ 的人会话列表 has_mention=true', bobGroup?.has_mention === true);

    const carolConvs = (await api('/conversations', { token: carol })).body;
    const carolGroup = carolConvs.find((c) => c.id === gcid);
    ok('未被 @ 的人 has_mention=false', carolGroup?.has_mention === false);

    const mAll = (await api(`/conversations/${gcid}/messages`, {
      method: 'POST', token: alice, body: { kind: 'text', content: '@所有人 通知', mentions: ['all'] },
    })).body;
    ok('@所有人 记为 -1', Array.isArray(mAll.mentions) && mAll.mentions.includes(-1), JSON.stringify(mAll.mentions));

    const carolConvs2 = (await api('/conversations', { token: carol })).body;
    ok('@所有人 让其他成员 has_mention=true',
      carolConvs2.find((c) => c.id === gcid)?.has_mention === true);

    const dmMention = (await api(`/conversations/${cid}/messages`, {
      method: 'POST', token: alice, body: { kind: 'text', content: '单聊 @all', mentions: ['all'] },
    })).body;
    ok('单聊忽略 @所有人', Array.isArray(dmMention.mentions) && dmMention.mentions.length === 0);

    const outsiderMention = (await api(`/conversations/${gcid}/messages`, {
      method: 'POST', token: alice, body: { kind: 'text', content: '试图 @外部人', mentions: [daveId, bobId] },
    })).body;
    ok('@非会话成员被过滤（只留 bob）',
      outsiderMention.mentions.length === 1 && outsiderMention.mentions[0] === bobId,
      JSON.stringify(outsiderMention.mentions));

    // uid=1 误匹配回归：admin(id=1) 不应因 bob(id=2) 的 @ 被误判
    const adminConvs = (await api('/conversations', { token: admin })).body;
    ok('未参与的会话不会误报 @（越权/误匹配回归）',
      !adminConvs.some((c) => c.has_mention === true));

    // ---------- 2. 转发 ----------
    console.log('\n=== 2. 消息转发 ===');
    const fwd = await api('/conversations/forward', {
      method: 'POST', token: alice, body: { messageId: mBob.id, conversationIds: [cid] },
    });
    ok('转发到 1 个会话成功', fwd.status === 200 && fwd.body.count === 1, JSON.stringify(fwd.body).slice(0, 90));
    ok('转发生成的是新消息（id 不同）', fwd.body.items[0].message.id !== mBob.id);
    ok('转发内容一致', fwd.body.items[0].message.content === '你好 @鲍勃');

    const dmHistory = (await api(`/conversations/${cid}/messages`, { token: alice })).body;
    ok('目标会话历史里出现转发消息',
      dmHistory.messages.some((m) => m.id === fwd.body.items[0].message.id));

    const fwdMulti = await api('/conversations/forward', {
      method: 'POST', token: alice, body: { messageId: mBob.id, conversationIds: [cid, gcid] },
    });
    ok('一次转发到多个会话', fwdMulti.body.count === 2, `count=${fwdMulti.body.count}`);

    const fwdEmpty = await api('/conversations/forward', {
      method: 'POST', token: alice, body: { messageId: mBob.id, conversationIds: [] },
    });
    ok('转发目标为空被拒', fwdEmpty.status === 400);

    const recallTarget = (await api(`/conversations/${gcid}/messages`, {
      method: 'POST', token: alice, body: { kind: 'text', content: '待撤回再转发' },
    })).body;
    await api(`/conversations/${gcid}/messages/${recallTarget.id}/recall`, { method: 'POST', token: alice, body: {} });
    const fwdRecalled = await api('/conversations/forward', {
      method: 'POST', token: alice, body: { messageId: recallTarget.id, conversationIds: [cid] },
    });
    ok('转发已撤回消息被拒', fwdRecalled.status === 400, fwdRecalled.body?.error);

    // carol 与 alice 没有单聊，只有群；构造一个 carol 不在的会话转发
    const daveDm = (await api(`/conversations/dm/${daveId}`, { token: alice })).body.conversationId;
    const fwdOutsider = await api('/conversations/forward', {
      method: 'POST', token: carol, body: { messageId: mBob.id, conversationIds: [daveDm] },
    });
    ok('转发到非我参与的会话被拒', fwdOutsider.status === 400, fwdOutsider.body?.error);

    // ---------- 3. 置顶 ----------
    console.log('\n=== 3. 消息置顶 ===');
    const pin1 = await api(`/conversations/${gcid}/pin`, {
      method: 'POST', token: alice, body: { messageId: mBob.id },
    });
    ok('群主置顶成功', pin1.status === 200 && pin1.body.pinnedMessageId === mBob.id, JSON.stringify(pin1.body));

    const gHist = (await api(`/conversations/${gcid}/messages`, { token: bob })).body;
    ok('会话历史返回置顶消息详情', gHist.pinned?.id === mBob.id && !!gHist.pinned?.sender_name);
    ok('会话历史返回会话信息', gHist.conversation?.id === gcid && gHist.conversation?.type === 'group');

    const pin2 = await api(`/conversations/${gcid}/pin`, {
      method: 'POST', token: alice, body: { messageId: mBob.id },
    });
    ok('再次置顶同一消息 = 取消置顶', pin2.body.pinnedMessageId === null);

    await api(`/conversations/${gcid}/pin`, { method: 'POST', token: alice, body: { messageId: mBob.id } });
    const pinByCarol = await api(`/conversations/${gcid}/pin`, {
      method: 'POST', token: carol, body: { messageId: mAll.id },
    });
    ok('普通成员置顶群消息被拒', pinByCarol.status === 400, pinByCarol.body?.error);

    const dmPin = await api(`/conversations/${cid}/pin`, {
      method: 'POST', token: bob, body: { messageId: m1IdOf(dmHistory) },
    });
    ok('单聊任意成员可置顶', dmPin.status === 200 && dmPin.body.pinnedMessageId !== null, JSON.stringify(dmPin.body));

    const pinRecalled = await api(`/conversations/${gcid}/pin`, {
      method: 'POST', token: alice, body: { messageId: recallTarget.id },
    });
    ok('置顶已撤回消息被拒', pinRecalled.status === 400, pinRecalled.body?.error);

    // ---------- 4. 收藏 ----------
    console.log('\n=== 4. 消息收藏 ===');
    const fav1 = await api('/favorites', { method: 'POST', token: alice, body: { messageId: mBob.id } });
    ok('收藏成功', fav1.status === 200 && fav1.body.ok === true);

    const favList = (await api('/favorites', { token: alice })).body;
    ok('收藏列表含该条', favList.items.some((i) => i.id === mBob.id), `total=${favList.total}`);
    ok('收藏条目带所在会话名', !!favList.items[0]?.conv_title);
    ok('收藏条目带发送者名', !!favList.items[0]?.sender_name);

    await api('/favorites', { method: 'POST', token: alice, body: { messageId: mBob.id } });
    const favList2 = (await api('/favorites', { token: alice })).body;
    ok('重复收藏幂等（总数不变）', favList2.total === favList.total, `${favList.total} -> ${favList2.total}`);

    const favDel = await api(`/favorites/${mBob.id}`, { method: 'DELETE', token: alice });
    const favList3 = (await api('/favorites', { token: alice })).body;
    ok('取消收藏', favDel.body.ok === true && favList3.total === favList.total - 1);

    const favRecalled = await api('/favorites', { method: 'POST', token: alice, body: { messageId: recallTarget.id } });
    ok('收藏已撤回消息被拒', favRecalled.status === 400, favRecalled.body?.error);

    const favOutsider = await api('/favorites', { method: 'POST', token: carol, body: { messageId: mBob.id } });
    ok('收藏未参与会话的消息被拒（群消息 carol 在群内应成功）', favOutsider.status === 200);

    const favNotMember = await api('/favorites', { method: 'POST', token: carol, body: { messageId: m1IdOf(dmHistory) } });
    ok('收藏与我无关的单聊消息被拒', favNotMember.status === 400, favNotMember.body?.error);

    // ---------- 5. 群管理 ----------
    console.log('\n=== 5. 群管理 ===');
    const rename = await api(`/groups/${gid}`, { method: 'PATCH', token: alice, body: { name: '新群名' } });
    ok('群主改群名', rename.status === 200 && rename.body.group.name === '新群名');

    const announce = await api(`/groups/${gid}`, {
      method: 'PATCH', token: alice, body: { announcement: '本群用于测试，请勿闲聊' },
    });
    ok('群主设群公告', announce.status === 200 && !!announce.body.group.announcement);

    const renameByCarol = await api(`/groups/${gid}`, { method: 'PATCH', token: carol, body: { name: '篡改' } });
    ok('普通成员改群名被拒', renameByCarol.status === 403);

    const emptyName = await api(`/groups/${gid}`, { method: 'PATCH', token: alice, body: { name: '  ' } });
    ok('空群名被拒', emptyName.status === 400);

    const setAdmin = await api(`/groups/${gid}/members/${bobId}`, {
      method: 'PATCH', token: alice, body: { role: 'admin' },
    });
    ok('群主设 bob 为管理员', setAdmin.status === 200);

    const setAdminByCarol = await api(`/groups/${gid}/members/${bobId}`, {
      method: 'PATCH', token: carol, body: { role: 'admin' },
    });
    ok('普通成员设管理员被拒', setAdminByCarol.status === 403);

    const mute = await api(`/groups/${gid}/members/${carolId}`, {
      method: 'PATCH', token: bob, body: { muteMinutes: 5 },
    });
    ok('管理员禁言普通成员', mute.status === 200);

    const carolSend = await api(`/conversations/${gcid}/messages`, {
      method: 'POST', token: carol, body: { kind: 'text', content: '我被禁言了还能发吗' },
    });
    ok('被禁言成员发消息被拒', carolSend.status === 400, carolSend.body?.error);
    ok('禁言提示含剩余分钟', /禁言/.test(carolSend.body?.error || ''));

    const unmute = await api(`/groups/${gid}/members/${carolId}`, {
      method: 'PATCH', token: bob, body: { muteMinutes: 0 },
    });
    const carolSend2 = await api(`/conversations/${gcid}/messages`, {
      method: 'POST', token: carol, body: { kind: 'text', content: '解除禁言后可以发了' },
    });
    ok('解除禁言后可发言', unmute.status === 200 && carolSend2.status === 200);

    const ownerMute = await api(`/groups/${gid}/members/${aliceId}`, {
      method: 'PATCH', token: bob, body: { muteMinutes: 5 },
    });
    ok('群主不能被禁言', ownerMute.status === 400);

    const muteAdmin = await api(`/groups/${gid}/members/${bobId}`, {
      method: 'PATCH', token: alice, body: { muteMinutes: 5 },
    });
    ok('群主可禁言管理员', muteAdmin.status === 200);
    await api(`/groups/${gid}/members/${bobId}`, { method: 'PATCH', token: alice, body: { muteMinutes: 0 } });

    const kick = await api(`/groups/${gid}/members/${carolId}`, { method: 'DELETE', token: bob });
    ok('管理员踢普通成员', kick.status === 200);
    const gmAfterKick = (await api(`/groups/${gid}`, { token: alice })).body;
    ok('被踢成员已不在群', gmAfterKick.members.length === 2, `members=${gmAfterKick.members.length}`);

    const carolHistory = await api(`/conversations/${gcid}/messages`, { token: carol });
    ok('被踢后无法读群历史', carolHistory.status === 403);

    await api(`/groups/${gid}/members`, { method: 'POST', token: alice, body: { userId: carolId } });
    await api(`/groups/${gid}/members/${carolId}`, { method: 'PATCH', token: alice, body: { role: 'admin' } });
    const kickAdmin = await api(`/groups/${gid}/members/${carolId}`, { method: 'DELETE', token: bob });
    ok('管理员不能踢管理员', kickAdmin.status === 403, kickAdmin.body?.error);

    const transfer = await api(`/groups/${gid}/transfer`, {
      method: 'POST', token: alice, body: { userId: bobId },
    });
    ok('群主转让成功', transfer.status === 200 && transfer.body.newOwnerId === bobId);

    const gmAfterTransfer = (await api(`/groups/${gid}`, { token: bob })).body;
    ok('新群主 is_owner=true', gmAfterTransfer.is_owner === true && gmAfterTransfer.my_role === 'owner');
    ok('原群主降为普通成员',
      gmAfterTransfer.members.find((m) => m.id === aliceId)?.role === 'member');

    const ownerLeave = await api(`/groups/${gid}/leave`, { method: 'POST', token: bob, body: {} });
    ok('群主不能直接退群（须先转让）', ownerLeave.status === 400, ownerLeave.body?.error);

    const memberLeave = await api(`/groups/${gid}/leave`, { method: 'POST', token: alice, body: {} });
    ok('普通成员可退群', memberLeave.status === 200);
    const gmAfterLeave = (await api(`/groups/${gid}`, { token: bob })).body;
    ok('退群后成员数减少', gmAfterLeave.members.length === 2, `members=${gmAfterLeave.members.length}`);

    // ---------- 6. 免打扰 ----------
    console.log('\n=== 6. 免打扰 ===');
    const muteConv = await api(`/conversations/${cid}/mute`, {
      method: 'POST', token: alice, body: { muted: true },
    });
    ok('开启免打扰', muteConv.status === 200 && muteConv.body.muted === true);
    const aliceConvs = (await api('/conversations', { token: alice })).body;
    ok('会话列表 muted=true', aliceConvs.find((c) => c.id === cid)?.muted === true);
    const unmuteConv = await api(`/conversations/${cid}/mute`, {
      method: 'POST', token: alice, body: { muted: false },
    });
    ok('关闭免打扰', unmuteConv.body.muted === false);

    // ---------- 7. 群公告透传 ----------
    console.log('\n=== 7. 群公告 ===');
    const bobConvsFinal = (await api('/conversations', { token: bob })).body;
    ok('会话列表带群公告', !!bobConvsFinal.find((c) => c.id === gcid)?.announcement);

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

/** 从会话历史里取第一条 alice 发的未撤回消息 id（供置顶/收藏用） */
function m1IdOf(history) {
  const m = (history.messages || []).find((x) => !x.deleted);
  return m ? m.id : 0;
}
