const router = require('express').Router();
const db = require('../db');
const { verifyToken } = require('../auth');
const hub = require('../hub');
const events = require('../events');

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

  // 🔴 系统管理员在**任何群**里都算管理员（龙哥 2026-10-10："保留系统管理员
  //    可以主动直接进入和加入所有群聊"）。POST /:groupId/join 把管理员加进来时
  //    给的是 member 角色 —— 只看群内角色的话，管理员进了群却改不了群名、
  //    挂不了课程，等于"进得去、管不了"，比进不去更让人困惑。
  //    ⚠️ 但 isOwner **不跟着升**：转让群主、被踢保护这类"群归属"的操作
  //    仍然只认真正的群主，系统管理员不能把别人的群转走。
  const isSysAdmin = db.prepare('SELECT role FROM users WHERE id=?').get(uid)?.role === 'admin';
  return {
    g, me, isSysAdmin,
    isOwner: g.owner_id === uid,
    isAdmin: me.role === 'admin' || g.owner_id === uid || isSysAdmin,
  };
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
  // 4 步写入必须原子（审计 P1-2）：conversations / groups / group_members /
  // conversation_members 缺一不可。中途失败若不回滚，会留下
  // "群建好了但建群者不在群里"（loadGroup 直接 403）或"会话建了没群"的孤儿会话。
  // 本库 0 外键（见 db.js），数据库不会帮你拦，只能靠事务。
  db.exec('BEGIN');
  let cid, gid;
  try {
    const cinfo = db.prepare("INSERT INTO conversations (type,created_at) VALUES ('group',?)").run(Date.now());
    cid = cinfo.lastInsertRowid;
    const ginfo = db.prepare('INSERT INTO groups (name,owner_id,conversation_id,created_at) VALUES (?,?,?,?)')
      .run(name, uid, cid, Date.now());
    gid = ginfo.lastInsertRowid;
    db.prepare('INSERT INTO group_members (group_id,user_id,role,joined_at) VALUES (?,?,?,?)').run(gid, uid, 'owner', Date.now());
    db.prepare('INSERT INTO conversation_members (conversation_id,user_id) VALUES (?,?)').run(cid, uid);
    db.exec('COMMIT');
  } catch (e) {
    db.exec('ROLLBACK');
    return res.status(500).json({ error: e.message });
  }
  // 事件放在 COMMIT 之后：广播出去之后对方就该能查到这个群了，
  // 在事务内 emit 有可能让对端先收到通知、回头却查不到（读不到已回滚的中间态）。
  events.emit('conversation.created', {
    conversationId: cid,
    selfId: uid,
    data: { type: 'group', groupId: gid, name },
  });
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

/**
 * 全部群（仅系统管理员）—— 配合 POST /:groupId/join 用。
 * 「管理员要能进所有群」这句话里藏着一个前提：他得先**看得到**有哪些群。
 * /my 只返回我加入的，管理员一个群都没进过时那里是空的，
 * 于是"能进所有群"变成了"不知道有群可进"。
 */
router.get('/all', (req, res) => {
  const uid = uidOf(req, res); if (uid === null) return;
  const me = db.prepare('SELECT role FROM users WHERE id=?').get(uid);
  if (!me || me.role !== 'admin') return res.status(403).json({ error: '只有系统管理员可以查看全部群' });
  const rows = db.prepare(`
    SELECT g.id, g.name, g.avatar, g.conversation_id, g.created_at,
           u.nickname AS owner_name,
           (SELECT COUNT(*) FROM group_members gm WHERE gm.group_id = g.id) AS members,
           EXISTS(SELECT 1 FROM group_members m2 WHERE m2.group_id = g.id AND m2.user_id = ?) AS joined
      FROM groups g LEFT JOIN users u ON u.id = g.owner_id
     ORDER BY g.id DESC`).all(uid);
  res.json({ items: rows.map((r) => ({ ...r, joined: !!r.joined })), total: rows.length });
});

// 群信息 + 成员 + 我的角色
router.get('/:groupId', (req, res) => {
  const uid = uidOf(req, res); if (uid === null) return;
  const gid = Number(req.params.groupId);
  const ctx = loadGroup(gid, uid, res); if (!ctx) return;
  const members = db.prepare(`SELECT u.id,u.username,u.nickname,u.avatar,u.is_bot,m.role,m.muted_until,m.joined_at
    FROM group_members m JOIN users u ON u.id=m.user_id WHERE m.group_id=?`).all(gid)
    .map((m) => ({ ...m, is_bot: !!m.is_bot }));
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
  // 系统管理员不受"管理员不能移出管理员"这条限制 —— 他就是兜底的那个人，
  // 真出现管理员胡来的情况，总得有个人能处理
  if (!ctx.isOwner && tm.role === 'admin' && !ctx.isSysAdmin) {
    return res.status(403).json({ error: '管理员不能移出其他管理员' });
  }

  db.prepare('DELETE FROM group_members WHERE group_id=? AND user_id=?').run(gid, target);
  db.prepare('DELETE FROM conversation_members WHERE conversation_id=? AND user_id=?').run(ctx.g.conversation_id, target);
  notifyGroup(ctx.g.conversation_id, gid, 'member');
  hub.broadcastToUser(target, { type: 'group:kicked', groupId: gid, conversationId: ctx.g.conversation_id });
  events.emit('member.left', {
    conversationId: ctx.g.conversation_id,
    selfId: uid,
    data: { groupId: gid, userId: target, reason: 'kicked', operatorId: uid },
  });
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
  events.emit('member.left', {
    conversationId: ctx.g.conversation_id,
    selfId: uid,
    data: { groupId: gid, userId: uid, reason: 'leave' },
  });
  res.json({ ok: true });
});

// 拉人入群（群成员均可拉人）
router.post('/:groupId/members', (req, res) => {
  const uid = uidOf(req, res); if (uid === null) return;
  const gid = Number(req.params.groupId);
  const ctx = loadGroup(gid, uid, res); if (!ctx) return;
  const userId = Number(req.body?.userId);
  if (!db.prepare('SELECT id FROM users WHERE id=?').get(userId)) return res.status(404).json({ error: 'user not found' });
  // 2 步写入要原子（审计 P1-2）：group_members 与 conversation_members 必须在同一事务。
  // 只插前者的话，这人能在"群成员列表"里看到群，却收不到任何群消息
  // （发消息是按 conversation_members 投递的），而界面不会给任何提示 —— 极难排查。
  db.exec('BEGIN');
  try {
    if (!db.prepare('SELECT user_id FROM group_members WHERE group_id=? AND user_id=?').get(gid, userId)) {
      db.prepare('INSERT INTO group_members (group_id,user_id,role,joined_at) VALUES (?,?,?,?)').run(gid, userId, 'member', Date.now());
    }
    if (!db.prepare('SELECT user_id FROM conversation_members WHERE conversation_id=? AND user_id=?').get(ctx.g.conversation_id, userId)) {
      db.prepare('INSERT INTO conversation_members (conversation_id,user_id) VALUES (?,?)').run(ctx.g.conversation_id, userId);
    }
    db.exec('COMMIT');
  } catch (e) {
    db.exec('ROLLBACK');
    return res.status(500).json({ error: e.message });
  }
  // 广播放在 COMMIT 之后：通知出去时数据已经落库，对端刷新就能看到。
  notifyGroup(ctx.g.conversation_id, gid, 'member');
  hub.broadcastToUser(userId, { type: 'group:invited', groupId: gid, conversationId: ctx.g.conversation_id });
  events.emit('member.joined', {
    conversationId: ctx.g.conversation_id,
    selfId: uid,
    data: { groupId: gid, userId, operatorId: uid },
  });
  res.json({ ok: true });
});

/* ============================================================
 * 群功能面板：群文件 / 群相册 / 群视频 / 群课堂
 *
 * 前三样**不建新表** —— 群里发过的东西本来就在 messages 里，
 * 再复制一份到"群文件表"就等于两处真相：撤回了的消息在群文件里还在、
 * 换了个文件名两处对不上。这里直接从消息流聚合，天然跟着撤回走。
 * 只有群课堂需要新表（group_courses），因为它关联的是培训中心的课程，
 * 不是消息。
 * ============================================================ */

/** 该群会话里某类消息的原始行（带上传者与文件信息） */
function collectGroupMedia(gid, kinds, mimePrefix) {
  const g = db.prepare('SELECT conversation_id FROM groups WHERE id=?').get(gid);
  if (!g) return [];
  const sql = `
    SELECT m.id, m.kind, m.content, m.created_at, m.sender_id, m.file_id,
           u.nickname AS sender_name, u.username AS sender_username, u.avatar AS sender_avatar,
           f.name AS file_name, f.mime AS file_mime, f.size AS file_size, f.path AS file_path
      FROM messages m
      JOIN users u ON u.id = m.sender_id
      LEFT JOIN files f ON f.id = m.file_id
     WHERE m.conversation_id = ? AND m.deleted = 0 AND m.kind IN (${kinds.map(() => '?').join(',')})
       ${mimePrefix ? 'AND f.mime LIKE ?' : ''}
     ORDER BY m.id DESC`;
  const args = [g.conversation_id, ...kinds];
  if (mimePrefix) args.push(mimePrefix + '%');
  return db.prepare(sql).all(...args);
}

/** 把一行媒体消息整理成前端直接能渲染的形状；file_path 不外泄，只给访问地址 */
function shapeMedia(r) {
  return {
    id: r.id,
    kind: r.kind,
    createdAt: r.created_at,
    sender: { id: r.sender_id, name: r.sender_name || r.sender_username, avatar: r.sender_avatar },
    // 图片消息的 content 就是 /files/xxx；文件消息要从 files 表 join 出来
    url: r.kind === 'image' ? r.content : (r.file_path ? `/files/${r.file_path}` : null),
    name: r.file_name || null,
    mime: r.file_mime || null,
    size: r.file_size || null,
    fileId: r.file_id || null,
  };
}

/** 群文件：群里发过的所有文件（不含图片，图片归群相册） */
router.get('/:groupId/files', (req, res) => {
  const uid = uidOf(req, res); if (uid === null) return;
  const gid = Number(req.params.groupId);
  const ctx = loadGroup(gid, uid, res); if (!ctx) return;
  const rows = collectGroupMedia(gid, ['file']);
  res.json({ items: rows.map(shapeMedia), total: rows.length });
});

/** 群相册：群里发过的所有图片，最近的最先 */
router.get('/:groupId/albums', (req, res) => {
  const uid = uidOf(req, res); if (uid === null) return;
  const gid = Number(req.params.groupId);
  const ctx = loadGroup(gid, uid, res); if (!ctx) return;
  const rows = collectGroupMedia(gid, ['image']);
  res.json({ items: rows.map(shapeMedia), total: rows.length });
});

/** 群视频：群里发过的视频文件（按 mime 前缀筛，不靠扩展名猜） */
router.get('/:groupId/videos', (req, res) => {
  const uid = uidOf(req, res); if (uid === null) return;
  const gid = Number(req.params.groupId);
  const ctx = loadGroup(gid, uid, res); if (!ctx) return;
  const rows = collectGroupMedia(gid, ['file'], 'video/');
  res.json({ items: rows.map(shapeMedia), total: rows.length });
});

/** 群课堂：这个群挂了哪些培训中心的课（带我自己的学习进度） */
router.get('/:groupId/courses', (req, res) => {
  const uid = uidOf(req, res); if (uid === null) return;
  const gid = Number(req.params.groupId);
  const ctx = loadGroup(gid, uid, res); if (!ctx) return;
  const rows = db.prepare(`
    SELECT c.id, c.title, c.intro, c.category, c.required, c.cover_file_id,
           gc.created_at AS linked_at, gc.created_by,
           (SELECT COUNT(*) FROM tr_chapter ch WHERE ch.course_id = c.id) AS chapter_count,
           (SELECT COUNT(*) FROM tr_lesson l JOIN tr_chapter ch2 ON ch2.id = l.chapter_id
             WHERE ch2.course_id = c.id) AS lesson_count
      FROM group_courses gc
      JOIN tr_course c ON c.id = gc.course_id
     WHERE gc.group_id = ?
     ORDER BY gc.created_at DESC`).all(gid);

  const progress = db.prepare(`SELECT COUNT(*) total,
      SUM(CASE WHEN p.done = 1 THEN 1 ELSE 0 END) done
    FROM tr_lesson l JOIN tr_chapter ch ON ch.id = l.chapter_id
    LEFT JOIN tr_progress p ON p.lesson_id = l.id AND p.user_id = ?
    WHERE ch.course_id = ?`);

  res.json({
    items: rows.map((c) => {
      const p = progress.get(uid, c.id) || { total: 0, done: 0 };
      const total = Number(p.total) || 0;
      const done = Number(p.done) || 0;
      return {
        id: c.id,
        title: c.title,
        intro: c.intro,
        category: c.category,
        required: !!c.required,
        cover: c.cover_file_id,
        chapterCount: Number(c.chapter_count) || 0,
        lessonCount: Number(c.lesson_count) || 0,
        // 没课时也不能省这个字段：客户端"有数据才渲染"会让人以为没记录
        progressPct: total ? Math.round((done * 100) / total) : 0,
        linkedAt: c.linked_at,
      };
    }),
    // 群主/管理员才需要"挂课程"按钮，前端按这个决定要不要显示
    canManage: ctx.isAdmin,
  });
});

/** 挂一门课到群里（群主或管理员） */
router.post('/:groupId/courses', (req, res) => {
  const uid = uidOf(req, res); if (uid === null) return;
  const gid = Number(req.params.groupId);
  const cid = Number((req.body || {}).courseId);
  const ctx = loadGroup(gid, uid, res); if (!ctx) return;
  if (!ctx.isAdmin) return res.status(403).json({ error: '只有群主或管理员可以挂课程' });
  if (!Number.isInteger(cid) || cid <= 0) return res.status(400).json({ error: '课程 id 不合法' });
  if (!db.prepare('SELECT id FROM tr_course WHERE id=?').get(cid)) {
    return res.status(404).json({ error: '课程不存在' });
  }
  if (db.prepare('SELECT 1 FROM group_courses WHERE group_id=? AND course_id=?').get(gid, cid)) {
    return res.json({ ok: true, duplicated: true });   // 重复挂不算错，幂等
  }
  db.prepare('INSERT INTO group_courses (group_id,course_id,created_by,created_at) VALUES (?,?,?,?)')
    .run(gid, cid, uid, Date.now());
  notifyGroup(ctx.g.conversation_id, gid, 'course:linked', { courseId: cid });
  res.json({ ok: true });
});

/** 从群里摘掉一门课（群主或管理员）；只解关联，不动课程本身 */
router.delete('/:groupId/courses/:courseId', (req, res) => {
  const uid = uidOf(req, res); if (uid === null) return;
  const gid = Number(req.params.groupId);
  const cid = Number(req.params.courseId);
  const ctx = loadGroup(gid, uid, res); if (!ctx) return;
  if (!ctx.isAdmin) return res.status(403).json({ error: '只有群主或管理员可以摘课程' });
  db.prepare('DELETE FROM group_courses WHERE group_id=? AND course_id=?').run(gid, cid);
  notifyGroup(ctx.g.conversation_id, gid, 'course:unlinked', { courseId: cid });
  res.json({ ok: true });
});

/**
 * 系统管理员直接进群（龙哥 2026-10-10 要的"管理员可主动进入和加入所有群聊"）。
 *
 * 为什么单独一个端点而不是顺手放开 loadGroup：
 *   放开 loadGroup 的话，管理员能"看"但不能"说话"（不在 conversation_members
 *   里就收不到消息、发消息会被拒），界面上就是"进得去、发不出"的半残状态。
 *   这里一次性把 group_members 和 conversation_members 都补齐 —— 要么不进，
 *   要么就是个能正常收发消息的普通成员。
 */
router.post('/:groupId/join', (req, res) => {
  const uid = uidOf(req, res); if (uid === null) return;
  const gid = Number(req.params.groupId);
  const me = db.prepare('SELECT role FROM users WHERE id=?').get(uid);
  if (!me || me.role !== 'admin') return res.status(403).json({ error: '只有系统管理员可以直接进群' });
  const g = db.prepare('SELECT id,conversation_id FROM groups WHERE id=?').get(gid);
  if (!g) return res.status(404).json({ error: '群不存在' });

  db.exec('BEGIN');
  try {
    if (!db.prepare('SELECT user_id FROM group_members WHERE group_id=? AND user_id=?').get(gid, uid)) {
      db.prepare('INSERT INTO group_members (group_id,user_id,role,joined_at) VALUES (?,?,?,?)')
        .run(gid, uid, 'member', Date.now());
    }
    if (!db.prepare('SELECT user_id FROM conversation_members WHERE conversation_id=? AND user_id=?')
      .get(g.conversation_id, uid)) {
      db.prepare('INSERT INTO conversation_members (conversation_id,user_id) VALUES (?,?)')
        .run(g.conversation_id, uid);
    }
    db.exec('COMMIT');
  } catch (e) {
    db.exec('ROLLBACK');
    return res.status(500).json({ error: e.message });
  }
  hub.broadcastToUser(uid, { type: 'conversation.created', conversationId: g.conversation_id, data: { groupId: gid } });
  notifyGroup(g.conversation_id, gid, 'member');
  res.json({ ok: true, conversationId: g.conversation_id });
});

module.exports = router;
