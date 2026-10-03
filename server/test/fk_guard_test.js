// 验证新加的引用完整性触发器：能挡脏数据，且不误伤正常写入
const path = require('path');
const os = require('os');
const fs = require('fs');
const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'fk-verify-'));
process.env.DATA_DIR = dir;
process.env.ADMIN_PASSWORD = 'x'.repeat(12);
// 真正加载 db.js（会用 DATA_DIR 建库 + 装触发器）
const db = require(path.resolve(__dirname, '..', 'src', 'db.js'));

let pass = 0, fail = 0;
function check(name, fn) {
  try {
    fn();
    console.log('  \x1b[32m✓\x1b[0m ' + name);
    pass++;
  } catch (e) {
    console.log('  \x1b[31m✗\x1b[0m ' + name + '  → ' + e.message);
    fail++;
  }
}
function expectBlocked(fn, hint) {
  try {
    fn();
    throw new Error('本该被拦住，却写进去了（' + hint + '）');
  } catch (e) {
    if (String(e.message).includes('本该被拦住')) throw e;
    if (!/不存在的/.test(e.message)) throw new Error('报错不对：' + e.message);
  }
}

console.log('=== ① 挡脏数据：父行不存在时必须写不进去 ===');
check('conversation_members 指向不存在的会话 → 拒绝', () => {
  expectBlocked(() => db.prepare('INSERT INTO conversation_members (conversation_id,user_id) VALUES (?,?)').run(99999, 1), '孤立会话成员');
});
check('conversation_members 指向不存在的用户 → 拒绝', () => {
  expectBlocked(() => db.prepare('INSERT INTO conversation_members (conversation_id,user_id) VALUES (?,?)').run(1, 99999), '孤立用户');
});
check('group_members 指向不存在的群 → 拒绝', () => {
  expectBlocked(() => db.prepare('INSERT INTO group_members (group_id,user_id,role,joined_at) VALUES (?,?,?,?)').run(99999, 1, 'member', Date.now()), '孤立群成员');
});
check('friendships 指向不存在的用户 → 拒绝', () => {
  expectBlocked(() => db.prepare('INSERT INTO friendships (user_id,friend_id,status,created_at) VALUES (?,?,?,?)').run(99999, 1, 'pending', Date.now()), '孤立好友');
});
check('UPDATE 指向不存在的父行 → 拒绝', () => {
  // 造一条真实的 friendships，再把 friend_id 改成不存在的用户。
  // （早先这个用例写成"把 friend_id 改成同样的值"，那本来就合法、不该被拦 ——
  //   是断言写错了，不是触发器没生效。）
  const a = db.prepare('INSERT INTO users (username,password_hash,nickname,role,created_at) VALUES (?,?,?,?,?)')
    .run('fk_upd_a', 'h', 'U1', 'user', Date.now()).lastInsertRowid;
  const b = db.prepare('INSERT INTO users (username,password_hash,nickname,role,created_at) VALUES (?,?,?,?,?)')
    .run('fk_upd_b', 'h', 'U2', 'user', Date.now()).lastInsertRowid;
  db.prepare('INSERT INTO friendships (user_id,friend_id,status,created_at) VALUES (?,?,?,?)').run(a, b, 'pending', Date.now());
  expectBlocked(() => db.prepare('UPDATE friendships SET friend_id=99999 WHERE user_id=?').run(a), 'UPDATE 造成孤儿');
});
check('UPDATE 改成合法值 → 放行（别误伤）', () => {
  const a = db.prepare("SELECT user_id FROM friendships WHERE status='pending' LIMIT 1").get().user_id;
  const c = db.prepare('INSERT INTO users (username,password_hash,nickname,role,created_at) VALUES (?,?,?,?,?)')
    .run('fk_upd_c', 'h', 'U3', 'user', Date.now()).lastInsertRowid;
  db.prepare('UPDATE friendships SET friend_id=? WHERE user_id=?').run(c, a); // 指向真实用户：必须成功
});

console.log('\n=== ② 不误伤：正常业务写入必须照常成功 ===');
const u1 = db.prepare('INSERT INTO users (username,password_hash,nickname,role,created_at) VALUES (?,?,?,?,?)')
  .run('fk_u1', 'h', 'A', 'user', Date.now()).lastInsertRowid;
const u2 = db.prepare('INSERT INTO users (username,password_hash,nickname,role,created_at) VALUES (?,?,?,?,?)')
  .run('fk_u2', 'h', 'B', 'user', Date.now()).lastInsertRowid;
check('建两个用户（父行）', () => { if (!u1 || !u2) throw new Error('建用户失败'); });
check('建会话 + 加成员（业务最常见组合）', () => {
  const cid = db.prepare("INSERT INTO conversations (type,created_at) VALUES ('dm',?)").run(Date.now()).lastInsertRowid;
  db.prepare('INSERT INTO conversation_members (conversation_id,user_id) VALUES (?,?)').run(cid, u1);
  db.prepare('INSERT INTO conversation_members (conversation_id,user_id) VALUES (?,?)').run(cid, u2);
});
check('建群 + 群主成员 + 会话成员（建群 4 步）', () => {
  const cid = db.prepare("INSERT INTO conversations (type,created_at) VALUES ('group',?)").run(Date.now()).lastInsertRowid;
  const gid = db.prepare('INSERT INTO groups (name,owner_id,conversation_id,created_at) VALUES (?,?,?,?)')
    .run('群', u1, cid, Date.now()).lastInsertRowid;
  db.prepare('INSERT INTO group_members (group_id,user_id,role,joined_at) VALUES (?,?,?,?)').run(gid, u1, 'owner', Date.now());
  db.prepare('INSERT INTO conversation_members (conversation_id,user_id) VALUES (?,?)').run(cid, u1);
});
check('加好友（双向两条记录）', () => {
  db.prepare('INSERT INTO friendships (user_id,friend_id,status,created_at) VALUES (?,?,?,?)').run(u1, u2, 'accepted', Date.now());
  db.prepare('INSERT INTO friendships (user_id,friend_id,status,created_at) VALUES (?,?,?,?)').run(u2, u1, 'accepted', Date.now());
});
check('正常删除会话成员（触发器不拦 DELETE）', () => {
  const cid = db.prepare("INSERT INTO conversations (type,created_at) VALUES ('dm',?)").run(Date.now()).lastInsertRowid;
  db.prepare('INSERT INTO conversation_members (conversation_id,user_id) VALUES (?,?)').run(cid, u1);
  db.prepare('DELETE FROM conversation_members WHERE conversation_id=? AND user_id=?').run(cid, u1);
});

console.log('\n=== ③ 回滚验证：事务里被触发器拒绝 → 整笔撤销 ===');
check('被触发器拒绝后事务内先前的写入也一起回滚', () => {
  const cid = db.prepare("INSERT INTO conversations (type,created_at) VALUES ('dm',?)").run(Date.now()).lastInsertRowid;
  const before = db.prepare('SELECT COUNT(*) c FROM conversation_members').get().c;
  db.exec('BEGIN');
  try {
    db.prepare('INSERT INTO conversation_members (conversation_id,user_id) VALUES (?,?)').run(cid, u1);
    db.prepare('INSERT INTO conversation_members (conversation_id,user_id) VALUES (?,?)').run(99999, u2); // 该行被触发器拒
    db.exec('COMMIT');
    throw new Error('本该回滚，却提交了');
  } catch (e) {
    if (String(e.message).includes('本该回滚')) throw e;
    db.exec('ROLLBACK');
  }
  const after = db.prepare('SELECT COUNT(*) c FROM conversation_members').get().c;
  if (after !== before) throw new Error('回滚不干净：' + before + ' → ' + after);
});

console.log('\n=== ④ 触发器确实装上了 ===');
const trgs = db.prepare("SELECT name FROM sqlite_master WHERE type='trigger' AND name LIKE 'trg_fk%'").all();
check('已安装 ' + trgs.length + ' 个触发器（7 关系 × 插入/更新）', () => {
  if (trgs.length < 14) throw new Error('只装了 ' + trgs.length + ' 个');
});

console.log('\n通过 ' + pass + ' / ' + (pass + fail));
db.close();
fs.rmSync(dir, { recursive: true, force: true });
process.exit(fail ? 1 : 0);
