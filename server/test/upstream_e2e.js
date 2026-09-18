// 上游受控转发端到端测试（动态配置与模块 · 第三期）
//
// 这一期的**风险全在安全边界**上：客户端能通过它打到内网服务。所以测试重点不是
// "能不能转发"，而是"**会不会变成一个任意 URL 的跳板**"：
//   ① 鉴权：未登录必须 401（上游回的是经营数据，不能靠一个 URL 拿到）
//   ② 路径逃逸：`..` / 绝对 URL / `//host` 必须被挡（跳不出 base_url）
//   ③ 方法白名单：PUT/DELETE 不许转发（不能拿它去打别人的写接口）
//   ④ 角色白名单：设了 allowRoles 之后普通用户 403、管理员 200
//   ⑤ 凭据只在服务端：authHeader 由服务端注入，**列表接口不回传明文**
//   ⑥ 不提交 authHeader 时**不清空**既有凭据（管理台不回显明文，这是默认行为）
//   ⑦ 幂等：同名重复提交只更新，不新增
//   ⑧ 失败可分辨：没登记/停用/超时 → 502，且文案说清是哪种
//
//   node test/upstream_e2e.js

const { spawn } = require('child_process');
const http = require('http');
const path = require('path');
const fs = require('fs');
const os = require('os');

const PORT = 3697;          // IM 服务端
const UP_PORT = 3703;       // 假上游
const BASE = `http://127.0.0.1:${PORT}`;
const UP_BASE = `http://127.0.0.1:${UP_PORT}`;
const SERVER_DIR = path.resolve(__dirname, '..');
const DATA_DIR = path.join(os.tmpdir(), 'xiaozhi-up-e2e-' + Date.now());

const SECRET = 'Bearer upstream-test-token';

let passed = 0;
let failed = 0;
const failures = [];

function ok(name, cond, extra) {
  if (cond) {
    passed++;
    console.log(`  \u2713 ${name}`);
  } else {
    failed++;
    failures.push(name + (extra ? ` \u2014 ${extra}` : ''));
    console.log(`  \u2717 ${name}${extra ? '  \u2192 ' + extra : ''}`);
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

/** 假上游：故意暴露几个"只有带对凭据才通"的路径，用来验证凭据真的是服务端在给 */
function startFakeUpstream() {
  const srv = http.createServer((req, res) => {
    const u = new URL(req.url, UP_BASE);
    const send = (code, obj) => {
      res.writeHead(code, { 'Content-Type': 'application/json; charset=utf-8' });
      res.end(JSON.stringify(obj));
    };

    if (u.pathname === '/') return send(200, { ok: true, hello: 'upstream' });

    if (u.pathname === '/report/daily') {
      const day = u.searchParams.get('day') || '(未传)';
      // 回一个"表格 + 图表都要用"的形状，验证 data 是原样透传的
      return send(200, {
        ok: true,
        day,
        income: 123.45,
        rows: [
          { item: 'A', qty: 2, amt: 40.6 },
          { item: 'B', qty: 1, amt: 82.85 },
        ],
      });
    }

    // 需要凭据：只有服务端注入的 Authorization 才对
    if (u.pathname === '/guarded') {
      if (req.headers.authorization !== SECRET) {
        return send(401, { error: 'bad auth', got: req.headers.authorization || null });
      }
      return send(200, { ok: true, secret_ok: true });
    }

    // 慢：用来验证超时被识别成"超时"而不是"连不上"
    if (u.pathname === '/slow') {
      setTimeout(() => send(200, { ok: true, late: true }), 4000);
      return;
    }

    // 上游自己回的 404：必须原样透传，不能被当成网关错误
    return send(404, { error: 'upstream says not found' });
  });
  return new Promise((resolve) => srv.listen(UP_PORT, '127.0.0.1', () => resolve(srv)));
}

async function main() {
  fs.mkdirSync(DATA_DIR, { recursive: true });

  const fake = await startFakeUpstream();
  const child = spawn(process.execPath, ['src/index.js'], {
    cwd: SERVER_DIR,
    env: {
      ...process.env,
      PORT: String(PORT),
      DATA_DIR,
      DB_PATH: path.join(DATA_DIR, 'test.db'),
      ADMIN_USERNAME: 'admin',
      ADMIN_PASSWORD: 'admin-test-pw',
    },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  child.stdout.on('data', () => {});
  child.stderr.on('data', (d) => process.stderr.write('[server] ' + d));

  const shutdown = () => {
    try { child.kill(); } catch { /* ignore */ }
    try { fake.close(); } catch { /* ignore */ }
    try { fs.rmSync(DATA_DIR, { recursive: true, force: true }); } catch { /* ignore */ }
  };
  process.on('exit', shutdown);

  let up = false;
  for (let i = 0; i < 60; i++) {
    try {
      const r = await fetch(BASE + '/api/health');
      if (r.ok) { up = true; break; }
    } catch { /* 还没起来 */ }
    await sleep(200);
  }
  if (!up) throw new Error('服务端未能在 12 秒内启动');

  const adminLogin = (await api('POST', '/api/auth/login', {
    body: { username: 'admin', password: 'admin-test-pw' },
  })).body;
  const admin = adminLogin.token;
  ok('管理员登录', !!admin);

  await api('POST', '/api/auth/register', {
    body: { username: 'zhang', password: 'pass123456', nickname: '小张' },
  });
  const user = (await api('POST', '/api/auth/login', {
    body: { username: 'zhang', password: 'pass123456' },
  })).body.token;
  ok('普通用户登录', !!user);

  // ---------------------------------------------------------------
  console.log('\n① 鉴权：上游回的是经营数据，不能靠一个 URL 拿到');
  {
    const r = await fetch(BASE + '/api/hooks/up/anything/x');
    ok('未登录访问 → 401', r.status === 401, `实际 ${r.status}`);
  }

  // ---------------------------------------------------------------
  console.log('\n② 未登记的名字必须被拒（白名单是唯一入口）');
  {
    const r = await api('GET', '/api/hooks/up/not_registered/x', { token: admin });
    ok('未登记 → 502 且文案点明"没有登记"',
      r.status === 502 && /没有登记/.test(r.body?.error || ''), JSON.stringify(r.body));
  }

  // ---------------------------------------------------------------
  console.log('\n③ 登记参数校验：脏配置必须被拦在写入前');
  {
    const bad = [
      ['名字含大写/非法字符（URL 里必须是小写安全字）', { name: 'Bad Name!', baseUrl: UP_BASE }],
      ['名字太短', { name: 'a', baseUrl: UP_BASE }],
      ['baseUrl 不是 http(s)', { name: 'x1', baseUrl: 'ftp://1.2.3.4' }],
      ['baseUrl 缺主机名', { name: 'x2', baseUrl: 'http://' }],
      ['超时越界（太大）', { name: 'x3', baseUrl: UP_BASE, timeoutMs: 999999 }],
      ['超时越界（太小）', { name: 'x4', baseUrl: UP_BASE, timeoutMs: 10 }],
      ['角色名非法', { name: 'x5', baseUrl: UP_BASE, allowRoles: ['管理员'] }],
      ['allowRoles 不是数组', { name: 'x6', baseUrl: UP_BASE, allowRoles: 'admin' }],
    ];
    for (const [label, payload] of bad) {
      const r = await api('POST', '/api/admin/upstreams', { token: admin, body: payload });
      ok(label, r.status === 400, `实际 ${r.status} ${JSON.stringify(r.body)}`);
    }
  }

  // ---------------------------------------------------------------
  console.log('\n④ 登记后转发：数据原样透传（含 query）');
  let upId = null;
  {
    const r = await api('POST', '/api/admin/upstreams', {
      token: admin,
      body: { name: 'report', label: '门店日报（测试）', baseUrl: UP_BASE, timeoutMs: 3000 },
    });
    upId = r.body?.id;
    ok('登记成功', r.status === 200 && !!upId, JSON.stringify(r.body));

    const t = await api('GET', '/api/hooks/up/report/report/daily?day=2026-09-16', { token: admin });
    ok('转发成功且状态 200', t.status === 200, JSON.stringify(t.body));
    ok('query 透传（day=2026-09-16）', t.body?.data?.day === '2026-09-16',
      JSON.stringify(t.body?.data));
    ok('rows 原样到达（表格/图表要用的形状）',
      Array.isArray(t.body?.data?.rows) && t.body.data.rows.length === 2,
      JSON.stringify(t.body?.data?.rows));
    ok('回包带 upstream/status/ms/url（排障要用）',
      t.body?.upstream === 'report' && t.body?.status === 200 && typeof t.body?.ms === 'number'
      && !!t.body?.url);

    // 上游自己回的 404 必须原样透传 —— 不能被网关吞成 502，
    // 否则客户端分不清"这个接口不存在"和"网关坏了"
    const nf = await api('GET', '/api/hooks/up/report/nope', { token: admin });
    ok('上游的 404 原样透传（不是 502）', nf.status === 404, `实际 ${nf.status}`);
  }

  // ---------------------------------------------------------------
  console.log('\n⑤ 路径逃逸：绝不能跳出 base_url 变成任意 URL 跳板');
  {
    const attacks = [
      ['子路径含 ..', '/api/hooks/up/report/..%2F..%2Fadmin'],
      ['子路径是绝对 URL', '/api/hooks/up/report/http://169.254.169.254/latest/meta-data'],
      ['子路径以 // 开头（协议相对）', '/api/hooks/up/report//evil.example.com/x'],
    ];
    for (const [label, p] of attacks) {
      const r = await api('GET', p, { token: admin });
      ok(label + ' → 被拒（502）', r.status === 502 || r.status === 404,
        `实际 ${r.status} ${JSON.stringify(r.body)}`);
    }
    // 直接调模块层的 buildUrl 做断言：路由层 %2F 解码行为随框架版本变，
    // 但"能不能跳出 base_url"这个判据必须稳
    const upstream = require(path.join(SERVER_DIR, 'src', 'upstream.js'));
    const row = { base_url: UP_BASE };
    for (const [label, sub] of [
      ['buildUrl 挡 ..', '../../etc/passwd'],
      ['buildUrl 挡绝对 URL', 'http://evil.example.com/x'],
      ['buildUrl 挡协议相对', '//evil.example.com/x'],
      ['buildUrl 挡前导斜杠+协议相对（先剥斜杠再判就漏了）', '///evil.example.com/x'],
      ['buildUrl 挡编码 ..（上游解码后会跳出去）', '..%2F..%2Fadmin'],
      ['buildUrl 挡双重编码 ..', '%252E%252E%252Fetc'],
      ['buildUrl 挡反斜杠绕路', '..\\..\\etc'],
      ['buildUrl 挡坏编码', '%zz%2F'],
    ]) {
      const r = upstream.buildUrl(row, sub, '');
      ok(label, !!r.error, JSON.stringify(r));
    }
    // 断言不能只证明"坏输入被拒"，还得证明"好输入没被误伤"，
    // 否则把函数改成恒返回 error 也能全绿
    const good = upstream.buildUrl(row, '/a/b', 'k=1');
    ok('buildUrl 正常拼接', good.url === `${UP_BASE}/a/b?k=1`, JSON.stringify(good));
    const good2 = upstream.buildUrl(row, 'a/b/c', '');
    ok('buildUrl 不给前导斜杠也照拼', good2.url === `${UP_BASE}/a/b/c`, JSON.stringify(good2));
    const dotFile = upstream.buildUrl(row, 'report/a..b', '');
    ok('名字里带 .. 但不是独立一段 → 放行（别把正常文件名也毙了）',
      dotFile.url === `${UP_BASE}/report/a..b`, JSON.stringify(dotFile));
  }

  // ---------------------------------------------------------------
  console.log('\n⑥ 方法白名单：不能拿它去打别人的写接口');
  {
    const r = await api('PUT', '/api/hooks/up/report/report/daily', { token: admin });
    ok('PUT → 被拒（502）', r.status === 502 && /只允许/.test(r.body?.error || ''),
      JSON.stringify(r.body));
    const d = await api('DELETE', '/api/hooks/up/report/report/daily', { token: admin });
    ok('DELETE → 被拒（502）', d.status === 502, JSON.stringify(d.body));
  }

  // ---------------------------------------------------------------
  console.log('\n⑦ 凭据由服务端注入（客户端拿不到，也无需知道）');
  {
    // 先登记一条**不带凭据**的上游。顺序很重要：必须在登记之后才能断言 401，
    // 否则 401 会来自"没登记"（502 还没到，先撞上别的东西），断言看着通过其实没验到东西。
    const reg = await api('POST', '/api/admin/upstreams', {
      token: admin, body: { name: 'guarded', baseUrl: UP_BASE },
    });
    ok('登记一条不带凭据的上游', reg.status === 200, JSON.stringify(reg.body));

    const before = await api('GET', '/api/hooks/up/guarded/guarded', { token: admin });
    ok('未配凭据时上游 401（证明凭据不是客户端给的，也没被凭空造出来）',
      before.status === 401, JSON.stringify(before.body));

    const setAuth = await api('POST', '/api/admin/upstreams', {
      token: admin,
      body: { name: 'guarded', authHeader: SECRET },
    });
    ok('补上凭据（这是"只提交 authHeader"的部分更新）', setAuth.status === 200,
      JSON.stringify(setAuth.body));

    const after = await api('GET', '/api/hooks/up/guarded/guarded', { token: admin });
    ok('配了凭据后上游 200（服务端确实注入了 Authorization）',
      after.status === 200 && after.body?.data?.secret_ok === true, JSON.stringify(after.body));

    // 客户端即使自己乱塞 Authorization，也覆盖不了服务端注入的那条
    const spoof = await fetch(BASE + '/api/hooks/up/guarded/guarded', {
      headers: { Authorization: 'Bearer ' + admin },
    });
    ok('带用户 token 请求 guarded 仍走服务端凭据（200）',
      spoof.status === 200, `实际 ${spoof.status}`);

    const list = await api('GET', '/api/admin/upstreams', { token: admin });
    const row = (list.body?.upstreams || []).find((x) => x.name === 'guarded');
    ok('列表只回 hasAuth，不回传凭据明文',
      row && row.hasAuth === true && row.authHeader === undefined
      && !JSON.stringify(list.body).includes('upstream-test-token'),
      JSON.stringify(row));

    // 管理台表单不回显明文，所以"不提交 authHeader"必须是**保持原值**而不是清空。
    // ⚠️ 这条必须确认那次更新真的成功了：若 POST 被 400 掉，凭据确实"还在"，
    //    但原因变成"根本没改"，断言会**假通过**（这正是第一版的漏洞）。
    const rename = await api('POST', '/api/admin/upstreams', {
      token: admin,
      body: { name: 'guarded', label: '改个说明' },
    });
    ok('只提交 label（不带 baseUrl/authHeader）→ 200，部分更新不被拦',
      rename.status === 200, JSON.stringify(rename.body));
    const again = await api('GET', '/api/hooks/up/guarded/guarded', { token: admin });
    ok('只改说明不提交凭据 → 凭据保持（不会被空值清掉）',
      again.status === 200, JSON.stringify(again.body));
    const row2 = ((await api('GET', '/api/admin/upstreams', { token: admin }))
      .body?.upstreams || []).find((x) => x.name === 'guarded');
    ok('说明确实写进去了（证明上面那次更新是真生效，不是被静默拒绝）',
      row2?.label === '改个说明', JSON.stringify(row2));
  }

  // ---------------------------------------------------------------
  console.log('\n⑧ 角色白名单：入口可见性 ≠ 数据权限');
  {
    // 不设 allowRoles：普通用户可读
    const openRead = await api('GET', '/api/hooks/up/report/report/daily', { token: user });
    ok('未设白名单时普通用户可读', openRead.status === 200, `实际 ${openRead.status}`);

    await api('POST', '/api/admin/upstreams', {
      token: admin,
      body: { name: 'report', allowRoles: ['admin'] },
    });
    const denied = await api('GET', '/api/hooks/up/report/report/daily', { token: user });
    ok('设了 allowRoles=[admin] 后普通用户 → 403',
      denied.status === 403, `实际 ${denied.status} ${JSON.stringify(denied.body)}`);

    const allowed = await api('GET', '/api/hooks/up/report/report/daily', { token: admin });
    ok('管理员仍可读', allowed.status === 200, `实际 ${allowed.status}`);

    // 白名单之外的角色**一个都不放**（就算名字看着更"高"也没用，规则只有一套）
    const boss = await api('POST', '/api/auth/register', {
      body: { username: 'boss', password: 'pass123456', nickname: '老板' },
    });
    ok('（准备）再注册一个角色名为 user 的账号', boss.status === 200 || boss.status === 409);
    const bossTok = (await api('POST', '/api/auth/login', {
      body: { username: 'boss', password: 'pass123456' },
    })).body.token;
    const bossRead = await api('GET', '/api/hooks/up/report/report/daily', { token: bossTok });
    ok('白名单外的第二个账号同样 403', bossRead.status === 403, `实际 ${bossRead.status}`);

    // 放开白名单后要立刻恢复可读（改回空数组 = 所有登录用户）
    const clear = await api('POST', '/api/admin/upstreams', {
      token: admin, body: { name: 'report', allowRoles: [] },
    });
    ok('把白名单清空（只提交 allowRoles）→ 200', clear.status === 200,
      JSON.stringify(clear.body));
    const reopened = await api('GET', '/api/hooks/up/report/report/daily', { token: user });
    ok('清空白名单后普通用户恢复可读（不是"设了就再也撤不掉"）',
      reopened.status === 200, `实际 ${reopened.status}`);
  }

  // ---------------------------------------------------------------
  console.log('\n⑨ 失败要能分辨：停用 / 超时 / 连不上');
  {
    const off1 = await api('POST', '/api/admin/upstreams', {
      token: admin, body: { name: 'report', enabled: false },
    });
    ok('只提交 enabled:false → 200（停用按钮不能因为"没带地址"而失败）',
      off1.status === 200, JSON.stringify(off1.body));
    const off = await api('GET', '/api/hooks/up/report/report/daily', { token: admin });
    ok('停用 → 502 且文案说"已停用"',
      off.status === 502 && /已停用/.test(off.body?.error || ''), JSON.stringify(off.body));

    // 停用后即使管理员也读不到（停用是"全局关闸"，与角色白名单不是一回事）
    const offUser = await api('GET', '/api/hooks/up/report/report/daily', { token: user });
    ok('停用对所有角色一视同仁（普通用户也 502 已停用）',
      offUser.status === 502 && /已停用/.test(offUser.body?.error || ''),
      JSON.stringify(offUser.body));

    const on1 = await api('POST', '/api/admin/upstreams', {
      token: admin, body: { name: 'report', enabled: true },
    });
    ok('恢复启用 → 200', on1.status === 200, JSON.stringify(on1.body));
    const back = await api('GET', '/api/hooks/up/report/report/daily', { token: admin });
    ok('恢复启用后立刻又通（状态真的落库了，不是内存标记）',
      back.status === 200, `实际 ${back.status}`);

    // 超时：上游 4 秒才回，配 1 秒超时
    await api('POST', '/api/admin/upstreams', {
      token: admin, body: { name: 'slowone', baseUrl: UP_BASE, timeoutMs: 1000 },
    });
    const slow = await api('GET', '/api/hooks/up/slowone/slow', { token: admin });
    ok('超时 → 502 且文案说"超时"（不是"连不上"）',
      slow.status === 502 && /超时/.test(slow.body?.error || ''), JSON.stringify(slow.body));

    // 连不上：指向一个没人监听的端口
    await api('POST', '/api/admin/upstreams', {
      token: admin, body: { name: 'deadone', baseUrl: 'http://127.0.0.1:9', timeoutMs: 2000 },
    });
    const dead = await api('GET', '/api/hooks/up/deadone/x', { token: admin });
    ok('连不上 → 502 且文案说"连不上"',
      dead.status === 502 && /连不上/.test(dead.body?.error || ''), JSON.stringify(dead.body));
  }

  // ---------------------------------------------------------------
  console.log('\n⑩ 幂等与 CRUD');
  {
    const l1 = await api('GET', '/api/admin/upstreams', { token: admin });
    const cnt1 = l1.body.upstreams.length;
    await api('POST', '/api/admin/upstreams', {
      token: admin, body: { name: 'report', label: '再点一次保存' },
    });
    const l2 = await api('GET', '/api/admin/upstreams', { token: admin });
    ok('同名重复提交只更新、不新增', l2.body.upstreams.length === cnt1,
      `${cnt1} → ${l2.body.upstreams.length}`);

    const probe = await api('POST', `/api/admin/upstreams/${upId}/probe`, { token: admin });
    ok('探活能通（配完点一下就知道对不对）',
      probe.status === 200 && probe.body?.reachable === true, JSON.stringify(probe.body));

    const t = await api('POST', `/api/admin/upstreams/${upId}/test`, {
      token: admin, body: { subPath: 'report/daily?day=2026-09-15' },
    });
    ok('管理台直连试跑拿到真实数据',
      t.status === 200 && t.body?.data?.income === 123.45, JSON.stringify(t.body));

    // 管理台"试跑"看到的形状必须和客户端实际收到的一模一样：
    // 管理员就是照着试跑结果去填 dataPath（data.rows）的，两边字段集一旦漂移，
    // 就会出现"照着看到填的却取不到数"，且每一步看着都对，极难查。
    const viaClient = await api('GET', '/api/hooks/up/report/report/daily?day=2026-09-15',
      { token: admin });
    const keysOf = (o) => Object.keys(o || {}).sort().join(',');
    ok('试跑与客户端回包字段集逐字一致（dataPath 不会因端而异取不到数）',
      keysOf(t.body) === keysOf(viaClient.body),
      `试跑 ${keysOf(t.body)} vs 客户端 ${keysOf(viaClient.body)}`);
    ok('dataPath 约定成立：data.rows 取得到数组（内置模板写的就是 data.rows）',
      Array.isArray(viaClient.body?.data?.rows), JSON.stringify(viaClient.body?.data));

    const del = await api('DELETE', `/api/admin/upstreams/${upId}`, { token: admin });
    ok('删除成功', del.status === 200, JSON.stringify(del.body));
    const gone = await api('GET', '/api/hooks/up/report/report/daily', { token: admin });
    ok('删除后立即失效（502 没有登记）',
      gone.status === 502, `实际 ${gone.status}`);

    const forbidden = await api('GET', '/api/admin/upstreams', { token: user });
    ok('非管理员看不到上游清单 → 403', forbidden.status === 403 || forbidden.status === 401,
      `实际 ${forbidden.status}`);
  }

  // ---------------------------------------------------------------
  console.log('\n' + '='.repeat(52));
  console.log(`通过 ${passed} / ${passed + failed}`);
  if (failed) {
    console.log('\n失败项：');
    failures.forEach((f) => console.log('  - ' + f));
  }
  shutdown();
  process.exit(failed ? 1 : 0);
}

main().catch((e) => {
  console.error('测试异常：', e);
  process.exit(1);
});
