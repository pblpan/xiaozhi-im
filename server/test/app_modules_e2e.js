// 动态模块端到端测试（SPEC-动态配置与模块.md 第二期）
//
// 这一期的风险集中在"服务端下发的 schema 会不会把客户端搞崩 / 变成 SSRF 跳板"，
// 所以测试的重点不是 CRUD 通不通，而是**非法配置必须被服务端拦下**：
//   ① schema 校验：未知组件 / 非法颜色 / 非 hooks 路径 / http 的 openUrl /
//      嵌套超限 / 组件数超限 / 非法 moduleId / 非法表单类型 / navigate 非内置页
//   ② 管理台 CRUD + 鉴权（401/403）
//   ③ 下发过滤：enabled / minClientVersion / visibleTo(roles|userIds)
//   ④ bootstrap 只能给"对所有人可见"的模块（免鉴权接口不能泄露定向关系）
//   ⑤ 提交闭环：正常提交 / 缺必填 / 类型错 / 伪造字段被丢弃 / 管理台可查
//
//   node test/app_modules_e2e.js

const { spawn } = require('child_process');
const path = require('path');
const fs = require('fs');
const os = require('os');

const PORT = 3696;
const BASE = `http://127.0.0.1:${PORT}`;
const SERVER_DIR = path.resolve(__dirname, '..');
const DATA_DIR = path.join(os.tmpdir(), 'xiaozhi-am-e2e-' + Date.now());

let passed = 0;
let failed = 0;
const failures = [];

function ok(name, cond, extra) {
  if (cond) {
    passed++;
    console.log(`  \u2713 ${name}`);
  } else {
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

/** 一个最小合法模块 */
function mod(over = {}) {
  return {
    moduleId: 'demo_mod',
    title: '演示模块',
    icon: 'dashboard',
    enabled: true,
    sort: 0,
    minClientVersion: null,
    visibleTo: { roles: [], userIds: [] },
    body: [{ component: 'text', text: 'hello', color: 'muted' }],
    ...over,
  };
}

async function main() {
  fs.mkdirSync(DATA_DIR, { recursive: true });
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

  // ---- 准备：管理员 + 普通用户 ----
  const adminLogin = (await api('POST', '/api/auth/login', {
    body: { username: 'admin', password: 'admin-test-pw' },
  })).body;
  const admin = adminLogin.token;
  ok('管理员登录', !!admin);

  await api('POST', '/api/auth/register', { body: { username: 'zhang', password: 'pass123456', nickname: '小张' } });
  const userLogin = (await api('POST', '/api/auth/login', {
    body: { username: 'zhang', password: 'pass123456' },
  })).body;
  const user = userLogin.token;
  const userId = userLogin.user?.id;
  ok('普通用户登录并拿到 uid', !!user && Number.isInteger(userId), `uid=${userId}`);

  console.log('\n① schema 校验：非法配置必须被服务端拦下');
  const bad = [
    ['未知组件类型', mod({ body: [{ component: 'video', src: 'x' }] })],
    ['组件缺 component 字段', mod({ body: [{ text: 'x' }] })],
    ['text 缺 text', mod({ body: [{ component: 'text' }] })],
    ['text 的 size 越界', mod({ body: [{ component: 'text', text: 'x', size: 999 }] })],
    ['颜色写死色值（破坏深色主题）', mod({ body: [{ component: 'text', text: 'x', color: '#ff0000' }] })],
    ['card 缺 children', mod({ body: [{ component: 'card', title: 'x' }] })],
    ['card 嵌套超限', mod({ body: [{ component: 'card', children: [
      { component: 'card', children: [{ component: 'card', children: [
        { component: 'card', children: [{ component: 'card', children: [] }] }] }] }] }] })],
    ['form 字段类型非法', mod({ body: [{ component: 'form', fields: [{ key: 'a', label: 'A', type: 'file' }] }] })],
    ['form 字段名非法', mod({ body: [{ component: 'form', fields: [{ key: '1 bad!', label: 'A', type: 'text' }] }] })],
    ['select 缺 options', mod({ body: [{ component: 'form', fields: [{ key: 'a', label: 'A', type: 'select' }] }] })],
    ['action 缺 label', mod({ body: [{ component: 'action', onTap: { action: 'copy', text: 'x' } }] })],
    ['onLoad 指向非 hooks 路径（SSRF）', mod({ onLoad: { action: 'api', path: 'http://169.254.169.254/latest/meta-data' } })],
    ['submit 指向内网地址（SSRF）', mod({ body: [{ component: 'form',
      fields: [{ key: 'a', label: 'A', type: 'text' }],
      submit: { action: 'api', method: 'POST', path: '/api/admin/users' } }] })],
    ['openUrl 用 http（可被劫持）', mod({ body: [{ component: 'action', label: 'go', onTap: { action: 'openUrl', url: 'http://evil.com' } }] })],
    ['navigate 跳非内置页', mod({ body: [{ component: 'action', label: 'go', onTap: { action: 'navigate', page: 'anything' } }] })],
    ['未知动作类型', mod({ body: [{ component: 'action', label: 'go', onTap: { action: 'eval', code: 'x' } }] })],
    ['moduleId 非法', mod({ moduleId: 'Bad-Id! ' })],
    ['minClientVersion 格式错', mod({ minClientVersion: 'v1' })],
    ['dataPath 含非法字符', mod({ body: [{ component: 'list', dataPath: 'a$(rm -rf)', itemTemplate: { title: 'x' } }] })],
    ['list 缺 itemTemplate.title', mod({ body: [{ component: 'list', dataPath: 'data.items', itemTemplate: { subtitle: 'x' } }] })],
    ['table 缺 columns', mod({ body: [{ component: 'table', dataPath: 'data.rows' }] })],
    ['chart kind 非法', mod({ body: [{ component: 'chart', dataPath: 'data.rows', kind: 'pie' }] })],
    ['body 不是数组', mod({ body: { component: 'text', text: 'x' } })],
  ];
  for (const [name, payload] of bad) {
    const r = await api('POST', '/api/admin/modules', { token: admin, body: payload });
    ok(`拒绝：${name}`, r.status === 400, `实际 ${r.status} ${JSON.stringify(r.body).slice(0, 90)}`);
  }
  const emptyAfterBad = (await api('GET', '/api/admin/modules', { token: admin })).body;
  ok('以上全部被拒后库里仍无模块（没有脏数据落库）',
    Array.isArray(emptyAfterBad?.modules) && emptyAfterBad.modules.length === 0,
    `实际 ${emptyAfterBad?.modules?.length}`);

  console.log('\n② 合法模块：8 种组件 + 未知图标/未知字段的宽容处理');
  const all8 = mod({
    moduleId: 'all_components',
    title: '八组件',
    icon: 'inventory',
    body: [
      { component: 'text', text: '标题', size: 18, color: 'primary', align: 'center' },
      { component: 'divider' },
      { component: 'card', title: '卡片', subtitle: '子标题', accent: 'warning',
        children: [{ component: 'text', text: '卡内文字', color: 'muted' }] },
      { component: 'list', dataPath: 'data.items',
        itemTemplate: { title: '{{name}}', subtitle: '{{desc}}', trailing: '{{qty}}' } },
      { component: 'table', dataPath: 'data.rows',
        columns: [{ key: 'name', label: '名称', width: 120 }, { key: 'qty', label: '数量' }] },
      { component: 'chart', dataPath: 'data.rows', xKey: 'name', yKey: 'qty', kind: 'bar' },
      { component: 'action', label: '刷新', color: 'primary',
        onTap: { action: 'api', path: '/api/hooks/demo/refresh', method: 'GET' } },
      { component: 'form',
        fields: [{ key: 'device', label: '设备名称', type: 'text', required: true }],
        submit: { action: 'api', method: 'POST', path: '/api/hooks/demo/create' } },
    ],
  });
  const r8 = await api('POST', '/api/admin/modules', { token: admin, body: all8 });
  ok('8 种组件全部通过校验', r8.status === 200, `实际 ${r8.status} ${JSON.stringify(r8.body).slice(0, 120)}`);
  ok('下发时保留 8 个顶层组件', r8.body?.module?.body?.length === 8, `实际 ${r8.body?.module?.body?.length}`);
  ok('card 内子组件被递归保留', r8.body?.module?.body?.[2]?.children?.length === 1);
  ok('table 的 width 缺失时被设为 undefined（不写死默认值）',
    r8.body?.module?.body?.[4]?.columns?.[1]?.width === undefined);

  const iconMod = await api('POST', '/api/admin/modules', { token: admin, body: mod({
    moduleId: 'icon_fallback', title: '图标回落', icon: 'not_a_real_icon',
  }) });
  ok('未知图标回落到默认图标（客户端不会因图标名崩）',
    iconMod.status === 200 && iconMod.body?.module?.icon === 'dashboard',
    `实际 ${iconMod.body?.module?.icon}`);

  const extraField = await api('POST', '/api/admin/modules', { token: admin, body: mod({
    moduleId: 'extra_field', title: '多余字段', body: [{ component: 'text', text: 'x', futureField: 123 }],
  }) });
  ok('组件里的未知字段被丢弃（不往下发）',
    extraField.status === 200 && !('futureField' in (extraField.body?.module?.body?.[0] || {})));

  console.log('\n③ 管理台鉴权');
  const m0 = await api('GET', '/api/admin/modules');
  ok('未登录读模块 → 401', m0.status === 401, `实际 ${m0.status}`);
  const m1 = await api('GET', '/api/admin/modules', { token: user });
  ok('普通用户读模块 → 403', m1.status === 403, `实际 ${m1.status}`);
  const m2 = await api('GET', '/api/admin/modules', { token: admin });
  ok('管理员读到模块清单', m2.status === 200 && m2.body.modules.length === 3, `实际 ${m2.body?.modules?.length}`);
  ok('返回能力清单（组件/颜色/图标/动作），供管理台渲染编辑器',
    Array.isArray(m2.body?.capability?.components) && m2.body.capability.components.length === 8
    && Array.isArray(m2.body.capability.icons) && Array.isArray(m2.body.capability.navPages));
  const p0 = await api('POST', '/api/admin/modules', { token: user, body: mod({ moduleId: 'hack' }) });
  ok('普通用户建模块 → 403', p0.status === 403, `实际 ${p0.status}`);

  console.log('\n④ 下发过滤：enabled / 版本 / 可见性');
  // 三个模块：全员可见 / 仅 admin 角色 / 仅指定用户 / 停用 / 要求高版本
  await api('POST', '/api/admin/modules', { token: admin, body: mod({
    moduleId: 'for_admin', title: '仅管理员', visibleTo: { roles: ['admin'], userIds: [] },
  }) });
  await api('POST', '/api/admin/modules', { token: admin, body: mod({
    moduleId: 'for_zhang', title: '仅小张', visibleTo: { roles: [], userIds: [userId] },
  }) });
  await api('POST', '/api/admin/modules', { token: admin, body: mod({
    moduleId: 'disabled_one', title: '已停用', enabled: false,
  }) });
  await api('POST', '/api/admin/modules', { token: admin, body: mod({
    moduleId: 'need_new', title: '要新版', minClientVersion: '9.9.9',
  }) });

  const cfgUser = await api('GET', '/api/client/config?clientVersion=0.9.0', { token: user });
  const ids = (cfgUser.body?.modules || []).map((m) => m.moduleId);
  ok('普通用户看得到全员模块', ids.includes('all_components'), `实际 ${ids.join(',')}`);
  ok('普通用户看不到仅管理员模块', !ids.includes('for_admin'));
  ok('普通用户看得到"仅指定用户"（自己）', ids.includes('for_zhang'), `uid=${userId}`);
  ok('停用的模块不下发', !ids.includes('disabled_one'));
  ok('客户端版本低于 minClientVersion → 整体忽略', !ids.includes('need_new'));

  const cfgAdmin = await api('GET', '/api/client/config?clientVersion=0.9.0', { token: admin });
  const aids = (cfgAdmin.body?.modules || []).map((m) => m.moduleId);
  ok('管理员看得到仅管理员模块', aids.includes('for_admin'));
  ok('管理员看不到"仅指定用户(小张)"的模块', !aids.includes('for_zhang'));

  const cfgNew = await api('GET', '/api/client/config?clientVersion=9.9.9', { token: user });
  ok('客户端版本足够时下发高版本模块',
    (cfgNew.body?.modules || []).map((m) => m.moduleId).includes('need_new'));

  const cfgNoVer = await api('GET', '/api/client/config', { token: user });
  ok('不传 clientVersion 时高版本模块被忽略（版本不合法=不满足，宁可不给）',
    !(cfgNoVer.body?.modules || []).map((m) => m.moduleId).includes('need_new'));

  console.log('\n⑤ bootstrap 的免鉴权红线');
  const bs = await api('GET', '/api/client/bootstrap?clientVersion=0.9.0');
  const bsIds = (bs.body?.modules || []).map((m) => m.moduleId);
  ok('bootstrap 免鉴权可访问', bs.status === 200);
  ok('bootstrap 只下发"对所有人可见"的模块', bsIds.includes('all_components') && bsIds.includes('icon_fallback'));
  ok('bootstrap 不含仅管理员模块（否则泄露权限结构）', !bsIds.includes('for_admin'));
  ok('bootstrap 不含仅指定用户模块（否则泄露"谁能看"）', !bsIds.includes('for_zhang'));
  ok('bootstrap 不含停用模块', !bsIds.includes('disabled_one'));

  console.log('\n⑥ 客户端模块访问与提交闭环');
  const g1 = await api('GET', '/api/client/modules/all_components?clientVersion=0.9.0', { token: user });
  ok('用户能取到自己可见的模块定义', g1.status === 200 && g1.body?.module?.moduleId === 'all_components');
  const g2 = await api('GET', '/api/client/modules/for_admin?clientVersion=0.9.0', { token: user });
  ok('取无权模块 → 403', g2.status === 403, `实际 ${g2.status}`);
  const g3 = await api('GET', '/api/client/modules/not_exist?clientVersion=0.9.0', { token: user });
  ok('取不存在模块 → 404', g3.status === 404, `实际 ${g3.status}`);
  const g4 = await api('GET', '/api/client/modules/all_components?clientVersion=0.9.0');
  ok('未登录取模块 → 401', g4.status === 401, `实际 ${g4.status}`);

  // 提交：模块 all_components 的表单有必填 device 字段
  const s1 = await api('POST', '/api/client/modules/all_components/submit', {
    token: user, body: { clientVersion: '0.9.0', data: { device: '3 号机' } },
  });
  ok('正常提交成功', s1.status === 200 && s1.body?.ok === true, `实际 ${s1.status} ${JSON.stringify(s1.body)}`);
  const s2 = await api('POST', '/api/client/modules/all_components/submit', {
    token: user, body: { clientVersion: '0.9.0', data: {} },
  });
  ok('缺必填字段 → 400 且提示字段名',
    s2.status === 400 && /请填写/.test(s2.body?.error || ''), `实际 ${JSON.stringify(s2.body)}`);
  const s3 = await api('POST', '/api/client/modules/all_components/submit', {
    token: user, body: { clientVersion: '0.9.0', data: { device: 'x', isAdmin: true, role: 'admin' } },
  });
  ok('伪造字段（isAdmin/role）能提交但会被白名单丢弃', s3.status === 200, `实际 ${JSON.stringify(s3.body)}`);
  const subs = await api('GET', '/api/admin/modules/all_components/submissions', { token: admin });
  const first = subs.body?.items?.[0] || {};
  ok('管理台能查到提交记录', subs.status === 200 && subs.body.items.length === 2,
    `实际 ${subs.body?.items?.length}`);
  ok('提交数据里没有伪造的 isAdmin/role 字段',
    !('isAdmin' in (first.data || {})) && !('role' in (first.data || {})),
    `实际 ${JSON.stringify(first.data)}`);
  ok('提交记录带提交人昵称', !!first.nickname, `实际 ${first.nickname}`);

  const s4 = await api('POST', '/api/client/modules/for_admin/submit', {
    token: user, body: { clientVersion: '0.9.0', data: { device: 'x' } },
  });
  ok('向无权模块提交 → 403（不是 400，避免探测模块是否存在）', s4.status === 403, `实际 ${s4.status}`);

  console.log('\n⑦ 更新与删除');
  const upd = await api('POST', '/api/admin/modules', { token: admin, body: mod({
    moduleId: 'all_components', title: '八组件（改标题）', body: [{ component: 'text', text: 'only one' }],
  }) });
  ok('同 moduleId 再提交 = 更新（不产生重复）',
    upd.status === 200 && upd.body?.module?.title === '八组件（改标题）' && upd.body.module.body.length === 1);
  const cnt = (await api('GET', '/api/admin/modules', { token: admin })).body.modules.length;
  ok('更新后模块总数不变（仍是 7 个）', cnt === 7, `实际 ${cnt}`);
  const del = await api('DELETE', '/api/admin/modules/extra_field', { token: admin });
  ok('删除模块成功', del.status === 200 && del.body.ok === true);
  const del2 = await api('DELETE', '/api/admin/modules/extra_field', { token: admin });
  ok('删除不存在的模块 → 404', del2.status === 404);
  const cnt2 = (await api('GET', '/api/admin/modules', { token: admin })).body.modules.length;
  ok('删除后数量减一', cnt2 === 6, `实际 ${cnt2}`);
  const delU = await api('DELETE', '/api/admin/modules/all_components', { token: user });
  ok('普通用户删模块 → 403', delU.status === 403, `实际 ${delU.status}`);

  console.log('\n⑧ 模板库（服务端与校验规则同源，模板本身必须合法）');
  const cap = (await api('GET', '/api/admin/modules', { token: admin })).body.capability;
  ok('能力清单里带模板库', Array.isArray(cap?.templates) && cap.templates.length >= 4,
    `实际 ${cap?.templates?.length}`);
  ok('每个模板都带 id/name/desc/module 四要素',
    cap.templates.every((t) => t.id && t.name && t.desc && t.module));

  for (const t of cap.templates) {
    const r = await api('POST', '/api/admin/modules', { token: admin, body: t.module });
    ok(`模板「${t.name}」能通过服务端校验并落库`, r.status === 200,
      `实际 ${r.status} ${JSON.stringify(r.body).slice(0, 100)}`);
  }
  const listed = (await api('GET', '/api/admin/modules', { token: admin })).body.modules
    .map((m) => m.moduleId);
  ok('模板模块已入库', listed.includes('device_repair') && listed.includes('sales_board'),
    listed.join(','));
  const dr = (await api('GET', '/api/admin/modules', { token: admin })).body.modules
    .find((m) => m.moduleId === 'device_repair');
  ok('设备报修模板含 1 个表单 + 1 段说明', dr?.body?.length === 2
    && dr.body[1].component === 'form' && dr.body[1].fields.length === 5);

  // 走一遍"管理台建模块 → App 不重装看到 → 提交"的验收路径
  const accCfg = await api('GET', '/api/client/config?clientVersion=0.9.0', { token: user });
  const accMod = (accCfg.body?.modules || []).find((m) => m.moduleId === 'device_repair');
  ok('验收：客户端刷新即可看到新入口（无需重装）', !!accMod, `看到 ${accCfg.body?.modules?.length} 个`);
  const accSub = await api('POST', '/api/client/modules/device_repair/submit', {
    token: user,
    body: { clientVersion: '0.9.0', data: { device: '3 号包装机', level: 'high', desc: '异响' } },
  });
  ok('验收：表单能提交成功', accSub.status === 200 && accSub.body?.ok === true,
    JSON.stringify(accSub.body));
  const accList = await api('GET', '/api/admin/modules/device_repair/submissions', { token: admin });
  const accRow = accList.body?.items?.[0] || {};
  ok('验收：管理台能看到这条提交（含提交人与内容）',
    accRow.data?.device === '3 号包装机' && accRow.data?.level === 'high' && !!accRow.nickname,
    JSON.stringify(accRow));

  // ---- 汇总 ----
  console.log(`\n${'='.repeat(50)}`);
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
