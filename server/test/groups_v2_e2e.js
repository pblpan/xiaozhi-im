// 群功能 v2（全员禁言 / 群名片 / 加群审批 / 群投票）—— 端到端测试
//
//   node test/groups_v2_e2e.js
//
// 起一个隔离实例（独立 DATA_DIR + 端口），跑真实 HTTP。
//
// 【这四样为什么值得专门一个文件】
// 它们共享同一条主线：「群设置改了之后，普通成员的行为必须立刻跟着变」——
// 全员禁言开了普通成员就要发不出、审批开了普通成员拉人就要变成待批。
// 只测接口返回 ok 不够，必须用 sendMessage 的真实路径把"发不出"钉住。

const { spawn } = require('child_process');
const path = require('path');
const fs = require('fs');
const os = require('os');

const PORT = 3733;
const BASE = `http://127.0.0.1:${PORT}`;
const SERVER_DIR = path.resolve(__dirname, '..');
const DATA_DIR = path.join(os.tmpdir(), 'xiaozhi-groups-v2-e2e-' + Date.now());

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
  console.log('[群功能 v2 E2E] 服务端已就绪 ' + BASE + '\n');

  const reg = async (u) => {
    const r = await api('POST', '/api/auth/register', { body: { username: u, password: 'pw123456', nickname: u } });
    if (!r.body?.token) throw new Error(`注册 ${u} 失败: ${JSON.stringify(r)}`);
    return r.body;
  };
  const A = await reg('owner1');   // 群主
  const B = await reg('member1');  // 普通成员
  const C = await reg('member2');  // 被拉的人
  const D = await reg('member3');  // 另一个普通成员
  const ta = A.token, tb = B.token, tc = C.token, td = D.token;
  const aId = A.user.id, bId = B.user.id, cId = C.user.id, dId = D.user.id;

  const lg = await api('POST', '/api/auth/login', { body: { username: 'admin', password: 'TestAdmin_123' } });
  const tAdmin = lg.body?.token;
  ok('管理员登录成功', !!tAdmin);

  // ---------------- 建群 ----------------
  let r = await api('POST', '/api/groups', { token: ta, body: { name: 'v2功能群' } });
  const gid = r.body?.groupId, cid = r.body?.conversationId;
  ok('建群 → 200', r.status === 200 && Number.isInteger(gid), JSON.stringify(r.body));
  for (const uid of [bId, cId]) {
    await api('POST', `/api/groups/${gid}/members`, { token: ta, body: { userId: uid } });
  }

  // ---------------- 一：全员禁言 ----------------
  console.log('\n【一】全员禁言');
  r = await api('POST', `/api/conversations/${cid}/messages`, { token: tb, body: { kind: 'text', content: '平时能发' } });
  ok('禁言前普通成员能发言 → 200', r.status === 200, JSON.stringify(r.body).slice(0, 120));

  r = await api('PATCH', `/api/groups/${gid}`, { token: tb, body: { mutedAll: true } });
  ok('普通成员不能开全员禁言 → 403', r.status === 403, `status=${r.status}`);

  r = await api('PATCH', `/api/groups/${gid}`, { token: ta, body: { mutedAll: true } });
  ok('群主开全员禁言 → 200', r.status === 200 && r.body?.group?.muted_all === 1, JSON.stringify(r.body));

  r = await api('POST', `/api/conversations/${cid}/messages`, { token: tb, body: { kind: 'text', content: '被禁言了' } });
  ok('开启后普通成员发言被拦 → 400', r.status === 400 && /全员禁言/.test(r.body?.error || ''), `status=${r.status} body=${JSON.stringify(r.body)}`);

  r = await api('POST', `/api/conversations/${cid}/messages`, { token: ta, body: { kind: 'text', content: '群主还能发' } });
  ok('群主豁免仍能发言 → 200', r.status === 200, JSON.stringify(r.body).slice(0, 120));

  r = await api('POST', `/api/conversations/${cid}/messages`, { token: tAdmin, body: { kind: 'text', content: '系统管理员也能发' } });
  ok('系统管理员豁免（不在群也能发？—他未入群应 400 not member）→ 非"全员禁言"文案',
    r.status !== 400 || !/全员禁言/.test(r.body?.error || ''), `status=${r.status} body=${JSON.stringify(r.body)}`);

  r = await api('PATCH', `/api/groups/${gid}`, { token: ta, body: { mutedAll: false } });
  r = await api('POST', `/api/conversations/${cid}/messages`, { token: tb, body: { kind: 'text', content: '又能发了' } });
  ok('关闭后普通成员恢复发言 → 200', r.status === 200, JSON.stringify(r.body).slice(0, 120));

  // ---------------- 二：群名片 ----------------
  console.log('\n【二】群名片');
  r = await api('PATCH', `/api/groups/${gid}/members/me`, { token: tb, body: { nickname: '小张（仓管）' } });
  ok('自己设群名片 → 200', r.status === 200 && r.body?.nickname === '小张（仓管）', JSON.stringify(r.body));

  r = await api('GET', `/api/groups/${gid}`, { token: ta });
  const meB = (r.body?.members || []).find((m) => m.id === bId);
  ok('群详情下发 nickname = 群名片优先', meB?.nickname === '小张（仓管）' && meB?.group_nickname === '小张（仓管）' && meB?.real_nickname === 'member1', JSON.stringify(meB));
  const meA = (r.body?.members || []).find((m) => m.id === aId);
  ok('没设名片的成员 nickname 回退真实昵称', meA?.nickname === 'owner1' && meA?.group_nickname == null, JSON.stringify(meA));

  r = await api('PATCH', `/api/groups/${gid}/members/${bId}/nickname`, { token: tb, body: { nickname: '自己改自己走专用口' } });
  ok('他人名片接口对普通成员 → 403', r.status === 403, `status=${r.status}`);

  r = await api('PATCH', `/api/groups/${gid}/members/${bId}/nickname`, { token: ta, body: { nickname: '仓管·张三' } });
  ok('群主改他人群名片 → 200', r.status === 200 && r.body?.nickname === '仓管·张三', JSON.stringify(r.body));

  r = await api('PATCH', `/api/groups/${gid}/members/${bId}/nickname`, { token: ta, body: { nickname: 'x'.repeat(21) } });
  ok('超 20 字 → 400', r.status === 400, `status=${r.status}`);

  r = await api('PATCH', `/api/groups/${gid}/members/me`, { token: tb, body: { nickname: '' } });
  r = await api('GET', `/api/groups/${gid}`, { token: ta });
  const meB2 = (r.body?.members || []).find((m) => m.id === bId);
  ok('空串清除名片 → 回退真实昵称', meB2?.nickname === 'member1', JSON.stringify(meB2));

  // ---------------- 三：加群审批 ----------------
  console.log('\n【三】加群审批');
  r = await api('PATCH', `/api/groups/${gid}`, { token: ta, body: { joinMode: 'bogus' } });
  ok('非法 joinMode → 400', r.status === 400, `status=${r.status}`);

  r = await api('PATCH', `/api/groups/${gid}`, { token: ta, body: { joinMode: 'approval' } });
  ok('开启加群验证 → 200', r.status === 200 && r.body?.group?.join_mode === 'approval', JSON.stringify(r.body));

  // 群主（管理员权限）拉人：直接进
  r = await api('POST', `/api/groups/${gid}/members`, { token: ta, body: { userId: dId } });
  ok('审批模式下群主拉人直接进', r.status === 200 && r.body?.ok === true && !r.body?.pending, JSON.stringify(r.body));

  // 普通成员拉一个已在群的人：幂等返回 duplicated，不重复挂申请
  r = await api('POST', `/api/groups/${gid}/members`, { token: tb, body: { userId: cId } });
  ok('拉已在群的人 → duplicated 幂等', r.status === 200 && r.body?.duplicated === true, JSON.stringify(r.body));

  // 普通成员拉一个不在群的新人 → 进申请池
  const E = await reg('newbie');
  r = await api('POST', `/api/groups/${gid}/members`, { token: tb, body: { userId: E.user.id } });
  ok('普通成员拉新人 → pending', r.status === 200 && r.body?.pending === true, JSON.stringify(r.body));

  r = await api('GET', `/api/groups/${gid}/joinRequests`, { token: tb });
  ok('普通成员看审批列表 → 403', r.status === 403, `status=${r.status}`);

  r = await api('GET', `/api/groups/${gid}/joinRequests`, { token: ta });
  const req = (r.body?.items || []).find((x) => x.user_id === E.user.id);
  ok('群主看到待审申请（带申请人/邀请人）', r.status === 200 && !!req && req.user_nickname === 'newbie' && req.inviter_nickname === 'member1', JSON.stringify(r.body?.items));

  // 没批之前新人确实不在群里
  r = await api('GET', `/api/groups/${gid}`, { token: E.token });
  ok('未批前申请人不在群 → 403', r.status === 403, `status=${r.status}`);

  r = await api('POST', `/api/groups/${gid}/joinRequests/${req.id}/approve`, { token: tb });
  ok('普通成员审批 → 403', r.status === 403, `status=${r.status}`);

  r = await api('POST', `/api/groups/${gid}/joinRequests/${req.id}/approve`, { token: ta });
  ok('群主批准 → 200', r.status === 200 && r.body?.ok === true, JSON.stringify(r.body));

  r = await api('GET', `/api/groups/${gid}`, { token: E.token });
  ok('批准后新人真在群里', r.status === 200, `status=${r.status}`);

  r = await api('POST', `/api/groups/${gid}/joinRequests/${req.id}/approve`, { token: ta });
  ok('重复审批 → 404（已处理）', r.status === 404, `status=${r.status}`);

  // 拒绝路径
  const F = await reg('newbie2');
  await api('POST', `/api/groups/${gid}/members`, { token: tb, body: { userId: F.user.id } });
  r = await api('GET', `/api/groups/${gid}/joinRequests`, { token: ta });
  const reqF = (r.body?.items || []).find((x) => x.user_id === F.user.id);
  r = await api('POST', `/api/groups/${gid}/joinRequests/${reqF.id}/reject`, { token: ta });
  ok('群主拒绝 → 200', r.status === 200, JSON.stringify(r.body));
  r = await api('GET', `/api/groups/${gid}`, { token: F.token });
  ok('被拒后仍不在群 → 403', r.status === 403, `status=${r.status}`);

  r = await api('PATCH', `/api/groups/${gid}`, { token: ta, body: { joinMode: 'free' } });
  ok('改回 free 模式', r.status === 200 && r.body?.group?.join_mode === 'free');

  // ---------------- 四：群投票 ----------------
  console.log('\n【四】群投票');
  r = await api('POST', `/api/groups/${gid}/polls`, { token: ta, body: { title: '团建吃什么', options: ['火锅', '烧烤', '日料'], multi: false } });
  ok('建单选投票 → 200', r.status === 200 && Number.isInteger(r.body?.pollId), JSON.stringify(r.body));
  const pollId = r.body?.pollId;

  // 卡片消息真发进群里了（kind=poll，content 带 pollId）
  r = await api('GET', `/api/conversations/${cid}/messages`, { token: ta });
  const pollMsg = (r.body?.messages || []).filter((m) => m.kind === 'pop').concat((r.body?.messages || []).filter((m) => m.kind === 'poll'));
  const card = pollMsg.find((m) => m.kind === 'poll');
  ok('群里出现 poll 消息卡片且带 pollId', !!card && (() => { try { return JSON.parse(card.content).pollId === pollId; } catch { return false; } })(), JSON.stringify(card || r.body?.messages?.slice(-2)));

  r = await api('POST', `/api/groups/${gid}/polls`, { token: ta, body: { title: '只有一个选项', options: ['就它'] } });
  ok('选项少于 2 → 400', r.status === 400, `status=${r.status}`);

  r = await api('POST', `/api/groups/${gid}/polls/${pollId}/vote`, { token: tb, body: { options: [0, 1] } });
  ok('单选投两票 → 400', r.status === 400, `status=${r.status} body=${JSON.stringify(r.body)}`);

  r = await api('POST', `/api/groups/${gid}/polls/${pollId}/vote`, { token: tb, body: { options: [1] } });
  ok('普通成员投票 → 200 计票+1', r.status === 200 && r.body?.poll?.counts?.[1] === 1 && r.body?.poll?.myVotes?.[0] === 1, JSON.stringify(r.body?.poll));

  r = await api('POST', `/api/groups/${gid}/polls/${pollId}/vote`, { token: tb, body: { options: [2] } });
  ok('改票（单选清旧票）→ counts[1]归0 counts[2]=1', r.status === 200 && r.body?.poll?.counts?.[1] === 0 && r.body?.poll?.counts?.[2] === 1, JSON.stringify(r.body?.poll?.counts));

  // 多选投票
  r = await api('POST', `/api/groups/${gid}/polls`, { token: tb, body: { title: '谁参加周五例会', options: ['上午', '下午', '晚上'], multi: true, anonymous: true } });
  const multiId = r.body?.pollId;
  ok('普通成员也能建多选匿名投票', r.status === 200 && Number.isInteger(multiId), JSON.stringify(r.body));
  await api('POST', `/api/groups/${gid}/polls/${multiId}/vote`, { token: ta, body: { options: [0, 2] } });
  await api('POST', `/api/groups/${gid}/polls/${multiId}/vote`, { token: td, body: { options: [2] } });
  r = await api('GET', `/api/groups/${gid}/polls/${multiId}`, { token: ta });
  ok('多选计票正确 [1,0,2]', r.body?.poll?.counts?.[0] === 1 && r.body?.poll?.counts?.[2] === 2, JSON.stringify(r.body?.poll?.counts));
  ok('匿名投票不下发 voters 名单', r.body?.poll?.voters === undefined, JSON.stringify(r.body?.poll?.voters));

  // 非匿名：名单下发
  r = await api('GET', `/api/groups/${gid}/polls/${pollId}`, { token: ta });
  ok('非匿名投票下发 voters 名单', Array.isArray(r.body?.poll?.voters?.[2]) && r.body.poll.voters[2].includes(bId), JSON.stringify(r.body?.poll?.voters));

  r = await api('POST', `/api/groups/${gid}/polls/${pollId}/close`, { token: tb, body: {} });
  ok('非发起人的普通成员不能关闭 → 403', r.status === 403, `status=${r.status}`);

  r = await api('POST', `/api/groups/${gid}/polls/${pollId}/close`, { token: ta, body: {} });
  ok('发起人（群主）关闭 → 200', r.status === 200, JSON.stringify(r.body));

  r = await api('POST', `/api/groups/${gid}/polls/${pollId}/vote`, { token: td, body: { options: [0] } });
  ok('关闭后投票 → 400', r.status === 400, `status=${r.status}`);

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
