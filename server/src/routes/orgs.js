const router = require('express').Router();
const db = require('../db');
const { verifyToken, hashPassword } = require('../auth');
const settings = require('../settings');

function uidOf(req, res) {
  const c = verifyToken(req.headers.authorization?.replace('Bearer ', ''));
  if (!c) { res.status(401).json({ error: 'unauthorized' }); return null; }
  return c.uid;
}

function adminOf(req, res) {
  const uid = uidOf(req, res); if (uid === null) return null;
  const u = db.prepare('SELECT role FROM users WHERE id=?').get(uid);
  if (!u || u.role !== 'admin') { res.status(403).json({ error: 'forbidden' }); return null; }
  return uid;
}

// 工作模式下才允许组织机构操作。返回 null 表示已放行/已响应。
function requireWorkMode(req, res) {
  if (settings.get('friendMode') === 'work') return true;
  res.status(400).json({ error: '请先在管理后台切换到工作模式' });
  return false;
}

const ORG_COLS = 'u.id,u.username,u.nickname,u.avatar,u.signature,u.employee_no';
const MAX_MEMBERS = 500;

// ============================================================
// 创建组织（一个服务器一个组织，admin 专属）
// ============================================================
router.post('/', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  if (!requireWorkMode(req, res)) return;

  const name = String(req.body?.name || '').trim();
  if (name.length < 2 || name.length > 30) {
    return res.status(400).json({ error: '组织名 2-30 个字' });
  }
  if (db.prepare('SELECT id FROM orgs LIMIT 1').get()) {
    return res.status(409).json({ error: '本服务器已创建组织，一个服务器只支持一个组织' });
  }
  const info = db.prepare('INSERT INTO orgs (name, created_by, created_at) VALUES (?,?,?)')
    .run(name, uid, Date.now());
  res.json({ id: info.lastInsertRowid, name });
});

// ============================================================
// 我的组织（admin=我创建的；员工=我所属的）。没组织返回 null
// ============================================================
router.get('/my', (req, res) => {
  const uid = uidOf(req, res); if (uid === null) return;
  const me = db.prepare('SELECT id, role, org_id FROM users WHERE id=?').get(uid);

  let org = null;
  if (me.role === 'admin') {
    org = db.prepare('SELECT id, name, created_by FROM orgs LIMIT 1').get() || null;
  } else if (me.org_id) {
    org = db.prepare('SELECT id, name, created_by FROM orgs WHERE id=?').get(me.org_id) || null;
  }
  if (!org) return res.json({ org: null, members: [] });

  const members = db.prepare(`SELECT ${ORG_COLS} FROM users u
    WHERE u.org_id=? ORDER BY u.id`).all(org.id);
  res.json({ org, members });
});

// ============================================================
// 添加员工（工号=账号，初始密码=工号，自动与全员互为好友）
// ============================================================
router.post('/:id/members', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  if (!requireWorkMode(req, res)) return;

  const orgId = Number(req.params.id);
  if (!Number.isInteger(orgId) || orgId <= 0) return res.status(400).json({ error: '组织 id 不合法' });
  const org = db.prepare('SELECT id, name, created_by FROM orgs WHERE id=?').get(orgId);
  if (!org) return res.status(404).json({ error: '组织不存在' });
  if (org.created_by !== uid) return res.status(403).json({ error: '只有组织创建者可以添加员工' });

  const employeeNo = String(req.body?.employeeNo || '').trim();
  const nickname = String(req.body?.nickname || '').trim();
  // 工号即登录账号，沿用账号的字符纪律：字母/数字/下划线，避免和显示名混淆
  if (!/^[A-Za-z0-9_]{3,20}$/.test(employeeNo)) {
    return res.status(400).json({ error: '工号 3-20 位，仅限字母、数字、下划线' });
  }
  if (nickname && [...nickname].length > 24) return res.status(400).json({ error: '昵称最多 24 个字' });

  const count = db.prepare('SELECT COUNT(*) AS c FROM users WHERE org_id=?').get(orgId).c;
  if (count >= MAX_MEMBERS) return res.status(400).json({ error: `组织成员已达上限（${MAX_MEMBERS} 人）` });

  // 工号=账号：撞 users.username 的 UNIQUE 约束 = 工号已被占用
  let newUid;
  try {
    const info = db.prepare(`INSERT INTO users (username, password_hash, nickname, role, org_id, employee_no, created_at)
      VALUES (?,?,?,?,?,?,?)`)
      .run(employeeNo, hashPassword(employeeNo), nickname || employeeNo, 'user', orgId, employeeNo, Date.now());
    newUid = info.lastInsertRowid;
  } catch (e) {
    if (/UNIQUE/i.test(e.message)) {
      return res.status(409).json({ error: `工号 ${employeeNo} 已被占用（可能是重名账号或已录入）` });
    }
    throw e;
  }

  // 同事自动互为好友：与「组织内现有员工 + 管理员」各落两条 accepted。
  // 不走 pending→accept 流程 —— 工作模式没有"申请同意"语义，
  // 老板录完人，员工登录就能直接找到所有同事（会话列表直接可用）。
  const mateIds = db.prepare('SELECT id FROM users WHERE org_id=? AND id<>?').all(orgId, newUid).map((r) => r.id);
  if (!mateIds.includes(uid)) mateIds.push(uid); // 管理员（无工号）也要能找到员工
  const now = Date.now();
  const ins = db.prepare("INSERT OR IGNORE INTO friendships (user_id,friend_id,status,created_at) VALUES (?,?,'accepted',?)");
  // node:sqlite 没有 better-sqlite3 的 db.transaction()，用显式 SQL 事务；
  // 半途失败回滚，避免"加了一半好友"的脏状态
  db.exec('BEGIN');
  try {
    for (const mate of mateIds) {
      ins.run(newUid, mate, now);
      ins.run(mate, newUid, now);
    }
    db.exec('COMMIT');
  } catch (e) {
    try { db.exec('ROLLBACK'); } catch { /* 事务已结束 */ }
    throw e;
  }

  const user = db.prepare(`SELECT ${ORG_COLS} FROM users u WHERE u.id=?`).get(newUid);
  res.json({ user });
});

// ============================================================
// 移除员工（禁用语义：账号保留、退出组织、好友关系解除）
// ============================================================
router.delete('/:id/members/:uid', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  const orgId = Number(req.params.id);
  const target = Number(req.params.uid);
  const org = db.prepare('SELECT id, created_by FROM orgs WHERE id=?').get(orgId);
  if (!org) return res.status(404).json({ error: '组织不存在' });
  if (org.created_by !== uid) return res.status(403).json({ error: '只有组织创建者可以移除员工' });
  const u = db.prepare('SELECT id, org_id, role FROM users WHERE id=?').get(target);
  if (!u || u.org_id !== orgId) return res.status(404).json({ error: '该用户不是本组织成员' });

  db.prepare('UPDATE users SET org_id=NULL, employee_no=NULL WHERE id=?').run(target);
  db.prepare('DELETE FROM friendships WHERE (user_id=? AND friend_id IN (SELECT id FROM users WHERE org_id=? OR id=?)) OR (friend_id=? AND user_id IN (SELECT id FROM users WHERE org_id=? OR id=?))')
    .run(target, orgId, org.created_by, target, orgId, org.created_by);
  res.json({ ok: true });
});

module.exports = router;
