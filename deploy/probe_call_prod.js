// 生产实例通话信令探测（只读、不写库）
// 用法: node deploy/probe_call_prod.js [baseUrl] [user] [pass]
// 作用: 登录 -> 连 WS -> 发几个"必然失败"的通话帧，看服务端是否回了 call:* 系列帧。
//       如果 call.js 没加载，服务端会回 unknown type，而不是 call:error/call:busy。
const http = require('http');
const path = require('path');
const WebSocket = require(path.join(__dirname, '..', 'server', 'node_modules', 'ws'));

const BASE = process.argv[2] || 'http://192.168.31.44:3602';
const USER = process.argv[3] || 'admin';
const PASS = process.argv[4] || 'admin123';
const WSURL = BASE.replace(/^http/, 'ws') + '/ws';

function post(p, body, token) {
  return new Promise((res, rej) => {
    const data = JSON.stringify(body || {});
    const req = http.request(BASE + p, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(data),
        ...(token ? { Authorization: 'Bearer ' + token } : {}),
      },
    }, r => {
      let b = '';
      r.on('data', c => (b += c));
      r.on('end', () => {
        try { res({ code: r.statusCode, json: JSON.parse(b) }); }
        catch (e) { res({ code: r.statusCode, raw: b }); }
      });
    });
    req.on('error', rej);
    req.write(data);
    req.end();
  });
}

function get(p, token) {
  return new Promise((res, rej) => {
    const req = http.request(BASE + p, {
      method: 'GET',
      headers: { ...(token ? { Authorization: 'Bearer ' + token } : {}) },
    }, r => {
      let b = '';
      r.on('data', c => (b += c));
      r.on('end', () => {
        try { res({ code: r.statusCode, json: JSON.parse(b) }); }
        catch (e) { res({ code: r.statusCode, raw: b }); }
      });
    });
    req.on('error', rej);
    req.end();
  });
}

(async () => {
  const lg = await post('/api/auth/login', { username: USER, password: PASS });
  if (!lg.json || !lg.json.token) {
    console.log('登录失败:', JSON.stringify(lg).slice(0, 300));
    process.exit(1);
  }
  const token = lg.json.token;
  const me = lg.json.user || {};
  console.log('登录成功: %s id=%s', USER, me.id);

  // 取一个真实会话 id：用它发"呼叫自己"的请求，既能走到 call.js 内部逻辑，
  // 又不会真的给别人推来电（不产生任何脏数据）
  let convId = null;
  const cl = await get('/api/conversations', token);
  const list = (cl.json && (cl.json.conversations || cl.json.items || cl.json.list)) || cl.json;
  if (Array.isArray(list) && list.length) convId = list[0].id;
  console.log('会话列表: %d 条，取第一条 id=%s', Array.isArray(list) ? list.length : 0, convId);

  const ws = new WebSocket(WSURL + '?token=' + encodeURIComponent(token));
  const got = [];
  ws.on('open', () => {
    console.log('WS 已连接 ->', WSURL);
    const send = (obj, ms) => setTimeout(() => ws.send(JSON.stringify(obj)), ms);
    // 1) 未知 callId 挂断：应被静默忽略（不回帧）
    send({ type: 'call:end', callId: 'no-such-call-id' }, 300);
    // 2) 缺 conversationId：老版本会甩 SQLite 底层错误，修好后应是中文可读提示
    send({ type: 'call:invite', calleeId: me.id, mode: 'video' }, 800);
    // 3) 真实会话 + 呼叫自己：应回「通话对象不正确」
    if (convId) send({ type: 'call:invite', conversationId: convId, calleeId: me.id, mode: 'video' }, 1300);
  });
  ws.on('message', raw => {
    let m;
    try { m = JSON.parse(raw.toString()); } catch (e) { return; }
    if (['hello', 'ready', 'presence', 'ping', 'pong'].includes(m.type)) return;
    got.push(m);
    console.log('  <-', JSON.stringify(m).slice(0, 220));
  });
  ws.on('error', e => { console.log('WS 错误:', e.message); process.exit(1); });

  setTimeout(() => {
    try { ws.close(); } catch (e) {}
    const errs = got.filter(m => m.type === 'error');
    const msgs = errs.map(m => m.message);
    console.log('\n收到的 error 帧:', JSON.stringify(msgs));

    // 判定标准（不依赖真的打通一通电话，零副作用）：
    //   ① ref 是 call:*  -> 说明 ws.js 已经把通话帧分发给了 call.js（模块生效）
    //   ② 错误消息是中文可读文案，而不是 SQLite 底层报错 -> 参数校验修复已生效
    const routed = errs.some(m => typeof m.ref === 'string' && m.ref.startsWith('call:'));
    const noSqlite = !msgs.some(s => /SQLite|bound/i.test(s || ''));
    const readable = msgs.some(s => /参数不正确|通话对象不正确|会话|不在该会话/.test(s || ''));

    console.log('① 通话帧已路由到 call 模块:', routed ? '是' : '否');
    console.log('② 无 SQLite 底层报错     :', noSqlite ? '是' : '否');
    console.log('③ 返回中文可读错误       :', readable ? '是' : '否');

    const pass = routed && noSqlite && readable;
    console.log('\n结论:', pass
      ? '通话信令已在生产实例生效（call 模块工作正常，参数校验已修复）'
      : '仍有问题，检查服务端是否为 v0.5.0 且 call.js 已部署');
    process.exit(pass ? 0 : 1);
  }, 2600);
})().catch(e => { console.log('异常:', e.message); process.exit(1); });
