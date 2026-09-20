// M4（培训中心）线上只读验收探针
//
//   IM_PASS=<管理台口令> node deploy/_m4_probe.js
//
// 【为什么单独写一个】
// e2e 跑在本地空库上，线上跑在**真库**上。空库能撞巧通过（M3 那次就是：
// 建群接口回错了 id，本地两个号都从 1 开始所以过了，线上一错开就 403）。
// 这个探针只做**读**，不往生产库写任何东西 —— 但要确认线上真的认得出培训模块：
//   ① 模块入口是否随服务端下发 ② 学员/管理端接口是否 200 不是 404
//   ③ 未鉴权是否真的被拦 ④ 部署到线上的管理台产物里有没有新页面
//
// 退出码 0 = 全部通过。
const BASE = process.env.IM_BASE || 'http://192.168.31.44:3602';
const PASS = process.env.IM_PASS || '';

let pass = 0;
const bad = [];
function ok(name, cond, detail) {
  if (cond) { pass++; console.log(`  ✓ ${name}${detail ? ' — ' + detail : ''}`); }
  else { bad.push(name + (detail ? ' — ' + detail : '')); console.log(`  ✗ ${name}${detail ? ' — ' + detail : ''}`); }
}

async function req(path, { method = 'GET', body, token } = {}) {
  const headers = {};
  if (body) headers['Content-Type'] = 'application/json';
  if (token) headers.Authorization = 'Bearer ' + token;
  const r = await fetch(BASE + path, {
    method, headers, body: body ? JSON.stringify(body) : undefined,
  });
  let j = null;
  const txt = await r.text();
  try { j = JSON.parse(txt); } catch { /* 静态资源不是 JSON */ }
  return { status: r.status, body: j, text: txt };
}

(async () => {
  if (!PASS) { console.error('缺少 IM_PASS（管理台口令），从桌面「小智管理台新密码-请勿外传.txt」取'); process.exit(2); }
  console.log(`== 线上只读验收 ${BASE} ==`);

  const h = await req('/api/health');
  ok('健康检查', h.status === 200 && h.body && h.body.ok === true, `status=${h.status}`);

  const lg = await req('/api/auth/login', { method: 'POST', body: { username: 'admin', password: PASS } });
  ok('管理员登录', lg.status === 200 && lg.body && lg.body.token, `status=${lg.status}`);
  const token = lg.body && lg.body.token;
  if (!token) { console.log('\n登录没过，后面全部无意义，停在这里。'); process.exit(1); }

  // ① 模块入口：客户端靠它决定工作台里显不显示「培训中心」
  const apps = await req('/api/client/apps', { token });
  const list = (apps.body && (apps.body.items || apps.body.apps)) || [];
  const tr = Array.isArray(list) ? list.find((a) => a && a.id === 'training') : null;
  ok('客户端应用清单含 training 入口', !!tr,
    tr ? `title=${tr.title} icon=${tr.icon}` : `清单里没有；共 ${Array.isArray(list) ? list.length : '?'} 项，status=${apps.status}`);
  if (tr) ok('  入口名字逐字是「培训中心」', tr.title === '培训中心', `实际 "${tr.title}"`);

  // ② 学员接口（读）
  const c = await req('/api/training/courses', { token });
  ok('GET /api/training/courses → 200', c.status === 200, `status=${c.status}`);
  ok('  返回分页信封（items/total/page/pageSize）',
    !!c.body && Array.isArray(c.body.items) && typeof c.body.total === 'number'
      && typeof c.body.page === 'number' && typeof c.body.pageSize === 'number',
    c.body ? Object.keys(c.body).join(',') : String(c.text).slice(0, 80));

  // ③ 管理端接口（读）
  const ac = await req('/api/training/admin/courses', { token });
  ok('GET /api/training/admin/courses → 200（含草稿）', ac.status === 200, `status=${ac.status}`);
  ok('  返回数组', !!ac.body && Array.isArray(ac.body.items),
    ac.body ? `items=${ac.body.items && ac.body.items.length}` : String(ac.text).slice(0, 80));

  const as = await req('/api/training/admin/sheets', { token });
  ok('GET /api/training/admin/sheets → 200（成绩查询）', as.status === 200, `status=${as.status}`);
  ok('  返回数组', !!as.body && Array.isArray(as.body.items),
    as.body ? `items=${as.body.items && as.body.items.length}` : String(as.text).slice(0, 80));

  // ④ 未鉴权必须被拦（新路由最容易忘记挂鉴权，而本地测试常常是带 token 跑的）
  const noauth = await req('/api/training/admin/courses');
  ok('未鉴权 /api/training/admin/courses → 401', noauth.status === 401, `status=${noauth.status}`);

  // ⑤ 部署到线上的管理台产物里，真的有没有这个页面
  //    （"代码写好了"和"装出来的那份里有"是两件事 —— 2026-09-19 真栽过一次）
  // ⚠️ 资源路径要**照抄 index.html 里的 src**，不能自己拼 `/assets/...`：
  //    静态目录挂在 `/admin` 下，自己拼会拿到 `{"error":"not found"}`（21 字节），
  //    然后看起来像"产物里没有新页面"—— 探针自己错，比被测代码错更常见。
  let html = await req('/admin');
  if (html.status !== 200) html = await req('/admin/');
  ok('管理台页面可达', html.status === 200, `status=${html.status}`);
  const m = /src="([^"]+\.js)"/.exec(html.text || '');
  if (m) {
    const js = await req(m[1]);
    const hit = (js.text || '').includes('培训中心');
    ok(`  线上管理台产物含「培训中心」（${m[1]}）`, hit && js.status === 200,
      `status=${js.status} bundle ${(js.text || '').length} 字节`);
    ok('  线上管理台产物含成绩页文案（未交卷）', (js.text || '').includes('未交卷'), '');
  } else {
    ok('  从 index.html 里找出资源文件名', false, (html.text || '').slice(0, 160));
  }

  console.log('\n' + '='.repeat(52));
  if (bad.length) {
    console.log(`失败 ${bad.length} / 通过 ${pass}`);
    for (const b of bad) console.log('  · ' + b);
    process.exit(1);
  }
  console.log(`通过 ${pass} / ${pass}`);
  console.log('='.repeat(52));
})().catch((e) => { console.error('探针自身异常：', e); process.exit(2); });
