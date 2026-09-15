/**
 * 客户端配置接口（SPEC §6）
 *
 * /bootstrap 免鉴权的原因：App 冷启动时可能还没登录，此时恰恰最需要拿到
 * 地址候选与维护公告。要求鉴权会变成"连不上 → 拿不到配置 → 永远连不上"死锁。
 * 代价是内容对未授权者可见，所以这里只能返回公开信息（地址/公告/开关/版本策略），
 * 绝不能混入 token、密钥、用户数据 —— 见 SPEC §6.1 的硬边界。
 */
const router = require('express').Router();
const { verifyToken } = require('../auth');
const clientconfig = require('../clientconfig');
const appmodules = require('../appmodules');
const appregistry = require('../apps');
const attendance = require('../attendance');
const settings = require('../settings');
const db = require('../db');
const pkg = require('../../package.json');

function uidOf(req, res) {
  const c = verifyToken(req.headers.authorization?.replace('Bearer ', ''));
  if (!c) { res.status(401).json({ error: 'unauthorized' }); return null; }
  return c.uid;
}

/** 取用户角色（用于按角色下发模块）；查不到当作普通 user，不因此报错 */
function roleOf(uid) {
  const u = db.prepare('SELECT role FROM users WHERE id=?').get(uid);
  return u?.role || 'user';
}

/** 冷启动拉取（未登录可访问）
 *  注意：这里只下发"对所有人可见"的模块（visibleTo 为空），
 *  用户定向模块必须走 /config（需登录），否则免鉴权接口会泄露"谁有权看什么"。 */
router.get('/bootstrap', (req, res) => {
  const cur = clientconfig.current();
  const cv = String(req.query.clientVersion || '');
  const allModules = appmodules.listVisible({ clientVersion: cv })
    .filter((m) => !(m.visibleTo?.roles?.length || m.visibleTo?.userIds?.length));
  res.json({
    configVersion: cur.version,
    serverVersion: pkg.version,
    payload: cur.payload,
    // 公司名与好友模式是"这台服务器是谁"的公开信息：
    // 登录页要显示「xxx小智」、注册页要按模式变文案 —— 都在登录前，必须免鉴权可取。
    // 不含任何用户数据，符合 SPEC §6.1 的免鉴权硬边界。
    ...settings.all(),
    modules: allModules,
    ts: Date.now(),
  });
});

/** 已登录拉取：完整配置 + 按角色/用户过滤后的动态模块 */
router.get('/config', (req, res) => {
  const uid = uidOf(req, res); if (uid === null) return;
  const cur = clientconfig.current();
  const cv = String(req.query.clientVersion || '');
  res.json({
    configVersion: cur.version,
    serverVersion: pkg.version,
    payload: cur.payload,
    ...settings.all(),
    modules: appmodules.listVisible({ userId: uid, role: roleOf(uid), clientVersion: cv }),
    ts: Date.now(),
  });
});

/**
 * 应用中心（客户端「工作台」的一次性取数入口）
 *
 * 把两类应用合并在一个列表里下发：
 *   kind='builtin'  内置应用（考勤打卡 / 我的申请 / 组织通讯录）—— 随安装包发布
 *   kind='dynamic'  自定义应用（管理台用 JSON 拼的动态模块）
 * 客户端用同一个工作台渲染，用户看到的是"一个应用中心"。
 *
 * 可见性由**业务状态**决定，不由开关决定：没开工作模式就没有考勤入口，
 * 考勤被停用就没有打卡入口 —— 服务端算好再下发，客户端不做判断（SPEC 拍板项 1）。
 * 这样也杜绝了"入口在、点进去报错"的状态。
 */
router.get('/apps', (req, res) => {
  const uid = uidOf(req, res); if (uid === null) return;
  const me = db.prepare('SELECT id, role, org_id FROM users WHERE id=?').get(uid);
  const org = db.prepare('SELECT id, name FROM orgs LIMIT 1').get() || null;
  const friendMode = settings.get('friendMode');
  const attEnabled = settings.get('attendanceEnabled') !== false;
  // 组织成员 = 有 org_id 且归属当前组织；管理员没有 org_id，但仍应看到
  // 「组织通讯录」这类只读入口（他要看全员），所以单独放行 role='admin'
  const hasOrg = !!org && (me.org_id === org.id || me.role === 'admin');

  const builtin = appregistry.listFor({
    friendMode, attendanceEnabled: attEnabled, hasOrg, role: me.role,
  });

  // 角标：管理者的第一诉求是"有没有待处理"，员工的第一诉求是"我打卡了没"。
  // 只给这两处算角标 —— 每个应用都算就是给每次冷启动加一串查询。
  const now = Date.now();
  for (const a of builtin) {
    if (a.id === 'attendance' && me.org_id) {
      const day = attendance.dayOf(now);
      const workdays = settings.get('attWorkdays') || [1, 2, 3, 4, 5];
      const isWorkday = workdays.includes(attendance.weekdayOf(day));
      if (isWorkday) {
        // 口径**不能**写死成"有没有上班卡"：一天 4 次卡的班次里，
        // 打了上班卡就消角标，等于中午、下午漏打都没人提醒；
        // 反过来若按"今天还剩几张卡"算，早上 8 点就在催下午 1 点的卡，同样烦人。
        // 正确的问法是"**已经到点却还没打**的卡有几张"—— 直接复用判定引擎，
        // 免得这里再判一次"今天几次卡"而和报表口径分家。
        const { shift } = attendance.shiftFor(uid, me.org_id);
        const recs = attendance.recordsOn(uid, day);
        const reqs = db.prepare("SELECT * FROM att_requests WHERE user_id=? AND status='approved'").all(uid);
        const judged = attendance.judgeDay({ day, now, shift, recs, reqs, workdays });
        const dueMissing = judged.punches.filter((p) => p.due && !p.done && !p.exempt).length;
        if (dueMissing > 0) a.badge = '待打卡';
      }
    }
    if (a.id === 'my_requests' && me.org_id) {
      const c = db.prepare("SELECT COUNT(*) AS c FROM att_requests WHERE user_id=? AND status='pending'").get(uid).c;
      if (c > 0) a.badge = String(c);
    }
    // 管理员的角标是**待审批条数**（他的待办），不是"谁缺卡"——
    // 缺卡数要跑一遍全员判定（judgeRange），冷启动时为一张卡片付这个代价不值；
    // 待审批一条 COUNT 就够，而且那才是需要他动手的事。
    if (a.id === 'att_admin' && org) {
      const c = db.prepare("SELECT COUNT(*) AS c FROM att_requests WHERE org_id=? AND status='pending'").get(org.id).c;
      if (c > 0) a.badge = String(c);
    }
  }

  const cv = String(req.query.clientVersion || '');
  const dynamic = appmodules.listVisible({ userId: uid, role: me.role, clientVersion: cv })
    .map((m) => ({
      id: m.moduleId, title: m.title, icon: m.icon, group: 'custom',
      desc: '', kind: 'dynamic', sort: m.sort,
      // 把最低版本要求一起下发：服务端已经按 cv 过滤过，客户端仍会**再卡一次**
      // （老客户端连 `?clientVersion=` 都可能没带，那时 cv 为空、这里全部被过滤掉，
      //  这是服务端侧的兜底；客户端侧的兜底见 workbench.dart）。
      minVersion: m.minClientVersion || '',
    }));

  res.json({
    apps: [...builtin, ...dynamic],
    groups: appregistry.GROUPS,
    workMode: friendMode,
    ts: now,
  });
});

/** 客户端上报已生效版本（写 config_applied，管理台"同步状态"的数据来源） */router.post('/report-applied', (req, res) => {
  const uid = uidOf(req, res); if (uid === null) return;
  const ok = clientconfig.reportApplied(uid, req.body?.deviceId, req.body?.configVersion);
  if (!ok) return res.status(400).json({ error: 'configVersion 不合法' });
  res.json({ ok: true });
});

/** 单个模块定义（打开动态页面时拉取，保证拿到的是最新一版，不吃冷启动缓存） */
router.get('/modules/:id', (req, res) => {
  const uid = uidOf(req, res); if (uid === null) return;
  const cv = String(req.query.clientVersion || '');
  const m = appmodules.get(req.params.id);
  if (!m || !m.enabled) return res.status(404).json({ error: '模块不存在或已停用' });
  const visible = appmodules.listVisible({ userId: uid, role: roleOf(uid), clientVersion: cv })
    .some((x) => x.moduleId === m.moduleId);
  if (!visible) return res.status(403).json({ error: '无权访问该模块' });
  res.json({ module: m, ts: Date.now() });
});

/**
 * 动态表单提交。
 * 安全要点：字段白名单取自**服务端存的 schema**，不是客户端传的定义——
 * 否则客户端可以自己发明字段往库里塞任何东西（见 sanitizeSubmission）。
 */
router.post('/modules/:id/submit', (req, res) => {
  const uid = uidOf(req, res); if (uid === null) return;
  const cv = String((req.body && req.body.clientVersion) || req.query.clientVersion || '');
  const m = appmodules.get(req.params.id);
  if (!m || !m.enabled) return res.status(404).json({ error: '模块不存在或已停用' });
  const visible = appmodules.listVisible({ userId: uid, role: roleOf(uid), clientVersion: cv })
    .some((x) => x.moduleId === m.moduleId);
  if (!visible) return res.status(403).json({ error: '无权访问该模块' });
  const r = appmodules.recordSubmission(req.params.id, uid, req.body?.data);
  if (r.error) return res.status(400).json({ error: r.error });
  res.json({ ok: true, id: r.id });
});

module.exports = router;
