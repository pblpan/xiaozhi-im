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

const ORG_COLS = `u.id,u.username,u.nickname,u.avatar,u.signature,u.employee_no,u.dept_id,u.position_id,
  d.name AS dept_name, p.name AS position_name`;
const MEMBER_JOIN = `
  FROM users u
  LEFT JOIN org_depts d ON d.id = u.dept_id
  LEFT JOIN org_positions p ON p.id = u.position_id`;
const MAX_MEMBERS = 500;

// 取本服务器唯一组织（单组织语义，全项目一致）
function theOrg() {
  return db.prepare('SELECT id, name, created_by FROM orgs LIMIT 1').get() || null;
}

// 校验部门/岗位 id 属于本组织；返回 {ok} 或 {error}
function checkDeptPosition(orgId, deptId, positionId) {
  if (deptId != null) {
    if (!db.prepare('SELECT id FROM org_depts WHERE id=? AND org_id=?').get(deptId, orgId)) {
      return { error: '部门不存在（请先在部门管理里创建）' };
    }
  }
  if (positionId != null) {
    if (!db.prepare('SELECT id FROM org_positions WHERE id=? AND org_id=?').get(positionId, orgId)) {
      return { error: '岗位不存在（请先在岗位管理里创建）' };
    }
  }
  return { ok: true };
}

// 新员工与「组织内现有员工 + 管理员」自动互为好友（显式事务，半途回滚）
function autoFriend(newUid, orgId, adminUid) {
  const mateIds = db.prepare('SELECT id FROM users WHERE org_id=? AND id<>?').all(orgId, newUid).map((r) => r.id);
  if (!mateIds.includes(adminUid)) mateIds.push(adminUid); // 管理员（无工号）也要能找到员工
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
}

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

  const members = db.prepare(`SELECT ${ORG_COLS} ${MEMBER_JOIN}
    WHERE u.org_id=? ORDER BY u.id`).all(org.id);
  const depts = db.prepare('SELECT id, name, parent_id, sort FROM org_depts WHERE org_id=? ORDER BY sort, id').all(org.id);
  const positions = db.prepare('SELECT id, name, dept_id, sort FROM org_positions WHERE org_id=? ORDER BY sort, id').all(org.id);
  res.json({ org, members, depts, positions });
});

// ============================================================
// 添加员工（工号=账号，初始密码=工号，自动与全员互为好友）
// 可选 deptId / positionId（部门管理、岗位管理里建的）
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
  const deptId = req.body?.deptId ?? null;
  const positionId = req.body?.positionId ?? null;
  // 工号即登录账号，沿用账号的字符纪律：字母/数字/下划线，避免和显示名混淆
  if (!/^[A-Za-z0-9_]{3,20}$/.test(employeeNo)) {
    return res.status(400).json({ error: '工号 3-20 位，仅限字母、数字、下划线' });
  }
  if (nickname && [...nickname].length > 24) return res.status(400).json({ error: '昵称最多 24 个字' });

  const chk = checkDeptPosition(orgId, deptId, positionId);
  if (chk.error) return res.status(400).json({ error: chk.error });

  const count = db.prepare('SELECT COUNT(*) AS c FROM users WHERE org_id=?').get(orgId).c;
  if (count >= MAX_MEMBERS) return res.status(400).json({ error: `组织成员已达上限（${MAX_MEMBERS} 人）` });

  // 工号 = 账号。撞号时分两种情况，必须分开处理：
  //   a) 号没被占用 → 新建账号，初始密码 = 工号
  //   b) 号被一个「游离账号」占着（普通模式时期自己注册、还没进任何组织）
  //      → 收编进组织，密码保持不变
  // (b) 是普通模式转工作模式后，老账号唯一的归队路径。以前这种情况一律 409，
  // 等于把老用户堵死：他在工作模式下搜不到同事、加不了好友，想被录入又提示
  // "工号已被占用"，最后只能换个号重来 —— 数据和人全断。
  const exist = db.prepare('SELECT id, role, org_id FROM users WHERE username=?').get(employeeNo);
  let newUid;
  let adopted = false;
  if (exist) {
    if (exist.role === 'admin') {
      return res.status(409).json({ error: `账号 ${employeeNo} 是管理员，不能作为员工录入` });
    }
    if (exist.org_id) {
      return res.status(409).json({ error: `账号 ${employeeNo} 已在组织中，无需重复录入` });
    }
    // 只改归属，不动 password_hash —— 人还是那个人，密码照旧
    db.prepare('UPDATE users SET org_id=?, employee_no=?, dept_id=?, position_id=? WHERE id=?')
      .run(orgId, employeeNo, deptId, positionId, exist.id);
    if (nickname) db.prepare('UPDATE users SET nickname=? WHERE id=?').run(nickname, exist.id);
    newUid = exist.id;
    adopted = true;
  } else {
    try {
      const info = db.prepare(`INSERT INTO users (username, password_hash, nickname, role, org_id, employee_no, dept_id, position_id, created_at)
        VALUES (?,?,?,?,?,?,?,?,?)`)
        .run(employeeNo, hashPassword(employeeNo), nickname || employeeNo, 'user', orgId, employeeNo, deptId, positionId, Date.now());
      newUid = info.lastInsertRowid;
    } catch (e) {
      if (/UNIQUE/i.test(e.message)) {
        return res.status(409).json({ error: `工号 ${employeeNo} 已被占用（可能是重名账号或已录入）` });
      }
      throw e;
    }
  }

  // 收编的账号也要补同事好友关系（autoFriend 用 INSERT OR IGNORE，重复无害）
  autoFriend(newUid, orgId, uid);

  const user = db.prepare(`SELECT ${ORG_COLS} ${MEMBER_JOIN} WHERE u.id=?`).get(newUid);
  res.json({ user, adopted });
});

// ============================================================
// 编辑员工（部门 / 岗位 / 昵称 —— 员工管理的"改"）
// ============================================================
router.put('/:id/members/:uid', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  // 与「录入员工」保持同一道门：普通模式下组织相关写操作一律停下，
  // 否则会出现"能改不能加"这种自相矛盾的状态
  if (!requireWorkMode(req, res)) return;
  const orgId = Number(req.params.id);
  const target = Number(req.params.uid);
  const org = db.prepare('SELECT id, created_by FROM orgs WHERE id=?').get(orgId);
  if (!org) return res.status(404).json({ error: '组织不存在' });
  if (org.created_by !== uid) return res.status(403).json({ error: '只有组织创建者可以编辑员工' });
  const u = db.prepare('SELECT id, org_id, role FROM users WHERE id=?').get(target);
  if (!u || u.org_id !== orgId) return res.status(404).json({ error: '该用户不是本组织成员' });

  const b = req.body || {};
  const sets = [];
  const params = [];
  if (b.nickname !== undefined) {
    const nickname = String(b.nickname).trim();
    if (nickname && [...nickname].length > 24) return res.status(400).json({ error: '昵称最多 24 个字' });
    sets.push('nickname=?'); params.push(nickname || u.username);
  }
  if (b.deptId !== undefined) {
    const chk = checkDeptPosition(orgId, b.deptId, null);
    if (chk.error) return res.status(400).json({ error: chk.error });
    sets.push('dept_id=?'); params.push(b.deptId ?? null);
  }
  if (b.positionId !== undefined) {
    const chk = checkDeptPosition(orgId, null, b.positionId);
    if (chk.error) return res.status(400).json({ error: chk.error });
    sets.push('position_id=?'); params.push(b.positionId ?? null);
  }
  if (!sets.length) return res.status(400).json({ error: '无修改内容' });
  params.push(target);
  db.prepare(`UPDATE users SET ${sets.join(',')} WHERE id=?`).run(...params);
  const user = db.prepare(`SELECT ${ORG_COLS} ${MEMBER_JOIN} WHERE u.id=?`).get(target);
  res.json({ user });
});

// ============================================================
// 移除员工（禁用语义：账号保留、退出组织、好友关系解除）
// ============================================================
router.delete('/:id/members/:uid', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  if (!requireWorkMode(req, res)) return;
  const orgId = Number(req.params.id);
  const target = Number(req.params.uid);
  const org = db.prepare('SELECT id, created_by FROM orgs WHERE id=?').get(orgId);
  if (!org) return res.status(404).json({ error: '组织不存在' });
  if (org.created_by !== uid) return res.status(403).json({ error: '只有组织创建者可以移除员工' });
  const u = db.prepare('SELECT id, org_id, role FROM users WHERE id=?').get(target);
  if (!u || u.org_id !== orgId) return res.status(404).json({ error: '该用户不是本组织成员' });

  // dept_id/position_id 必须一起清：只清 org_id 的话，部门删除护栏
  // （按 dept_id 统计人数）会把这名已移除的员工继续算作占用者 ——
  // 界面上看不到人，却永远提示"该部门下有 N 名员工"，部门删不掉。
  db.prepare('UPDATE users SET org_id=NULL, employee_no=NULL, dept_id=NULL, position_id=NULL WHERE id=?').run(target);
  db.prepare('DELETE FROM friendships WHERE (user_id=? AND friend_id IN (SELECT id FROM users WHERE org_id=? OR id=?)) OR (friend_id=? AND user_id IN (SELECT id FROM users WHERE org_id=? OR id=?))')
    .run(target, orgId, org.created_by, target, orgId, org.created_by);
  res.json({ ok: true });
});

// ============================================================
// 部门管理（套用工厂 V2 人事模型：父子层级 + 排序）
// ============================================================
// 组织管理操作的公共前置：admin + 组织存在 + 是创建者
function orgOwnerOf(req, res) {
  const uid = adminOf(req, res); if (uid === null) return null;
  const org = theOrg();
  if (!org) { res.status(404).json({ error: '尚未创建组织' }); return null; }
  if (org.created_by !== uid) { res.status(403).json({ error: '只有组织创建者可以管理组织' }); return null; }
  return { uid, org };
}

router.get('/depts', (req, res) => {
  const uid = uidOf(req, res); if (uid === null) return;
  const org = theOrg();
  if (!org) return res.json([]);
  res.json(db.prepare('SELECT id, name, parent_id, sort FROM org_depts WHERE org_id=? ORDER BY sort, id').all(org.id));
});

router.post('/depts', (req, res) => {
  const owner = orgOwnerOf(req, res); if (!owner) return;
  if (!requireWorkMode(req, res)) return;
  const name = String(req.body?.name || '').trim();
  if (!name || [...name].length > 30) return res.status(400).json({ error: '部门名称必填，最多 30 个字' });
  const parentId = Number(req.body?.parentId) || 0;
  if (parentId) {
    if (!db.prepare('SELECT id FROM org_depts WHERE id=? AND org_id=?').get(parentId, owner.org.id)) {
      return res.status(400).json({ error: '上级部门不存在' });
    }
  }
  const sort = Number(req.body?.sort) || 0;
  const info = db.prepare('INSERT INTO org_depts (org_id, name, parent_id, sort) VALUES (?,?,?,?)')
    .run(owner.org.id, name, parentId, sort);
  res.json({ id: info.lastInsertRowid, message: '部门已新增' });
});

router.put('/depts/:id', (req, res) => {
  const owner = orgOwnerOf(req, res); if (!owner) return;
  const did = Number(req.params.id);
  const dept = db.prepare('SELECT id, parent_id FROM org_depts WHERE id=? AND org_id=?').get(did, owner.org.id);
  if (!dept) return res.status(404).json({ error: '部门不存在' });

  const name = req.body?.name !== undefined ? String(req.body.name).trim() : null;
  if (name !== null && (!name || [...name].length > 30)) return res.status(400).json({ error: '部门名称最多 30 个字' });
  const parentId = req.body?.parentId !== undefined ? (Number(req.body.parentId) || 0) : null;
  if (parentId === did) return res.status(400).json({ error: '上级部门不能设为自身' });
  if (parentId) {
    // 上级不能是自己管辖内的子部门（会成环）—— 沿父链向上爬检测（工厂 V2 同款算法）
    const all = db.prepare('SELECT id, parent_id FROM org_depts WHERE org_id=?').all(owner.org.id);
    let cur = parentId;
    const seen = new Set();
    while (cur && cur !== 0 && !seen.has(cur)) {
      seen.add(cur);
      if (cur === did) return res.status(400).json({ error: '上级部门不能设为自己的子部门' });
      cur = all.find((d) => d.id === cur)?.parent_id || 0;
    }
    if (!db.prepare('SELECT id FROM org_depts WHERE id=? AND org_id=?').get(parentId, owner.org.id)) {
      return res.status(400).json({ error: '上级部门不存在' });
    }
  }
  const sort = req.body?.sort !== undefined ? (Number(req.body.sort) || 0) : null;
  db.prepare('UPDATE org_depts SET name=COALESCE(?,name), parent_id=COALESCE(?,parent_id), sort=COALESCE(?,sort) WHERE id=?')
    .run(name, parentId, sort, did);
  res.json({ message: '已保存' });
});

router.delete('/depts/:id', (req, res) => {
  const owner = orgOwnerOf(req, res); if (!owner) return;
  const did = Number(req.params.id);
  const dept = db.prepare('SELECT id FROM org_depts WHERE id=? AND org_id=?').get(did, owner.org.id);
  if (!dept) return res.status(404).json({ error: '部门不存在' });
  const empCnt = db.prepare('SELECT COUNT(*) AS c FROM users WHERE dept_id=?').get(did).c;
  if (empCnt > 0) return res.status(400).json({ error: `该部门下有 ${empCnt} 名员工，请先调整他们的部门` });
  const subCnt = db.prepare('SELECT COUNT(*) AS c FROM org_depts WHERE parent_id=?').get(did).c;
  if (subCnt > 0) return res.status(400).json({ error: '该部门下有子部门，请先移除子部门或调整其上级' });
  db.prepare('DELETE FROM org_depts WHERE id=?').run(did);
  res.json({ message: '已删除' });
});

// ============================================================
// 岗位管理（可挂部门；不挂 = 全厂通用岗位）
// ============================================================
router.get('/positions', (req, res) => {
  const uid = uidOf(req, res); if (uid === null) return;
  const org = theOrg();
  if (!org) return res.json([]);
  res.json(db.prepare(`SELECT p.id, p.name, p.dept_id, p.sort, d.name AS dept_name
    FROM org_positions p LEFT JOIN org_depts d ON d.id = p.dept_id
    WHERE p.org_id=? ORDER BY p.sort, p.id`).all(org.id));
});

router.post('/positions', (req, res) => {
  const owner = orgOwnerOf(req, res); if (!owner) return;
  if (!requireWorkMode(req, res)) return;
  const name = String(req.body?.name || '').trim();
  if (!name || [...name].length > 30) return res.status(400).json({ error: '岗位名称必填，最多 30 个字' });
  const deptId = req.body?.deptId ?? null;
  const chk = checkDeptPosition(owner.org.id, deptId, null);
  if (chk.error) return res.status(400).json({ error: chk.error });
  const info = db.prepare('INSERT INTO org_positions (org_id, name, dept_id, sort) VALUES (?,?,?,?)')
    .run(owner.org.id, name, deptId, Number(req.body?.sort) || 0);
  res.json({ id: info.lastInsertRowid, message: '岗位已新增' });
});

router.put('/positions/:id', (req, res) => {
  const owner = orgOwnerOf(req, res); if (!owner) return;
  const pid = Number(req.params.id);
  const pos = db.prepare('SELECT id FROM org_positions WHERE id=? AND org_id=?').get(pid, owner.org.id);
  if (!pos) return res.status(404).json({ error: '岗位不存在' });
  const b = req.body || {};
  const sets = [];
  const params = [];
  if (b.name !== undefined) {
    const name = String(b.name).trim();
    if (!name || [...name].length > 30) return res.status(400).json({ error: '岗位名称最多 30 个字' });
    sets.push('name=?'); params.push(name);
  }
  if (b.deptId !== undefined) {
    const chk = checkDeptPosition(owner.org.id, b.deptId, null);
    if (chk.error) return res.status(400).json({ error: chk.error });
    sets.push('dept_id=?'); params.push(b.deptId ?? null);
  }
  if (b.sort !== undefined) { sets.push('sort=?'); params.push(Number(b.sort) || 0); }
  if (!sets.length) return res.status(400).json({ error: '无修改内容' });
  params.push(pid);
  db.prepare(`UPDATE org_positions SET ${sets.join(',')} WHERE id=?`).run(...params);
  res.json({ message: '已保存' });
});

router.delete('/positions/:id', (req, res) => {
  const owner = orgOwnerOf(req, res); if (!owner) return;
  const pid = Number(req.params.id);
  const pos = db.prepare('SELECT id FROM org_positions WHERE id=? AND org_id=?').get(pid, owner.org.id);
  if (!pos) return res.status(404).json({ error: '岗位不存在' });
  const cnt = db.prepare('SELECT COUNT(*) AS c FROM users WHERE position_id=?').get(pid).c;
  if (cnt > 0) return res.status(400).json({ error: `该岗位下有 ${cnt} 名员工，请先调整他们的岗位` });
  db.prepare('DELETE FROM org_positions WHERE id=?').run(pid);
  res.json({ message: '已删除' });
});

// ============================================================
// 批量导入员工 —— 公司成建制入职的核心（否则一个厂录一上午）
// body: { rows: [{ employeeNo, nickname, dept, position }] }
// 部门/岗位按名字匹配，不存在自动创建（部门挂顶级、岗位挂所在部门）；
// 单行失败只跳过该行，不整批回滚 —— 返回每行结果让管理员精确补录。
// ============================================================
router.post('/:id/members/import', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  if (!requireWorkMode(req, res)) return;
  const orgId = Number(req.params.id);
  const org = db.prepare('SELECT id, name, created_by FROM orgs WHERE id=?').get(orgId);
  if (!org) return res.status(404).json({ error: '组织不存在' });
  if (org.created_by !== uid) return res.status(403).json({ error: '只有组织创建者可以导入员工' });

  const rows = Array.isArray(req.body?.rows) ? req.body.rows : [];
  if (!rows.length) return res.status(400).json({ error: '没有可导入的数据' });
  if (rows.length > 1000) return res.status(400).json({ error: '单次最多导入 1000 行，请分批' });

  const count = db.prepare('SELECT COUNT(*) AS c FROM users WHERE org_id=?').get(orgId).c;
  if (count + rows.length > MAX_MEMBERS) {
    return res.status(400).json({ error: `组织成员上限 ${MAX_MEMBERS} 人，当前 ${count} 人，本批 ${rows.length} 行超限` });
  }

  // 部门/岗位名 → id 的会话内缓存（同一批里同名只建一次）
  const deptCache = new Map();
  const posCache = new Map();
  const newDepts = [];
  const newPositions = [];

  function deptIdOf(name) {
    if (!name) return null;
    const key = name;
    if (deptCache.has(key)) return deptCache.get(key);
    let id = db.prepare('SELECT id FROM org_depts WHERE org_id=? AND name=?').get(orgId, name)?.id || null;
    if (!id) {
      id = db.prepare('INSERT INTO org_depts (org_id, name, parent_id, sort) VALUES (?,?,0,0)')
        .run(orgId, name).lastInsertRowid;
      newDepts.push(name);
    }
    deptCache.set(key, id);
    return id;
  }
  function posIdOf(name, dId) {
    if (!name) return null;
    // 岗位先按"同名+同部门"找，找不到再按"同名+通用"兜底，最后才建
    let id = db.prepare('SELECT id FROM org_positions WHERE org_id=? AND name=? AND (dept_id=? OR dept_id IS NULL)')
      .get(orgId, name, dId)?.id || null;
    if (!id) {
      id = db.prepare('SELECT id FROM org_positions WHERE org_id=? AND name=?').get(orgId, name)?.id || null;
    }
    if (!id) {
      id = db.prepare('INSERT INTO org_positions (org_id, name, dept_id, sort) VALUES (?,?,?,0)')
        .run(orgId, name, dId).lastInsertRowid;
      newPositions.push(name);
    }
    posCache.set(name + '|' + (dId || 0), id);
    return id;
  }

  const created = [];
  const adopted = [];
  const skipped = [];
  for (const row of rows) {
    const employeeNo = String(row?.employeeNo || '').trim();
    const nickname = String(row?.nickname || '').trim().slice(0, 24);
    const dept = String(row?.dept || '').trim().slice(0, 30);
    const position = String(row?.position || '').trim().slice(0, 30);
    if (!/^[A-Za-z0-9_]{3,20}$/.test(employeeNo)) {
      skipped.push({ employeeNo, reason: '工号格式错（3-20 位字母/数字/下划线）' });
      continue;
    }
    // 撞号分两类：管理员/已在组织 → 跳过；游离老账号 → 收编（同「录入员工」语义）
    const exist = db.prepare('SELECT id, role, org_id FROM users WHERE username=?').get(employeeNo);
    if (exist && exist.role === 'admin') {
      skipped.push({ employeeNo, reason: '该账号是管理员，不能作为员工导入' });
      continue;
    }
    if (exist && exist.org_id) {
      skipped.push({ employeeNo, reason: '已在组织中（无需重复导入）' });
      continue;
    }
    try {
      const dId = deptIdOf(dept);
      const pId = posIdOf(position, dId);
      if (exist) {
        // 老账号归队：只改归属与部门岗位，密码保持原样
        db.prepare('UPDATE users SET org_id=?, employee_no=?, dept_id=?, position_id=? WHERE id=?')
          .run(orgId, employeeNo, dId, pId, exist.id);
        if (nickname) db.prepare('UPDATE users SET nickname=? WHERE id=?').run(nickname, exist.id);
        autoFriend(exist.id, orgId, uid);
        adopted.push(employeeNo);
      } else {
        const info = db.prepare(`INSERT INTO users (username, password_hash, nickname, role, org_id, employee_no, dept_id, position_id, created_at)
          VALUES (?,?,?,?,?,?,?,?,?)`)
          .run(employeeNo, hashPassword(employeeNo), nickname || employeeNo, 'user', orgId, employeeNo, dId, pId, Date.now());
        autoFriend(info.lastInsertRowid, orgId, uid);
        created.push(employeeNo);
      }
    } catch (e) {
      skipped.push({ employeeNo, reason: '写入失败：' + e.message });
    }
  }

  res.json({
    created: created.length,
    adopted,
    skipped,
    newDepts,
    newPositions,
    message: `导入完成：新建 ${created.length} 人`
      + (adopted.length ? `，老账号归队 ${adopted.length} 人（密码不变）` : '')
      + (skipped.length ? `，跳过 ${skipped.length} 行` : ''),
  });
});

module.exports = router;
// 供 admin.js 复用：工作模式下后台新建普通用户 = 员工入职，要补同事好友关系
module.exports.autoFriend = autoFriend;
