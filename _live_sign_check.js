// 线上真机验收：在**生产库**上发一对凭据、用签名真调一次、然后把测试数据清掉。
//
//   node _live_sign_check.js
//
// 和 e2e 的区别：e2e 打的是临时库起的临时服务；这里打的是 192.168.31.44 上真在跑的那个。
// 补的是"部署没部署对"这条缝 —— 代码推上去了、md5 也对上了，但
// 挂载层级错了 / 容器没真重启 / 库里表没建出来，全都能让功能"看起来上线了其实没有"。
//
// 用完会把自己建的凭据和群删掉，不留测试数据。

const crypto = require('crypto');
const BASE = 'http://192.168.31.44:3602';

const ADMIN_USER = 'admin';
const ADMIN_PASS = process.argv[2] || process.env.XZ_ADMIN_PASS;

let passed = 0, failed = 0; const failures = [];
const ok = (n, c, e) => {
  if (c) { passed++; console.log(`  \u2713 ${n}`); }
  else { failed++; failures.push(n + (e ? ` — ${e}` : '')); console.log(`  \u2717 ${n}${e ? `  → ${e}` : ''}`); }
};

async function api(method, p, { headers, body } = {}) {
  const res = await fetch(BASE + p, {
    method,
    headers: { ...(body != null ? { 'Content-Type': 'application/json' } : {}), ...(headers || {}) },
    // 🔴 body 已经是字符串时**不能再 stringify 一次** —— 那会发出一个 JSON 字符串，
    // 服务端校验不过只回 400 且没 body，看起来像"业务拒绝了"，其实是自己发的就错了。
    body: body == null ? undefined : (typeof body === 'string' ? body : JSON.stringify(body)),
  });
  let j = null; try { j = await res.json(); } catch { /* ignore */ }
  return { status: res.status, body: j };
}

function signed({ appId, secret, method, url, body = '' }) {
  const i = url.indexOf('?');
  const p = i < 0 ? url : url.slice(0, i);
  const q = i < 0 ? '' : url.slice(i + 1);
  const raw = typeof body === 'string' ? body : JSON.stringify(body);
  const ts = String(Math.floor(Date.now() / 1000));
  const nonce = crypto.randomBytes(12).toString('hex');
  const bh = crypto.createHash('sha256').update(Buffer.from(raw, 'utf8')).digest('hex');
  const sign = crypto.createHmac('sha256', secret)
    .update([method.toUpperCase(), p, q, ts, nonce, bh].join('\n')).digest('hex');
  return { 'X-App-Id': appId, 'X-Timestamp': ts, 'X-Nonce': nonce, 'X-Sign': sign };
}

(async () => {
  if (!ADMIN_PASS) { console.error('需要管理员密码：node _live_sign_check.js <密码>'); process.exit(2); }
  console.log('[线上真机验收] ' + BASE + '\n');

  let r = await api('POST', '/api/auth/login', { body: { username: ADMIN_USER, password: ADMIN_PASS } });
  ok('管理员登录线上', !!r.body?.token, JSON.stringify(r.body).slice(0, 120));
  // 🔴 登录失败必须当场停：不然下面全用 undefined 去签名，报的是
  // "key must be of type string" 这种跟真正原因八竿子打不着的错，白查半天。
  if (!r.body?.token) { console.error('\n登录没过，后面全测不了。先确认密码取对了再跑。'); process.exit(1); }
  const ADMIN = { Authorization: 'Bearer ' + r.body.token };

  // 取版本号（服务端 package.json）
  const st = await api('GET', '/api/admin/stats', { headers: ADMIN });
  console.log('  · 线上接口可读，管理员权限正常:', st.status === 200);

  const tag = '验收探针-' + Date.now();
  r = await api('POST', '/api/admin/integrations/bots', { headers: ADMIN, body: { name: tag } });
  const botId = r.body?.id ?? r.body?.bot?.id;
  ok('建临时机器人', !!botId, JSON.stringify(r.body).slice(0, 160));

  r = await api('POST', '/api/admin/groups', { headers: ADMIN, body: { name: tag, member_ids: [botId] } });
  const groupId = r.body?.id;
  // 🔴 这个接口返回的是**群 id**，不是会话 id。空库上两者都从 1 开始，
  // 直接拿来用会撞巧通过；线上库里有历史数据，号一错开就 403。必须回查 conversation_id。
  const gl = await api('GET', '/api/admin/groups?q=' + encodeURIComponent(tag), { headers: ADMIN });
  const convId = (gl.body?.items || []).find((g) => g.id === groupId)?.conversation_id;
  ok('建临时群（取到会话 id，不是群 id）', convId != null,
    JSON.stringify({ groupId, convId }));

  r = await api('POST', '/api/admin/integrations/clients', {
    headers: ADMIN,
    body: { name: tag, userId: botId, scopes: ['conversation:read', 'message:send', 'message:read'] },
  });
  const APP_ID = r.body?.client?.appId, SECRET = r.body?.secret;
  ok('🔴 线上发放凭据成功（app_id + 明文 secret）', !!APP_ID && !!SECRET,
    JSON.stringify(r.body).slice(0, 160));
  const cid = r.body?.client?.id;

  console.log('\n【线上签名调用】');
  const me = '/api/open/me';
  r = await api('GET', me, { headers: signed({ appId: APP_ID, secret: SECRET, method: 'GET', url: me }) });
  ok('🔴 正确签名 → 200', r.status === 200, JSON.stringify(r.body).slice(0, 200));
  ok('  via=sign / appId 对得上', r.body?.via === 'sign' && r.body?.appId === APP_ID,
    JSON.stringify({ via: r.body?.via, appId: r.body?.appId }));

  // 篡改一个字节
  const h = signed({ appId: APP_ID, secret: SECRET, method: 'GET', url: me });
  h['X-Sign'] = h['X-Sign'].slice(0, -1) + (h['X-Sign'].slice(-1) === 'a' ? 'b' : 'a');
  r = await api('GET', me, { headers: h });
  ok('  签名改 1 字节 → 401 bad_sign', r.status === 401 && r.body?.code === 'bad_sign', JSON.stringify(r.body));

  // 同一 nonce 两次
  const h2 = signed({ appId: APP_ID, secret: SECRET, method: 'GET', url: me });
  const a1 = await api('GET', me, { headers: h2 });
  const a2 = await api('GET', me, { headers: h2 });
  ok('  同 nonce 第二次 → 409 nonce_replayed',
    a1.status === 200 && a2.status === 409 && a2.body?.code === 'nonce_replayed',
    `第一次 ${a1.status} / 第二次 ${a2.status} ${JSON.stringify(a2.body)}`);

  // 真发一条消息
  const url = `/api/open/conversations/${convId}/messages`;
  const body = JSON.stringify({ text: '签名通道线上验收 ' + tag });
  r = await api('POST', url, { headers: signed({ appId: APP_ID, secret: SECRET, method: 'POST', url, body }), body });
  ok('🔴 用签名真发出一条消息', r.status === 200 && (r.body?.ok === true || r.body?.id != null),
    `status=${r.status} body=${JSON.stringify(r.body)?.slice(0, 200)}`);

  // 清理
  console.log('\n【清理测试数据】');
  if (cid) await api('DELETE', `/api/admin/integrations/clients/${cid}`, { headers: ADMIN });
  // 机器人删除接口会连带清掉它发的消息；群只能留着（没有删除接口就明说）
  const delBot = await api('DELETE', `/api/admin/integrations/bots/${botId}`, { headers: ADMIN });
  const left = await api('GET', '/api/admin/integrations/clients', { headers: ADMIN });
  ok('临时凭据已删干净', !String(JSON.stringify(left.body)).includes(tag),
    JSON.stringify(left.body).slice(0, 200));
  console.log('  · 删机器人:', delBot.status, '（群 ' + convId + ' 如需清理请在管理台手动删）');

  console.log(`\n[线上真机验收] 通过 ${passed} / 失败 ${failed}`);
  if (failures.length) { console.log('失败项：'); for (const f of failures) console.log('  ✗ ' + f); }
  process.exit(failed ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(1); });
