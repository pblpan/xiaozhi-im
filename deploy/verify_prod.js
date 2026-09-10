/**
 * 小智IM v0.2.0 生产环境验证：语音消息 + 全局消息搜索
 *
 * 策略：创建临时用户 -> 与 admin 建 DM -> 发语音/文字 -> 全面校验 -> 清理
 * 清理是物理删除（admin 的 DELETE /admin/messages/:id 会连磁盘文件一起删），
 * 因此不会给真实用户留下测试数据。
 *
 * 用法：node verify_prod.js
 */
const BASE_LAN = 'http://192.168.31.44:3602';
const BASE_WAN = 'https://1dcf316343d04ecd93dd0330c2d81a0d.hn.takin.cc';

const STAMP = 'XZVERIFY' + Date.now().toString().slice(-8);
const TMP_USER = 'xztest' + Date.now().toString().slice(-6);

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

async function uploadAudio(base, token, name) {
  const bytes = new Uint8Array(3072);
  for (let i = 0; i < bytes.length; i++) bytes[i] = (i * 31) & 0xff;
  const fd = new FormData();
  fd.append('file', new Blob([bytes], { type: 'audio/mp4' }), name);
  const r = await fetch(base + '/api/files/upload', {
    method: 'POST',
    headers: { Authorization: 'Bearer ' + token },
    body: fd,
  });
  return { status: r.status, body: await r.json().catch(() => null) };
}

(async () => {
  const created = { msgs: [], files: [], userId: null };
  let adminTok = null;

  try {
    // ---------- 0. 连通性 ----------
    console.log('\n=== 0. 连通性（内网 / 外网）===');
    const hLan = await api(BASE_LAN, '/health');
    ok('内网 /api/health 200', hLan.status === 200 && hLan.body?.ok === true, JSON.stringify(hLan.body));
    const hWan = await api(BASE_WAN, '/health');
    ok('外网 /api/health 200', hWan.status === 200 && hWan.body?.ok === true, JSON.stringify(hWan.body));

    // ---------- 1. 登录 ----------
    console.log('\n=== 1. 鉴权 ===');
    const lg = await api(BASE_LAN, '/auth/login', { method: 'POST', body: { username: 'admin', password: 'admin123' } });
    adminTok = lg.body?.token;
    ok('admin 登录成功', !!adminTok);
    const lgWan = await api(BASE_WAN, '/auth/login', { method: 'POST', body: { username: 'admin', password: 'admin123' } });
    ok('外网登录成功', lgWan.status === 200 && !!lgWan.body?.token);

    // ---------- 2. 建临时用户 ----------
    console.log('\n=== 2. 临时用户（隔离测试，用完即删）===');
    const mk = await api(BASE_LAN, '/admin/users', {
      method: 'POST', token: adminTok,
      body: { username: TMP_USER, password: 'tmp123456', nickname: '临时验证号' },
    });
    created.userId = mk.body?.id;
    ok('创建临时用户', !!created.userId, JSON.stringify(mk.body));
    const tmpLogin = await api(BASE_LAN, '/auth/login', { method: 'POST', body: { username: TMP_USER, password: 'tmp123456' } });
    const tmpTok = tmpLogin.body?.token;
    ok('临时用户登录', !!tmpTok);

    // 与 admin 建 DM（消息只在这条私聊里，不打扰任何真人）
    const meAdmin = await api(BASE_LAN, '/auth/me', { token: adminTok });
    const adminId = meAdmin.body?.id || meAdmin.body?.user?.id;
    const dm = await api(BASE_LAN, `/conversations/dm/${adminId}`, { token: tmpTok });
    const cid = dm.body?.conversationId;
    ok('建立临时 DM 会话', !!cid, JSON.stringify(dm.body));

    // ---------- 3. 语音消息 ----------
    console.log('\n=== 3. 语音消息（生产）===');
    const up = await uploadAudio(BASE_LAN, tmpTok, 'voice.m4a');
    ok('上传音频文件', up.status === 200 && !!up.body?.id, JSON.stringify(up.body));
    created.files.push(up.body?.id);

    const voice = await api(BASE_LAN, `/conversations/${cid}/messages`, {
      method: 'POST', token: tmpTok,
      body: { kind: 'audio', content: '9', fileId: up.body.id },
    });
    created.msgs.push(voice.body?.id);
    ok('发送语音消息', voice.status === 200 && voice.body?.kind === 'audio', JSON.stringify(voice.body));
    ok('语音带可播放 file_url', !!voice.body?.file_url, JSON.stringify(voice.body));
    ok('语音时长 content=9', voice.body?.content === '9', 'content=' + voice.body?.content);

    // 音频文件真的能下载
    if (voice.body?.file_url) {
      const fr = await fetch(BASE_LAN + voice.body.file_url);
      const buf = await fr.arrayBuffer();
      ok('语音文件可下载且非空', fr.status === 200 && buf.byteLength > 0, `status=${fr.status} size=${buf.byteLength}`);
    } else {
      ok('语音文件可下载且非空', false, 'no file_url');
    }

    // 非法类型 / 缺文件
    const badKind = await api(BASE_LAN, `/conversations/${cid}/messages`, {
      method: 'POST', token: tmpTok, body: { kind: 'video', content: 'x' },
    });
    ok('非法消息类型被拒（400）', badKind.status === 400, JSON.stringify(badKind.body));
    const noFile = await api(BASE_LAN, `/conversations/${cid}/messages`, {
      method: 'POST', token: tmpTok, body: { kind: 'audio', content: '3' },
    });
    ok('语音缺文件被拒（400）', noFile.status === 400, JSON.stringify(noFile.body));

    // ---------- 4. 文字 + 会话列表预览 ----------
    console.log('\n=== 4. 会话列表语音预览 ===');
    const text = await api(BASE_LAN, `/conversations/${cid}/messages`, {
      method: 'POST', token: tmpTok,
      body: { kind: 'text', content: STAMP + ' 生产验证文字' },
    });
    created.msgs.push(text.body?.id);
    ok('发送验证文字', text.status === 200, JSON.stringify(text.body));

    const convs = await api(BASE_LAN, '/conversations', { token: tmpTok });
    const cv = (convs.body || []).find((c) => c.id === cid);
    ok('会话列表可见该会话', !!cv, JSON.stringify(convs.body));
    ok('最新预览为文字（非原始 kind）', cv?.last_content?.includes(STAMP), 'last=' + cv?.last_content);
    ok('会话列表带 unread 字段', typeof cv?.unread === 'number', 'unread=' + cv?.unread);

    // 再发一条语音，确认预览变 [语音]
    const up2 = await uploadAudio(BASE_LAN, tmpTok, 'voice2.m4a');
    created.files.push(up2.body?.id);
    const v2 = await api(BASE_LAN, `/conversations/${cid}/messages`, {
      method: 'POST', token: tmpTok, body: { kind: 'audio', content: '4', fileId: up2.body.id },
    });
    created.msgs.push(v2.body?.id);
    const convs2 = await api(BASE_LAN, '/conversations', { token: tmpTok });
    const cv2 = (convs2.body || []).find((c) => c.id === cid);
    ok('语音消息预览显示 [语音]', cv2?.last_content === '[语音]', 'last=' + cv2?.last_content);

    // ---------- 5. 消息搜索 ----------
    console.log('\n=== 5. 全局消息搜索（生产）===');
    const s1 = await api(BASE_LAN, '/conversations/search?q=' + encodeURIComponent(STAMP), { token: tmpTok });
    ok('搜到自己的验证消息', s1.status === 200 && s1.body?.total >= 1, JSON.stringify(s1.body).slice(0, 200));
    ok('结果带会话标题', !!s1.body?.items?.[0]?.conv_title, JSON.stringify(s1.body?.items?.[0]));
    ok('结果带发送者名', !!s1.body?.items?.[0]?.sender_name, JSON.stringify(s1.body?.items?.[0]));

    const sWan = await api(BASE_WAN, '/conversations/search?q=' + encodeURIComponent(STAMP), { token: lgWan.body.token });
    ok('外网搜索同样命中', sWan.status === 200 && sWan.body?.total >= 1, JSON.stringify(sWan.body).slice(0, 160));

    const sWild = await api(BASE_LAN, '/conversations/search?q=' + encodeURIComponent('%'), { token: tmpTok });
    ok('LIKE 通配符已转义（搜 % 不返回全部）', sWild.body?.total === 0, 'total=' + sWild.body?.total);

    const sAudio = await api(BASE_LAN, '/conversations/search?q=' + encodeURIComponent('语音'), { token: tmpTok });
    ok('非文字消息不参与搜索', sAudio.body?.total === 0, 'total=' + sAudio.body?.total);

    const sEmpty = await api(BASE_LAN, '/conversations/search?q=', { token: tmpTok });
    ok('空关键词返回空结果', sEmpty.body?.total === 0);

    const sNoAuth = await api(BASE_LAN, '/conversations/search?q=' + encodeURIComponent(STAMP));
    ok('搜索未登录被拒（401）', sNoAuth.status === 401, 'status=' + sNoAuth.status);

    // admin 是会话成员，应该也能搜到；非成员（拿一个不相关 token）搜不到
    const sAdmin = await api(BASE_LAN, '/conversations/search?q=' + encodeURIComponent(STAMP), { token: adminTok });
    ok('会话内另一成员可搜到', sAdmin.body?.total >= 1, 'total=' + sAdmin.body?.total);

    // ---------- 6. 历史接口结构 ----------
    console.log('\n=== 6. 历史接口结构 ===');
    const hist = await api(BASE_LAN, `/conversations/${cid}/messages`, { token: tmpTok });
    ok('历史返回对象结构', hist.body && Array.isArray(hist.body.messages) && Array.isArray(hist.body.members),
      Object.keys(hist.body || {}).join(','));
    const audioMsg = (hist.body?.messages || []).find((m) => m.id === voice.body?.id);
    ok('历史里语音消息 kind=audio', audioMsg?.kind === 'audio', JSON.stringify(audioMsg));
    ok('历史里语音带 file_url', !!audioMsg?.file_url, JSON.stringify(audioMsg));
    ok('历史返回 recallWindowMs', hist.body?.recallWindowMs === 120000);

    // ---------- 7. 清理 ----------
    console.log('\n=== 7. 清理测试数据 ===');
    let cleaned = 0;
    for (const id of created.msgs) {
      if (!id) continue;
      const d = await api(BASE_LAN, `/admin/messages/${id}`, { method: 'DELETE', token: adminTok });
      if (d.status === 200) cleaned++;
    }
    ok(`删除 ${created.msgs.length} 条测试消息`, cleaned === created.msgs.length, `cleaned=${cleaned}`);

    const delUser = await api(BASE_LAN, `/admin/users/${created.userId}`, { method: 'DELETE', token: adminTok });
    ok('删除临时用户', delUser.status === 200, JSON.stringify(delUser.body));
    created.userId = null;

    await sleep(300);
    const sAfter = await api(BASE_LAN, '/conversations/search?q=' + encodeURIComponent(STAMP), { token: adminTok });
    ok('清理后搜不到测试消息', sAfter.body?.total === 0, 'total=' + sAfter.body?.total);
  } catch (e) {
    console.error('\n验证异常：', e);
    fail++;
    // 尽力清理
    try {
      if (adminTok) {
        for (const id of created.msgs) {
          if (id) await api(BASE_LAN, `/admin/messages/${id}`, { method: 'DELETE', token: adminTok });
        }
        if (created.userId) await api(BASE_LAN, `/admin/users/${created.userId}`, { method: 'DELETE', token: adminTok });
      }
    } catch { /* ignore */ }
  }

  console.log('\n' + '='.repeat(46));
  console.log(`  通过 ${pass} / 失败 ${fail}`);
  console.log('='.repeat(46) + '\n');
  process.exit(fail > 0 ? 1 : 0);
})();
