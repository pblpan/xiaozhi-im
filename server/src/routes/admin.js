const router = require('express').Router();
const fs = require('fs');
const path = require('path');
const db = require('../db');
const config = require('../config');
const { verifyToken, hashPassword, verifyPassword } = require('../auth');

function adminOf(req, res) {
  const c = verifyToken(req.headers.authorization?.replace('Bearer ', ''));
  if (!c) { res.status(401).json({ error: 'unauthorized' }); return null; }
  const u = db.prepare('SELECT role FROM users WHERE id=?').get(c.uid);
  if (!u || u.role !== 'admin') { res.status(403).json({ error: 'forbidden' }); return null; }
  return c.uid;
}

router.get('/stats', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  const c = (sql) => db.prepare(sql).get().c;
  res.json({
    users: c('SELECT COUNT(*) c FROM users'),
    groups: c('SELECT COUNT(*) c FROM groups'),
    messages: c('SELECT COUNT(*) c FROM messages'),
    files: c('SELECT COUNT(*) c FROM files'),
    friendships: c("SELECT COUNT(*) c FROM friendships WHERE status='accepted'"),
    // 分类计数：便于管理员一眼看清各类消息占比
    text: c("SELECT COUNT(*) c FROM messages WHERE kind='text' AND deleted=0"),
    images: c("SELECT COUNT(*) c FROM messages WHERE kind='image' AND deleted=0"),
    audios: c("SELECT COUNT(*) c FROM messages WHERE kind='audio' AND deleted=0"),
    recalled: c('SELECT COUNT(*) c FROM messages WHERE deleted=1'),
    edited: c('SELECT COUNT(*) c FROM messages WHERE edited=1 AND deleted=0'),
  });
});

router.get('/info', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  res.json({
    port: config.PORT,
    db_path: config.DB_PATH,
    data_dir: config.DATA_DIR,
    files_dir: config.FILES_DIR,
    max_file_mb: config.MAX_FILE_MB,
    files_disk_bytes: (() => {
      try {
        const total = fs.readdirSync(config.FILES_DIR).reduce((sum, n) => {
          try { return sum + fs.statSync(path.join(config.FILES_DIR, n)).size; }
          catch { return sum; }
        }, 0);
        return total;
      } catch { return 0; }
    })(),
    node: process.version,
  });
});

/* ==================== Users ==================== */

router.get('/users', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  res.json(db.prepare('SELECT id,username,nickname,avatar,role,created_at FROM users ORDER BY id DESC LIMIT 500').all());
});

router.post('/users', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  const { username, password, nickname, role } = req.body || {};
  if (!username || !password) return res.status(400).json({ error: 'username/password required' });
  if (String(password).length < 6) return res.status(400).json({ error: '密码至少 6 位' });
  const exists = db.prepare('SELECT id FROM users WHERE username=?').get(username);
  if (exists) return res.status(409).json({ error: '账号已存在' });
  const r = db.prepare('INSERT INTO users (username,password_hash,nickname,role,created_at) VALUES (?,?,?,?,?)')
    .run(username, hashPassword(password), nickname || username, role === 'admin' ? 'admin' : 'user', Date.now());
  res.json({ id: r.lastInsertRowid });
});

router.patch('/users/:id', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  const target = Number(req.params.id);
  const { nickname, role, password, avatar } = req.body || {};
  const u = db.prepare('SELECT id,role FROM users WHERE id=?').get(target);
  if (!u) return res.status(404).json({ error: 'user not found' });

  const sets = []; const args = [];
  if (typeof nickname === 'string') { sets.push('nickname=?'); args.push(nickname); }
  if (typeof avatar === 'string') { sets.push('avatar=?'); args.push(avatar); }
  if (role === 'admin' || role === 'user') { sets.push('role=?'); args.push(role); }
  if (password) {
    if (String(password).length < 6) return res.status(400).json({ error: '密码至少 6 位' });
    sets.push('password_hash=?'); args.push(hashPassword(password));
  }
  if (!sets.length) return res.json({ ok: true, noop: true });
  args.push(target);
  db.prepare(`UPDATE users SET ${sets.join(',')} WHERE id=?`).run(...args);
  res.json({ ok: true });
});

router.post('/users/:id/role', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  const role = req.body?.role === 'admin' ? 'admin' : 'user';
  db.prepare('UPDATE users SET role=? WHERE id=?').run(role, Number(req.params.id));
  res.json({ ok: true });
});

router.delete('/users/:id', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  const target = Number(req.params.id);
  if (target === uid) return res.status(400).json({ error: 'cannot delete self' });
  // 清理该用户留下的痕迹（不让好友/群成员记录引用空 user）
  db.prepare('DELETE FROM friendships WHERE user_id=? OR friend_id=?').run(target, target);
  db.prepare('DELETE FROM group_members WHERE user_id=?').run(target);
  const ownedGroups = db.prepare('SELECT id,conversation_id FROM groups WHERE owner_id=?').all(target);
  for (const g of ownedGroups) {
    db.prepare('DELETE FROM groups WHERE id=?').run(g.id);
    db.prepare('DELETE FROM group_members WHERE group_id=?').run(g.id);
    if (g.conversation_id) db.prepare('DELETE FROM conversation_members WHERE conversation_id=?').run(g.conversation_id);
  }
  db.prepare('DELETE FROM users WHERE id=?').run(target);
  res.json({ ok: true });
});

/* ==================== Groups ==================== */

router.get('/groups', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  res.json(db.prepare(`SELECT g.id,g.name,g.owner_id,u.nickname owner_name,g.created_at,
    (SELECT COUNT(*) FROM group_members gm WHERE gm.group_id=g.id) members
    FROM groups g JOIN users u ON u.id=g.owner_id ORDER BY g.id DESC`).all());
});

router.post('/groups', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  const { name, owner_id, member_ids } = req.body || {};
  if (!name) return res.status(400).json({ error: 'name required' });
  const owner = owner_id || uid;
  if (!db.prepare('SELECT id FROM users WHERE id=?').get(owner)) return res.status(400).json({ error: 'owner 不存在' });

  // node:sqlite 没有 transaction()，手工 BEGIN/COMMIT/ROLLBACK
  db.exec('BEGIN');
  try {
    const conv = db.prepare('INSERT INTO conversations (type,created_at) VALUES (?,?)').run('group', Date.now());
    const convId = conv.lastInsertRowid;
    db.prepare('INSERT INTO conversation_members (conversation_id,user_id) VALUES (?,?)').run(convId, owner);
    const g = db.prepare('INSERT INTO groups (name,owner_id,conversation_id,created_at) VALUES (?,?,?,?)')
      .run(name, owner, convId, Date.now());
    db.prepare('INSERT INTO group_members (group_id,user_id,role,joined_at) VALUES (?,?,?,?)')
      .run(g.lastInsertRowid, owner, 'owner', Date.now());
    const ids = Array.isArray(member_ids) ? member_ids.filter((x) => Number.isInteger(x) && x !== owner) : [];
    const ins = db.prepare('INSERT INTO group_members (group_id,user_id,joined_at) VALUES (?,?,?)');
    const insC = db.prepare('INSERT OR IGNORE INTO conversation_members (conversation_id,user_id) VALUES (?,?)');
    for (const mid of ids) {
      if (db.prepare('SELECT id FROM users WHERE id=?').get(mid)) {
        ins.run(g.lastInsertRowid, mid, Date.now());
        insC.run(convId, mid);
      }
    }
    db.exec('COMMIT');
    res.json({ id: g.lastInsertRowid });
  } catch (e) {
    db.exec('ROLLBACK');
    res.status(500).json({ error: e.message });
  }
});

router.patch('/groups/:id', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  const gid = Number(req.params.id);
  const g = db.prepare('SELECT id,name,owner_id,conversation_id FROM groups WHERE id=?').get(gid);
  if (!g) return res.status(404).json({ error: 'group not found' });
  const { name, owner_id, member_ids } = req.body || {};

  db.exec('BEGIN');
  try {
    if (typeof name === 'string' && name) db.prepare('UPDATE groups SET name=? WHERE id=?').run(name, gid);
    if (Number.isInteger(owner_id) && owner_id !== g.owner_id) {
      if (!db.prepare('SELECT id FROM users WHERE id=?').get(owner_id)) {
        db.exec('ROLLBACK');
        return res.status(400).json({ error: '新群主不存在' });
      }
      db.prepare('UPDATE groups SET owner_id=? WHERE id=?').run(owner_id, gid);
      db.prepare('UPDATE group_members SET role=? WHERE group_id=? AND user_id=?').run('owner', gid, owner_id);
      db.prepare('UPDATE group_members SET role=? WHERE group_id=? AND user_id=?').run('member', gid, g.owner_id);
      db.prepare('INSERT OR IGNORE INTO conversation_members (conversation_id,user_id) VALUES (?,?)').run(g.conversation_id, owner_id);
    }
    if (Array.isArray(member_ids)) {
      const cur = new Set(db.prepare('SELECT user_id FROM group_members WHERE group_id=?').all(gid).map((r) => r.user_id));
      const want = new Set(member_ids.filter(Number.isInteger));
      want.add(g.owner_id);
      const ins = db.prepare('INSERT OR IGNORE INTO group_members (group_id,user_id,joined_at) VALUES (?,?,?)');
      const insC = db.prepare('INSERT OR IGNORE INTO conversation_members (conversation_id,user_id) VALUES (?,?)');
      for (const m of want) if (!cur.has(m)) {
        if (db.prepare('SELECT id FROM users WHERE id=?').get(m)) { ins.run(gid, m, Date.now()); insC.run(g.conversation_id, m); }
      }
      const del = db.prepare('DELETE FROM group_members WHERE group_id=? AND user_id=?');
      const delC = db.prepare('DELETE FROM conversation_members WHERE conversation_id=? AND user_id=?');
      for (const m of cur) if (!want.has(m) && m !== g.owner_id) {
        del.run(gid, m);
        delC.run(g.conversation_id, m);
      }
    }
    db.exec('COMMIT');
    res.json({ ok: true });
  } catch (e) {
    db.exec('ROLLBACK');
    res.status(500).json({ error: e.message });
  }
});

router.delete('/groups/:id', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  const gid = Number(req.params.id);
  const g = db.prepare('SELECT conversation_id FROM groups WHERE id=?').get(gid);
  db.prepare('DELETE FROM groups WHERE id=?').run(gid);
  db.prepare('DELETE FROM group_members WHERE group_id=?').run(gid);
  if (g) db.prepare('DELETE FROM conversation_members WHERE conversation_id=?').run(g.conversation_id);
  res.json({ ok: true });
});

/* ==================== Files ==================== */

router.get('/files', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  res.json(db.prepare(`SELECT f.id,f.name,f.mime,f.size,f.path,f.created_at,u.username owner,f.owner_id
    FROM files f LEFT JOIN users u ON u.id=f.owner_id ORDER BY f.id DESC LIMIT 500`).all());
});

router.delete('/files/:id', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  const fid = Number(req.params.id);
  const f = db.prepare('SELECT path FROM files WHERE id=?').get(fid);
  if (!f) return res.status(404).json({ error: 'file not found' });
  // 解除消息引用 + 删磁盘文件
  db.prepare('UPDATE messages SET file_id=NULL,kind=?,content=? WHERE file_id=?').run('text', '[文件已被管理员删除]', fid);
  db.prepare('DELETE FROM files WHERE id=?').run(fid);
  try { fs.unlinkSync(path.join(config.FILES_DIR, f.path)); } catch {}
  res.json({ ok: true });
});

/* ==================== Messages ==================== */

router.get('/messages', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  const limit = Math.min(Number(req.query.limit) || 200, 1000);
  const kind = String(req.query.kind || '').trim();
  const q = String(req.query.q || '').trim();

  const where = [];
  const params = [];
  if (kind) { where.push('m.kind = ?'); params.push(kind); }
  if (q) {
    // 转义 LIKE 通配符，避免管理员输入 % 变全表扫描
    where.push("m.content LIKE ? ESCAPE '\\'");
    params.push('%' + q.replace(/[\\%_]/g, (ch) => '\\' + ch) + '%');
  }
  params.push(limit);

  const rows = db.prepare(`SELECT m.id,m.conversation_id,m.sender_id,u.username sender_name,m.kind,m.content,m.file_id,m.created_at,m.deleted,m.edited
    FROM messages m LEFT JOIN users u ON u.id=m.sender_id
    ${where.length ? 'WHERE ' + where.join(' AND ') : ''}
    ORDER BY m.id DESC LIMIT ?`).all(...params);
  res.json(rows);
});

router.delete('/messages/:id', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  const mid = Number(req.params.id);
  const m = db.prepare('SELECT file_id FROM messages WHERE id=?').get(mid);
  if (!m) return res.status(404).json({ error: 'message not found' });
  // 物理删除消息；如果是文件消息，且是该文件唯一引用，一并删磁盘
  db.prepare('DELETE FROM messages WHERE id=?').run(mid);
  if (m.file_id) {
    const still = db.prepare('SELECT COUNT(*) c FROM messages WHERE file_id=?').get(m.file_id).c;
    if (still === 0) {
      const f = db.prepare('SELECT path FROM files WHERE id=?').get(m.file_id);
      if (f) {
        db.prepare('DELETE FROM files WHERE id=?').run(m.file_id);
        try { fs.unlinkSync(path.join(config.FILES_DIR, f.path)); } catch {}
      }
    }
  }
  res.json({ ok: true });
});

/* ==================== Friendships ==================== */

router.get('/friendships', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  res.json(db.prepare(`SELECT fs.id,fs.user_id,fs.friend_id,fs.status,fs.created_at,
    ua.username user_name, ub.username friend_name
    FROM friendships fs
    LEFT JOIN users ua ON ua.id=fs.user_id
    LEFT JOIN users ub ON ub.id=fs.friend_id
    ORDER BY fs.id DESC LIMIT 500`).all());
});

router.delete('/friendships/:id', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  const id = Number(req.params.id);
  db.prepare('DELETE FROM friendships WHERE id=?').run(id);
  res.json({ ok: true });
});

/* ==================== Self password ==================== */

router.post('/change-password', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  const { old_password, new_password } = req.body || {};
  if (!old_password || !new_password) return res.status(400).json({ error: '旧密码与新密码必填' });
  if (String(new_password).length < 6) return res.status(400).json({ error: '新密码至少 6 位' });
  const u = db.prepare('SELECT password_hash FROM users WHERE id=?').get(uid);
  if (!verifyPassword(old_password, u.password_hash)) return res.status(400).json({ error: '旧密码错误' });
  db.prepare('UPDATE users SET password_hash=? WHERE id=?').run(hashPassword(new_password), uid);
  res.json({ ok: true });
});

module.exports = router;