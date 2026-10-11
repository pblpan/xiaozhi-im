'use strict';
/**
 * 「门店经营」群成员排查（纯只读 SQL，绕过 API 语义坑）。
 * 用法：python deploy/_exec_in_container.py deploy/_dailyreport_debug2.js
 */
const { DatabaseSync } = require('node:sqlite');
const db = new DatabaseSync('/data/xiaozhi-im.db', { readOnly: true });

const convId = Number(process.argv[2] || 16);

const g = db.prepare('SELECT id, name, conversation_id FROM groups WHERE conversation_id=?').get(convId);
console.log(`[groups] conversation_id=${convId} →`, JSON.stringify(g));

const conv = db.prepare('SELECT id, type FROM conversations WHERE id=?').get(convId);
console.log(`[conversations] #${convId} →`, JSON.stringify(conv));

const members = db.prepare(`
  SELECT u.id, u.username, u.nickname, u.is_bot, u.role,
         cm.conversation_id IS NOT NULL AS in_conv
  FROM conversation_members cm
  JOIN users u ON u.id = cm.user_id
  WHERE cm.conversation_id = ?`).all(convId);
console.log(`\n[conversation_members] 会话 #${convId} 成员 ${members.length} 人:`);
for (const m of members) {
  console.log(`  #${m.id} ${m.nickname || m.username} (${m.username}) is_bot=${m.is_bot} role=${m.role}`);
}
const real = members.filter((m) => !m.is_bot);
console.log(`\n🔴 真人数量: ${real.length}${real.length === 0 ? '  ← 推得再勤也没人看得到！' : ''}`);

// group_members（群成员表，与 conversation_members 双写）
if (g) {
  const gm = db.prepare(`
    SELECT u.id, u.nickname, u.is_bot FROM group_members gm
    JOIN users u ON u.id = gm.user_id WHERE gm.group_id = ?`).all(g.id);
  console.log(`\n[group_members] 群 ${g.id}「${g.name}」成员 ${gm.length} 人:`);
  for (const m of gm) console.log(`  #${m.id} ${m.nickname}${m.is_bot ? ' [机器人]' : ''}`);
}

// 管理员在不在
const admin = db.prepare("SELECT id, nickname, username FROM users WHERE role='admin' ORDER BY id LIMIT 1").get();
const adminIn = members.some((m) => m.id === admin.id);
console.log(`\n[check] 管理员 #${admin.id} ${admin.nickname}(${admin.username}) 在会话 #${convId} 成员里: ${adminIn ? '✅ 是' : '❌ 否'}`);
console.log('[done] 只读排查完成');
db.close();
