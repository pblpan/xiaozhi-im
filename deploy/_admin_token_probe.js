'use strict';
/**
 * 管理台体检用的临时**管理员**令牌（跑在容器里）。
 * 与 _token_probe.js 同源思路：让服务端自己用同一把 JWT_SECRET 签，
 * 避免把管理口令明文塞进 shell / 日志 / history。
 *
 * 用法：docker exec xiaozhi-im node /app/_admin_token_probe.js /data/xiaozhi-im.db
 * 只打印一个 token。
 */
const { signToken } = require('/app/src/auth');
const { DatabaseSync } = require('node:sqlite');

const db = new DatabaseSync(process.argv[2]);
const u = db.prepare(
  "SELECT id, role FROM users WHERE role = 'admin' ORDER BY id LIMIT 1"
).get() || db.prepare('SELECT id, role FROM users ORDER BY id LIMIT 1').get();

if (!u) {
  console.error('库里一个用户都没有，签不出 token');
  process.exit(2);
}
console.log(signToken({ uid: u.id, role: u.role }));
db.close();
