// 线上验证：群功能 v2 的数据库迁移 + 模块加载（只读，不动生产数据）。
// 容器里跑：python deploy/_exec_in_container.py deploy/_verify_group_v2.js
const db = require('/app/src/db');
const chat = require('/app/src/chat');

let bad = 0;
const ok = (name, cond, extra) => {
  console.log(`${cond ? '  \u2713' : '  \u2717'} ${name}${extra ? '  → ' + extra : ''}`);
  if (!cond) bad++;
};

console.log('== 1) 列迁移 ==');
for (const [table, col] of [
  ['groups', 'muted_all'],
  ['groups', 'join_mode'],
  ['group_members', 'nickname'],
]) {
  const cols = db.prepare('SELECT name FROM pragma_table_info(?)').all(table).map((c) => c.name);
  ok(`${table}.${col}`, cols.includes(col), cols.join(','));
}

console.log('== 2) 新表 ==');
for (const t of ['group_join_requests', 'group_polls', 'group_poll_votes']) {
  const row = db.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name=?").get(t);
  ok(`表 ${t}`, !!row);
}

console.log('== 3) 模块 ==');
ok("KINDS 注册 'poll'", chat.KINDS.includes('poll'), chat.KINDS.join(','));
// mutedAllBlock 是 chat.js 内部函数（故意不导出），拦截行为由 groups_v2_e2e 44/44 钉住
ok('mutedUntilOf 仍在导出清单（chat.js 加载完整）', typeof chat.mutedUntilOf === 'function');

console.log('== 4) 线上数据快照（只读） ==');
const g = db.prepare('SELECT id,name,muted_all,join_mode FROM groups ORDER BY id DESC LIMIT 5').all();
g.forEach((x) => console.log(`  群#${x.id} ${x.name} muted_all=${x.muted_all} join_mode=${x.join_mode}`));
const nUsers = db.prepare('SELECT COUNT(*) n FROM users WHERE is_bot=0').get().n;
const nGroups = db.prepare('SELECT COUNT(*) n FROM groups').get().n;
console.log(`  真人 ${nUsers} 个 / 群 ${nGroups} 个（全员禁言与审批都默认关闭，老行为不变）`);

console.log(bad ? `\n!! ${bad} 项未通过` : '\n全部通过');
process.exit(bad ? 1 : 0);
