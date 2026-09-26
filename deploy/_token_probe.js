'use strict';
/**
 * 线上体检用的临时令牌（跑在容器里）。
 *
 * 🔴 为什么不注册一个一次性账号：线上是**工作模式**（friend_mode=work），
 *    服务端直接回「工作模式下由管理员统一添加员工账号」，自助注册这条路
 *    根本走不通（2026-09-26 实测）。
 *
 * 🔴 为什么不用管理员口令登录：那串明文会出现在 shell 命令和 curl 的参数里，
 *    进日志、进 history。为了体检一下接口就把管理口令明文撒一遍，不值当。
 *
 * 正确做法：**让服务端自己签**。容器里有 `/app/src/auth.js`，它用的
 * JWT_SECRET 与正在跑的服务是同一把（缺失时会生成并持久化到数据目录，
 * 所以重启也一致）。签出来的 token 是普通用户身份，参照数接口本来就只要
 * 「任意登录用户」。
 *
 * 用法：docker exec xiaozhi-im node /app/_token_probe.js /data/xiaozhi-im.db
 * 只打印一个 token，别的什么都不打（调用方要能直接拿来用）。
 */
const { signToken } = require('/app/src/auth');
const { DatabaseSync } = require('node:sqlite');

const db = new DatabaseSync(process.argv[2]);
// 优先挑一个非管理员 —— 参照数是普通员工用的接口，用普通身份验才对得上。
const u = db.prepare(
  "SELECT id, role FROM users WHERE role IS NOT 'admin' ORDER BY id LIMIT 1"
).get() || db.prepare('SELECT id, role FROM users ORDER BY id LIMIT 1').get();

if (!u) {
  console.error('库里一个用户都没有，签不出 token');
  process.exit(2);
}
console.log(signToken({ uid: u.id, role: u.role }));
db.close();
