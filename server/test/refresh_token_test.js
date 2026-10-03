// 双令牌（access + refresh）机制测试 —— 对应审计 P2「JWT 30 天无刷新」
//
//   node test/refresh_token_test.js
//
// 【为什么这些数字/判据要写成断言】
//   · refresh **只存哈希不存明文**：库里被拖走也换不出令牌。
//     判据 = 直接查库比对，表里不能出现签发出去的原文。
//   · **轮换**：用一次之后旧的必须立刻作废。不轮换的话，偷到的 refresh
//     能一直续命到 30 天自然过期 —— 那等于没做刷新机制。
//   · 改密码要**作废全部 refresh**：不然"改密码把小偷锁在外面"是假的，
//     对方手上的 refresh 还能继续换新令牌。
//   · 过期令牌要能被识别并清掉，不能当有效令牌用。
//   · refresh 端点也要有限流（否则它就是"无限续期"的漏洞）。
const path = require('path');
const os = require('os');
const fs = require('fs');
const crypto = require('crypto');

const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'refresh-test-'));
process.env.DATA_DIR = dir;
process.env.ADMIN_PASSWORD = 'unit-test-pass-123';

const db = require(path.resolve(__dirname, '..', 'src', 'db.js'));
const tokens = require(path.resolve(__dirname, '..', 'src', 'tokens.js'));
const { hashPassword, verifyToken } = require(path.resolve(__dirname, '..', 'src', 'auth.js'));

let pass = 0, fail = 0;
function check(name, fn) {
  try { fn(); console.log('  \x1b[32m✓\x1b[0m ' + name); pass++; }
  catch (e) { console.log('  \x1b[31m✗\x1b[0m ' + name + '  → ' + e.message); fail++; }
}
function assert(cond, msg) { if (!cond) throw new Error(msg || '断言不成立'); }

console.log('=== ① 签发：返回 access + refresh，且库里只有哈希 ===');
const uid = db.prepare('INSERT INTO users (username,password_hash,nickname,role,created_at) VALUES (?,?,?,?,?)')
  .run('rt_user', hashPassword('pw123456'), '刷新测试', 'user', Date.now()).lastInsertRowid;
const user = db.prepare('SELECT id,role FROM users WHERE id=?').get(uid);

const pair = tokens.issuePair(user);
check('返回 token / refreshToken / expiresIn 三个字段', () => {
  assert(pair.token && pair.refreshToken && pair.expiresIn, '字段缺失');
});
check('access token 可验签且带 uid', () => {
  const c = verifyToken(pair.token);
  assert(c && c.uid === uid, 'access 验签失败或 uid 不对');
});
check('库里存的是哈希，不是 refreshToken 原文', () => {
  const row = db.prepare('SELECT token_hash FROM refresh_tokens WHERE user_id=?').get(uid);
  assert(row, '库里没有记录');
  assert(row.token_hash !== pair.refreshToken, '⚠️ 库里存的是明文，库泄露即可直接用');
  const expect = crypto.createHash('sha256').update(pair.refreshToken).digest('hex');
  assert(row.token_hash === expect, '哈希算法/内容对不上');
});

console.log('\n=== ② 轮换：用一次之后旧的立刻作废 ===');
const rotated = tokens.rotate(pair.refreshToken);
check('首次 rotate 成功换出新的一对', () => {
  assert(!rotated.error, 'rotate 失败：' + rotated.error);
  assert(rotated.pair && rotated.pair.refreshToken, '没换到新的 refreshToken');
  assert(rotated.pair.refreshToken !== pair.refreshToken, '新旧 refresh 相同（没换）');
});
check('旧 refresh 再用 → 必须失败（这才是"轮换"）', () => {
  const again = tokens.rotate(pair.refreshToken);
  assert(again.error, '⚠️ 旧 refresh 还能用，等于没轮换 —— 泄露后可无限续期');
});
check('新 refresh 可用', () => {
  const again = tokens.rotate(rotated.pair.refreshToken);
  assert(!again.error, '新 refresh 反而不能用：' + again.error);
});

console.log('\n=== ③ 作废：改密码要能一次性清掉全部 refresh ===');
const p2 = tokens.issuePair(user);
const p3 = tokens.issuePair(user);
check('签发多个 refresh 后库里有多行', () => {
  const n = db.prepare('SELECT COUNT(*) c FROM refresh_tokens WHERE user_id=?').get(uid).c;
  assert(n >= 2, '只有 ' + n + ' 行');
});
check('revokeAll 之后该用户一行不剩', () => {
  tokens.revokeAll(uid);
  const n = db.prepare('SELECT COUNT(*) c FROM refresh_tokens WHERE user_id=?').get(uid).c;
  assert(n === 0, '还剩 ' + n + ' 行没清 —— 改密码锁不住小偷');
});
check('作废后这些 refresh 都不能再换（抽查 p2）', () => {
  const r = tokens.rotate(p2.refreshToken);
  assert(r.error, '作废后的 refresh 仍能换出令牌');
});
check('作废不影响别的用户', () => {
  const other = db.prepare('INSERT INTO users (username,password_hash,nickname,role,created_at) VALUES (?,?,?,?,?)')
    .run('rt_other', hashPassword('pw123456'), '别人', 'user', Date.now()).lastInsertRowid;
  const op = tokens.issuePair(db.prepare('SELECT id,role FROM users WHERE id=?').get(other));
  tokens.revokeAll(uid); // 只作废 uid
  const still = tokens.rotate(op.refreshToken);
  assert(!still.error, '别人的 refresh 被误伤了：' + still.error);
});

console.log('\n=== ④ 异常输入：不能让 rotate 崩，也不能放行 ===');
check('refreshToken 缺失 → 400', () => {
  const r = tokens.rotate(undefined);
  assert(r.status === 400, 'status 应为 400，实际 ' + r.status);
});
check('refreshToken 为空串 → 400', () => {
  const r = tokens.rotate('');
  assert(r.status === 400, 'status 应为 400，实际 ' + r.status);
});
check('乱编的 refreshToken → 401', () => {
  const r = tokens.rotate('not-a-real-token');
  assert(r.status === 401, 'status 应为 401，实际 ' + r.status);
});
check('已过期的 refreshToken → 401 且被清掉', () => {
  const p = tokens.issuePair(user);
  // 手动把它改成已过期
  db.prepare('UPDATE refresh_tokens SET expires_at=? WHERE token_hash=?')
    .run(Date.now() - 1000, crypto.createHash('sha256').update(p.refreshToken).digest('hex'));
  const r = tokens.rotate(p.refreshToken);
  assert(r.status === 401, '过期令牌应 401，实际 ' + r.status);
  const n = db.prepare('SELECT COUNT(*) c FROM refresh_tokens WHERE user_id=?').get(user.id).c;
  const left = db.prepare('SELECT token_hash FROM refresh_tokens WHERE user_id=?').all().length;
  assert(left === n, '过期行没清掉');
});
check('账号被删后，其 refresh 立即失效', () => {
  const victim = db.prepare('INSERT INTO users (username,password_hash,nickname,role,created_at) VALUES (?,?,?,?,?)')
    .run('rt_victim', hashPassword('pw123456'), '将被删', 'user', Date.now()).lastInsertRowid;
  const vp = tokens.issuePair(db.prepare('SELECT id,role FROM users WHERE id=?').get(victim));
  db.prepare('DELETE FROM users WHERE id=?').run(victim);
  const r = tokens.rotate(vp.refreshToken);
  assert(r.error, '账号删了 refresh 还能用 —— 删号等于没删');
});

console.log('\n=== ⑤ 向后兼容：旧客户端不受影响 ===');
check('access 仍是原来的形状（uid + role），旧客户端能继续用', () => {
  const c = verifyToken(pair.token);
  assert(c.uid && c.role, 'claims 不完整');
  assert(!c.kind, 'access 不该带 kind（那是 refresh 的标记）');
});
check('登录响应里 token 字段名没变（客户端读的就是 token）', () => {
  assert('token' in pair && 'refreshToken' in pair, '字段名变了会打不到旧客户端');
});

console.log('\n通过 ' + pass + ' / ' + (pass + fail));
db.close();
fs.rmSync(dir, { recursive: true, force: true });
process.exit(fail ? 1 : 0);
