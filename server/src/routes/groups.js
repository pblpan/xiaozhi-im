const router = require('express').Router();
const db = require('../db');
const { verifyToken } = require('../auth');
const hub = require('../hub');

function uidOf(req, res) {
  const c = verifyToken(req.headers.authorization?.replace('Bearer ', ''));
  if (!c) { res.status(401).json({ error: 'unauthorized' }); return null; }
  return c.uid;
}

/** 取群 + 我在群里的角色，非成员返回 null 并已回 403 */
function loadGroup(gid, uid, res) {
  const g = db.prepare('SELECT id,name,owner_id,avatar,conversation_id,created_at,announcement FROM groups WHERE id=?').get(gid);
  if (!g) { res.status(404).json({ error: 'not found' }); return null; }
  const me = db.prepare('SELECT role,muted_until FROM group_members WHERE group_id=? AND user_id=?').get(gid, uid);
  if (!me) { res.status(403).json({ error: 'not a group member' }); return null; }
  return { g, me, isOwner: g.owner_id === uid, isAdmin: me.role === 'admin' || g.owner_id === uid };
}

/** 群变更后通知全体成员刷新（前端收到后重拉群信息/会话列表） */
function notifyGroup(conversationId, groupId, action, extra = {}) {
  hub.broadcastToConversation(db, conversationId, {
    type: 'group:updated', groupId, conversationId, action, ...extra,
  }, null);
}

// 建群（同时建群会话）
router.post('/', (req, res) => {
  const uid = uidOf(req, res); if (uid === null) return;
  const name = (req.body?.name || '').trim();
  if (!name) return res.status(400).json({ error: 'name required' });
  const cinfo = db.prepare("INSERT INTO conversations (type,created_at) VALUES ('group',?)").run(Date.now());
  const cid = cinfo.lastInsertRowid;
  const ginfo = db.prepare('INSERT INTO groups (name,owner_id,conversation_id,created_at) VALUES (?,?,?,?)')
    .run(name, uid, cid, Date.now());
  const gid = ginfo.lastInsertRowid;
  db.prepare('INSERT INTO group_members (group_id,user_id,role,joined_at) VALUES (?,?,?,?)').run(gid, uid, 'owner', Date.now());
  db.prepare('INSERT INTO conversation_members (conversation_id,user_id) VALUES (?,?)').run(cid, uid);
  res.json({ groupId: gid, conversationId: cid });
});

// 我加入的群
router.get('/my', (req, res) => {
  const uid = uidOf(req, res); if (uid === null) return;
  const rows = db.prepare(`SELECT g.id,g.name,g.avatar,g.conversation_id,g.announcement,
    m.role AS my_role, m.muted_until,
    (SELECT COUNT(*) FROM group_members gm WHERE gm.group_id=g.id) members
    FROM groups g JOIN group_members m ON m.group_id=g.id WHERE m.user_id=? ORDER BY g.id DESC`).all(uid);
  res.json(rows);
});

// 群信息 + 成员 + 我的角色
router.get('/:groupId', (req, res) => {
  const uid = uidOf(req, res); if (uid === null) return;
  const gid = Number(req.params.groupId);
  const ctx = loadGroup(gid, uid, res); if (!ctx) return;
  const members = db.prepare(`SELECT u.id,u.username,u.nickname,u.avatar,m.role,m.muted_until,m.joined_at
    FROM group_members m JOIN users u ON u.id=m.user_id WHERE m.group_id=?`).all(gid);
  res.json({
    group: ctx.g,
    members,
    my_role: ctx.isOwner ? 'owner' : ctx.me.role,
    is_owner: ctx.isOwner,
    can_manage: ctx.isAdmin,
  });
});

// 改群名 / 群公告（群主或管理员）
router.patch('/:groupId', (req, res) => {
  const uid = uidOf(req, res); if (uid === null) return;
  const gid = Number(req.params.groupId);
  const ctx = loadGroup(gid, uid, res); if (!ctx) return;
  if (!ctx.isAdmin) return res.status(403).json({ error: '只有群主或管理员可以修改群资料' });

  const body = req.body || {};
  const sets = [];
  const args = [];
  if (typeof body.name === 'string') {
    const n = body.name.trim();
    if (!n) return res.status(400).json({ error: '群名不能为空' });
    if (n.length > 30) return res.status(400).json({ error: '群名最长 30 个字' });
    sets.push('name = ?'); args.push(n);
  }
  if (typeof body.announcement === 'string') {
    const a = body.announcement.trim();
    if (a.length > 500) return res.status(400).json({ error: '群公告最长 500 个字' });
    sets.push('announcement = ?'); args.push(a || null);
  }
  if (!sets.length) return res.status(400).json({ error: '没有要修改的内容' });

  args.push(gid);
  db.prepare(`UPDATE groups SET ${sets.join(', ')} WHERE id = ?`).run(...args);
  notifyGroup(ctx.g.conversation_id, gid, 'profile');
  res.json({ ok: true, group: db.prepare('SELECT id,name,announcement FROM groups WHERE id=?').get(gid) });
});

// 设/撤管理员、禁言/解除（群主；管理员仅可禁言普通成员）
router.patch('/:groupId/members/:userId', (req, res) => {
  const uid = uidOf(req, res); if (uid === null) return;
  const gid = Number(req.params.groupId);
  const target = Number(req.params.userId);
  const ctx = loadGroup(gid, uid, res); if (!ctx) return;
  if (target === ctx.g.owner_id) return res.status(400).json({ error: '不能对群主操作' });
  const tm = db.prepare('SELECT role FROM group_members WHERE group_id=? AND user_id=?').get(gid, target);
  if (!tm) return res.status(404).json({ error: '该用户不在群里' });

  const body = req.body || {};
  const sets = [];
  const args = [];

  if (typeof body.role === 'string') {
    if (!ctx.isOwner) return res.status(403).json({ error: '只有群主可以设置管理员' });
    const r = body.role === 'admin' ? 'admin' : 'member';
    sets.push('role = ?'); args.push(r);
  }
  if (body.muteMinutes !== undefined) {
    const mins = Number(body.muteMinutes);
    // 管理员不能禁言另一个管理员；群主不受限
    if (!ctx.isOwner && tm.role === 'admin') {
      return res.status(403).json({ error: '不能禁言管理员' });
    }
    if (!ctx.isAdmin) return res.status(403).json({ error: '只有群主或管理员可以禁言' });
    const until = Number.isFinite(mins) && mins > 0
      ? Date.now() + Math.min(mins, 7 * 24 * 60) * 60000
      : 0;
    sets.push('muted_until = ?'); args.push(until);
  }
  if (!sets.length) return res.status(400).json({ error: '没有要修改的内容' });

  args.push(gid, target);
  db.prepare(`UPDATE group_members SET ${sets.join(', ')} WHERE group_id = ? AND user_id = ?`).run(...args);
  notifyGroup(ctx.g.conversation_id, gid, 'member');
  hub.broadcastToUser(target, { type: 'group:updated', groupId: gid, conversationId: ctx.g.conversation_id, action: 'me' });
  res.json({ ok: true });
});

// 转让群主（仅现任群主）
router.post('/:groupId/transfer', (req, res) => {
  const uid = uidOf(req, res); if (uid === null) return;
  const gid = Number(req.params.groupId);
  const ctx = loadGroup(gid, uid, res); if (!ctx) return;
  if (!ctx.isOwner) return res.status(403).json({ error: '只有群主可以转让' });
  const target = Number((req.body || {}).userId);
  if (target === uid) return res.status(400).json({ error: '不能转让给自己' });
  const tm = db.prepare('SELECT role FROM group_members WHERE group_id=? AND user_id=?').get(gid, target);
  if (!tm) return res.status(404).json({ error: '该用户不在群里' });

  db.prepare('UPDATE groups SET owner_id=? WHERE id=?').run(target, gid);
  db.prepare("UPDATE group_members SET role='owner', muted_until=0 WHERE group_id=? AND user_id=?").run(gid, target);
  db.prepare("UPDATE group_members SET role='member' WHERE group_id=? AND user_id=?").run(gid, uid);
  notifyGroup(ctx.g.conversation_id, gid, 'owner', { newOwnerId: target });
  res.json({ ok: true, newOwnerId: target });
});

// 踢人（群主可踢任何人；管理员只能踢普通成员）
router.delete('/:groupId/members/:userId', (req, res) => {
  const uid = uidOf(req, res); if (uid === null) return;
  const gid = Number(req.params.groupId);
  const target = Number(req.params.userId);
  const ctx = loadGroup(gid, uid, res); if (!ctx) return;
  if (target === ctx.g.owner_id) return res.status(400).json({ error: '不能移出群主' });
  const tm = db.prepare('SELECT role FROM group_members WHERE group_id=? AND user_id=?').get(gid, target);
  if (!tm) return res.status(404).json({ error: '该用户不在群里' });
  if (!ctx.isAdmin) return res.status(403).json({ error: '只有群主或管理员可以移出成员' });
  if (!ctx.isOwner && tm.role === 'admin') return res.status(403).json({ error: '管理员不能移出其他管理员' });

  db.prepare('DELETE FROM group_members WHERE group_id=? AND user_id=?').run(gid, target);
  db.prepare('DELETE FROM conversation_members WHERE conversation_id=? AND user_id=?').run(ctx.g.conversation_id, target);
  notifyGroup(ctx.g.conversation_id, gid, 'member');
  hub.broadcastToUser(target, { type: 'group:kicked', groupId: gid, conversationId: ctx.g.conversation_id });
  res.json({ ok: true });
});

// 主动退群（群主须先转让）
router.post('/:groupId/leave', (req, res) => {
  const uid = uidOf(req, res); if (uid === null) return;
  const gid = Number(req.params.groupId);
  const ctx = loadGroup(gid, uid, res); if (!ctx) return;
  if (ctx.isOwner) return res.status(400).json({ error: '群主需先转让群主才能退群' });

  db.prepare('DELETE FROM group_members WHERE group_id=? AND user_id=?').run(gid, uid);
  db.prepare('DELETE FROM conversation_members WHERE conversation_id=? AND user_id=?').run(ctx.g.conversation_id, uid);
  notifyGroup(ctx.g.conversation_id, gid, 'member');
  res.json({ ok: true });
});

// 拉人入群（群成员均可拉人）
router.post('/:groupId/members', (req, res) => {
  const uid = uidOf(req, res); if (uid === null) return;
  const gid = Number(req.params.groupId);
  const ctx = loadGroup(gid, uid, res); if (!ctx) return;
  const userId = Number(req.body?.userId);
  if (!db.prepare('SELECT id FROM users WHERE id=?').get(userId)) return res.status(404).json({ error: 'user not found' });
  if (!db.prepare('SELECT user_id FROM group_members WHERE group_id=? AND user_id=?').get(gid, userId)) {
    db.prepare('INSERT INTO group_members (group_id,user_id,role,joined_at) VALUES (?,?,?,?)').run(gid, userId, 'member', Date.now());
  }
  if (!db.prepare('SELECT user_id FROM conversation_members WHERE conversation_id=? AND user_id=?').get(ctx.g.conversation_id, userId)) {
    db.prepare('INSERT INTO conversation_members (conversation_id,user_id) VALUES (?,?)').run(ctx.g.conversation_id, userId);
  }
  notifyGroup(ctx.g.conversation_id, gid, 'member');
  hub.broadcastToUser(userId, { type: 'group:invited', groupId: gid, conversationId: ctx.g.conversation_id });
  res.json({ ok: true });
});

module.exports = router;
