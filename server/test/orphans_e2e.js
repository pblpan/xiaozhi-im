// 孤儿巡检 e2e 测试 —— 对应 #234 / 管理台「数据体检」页的后端
//
//   node test/orphans_e2e.js
//
// 【覆盖】
//   · scan 能查出各类孤儿，且**数量准确**（这是巡检页唯一可信的前提 ——
//     数错了管理员就会照着错的数量做决策）
//   · 「产品要保留的引用」也被查出来，但 purgeable=false、**且清理接口拒绝处理**
//   · purge 能把 purgeable 的清干净，且**不误伤**保留类
//   · confirm 数量比对：数量变了必须 409
//   · 清理前有备份，且备份里能捞回被删的行
//   · 鉴权：未登录 401 / 非管理员 403
const { spawn } = require('child_process');
const path = require('path');
const fs = require('fs');
const os = require('os');

const PORT = 3719;
const BASE = `http://127.0.0.1:${PORT}`;
const DATA_DIR = fs.mkdtempSync(path.join(os.tmpdir(), 'orphans-e2e-'));

let pass = 0, fail = 0;
const ok = (c, n, e = '') => { if (c) { console.log('  \x1b[32m✓\x1b[0m ' + n); pass++; } else { console.log('  \x1b[31m✗\x1b[0m ' + n + (e ? '  → ' + e : '')); fail++; } };
const eq = (a, b, n) => ok(a === b, n, `期望 ${b}，实际 ${a}`);

let child = null;
function start() {
  return new Promise((resolve, reject) => {
    child = spawn(process.execPath, [path.join(__dirname, '..', 'src', 'index.js')], {
      env: { ...process.env, PORT: String(PORT), DATA_DIR, JWT_SECRET: 'test-secret-for-orphans-e2e' },
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    let out = '';
    child.stdout.on('data', (d) => {
      out += d.toString();
      if (out.includes('服务端已启动')) resolve();
    });
    child.stderr.on('data', (d) => { out += d.toString(); });
    setTimeout(() => reject(new Error('启动超时：' + out.slice(-500))), 20000);
  });
}
async function api(pathname, opts = {}) {
  const r = await fetch(BASE + pathname, opts);
  let body = null;
  try { body = await r.json(); } catch (_) {}
  return { status: r.status, body };
}
async function login(username, password) {
  const r = await api('/api/auth/login', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ username, password }),
  });
  return r.body?.token;
}
const auth = (token, extra = {}) => ({ ...extra, headers: { 'Content-Type': 'application/json', Authorization: 'Bearer ' + token, ...(extra.headers || {}) } });

(async () => {
  console.log('孤儿巡检 e2e\n');
  await start();

  // 直连库造数据：绕过接口，才能造出"接口造不出"的历史遗留孤儿
  const { DatabaseSync } = require('node:sqlite');
  const db = new DatabaseSync(path.join(DATA_DIR, 'xiaozhi-im.db'));

  // db.js 播种的 admin 密码是随机的（ADMIN_PASSWORD 没配时），所以先在库里
  // 改成一个已知值再登录 —— 比走 /api/setup 绕得多。
  // ⚠️ 这里直连库是因为 e2e 本来就要直连库造"接口造不出的历史孤儿"。
  let admin = null;
  {
    const { hashPassword } = require(path.join(__dirname, '..', 'src', 'auth.js'));
    db.prepare('UPDATE users SET password_hash=? WHERE username=?').run(hashPassword('known-pw-123'), 'admin');
    admin = await login('admin', 'known-pw-123');
  }
  ok(!!admin, '拿到管理员 token');
  if (!admin) { console.log('拿不到 token，终止'); process.exit(1); }

  const U = (n) => db.prepare('INSERT INTO users (username,password_hash,nickname,role,created_at) VALUES (?,?,?,?,?)')
    .run('e2e_' + n, 'h', n, 'user', Date.now()).lastInsertRowid;

  console.log('\n=== 造孤儿数据 ===');
  const u1 = U('ghost');        // 会被引用、随后删除 → 产生孤儿
  const u2 = U('alive');
  const cid = db.prepare("INSERT INTO conversations (type,created_at) VALUES ('dm',?)").run(Date.now()).lastInsertRowid;
  db.prepare('INSERT INTO conversation_members (conversation_id,user_id) VALUES (?,?)').run(cid, u2);
  // 会话成员指向 ghost（孤儿：user 不存在）
  db.prepare('INSERT INTO conversation_members (conversation_id,user_id) VALUES (?,?)').run(cid, u1);
  // 收藏指向 ghost 的消息占位（先造消息再删用户）
  const mid = db.prepare("INSERT INTO messages (conversation_id,sender_id,kind,content,created_at) VALUES (?,?,'text','hi',?)")
    .run(cid, u1, Date.now()).lastInsertRowid;
  db.prepare('INSERT INTO favorites (user_id,message_id,created_at) VALUES (?,?,?)').run(u1, mid, Date.now());
  // 审批单 + 考勤（**保留类**：purgeable=false）
  db.prepare("INSERT INTO approvals (kind,title,status,submitter_id,created_at) VALUES ('stocktake','测试单','pending',?,?)")
    .run(u1, Date.now());
  // att_requests.kind 是 NOT NULL（leave/makeup/outing/overtime），必须给值
  db.prepare("INSERT INTO att_requests (org_id,user_id,kind,day,status,created_at) VALUES (1,?,'makeup','2026-10-01','pending',?)")
    .run(u1, Date.now());
  // 现在把 ghost 删掉 —— 注意 messages/approvals/att_requests 里的引用**故意留着**
  db.prepare('DELETE FROM users WHERE id=?').run(u1);
  console.log('  （已删除用户 ' + u1 + '，其残留引用保留）');

  console.log('\n=== ① 鉴权 ===');
  eq((await api('/api/admin/orphans/scan')).status, 401, '未登录 scan → 401');
  // 造个普通用户试
  db.prepare("INSERT INTO users (username,password_hash,nickname,role,created_at) VALUES ('plain_u',?,'普通','user',?)")
    .run(require(path.join(__dirname, '..', 'src', 'auth.js')).hashPassword('plain-pw-123'), Date.now());
  const plain = await login('plain_u', 'plain-pw-123');
  eq((await api('/api/admin/orphans/scan', { headers: { Authorization: 'Bearer ' + plain } })).status, 403, '非管理员 scan → 403');

  console.log('\n=== ② scan：数量与分类必须准确 ===');
  const scan = (await api('/api/admin/orphans/scan', auth(admin))).body;
  ok(!!scan.items, '返回 items 列表');
  eq(scan.items.length, scan.summary.checked, 'items 条数 = 体检的关联数');
  const byKey = Object.fromEntries(scan.items.map((i) => [i.key, i]));
  // ghost 被删后：会话成员 1、收藏 1、消息发送者 1、审批 1、补卡 1、好友/群等为 0
  eq(byKey['conversation_members.user'].count, 1, '会话成员→用户 孤儿数 = 1');
  eq(byKey['favorites.user'].count, 1, '收藏→用户 孤儿数 = 1');
  ok(byKey['messages.sender'].count >= 1, '消息→发送者 被检出', '实际 ' + byKey['messages.sender'].count);

  console.log('\n=== ③ 分类正确：保留类必须标为不可清理 ===');
  eq(byKey['messages.sender'].purgeable, false, '消息→发送者 标记为 purgeable=false');
  eq(byKey['approvals.submitter'].purgeable, false, '审批单→提交人 标记为 purgeable=false');
  eq(byKey['att_requests.user'].purgeable, false, '补卡申请→申请人 标记为 purgeable=false');
  ok(!!byKey['messages.sender'].why, '保留类给出了"为什么不建议清"的说明');
  ok(!!byKey['conversation_members.user'].impact, '可清理类说明了"清掉会怎样"');
  eq(byKey['conversation_members.user'].purgeable, true, '会话成员→用户 标记为 purgeable=true');
  // 保留类不返回样本（没意义），可清理类返回
  eq((byKey['messages.sender'].sample || []).length, 0, '保留类不返回样本 id');
  ok((byKey['conversation_members.user'].sample || []).length === 1, '可清理类返回了样本行');
  // 🔴 防复发：不是每张表都有 id 列（conversation_members / group_members /
  //    inv_grants 是复合主键）。样本查询曾写死 c.id，报错被 catch 吞掉 →
  //    页面显示"有孤儿但点不出明细"。这里对**所有**可清理关联都验一遍样本能查出来。
  for (const it of scan.items) {
    if (it.count > 0 && it.purgeable) {
      ok((it.sample || []).length > 0, `样本可查出：${it.label}`);
    }
  }
  ok(scan.summary.purgeable >= 2, 'summary.purgeable 统计到可清理项', '实际 ' + scan.summary.purgeable);
  ok(scan.summary.kept >= 3, 'summary.kept 统计到保留类', '实际 ' + scan.summary.kept);

  console.log('\n=== ④ purge 硬闸门：保留类不可清理（服务端拦住，不靠前端）===');
  const badPurge = await api('/api/admin/orphans/purge', auth(admin, {
    method: 'POST', body: JSON.stringify({ keys: ['messages.sender'], confirm: 999 }),
  }));
  eq(badPurge.status, 400, '清理「消息→发送者」被拒（400）');
  ok(/不建议清理/.test(badPurge.body?.error || ''), '拒绝原因写明"不建议清理"', badPurge.body?.error);

  console.log('\n=== ⑤ confirm 数量比对：数字错了必须 409 ===');
  const wrong = await api('/api/admin/orphans/purge', auth(admin, {
    method: 'POST', body: JSON.stringify({ keys: ['conversation_members.user'], confirm: 999 }),
  }));
  eq(wrong.status, 409, 'confirm 数量不符 → 409');
  ok(/数量已变化/.test(wrong.body?.error || ''), '409 给出可读原因', wrong.body?.error);

  console.log('\n=== ⑥ 真正清理：purgeable 清干净，且不误伤保留类 ===');
  const before = db.prepare('SELECT COUNT(*) c FROM conversation_members WHERE user_id=?').get(u1).c;
  ok(before >= 1, '清理前该孤儿行确实存在');
  const real = await api('/api/admin/orphans/purge', auth(admin, {
    method: 'POST', body: JSON.stringify({ keys: ['conversation_members.user', 'favorites.user'], confirm: 2 }),
  }));
  eq(real.status, 200, '清理请求 200');
  eq(db.prepare('SELECT COUNT(*) c FROM conversation_members WHERE user_id=?').get(u1).c, 0, '会话成员孤儿已清空');
  eq(db.prepare('SELECT COUNT(*) c FROM favorites WHERE user_id=?').get(u1).c, 0, '收藏孤儿已清空');
  // 🔴 关键：保留类必须**一行没少**
  ok(db.prepare('SELECT COUNT(*) c FROM messages WHERE sender_id=?').get(u1).c >= 1, '🔒 消息未被误删（保留类）');
  eq(db.prepare('SELECT COUNT(*) c FROM approvals WHERE submitter_id=?').get(u1).c, 1, '🔒 审批留痕未被误删（保留类）');
  ok(db.prepare('SELECT COUNT(*) c FROM att_requests WHERE user_id=?').get(u1).c >= 1, '🔒 补卡申请未被误删（保留类）');
  // 活着的用户不能被动
  eq(db.prepare('SELECT COUNT(*) c FROM conversation_members WHERE user_id=?').get(u2).c, 1, '正常成员的会话记录未受影响');

  console.log('\n=== ⑦ 清理有备份，且能捞回 ===');
  ok(!!real.body?.backup?.name, '返回了备份文件名', JSON.stringify(real.body));
  const bdir = path.join(DATA_DIR, 'purge-backup');
  const bfiles = fs.existsSync(bdir) ? fs.readdirSync(bdir) : [];
  ok(bfiles.length > 0, '备份目录里确实有文件');
  if (bfiles.length) {
    const b = JSON.parse(fs.readFileSync(path.join(bdir, bfiles[0]), 'utf8'));
    eq(b.kind, 'orphans', '备份标明了类型');
    ok(b.count >= 2, '备份里记录了条数', 'count=' + b.count);
    ok(b.rows.some((r) => r._relation === 'conversation_members.user'), '备份里含被删的孤儿行，可捞回');
  }

  console.log('\n=== ⑧ 再扫一次：孤儿没了，保留类还在 ===');
  const scan2 = (await api('/api/admin/orphans/scan', auth(admin))).body;
  const bk2 = Object.fromEntries(scan2.items.map((i) => [i.key, i]));
  eq(bk2['conversation_members.user'].count, 0, '已清理项复查为 0');
  ok(bk2['messages.sender'].count >= 1, '保留类复查仍在（且仍标记不可清理）');
  eq(bk2['messages.sender'].purgeable, false, '保留类标记没变');

  console.log('\n====================================================');
  console.log(`通过 ${pass} / ${pass + fail}`);
  console.log('====================================================');
  try { child.kill(); } catch (_) {}
  try { db.close(); fs.rmSync(DATA_DIR, { recursive: true, force: true }); } catch (_) {}
  process.exit(fail ? 1 : 0);
})().catch((e) => {
  console.error('\n💥 ' + e.message);
  if (child) try { child.kill(); } catch (_) {}
  try { fs.rmSync(DATA_DIR, { recursive: true, force: true }); } catch (_) {}
  process.exit(1);
});
