/**
 * 小智IM v0.3.0 生产环境验证：@提及 / 转发 / 收藏 / 置顶 / 群管理
 *
 * 策略：创建 2 个临时用户 -> 建群互发 -> 全面校验 -> 物理清理
 * 清理顺序：删消息（连带磁盘文件）-> 删群 -> 删用户，不给真实用户留数据。
 *
 * 用法：node verify_prod_v030.js
 */
const BASE_LAN = 'http://192.168.31.44:3602';
const BASE_WAN = 'https://1dcf316343d04ecd93dd0330c2d81a0d.hn.takin.cc';

const STAMP = 'XZ30' + Date.now().toString().slice(-8);
const SUF = Date.now().toString().slice(-6);

let pass = 0, fail = 0;
const ok = (n, c, extra = '') => {
  if (c) { pass++; console.log('  \u2705 ' + n); }
  else { fail++; console.log('  \u274c ' + n + (extra ? '  -> ' + extra : '')); }
};
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function api(base, p, { method = 'GET', token, body } = {}) {
  const headers = {};
  if (token) headers['Authorization'] = 'Bearer ' + token;
  let payload;
  if (body !== undefined) {
    headers['Content-Type'] = 'application/json';
    payload = JSON.stringify(body);
  }
  const r = await fetch(base + '/api' + p, { method, headers, body: payload });
  const t = await r.text();
  let j = null;
  try { j = JSON.parse(t); } catch { /* 非 JSON */ }
  return { status: r.status, body: j, text: t };
}

(async () => {
  const created = { msgs: [], userIds: [], groupId: null };
  let adminTok = null;

  const track = (m) => { if (m?.id) created.msgs.push(m.id); return m; };

  try {
    // ---------- 0. 连通性 ----------
    console.log('\n=== 0. 连通性（内网 / 外网）===');
    const hLan = await api(BASE_LAN, '/health');
    ok('内网 /api/health 200', hLan.status === 200 && hLan.body?.ok === true);
    const hWan = await api(BASE_WAN, '/health');
    ok('外网 /api/health 200', hWan.status === 200 && hWan.body?.ok === true);

    // ---------- 1. 账号 ----------
    console.log('\n=== 1. 临时账号 ===');
    const lg = await api(BASE_LAN, '/auth/login', { method: 'POST', body: { username: 'admin', password: 'admin123' } });
    adminTok = lg.body?.token;
    ok('admin 登录成功', !!adminTok);

    const mk = async (u) => {
      const r = await api(BASE_LAN, '/admin/users', {
        method: 'POST', token: adminTok,
        body: { username: u, password: 'vfy12345', nickname: u },
      });
      if (r.body?.id) created.userIds.push(r.body.id);
      return r.body;
    };
    const uA = 'xzva' + SUF, uB = 'xzvb' + SUF;
    const A = await mk(uA);
    const B = await mk(uB);
    ok('创建 2 个临时用户', !!A?.id && !!B?.id, `A=${A?.id} B=${B?.id}`);

    const tokA = (await api(BASE_LAN, '/auth/login', { method: 'POST', body: { username: uA, password: 'vfy12345' } })).body?.token;
    const tokB = (await api(BASE_LAN, '/auth/login', { method: 'POST', body: { username: uB, password: 'vfy12345' } })).body?.token;
    ok('两个临时用户登录成功', !!tokA && !!tokB);

    // ---------- 2. 建群 ----------
    console.log('\n=== 2. 建群 ===');
    const g = (await api(BASE_LAN, '/groups', { method: 'POST', token: tokA, body: { name: STAMP + '群' } })).body;
    created.groupId = g?.groupId;
    const gid = g?.groupId, gcid = g?.conversationId;
    ok('建群成功', !!gid && !!gcid, JSON.stringify(g));

    await api(BASE_LAN, `/groups/${gid}/members`, { method: 'POST', token: tokA, body: { userId: B.id } });
    const gm = (await api(BASE_LAN, `/groups/${gid}`, { token: tokA })).body;
    ok('拉 B 入群', gm?.members?.length === 2, `members=${gm?.members?.length}`);
    ok('群详情返回 my_role / can_manage', gm?.my_role === 'owner' && gm?.is_owner === true);

    // ---------- 3. @提及 ----------
    console.log('\n=== 3. @提及 ===');
    const m1 = track((await api(BASE_LAN, `/conversations/${gcid}/messages`, {
      method: 'POST', token: tokA,
      body: { kind: 'text', content: `${STAMP} 你好 @${uB}`, mentions: [B.id] },
    })).body);
    ok('@某人消息落库', Array.isArray(m1?.mentions) && m1.mentions.includes(B.id), JSON.stringify(m1?.mentions));

    const convB = (await api(BASE_LAN, '/conversations', { token: tokB })).body;
    const gRowB = (convB || []).find((c) => c.id === gcid);
    ok('B 的会话列表 has_mention=true', gRowB?.has_mention === true, JSON.stringify(gRowB)?.slice(0, 160));
    ok('B 看到群公告字段存在', 'announcement' in (gRowB || {}));
    ok('B 看到 group_id', gRowB?.group_id === gid, `group_id=${gRowB?.group_id}`);

    const mAll = track((await api(BASE_LAN, `/conversations/${gcid}/messages`, {
      method: 'POST', token: tokA,
      body: { kind: 'text', content: `${STAMP} @所有人 通知`, mentions: ['all'] },
    })).body);
    ok('@所有人 记为 -1', Array.isArray(mAll?.mentions) && mAll.mentions.includes(-1));

    const mOut = track((await api(BASE_LAN, `/conversations/${gcid}/messages`, {
      method: 'POST', token: tokA,
      body: { kind: 'text', content: `${STAMP} 越权尝试`, mentions: [99999, B.id] },
    })).body);
    ok('@非成员被过滤', mOut?.mentions?.length === 1 && mOut.mentions[0] === B.id, JSON.stringify(mOut?.mentions));

    // ---------- 4. 转发 ----------
    console.log('\n=== 4. 消息转发 ===');
    const dmAB = (await api(BASE_LAN, `/conversations/dm/${B.id}`, { token: tokA })).body?.conversationId;
    const fwd = await api(BASE_LAN, '/conversations/forward', {
      method: 'POST', token: tokA, body: { messageId: m1.id, conversationIds: [dmAB] },
    });
    ok('转发到单聊成功', fwd.status === 200 && fwd.body?.count === 1, JSON.stringify(fwd.body)?.slice(0, 140));
    (fwd.body?.items || []).forEach((i) => track(i.message));
    ok('转发为新消息 id', fwd.body?.items?.[0]?.message?.id !== m1.id);

    const fwdBad = await api(BASE_LAN, '/conversations/forward', {
      method: 'POST', token: tokA, body: { messageId: m1.id, conversationIds: [] },
    });
    ok('空目标被拒（400）', fwdBad.status === 400);

    // ---------- 5. 置顶 ----------
    console.log('\n=== 5. 消息置顶 ===');
    const pin1 = await api(BASE_LAN, `/conversations/${gcid}/pin`, {
      method: 'POST', token: tokA, body: { messageId: m1.id },
    });
    ok('群主置顶成功', pin1.status === 200 && pin1.body?.pinnedMessageId === m1.id, JSON.stringify(pin1.body));

    const histB = (await api(BASE_LAN, `/conversations/${gcid}/messages`, { token: tokB })).body;
    ok('会话历史带置顶消息', histB?.pinned?.id === m1.id);
    ok('会话历史带会话信息', histB?.conversation?.type === 'group');
    ok('置顶消息带发送者名', !!histB?.pinned?.sender_name);

    const pin2 = await api(BASE_LAN, `/conversations/${gcid}/pin`, {
      method: 'POST', token: tokA, body: { messageId: m1.id },
    });
    ok('再次置顶 = 取消', pin2.body?.pinnedMessageId === null);
    await api(BASE_LAN, `/conversations/${gcid}/pin`, { method: 'POST', token: tokA, body: { messageId: m1.id } });

    const pinByB = await api(BASE_LAN, `/conversations/${gcid}/pin`, {
      method: 'POST', token: tokB, body: { messageId: mAll.id },
    });
    ok('普通成员置顶被拒（400）', pinByB.status === 400, pinByB.body?.error);

    // ---------- 6. 收藏 ----------
    console.log('\n=== 6. 消息收藏 ===');
    const fav = await api(BASE_LAN, '/favorites', { method: 'POST', token: tokA, body: { messageId: m1.id } });
    ok('收藏成功', fav.status === 200 && fav.body?.ok === true);

    const favList = (await api(BASE_LAN, '/favorites', { token: tokA })).body;
    ok('收藏列表含该条', (favList?.items || []).some((i) => i.id === m1.id), `total=${favList?.total}`);
    ok('收藏带会话名', !!favList?.items?.[0]?.conv_title);
    ok('收藏带发送者名', !!favList?.items?.[0]?.sender_name);

    await api(BASE_LAN, '/favorites', { method: 'POST', token: tokA, body: { messageId: m1.id } });
    const favList2 = (await api(BASE_LAN, '/favorites', { token: tokA })).body;
    ok('重复收藏幂等', favList2?.total === favList?.total);

    const favDel = await api(BASE_LAN, `/favorites/${m1.id}`, { method: 'DELETE', token: tokA });
    ok('取消收藏', favDel.body?.ok === true);

    // ---------- 7. 群管理 ----------
    console.log('\n=== 7. 群管理 ===');
    const ren = await api(BASE_LAN, `/groups/${gid}`, {
      method: 'PATCH', token: tokA, body: { name: STAMP + '新群名' },
    });
    ok('群主改群名', ren.status === 200 && ren.body?.group?.name === STAMP + '新群名');

    const ann = await api(BASE_LAN, `/groups/${gid}`, {
      method: 'PATCH', token: tokA, body: { announcement: STAMP + ' 这是一条群公告' },
    });
    ok('群主设公告', ann.status === 200 && !!ann.body?.group?.announcement);

    const renByB = await api(BASE_LAN, `/groups/${gid}`, {
      method: 'PATCH', token: tokB, body: { name: '篡改' },
    });
    ok('普通成员改群名被拒（403）', renByB.status === 403);

    const setAdmin = await api(BASE_LAN, `/groups/${gid}/members/${B.id}`, {
      method: 'PATCH', token: tokA, body: { role: 'admin' },
    });
    ok('设 B 为管理员', setAdmin.status === 200);

    const mute = await api(BASE_LAN, `/groups/${gid}/members/${B.id}`, {
      method: 'PATCH', token: tokA, body: { muteMinutes: 5 },
    });
    ok('禁言 B', mute.status === 200);

    const bSend = await api(BASE_LAN, `/conversations/${gcid}/messages`, {
      method: 'POST', token: tokB, body: { kind: 'text', content: STAMP + ' 被禁言还能发？' },
    });
    ok('被禁言后发消息被拒（400）', bSend.status === 400, bSend.body?.error);
    ok('禁言提示含剩余时间', /禁言/.test(bSend.body?.error || ''));

    const unmute = await api(BASE_LAN, `/groups/${gid}/members/${B.id}`, {
      method: 'PATCH', token: tokA, body: { muteMinutes: 0 },
    });
    const bSend2 = track((await api(BASE_LAN, `/conversations/${gcid}/messages`, {
      method: 'POST', token: tokB, body: { kind: 'text', content: STAMP + ' 解除禁言后正常' },
    })).body);
    ok('解除禁言后可发言', unmute.status === 200 && bSend2?.id);

    const kick = await api(BASE_LAN, `/groups/${gid}/members/${B.id}`, { method: 'DELETE', token: tokA });
    ok('群主移出成员', kick.status === 200);

    const bRead = await api(BASE_LAN, `/conversations/${gcid}/messages`, { token: tokB });
    ok('被移出后无法读群历史（403）', bRead.status === 403);

    // 拉回并转让群主
    await api(BASE_LAN, `/groups/${gid}/members`, { method: 'POST', token: tokA, body: { userId: B.id } });
    const tr = await api(BASE_LAN, `/groups/${gid}/transfer`, {
      method: 'POST', token: tokA, body: { userId: B.id },
    });
    ok('转让群主成功', tr.status === 200 && tr.body?.newOwnerId === B.id, JSON.stringify(tr.body));

    const gmB = (await api(BASE_LAN, `/groups/${gid}`, { token: tokB })).body;
    ok('B 成为群主', gmB?.is_owner === true && gmB?.my_role === 'owner');
    ok('A 降为普通成员', (gmB?.members || []).find((m) => m.id === A.id)?.role === 'member');

    const leaveOwner = await api(BASE_LAN, `/groups/${gid}/leave`, { method: 'POST', token: tokB, body: {} });
    ok('群主不能直接退群（400）', leaveOwner.status === 400);

    const leaveA = await api(BASE_LAN, `/groups/${gid}/leave`, { method: 'POST', token: tokA, body: {} });
    ok('普通成员退群成功', leaveA.status === 200);

    // ---------- 8. 免打扰 ----------
    console.log('\n=== 8. 免打扰 ===');
    const muteC = await api(BASE_LAN, `/conversations/${dmAB}/mute`, {
      method: 'POST', token: tokA, body: { muted: true },
    });
    ok('开启免打扰', muteC.status === 200 && muteC.body?.muted === true);
    const convA = (await api(BASE_LAN, '/conversations', { token: tokA })).body;
    ok('会话列表 muted=true', (convA || []).find((c) => c.id === dmAB)?.muted === true);

    // ---------- 9. 外网复验 ----------
    console.log('\n=== 9. 外网复验（关键路径）===');
    const lgWan = await api(BASE_WAN, '/auth/login', { method: 'POST', body: { username: uB, password: 'vfy12345' } });
    ok('外网登录成功', lgWan.status === 200 && !!lgWan.body?.token);
    const wanTok = lgWan.body?.token;

    const wanGm = await api(BASE_WAN, `/groups/${gid}`, { token: wanTok });
    ok('外网拉群详情成功', wanGm.status === 200 && wanGm.body?.group?.id === gid);
    ok('外网看到群公告', !!wanGm.body?.group?.announcement);

    const wanHist = await api(BASE_WAN, `/conversations/${gcid}/messages`, { token: wanTok });
    ok('外网拉群历史成功', wanHist.status === 200 && Array.isArray(wanHist.body?.messages));
    const wanM1 = (wanHist.body?.messages || []).find((m) => m.id === m1.id);
    ok('外网看到 @提及 字段', Array.isArray(wanM1?.mentions) && wanM1.mentions.includes(B.id));
    ok('外网看到置顶消息', wanHist.body?.pinned?.id === m1.id);

    const wanFav = await api(BASE_WAN, '/favorites', { method: 'POST', token: wanTok, body: { messageId: m1.id } });
    ok('外网收藏成功', wanFav.status === 200);
    const wanFavList = (await api(BASE_WAN, '/favorites', { token: wanTok })).body;
    ok('外网收藏列表可见', (wanFavList?.items || []).some((i) => i.id === m1.id));
    await api(BASE_WAN, `/favorites/${m1.id}`, { method: 'DELETE', token: wanTok });

    const wanConv = (await api(BASE_WAN, '/conversations', { token: wanTok })).body;
    ok('外网会话列表 has_mention=true', (wanConv || []).find((c) => c.id === gcid)?.has_mention === true);

    // ---------- 10. admin 后台新字段 ----------
    console.log('\n=== 10. 管理后台新字段 ===');
    const admGroups = (await api(BASE_LAN, '/admin/groups', { token: adminTok })).body;
    const myGroup = (admGroups || []).find((x) => x.id === gid);
    ok('admin 群组列表带公告', !!myGroup?.announcement, JSON.stringify(myGroup)?.slice(0, 140));

    const admMsgs = (await api(BASE_LAN, '/admin/messages?mentioned=1&limit=50', { token: adminTok })).body;
    ok('admin 消息支持「仅看@提及」筛选', Array.isArray(admMsgs) && admMsgs.length > 0, `n=${admMsgs?.length}`);
    ok('admin 消息带 mentions 字段', admMsgs?.some((m) => m.mentions));

    const admAdmin = await api(BASE_LAN, `/admin/messages?q=${encodeURIComponent(STAMP)}&limit=5`, { token: adminTok });
    ok('admin 关键词筛选正常', admAdmin.status === 200 && Array.isArray(admAdmin.body));

    // ---------- 11. 清理 ----------
    console.log('\n=== 11. 清理测试数据 ===');
    let cleaned = 0;
    for (const id of created.msgs) {
      const d = await api(BASE_LAN, `/admin/messages/${id}`, { method: 'DELETE', token: adminTok });
      if (d.status === 200) cleaned++;
    }
    ok(`删除 ${created.msgs.length} 条测试消息`, cleaned === created.msgs.length, `cleaned=${cleaned}`);

    if (created.groupId) {
      const dg = await api(BASE_LAN, `/admin/groups/${created.groupId}`, { method: 'DELETE', token: adminTok });
      ok('删除测试群', dg.status === 200, JSON.stringify(dg.body));
    }

    let delUsers = 0;
    for (const id of created.userIds) {
      const du = await api(BASE_LAN, `/admin/users/${id}`, { method: 'DELETE', token: adminTok });
      if (du.status === 200) delUsers++;
    }
    ok(`删除 ${created.userIds.length} 个临时用户`, delUsers === created.userIds.length);
    created.userIds = [];

    await sleep(300);
    const after = await api(BASE_LAN, '/conversations/search?q=' + encodeURIComponent(STAMP), { token: adminTok });
    ok('清理后搜不到测试消息', after.body?.total === 0, 'total=' + after.body?.total);
  } catch (e) {
    console.error('\n验证异常：', e);
    fail++;
    try {
      if (adminTok) {
        for (const id of created.msgs) {
          if (id) await api(BASE_LAN, `/admin/messages/${id}`, { method: 'DELETE', token: adminTok });
        }
        if (created.groupId) await api(BASE_LAN, `/admin/groups/${created.groupId}`, { method: 'DELETE', token: adminTok });
        for (const id of created.userIds) {
          await api(BASE_LAN, `/admin/users/${id}`, { method: 'DELETE', token: adminTok });
        }
      }
    } catch { /* ignore */ }
  }

  console.log('\n' + '='.repeat(46));
  console.log(`  通过 ${pass} / 失败 ${fail}`);
  console.log('='.repeat(46) + '\n');
  process.exit(fail > 0 ? 1 : 0);
})();
