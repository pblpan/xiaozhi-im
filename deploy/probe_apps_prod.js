// 生产只读探针：核对 /api/client/apps 对**不同角色**分别下发哪些内置应用。
//
// 为什么要有这个探针：
//   「管理员工作台少两个入口」这种问题在源码里看不出来 —— apps.js 的 listFor
//   只是**纯函数**，真正说话的是线上那台机器在拿到真实 role / org_id 之后的输出。
//   本地 e2e 用临时库跑绿了，也不代表现场那个 role=admin、org_id 为空的账号
//   拿到的是同一份清单。所以改完必须打线上问一次。
//
// 用法（JWT_SECRET 从生产 docker/.env 取，本仓库 Public，凭据一律不进源码）：
//     XZ_SECRET=<JWT_SECRET> node deploy/probe_apps_prod.js [BASE] [uid:role ...]
//     默认 BASE = http://192.168.31.44:3602
//     默认探测 1:admin（管理员）、10001:user（员工）
//
// 只发 GET，不改任何数据。
const crypto = require('crypto');

const DEFAULT_BASE = 'http://192.168.31.44:3602';
// 位置参数里 BASE 可以省略：凡是没带 '://' 的都当成 uid:role。
// （踩过：参数顺序按「BASE 在前」写死，结果 `probe 2:admin` 把 uid 当成了主机名，
//   报的是 "Failed to parse URL from 2:admin/..."，看着像探针坏了、其实是入参。）
const _args = process.argv.slice(2);
const BASE = _args.find((a) => a.includes('://')) || DEFAULT_BASE;
const SECRET = process.env.XZ_SECRET || '';
const WHO = _args.filter((a) => !a.includes('://'));
if (!WHO.length) WHO.push('1:admin', '10001:user');

if (!SECRET) {
  console.error('缺 XZ_SECRET（生产 JWT_SECRET，见 docker/.env）');
  process.exit(2);
}

function b64url(buf) {
  return Buffer.from(buf).toString('base64')
    .replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}
function mintToken(uid, role) {
  const now = Math.floor(Date.now() / 1000);
  const head = b64url(JSON.stringify({ alg: 'HS256', typ: 'JWT' }));
  const body = b64url(JSON.stringify({ uid, role, iat: now, exp: now + 30 * 86400 }));
  return head + '.' + body + '.' +
    b64url(crypto.createHmac('sha256', SECRET).update(head + '.' + body).digest());
}

let failed = 0;
const ok = (name, cond, extra) => {
  console.log((cond ? '  ✓ ' : '  ✗ ') + name + (cond || !extra ? '' : '  → ' + extra));
  if (!cond) failed++;
};

(async () => {
  const seen = {};
  const ovSeen = {};
  for (const w of WHO) {
    const [uid, role] = w.split(':');
    const token = mintToken(Number(uid), role || 'user');
    const r = await fetch(BASE + '/api/client/apps', {
      headers: { Authorization: 'Bearer ' + token, 'Content-Type': 'application/json' },
    });
    let j = null;
    try { j = await r.json(); } catch { /* 非 JSON */ }
    // ⚠️ 响应体是 { apps: [内置..., 动态...], groups, workMode }——
    //    内置项靠 kind==='builtin' 挑出来。别拿 `builtin` 当字段名去取
    //    （踩过：取到 undefined，两个角色都"空工作台"，看着像服务端没下发，
    //     其实是探针读错了字段）。
    const all = ((j && j.apps) || []);
    const builtin = all.filter((a) => a.kind === 'builtin');
    const dynamic = all.filter((a) => a.kind !== 'builtin');
    const ids = builtin.map((a) => a.id);
    const badges = builtin.filter((a) => a.badge).map((a) => a.id + '=' + a.badge);
    console.log(`\n== uid=${uid} role=${role}  HTTP ${r.status}`);
    console.log('   内置应用: ' + (ids.length ? ids.join(', ') : '(空)'));
    if (dynamic.length) console.log('   动态模块: ' + dynamic.map((a) => a.id).join(', '));
    if (badges.length) console.log('   角标: ' + badges.join(', '));
    console.log('   工作模式: ' + (j && j.workMode));
    for (const a of builtin) console.log(`     - ${a.id}  ${a.title}  (${a.group})`);
    seen[role + ':' + uid] = ids;

    // 入口可见 ≠ 点进去能用。管理员那个「考勤记录」页拉的是管理端接口
    // （/api/admin/attendance/overview，adminGuard 把关），所以可见性对了之后
    // 还必须确认**同一条 token 真能读到数据** —— 否则就是"入口在、点进去 403"。
    if (ids.includes('att_admin')) {
      const r2 = await fetch(BASE + '/api/admin/attendance/overview', {
        headers: { Authorization: 'Bearer ' + token, 'Content-Type': 'application/json' },
      });
      let j2 = null;
      try { j2 = await r2.json(); } catch { /* 非 JSON */ }
      const stats = (j2 && j2.stats) || {};
      const items = (j2 && j2.items) || [];
      console.log(`   看板接口 HTTP ${r2.status}  stats.total=${stats.total} ` +
        `present=${stats.present} missing=${stats.missing}  员工数=${items.length}`);
      // 卡片字段集必须和 punchView() 一致（尤其 done）。踩过：overview 漏发 done，
      // 于是"已经打过的卡"在管理员看板上显示成"缺" —— 员工页正常、看板不对，
      // 最容易怀疑到判定引擎上去。线上必须真验一次。
      const NEED = ['key', 'type', 'slot', 'label', 'expectTime', 'expectAt',
                    'time', 'at', 'done', 'due', 'exempt', 'status',
                    'lateMinutes', 'earlyMinutes'];
      const punches = items.flatMap((i) => i.punches || []);
      const missKeys = NEED.filter((k) => punches.some((p) => !(k in p)));
      const badDone = punches.filter((p) => p.done !== (p.time != null));
      const doneCnt = punches.filter((p) => p.done === true).length;
      // v0.15.2 卡名口径：不许再出现"午休"这类时段词（那套叫法只对早班成立），
      // 并且同一人一天里每张卡的「卡名+应打时刻」必须互不相同 ——
      // 名字统一成"上班/下班"之后，不给时刻就分不清补的是哪一张。
      const badLabel = punches.filter((p) => /午休|晚餐|中休|中午/.test(p.label || ''));
      const dupCard = items.filter((i) => {
        const u = (i.punches || []).map((p) => `${p.label}@${p.expectTime}`);
        return new Set(u).size !== u.length;
      });
      console.log(`   卡片 ${punches.length} 张（已打 ${doneCnt} 张）  缺字段: ` +
        (missKeys.length ? missKeys.join(',') : '无') +
        `  done/time 不一致: ${badDone.length}` +
        `  带时段词的卡名: ${badLabel.length}  有同名同刻的卡: ${dupCard.length} 人`);
      ovSeen[uid] = {
        status: r2.status, total: stats.total, items: items.length,
        punches: punches.length, doneCnt, missKeys: missKeys.length,
        badDone: badDone.length, badLabel: badLabel.length, dupCard: dupCard.length,
      };
    }
  }

  console.log('\n== 断言');
  const admins = Object.entries(seen).filter(([k]) => k.startsWith('admin:'));
  const users = Object.entries(seen).filter(([k]) => k.startsWith('user:'));
  for (const [k, ids] of admins) {
    ok(`${k} 能看到 att_admin（考勤记录）`, ids.includes('att_admin'), ids.join(','));
    ok(`${k} 看不到 attendance（管理员不打卡）`, !ids.includes('attendance'), ids.join(','));
    ok(`${k} 看不到 my_requests`, !ids.includes('my_requests'), ids.join(','));
  }
  for (const [uid, r] of Object.entries(ovSeen)) {
    ok(`uid=${uid} 看板接口可用（HTTP 200 且有 items）`,
      r.status === 200 && r.items > 0,
      `HTTP ${r.status}, items=${r.items}`);
    ok(`uid=${uid} 看板的卡带齐字段（含 done）`,
      r.punches > 0 && r.missKeys === 0,
      `卡片 ${r.punches} 张，缺 ${r.missKeys} 种字段`);
    ok(`uid=${uid} done 与 time 一致（打过的卡不会显示成"缺"）`,
      r.badDone === 0, `${r.badDone} 张不一致`);
    ok(`uid=${uid} 卡名不含时段词（早班晚班都能用）`,
      r.badLabel === 0, `${r.badLabel} 张还带着"午休/晚餐"这类词`);
    ok(`uid=${uid} 每张卡的「卡名+应打时刻」互不相同（补卡按钮分得清）`,
      r.dupCard === 0, `${r.dupCard} 人有同名同刻的卡`);
  }
  for (const [k, ids] of users) {
    ok(`${k} 看不到 att_admin（员工专属不该有）`, !ids.includes('att_admin'), ids.join(','));
    ok(`${k} 能看到 attendance（员工要打卡）`, ids.includes('attendance'), ids.join(','));
  }

  console.log('\n' + (failed ? `结论: 有 ${failed} 条不符 ✗` : '结论: 线上下发符合预期 ✓'));
  process.exit(failed ? 1 : 0);
})();
