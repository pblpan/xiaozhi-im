#!/usr/bin/env node
'use strict';
/**
 * 线上「全员好友补齐」执行探针（2026-10-11 龙哥反馈④ 收尾）。
 *
 * 用途：热部署 backfill 代码后，帮龙哥把线上好友**真的补齐** ——
 *       光把功能上线不算完，他的问题（"改了工作模式怎么没自动加好友"）要当场解决。
 *
 * 做法：查库只读拿统计与 admin id → 签 admin token → 走 **HTTP 接口**
 *       （POST /api/admin/friendships/backfill）触发补齐 —— 写入必须走刚部署的
 *       服务端代码路径（事务/升级 pending 语义都在里面），探针绝不直接写线上库。
 *       幂等接口，跑多次无害。
 *
 * 用法：python deploy/_exec_in_container.py deploy/_backfill_probe.js <容器内库路径>
 */
const { signToken } = require('/app/src/auth');
const { DatabaseSync } = require('node:sqlite');

const dbfile = process.argv[2] || '/data/xiaozhi-im.db';
if (!dbfile) { console.error('用法: node _backfill_probe.js <库路径>'); process.exit(2); }
const db = new DatabaseSync(dbfile, { readOnly: true });

const stats = () => ({
  users: db.prepare("SELECT COUNT(*) c FROM users WHERE is_bot=0").get().c,
  rows: db.prepare('SELECT COUNT(*) c FROM friendships').get().c,
  accepted: db.prepare("SELECT COUNT(*) c FROM friendships WHERE status='accepted'").get().c,
  pending: db.prepare("SELECT COUNT(*) c FROM friendships WHERE status='pending'").get().c,
});
const before = stats();
const admin = db.prepare("SELECT id FROM users WHERE role='admin' ORDER BY id LIMIT 1").get();
db.close();
if (!admin) { console.error('库里没有 admin 用户'); process.exit(1); }

const BASE = 'http://127.0.0.1:' + (process.env.PORT || 3000);
const token = signToken({ uid: admin.id, role: 'admin' });

(async () => {
  console.log('补齐前: ' + JSON.stringify(before));
  const r = await fetch(BASE + '/api/admin/friendships/backfill', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: 'Bearer ' + token },
  });
  const body = await r.json().catch(() => null);
  console.log('POST /api/admin/friendships/backfill -> ' + r.status + ' ' + JSON.stringify(body));
  if (r.status !== 200) process.exit(1);
  // 复查统计（重开只读连接，避免读到旧句柄）
  const db2 = new DatabaseSync(dbfile, { readOnly: true });
  const q = () => ({
    rows: db2.prepare('SELECT COUNT(*) c FROM friendships').get().c,
    accepted: db2.prepare("SELECT COUNT(*) c FROM friendships WHERE status='accepted'").get().c,
    pending: db2.prepare("SELECT COUNT(*) c FROM friendships WHERE status='pending'").get().c,
  });
  const after = q();
  db2.close();
  console.log('补齐后: ' + JSON.stringify(after));
  const expectPairs = before.users * (before.users - 1) / 2;
  const okRows = after.accepted === expectPairs * 2 && after.pending === 0;
  console.log((okRows ? '✅' : '⚠️') + ' 期望 accepted=' + (expectPairs * 2) +
    '（' + before.users + ' 人两两互加）、pending=0 —— ' +
    (okRows ? '线上好友已全量补齐' : '数字不对，别当通过，人工核一遍'));
})();
