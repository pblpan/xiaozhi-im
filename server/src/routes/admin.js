const router = require('express').Router();
const fs = require('fs');
const path = require('path');
const db = require('../db');
const config = require('../config');
const { verifyToken, hashPassword, verifyPassword } = require('../auth');
const clientconfig = require('../clientconfig');
const appmodules = require('../appmodules');
const appoverrides = require('../appoverrides');
const appgroups = require('../appgroups');
const appnotice = require('../appnotice');
const appguard = require('../appguard');
const appdata = require('../appdata');
const upstream = require('../upstream');
const localdata = require('../localdata');
const appregistry = require('../apps');
const settings = require('../settings');
const remote = require('../remote');
const hub = require('../hub');
const chat = require('../chat');
const orgs = require('./orgs');
const paging = require('../paging');
// 只是借它的时区工具算"今天"的边界：容器 TZ 常是 UTC，
// 用 date('now') 会把北京时间当天 0-8 点算进"昨天"，仪表盘的"今日新增"就整体偏。
// 复用考勤那套已按 ATT_TIMEZONE 校准的 tsOfDay，不再自己造一份。
const att = require('../attendance');
const pkg = require('../../package.json');

// 单次批量清理的条数上限：防止一条条件写宽了把整个库删掉。
// 配合"算法条数 → 手输条数确认 → 服务端重算比对"的三步模型使用。
const MAX_PURGE = 20000;
// 孤儿巡检的扫描上限：避免超大目录把接口拖死；超限时响应里标 truncated
const MAX_ORPHAN_SCAN = 5000;

function adminOf(req, res) {
  const c = verifyToken(req.headers.authorization?.replace('Bearer ', ''));
  if (!c) { res.status(401).json({ error: 'unauthorized' }); return null; }
  const u = db.prepare('SELECT role FROM users WHERE id=?').get(c.uid);
  // 🔴 401 与 403 要分清（2026-10-03 修，审计 P2「鉴权行为漂移」）：
  //   · 401 = 你的登录态本身不成立（没令牌 / 令牌无效 / **账号已被删掉**）
  //   · 403 = 登录态没问题，但你没这个权限（是登录用户但不是管理员）
  // 以前这里把"用户不存在"和"不是管理员"合并成 403，后果是：账号被管理员删掉后，
  // 那个人的客户端收到 403 会被理解成"我没权限"，于是**不会跳登录页**，
  // 只能一直对着 403 干瞪眼 —— 看起来像程序坏了。
  // 令牌签名有效但查不到人，说明的是"这个人已经不该存在了"，属于登录态失效 → 401。
  if (!u) { res.status(401).json({ error: 'unauthorized' }); return null; }
  if (u.role !== 'admin') { res.status(403).json({ error: 'forbidden' }); return null; }
  return c.uid;
}

/** 备份文件名用的时间戳（本地时区可读，不含冒号以免文件名非法） */
function stampName(d = new Date()) {
  const p = (n, w = 2) => String(n).padStart(w, '0');
  return `${d.getFullYear()}${p(d.getMonth() + 1)}${p(d.getDate())}-${p(d.getHours())}${p(d.getMinutes())}${p(d.getSeconds())}`;
}

/**
 * 把待删记录导出成 JSON 落到 `<DATA_DIR>/purge-backup/`。
 *
 * 成本极低，但把"不可恢复"变成"能捞回来" —— 审计留痕的标准做法。
 * 导出失败**不阻断删除**（磁盘满等情况下，删除是用户的明确意图），
 * 但要把错误带回响应里让管理员知道没留下备份。
 */
function writePurgeBackup(kind, rows, meta) {
  const dir = path.join(config.DATA_DIR, 'purge-backup');
  const name = `${kind}-${stampName()}.json`;
  try {
    fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(
      path.join(dir, name),
      JSON.stringify({ kind, at: Date.now(), ...meta, count: rows.length, rows }, null, 2),
      'utf8',
    );
    return { name, error: null };
  } catch (e) {
    return { name: null, error: e.message };
  }
}

/**
 * 消息列表的筛选条件构建（列表、preview、purge 三处共用一套，避免口径分家）。
 * 返回 `{ error }` 时路由回 400。
 */
function messageFilter(query, timeField = 'm.created_at') {
  const list = paging.parseList(query);
  if (list.error) return { error: list.error };

  const params = [];
  const where = [];
  where.push(...paging.timeWhere(list, params, timeField));

  const kind = String(query.kind || '').trim();
  if (kind) { where.push('m.kind = ?'); params.push(kind); }
  const senderId = Number(query.senderId);
  if (Number.isFinite(senderId) && senderId > 0) { where.push('m.sender_id = ?'); params.push(senderId); }
  const conversationId = Number(query.conversationId);
  if (Number.isFinite(conversationId) && conversationId > 0) { where.push('m.conversation_id = ?'); params.push(conversationId); }
  if (String(query.mentioned || '') === '1') where.push('m.mentions IS NOT NULL');
  const q = String(query.q || '').trim();
  if (q) { where.push("m.content LIKE ? ESCAPE '\\'"); params.push(paging.likeParam(q)); }

  return { list, where, params, sql: where.length ? 'WHERE ' + where.join(' AND ') : '' };
}

/** 文件列表的筛选条件构建（列表 / preview / purge 共用） */
function fileFilter(query) {
  const list = paging.parseList(query);
  if (list.error) return { error: list.error };

  const where = [];
  const params = [];
  where.push(...paging.timeWhere(list, params, 'f.created_at'));

  const ownerId = Number(query.ownerId);
  if (Number.isFinite(ownerId) && ownerId > 0) { where.push('f.owner_id = ?'); params.push(ownerId); }
  const mime = String(query.mime || '').trim();
  if (mime) { where.push("f.mime LIKE ? ESCAPE '\\'"); params.push(paging.escapeLike(mime) + '%'); }
  const minSize = Number(query.minSize);
  if (Number.isFinite(minSize) && minSize > 0) { where.push('f.size >= ?'); params.push(minSize); }
  const maxSize = Number(query.maxSize);
  if (Number.isFinite(maxSize) && maxSize > 0) { where.push('f.size <= ?'); params.push(maxSize); }
  const q = String(query.q || '').trim();
  if (q) { where.push("f.name LIKE ? ESCAPE '\\'"); params.push(paging.likeParam(q)); }

  return { list, where, params, sql: where.length ? 'WHERE ' + where.join(' AND ') : '' };
}


router.get('/stats', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  const c = (sql) => db.prepare(sql).get().c;
  // 「今日」边界（毫秒）：走 ATT_TIMEZONE，与考勤同一套口径。
  // 用 addDays 推明天 0 点而不是 dayStart+86400000 —— 有夏令时的时区那样子会差一小时。
  const day = att.today();
  const dayStart = att.tsOfDay(day, '00:00');
  const dayEnd = att.tsOfDay(att.addDays(day, 1), '00:00');
  const weekStart = att.tsOfDay(att.addDays(day, -6), '00:00');
  const inDay = (col) => c(`SELECT COUNT(*) c FROM ${col} WHERE created_at>=${dayStart} AND created_at<${dayEnd}`);
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
    cards: c("SELECT COUNT(*) c FROM messages WHERE kind='card' AND deleted=0"),
    recalled: c('SELECT COUNT(*) c FROM messages WHERE deleted=1'),
    edited: c('SELECT COUNT(*) c FROM messages WHERE edited=1 AND deleted=0'),
    // 集成层：一眼看出对接了几个外部系统、有没有在失败
    bots: c('SELECT COUNT(*) c FROM users WHERE is_bot=1'),
    tokens: c('SELECT COUNT(*) c FROM api_tokens WHERE revoked=0'),
    hooks_in: c('SELECT COUNT(*) c FROM incoming_hooks WHERE revoked=0'),
    hooks_out: c('SELECT COUNT(*) c FROM outgoing_hooks WHERE active=1'),
    deliveries_failed: c('SELECT COUNT(*) c FROM webhook_deliveries WHERE ok=0'),
    pubkeys: c('SELECT COUNT(*) c FROM public_keys WHERE revoked=0'),
    // 组织机构：工作模式下管理员最关心「组织建了没、里面有多少人」，
    // 这两个数同时被仪表盘的上手向导用来判断某一步做完没有
    orgs: c('SELECT COUNT(*) c FROM orgs'),
    orgMembers: c('SELECT COUNT(*) c FROM users WHERE org_id IS NOT NULL'),
    depts: c('SELECT COUNT(*) c FROM org_depts'),
    // 考勤：仪表盘要显示"今天到了几个人、有几张待批的假条"，
    // 向导也靠 attendanceEnabled 判断考勤这一步做没做
    attendanceEnabled: settings.get('attendanceEnabled') !== false,
    attPending: c("SELECT COUNT(*) c FROM att_requests WHERE status='pending'"),
    attShifts: c('SELECT COUNT(*) c FROM att_shifts'),
    attGroups: c('SELECT COUNT(*) c FROM att_groups'),

    // ── 时间维度（v0.15.0）──────────────────────────────
    // 只有累计总数的话，仪表盘就是个计分板：管理员看不出"今天有没有人用"。
    // 给出今日增量 + 近 7 天实际发过消息的人数，让数字有参照。
    day,
    tz: att.TZ,
    msgsToday: inDay('messages'),
    usersToday: inDay('users'),
    filesToday: inDay('files'),
    // 近 7 天真正发过消息的人（去重）——比"用户总数"更能说明这套系统在被使用
    activeUsers7d: c(`SELECT COUNT(DISTINCT sender_id) c FROM messages WHERE created_at>=${weekStart}`),
  });
});

router.get('/info', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  res.json({
    port: config.PORT,
    db_path: config.DB_PATH,
    data_dir: config.DATA_DIR,
    files_dir: config.FILES_DIR,
    files_dir_default: config.DEFAULT_FILES_DIR,
    files_dir_custom: path.resolve(config.FILES_DIR) !== path.resolve(config.DEFAULT_FILES_DIR),
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
    version: pkg.version,
  });
});

/* ==================== 文件存储目录自定义 ====================
 * POST /files-dir { dir }  写入 paths.env（重启生效，启动自动搬遗留文件）
 *   · dir 为空字符串 = 清除自定义，回落默认 <数据目录>/files
 * DELETE /files-dir        等价于 POST { dir: '' }
 * 校验：目录必须可创建/可写；不能等于数据目录本身，也不能是它的祖先。
 */
function validateFilesDir(raw) {
  const dir = String(raw || '').trim();
  if (!dir) return { ok: true, dir: '' }; // 清除
  let p;
  try { p = path.resolve(dir); } catch { return { ok: false, error: '路径格式不正确' }; }
  const data = path.resolve(config.DATA_DIR);
  if (p === data) return { ok: false, error: '不能设成数据目录本身' };
  if (data.startsWith(p + path.sep)) return { ok: false, error: '不能设成数据目录的上级目录' };
  // 🔴 必须走 config.mkdirsSafe（逐级建），**绝不能** fs.mkdirSync(recursive:true)。
  //    2026-10-05 线上事故：这里填 `/proc/xz_nope/files` → recursive mkdir 在 procfs 上
  //    死循环 → 单线程事件循环被占满 → 容器 CPU 97%、全站 HTTP 超时，只能重启容器。
  //    详细机理与复现脚本见 config.js 的 mkdirsSafe 注释 / deploy/_probe_mkdir_loop.js。
  const mk = config.mkdirsSafe(p);
  if (!mk.ok) return { ok: false, error: `目录建不了：${mk.error}` };
  try {
    const probe = path.join(mk.dir, `.xz_write_test_${Date.now()}`);
    fs.writeFileSync(probe, 'ok');
    fs.unlinkSync(probe);
  } catch (e) {
    return { ok: false, error: `目录不可写：${e.message}` };
  }
  return { ok: true, dir: mk.dir };
}

router.post('/files-dir', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  const v = validateFilesDir(req.body && req.body.dir);
  if (!v.ok) return res.status(400).json({ error: v.error });
  try {
    config.writePathsEnv(v.dir);
  } catch (e) {
    return res.status(500).json({ error: `写入配置失败：${e.message}` });
  }
  res.json({
    ok: true,
    dir: v.dir || config.DEFAULT_FILES_DIR,
    needRestart: true,
    message: v.dir
      ? '已保存，重启服务端后生效（启动时会自动把旧目录里的文件搬过去）'
      : '已恢复默认，重启服务端后生效（启动时会自动把自定义目录里的文件搬回来）',
  });
});

router.delete('/files-dir', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  try { config.writePathsEnv(''); } catch (e) {
    return res.status(500).json({ error: `写入配置失败：${e.message}` });
  }
  res.json({ ok: true, dir: config.DEFAULT_FILES_DIR, needRestart: true });
});

/* ==================== 实例级设置（公司名 / 好友模式） ==================== */

router.get('/settings', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  res.json(settings.all());
});

// 公司名客户端显示为「公司名小智」，所以这里只存公司原文。
// 切到 work 模式前管理员应先建好组织机构（接口在 /api/admin/org*）；
// 本接口不做这个强校验 —— 模式开关与建机构是两件事，绑死反而难用。
router.put('/settings', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  // 记住切模式前的值：normal → work 的那一刻要给所有老用户补齐好友
  // （组织录入的 autoFriend 只管"以后录入的人"，normal 时期注册的没人管 —— 2026-10-11 龙哥反馈）
  const modeBefore = settings.get('friendMode');
  const r = settings.update(req.body, uid);
  if (r.error) return res.status(400).json({ error: r.error });
  let friendsBackfilled = null;
  let friendsBackfillError = null;
  if (r.settings.friendMode === 'work' && modeBefore !== 'work') {
    try {
      friendsBackfilled = backfillAllFriendships();
    } catch (e) {
      // 补齐失败不让设置本身失败（模式已生效），但要把错误亮给管理员 —— 悄悄吞掉
      // 就是下一个"推成功群里看不到"：界面说切好了，好友其实没补。
      friendsBackfillError = e.message;
    }
  }
  // 推给所有在线客户端：公司名决定顶部标题、好友模式决定底部导航形态，
  // 这两样改完不推的话，已经开着的 App 要等重启或切后台才变 ——
  // 用户看到的就是"我在服务器上改了，客户端没改"。
  // 只推公开字段（bootstrap 里本来就免鉴权能拿到这两个），不掺内部数据。
  hub.broadcastAll({
    type: 'settings:changed',
    companyName: r.settings.companyName,
    friendMode: r.settings.friendMode,
    masterShowPurchasePrice: r.settings.masterShowPurchasePrice,
  });
  res.json({
    ...r.settings,
    ...(friendsBackfilled ? { friendsBackfilled } : {}),
    ...(friendsBackfillError ? { friendsBackfillError } : {}),
  });
});

/* ============ 远程协助：默认控制码（管理员远程维护用） ============ */
//
// 语义：这把码**就是一枚普通的访问码**，只是由管理台统一生成/轮换/吊销，
// 并把它的 id 记在 settings 里。明文同样只在生成那一秒回一次。
// 用途：员工自己生成的码是"他个人的钥匙"；管理员要维护门店/前台那台常开的
// 机器时，不能每次都让人家跑过去点一次"生成访问码"。
//
// ⚠️ 明文绝不进 settings 表 —— settings 会被免鉴权的 /api/client/bootstrap
//    铺开出去（App 冷启动还没登录就得拿公司名）。这里只回元信息。

router.get('/remote/default-code', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  res.json(remote.defaultCodeMeta());
});

router.post('/remote/default-code', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  const b = req.body || {};
  const r = remote.setDefaultCode({
    hostId: b.hostId,
    label: b.label,
    ttlMinutes: b.ttlMinutes,
    by: uid,
  });
  if (r.error) return res.status(400).json({ error: r.error });
  // code 是**唯一一次**能看到明文的机会，前端必须提示当场复制
  res.json(r);
});

router.delete('/remote/default-code', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  res.json(remote.clearDefaultCode({ by: uid }));
});

/* ==================== Users ==================== */

/**
 * 用户列表（服务端分页 + 服务端搜索）。
 *
 * 搜索为什么必须放服务端：分页和前端过滤天然矛盾 —— 前端只拿到当页 50 条，
 * `filteredUsers` 只能在这 50 条里搜，第 51 个人**搜不到且不报错**。
 */
router.get('/users', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  const list = paging.parseList(req.query);
  if (list.error) return res.status(400).json({ error: list.error });

  const where = [];
  const params = [];
  const q = String(req.query.q || '').trim();
  if (q) {
    where.push("(u.username LIKE ? ESCAPE '\\' OR u.nickname LIKE ? ESCAPE '\\')");
    params.push(paging.likeParam(q), paging.likeParam(q));
  }
  const role = String(req.query.role || '').trim();
  if (role === 'admin' || role === 'user') { where.push('u.role = ?'); params.push(role); }
  const w = where.length ? 'WHERE ' + where.join(' AND ') : '';

  const total = db.prepare(`SELECT COUNT(*) n FROM users u ${w}`).get(...params).n;
  const items = db.prepare(`SELECT u.id,u.username,u.nickname,u.avatar,u.role,u.created_at
    FROM users u ${w} ORDER BY u.id ${list.sortDir} LIMIT ? OFFSET ?`)
    .all(...params, list.pageSize, list.offset);
  res.json(paging.envelope(list, items, total));
});

/**
 * 用户轻量选项（**不分页**）。
 *
 * 管理台有 4 处选择器共用一份全局 users：用户页搜索、身份下拉、建群选成员、
 * 考勤组指定到人。用户列表一分页，这 4 处就**集体静默少人**（人变少了但不报错，
 * 属最难查的一类问题）。所以给它们一个专门的轻量接口，只回必要字段。
 *
 * 用户上千时这个接口本身会变大（4 字段 × 1000 人 ≈ 40KB）。第一版接受；
 * 真到上万再做「服务端搜索式下拉」，现在不做属 YAGNI。
 */
router.get('/users/options', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  res.json(db.prepare('SELECT id,username,nickname,is_bot,role FROM users ORDER BY id').all());
});

/**
 * 会话轻量选项（**不分页**）。
 *
 * 消息页/文件页的会话下拉需要**全部会话**：原来会话列表来自 integrations.js
 * 的 conversationOptions()，群和单聊各自 `LIMIT 100` —— 第 101 个群选不到。
 * 这里不限量，并把 name 一次算好（群名 / 单聊参与者拼接）。
 */
router.get('/conversations/options', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  const rows = db.prepare(`SELECT c.id, c.type,
      COALESCE(g.name, dm.name) AS name
    FROM conversations c
    LEFT JOIN groups g ON g.conversation_id = c.id
    LEFT JOIN (
      SELECT cm.conversation_id, GROUP_CONCAT(COALESCE(u.nickname,u.username), ' / ') AS name
      FROM conversation_members cm JOIN users u ON u.id = cm.user_id
      GROUP BY cm.conversation_id
    ) dm ON dm.conversation_id = c.id
    ORDER BY c.id DESC`).all();
  res.json(rows.map((r) => ({
    id: r.id,
    type: r.type,
    name: r.name || `会话 #${r.id}`,
  })));
});

router.post('/users', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  const { username, password, nickname, role } = req.body || {};
  if (!username || !password) return res.status(400).json({ error: 'username/password required' });
  if (String(password).length < 6) return res.status(400).json({ error: '密码至少 6 位' });
  const exists = db.prepare('SELECT id FROM users WHERE username=?').get(username);
  if (exists) return res.status(409).json({ error: '账号已存在' });

  // 工作模式下不制造「游离账号」：没进组织的人搜不到同事、加不了好友（work 模式
  // 下好友申请被拒），管理员却以为人建好了 —— 这里直接按员工入职处理，
  // 账号即工号、自动入组织、自动与同事互为好友，行为与「组织机构 → 录入员工」一致。
  let orgId = null;
  let employeeNo = null;
  if (settings.get('friendMode') === 'work' && role !== 'admin') {
    const org = db.prepare('SELECT id FROM orgs LIMIT 1').get();
    if (!org) {
      return res.status(400).json({
        error: '当前是工作模式但还没有组织：请先到「组织机构」创建组织，再录入员工',
      });
    }
    orgId = org.id;
    employeeNo = username;
  }

  const r = db.prepare(`INSERT INTO users (username,password_hash,nickname,role,org_id,employee_no,created_at)
    VALUES (?,?,?,?,?,?,?)`)
    .run(username, hashPassword(password), nickname || username,
      role === 'admin' ? 'admin' : 'user', orgId, employeeNo, Date.now());
  if (orgId) orgs.autoFriend(r.lastInsertRowid, orgId, uid);
  res.json({ id: r.lastInsertRowid, joinedOrg: !!orgId });
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
    db.prepare('DELETE FROM group_join_requests WHERE group_id=?').run(g.id);
    const polls = db.prepare('SELECT id FROM group_polls WHERE group_id=?').all(g.id);
    for (const p of polls) db.prepare('DELETE FROM group_poll_votes WHERE poll_id=?').run(p.id);
    db.prepare('DELETE FROM group_polls WHERE group_id=?').run(g.id);
    if (g.conversation_id) db.prepare('DELETE FROM conversation_members WHERE conversation_id=?').run(g.conversation_id);
  }
  db.prepare('DELETE FROM group_join_requests WHERE user_id=? OR inviter_id=?').run(target, target);
  db.prepare('DELETE FROM users WHERE id=?').run(target);
  res.json({ ok: true });
});

/* ==================== Groups ==================== */

router.get('/groups', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  const list = paging.parseList(req.query);
  if (list.error) return res.status(400).json({ error: list.error });

  const where = [];
  const params = [];
  const q = String(req.query.q || '').trim();
  if (q) { where.push("g.name LIKE ? ESCAPE '\\'"); params.push(paging.likeParam(q)); }
  const w = where.length ? 'WHERE ' + where.join(' AND ') : '';

  const total = db.prepare(`SELECT COUNT(*) n FROM groups g ${w}`).get(...params).n;
  // 原来这个接口完全没有 LIMIT，群多了会把响应直接撑大，现在统一进分页
  // （顺带带上 conversation_id：群与会话不是同一个 id，排查问题时要来回对）
  const items = db.prepare(`SELECT g.id,g.name,g.owner_id,g.conversation_id,u.nickname owner_name,g.created_at,g.announcement,
    (SELECT COUNT(*) FROM group_members gm WHERE gm.group_id=g.id) members
    FROM groups g JOIN users u ON u.id=g.owner_id
    ${w} ORDER BY g.id ${list.sortDir} LIMIT ? OFFSET ?`)
    .all(...params, list.pageSize, list.offset);
  res.json(paging.envelope(list, items, total));
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
    // 🔴 群 id 和会话 id 是**两个号**（groups / conversations 两张表各自自增）。
    // 以前只回 `id`（群 id），调用方十有八九会拿它去当会话 id 用 —— 空库上两者都从 1 开始，
    // 于是"撞巧能过"，等库里有了历史数据号错开，就开始莫名其妙 403。
    // 这里顺手把 conversationId 一起回出去，省掉一次回查，也少一个坑。
    res.json({ id: g.lastInsertRowid, conversationId: convId });
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
  db.prepare('DELETE FROM group_join_requests WHERE group_id=?').run(gid);
  const polls = db.prepare('SELECT id FROM group_polls WHERE group_id=?').all(gid);
  for (const p of polls) db.prepare('DELETE FROM group_poll_votes WHERE poll_id=?').run(p.id);
  db.prepare('DELETE FROM group_polls WHERE group_id=?').run(gid);
  if (g) db.prepare('DELETE FROM conversation_members WHERE conversation_id=?').run(g.conversation_id);
  res.json({ ok: true });
});

// 彻底删除一个会话（连同消息、成员、收藏、置顶）——用于清理测试数据/废弃会话
router.delete('/conversations/:id', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  const cid = Number(req.params.id);
  const conv = db.prepare('SELECT id FROM conversations WHERE id=?').get(cid);
  if (!conv) return res.status(404).json({ error: 'not found' });
  const ids = db.prepare('SELECT id FROM messages WHERE conversation_id=?').all(cid).map((r) => r.id);
  for (const mid of ids) {
    db.prepare('DELETE FROM favorites WHERE message_id=?').run(mid);
  }
  db.prepare('DELETE FROM messages WHERE conversation_id=?').run(cid);
  db.prepare('DELETE FROM conversation_members WHERE conversation_id=?').run(cid);
  const g = db.prepare('SELECT id FROM groups WHERE conversation_id=?').get(cid);
  if (g) {
    db.prepare('DELETE FROM group_members WHERE group_id=?').run(g.id);
    db.prepare('DELETE FROM group_join_requests WHERE group_id=?').run(g.id);
    const polls = db.prepare('SELECT id FROM group_polls WHERE group_id=?').all(g.id);
    for (const p of polls) db.prepare('DELETE FROM group_poll_votes WHERE poll_id=?').run(p.id);
    db.prepare('DELETE FROM group_polls WHERE group_id=?').run(g.id);
    db.prepare('DELETE FROM groups WHERE id=?').run(g.id);
  }
  db.prepare('DELETE FROM conversations WHERE id=?').run(cid);
  res.json({ ok: true, id: cid, messages: ids.length });
});

/* ==================== Files ==================== */

/**
 * 文件列表（服务端分页 + 多维筛选 + 引用计数）。
 *
 * `refCount` = 该文件被多少条消息引用。删除前用它告知影响面，
 * 避免"文件删了，还有人翻旧消息点不开"。
 */
router.get('/files', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  const f = fileFilter(req.query);
  if (f.error) return res.status(400).json({ error: f.error });

  const total = db.prepare(`SELECT COUNT(*) n FROM files f ${f.sql}`).get(...f.params).n;
  const items = db.prepare(`SELECT f.id,f.name,f.mime,f.size,f.path,f.created_at,f.owner_id,
      COALESCE(u.nickname,u.username) owner,
      (SELECT COUNT(*) FROM messages m WHERE m.file_id=f.id) refCount
    FROM files f LEFT JOIN users u ON u.id=f.owner_id
    ${f.sql} ORDER BY f.id ${f.list.sortDir} LIMIT ? OFFSET ?`)
    .all(...f.params, f.list.pageSize, f.list.offset);
  res.json(paging.envelope(f.list, items, total));
});

/**
 * 存储占用分析 —— 直接回答"谁把磁盘吃满了"。
 * byType 按字节降序；byOwner 取 TOP 10。
 */
router.get('/files/storage', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;

  const total = db.prepare('SELECT COUNT(*) count, COALESCE(SUM(size),0) bytes FROM files').get();
  const byType = db.prepare(`SELECT COALESCE(NULLIF(mime,''),'未知') mime, COUNT(*) count, SUM(size) bytes
    FROM files GROUP BY COALESCE(NULLIF(mime,''),'未知') ORDER BY bytes DESC`).all();
  const byOwner = db.prepare(`SELECT f.owner_id, COALESCE(u.nickname,u.username) username,
      COUNT(*) count, SUM(f.size) bytes
    FROM files f LEFT JOIN users u ON u.id=f.owner_id
    GROUP BY f.owner_id ORDER BY bytes DESC LIMIT 10`).all();

  // 磁盘实际占用与库里统计对不上时，管理员在这里第一时间看到
  let diskBytes = 0;
  let diskCount = 0;
  try {
    for (const e of fs.readdirSync(config.FILES_DIR, { withFileTypes: true })) {
      if (!e.isFile()) continue;
      diskCount++;
      try { diskBytes += fs.statSync(path.join(config.FILES_DIR, e.name)).size; } catch {}
    }
  } catch {}

  res.json({
    totalBytes: total.bytes,
    totalCount: total.count,
    diskBytes,
    diskCount,
    byType,
    byOwner,
  });
});

/**
 * 孤儿文件巡检：库里和磁盘对不上的两类都要能查出来。
 *   dbOnly   files 表有记录、磁盘文件不存在（断链：手动删了文件 / 挂载变更 / 迁移丢文件）
 *   diskOnly 磁盘有文件、files 表无记录（残留：删库残留 / 上传中途失败）
 *
 * 扫描设上限（超出标 truncated），避免超大目录把接口拖死。
 */
function scanOrphans() {
  const known = new Set(db.prepare('SELECT path FROM files').all().map((r) => r.path));
  const dbRows = db.prepare('SELECT id,name,mime,size,path,owner_id,created_at FROM files ORDER BY id DESC LIMIT ?')
    .all(MAX_ORPHAN_SCAN);

  const dbOnly = [];
  for (const r of dbRows) {
    if (!fs.existsSync(path.join(config.FILES_DIR, r.path))) dbOnly.push(r);
  }
  let truncated = dbRows.length >= MAX_ORPHAN_SCAN;

  const diskOnly = [];
  let diskTotal = 0;
  try {
    for (const e of fs.readdirSync(config.FILES_DIR, { withFileTypes: true })) {
      if (!e.isFile() || e.name.startsWith('.')) continue;
      diskTotal++;
      if (known.has(e.name)) continue;
      if (diskOnly.length >= MAX_ORPHAN_SCAN) { truncated = true; continue; }
      let size = 0;
      let mtime = 0;
      try {
        const st = fs.statSync(path.join(config.FILES_DIR, e.name));
        size = st.size;
        mtime = Math.floor(st.mtimeMs);
      } catch {}
      diskOnly.push({ path: e.name, size, mtime });
    }
  } catch {}

  return { dbOnly, diskOnly, diskTotal, truncated };
}

router.get('/files/orphans', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  const r = scanOrphans();
  const diskOnlyBytes = r.diskOnly.reduce((s, x) => s + (x.size || 0), 0);
  res.json({
    dbOnly: r.dbOnly,
    diskOnly: r.diskOnly,
    counts: {
      dbOnly: r.dbOnly.length,
      diskOnly: r.diskOnly.length,
      diskTotal: r.diskTotal,
      diskOnlyBytes,
    },
    truncated: r.truncated,
    scanLimit: MAX_ORPHAN_SCAN,
  });
});

/** 文件批量清理：只算不删（第三步 purge 会重新算一遍并比对） */
router.get('/files/purge-preview', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;

  if (String(req.query.orphanOnly || '') === '1') {
    const r = scanOrphans();
    const bytes = r.diskOnly.reduce((s, x) => s + (x.size || 0), 0);
    return res.json({
      orphanOnly: true, count: r.diskOnly.length, bytes,
      oldest: null, newest: null,
      tooMany: r.diskOnly.length > MAX_PURGE, limit: MAX_PURGE, truncated: r.truncated,
    });
  }

  const f = fileFilter(req.query);
  if (f.error) return res.status(400).json({ error: f.error });
  const row = db.prepare(`SELECT COUNT(*) n, COALESCE(SUM(f.size),0) bytes,
      MIN(f.created_at) oldest, MAX(f.created_at) newest FROM files f ${f.sql}`).get(...f.params);
  res.json({
    orphanOnly: false, count: row.n, bytes: row.bytes,
    oldest: row.oldest, newest: row.newest,
    tooMany: row.n > MAX_PURGE, limit: MAX_PURGE,
  });
});

/**
 * 文件批量清理。
 *
 * 沿用单条删除的语义（§4.5）：文件删除后**消息保留、内容替换成占位文案** ——
 * 用户翻到旧消息至少知道发生过什么。批量和单条必须一致，否则同一个动作
 * 在两条路径上表现不同，是审计最讨厌的。
 *
 * `orphanOnly=1` 只清 diskOnly 残留（库里本来就没记录），风险最低，不涉及消息。
 */
router.post('/files/purge', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  const body = req.body || {};
  const confirm = Number(body.confirm);
  if (!Number.isFinite(confirm)) return res.status(400).json({ error: '缺少 confirm（要删除的条数）' });

  // ---- 分支一：只清磁盘残留，不碰数据库记录 ----
  if (String(body.orphanOnly || '') === '1') {
    const r = scanOrphans();
    const list = r.diskOnly;
    if (list.length !== confirm) {
      return res.status(409).json({
        error: `数量已变化：当前命中 ${list.length} 个，你确认的是 ${confirm} 个，请重新确认`,
        count: list.length,
      });
    }
    if (list.length === 0) return res.json({ ok: true, deleted: 0, orphanOnly: true });
    if (list.length > MAX_PURGE) {
      return res.status(400).json({ error: `一次最多清理 ${MAX_PURGE} 个（当前 ${list.length} 个），请分批处理` });
    }
    const backup = writePurgeBackup('files-orphan', list, { operator: uid, orphanOnly: true });
    let deleted = 0;
    for (const x of list) {
      try { fs.unlinkSync(path.join(config.FILES_DIR, x.path)); deleted++; } catch {}
    }
    return res.json({ ok: true, deleted, orphanOnly: true, backup: backup.name, backupError: backup.error });
  }

  // ---- 分支二：按筛选条件删文件（含引用它的消息改占位文案） ----
  const f = fileFilter(body);
  if (f.error) return res.status(400).json({ error: f.error });
  const row = db.prepare(`SELECT COUNT(*) n FROM files f ${f.sql}`).get(...f.params);
  if (row.n !== confirm) {
    return res.status(409).json({
      error: `数量已变化：当前命中 ${row.n} 条，你确认的是 ${confirm} 条，请重新确认`,
      count: row.n,
    });
  }
  if (row.n === 0) return res.json({ ok: true, deleted: 0 });

  const rows = db.prepare(`SELECT f.* FROM files f ${f.sql} ORDER BY f.id`).all(...f.params);
  const backup = writePurgeBackup('files', rows, { operator: uid, filter: body, limit: MAX_PURGE });

  db.exec('BEGIN');
  try {
    for (const r of rows) {
      // 与单条删除完全一致的语义：解引用 + 换占位文案（消息保留）
      db.prepare('UPDATE messages SET file_id=NULL,kind=?,content=? WHERE file_id=?')
        .run('text', '[文件已被管理员删除]', r.id);
      db.prepare('DELETE FROM files WHERE id=?').run(r.id);
    }
    db.exec('COMMIT');
  } catch (e) {
    db.exec('ROLLBACK');
    return res.status(500).json({ error: '批量删除失败，已回滚：' + e.message });
  }

  // 磁盘删除放在事务提交之后：库先一致，磁盘删失败最多留个孤儿（孤儿巡检能发现），
  // 不会出现"文件没了但库还引用着"这种更糟的状态
  let filesDeleted = 0;
  for (const r of rows) {
    try { fs.unlinkSync(path.join(config.FILES_DIR, r.path)); filesDeleted++; } catch {}
  }
  res.json({ ok: true, deleted: rows.length, filesDeleted, backup: backup.name, backupError: backup.error });
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

/**
 * 消息列表（服务端分页 + 多维筛选）。
 *
 * 新增 `conversation_name`：以前只显示会话 ID，对人毫无意义。
 * 群会话取群名，单聊取参与者拼接（管理员视角没有"对方"这个概念，
 * 所以不能像客户端那样按"除我之外的人"取名）。
 */
router.get('/messages', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  const f = messageFilter(req.query);
  if (f.error) return res.status(400).json({ error: f.error });

  const total = db.prepare(`SELECT COUNT(*) n FROM messages m ${f.sql}`).get(...f.params).n;
  // 用 id 排序而不是 created_at：id 单调递增且是主键，created_at 可能因并发写入
  // 出现相同值，翻页时会错乱（同一条重复出现或漏掉）
  const items = db.prepare(`SELECT m.id,m.conversation_id,m.sender_id,m.kind,m.content,
      m.file_id,m.created_at,m.deleted,m.edited,m.mentions,
      COALESCE(u.nickname,u.username) sender_name,
      COALESCE(g.name, dm.name) conversation_name,
      c.type conversation_type
    FROM messages m
    LEFT JOIN users u ON u.id = m.sender_id
    LEFT JOIN conversations c ON c.id = m.conversation_id
    LEFT JOIN groups g ON g.conversation_id = m.conversation_id
    LEFT JOIN (
      SELECT cm.conversation_id, GROUP_CONCAT(COALESCE(u2.nickname,u2.username), ' / ') AS name
      FROM conversation_members cm JOIN users u2 ON u2.id = cm.user_id
      GROUP BY cm.conversation_id
    ) dm ON dm.conversation_id = m.conversation_id
    ${f.sql} ORDER BY m.id ${f.list.sortDir} LIMIT ? OFFSET ?`)
    .all(...f.params, f.list.pageSize, f.list.offset);
  res.json(paging.envelope(f.list, items, total));
});

/** 消息批量清理：只算不删 */
router.get('/messages/purge-preview', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  const f = messageFilter(req.query);
  if (f.error) return res.status(400).json({ error: f.error });
  const row = db.prepare(`SELECT COUNT(*) n, MIN(m.created_at) oldest, MAX(m.created_at) newest
    FROM messages m ${f.sql}`).get(...f.params);
  res.json({
    count: row.n,
    oldest: row.oldest,
    newest: row.newest,
    tooMany: row.n > MAX_PURGE,
    limit: MAX_PURGE,
  });
});

/**
 * 消息批量清理（三步安全模型的第 3 步）。
 *
 * 不是"勾选一堆 ID"而是**把筛选条件直接交给服务端执行**：用户的诉求是
 * "按条件定位"而非人工挑几千条；按条件删顺带解决翻页丢勾选、前端要塞几千个 ID、
 * 以及"点了删除才发现删多了"三个坑。
 *
 * `confirm` 是核心护栏：从"算条数"到"真删"之间数据可能变了（有人正在发消息），
 * 服务端重算后不一致就 **409 拒绝**，让用户重新确认，而不是多删。
 */
router.post('/messages/purge', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  const body = req.body || {};
  const f = messageFilter(body);
  if (f.error) return res.status(400).json({ error: f.error });

  const confirm = Number(body.confirm);
  if (!Number.isFinite(confirm)) return res.status(400).json({ error: '缺少 confirm（要删除的条数）' });

  const count = db.prepare(`SELECT COUNT(*) n FROM messages m ${f.sql}`).get(...f.params).n;
  if (count !== confirm) {
    return res.status(409).json({
      error: `数量已变化：当前命中 ${count} 条，你确认的是 ${confirm} 条，请重新确认`,
      count,
    });
  }
  if (count === 0) return res.json({ ok: true, deleted: 0 });
  if (count > MAX_PURGE) {
    return res.status(400).json({ error: `一次最多删除 ${MAX_PURGE} 条（当前 ${count} 条），请收窄条件后再试` });
  }

  // 导出备份要在删除之前完成
  const rows = db.prepare(`SELECT m.* FROM messages m ${f.sql} ORDER BY m.id`).all(...f.params);
  const backup = writePurgeBackup('messages', rows, { operator: uid, filter: body, limit: MAX_PURGE });
  const fileIds = [...new Set(rows.map((r) => r.file_id).filter((v) => v != null))];

  // 三句都用同一套筛选条件（子查询），避免把上万个 id 塞进 SQL 参数
  db.exec('BEGIN');
  try {
    // 收藏必须先清：chat.js 的收藏**列表**做了 JOIN messages、**计数**没做
    // （:533 vs :535），消息删了收藏行还在的话，用户会看到"收藏 20 条"
    // 但列表只有 15 条，且没有任何报错。
    db.prepare(`DELETE FROM favorites WHERE message_id IN (SELECT m.id FROM messages m ${f.sql})`).run(...f.params);
    // 置顶消息悬空：消息没了字段还指着不存在的 id，群公告/置顶位会失效
    db.prepare(`UPDATE conversations SET pinned_message_id=NULL
      WHERE pinned_message_id IN (SELECT m.id FROM messages m ${f.sql})`).run(...f.params);
    db.prepare(`DELETE FROM messages WHERE id IN (SELECT m.id FROM messages m ${f.sql})`).run(...f.params);
    db.exec('COMMIT');
  } catch (e) {
    db.exec('ROLLBACK');
    return res.status(500).json({ error: '批量删除失败，已回滚：' + e.message });
  }

  // 级联删文件：只删"删完后已无任何消息引用"的
  let filesDeleted = 0;
  for (const fid of fileIds) {
    const still = db.prepare('SELECT COUNT(*) c FROM messages WHERE file_id=?').get(fid).c;
    if (still !== 0) continue;
    const fr = db.prepare('SELECT path FROM files WHERE id=?').get(fid);
    db.prepare('DELETE FROM files WHERE id=?').run(fid);
    if (fr) {
      try { fs.unlinkSync(path.join(config.FILES_DIR, fr.path)); filesDeleted++; } catch {}
    }
  }

  res.json({ ok: true, deleted: count, filesDeleted, backup: backup.name, backupError: backup.error });
});

/** 下载批量清理时自动留下的备份（把"不可恢复"变成"能捞回来"） */
router.get('/purge-backups', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  const dir = path.join(config.DATA_DIR, 'purge-backup');
  let items = [];
  try {
    items = fs.readdirSync(dir)
      .filter((n) => n.endsWith('.json'))
      .map((n) => {
        let size = 0;
        try { size = fs.statSync(path.join(dir, n)).size; } catch {}
        return { name: n, size };
      })
      .sort((a, b) => (a.name < b.name ? 1 : -1));
  } catch {}
  res.json({ items, dir });
});

router.get('/purge-backups/:name', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  const name = String(req.params.name || '');
  // 防路径穿越：只允许固定前缀 + 安全字符
  if (!/^(messages|files|files-orphan)-[0-9-]+\.json$/.test(name)) {
    return res.status(400).json({ error: '非法的备份文件名' });
  }
  const p = path.join(config.DATA_DIR, 'purge-backup', name);
  if (!fs.existsSync(p)) return res.status(404).json({ error: 'not found' });
  res.download(p, name);
});

/** 已读回执：给定消息 id，返回谁读了 / 谁没读（管理员审计，不限制发送者）。 */
router.get('/messages/:id/readers', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  const mid = Number(req.params.id);
  const r = chat.readReceipt(mid);
  if (!r) return res.status(404).json({ error: 'message not found' });
  res.json(r);
});

router.delete('/messages/:id', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  const mid = Number(req.params.id);
  const m = db.prepare('SELECT file_id FROM messages WHERE id=?').get(mid);
  if (!m) return res.status(404).json({ error: 'message not found' });
  // 物理删除消息；同时清掉指向它的收藏与置顶（见 SPEC §3.3.1，否则会留下悬空引用）
  db.prepare('DELETE FROM favorites WHERE message_id=?').run(mid);
  db.prepare('UPDATE conversations SET pinned_message_id=NULL WHERE pinned_message_id=?').run(mid);
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

/**
 * 全员两两互加好友（工作模式补齐，2026-10-11 龙哥反馈）。
 *
 * 背景：组织录入新员工有 autoFriend，但 normal 模式时期注册的老用户
 * 在切到工作模式后**没有任何人给他们补好友** —— 用户看到的就是
 * "都工作模式了，怎么同事还不是好友"。
 *
 * 口径：
 *   · 范围 = 所有真人（is_bot=0）。机器人不是人，不进好友关系。
 *   · 关系是**双向两行**（与 friends.js / orgs.js autoFriend 同构），
 *     status 直接 'accepted' —— 工作模式的语义就是"同事天然是好友"。
 *   · 幂等：UNIQUE(user_id,friend_id) + INSERT OR IGNORE，点多少次都不重复。
 *   · 显式事务一次性写入；半途回滚，不留"加了一半"的脏状态。
 *   · 已有 accepted 关系原样保留（备注 remark 等不碰）。
 *   · 🔴 normal 时期的手动申请（status='pending'）**升级为 accepted** 而不是跳过：
 *     pending 行占住 UNIQUE(user_id,friend_id) 的一位，OR IGNORE 会跳过这一方向，
 *     造成"bob→alice 是好友、alice→bob 还挂在申请里"的单向怪状态；
 *     且工作模式语义就是"同事天然是好友"，申请-审批那套在这里没有意义。
 *     （e2e 曾用 added=11 抓出这条 —— 升级数单列 upgraded，不与 added 混计。）
 */
function backfillAllFriendships() {
  const ids = db.prepare('SELECT id FROM users WHERE is_bot = 0 ORDER BY id').all().map((r) => r.id);
  const now = Date.now();
  const ins = db.prepare("INSERT OR IGNORE INTO friendships (user_id,friend_id,status,created_at) VALUES (?,?,'accepted',?)");
  const promote = db.prepare("UPDATE friendships SET status='accepted' WHERE user_id=? AND friend_id=? AND status='pending'");
  let added = 0;
  let upgraded = 0;
  db.exec('BEGIN');
  try {
    for (let i = 0; i < ids.length; i++) {
      for (let j = i + 1; j < ids.length; j++) {
        added += ins.run(ids[i], ids[j], now).changes;
        added += ins.run(ids[j], ids[i], now).changes;
        upgraded += promote.run(ids[i], ids[j]).changes;
        upgraded += promote.run(ids[j], ids[i]).changes;
      }
    }
    db.exec('COMMIT');
  } catch (e) {
    try { db.exec('ROLLBACK'); } catch { /* 事务已结束 */ }
    throw e;
  }
  const n = ids.length;
  return { users: n, pairs: n * (n - 1) / 2, added, upgraded };
}

/** 一键补齐全员好友（管理台「好友关系」页按钮）。幂等，随时可点 */
router.post('/friendships/backfill', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  try {
    res.json({ ok: true, ...backfillAllFriendships() });
  } catch (e) {
    res.status(500).json({ error: '补齐失败：' + e.message });
  }
});

router.get('/friendships', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  const list = paging.parseList(req.query);
  if (list.error) return res.status(400).json({ error: list.error });

  const where = [];
  const params = [];
  const status = String(req.query.status || '').trim();
  if (status) { where.push('fs.status = ?'); params.push(status); }
  const q = String(req.query.q || '').trim();
  if (q) {
    where.push("(ua.username LIKE ? ESCAPE '\\' OR ub.username LIKE ? ESCAPE '\\')");
    params.push(paging.likeParam(q), paging.likeParam(q));
  }
  const w = where.length ? 'WHERE ' + where.join(' AND ') : '';

  const total = db.prepare(`SELECT COUNT(*) n FROM friendships fs
    LEFT JOIN users ua ON ua.id=fs.user_id LEFT JOIN users ub ON ub.id=fs.friend_id ${w}`).get(...params).n;
  const items = db.prepare(`SELECT fs.id,fs.user_id,fs.friend_id,fs.status,fs.created_at,
    ua.username user_name, ub.username friend_name
    FROM friendships fs
    LEFT JOIN users ua ON ua.id=fs.user_id
    LEFT JOIN users ub ON ub.id=fs.friend_id
    ${w} ORDER BY fs.id ${list.sortDir} LIMIT ? OFFSET ?`)
    .all(...params, list.pageSize, list.offset);
  res.json(paging.envelope(list, items, total));
});

/**
 * GET /admin/friendships/tree
 * 好友关系按"用户"聚合，方便管理台用树状结构查看（用户 → 他的好友列表）。
 * 扁平表在好友多的时候根本看不出"谁是谁的好友"，树一眼就清楚。
 */
router.get('/friendships/tree', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  const rows = db.prepare(`SELECT fs.id, fs.user_id, fs.friend_id, fs.status, fs.created_at,
    ua.username user_name, ub.username friend_name
    FROM friendships fs
    LEFT JOIN users ua ON ua.id = fs.user_id
    LEFT JOIN users ub ON ub.id = fs.friend_id
    ORDER BY fs.user_id, fs.id`).all();
  const map = new Map();
  for (const r of rows) {
    if (!map.has(r.user_id)) {
      map.set(r.user_id, {
        userId: r.user_id,
        userName: r.user_name || ('用户#' + r.user_id),
        friends: [],
      });
    }
    map.get(r.user_id).friends.push(r);
  }
  res.json({ tree: [...map.values()], total: rows.length });
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

/* ==================== 音视频中继（TURN）配置向导 ==================== */

/**
 * 中继配置的持久化文件路径。
 *
 * ⚠️ 以前这里返回 `${DATA_DIR}/../docker/.env`，在容器里 DATA_DIR=/data，
 * 于是拼出 `/docker/.env` —— 一个既不存在也没挂载的路径。文件不存在时
 * 保存接口直接 500，就算真写成功了也在容器层里，重建即丢。
 * 现在统一由 config.turnEnvPath() 提供（${DATA_DIR}/turn.env），
 * 落在共享数据目录，重建不丢、改完立即生效、无需 force-recreate。
 *
 * ⚠️ 这里**故意不提供环境变量覆盖**。曾经留过一个 TURN_ENV_PATH 覆盖口子，
 * 结果「管理台显示的路径」和「实际写入的路径」可以是两个文件 —— 管理员按
 * 提示去找根本改不到真正生效的那份，和当初凭据"看似存住了其实没存"是同一
 * 类坑。只有一条真实路径，就对不上了也不可能有人走岔。
 */
function envPath() {
  return config.turnEnvPath();
}

/** 当前中继状态：来源、是否启用、遮盖后的值、静态 TURN */
router.get('/turn', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  const t = config.turnInfo();
  res.json({
    ...t,
    envPath: envPath(),
    // 引导管理员：CF 没配好时前端据此提示
    ready: t.sources.length > 0,
  });
});

/** 校验一对 CF 凭据是否真的可用（不写盘，纯探测） */
router.post('/turn/verify', async (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  const { key_id, api_token } = req.body || {};
  const r = await config.probeTurnCredentials(key_id, api_token);
  res.json(r);
});

/**
 * 保存凭据。**先校验再写**，用错值覆盖生产会导致重启后中继全丢。
 * 写进 ${DATA_DIR}/turn.env（不是 compose 的 .env —— 那个路径在容器里不存在，
 * 而且改完还得 force-recreate 才进得了进程）。写完立即热加载。
 */
router.post('/turn', async (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  const { key_id, api_token } = req.body || {};

  const kid = String(key_id || '').trim();
  const tok = String(api_token || '').trim();
  if (!kid || !tok) return res.status(400).json({ error: 'Key ID 与 API Token 都不能为空' });

  // 强制先验一次，避免把无效凭据写进生产
  const probe = await config.probeTurnCredentials(kid, tok);
  if (!probe.ok) return res.status(400).json({ error: '凭据校验未通过：' + probe.error });

  // 落盘交给 config：写 ${DATA_DIR}/turn.env（共享目录，重建不丢），
  // 同时热加载进内存。不再手工拼 .env 文本 —— 那套写法既改不动不存在的
  // 文件，也没法让「保存成功」和「重启后仍在」同时成立。
  try {
    config.writeTurnEnv({ CF_TURN_KEY_ID: kid, CF_TURN_API_TOKEN: tok });
  } catch (e) {
    return res.status(500).json({ error: '写入配置文件失败：' + e.message });
  }
  const applied = config.applyTurnCredentials(kid, tok);

  res.json({
    ok: true,
    applied,
    envPath: envPath(),
    // 不再需要重建容器：turn.env 每次启动都会读，内存也已热加载。
    needRecreate: false,
  });
});

/* ==================== 客户端配置中心（v0.8.0 第一期） ==================== */

/** 当前线上配置 + 历史版本列表 */
router.get('/client-config', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  const cur = clientconfig.current();
  res.json({
    current: { version: cur.version, payload: cur.payload },
    history: clientconfig.history(20),
  });
});

/** 发布新版本（版本化只增不改；发布前服务端严格校验，脏数据出不了管理台） */
router.post('/client-config', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  const { payload, note } = req.body || {};
  const u = db.prepare('SELECT username FROM users WHERE id=?').get(uid);
  const r = clientconfig.publish(payload, note, u?.username || 'admin');
  if (r.error) return res.status(400).json({ error: r.error });
  res.json({ ok: true, version: r.version, payload: r.payload });
});

/** 回滚 = 用旧版本内容发布新版本 */
router.post('/client-config/rollback', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  const u = db.prepare('SELECT username FROM users WHERE id=?').get(uid);
  const r = clientconfig.rollback(Number(req.body?.version), u?.username || 'admin');
  if (r.error) return res.status(400).json({ error: r.error });
  res.json({ ok: true, version: r.version });
});

/** 同步状态：哪些设备吃到了哪版（排障时最想知道"还有几台在旧配置"） */
router.get('/client-config/applied', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  const cur = clientconfig.current();
  res.json({
    latest: cur.version,
    devices: clientconfig.appliedStatus(cur.version),
  });
});

/* ==================== 应用中心（工作台的统一视图） ==================== */

/**
 * 内置应用 + 自定义应用（动态模块）的统一清单。
 *
 * 返回值刻意带上 builtin 每个应用的 `need` 条件，让管理台能直接说明
 * "为什么这个应用现在不显示"（没开工作模式 / 没建组织 / 考勤被停用）——
 * 否则管理员只会看到"客户端里没有考勤"，然后来问是不是坏了。
 */
router.get('/apps', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  const org = db.prepare('SELECT id, name FROM orgs LIMIT 1').get() || null;
  const friendMode = settings.get('friendMode');
  const attEnabled = settings.get('attendanceEnabled') !== false;
  const overrides = appoverrides.map();
  // 可见性必须按**生效后**的清单算（停用的应用已经不在里面了），
  // 否则管理台会出现"卡片写着可见、客户端里没有"的对不上
  const visibleIds = appregistry.listFor(
    { friendMode, attendanceEnabled: attEnabled, hasOrg: !!org, role: 'admin' },
    overrides,
  ).map((a) => a.id);
  res.json({
    builtin: appregistry.catalog(overrides).map((a) => {
      const ov = overrides[a.id] || null;
      return {
        ...a,
        // 对"管理员视角"的可见性；员工视角可能更少（如考勤打卡管理员就看不到）
        visibleForAdmin: visibleIds.includes(a.id),
        disabled: !!(ov && ov.disabled),
        changed: !!ov,
        changedFields: ov ? appoverrides.changedFieldsOf(
          appregistry.BUILTIN_APPS.find((x) => x.id === a.id), ov,
        ) : [],
        paramCount: appoverrides.paramSchemaOf(a.id).length,
        overriddenParams: ov ? Object.keys(ov.params || {}).length : 0,
      };
    }),
    dynamic: appmodules.list(),
    // 分组与公告一并下发：管理台这个页面要三块内容（应用 / 分组 / 公告），
    // 分开取就得发三次请求，而它们改的是同一件事（"工作台长什么样"）。
    groups: appgroups.view(overrides),
    notices: appnotice.listAll(),
    noticeMax: appnotice.TEXT_MAX,
    context: {
      friendMode,
      attendanceEnabled: attEnabled,
      hasOrg: !!org,
      orgName: org ? org.name : null,
    },
  });
});

/** 某个内置应用"对员工是否可见"的判定说明（管理台用来解释缺入口的原因） */
router.get('/apps/why', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  const id = String(req.query.id || '');
  const app = appregistry.catalog().find((a) => a.id === id);
  if (!app) return res.status(404).json({ error: '内置应用不存在' });
  const org = db.prepare('SELECT id FROM orgs LIMIT 1').get() || null;
  const reasons = [];
  const n = app.need || {};
  if (n.workMode && settings.get('friendMode') !== 'work') reasons.push('当前是普通好友模式（需在「系统设置」切换为工作模式）');
  if (n.attendance && settings.get('attendanceEnabled') === false) reasons.push('考勤已被停用（可在「考勤管理 → 考勤设置」开启）');
  if (n.orgMember && !org) reasons.push('尚未创建组织（需在「组织机构」创建）');
  if (n.role === 'employee') reasons.push('管理员账号本身不参与考勤，属正常（管理员看的是「考勤记录」）');
  if (n.adminOnly) reasons.push('这是管理员专属入口（主管看板的入口，员工看不到是正常的）');
  res.json({ id, title: app.title, visible: reasons.length === 0, reasons });
});

/* ==================== 工作台分组（v0.22.0：组名/组序/收起/新增） ====================
 *
 * ⚠️ 路由注册顺序：下面这几个**必须**出现在 `/admin/apps/:id` 之前。
 *    Express 按注册先后匹配，`:id` 会把 `/apps/groups` 当成一个 id 吃掉，
 *    表现是"分组管理页永远 404，而且报的是'不是内置应用'"，很难往路由顺序上想。
 *
 * 设计口径见 appgroups.js 开头：
 *    · 出厂组只改名 / 调序 / 收起，**不提供删除**（删了应用会集体消失）；
 *    · 自定义组允许删，但组里还有应用时会拦下来。
 */

/** 当前分组清单（含每组挂了几个应用 —— 收起/删除前让人知道影响面） */
router.get('/apps/groups', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  const overrides = appoverrides.map();
  res.json({
    groups: appgroups.view(overrides),
    factoryKeys: appregistry.DEFAULT_GROUPS.map((g) => g.key),
    labelMax: appgroups.LABEL_MAX,
  });
});

/** 新建分组 */
router.post('/apps/groups', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  const u = db.prepare('SELECT username FROM users WHERE id=?').get(uid);
  const body = req.body || {};
  const key = String(body.key || '').trim();
  const r = appgroups.set(key, { label: body.label, sort: body.sort, hidden: false }, u?.username || 'admin');
  if (r.error) return res.status(400).json({ error: r.error });
  res.json({ ok: true, groups: appgroups.view(appoverrides.map()), message: `已新增分组「${(body.label || '').trim()}」` });
});

/** 改一个组（改名 / 调序 / 收起） */
router.patch('/apps/groups/:key', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  const u = db.prepare('SELECT username FROM users WHERE id=?').get(uid);
  const r = appgroups.set(req.params.key, req.body || {}, u?.username || 'admin');
  if (r.error) return res.status(400).json({ error: r.error });
  res.json({
    ok: true, groups: appgroups.view(appoverrides.map()), group: r.group,
    message: r.message || `已保存：${r.group ? `「${r.group.label}」` : '已恢复出厂设置'}`,
  });
});

/** 删一个组（只删管理台新建的；组里还有应用时会被 appgroups.remove 拦下） */
router.delete('/apps/groups/:key', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  // 必须把应用覆盖带进去：管理员可能已经把应用挪进这个组了
  const r = appgroups.remove(req.params.key, appoverrides.map());
  if (r.error) return res.status(400).json({ error: r.error });
  res.json({ ok: true, groups: appgroups.view(appoverrides.map()), message: '已删除分组' });
});

/* ==================== 工作台公告（v0.22.0：管理台可配） ====================
 * 与分组同族，也同样必须排在 `/admin/apps/:id` 之前。
 */

router.get('/apps/notices', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  res.json({
    notices: appnotice.listAll(),
    textMax: appnotice.TEXT_MAX,
    contentMax: appnotice.CONTENT_MAX,
    maxDownload: appnotice.MAX_DOWNLOAD,
    enabled: appnotice.listEnabled(),
  });
});

router.post('/apps/notices', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  const u = db.prepare('SELECT username FROM users WHERE id=?').get(uid);
  const body = req.body || {};
  const r = appnotice.add(body.text, u?.username || 'admin', body.bgFileId, body.content);
  if (r.error) return res.status(400).json({ error: r.error });
  res.json({ ok: true, notices: appnotice.listAll(), message: '公告已发布（客户端下次启动就能看到）' });
});

router.patch('/apps/notices/:id', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  const u = db.prepare('SELECT username FROM users WHERE id=?').get(uid);
  const r = appnotice.update(req.params.id, req.body || {}, u?.username || 'admin');
  if (r.error) return res.status(400).json({ error: r.error });
  res.json({ ok: true, notices: appnotice.listAll(), message: '已保存' });
});

router.delete('/apps/notices/:id', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  const r = appnotice.remove(req.params.id);
  if (!r.removed) return res.status(404).json({ error: '公告不存在' });
  res.json({ ok: true, notices: appnotice.listAll(), message: '已删除' });
});

/** 清理已停用的公告（生效中的不动） */
router.post('/apps/notices/purge', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  const r = appnotice.purgeDisabled();
  res.json({ ok: true, notices: appnotice.listAll(), removed: r.removed, message: `已清理 ${r.removed} 条已停用的公告` });
});

/* ==================== 应用管理（v0.21.0：每个应用一个抽屉） ====================
 *
 * 一个抽屉要回答四个问题，接口也就按这四块组织：
 *   ① 它现在长什么样、和出厂差在哪        → GET    /apps/:id  的 app 块
 *   ② 停用它会关掉什么（后端拦哪些接口）  → GET    /apps/:id  的 guard 块
 *   ③ 它有哪些数据、现在什么规模          → GET    /apps/:id  的 data 块
 *   ④ 改它 / 恢复出厂 / 看明细 / 导出 / 清 → PATCH DELETE GET .../data GET .../export POST .../purge
 *
 * 为什么"停用会关掉什么"要单独作为一块返回：
 * 管理员点停用之前唯一想知道的就是这件事。让他点完再去看客户端有没有变化，
 * 等于让他拿真实用户做实验。
 */

/** 取出内置应用并做上下文（可见性）计算；不是内置应用则已响应并返回 null */
function builtinOf(req, res) {
  const id = String(req.params.id || '');
  const factory = appregistry.BUILTIN_APPS.find((a) => a.id === id);
  if (!factory) {
    res.status(404).json({
      error: `不是内置应用：${id}。自定义应用（动态模块）有自己的编辑器，改它请到「动态模块」页。`,
      code: 'not_builtin',
    });
    return null;
  }
  const org = db.prepare('SELECT id FROM orgs LIMIT 1').get() || null;
  const overrides = appoverrides.map();
  const visibleIds = appregistry.listFor({
    friendMode: settings.get('friendMode'),
    attendanceEnabled: settings.get('attendanceEnabled') !== false,
    hasOrg: !!org, role: 'admin',
  }, overrides).map((a) => a.id);
  return { id, factory, visible: visibleIds.includes(id), visibleIds };
}

/** 一个应用的完整抽屉数据（不含明细行 —— 那个按数据源分页拉） */
router.get('/apps/:id', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  const b = builtinOf(req, res); if (!b) return;
  const m = appdata.metricsOf(b.id);
  const meta = appdata.APPS[b.id] || {};
  res.json({
    app: appoverrides.view(b.id, { visibleIds: b.visibleIds }),
    // 停用会关掉哪些接口：写清楚，管理员才知道自己按下的是什么
    guard: appguard.rulesOf(b.id),
    data: {
      localOnly: !!meta.localOnly,
      localOnlyNote: meta.localOnlyNote || '',
      overviewNote: meta.overviewNote || '',
      readOnlyReason: meta.readOnlyReason || '',
      metrics: m.items,
      warnings: m.warnings,
      sources: appdata.sourcesOf(b.id),
      purgeables: appdata.purgeablesOf(b.id),
      // 共用的平台接口（审批中心等）不随单个应用停用而关闭，明写出来
      shared: appguard.SHARED,
    },
    icons: appmodules.ICONS,
  });
});

/**
 * 改覆盖（PATCH 语义：没给的字段不动，给 null 是"清回出厂"）。
 * `disabled` 的改动是**立刻生效**的：下一个请求就会被 appguard 拦下来。
 */
router.patch('/apps/:id', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  const b = builtinOf(req, res); if (!b) return;
  const u = db.prepare('SELECT username FROM users WHERE id=?').get(uid);
  const r = appoverrides.set(req.params.id, req.body || {}, u?.username || 'admin');
  if (r.error) return res.status(400).json({ error: r.error });
  const posted = appoverrides.view(b.id, { visibleIds: b.visibleIds });
  res.json({
    ok: true,
    app: posted,
    message: posted.changed
      ? (posted.effective.disabled ? `已保存，「${posted.effective.title}」已停用` : `已保存，「${posted.effective.title}」已更新`)
      : `已恢复出厂设置，「${posted.effective.title}」现在是默认样子`,
  });
});

/** 恢复出厂：删掉覆盖行（不是写回默认值 —— 这样"和出厂逐字一致"是可验证的） */
router.delete('/apps/:id', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  const b = builtinOf(req, res); if (!b) return;
  const r = appoverrides.reset(b.id);
  if (r.error) return res.status(400).json({ error: r.error });
  res.json({
    ok: true,
    removed: r.removed,
    app: appoverrides.view(b.id, { visibleIds: b.visibleIds }),
    message: r.removed ? '已恢复出厂设置' : '本来就是出厂设置，没有可恢复的',
  });
});

/**
 * 明细（分页）。`?source=` 指定数据源；不传时只回元信息（抽屉打开时用）。
 * 时间窗默认最近 30 天（与全站列表一致的默认），`allTime=1` 才不限。
 */
router.get('/apps/:id/data', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  const b = builtinOf(req, res); if (!b) return;
  const sourceKey = String(req.query.source || '');
  if (!sourceKey) {
    return res.json({
      sources: appdata.sourcesOf(b.id),
      purgeables: appdata.purgeablesOf(b.id),
    });
  }
  const list = paging.parseList(req.query, { defaultPageSize: 50 });
  if (list.error) return res.status(400).json({ error: list.error });
  const r = appdata.detail(b.id, sourceKey, list, req.query.q);
  if (r.error) return res.status(400).json({ error: r.error });
  res.json({
    source: sourceKey,
    columns: (appdata.sourceOf(b.id, sourceKey) || {}).columns
      ? appdata.sourceOf(b.id, sourceKey).columns.map((c) => ({ key: c.key, label: c.label, width: c.width || 120, text: !!c.text }))
      : [],
    // timeFiltered=false 表示这个数据源没有时间列，"最近 7 天"对它不起作用 ——
    // 不告诉界面的话，管理员会以为筛选坏了
    timeFiltered: r.timeFiltered,
    ...r,
  });
});

/** 导出 CSV（UTF-8 BOM，Excel 直接双击不乱码） */
router.get('/apps/:id/export', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  const b = builtinOf(req, res); if (!b) return;
  const list = paging.parseList(req.query, { defaultPageSize: 50 });
  if (list.error) return res.status(400).json({ error: list.error });
  const r = appdata.csv(b.id, String(req.query.source || ''), list, req.query.q);
  if (r.error) return res.status(400).json({ error: r.error });
  const stamp = stampName();
  const name = `${b.id}-${r.sourceName || 'data'}-${stamp}.csv`;
  res.setHeader('Content-Type', 'text/csv; charset=utf-8');
  res.setHeader('Content-Disposition',
    `attachment; filename="${b.id}-data-${stamp}.csv"; filename*=UTF-8''${encodeURIComponent(name)}`);
  res.send(r.csv);
});

/**
 * 清理（三步安全模型）：
 *   第一步 dryRun=1              → 只算条数 + 抽 20 条样例，不动数据
 *   第二步 看条数、手输确认       （前端的事）
 *   第三步 dryRun=0 + expectCount → 服务端**重算条数比对**，一致才删，并且先落一份备份
 * expectCount 必须原样送回来：期间新产生的数据会让条数变化，
 * 变化了就中止 —— 否则"我看着 300 条点的确认，实际删了 305 条"。
 */
router.post('/apps/:id/purge', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  const b = builtinOf(req, res); if (!b) return;
  const body = req.body || {};
  const sourceKey = String(body.source || '');
  const list = paging.parseList(body, { defaultPageSize: 50 });
  if (list.error) return res.status(400).json({ error: list.error });

  if (body.dryRun !== false) {
    const p = appdata.purgePreview(b.id, sourceKey, list, body.q);
    if (p.error) return res.status(400).json({ error: p.error });
    return res.json({ dryRun: true, ...p, maxBackupRows: 5000 });
  }

  const expect = Number(body.expectCount);
  if (!Number.isFinite(expect)) {
    return res.status(400).json({ error: '缺少确认条数（expectCount），请先预览再确认', code: 'need_confirm' });
  }
  // 先备份再删：备份失败**不阻断**（删除是管理员的明确意图），
  // 但要把"没留下备份"这件事带回响应，不能悄悄过去
  const bk = appdata.rowsForBackup(b.id, sourceKey, list, body.q);
  const saved = bk.error ? { name: null, error: bk.error } : writePurgeBackup(
    `app-${b.id}-${sourceKey}`,
    bk.rows,
    { app: b.id, source: sourceKey, total: bk.total, truncated: bk.truncated, by: uid, from: list.from, to: list.to },
  );

  const r = appdata.purge(b.id, sourceKey, list, body.q, expect);
  if (r.error) {
    return res.status(409).json({ ...r, backup: saved.name, backupError: saved.error || bk.error || null });
  }
  const u = db.prepare('SELECT username FROM users WHERE id=?').get(uid);
  console.log(`[小智IM] 应用数据清理：${b.id}.${sourceKey} 删除 ${r.deleted} 条（by ${u?.username || uid}，备份 ${saved.name || '失败'}）`);
  res.json({
    ok: true,
    deleted: r.deleted,
    label: r.label,
    backup: saved.name,
    backupError: saved.error || bk.error || null,
    backupTruncated: !!bk.truncated,
    backupTotal: bk.total,
    message: `已清理 ${r.deleted} 条「${r.label}」${saved.name ? `，备份：${saved.name}` : '（⚠️ 备份失败，见 backupError）'}`,
  });
});

/* ============ 上游接口登记（第三期：让动态模块真能取到数） ============ */

/** 清单。**不回传凭据明文**，只回 hasAuth 标志 */
router.get('/upstreams', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  res.json({
    upstreams: upstream.list(),
    capability: {
      methods: upstream.ALLOWED_METHODS,
      defaultTimeout: upstream.DEFAULT_TIMEOUT,
      minTimeout: upstream.MIN_TIMEOUT,
      maxTimeout: upstream.MAX_TIMEOUT,
      // 客户端能拼出的完整前缀，管理台直接抄进模块的 onLoad.path
      pathPrefix: '/api/hooks/up/',
    },
  });
});

/** 新建/更新（按 name 幂等）。authHeader 不提交 = 保持原值，不会被空值清掉 */
router.post('/upstreams', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  const u = db.prepare('SELECT username FROM users WHERE id=?').get(uid);
  const r = upstream.upsert(req.body, u?.username || 'admin');
  if (r.error) return res.status(400).json({ error: r.error });
  res.json({ ok: true, ...r });
});

router.delete('/upstreams/:id', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  if (!upstream.remove(req.params.id)) return res.status(404).json({ error: '上游接口不存在' });
  res.json({ ok: true });
});

/** 探活：只打 base_url，配完点一下就知道通不通（内网地址最容易写错） */
router.post('/upstreams/:id/probe', async (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  res.json(await upstream.probe(Number(req.params.id)));
});

/** 直连试跑：管理台当场验证"这条路走不走得通、回的是什么形状"。
 *
 *  ⚠️ 回包字段必须与 `/api/hooks/up/...` 给客户端的**逐字一致**（ok/upstream/url/status/ms/truncated/data）。
 *  管理台这一页的用途就是"我先看一眼再决定 dataPath 怎么写"，两边形状只要有一点不一样，
 *  管理员按试跑结果拼出来的 `dataPath` 到客户端就取不到数 —— 这类"照着看到的填却不对"
 *  最难查，因为每一步看着都对。
 */
router.post('/upstreams/:id/test', async (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  const row = db.prepare('SELECT name FROM upstreams WHERE id=?').get(Number(req.params.id));
  if (!row) return res.status(404).json({ error: '上游接口不存在' });
  const sub = String(req.body?.subPath || '');
  const r = await upstream.forward(row.name, sub, { method: 'GET', search: '' });
  if (r.error) return res.status(502).json({ error: r.error, upstream: row.name, url: r.url || null });
  res.json({
    ok: r.ok,
    upstream: row.name,
    url: r.url,
    status: r.status,
    ms: r.ms,
    truncated: r.truncated,
    data: r.data,
  });
});

/* ==================== 动态模块（v0.9.0 第二期） ==================== */

/** 模块清单 + 组件/图标/动作的能力清单（管理台据此渲染编辑器） */
router.get('/modules', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  res.json({
    modules: appmodules.list(),
    capability: {
      components: appmodules.COMPONENTS,
      colors: appmodules.COLORS,
      fieldTypes: appmodules.FIELD_TYPES,
      actions: appmodules.ACTIONS,
      navPages: appmodules.NAV_PAGES,
      icons: appmodules.ICONS,
      chartKinds: appmodules.CHART_KINDS,
      maxDepth: appmodules.MAX_DEPTH,
      maxComponents: appmodules.MAX_COMPONENTS,
      templates: appmodules.TEMPLATES,
    },
  });
});

/** 新建/更新模块（schema 在服务端严格校验，脏数据出不了管理台） */
router.post('/modules', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  const u = db.prepare('SELECT username FROM users WHERE id=?').get(uid);
  const r = appmodules.upsert(req.body, u?.username || 'admin');
  if (r.error) return res.status(400).json({ error: r.error });
  res.json({ ok: true, module: r.module });
});

router.delete('/modules/:id', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  const ok = appmodules.remove(req.params.id);
  if (!ok) return res.status(404).json({ error: '模块不存在' });
  res.json({ ok: true });
});

/**
 * 动态模块能选的**数据来源清单**（第四期：让内容真有内容）。
 *
 * 管理台编辑 list / table / chart 时，数据来源原来是**手填一条路径**
 * （/api/hooks/up/xxx/yyy）—— 结果是管理员不知道能填什么、填错了前端就是空白。
 * 这里把两条路的可选项一次性给全，选完连路径带列一起回填。
 *
 * 🔴 上游那份只给 name/label，**绝不回 base_url 和 auth_header**：
 *    这是管理台页面，多回一个字段就多一条泄露通道，而它根本用不上。
 */
router.get('/module-sources', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  res.json({
    local: localdata.sourcesFor('admin'),
    upstreams: upstream.list().map((u) => ({
      name: u.name,
      label: u.label || u.name,
      enabled: u.enabled,
      pathPrefix: '/api/hooks/up/',
    })),
    // 客户端 dataPath 的约定形状，管理台照它生成默认值
    dataPath: 'data.rows',
  });
});

/**
 * 工作台**统一排序**。
 *
 * ─────────────────────────────────────────────────────────────
 * 为什么要有这一个入口
 * ─────────────────────────────────────────────────────────────
 * 排序原来分散在两处：内置应用改 app_overrides.sort，自定义模块改
 * app_modules.sort，而两处的数字**各排各的** —— 内置应用排成 10/20/30，
 * 模块也排成 10/20/30，落到客户端就是两组交错、谁也压不住谁。
 * 管理员的直觉是"我要把这个模块挪到打卡下面"，而他能做的只有
 * "去模块清单里把 20 改成 25" 然后猜。
 *
 * 这里一次收一串有序 id，按顺序统一发号（10/20/30…），
 * 两组共用一个序号空间 —— 顺序就是界面上拖出来的那个顺序。
 *
 * 🔴 id 前缀 `module:` 用来区分两类：不带前缀 = 内置应用 id。
 *    用前缀而不是"先查哪张表在不在"：后者在两边都有同名时会静默改错对象，
 *    而前缀是显式的，改错了立刻看得见。
 */
router.post('/order', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  const u = db.prepare('SELECT username FROM users WHERE id=?').get(uid);
  const by = u?.username || 'admin';

  const raw = req.body && Array.isArray(req.body.order) ? req.body.order : [];
  if (!raw.length) return res.status(400).json({ error: '没有要排序的条目' });
  if (raw.length > 200) return res.status(400).json({ error: '一次最多排 200 个条目' });

  const known = new Set(appregistry.BUILTIN_APPS.map((a) => a.id));
  for (const m of appmodules.list()) known.add('module:' + m.moduleId);

  let n = 0;
  let moved = 0;
  const skipped = [];
  for (const item of raw) {
    const id = String(item || '').trim();
    if (!known.has(id)) {
      skipped.push(id); // 不认识的一律跳过，不能因为一条脏数据整批失败
      continue;
    }
    n += 10;
    if (id.startsWith('module:')) {
      if (appmodules.setSort(id.slice(7), n)) moved++;
    } else {
      appoverrides.set(id, { sort: n }, by);
      moved++;
    }
  }
  res.json({ ok: true, moved, skipped });
});

/** 某模块的提交记录（第二期验收要看"表单真的收到数据了"） */
router.get('/modules/:id/submissions', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  const list = paging.parseList(req.query, { defaultPageSize: 100, defaultWindowDays: 0 });
  if (list.error) return res.status(400).json({ error: list.error });
  // 提交记录按 id 分页，不吃默认时间窗（否则老提交会"消失"）
  list.from = null;
  list.to = null;
  res.json({
    moduleId: req.params.id,
    ...paging.envelope(list, appmodules.listSubmissions(req.params.id, list.pageSize, list.offset),
      appmodules.countSubmissions(req.params.id)),
  });
});

/** 移除 CF 配置（回退到 STUN + 静态 TURN） */
router.delete('/turn', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  config.clearTurnCredentials();
  res.json({
    ok: true,
    envPath: envPath(),
    needRecreate: false,
  });
});

module.exports = router;