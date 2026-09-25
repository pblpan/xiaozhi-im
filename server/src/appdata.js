'use strict';

/**
 * 应用数据源注册表（管理台「应用中心 → 管理 → 数据」那一块的数据来源）
 *
 * ─────────────────────────────────────────────────────────────
 * 为什么要注册表，而不是给每个应用写一个接口
 * ─────────────────────────────────────────────────────────────
 * "看数据"这件事在每个应用上都是同一套形状：**概览几个数 + 明细一张表 + 导出**。
 * 每个应用各写一遍的结果就是分页口径、时间窗口径、导出编码各不一样 ——
 * 管理员会看到"这个应用能翻页那个不能""这个导出中文乱码那个不乱"，
 * 而这种不一致几乎没人会去修，因为它不算 bug。
 *
 * 所以把形状固定下来（概览/明细/导出/清理），每个应用只声明"我有哪些数据源、
 * 每一列叫什么、哪些列要当文本"。分页、时间窗、导出、备份、三步确认全在引擎里。
 *
 * ─────────────────────────────────────────────────────────────
 * 三条诚实原则（这个页面的价值全在上面）
 * ─────────────────────────────────────────────────────────────
 * 1. **没有数据的应用就写"没有数据"**。「扫码枪」纯离线跑在手机上，服务端
 *    一条记录也没有 —— 编一个空表格出来只会让管理员以为"数据丢了"。
 *
 * 2. **共用同一批表的应用要说出来**。「考勤记录」看的就是「考勤打卡」的流水，
 *    在 A 页面清理会同时改变 B 页面看到的数。不写清楚，两个页面一对照
 *    ("这边少了一条") 就会变成一次"数据不一致"的排查。
 *
 * 3. **不能清理的要说清为什么**。培训成绩、盘点差异都是**审计凭据**：
 *    删掉之后"当时到底考了多少分""这批货差在哪"就再也答不上来。
 *    给一个 403 不如给一句"为什么不行"。
 */

const db = require('./db');
const paging = require('./paging');
const att = require('./attendance');

/* ---------------- 展示用的小工具 ---------------- */

/** 时间戳 → 'YYYY-MM-DD HH:MM'（按考勤那套已校准时区，不用容器本地时区） */
function dtText(ts) {
  const n = Number(ts);
  if (!n) return '';
  return `${att.dayOf(n)} ${att.hhmmOf(n)}`;
}

function dayText(ts) {
  const n = Number(ts);
  return n ? att.dayOf(n) : '';
}

const SRC = {
  app: '客户端',
  admin: '管理员代打',
  makeup: '补卡审批',
};

const REQ_STATUS = { pending: '待审批', approved: '已通过', rejected: '已驳回', canceled: '已撤销' };
const REQ_KIND = { leave: '请假', makeup: '补卡', outing: '外出', overtime: '加班' };
const PHASE = { 1: '初盘', 2: '复盘', 3: '抽盘' };
const SHEET_STATUS = { 0: '进行中', 1: '已提交', 2: '已上传' };

/* ============================================================
 * 可复用的数据源（多个应用共用同一张表时，共用同一个对象 ——
 * 免得"考勤打卡"和"考勤记录"两边对同一列给出不同的名字）
 * ============================================================ */

/** 打卡流水（att_records）：考勤打卡 与 考勤记录 共用 */
const SRC_ATT_RECORDS = {
  key: 'records',
  name: '打卡流水',
  desc: '每一次打卡（含管理员代打与补卡审批写入）都是一条记录。',
  // 🔴 r.user_id 必须选出来：map 里要拿它换班次（同一张 out1 卡在 2 次卡
  //    和 4 次卡里的叫法不同），漏了它只会得到一句 "undefined" 之类的错，
  //    而且是在管理台打开抽屉时才炸
  select: `r.id, r.user_id, r.day, r.type, r.slot, r.at, r.source, r.lat, r.lng, r.address, r.device, r.note,
    u.nickname, u.username, u.employee_no`,
  from: `FROM att_records r LEFT JOIN users u ON u.id = r.user_id`,
  timeCol: 'r.at',
  order: 'r.at DESC, r.id DESC',
  search: ['u.nickname', 'u.username', 'u.employee_no', 'r.day', 'r.address'],
  columns: [
    { key: 'id', label: 'ID', width: 70 },
    { key: 'day', label: '日期', width: 100 },
    { key: 'who', label: '员工', width: 130 },
    { key: 'punch', label: '卡次', width: 120 },
    { key: 'atText', label: '打卡时刻', width: 150 },
    { key: 'sourceText', label: '来源', width: 100 },
    { key: 'address', label: '定位地址', width: 200 },
    { key: 'device', label: '设备', width: 140 },
  ],
  map: (r, ctx) => {
    const shift = att.shiftForCached(r.user_id, ctx.orgId, ctx.shiftCache).shift;
    const slot = Number(r.slot) === 2 ? 2 : 1;
    const label = att.punchLabelOf(shift, `${r.type}${slot}`);
    return {
      id: r.id,
      day: r.day,
      who: r.nickname || r.username || `用户${r.user_id}`,
      // 🔴 4 次卡的班次里 punchLabelOf 对第 1、2 段都返回「上班」/「下班」，
      //    表格里会出现两行一模一样的"上班"——**根本分不出是哪一段**。
      //    段号只在多段班次时才加：2 次卡加"第1段"纯属噪音。
      punch: shift.segments === 2 ? `第${slot}段 ${label}` : label,
      atText: dtText(r.at),
      sourceText: SRC[r.source] || r.source,
      address: r.address || (r.lat != null ? `${Number(r.lat).toFixed(5)}, ${Number(r.lng).toFixed(5)}` : ''),
      device: r.device || '',
    };
  },
  needUserId: true,
  purge: { table: 'att_records', idCol: 'r.id', timeCol: 'at', label: '打卡流水' },
};

/** 申请单（att_requests）：我的申请 与 考勤记录 共用 */
const SRC_ATT_REQUESTS = {
  key: 'requests',
  name: '申请单',
  desc: '请假 / 补卡 / 外出 / 加班的申请与审批结果。',
  select: `r.id, r.kind, r.status, r.reason, r.start_day, r.end_day, r.half, r.leave_type,
    r.day, r.clock_type, r.at, r.slot, r.reviewed_at, r.review_note, r.created_at,
    u.nickname, u.username, u.employee_no`,
  from: `FROM att_requests r LEFT JOIN users u ON u.id = r.user_id`,
  timeCol: 'r.created_at',
  order: 'r.created_at DESC, r.id DESC',
  search: ['u.nickname', 'u.username', 'r.reason'],
  columns: [
    { key: 'id', label: 'ID', width: 70 },
    { key: 'who', label: '申请人', width: 130 },
    { key: 'kindText', label: '类型', width: 70 },
    { key: 'detail', label: '内容', width: 260 },
    { key: 'statusText', label: '状态', width: 80 },
    { key: 'review', label: '审批', width: 200 },
    { key: 'createdText', label: '提交时间', width: 150 },
  ],
  map: (r) => {
    const range = r.kind === 'leave'
      ? `${r.start_day || ''} ~ ${r.end_day || ''}${r.half === 1 ? '（上午半天）' : r.half === 2 ? '（下午半天）' : ''}`
      : (r.kind === 'makeup'
        ? `${r.day || ''} 第${Number(r.slot) === 2 ? 2 : 1}段 ${r.clock_type || ''} 补于 ${r.at ? att.hhmmOf(r.at) : ''}`
        : `${dtText(r.start_at)} ~ ${dtText(r.end_at)}`);
    return {
      id: r.id,
      who: r.nickname || r.username || `用户${r.user_id}`,
      kindText: REQ_KIND[r.kind] || r.kind,
      detail: `${range}${r.reason ? `　${r.reason}` : ''}`,
      statusText: REQ_STATUS[r.status] || r.status,
      // 审批信息放一列：驳回了没写理由最容易被追问，这里一眼能看到
      review: r.reviewed_at
        ? `${dtText(r.reviewed_at)}${r.review_note ? `　${r.review_note}` : ''}`
        : (r.status === 'pending' ? '等待审批' : ''),
      createdText: dtText(r.created_at),
    };
  },
  purge: { table: 'att_requests', idCol: 'r.id', timeCol: 'created_at', label: '申请单' },
};

/* ============================================================
 * 应用 → 数据源
 * ============================================================ */

const APPS = {
  /* ---------------- 考勤打卡 ---------------- */
  attendance: {
    overviewNote: '这里看的是这台服务器上所有的打卡流水，不分人。判定结果（迟到/缺卡）请到「考勤管理」页看报表 —— 那是按班次算出来的，跟流水条数不是一回事。',
    metrics: [
      { key: 'today', label: '今日打卡', sql: 'SELECT COUNT(*) n FROM att_records WHERE day=?', args: () => [att.today()] },
      { key: 'week', label: '近 7 天打卡', sql: 'SELECT COUNT(*) n FROM att_records WHERE at>=?', args: () => [Date.now() - 7 * 86400000] },
      { key: 'total', label: '累计打卡', sql: 'SELECT COUNT(*) n FROM att_records' },
      { key: 'people', label: '涉及员工', unit: '人', sql: 'SELECT COUNT(DISTINCT user_id) n FROM att_records' },
      { key: 'byAdmin', label: '其中代打/补卡', sql: "SELECT COUNT(*) n FROM att_records WHERE source<>'app'" },
    ],
    sources: [SRC_ATT_RECORDS],
  },

  /* ---------------- 我的申请 ---------------- */
  my_requests: {
    overviewNote: '申请单是审批留痕，通过/驳回的理由都会一直留着 —— 这是事后核对「当时批没批、为什么」的唯一依据。',
    metrics: [
      { key: 'pending', label: '待审批', sql: "SELECT COUNT(*) n FROM att_requests WHERE status='pending'" },
      { key: 'approved', label: '已通过', sql: "SELECT COUNT(*) n FROM att_requests WHERE status='approved'" },
      { key: 'rejected', label: '已驳回', sql: "SELECT COUNT(*) n FROM att_requests WHERE status='rejected'" },
      { key: 'total', label: '申请总数', sql: 'SELECT COUNT(*) n FROM att_requests' },
    ],
    sources: [SRC_ATT_REQUESTS],
  },

  /* ---------------- 组织通讯录 ---------------- */
  work_org: {
    overviewNote: '组织和人员是「配置」不是「流水」：这里只提供查看与导出，不提供清理。要增删人请到「组织机构」页 —— 那样会同时处理账号、好友关系和考勤归属，从这里直接删会留下对不上的数据。',
    metrics: [
      { key: 'orgs', label: '组织', sql: 'SELECT COUNT(*) n FROM orgs' },
      { key: 'depts', label: '部门', sql: 'SELECT COUNT(*) n FROM org_depts' },
      { key: 'positions', label: '岗位', sql: 'SELECT COUNT(*) n FROM org_positions' },
      { key: 'members', label: '在册员工', unit: '人', sql: 'SELECT COUNT(*) n FROM users WHERE org_id IS NOT NULL' },
      { key: 'noDept', label: '未分配部门', unit: '人', sql: 'SELECT COUNT(*) n FROM users WHERE org_id IS NOT NULL AND dept_id IS NULL' },
    ],
    sources: [
      {
        key: 'members',
        name: '员工名册',
        desc: '已经录进组织的账号（工号 = 登录账号）。',
        select: `u.id, u.username, u.nickname, u.employee_no, u.org_id, u.role,
          d.name AS dept_name, p.name AS position_name, u.created_at`,
        from: `FROM users u
          LEFT JOIN org_depts d ON d.id = u.dept_id
          LEFT JOIN org_positions p ON p.id = u.position_id`,
        where: () => ({ sql: ['u.org_id IS NOT NULL'], args: [] }),
        timeCol: 'u.created_at',
        order: 'u.id ASC',
        search: ['u.nickname', 'u.username', 'u.employee_no'],
        columns: [
          { key: 'id', label: 'ID', width: 70 },
          { key: 'employeeNo', label: '工号', width: 120, text: true },
          { key: 'who', label: '姓名', width: 130 },
          { key: 'dept', label: '部门', width: 140 },
          { key: 'position', label: '岗位', width: 140 },
          { key: 'roleText', label: '角色', width: 80 },
          { key: 'createdText', label: '入册时间', width: 150 },
        ],
        map: (r) => ({
          id: r.id,
          employeeNo: r.employee_no || r.username,
          who: r.nickname || r.username,
          dept: r.dept_name || '（未分配）',
          position: r.position_name || '',
          roleText: r.role === 'admin' ? '管理员' : '员工',
          createdText: dtText(r.created_at),
        }),
      },
      {
        key: 'depts',
        name: '部门',
        desc: '支持父子层级（parent_id = 0 为顶级）。',
        select: 'd.id, d.name, d.parent_id, d.sort, o.name AS org_name',
        from: 'FROM org_depts d LEFT JOIN orgs o ON o.id = d.org_id',
        timeCol: null,
        order: 'd.sort ASC, d.id ASC',
        search: ['d.name'],
        columns: [
          { key: 'id', label: 'ID', width: 70 },
          { key: 'name', label: '部门', width: 200 },
          { key: 'parent', label: '上级', width: 160 },
          { key: 'sort', label: '排序', width: 80 },
          { key: 'org', label: '组织', width: 160 },
        ],
        map: (r) => ({
          id: r.id,
          name: r.name,
          parent: Number(r.parent_id) > 0 ? (db.prepare('SELECT name FROM org_depts WHERE id=?').get(r.parent_id)?.name || '（已删除）') : '（顶级）',
          sort: r.sort,
          org: r.org_name || '',
        }),
      },
      {
        key: 'positions',
        name: '岗位',
        desc: '可挂在某个部门下，也可以是全组织通用（dept_id 为空）。',
        select: 'p.id, p.name, p.dept_id, p.sort, d.name AS dept_name',
        from: 'FROM org_positions p LEFT JOIN org_depts d ON d.id = p.dept_id',
        timeCol: null,
        order: 'p.sort ASC, p.id ASC',
        search: ['p.name'],
        columns: [
          { key: 'id', label: 'ID', width: 70 },
          { key: 'name', label: '岗位', width: 200 },
          { key: 'dept', label: '所属部门', width: 180 },
          { key: 'sort', label: '排序', width: 80 },
        ],
        map: (r) => ({ id: r.id, name: r.name, dept: r.dept_name || '（全组织通用）', sort: r.sort }),
      },
    ],
    readOnlyReason: '组织与人员是配置数据，增删改一律走「组织机构」页（那里会同时处理账号、好友与考勤归属）。',
  },

  /* ---------------- 考勤记录（管理层看的那份） ---------------- */
  att_admin: {
    // 🔴 这一条必须写：两个页面看同一批表，在一边清理会同时改变另一边的数，
    //    不写清楚就会变成一次"数据对不上"的排查
    overviewNote: '⚠️ 这里的数据与「考勤打卡」「我的申请」是**同一批表**：在任一应用里清理，这里看到的数会同步变化。'
      + '这个应用本身不提供清理入口，避免两处都能删同一批数据。',
    metrics: [
      { key: 'recordsToday', label: '今日打卡', sql: 'SELECT COUNT(*) n FROM att_records WHERE day=?', args: () => [att.today()] },
      { key: 'pending', label: '待审批申请', sql: "SELECT COUNT(*) n FROM att_requests WHERE status='pending'" },
      { key: 'recordsTotal', label: '打卡流水', sql: 'SELECT COUNT(*) n FROM att_records' },
      { key: 'requestsTotal', label: '申请单', sql: 'SELECT COUNT(*) n FROM att_requests' },
    ],
    sources: [SRC_ATT_RECORDS, SRC_ATT_REQUESTS],
    readOnlyReason: '这两个数据源与「考勤打卡」「我的申请」共用同一批表，清理入口统一放在那两个应用里，避免两处都能删。',
  },

  /* ---------------- 扫码枪（纯离线） ---------------- */
  stocktake: {
    localOnly: true,
    localOnlyNote: '「扫码枪」是**纯离线**应用：扫码、明细、导出、盈亏表全部在手机上完成，'
      + '服务端没有它的任何接口，也没有它的任何数据。所以这里没有可看的数据 —— '
      + '这不是"数据丢了"，而是这个应用本来就不往服务器传。'
      + '停用它只会让客户端不再显示入口，手机上已采集的数据不受影响，导出照旧。',
    metrics: [],
    sources: [],
  },

  /* ---------------- 简易盘点（纯离线） ---------------- */
  simple_stocktake: {
    localOnly: true,
    localOnlyNote: '「简易盘点」和「库房减货」一样是**纯离线**应用：这一轮要盘的清单'
      + '（导入的 CSV）、每一趟节点、扫到的数量、导出的盘点数据单，全都只在手机上，'
      + '服务端没有它的任何接口，也没有它的任何数据。'
      + '所以这里没有可看的数据 —— 不是"数据丢了"，而是它本来就不往服务器传。'
      + '停用它只会让客户端不再显示入口，已导入的清单和已经盘过的数不受影响。',
    metrics: [],
    sources: [],
  },

  /* ---------------- 库房减货 ---------------- */
  //
  // 🔴 2026-09-25 起**不再纯离线**：龙哥定"减货单要上传管理台，因为要对账"。
  //    单据与明细从手机上传上来（POST /api/deduct/sheet/:no/upload），
  //    管理台「库房减货」页能对账（按商品跨单累加）。
  warehouse_deduct: {
    metrics: [
      { key: 'sheets', label: '减货单', sql: "SELECT COUNT(*) n FROM inv_sheets WHERE sheet_type = 'deduct'" },
      { key: 'rows', label: '明细行', sql: "SELECT COUNT(*) n FROM inv_scans WHERE sheet_type = 'deduct'" },
      { key: 'total_qty', label: '减货总数量', sql: "SELECT COALESCE(SUM(qty),0) n FROM inv_scans WHERE sheet_type = 'deduct'" },
    ],
    sources: [
      { label: '减货单与明细', table: 'inv_sheets / inv_scans', note: "sheet_type = 'deduct'" },
    ],
  },

  /* ---------------- 补货（纯离线） ---------------- */
  replenish: {
    localOnly: true,
    localOnlyNote: '「补货」是**纯离线**应用：补货单（分生鲜/杂百两个场景）、'
      + '明细、导出全部在手机上完成，数据落在手机本地的 '
      + 'stocktake_sheet / scan_record（sheet_type=replenish），'
      + '服务端没有它的任何接口，也没有它的任何数据。'
      + '所以这里没有可看的数据 —— 不是"数据丢了"，而是它本来就不往服务器传。'
      + '（「库房减货」已经改成要上传了，补货要不要同样对账还没定；'
      + '真要做，走减货那套 /api/deduct 的同构通道即可。）',
    metrics: [],
    sources: [],
  },

  /* ---------------- 价签打印（纯离线，且不留任何记录） ---------------- */
  //
  // 🔴 这里刻意与别的模块不同：**连 metrics 都不给**。
  //    盘点/减货能报"多少单多少行"，是因为服务端存着它们；
  //    价签服务端一条都没存 —— 打出去就贴在货上了，没有第二方认它。
  //    给一张空的"0 单 0 行"反而是句假话，所以这里连问都不问。
  price_tag: {
    localOnly: true,
    localOnlyNote: '「价签打印」连数据都不往服务器传：扫到的码、改过的售价、'
      + '打了多少张，全在手机上过一遍就出纸了，服务端没有它的接口，也没有它的任何记录 —— '
      + '不打单、不落库、不上报。所以这里没有可看的数据，这不是"数据丢了"，'
      + '而是它压根就不往服务器传。停用它只影响入口。',
    metrics: [],
    sources: [],
  },

  /* ---------------- 盘点 ---------------- */
  inventory: {
    overviewNote: '盘点的差异与失误笔数是从这批数据算出来的，所以这里**只提供查看与导出**：'
      + '删掉单据或明细，等于把当时的差异结论也一起删了，事后没人能复原"这批货到底差在哪"。',
    metrics: [
      { key: 'zones', label: '盘点位', sql: 'SELECT COUNT(*) n FROM inv_zones' },
      { key: 'locations', label: '货架位', sql: 'SELECT COUNT(*) n FROM inv_locations' },
      { key: 'sheets', label: '盘点单', sql: 'SELECT COUNT(*) n FROM inv_sheets' },
      { key: 'sheetsUploaded', label: '其中已上传', sql: 'SELECT COUNT(*) n FROM inv_sheets WHERE status=2' },
      { key: 'scans', label: '明细条数', sql: 'SELECT COUNT(*) n FROM inv_scans' },
      { key: 'bindings', label: '商品货位绑定', sql: 'SELECT COUNT(*) n FROM inv_barcode_locations' },
      { key: 'grantsLive', label: '生效中的抽盘授权', sql: 'SELECT COUNT(*) n FROM inv_grants WHERE revoked_at IS NULL' },
    ],
    sources: [
      {
        key: 'sheets',
        name: '盘点单',
        desc: '一张单 = 一个盘点位的一个阶段（初盘 / 复盘 / 抽盘）。',
        select: `s.sheet_no, s.zone_code, s.phase, s.status, s.operator, s.device_id,
          s.started_at, s.submitted_at, s.uploaded_at, s.created_at,
          z.zone_name,
          (SELECT COUNT(*) FROM inv_scans c WHERE c.sheet_no = s.sheet_no) AS scan_count`,
        from: 'FROM inv_sheets s LEFT JOIN inv_zones z ON z.zone_code = s.zone_code',
        timeCol: 's.created_at',
        order: 's.created_at DESC',
        search: ['s.sheet_no', 's.zone_code', 'z.zone_name', 's.operator'],
        columns: [
          { key: 'sheetNo', label: '单号', width: 170, text: true },
          { key: 'zone', label: '盘点位', width: 150 },
          { key: 'phaseText', label: '阶段', width: 70 },
          { key: 'statusText', label: '状态', width: 80 },
          { key: 'scanCount', label: '明细条数', width: 90 },
          { key: 'operator', label: '操作人', width: 110 },
          { key: 'uploadedText', label: '上传时间', width: 150 },
        ],
        map: (r) => ({
          sheetNo: r.sheet_no,
          zone: r.zone_name ? `${r.zone_name}（${r.zone_code}）` : r.zone_code,
          phaseText: PHASE[r.phase] || r.phase,
          statusText: SHEET_STATUS[r.status] || r.status,
          scanCount: r.scan_count,
          operator: r.operator || '',
          uploadedText: dtText(r.uploaded_at),
        }),
      },
      {
        key: 'scans',
        name: '盘点明细',
        desc: '上传上来的每一条「某单某条码数量」。条码与单号都当文本导出，避免 Excel 把它们变成科学计数法。',
        select: `c.id, c.sheet_no, c.zone_code, c.phase, c.barcode, c.qty, c.account_qty,
          c.loc_code, c.scanned_at, c.uploaded_at`,
        from: 'FROM inv_scans c',
        timeCol: 'c.uploaded_at',
        order: 'c.uploaded_at DESC, c.id DESC',
        search: ['c.sheet_no', 'c.barcode', 'c.loc_code', 'c.zone_code'],
        columns: [
          { key: 'barcode', label: '条码', width: 150, text: true },
          { key: 'qty', label: '实盘数', width: 90 },
          { key: 'accountQty', label: '账面数', width: 90 },
          { key: 'diff', label: '差异', width: 80 },
          { key: 'sheetNo', label: '单号', width: 170, text: true },
          { key: 'phaseText', label: '阶段', width: 70 },
          { key: 'locCode', label: '货架位', width: 110, text: true },
          { key: 'uploadedText', label: '上传时间', width: 150 },
        ],
        map: (r) => ({
          barcode: r.barcode,
          qty: r.qty,
          accountQty: r.account_qty == null ? '（账上无此商品）' : r.account_qty,
          diff: r.account_qty == null ? '' : Math.round((Number(r.qty) - Number(r.account_qty)) * 1000) / 1000,
          sheetNo: r.sheet_no,
          phaseText: PHASE[r.phase] || r.phase,
          locCode: r.loc_code || '',
          uploadedText: dtText(r.uploaded_at),
        }),
      },
      {
        key: 'zones',
        name: '盘点位',
        desc: '盘点位与它的货架位。locked = 锁定后不允许再开工。',
        select: `z.zone_code, z.zone_name, z.store_code, z.locked, z.updated_at,
          (SELECT COUNT(*) FROM inv_locations l WHERE l.zone_code = z.zone_code) AS loc_count`,
        from: 'FROM inv_zones z',
        timeCol: 'z.updated_at',
        order: 'z.zone_code ASC',
        search: ['z.zone_code', 'z.zone_name'],
        columns: [
          { key: 'zoneCode', label: '点位编码', width: 130, text: true },
          { key: 'zoneName', label: '点位名称', width: 200 },
          { key: 'storeCode', label: '门店', width: 100, text: true },
          { key: 'locCount', label: '货架位数', width: 100 },
          { key: 'lockedText', label: '状态', width: 90 },
        ],
        map: (r) => ({
          zoneCode: r.zone_code,
          zoneName: r.zone_name || '',
          storeCode: r.store_code || '',
          locCount: r.loc_count,
          lockedText: r.locked ? '已锁定' : '可用',
        }),
      },
      {
        key: 'grants',
        name: '抽盘授权',
        desc: '按盘点位授权。**解除是置 revoked_at 时间戳，不删行** —— 留着才能回答"当时到底授没授权给他"。',
        select: `g.zone_code, g.user_id, g.granted_by, g.granted_at, g.revoked_at,
          u.nickname, u.username, z.zone_name`,
        from: `FROM inv_grants g LEFT JOIN users u ON u.id = g.user_id
          LEFT JOIN inv_zones z ON z.zone_code = g.zone_code`,
        timeCol: 'g.granted_at',
        order: 'g.granted_at DESC',
        search: ['g.zone_code', 'u.nickname', 'u.username'],
        columns: [
          { key: 'zone', label: '盘点位', width: 200 },
          { key: 'who', label: '被授权人', width: 130 },
          { key: 'grantedText', label: '授权时间', width: 150 },
          { key: 'stateText', label: '状态', width: 90 },
          { key: 'revokedText', label: '解除时间', width: 150 },
        ],
        map: (r) => ({
          zone: r.zone_name ? `${r.zone_name}（${r.zone_code}）` : r.zone_code,
          who: r.nickname || r.username || `用户${r.user_id}`,
          grantedText: dtText(r.granted_at),
          stateText: r.revoked_at ? '已解除' : '生效中',
          revokedText: dtText(r.revoked_at),
        }),
      },
    ],
    readOnlyReason: '盘点数据是差异结论的凭据：单据与明细一旦删除，当时的差异与失误笔数就无法复原。要清理请走「盘点」页的归档流程。',
  },

  /* ---------------- 培训中心 ---------------- */
  training: {
    overviewNote: '培训的成绩与进度是考核凭据（"当时考了多少分"必须有据可查），所以这里只提供查看与导出，不提供清理。',
    metrics: [
      { key: 'courses', label: '课程', sql: 'SELECT COUNT(*) n FROM tr_course' },
      { key: 'published', label: '其中已发布', sql: 'SELECT COUNT(*) n FROM tr_course WHERE published=1' },
      { key: 'lessons', label: '课时', sql: 'SELECT COUNT(*) n FROM tr_lesson' },
      { key: 'enrolls', label: '加入学习', unit: '人次', sql: 'SELECT COUNT(*) n FROM tr_enroll' },
      { key: 'progressDone', label: '已学完课时', unit: '人次', sql: 'SELECT COUNT(*) n FROM tr_progress WHERE done=1' },
      { key: 'sheets', label: '答卷', sql: 'SELECT COUNT(*) n FROM tr_sheet WHERE submitted_at>0' },
      { key: 'passed', label: '其中及格', sql: 'SELECT COUNT(*) n FROM tr_sheet WHERE submitted_at>0 AND pass=1' },
    ],
    sources: [
      {
        key: 'courses',
        name: '课程',
        desc: '未发布的课程学员看不到（草稿态）。',
        select: `c.id, c.title, c.category, c.required, c.published, c.created_at,
          (SELECT COUNT(*) FROM tr_chapter ch WHERE ch.course_id = c.id) AS chapter_count,
          (SELECT COUNT(*) FROM tr_lesson l JOIN tr_chapter ch2 ON ch2.id = l.chapter_id WHERE ch2.course_id = c.id) AS lesson_count`,
        from: 'FROM tr_course c',
        timeCol: 'c.created_at',
        order: 'c.created_at DESC',
        search: ['c.title', 'c.category'],
        columns: [
          { key: 'id', label: 'ID', width: 70 },
          { key: 'title', label: '课程', width: 260 },
          { key: 'category', label: '分类', width: 130 },
          { key: 'chapterCount', label: '章节', width: 70 },
          { key: 'lessonCount', label: '课时', width: 70 },
          { key: 'flags', label: '属性', width: 120 },
          { key: 'createdText', label: '创建时间', width: 150 },
        ],
        map: (r) => ({
          id: r.id,
          title: r.title,
          category: r.category || '',
          chapterCount: r.chapter_count,
          lessonCount: r.lesson_count,
          flags: [r.required ? '必修' : '', r.published ? '已发布' : '草稿'].filter(Boolean).join(' / '),
          createdText: dtText(r.created_at),
        }),
      },
      {
        key: 'sheets',
        name: '考试成绩',
        desc: '成绩在交卷那一刻就落库了，之后改题不影响历史分数 —— 所以这里看到的是"当时考的"。',
        select: `s.id, s.user_id, s.attempt_no, s.score, s.pass, s.started_at, s.submitted_at,
          u.nickname, u.username, e.title AS exam_title, e.pass_score, c.title AS course_title`,
        from: `FROM tr_sheet s
          LEFT JOIN users u ON u.id = s.user_id
          LEFT JOIN tr_exam e ON e.id = s.exam_id
          LEFT JOIN tr_chapter ch ON ch.id = e.chapter_id
          LEFT JOIN tr_course c ON c.id = ch.course_id`,
        where: () => ({ sql: ['s.submitted_at > 0'], args: [] }),
        timeCol: 's.submitted_at',
        order: 's.submitted_at DESC',
        search: ['u.nickname', 'u.username', 'e.title', 'c.title'],
        columns: [
          { key: 'who', label: '学员', width: 130 },
          { key: 'course', label: '课程', width: 200 },
          { key: 'exam', label: '考试', width: 160 },
          { key: 'attempt', label: '第几次', width: 80 },
          { key: 'scoreText', label: '得分', width: 110 },
          { key: 'resultText', label: '结果', width: 80 },
          { key: 'submittedText', label: '交卷时间', width: 150 },
        ],
        map: (r) => ({
          who: r.nickname || r.username || `用户${r.user_id}`,
          course: r.course_title || '',
          exam: r.exam_title || '',
          attempt: `第 ${r.attempt_no} 次`,
          scoreText: `${r.score} / 及格 ${r.pass_score}`,
          resultText: r.pass ? '及格' : '未及格',
          submittedText: dtText(r.submitted_at),
        }),
      },
      {
        key: 'progress',
        name: '学习进度',
        desc: '每课时一行（看到第几秒 / 是否学完）。',
        select: `p.user_id, p.lesson_id, p.position_sec, p.done, p.updated_at,
          u.nickname, u.username, l.title AS lesson_title, l.duration_sec,
          ch.title AS chapter_title, c.title AS course_title`,
        from: `FROM tr_progress p
          LEFT JOIN users u ON u.id = p.user_id
          LEFT JOIN tr_lesson l ON l.id = p.lesson_id
          LEFT JOIN tr_chapter ch ON ch.id = l.chapter_id
          LEFT JOIN tr_course c ON c.id = ch.course_id`,
        timeCol: 'p.updated_at',
        order: 'p.updated_at DESC',
        search: ['u.nickname', 'u.username', 'l.title', 'c.title'],
        columns: [
          { key: 'who', label: '学员', width: 130 },
          { key: 'course', label: '课程', width: 180 },
          { key: 'chapter', label: '章节', width: 160 },
          { key: 'lesson', label: '课时', width: 200 },
          { key: 'percentText', label: '进度', width: 100 },
          { key: 'doneText', label: '状态', width: 80 },
          { key: 'updatedText', label: '最后更新', width: 150 },
        ],
        map: (r) => {
          const dur = Number(r.duration_sec) || 0;
          const pos = Number(r.position_sec) || 0;
          return {
            who: r.nickname || r.username || `用户${r.user_id}`,
            course: r.course_title || '',
            chapter: r.chapter_title || '',
            lesson: r.lesson_title || '',
            percentText: dur > 0 ? `${Math.min(100, Math.round((pos / dur) * 100))}%` : '—',
            doneText: r.done ? '已学完' : '学习中',
            updatedText: dtText(r.updated_at),
          };
        },
      },
    ],
    readOnlyReason: '培训成绩与学习进度是考核凭据，删掉就无法回答"当时考了多少分"。课程本身请在「培训中心」管理页维护。',
  },
};

/* ============================================================
 * 引擎：概览 / 明细 / 导出 / 清理
 * ============================================================ */

function metricsOf(appId) {
  const a = APPS[appId];
  if (!a) return { items: [], warnings: [] };
  const warnings = [];
  const items = a.metrics.map((m) => {
    let n = 0;
    try {
      const args = m.args ? m.args() : [];
      n = db.prepare(m.sql).get(...args)?.n ?? 0;
    } catch (e) {
      // 表在一台老库上可能还没建（迁移没跑到）—— 报 0 **并说明原因**，
      // 静默报 0 会被读成"真的没有数据"，那是两件完全不同的事。
      n = 0;
      warnings.push(`「${m.label}」取数失败：${e.message}`);
    }
    return { key: m.key, label: m.label, value: Number(n) || 0, unit: m.unit || '' };
  });
  return { items, warnings };
}

function sourcesOf(appId) {
  const a = APPS[appId];
  if (!a) return [];
  return a.sources.map((s) => ({
    key: s.key,
    name: s.name,
    desc: s.desc || '',
    columns: s.columns.map((c) => ({ key: c.key, label: c.label, width: c.width || 120, text: !!c.text })),
    purgeable: !!s.purge,
    // 没有时间列的数据源不受时间筛选影响，界面上要说出来，
    // 否则"选了最近 7 天但条数没变"会被当成筛选坏了
    timeFiltered: !!s.timeCol,
  }));
}

function sourceOf(appId, key) {
  const a = APPS[appId];
  if (!a) return null;
  return a.sources.find((s) => s.key === key) || null;
}

/**
 * 时间窗：数据源没有时间列时（部门/岗位这种配置数据）把窗口清掉。
 * 返回**新的 list**，不改调用方传进来的对象 —— 否则同一个 list 在
 * "先算 count 再取 sample"两处会被改两次。
 */
function windowFor(src, list) {
  if (src.timeCol) return list;
  return { ...list, from: null, to: null, allTime: true };
}

/** 拼 WHERE（时间窗 + 固定条件 + 关键词），params 按拼接顺序 push —— 顺序必须一致 */
function buildWhere(src, list, keyword) {
  const params = [];
  const where = [];
  if (src.timeCol) where.push(...paging.timeWhere(list, params, src.timeCol));
  if (src.where) {
    const fx = src.where();
    where.push(...fx.sql);
    params.push(...fx.args);
  }
  const kw = String(keyword || '').trim();
  if (kw && src.search && src.search.length) {
    where.push('(' + src.search.map((c) => `${c} LIKE ? ESCAPE '\\'`).join(' OR ') + ')');
    for (let i = 0; i < src.search.length; i++) params.push(paging.likeParam(kw));
  }
  return { sql: where.length ? `WHERE ${where.join(' AND ')}` : '', params };
}

/** 明细（分页）。返回 envelope + timeFiltered，或 { error } */
function detail(appId, key, rawList, keyword) {
  const src = sourceOf(appId, key);
  if (!src) return { error: `应用 ${appId} 没有数据源 ${key}` };
  const list = windowFor(src, rawList);
  const w = buildWhere(src, list, keyword);
  const total = db.prepare(`SELECT COUNT(*) n ${src.from} ${w.sql}`).get(...w.params).n;
  const rows = db.prepare(`SELECT ${src.select} ${src.from} ${w.sql} ORDER BY ${src.order} LIMIT ? OFFSET ?`)
    .all(...w.params, list.pageSize, list.offset);
  // 班次缓存：一页最多 200 行，不缓存会对同一员工反复查班次
  const ctx = { orgId: orgIdOf(), shiftCache: new Map() };
  const items = rows.map((r, i) => {
    const mapped = src.map(r, ctx);
    // 行没有天然主键时补一个（管理台的表格需要 key），
    // 用**下标 + offset** 而不是 indexOf —— 后者在有重复行时会给出同一个 key
    if (mapped.id === undefined || mapped.id === null) mapped.id = list.offset + i;
    return mapped;
  });
  return { ...paging.envelope(list, items, total), timeFiltered: !!src.timeCol };
}

/** 服务器唯一组织（全项目一致的单组织语义） */
function orgIdOf() {
  const o = db.prepare('SELECT id FROM orgs LIMIT 1').get();
  return o ? o.id : 0;
}

/** CSV 单元格：长数字与带前导零的编码在 Excel 里会被改写成科学计数法/丢零 */
function csvCell(v, isText) {
  if (v === null || v === undefined) return '';
  const s = String(v);
  if (s === '') return '';
  if (isText && (/^\d{9,}$/.test(s) || /^0\d+$/.test(s))) {
    // 写成 ="123" 让 Excel 当文本。外层仍按 RFC4180 加引号，
    // 所以标准解析器读到的是 ="123" 这个字面量，两边都不吃亏。
    return `"${(`="${s}"`).replace(/"/g, '""')}"`;
  }
  if (/[",\n\r]/.test(s)) return `"${s.replace(/"/g, '""')}"`;
  return s;
}

/**
 * 导出 CSV（带 UTF-8 BOM —— 不带的话 Excel 打开中文全是乱码，
 * 而这正是"导出功能不可用"的第一大投诉）。
 * 上限保护：一次最多导 20000 行，超了在末尾留一行说明，**绝不静默截断**。
 */
const CSV_MAX = 20000;

function csv(appId, key, rawList, keyword) {
  const src = sourceOf(appId, key);
  if (!src) return { error: `应用 ${appId} 没有数据源 ${key}` };
  const list = windowFor(src, rawList);
  const w = buildWhere(src, list, keyword);
  const total = db.prepare(`SELECT COUNT(*) n ${src.from} ${w.sql}`).get(...w.params).n;
  const rows = db.prepare(`SELECT ${src.select} ${src.from} ${w.sql} ORDER BY ${src.order} LIMIT ?`)
    .all(...w.params, CSV_MAX);
  const ctx = { orgId: orgIdOf(), shiftCache: new Map() };
  const cols = src.columns;
  const lines = [cols.map((c) => csvCell(c.label, false)).join(',')];
  for (const r of rows) {
    const m = src.map(r, ctx);
    lines.push(cols.map((c) => csvCell(m[c.key], !!c.text)).join(','));
  }
  if (total > rows.length) {
    lines.push(csvCell(`（以上为前 ${rows.length} 行，共 ${total} 行 —— 请缩小时间范围后用筛选分次导出）`, false));
  } else if (!rows.length) {
    lines.push(csvCell('（当前筛选条件下没有任何数据）', false));
  }
  return { csv: '\uFEFF' + lines.join('\r\n') + '\r\n', rows: rows.length, total, sourceName: src.name };
}

/**
 * 备份用：把命中行整批取出来（映射后的对象数组），供删除前落盘。
 * 上限 5000 行 + `truncated` 标志：备份的目的是"能捞回关键几条"，
 * 不是把整个库搬一份；但**截断必须说出来**，否则会以为"备份全了"。
 */
const BACKUP_MAX = 5000;

function rowsForBackup(appId, key, rawList, keyword, limit = BACKUP_MAX) {
  const src = sourceOf(appId, key);
  if (!src) return { error: `应用 ${appId} 没有数据源 ${key}` };
  const list = windowFor(src, rawList);
  const w = buildWhere(src, list, keyword);
  const total = db.prepare(`SELECT COUNT(*) n ${src.from} ${w.sql}`).get(...w.params).n;
  const rows = db.prepare(`SELECT ${src.select} ${src.from} ${w.sql} ORDER BY ${src.order} LIMIT ?`)
    .all(...w.params, limit);
  const ctx = { orgId: orgIdOf(), shiftCache: new Map() };
  return {
    rows: rows.map((r) => src.map(r, ctx)),
    total: Number(total) || 0,
    truncated: Number(total) > rows.length,
  };
}

/** 可清理的数据源（只有显式声明了 purge 的才算） */
function purgeablesOf(appId) {
  const a = APPS[appId];
  if (!a) return [];
  return a.sources.filter((s) => s.purge).map((s) => ({
    key: s.key,
    name: s.name,
    label: s.purge.label || s.name,
    columns: s.columns.map((c) => ({ key: c.key, label: c.label, width: c.width || 120, text: !!c.text })),
  }));
}

/**
 * 三步安全模型的第一步 / 第二步共用：**只算条数和抽样**，不动数据。
 * 第三步执行前会再调一次同样的函数比对条数 —— 期间新增的数据会让条数变化，
 * 变化了就拒绝执行（否则"我看着是 300 条点的确认，实际删了 305 条"）。
 */
function purgePreview(appId, key, rawList, keyword, limit = 20) {
  const src = sourceOf(appId, key);
  if (!src || !src.purge) return { error: `应用 ${appId} 的数据源 ${key} 不支持清理` };
  const list = windowFor(src, rawList);
  const w = buildWhere(src, list, keyword);
  const total = db.prepare(`SELECT COUNT(*) n ${src.from} ${w.sql}`).get(...w.params).n;
  const rows = db.prepare(`SELECT ${src.select} ${src.from} ${w.sql} ORDER BY ${src.order} LIMIT ?`)
    .all(...w.params, limit);
  const ctx = { orgId: orgIdOf(), shiftCache: new Map() };
  return {
    count: Number(total) || 0,
    sample: rows.map((r) => {
      const m = src.map(r, ctx);
      return src.columns.map((c) => ({ key: c.key, label: c.label, value: m[c.key] }));
    }),
    from: list.from,
    to: list.to,
    table: src.purge.table,
    label: src.purge.label || src.name,
  };
}

/**
 * 第三步：真的删。调用方必须先拿到 preview.count 并原样送回来，
 * 服务端重算一遍再比对 —— 这就是"手输条数确认"的服务端那一半。
 * 注意只删**主键命中**的那些行：按 WHERE 直接 DELETE 在条数变化时
 * 会连新数据一起删掉，而主键集合是我们刚刚看过的那一批。
 */
function purge(appId, key, rawList, keyword, expectCount) {
  const src = sourceOf(appId, key);
  if (!src || !src.purge) return { error: `应用 ${appId} 的数据源 ${key} 不支持清理` };
  const list = windowFor(src, rawList);
  const w = buildWhere(src, list, keyword);
  const now = db.prepare(`SELECT COUNT(*) n ${src.from} ${w.sql}`).get(...w.params).n;
  if (Number(expectCount) !== Number(now)) {
    return {
      error: `待删条数已变化（你确认时是 ${Number(expectCount)} 条，现在是 ${now} 条），已中止。请重新预览确认。`,
      code: 'count_changed',
      count: now,
    };
  }
  if (!now) return { error: '当前条件下没有可清理的数据', code: 'empty' };
  const ids = db.prepare(`SELECT ${src.purge.idCol} AS id ${src.from} ${w.sql}`).all(...w.params).map((x) => x.id);
  const info = db.prepare(`DELETE FROM ${src.purge.table} WHERE id IN (${ids.map(() => '?').join(',')})`).run(...ids);
  return { deleted: info.changes, table: src.purge.table, label: src.purge.label || src.name };
}

module.exports = {
  APPS,
  metricsOf, sourcesOf, sourceOf, detail, csv, rowsForBackup,
  purgeablesOf, purgePreview, purge, csvCell, dtText, windowFor,
};
