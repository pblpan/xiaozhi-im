const { DatabaseSync } = require('node:sqlite');
const path = require('path');
const fs = require('fs');
const config = require('./config');
const { hashPassword } = require('./auth');

fs.mkdirSync(path.dirname(config.DB_PATH), { recursive: true });

const db = new DatabaseSync(config.DB_PATH);
db.exec('PRAGMA journal_mode = WAL;');
db.exec(`
CREATE TABLE IF NOT EXISTS users (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  username TEXT UNIQUE NOT NULL,
  password_hash TEXT NOT NULL,
  nickname TEXT,
  avatar TEXT,
  role TEXT NOT NULL DEFAULT 'user',
  created_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS friendships (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id INTEGER NOT NULL,
  friend_id INTEGER NOT NULL,
  status TEXT NOT NULL DEFAULT 'pending',
  created_at INTEGER NOT NULL,
  UNIQUE(user_id, friend_id)
);
CREATE TABLE IF NOT EXISTS groups (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL,
  owner_id INTEGER NOT NULL,
  avatar TEXT,
  conversation_id INTEGER,
  created_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS group_members (
  group_id INTEGER NOT NULL,
  user_id INTEGER NOT NULL,
  role TEXT NOT NULL DEFAULT 'member',
  joined_at INTEGER NOT NULL,
  PRIMARY KEY(group_id, user_id)
);
CREATE TABLE IF NOT EXISTS conversations (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  type TEXT NOT NULL DEFAULT 'dm',
  created_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS conversation_members (
  conversation_id INTEGER NOT NULL,
  user_id INTEGER NOT NULL,
  PRIMARY KEY(conversation_id, user_id)
);
CREATE TABLE IF NOT EXISTS messages (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  conversation_id INTEGER NOT NULL,
  sender_id INTEGER NOT NULL,
  kind TEXT NOT NULL DEFAULT 'text',
  content TEXT,
  file_id INTEGER,
  topic TEXT,
  created_at INTEGER NOT NULL,
  edited INTEGER NOT NULL DEFAULT 0,
  deleted INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS files (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  owner_id INTEGER NOT NULL,
  name TEXT NOT NULL,
  mime TEXT,
  size INTEGER NOT NULL,
  path TEXT NOT NULL,
  created_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS favorites (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id INTEGER NOT NULL,
  message_id INTEGER NOT NULL,
  created_at INTEGER NOT NULL,
  UNIQUE(user_id, message_id)
);

/* ==================== 开放集成层 ==================== */

-- API 令牌：给外部系统（工厂V2 / OA / 脚本）的长期凭证，带 scope 限制
CREATE TABLE IF NOT EXISTS api_tokens (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL,
  token TEXT NOT NULL UNIQUE,
  scopes TEXT NOT NULL DEFAULT '',
  user_id INTEGER NOT NULL,        -- 以谁的身份行事（机器人或真人）
  created_by INTEGER NOT NULL,
  last_used_at INTEGER NOT NULL DEFAULT 0,
  expires_at INTEGER NOT NULL DEFAULT 0,   -- 0 = 永不过期
  revoked INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL
);

-- 入站 Webhook：外部系统 → IM（POST 一个地址即可推消息，无需登录）
CREATE TABLE IF NOT EXISTS incoming_hooks (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL,
  token TEXT NOT NULL UNIQUE,
  secret TEXT NOT NULL DEFAULT '',  -- 非空则要求 HMAC 签名
  bot_id INTEGER NOT NULL,          -- 以哪个机器人身份发言
  conversation_id INTEGER NOT NULL, -- 推到哪个会话
  created_by INTEGER NOT NULL,
  last_used_at INTEGER NOT NULL DEFAULT 0,
  revoked INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL
);

-- 出站 Webhook：IM → 外部系统（事件回调，带 HMAC 签名）
CREATE TABLE IF NOT EXISTS outgoing_hooks (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL,
  url TEXT NOT NULL,
  secret TEXT NOT NULL DEFAULT '',
  events TEXT NOT NULL DEFAULT '*',  -- 逗号分隔事件名；* = 全部
  conversation_id INTEGER,           -- NULL = 订阅所有会话
  active INTEGER NOT NULL DEFAULT 1,
  created_by INTEGER NOT NULL,
  created_at INTEGER NOT NULL
);

-- 投递日志：每次出站回调留痕，失败可重试、可手工重发
CREATE TABLE IF NOT EXISTS webhook_deliveries (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  hook_id INTEGER NOT NULL,
  event TEXT NOT NULL,
  payload TEXT NOT NULL,
  status INTEGER,                    -- HTTP 状态码，NULL = 尚未投递
  error TEXT,
  attempts INTEGER NOT NULL DEFAULT 0,
  ok INTEGER NOT NULL DEFAULT 0,
  next_retry_at INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL,
  delivered_at INTEGER
);
CREATE INDEX IF NOT EXISTS idx_deliveries_retry ON webhook_deliveries (ok, next_retry_at);
CREATE INDEX IF NOT EXISTS idx_deliveries_hook ON webhook_deliveries (hook_id, id DESC);

-- 公钥接入：外部系统提交公钥，IM 用公钥验签（替代/补充 HMAC 共享密钥）
CREATE TABLE IF NOT EXISTS public_keys (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  key_id TEXT UNIQUE NOT NULL,            -- 短 ID，对外用
  name TEXT NOT NULL,                     -- 用途名（人看）
  public_key TEXT NOT NULL,               -- PEM 格式公钥
  algorithm TEXT NOT NULL,                -- 'RSA-SHA256' / 'ECDSA-SHA256'
  fingerprint TEXT NOT NULL,              -- 公钥 SHA-256 指纹
  created_at INTEGER NOT NULL,
  last_used_at INTEGER NOT NULL DEFAULT 0,
  revoked INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_pubkeys_keyid ON public_keys (key_id);
`);

// ---- 幂等迁移（老库升级时不重建表）----
function ensureColumn(table, column, ddl) {
  const cols = db.prepare(`SELECT name FROM pragma_table_info(?)`).all(table);
  if (!cols.some((c) => c.name === column)) {
    db.exec(`ALTER TABLE ${table} ADD COLUMN ${ddl}`);
    console.log(`[小智IM] 迁移：${table}.${column} 已添加`);
  }
}
// 会话成员的已读位置（已读回执）：记录该成员读到的最大 message id
ensureColumn('conversation_members', 'last_read_id', 'last_read_id INTEGER NOT NULL DEFAULT 0');
// 消息 @提及：JSON 数组存被 @ 的用户 id，含 -1 表示 @所有人
ensureColumn('messages', 'mentions', 'mentions TEXT');
// 群公告（纯文本，展示在会话顶部）
ensureColumn('groups', 'announcement', 'announcement TEXT');
// 群成员禁言到期时间戳（0 = 未禁言）
ensureColumn('group_members', 'muted_until', 'muted_until INTEGER NOT NULL DEFAULT 0');
// 会话置顶消息（单条，NULL = 未置顶）
ensureColumn('conversations', 'pinned_message_id', 'pinned_message_id INTEGER');
// 会话免打扰
ensureColumn('conversation_members', 'muted', 'muted INTEGER NOT NULL DEFAULT 0');
// 机器人：特殊用户，不可登录、可被拉进群、可发消息（password_hash 存 '!' 使其永远验证失败）
ensureColumn('users', 'is_bot', 'is_bot INTEGER NOT NULL DEFAULT 0');
// 工号（好友"工作模式"下：工号=登录账号）；普通模式下为空
ensureColumn('users', 'employee_no', 'employee_no TEXT');
// 所属部门 id（工作模式组织机构用）；NULL = 不属于任何部门
ensureColumn('users', 'org_id', 'org_id INTEGER');

// ---- 实例级设置（键值）----
// 与 client_configs（版本化快照+灰度）的区别：公司名/好友模式是"服务器身份与策略"，
// 管理员改一次全体生效，不需要版本化与回滚 —— 用最简单的 KV 就够，
// 复杂机制只会让"改个名字"变得难懂。
db.exec(`
CREATE TABLE IF NOT EXISTS settings (
  key TEXT PRIMARY KEY,
  value TEXT,
  updated_at INTEGER NOT NULL,
  updated_by TEXT
);
`);
// ---- 组织机构（工作模式）----
// 一个服务器一个组织：工作模式下管理员建组织、按工号录入员工。
// 员工账号的 username=工号、初始密码=工号，org_id/employee_no 挂在 users 上
// （列迁移在下方 ensureColumn）。同事之间不需要好友申请 —— 录入时自动互为好友。
db.exec(`
CREATE TABLE IF NOT EXISTS orgs (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL,
  created_by INTEGER NOT NULL,
  created_at INTEGER NOT NULL
);
`);
// 工作模式组织机构：员工所属组织与工号
ensureColumn('users', 'employee_no', 'employee_no TEXT');
ensureColumn('users', 'org_id', 'org_id INTEGER');

// 组织机构扩展（套用工厂管理系统 V2 人事模型：部门 → 岗位 → 员工）：
// 部门支持父子层级（parent_id=0 为顶级），岗位可挂部门（也可全厂通用）。
// 员工不单独建表 —— 就是 org_id 命中的 users，部门/岗位以列挂在 users 上，
// 这样 IM 的账号体系（登录/好友）不用做两套身份。
db.exec(`
CREATE TABLE IF NOT EXISTS org_depts (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  org_id INTEGER NOT NULL,
  name TEXT NOT NULL,
  parent_id INTEGER NOT NULL DEFAULT 0,
  sort INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS org_positions (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  org_id INTEGER NOT NULL,
  name TEXT NOT NULL,
  dept_id INTEGER,
  sort INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_org_depts_org ON org_depts (org_id);
CREATE INDEX IF NOT EXISTS idx_org_positions_org ON org_positions (org_id);
`);
ensureColumn('users', 'dept_id', 'dept_id INTEGER');
ensureColumn('users', 'position_id', 'position_id INTEGER');

// 机器人的归属人（谁创建的，便于后台追责与清理）
ensureColumn('users', 'bot_owner_id', 'bot_owner_id INTEGER');

// ---- 个人资料扩展（个人信息面板用）----
// 生日存 'YYYY-MM-DD' 文本：不做时区换算、不存年龄（年龄会过期，生日不会）
ensureColumn('users', 'signature', 'signature TEXT');
ensureColumn('users', 'gender', 'gender TEXT');
ensureColumn('users', 'region', 'region TEXT');
ensureColumn('users', 'birthday', 'birthday TEXT');

// ---- 好友申请附言（认证消息）----
// 存在 friendships 上而不是单独建表：一条申请就是一行，天然一一对应
ensureColumn('friendships', 'message', 'message TEXT');

// ---- 好友备注（我给对方起的名字）----
// 同样是「我这一侧」的属性，所以存在 (user_id=我, friend_id=对方) 这一行上。
// 对方看不到、也不会被对方的改名影响；空/NULL 表示没设备注。
ensureColumn('friendships', 'remark', 'remark TEXT');

// ---- 好友申请附言模板 ----
// 每个用户维护自己的常用语；UNIQUE(user_id,content) 防重复添加同一条
db.exec(`
CREATE TABLE IF NOT EXISTS friend_templates (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id INTEGER NOT NULL,
  content TEXT NOT NULL,
  sort INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL,
  UNIQUE(user_id, content)
);
`);

// ---- 客户端配置中心（v0.8.0 第一期）----
// 版本化快照，只增不改：回滚 = 用旧内容发布新版本（历史永远可查）
db.exec(`
CREATE TABLE IF NOT EXISTS client_configs (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  version INTEGER NOT NULL UNIQUE,
  payload TEXT NOT NULL,
  note TEXT,
  created_by TEXT,
  created_at INTEGER NOT NULL
);
`);

// 哪台设备吃到了哪版配置（排障用：管理员能看到"还有 N 台在旧版本"）
db.exec(`
CREATE TABLE IF NOT EXISTS config_applied (
  user_id INTEGER,
  device_id TEXT,
  config_version INTEGER NOT NULL,
  applied_at INTEGER NOT NULL,
  PRIMARY KEY (user_id, device_id)
);
`);

// ---- 动态模块（v0.9.0 第二期）----
// 管理员在管理台拼页面 → 客户端不重装就出现入口。schema 的合法性由
// server/src/appmodules.js 在"发布时"严格校验，这里只负责存。
db.exec(`
CREATE TABLE IF NOT EXISTS app_modules (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  module_id TEXT NOT NULL UNIQUE,
  title TEXT NOT NULL,
  icon TEXT,
  schema TEXT NOT NULL,
  min_client_version TEXT,
  enabled INTEGER NOT NULL DEFAULT 1,
  sort INTEGER NOT NULL DEFAULT 0,
  visible_roles TEXT NOT NULL DEFAULT '[]',
  visible_user_ids TEXT NOT NULL DEFAULT '[]',
  updated_at INTEGER NOT NULL,
  updated_by TEXT
);
`);

// 动态表单提交记录。payload 只存"按 schema 白名单清洗过"的字段，
// 客户端多传的一律不落库（防止伪造字段污染数据）。
db.exec(`
CREATE TABLE IF NOT EXISTS module_submissions (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  module_id TEXT NOT NULL,
  user_id INTEGER,
  payload TEXT NOT NULL,
  created_at INTEGER NOT NULL
);
`);
db.exec(`CREATE INDEX IF NOT EXISTS idx_submissions_module ON module_submissions(module_id, created_at DESC);`);

// ---- 上游接口登记（动态模块第三期：让自建应用真的能取到数）----
//
// 背景：动态模块的 `onLoad` / `action` 只允许 `/api/hooks/` 前缀（防 SSRF），
// 但那一层一直没实现，于是 list/table/chart 三种组件只能渲染空壳。
//
// 这里存的就是"允许被转发的上游"。安全边界是**白名单**，而不是"只准公网 IP"
// —— 上游本来就在内网（工厂 V2、餐饮 POS、门店数据桥接器都在 192.168 段），
// 禁内网等于这个功能没用。真正防的是"客户端能打到任意 URL"这件事：
// 路径由登记的名字查出来，客户端永远只给得出一个名字。
//
// 凭证（auth_header）由服务端持有，**绝不下发给客户端**，也不会回显在列表里。
//
// allow_roles：哪些角色能通过这条上游取数。空数组 = 所有已登录用户。
// 为什么必须有这一列：模块的 visibleTo 只管"入口给谁看"，管不住"接口给谁调"。
// 门店日报这类经营数据如果只靠前端隐藏入口，任何员工拿自己的 token 直接打
// /api/hooks/up/report/... 就能拿到 —— 入口可见性和数据权限是两件事。
db.exec(`
CREATE TABLE IF NOT EXISTS upstreams (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL UNIQUE,          -- URL 里用的名字：/api/hooks/up/<name>/...
  label TEXT,                          -- 中文说明，管理台显示
  base_url TEXT NOT NULL,              -- 如 http://192.168.1.100:3700
  auth_header TEXT,                    -- 可选。整条 Authorization 值，服务端持有
  allow_roles TEXT NOT NULL DEFAULT '[]', -- 允许的角色白名单，空=所有登录用户
  timeout_ms INTEGER NOT NULL DEFAULT 10000,
  enabled INTEGER NOT NULL DEFAULT 1,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  updated_by TEXT
);
`);
// 兜底：万一某台机器的 upstreams 是在加 allow_roles 之前建的，
// CREATE TABLE IF NOT EXISTS 是空操作、列会缺 → 后面读出来 JSON.parse(null) 直接崩。
ensureColumn('upstreams', 'allow_roles', "allow_roles TEXT NOT NULL DEFAULT '[]'");

// ---- 远程协助（对标 UU 远程）----
// 两张表，职责严格分开：
//   remote_sessions        每次会话的**审计记录**（谁被谁控、多久、什么模式、怎么结束的）
//   remote_access_codes    无人值守访问码
//
// 【为什么访问码只存哈希】
// 访问码等价于"这台电脑的钥匙"。一旦明文入库，DB 被拷走就等于钥匙被拷走 ——
// 而它不像登录密码那样可以强制所有人改。所以库里只有 scrypt(code, salt)，
// 明文只在**生成的那一刻**返回给用户一次，之后谁也拿不回来（包括管理员）。
//
// ⚠️ 必须是慢哈希：9 位数字只有 10^9 种组合，用 SHA256 的话库被拷走就能
// 离线枚举反推。详见 src/remote.js 里 hashCode() 的说明。
db.exec(`
CREATE TABLE IF NOT EXISTS remote_sessions (
  id TEXT PRIMARY KEY,
  host_id INTEGER NOT NULL,          -- 被控端（屏幕被看、键鼠被操作的一方）
  controller_id INTEGER,             -- 控制端（无人值守兑换码之前可能还没有）
  mode TEXT NOT NULL,                -- attended 有人值守 / unattended 无人值守
  code_id INTEGER,                   -- 无人值守时兑换的是哪个码
  status TEXT NOT NULL,              -- requesting | connecting | active | ended
  end_reason TEXT,                   -- host_end | controller_end | timeout | rejected | canceled | failed
  created_at INTEGER NOT NULL,
  started_at INTEGER,                -- 真正连通（active）的时刻
  ended_at INTEGER,
  duration_sec INTEGER NOT NULL DEFAULT 0,
  host_device TEXT,                  -- 被控端上报的设备描述（Windows 10 / Android 14 ...）
  controller_device TEXT
);
`);
db.exec(`CREATE INDEX IF NOT EXISTS idx_remote_sessions_host ON remote_sessions(host_id, created_at DESC);`);
db.exec(`CREATE INDEX IF NOT EXISTS idx_remote_sessions_ctrl ON remote_sessions(controller_id, created_at DESC);`);

db.exec(`
CREATE TABLE IF NOT EXISTS remote_access_codes (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id INTEGER NOT NULL,          -- 归属：这个码能开**这个人**的电脑
  label TEXT NOT NULL DEFAULT '',    -- 备注（"门店前台那台"），方便自己认
  code_hash TEXT NOT NULL,           -- scrypt(code, salt)；**绝不存明文**
  salt TEXT NOT NULL,                -- 每行独立随机盐，同一明文在不同行也不同哈希
  single_use INTEGER NOT NULL DEFAULT 0,  -- 一次性：用一次自动作废
  expires_at INTEGER,                -- 过期时间，NULL=长期有效
  revoked INTEGER NOT NULL DEFAULT 0,
  use_count INTEGER NOT NULL DEFAULT 0,
  last_used_at INTEGER,
  created_at INTEGER NOT NULL
);
`);
db.exec(`CREATE INDEX IF NOT EXISTS idx_remote_codes_user ON remote_access_codes(user_id, revoked);`);

// 兑换失败记录 —— 用于**限流**。没有它就是无限次撞码：
// 9 位数字虽有一亿种组合，但配上不限次尝试就是一个可被暴力枚举的门。
db.exec(`
CREATE TABLE IF NOT EXISTS remote_code_attempts (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id INTEGER NOT NULL,
  ts INTEGER NOT NULL
);
`);
db.exec(`CREATE INDEX IF NOT EXISTS idx_remote_attempts_user ON remote_code_attempts(user_id, ts DESC);`);

/* ==================== 考勤（工作模式的标配能力，对标钉钉考勤）====================
 *
 * 六张表，职责互不重叠：
 *   att_shifts        班次：几点上下班、休息时段、弹性与宽限（一个组织可有多套）
 *   att_groups        考勤组：一批人用哪套班次、要不要定位、允不允许外勤
 *   att_group_members 考勤组的「点名」成员
 *   att_group_depts   考勤组按部门纳入（部门内所有人自动算成员，新员工自动进组）
 *   att_records       打卡流水
 *   att_requests      请假/补卡/外出/加班申请单
 *
 * 【一天打几次卡，由班次有没有休息时段决定】
 *   填了休息开始/结束（如 12:00 / 13:00）→ 一天 4 次：
 *       上班(in,1) 下班(out,1) 上班(in,2) 下班(out,2)   ← 卡名一样，靠 slot 区分
 *       在岗时长 = (12:00-08:00) + (17:00-13:00) = 8 小时
 *   没填 → 一天 2 次（上班/下班），老行为不变。
 *   两种模式共用同一套判定代码，只差"期望打卡计划"这张表（见 attendance.js
 *   的 punchPlan）—— 判定逻辑写两套的话，改了这边忘那边，迟早对不上。
 *
 * 【为什么打卡流水允许一人一天多条】
 * 钉钉的语义是「更新打卡」而不是「一天只能打一次」：员工手滑打早了会再打一次。
 * 库里保留全部流水（审计需要，管理台能看到"他 8:31 打过又 9:02 补打"），
 * 统计只在服务端按 (type, slot) 各取一条 —— 口径集中在一处，客户端不参与计算。
 *
 * 【为什么考勤组要存部门而不是存"展开后的成员"】
 * 存成员的话，每次录入新员工都得回头把十几个考勤组重新展开一遍，漏一个就是
 * "新来的不用打卡"。存部门则新员工一入职就自动在组里，人事少做一件事。
 */
db.exec(`
CREATE TABLE IF NOT EXISTS att_shifts (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  org_id INTEGER NOT NULL,
  name TEXT NOT NULL,
  work_start TEXT NOT NULL,              -- 'HH:MM'
  work_end TEXT NOT NULL,                -- 'HH:MM'；work_end<=work_start 表示跨天班（cross_day=1）
  rest_start TEXT,                       -- 'HH:MM' 休息开始(第 1 段结束)。与 rest_end 同时有值 = 一天 4 次卡
  rest_end TEXT,                         -- 'HH:MM' 休息结束(第 2 段开始)
  rest_minutes INTEGER NOT NULL DEFAULT 0,   -- 不填休息时段时的休息时长（仅展示/扣工时）
  flex_minutes INTEGER NOT NULL DEFAULT 0,   -- 弹性上班分钟数：0=不弹性（只作用于当天第一次上班）
  late_grace INTEGER NOT NULL DEFAULT 0,     -- 迟到宽限（分钟）：宽限内不算迟到
  early_grace INTEGER NOT NULL DEFAULT 0,    -- 可提前打卡分钟数：下班前 N 分钟打不算早退
  cross_day INTEGER NOT NULL DEFAULT 0,      -- 夜班：下班时间在次日
  enabled INTEGER NOT NULL DEFAULT 1,
  sort INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS att_groups (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  org_id INTEGER NOT NULL,
  name TEXT NOT NULL,
  shift_id INTEGER,                          -- NULL = 用组织默认班次
  -- 定位要求：off 不校验 | optional 有就记、没有算外勤 | required 必须带定位
  -- 刻意**不做地理围栏**（公司坐标+半径）：桌面端拿不到定位、内网场景意义有限，
  -- 而围栏要配坐标与地图，是"配了也不准"的功能。只记录地点，由管理者判断。
  location_mode TEXT NOT NULL DEFAULT 'off',
  created_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS att_group_members (
  group_id INTEGER NOT NULL,
  user_id INTEGER NOT NULL,
  PRIMARY KEY(group_id, user_id)
);
CREATE TABLE IF NOT EXISTS att_group_depts (
  group_id INTEGER NOT NULL,
  dept_id INTEGER NOT NULL,
  PRIMARY KEY(group_id, dept_id)
);
CREATE TABLE IF NOT EXISTS att_records (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  org_id INTEGER NOT NULL,
  user_id INTEGER NOT NULL,
  day TEXT NOT NULL,                     -- 'YYYY-MM-DD'，按**服务器指定时区日**切分，不用容器本地时区
  type TEXT NOT NULL,                    -- 'in' 上班卡 | 'out' 下班卡
  slot INTEGER NOT NULL DEFAULT 1,       -- 第几段：1=上午(或两段班的唯一那段) 2=下午
  at INTEGER NOT NULL,                   -- 打卡时刻（时间戳）
  source TEXT NOT NULL DEFAULT 'app',    -- app 客户端 | admin 管理员代打 | makeup 补卡审批通过
  lat REAL, lng REAL, address TEXT,
  device TEXT,
  note TEXT,
  created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_att_records_user_day ON att_records (user_id, day);
CREATE INDEX IF NOT EXISTS idx_att_records_org_day ON att_records (org_id, day);
CREATE TABLE IF NOT EXISTS att_requests (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  org_id INTEGER NOT NULL,
  user_id INTEGER NOT NULL,
  kind TEXT NOT NULL,                    -- leave 请假 | makeup 补卡 | outing 外出 | overtime 加班
  status TEXT NOT NULL DEFAULT 'pending',-- pending | approved | rejected | canceled
  reason TEXT,
  start_day TEXT, end_day TEXT,          -- 请假：起止日期（含）
  half INTEGER NOT NULL DEFAULT 0,       -- 请假 0=全天 1=上午半天 2=下午半天
  leave_type TEXT,                       -- personal 事假 | sick 病假 | annual 年假 | comp 调休
  day TEXT, clock_type TEXT, at INTEGER, -- 补卡：哪天的哪张卡、补在什么时刻
  slot INTEGER NOT NULL DEFAULT 1,       -- 补卡：补的是第几段（4 次卡时 1=上午 2=下午）
  start_at INTEGER, end_at INTEGER,      -- 外出/加班：起止时刻
  reviewed_by INTEGER, reviewed_at INTEGER, review_note TEXT,
  created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_att_requests_user ON att_requests (user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_att_requests_org ON att_requests (org_id, status, created_at DESC);
`);
// 老库升级：早期版本没有这几列，补上（否则新功能在已装环境里永远存不住值）
ensureColumn('att_shifts', 'early_grace', 'early_grace INTEGER NOT NULL DEFAULT 0');
ensureColumn('att_shifts', 'rest_start', 'rest_start TEXT');
ensureColumn('att_shifts', 'rest_end', 'rest_end TEXT');
ensureColumn('att_records', 'slot', 'slot INTEGER NOT NULL DEFAULT 1');
ensureColumn('att_requests', 'slot', 'slot INTEGER NOT NULL DEFAULT 1');

// ---- 管理台列表页的查询索引（v0.14.0 新增）----
// messages / files 原先**一个索引都没有**（生产库实测 indexes 为空）。
// LIKE '%x%' 前导通配符任何索引都用不上，所以策略是：先靠时间/发送者/会话/类型
// 把行数砍下来，再对剩下的少量行做 LIKE —— 配合列表默认 30 天窗才成立。
// CREATE INDEX IF NOT EXISTS 幂等，不需要迁移标记。
// 不写 DESC：SQLite 可反向扫描索引，单列索引上 DESC 与 ASC 完全等价（写了只是噪音）。
db.exec(`
CREATE INDEX IF NOT EXISTS idx_messages_created ON messages (created_at);
CREATE INDEX IF NOT EXISTS idx_messages_sender  ON messages (sender_id, created_at);
CREATE INDEX IF NOT EXISTS idx_messages_conv    ON messages (conversation_id, created_at);
CREATE INDEX IF NOT EXISTS idx_messages_kind    ON messages (kind, created_at);
CREATE INDEX IF NOT EXISTS idx_files_created    ON files (created_at);
CREATE INDEX IF NOT EXISTS idx_files_owner      ON files (owner_id, created_at);
CREATE INDEX IF NOT EXISTS idx_files_size       ON files (size);
CREATE INDEX IF NOT EXISTS idx_favorites_message ON favorites (message_id);
`);

// ---- iOS 推送（APNs）相关表 ----
// 为什么不把设备令牌塞进 settings 的 JSON：令牌要按"用户 × 设备 × 环境
// (sandbox/production)"多维组织，而且**单条失效**必须能单独下线
// （APNs 回 410 只针对那一个令牌）。塞进一个 blob 迟早写坏，且没法查询。
db.exec(`
CREATE TABLE IF NOT EXISTS push_devices (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id INTEGER NOT NULL,
  platform TEXT NOT NULL DEFAULT 'ios',    -- ios | android(预留) | ...
  token TEXT NOT NULL,                     -- APNs 设备令牌：64 位十六进制
  env TEXT NOT NULL DEFAULT 'production',  -- production | sandbox，两个环境的令牌不通用
  topic TEXT,                              -- 推送主题 = App 的 Bundle ID
  device_name TEXT,
  fail_count INTEGER NOT NULL DEFAULT 0,
  active INTEGER NOT NULL DEFAULT 1,       -- 0=令牌已失效（410/BadDeviceToken），不再投递
  last_ok_at INTEGER,
  last_error TEXT,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  UNIQUE(token)
);
CREATE INDEX IF NOT EXISTS idx_push_devices_user ON push_devices (user_id, active);

CREATE TABLE IF NOT EXISTS push_log (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id INTEGER NOT NULL,
  device_id INTEGER,
  -- 只留尾 8 位：日志要能追到"是哪台设备"，但不该把完整令牌堆在库里
  token_tail TEXT,
  ok INTEGER NOT NULL DEFAULT 0,
  status INTEGER,                          -- APNs 的 :status（200/400/410/...）
  reason TEXT,                             -- APNs 的 reason（BadDeviceToken / Unregistered ...）
  title TEXT,
  body TEXT,
  apns_id TEXT,
  created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_push_log_created ON push_log (created_at);
CREATE INDEX IF NOT EXISTS idx_push_log_user ON push_log (user_id, created_at DESC);
`);

// ---- 盘点（inventory 模块）----
//
// 🔴 命名说明：接口路径按方案文档用 `/api/stocktake/...`，但**这里的
//    「stocktake」指的是盘点**，不是客户端那个 id 也叫 stocktake 的「扫码枪」。
//    两者是不同模块（扫码枪=快速扫码成账，盘点=点位/三遍制）。
//    别看到 /api/stocktake 就以为在改扫码枪。
//
// 🔴 为什么 inv_scans 要存 account_qty（账面数）：
//    服务端**没有商品档案**（商档在客户端本地，从泰格上游拉的）。
//    所以差异集没法在服务端自己算出来 —— 由客户端上传时把当时的账面数
//    一并带上来。这样服务端的单据详情能独立给出差异，不必再连泰格。
//    account_qty 为 NULL 是一个**有效且重要**的状态：账上没有这个商品
//    （新品/错码），这本身就是最严重的一类差异，绝不能被当成"没差异"。
db.exec(`
CREATE TABLE IF NOT EXISTS inv_zones (
  zone_code TEXT PRIMARY KEY,
  zone_name TEXT,
  store_code TEXT,
  locked INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS inv_locations (
  loc_code TEXT PRIMARY KEY,
  loc_name TEXT,
  zone_code TEXT NOT NULL,
  sort_no INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_inv_locations_zone ON inv_locations (zone_code, sort_no);

CREATE TABLE IF NOT EXISTS inv_barcode_locations (
  barcode TEXT NOT NULL,
  loc_code TEXT NOT NULL,
  bound_at INTEGER NOT NULL,
  PRIMARY KEY (barcode, loc_code)
);
CREATE INDEX IF NOT EXISTS idx_inv_bl_loc ON inv_barcode_locations (loc_code);

CREATE TABLE IF NOT EXISTS inv_sheets (
  sheet_no TEXT PRIMARY KEY,
  zone_code TEXT NOT NULL,
  phase INTEGER NOT NULL DEFAULT 1,      -- 1初盘 2复盘 3抽盘
  status INTEGER NOT NULL DEFAULT 0,     -- 0进行中 1已提交 2已上传
  operator TEXT,
  operator_id INTEGER,
  device_id TEXT,                        -- 哪台设备传上来的（排查"两台机器各传一半"）
  started_at INTEGER,
  submitted_at INTEGER,
  uploaded_at INTEGER,
  created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_inv_sheets_zone ON inv_sheets (zone_code, phase, started_at DESC);

CREATE TABLE IF NOT EXISTS inv_scans (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  sheet_no TEXT NOT NULL,
  zone_code TEXT NOT NULL,
  phase INTEGER NOT NULL DEFAULT 1,
  barcode TEXT NOT NULL,
  qty REAL NOT NULL DEFAULT 0,
  account_qty REAL,                      -- 上传时的账面数；NULL=账上没有这个商品
  loc_code TEXT,
  scanned_at INTEGER,
  uploaded_at INTEGER NOT NULL,
  -- 幂等键：同一张单、同一阶段、同一条码只占一行。
  -- 客户端断网重传时靠它 UPSERT，不会变成两行（多算一个品种）。
  UNIQUE (sheet_no, phase, barcode)
);
CREATE INDEX IF NOT EXISTS idx_inv_scans_sheet ON inv_scans (sheet_no);
CREATE INDEX IF NOT EXISTS idx_inv_scans_zone_phase ON inv_scans (zone_code, phase);
`);

// ---- 抽盘授权（M2/P2）----
//
// 🔴 为什么要落表，而不是给 users 加一个 can_stocktake 布尔：
//    抽盘权限是**按盘点位给的**，而且是**临时的**。同一个主管今天抽 A 区、
//    明天 B 区；离职/调岗要能立刻收回且**留痕**。一个布尔字段表达不了
//    "谁、在哪个点位、谁给的、什么时候给的、什么时候收回的"这五件事，
//    而这五件事恰恰是事后追责时唯一能拿出来的东西。
//
// 🔴 撤销用 revoked_at 置时间戳，**不是 DELETE 掉那一行**：
//    删了就没法回答"当时到底授没授权给他"——被拒的人一定会来问这句。
//    判"有没有权"统一走 `revoked_at IS NULL`，别在别处另写一套。
//
// 🔴 管理员**天然持权**（见 inventory.js 的 hasGrant）：
//    每个盘点位都先给管理员授一次权，第一天就没人能开工。
db.exec(`
CREATE TABLE IF NOT EXISTS inv_grants (
  zone_code TEXT NOT NULL,
  user_id INTEGER NOT NULL,
  granted_by INTEGER,
  granted_at INTEGER NOT NULL,
  revoked_at INTEGER,                    -- NULL = 生效中；非空 = 已解除（留痕，不删行）
  PRIMARY KEY (zone_code, user_id)
);
CREATE INDEX IF NOT EXISTS idx_inv_grants_user ON inv_grants (user_id, zone_code);
CREATE INDEX IF NOT EXISTS idx_inv_grants_live ON inv_grants (zone_code, revoked_at);
`);

// ---- 通用审批中心（M2/P2）----
//
// 🔴 为什么不做成"盘点专用审批表"：
//    审批这件事全系统只有一套语义（待审 / 通过 / 驳回 + 理由），
//    做成通用的，后面请假、调价、报废都能直接挂上来，
//    不必每加一类业务就复制一遍"待审批/已审批/驳回"三态和它的边界。
//    `kind` + `ref` 两个字段把"这是什么业务、对应哪条记录"表达清楚就够了。
//
// 🔴 `reject_reason` 在**驳回时必填**（不是可选）：
//    驳回而不说理由，提交人只能反复猜、反复提，审批就退化成了刁难。
//    PG 的文案"请输入驳回理由"说明它也是硬拦的。
//
// 🔴 `payload` 存 JSON 快照，**不是外键**：
//    审批要看的是"当时提交的是什么"。关联记录事后被改（或删），
//    审批意见就成了对不上的空话；快照让这份意见永远有据可依。
db.exec(`
CREATE TABLE IF NOT EXISTS approvals (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  kind TEXT NOT NULL,                     -- 'stocktake' / 以后别的业务
  title TEXT,
  ref TEXT,                               -- 关联对象（盘点就是 sheet_no）
  payload TEXT,                           -- JSON 快照
  status TEXT NOT NULL DEFAULT 'pending', -- pending / approved / rejected
  submitter_id INTEGER NOT NULL,
  submitter_name TEXT,
  decided_by INTEGER,
  decided_by_name TEXT,
  decided_at INTEGER,
  reject_reason TEXT,
  created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_approvals_status ON approvals (status, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_approvals_submitter ON approvals (submitter_id, status, created_at DESC);
`);

// 盘点单的审批状态：0 未提审 / 1 待审批 / 2 已通过 / 3 已驳回。
// 🔴 和 `status`（0进行中/1已提交/2已上传）是**两回事**，别合并：
//    status 说的是"这张单的技术状态"（还能不能写），
//    审批说的是"主管认不认这批数"。合并之后，"已上传但没批"就没法表达，
//    而现场最常见的就是这种单 —— 传上去了、主管还没看。
ensureColumn('inv_sheets', 'approval_status', 'approval_status INTEGER NOT NULL DEFAULT 0');
// 驳回理由（批准时为空）。驳回必填，见 routes/approval.js。
ensureColumn('inv_sheets', 'reject_reason', 'reject_reason TEXT');

// 单据类型：'inventory' 盘点 / 'deduct' 库房减货。
//
// 🔴 为什么减货要和盘点**共用这一张表**（而不是另建 deduct_sheets）：
//    单据状态机（进行中/已提交/已上传）、幂等键、导出口径这三件事两边完全一样，
//    各建一套的结果是"改了盘点忘了减货"，而这两边的单号前缀（INV- / JH-）不同，
//    混在一起根本看不出来哪张是减货 —— 靠一列显式区分，谁都不会看错。
//
// 🔴 加了这列之后，**盘点侧所有列表类查询必须带 sheet_type 过滤**，
//    否则减货单会混进"盘点单列表"（现场表现为：点开一张单，里面是减货的货，
//    而减货不看点位不看阶段，点位的阶段小结会算出莫名其妙的数）。
//    按 sheet_no 精确查的那些不用改（单号本身不冲突）。
ensureColumn('inv_sheets', 'sheet_type', "sheet_type TEXT NOT NULL DEFAULT 'inventory'");
// 减货单不挂盘点位，但 inv_sheets.zone_code 是 NOT NULL（盘点位的语义就在这列上）。
// 用一个**不可能成为合法点位码**的占位值：code() 会拒掉含空白/斜杠的串，
// 而 '-' 既过得了校验又不会是任何门店起的点位名，正好当"无点位"。
// 见 routes/deduct.js 的 DEDUCT_ZONE。
ensureColumn('inv_scans', 'sheet_type', "sheet_type TEXT NOT NULL DEFAULT 'inventory'");

// ---- 商品档案（商档）----
//
// 🔴 为什么要把商档搬到服务端：
//    盘点算差异必须有账面数（account_qty），原来唯一通路是泰格上游钩子
//    `/api/hooks/up/tiger/master/items`，而那个桥接跑在一台会关机、IP 会漂的
//    机器上（2026-09-19 实测 fetch failed）。链路一断，初盘每一行都是
//    "账上无此商品"，差异集 = 全部商品，三遍制等于白盘。
//    商档是**门店自己的底表**，放在自家服务端最合适：一次导入，全员拉同一份，
//    不再依赖任何外部机器。
//
// 🔴 为什么要有 batch 列：
//    12 万行不可能一次请求传完（要分块），但"分块写到一半"绝不能让店里
//    看到一份残缺的商档。做法是：分块写入都带同一个 batch 号，
//    全部传完再调 commit —— commit 时才删掉非本次 batch 的旧数据。
//    传一半就放弃的话，旧商档完好无损。
db.exec(`
CREATE TABLE IF NOT EXISTS product_master (
  barcode TEXT PRIMARY KEY,
  name TEXT,
  spec TEXT,
  unit TEXT,
  unit_price REAL,              -- 售价。名字沿用早期列名，语义见下面那条注释
  purchase_price REAL,          -- 进价（成本价）
  account_qty REAL,             -- 账面数（库存）；NULL = 账上没有，盘点时算差异
  batch TEXT,                   -- 本次导入批次号，commit 时用它区分新旧
  updated_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_product_master_updated ON product_master (updated_at);
`);

// ── 商档「进价」列：老库是加表之后才有这列的，启动时补上 ────────────────
// 🔴 为什么不能只写进上面的 CREATE TABLE：已经跑着的库（比如线上 2026-09-20
//    导的那 12.6 万行）建表时还没有这列，而 `CREATE TABLE IF NOT EXISTS`
//    对已存在的表**什么都不做** —— 于是新字段永远加不上，导入时服务端静默
//    丢掉进价，管理台也拿不到。这类毛病最阴的地方是**不报错**：一切照常，
//    只是那一列永远是空。所以每次启动都要兜住。
//
// 🔴 列名沿用 `unit_price` 表示**售价**：早期就叫这个名，线上已有数据按它写入；
//    改名要同时动数据库、管理台、客户端本地表三处，风险大于收益。
//    语义在这条注释里钉死：`unit_price` = 售价，`purchase_price` = 进价。
try {
  const pmCols = db.prepare('PRAGMA table_info(product_master)').all().map((c) => c.name);
  if (!pmCols.includes('purchase_price')) {
    db.exec('ALTER TABLE product_master ADD COLUMN purchase_price REAL');
  }
} catch (e) {
  console.warn('[小智IM] product_master 补 purchase_price 列失败：%s', e.message);
}

// ── 开放 API 的「签名通道」（对接方用 app_id + app_secret 调，见 apisign.js）──
//
// 为什么还要在长期令牌之外再开一条：Bearer token 一旦泄露 = 可无限重放，
// 而且**看不出是谁在调**。签名通道要求每次请求现算 HMAC，带时间戳和一次性
// nonce，泄露的只是一串没法倒推 secret 的签名。
db.exec(`
CREATE TABLE IF NOT EXISTS api_clients (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  app_id TEXT NOT NULL UNIQUE,
  app_secret_enc TEXT NOT NULL,   -- AES-256-GCM 密文（明文只在"发密钥"那一刻回一次）
  -- 轮换宽限期：旧密钥先挪到这两列，宽限期内两个都认，过期即失效。
  -- 没有宽限期的话"点一下轮换" = 当场把对接方踢下线，于事没人敢轮换。
  app_secret_prev_enc TEXT,
  prev_valid_until INTEGER NOT NULL DEFAULT 0,
  name TEXT NOT NULL,
  scopes TEXT NOT NULL DEFAULT '',
  user_id INTEGER NOT NULL,       -- 以谁的身份行事（机器人或真人）
  enabled INTEGER NOT NULL DEFAULT 1,
  created_by INTEGER NOT NULL,
  last_used_at INTEGER NOT NULL DEFAULT 0,
  rotated_at INTEGER,
  created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_api_clients_enabled ON api_clients (enabled);

-- 一次性随机串。防重放：同一个 nonce 在时间窗内只能用一次。
-- 🔴 这张表**必须定期清**（见 apisign.purgeExpiredNonces），否则它会一路涨下去。
CREATE TABLE IF NOT EXISTS api_nonce (
  nonce TEXT PRIMARY KEY,
  app_id TEXT NOT NULL,
  at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_api_nonce_at ON api_nonce (at);

-- ══════════════════════════════════════════════════════════════
-- 培训中心（training）—— 课程 / 章节 / 课时 / 进度 / 考试
-- ══════════════════════════════════════════════════════════════
-- 几个一眼看不出、改之前必须知道的决定：
--
-- ① **考试机会在「开始」时就消耗，不是在「提交」时。**
--    对齐真实培训的做法（PG：退出考试后将浪费本次考试机会）。
--    如果只在提交时才算用掉，学员可以"点进去看一眼题目 → 退出 → 再点进去"，
--    题目就漏光了，而且没有任何报错。所以 start 即落 sheet（submitted_at=0）。
--
-- ② **进度表主键是 (user_id, lesson_id)**，不是自增 id。
--    弱网下客户端会重传，用 UPSERT 幂等；写成多行的话"看了多少"会来回跳。
--
-- ③ **课时文件引用 files 表的 id，不自己存路径。**
--    路径是存储层的概念（files.path 已经是随机化文件名，防覆盖与路径穿越），
--    再存一份就会有两套真相。播放接口按 file_id 查回路径。
--
-- ④ **题目选项的正确答案存在 option 上**，不在 question 上。
--    多选题有多个正确项；把答案放 question 上就得再搞一个"多选答案数组"，
--    两份数据会对不上。

CREATE TABLE IF NOT EXISTS tr_course (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  title TEXT NOT NULL,
  intro TEXT NOT NULL DEFAULT '',
  category TEXT NOT NULL DEFAULT '',   -- 店长管理 / 生鲜陈列 / 加工管理 / 防损 / 前台收银 / 杂百运营…
  cover_file_id INTEGER,               -- 封面图（可空）
  required INTEGER NOT NULL DEFAULT 0, -- 必修：必修课不学完，年度培训进度就不满
  published INTEGER NOT NULL DEFAULT 0,-- 未发布的课程学员侧看不见（草稿态）
  created_by INTEGER,
  created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_tr_course_pub ON tr_course (published);

CREATE TABLE IF NOT EXISTS tr_chapter (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  course_id INTEGER NOT NULL,
  title TEXT NOT NULL,
  sort INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_tr_chapter_course ON tr_chapter (course_id);

CREATE TABLE IF NOT EXISTS tr_lesson (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  chapter_id INTEGER NOT NULL,
  title TEXT NOT NULL,
  kind TEXT NOT NULL DEFAULT 'video',  -- video / doc（doc 只记"看过"，不算时长）
  file_id INTEGER,                     -- 关联 files.id；doc 也必须挂文件，否则学员点开是空的
  link_url TEXT NOT NULL DEFAULT '',   -- 🔴 外链课件（可空）：共享盘 / 视频号 / 腾讯文档
                                       --    这类"文件进不了系统"的课件走这条。
  duration_sec INTEGER NOT NULL DEFAULT 0,
  sort INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_tr_lesson_chapter ON tr_lesson (chapter_id);

-- 「加入课程」。有这张表才有"公共课程 / 我的课程"的区分
-- （不加的话，课程列表只能全量下发，学员没法把课收进自己的学习清单）。
CREATE TABLE IF NOT EXISTS tr_enroll (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id INTEGER NOT NULL,
  course_id INTEGER NOT NULL,
  joined_at INTEGER NOT NULL,
  UNIQUE(user_id, course_id)
);
CREATE INDEX IF NOT EXISTS idx_tr_enroll_user ON tr_enroll (user_id);

CREATE TABLE IF NOT EXISTS tr_progress (
  user_id INTEGER NOT NULL,
  lesson_id INTEGER NOT NULL,
  position_sec INTEGER NOT NULL DEFAULT 0,  -- 看到第几秒（下次接着播）
  done INTEGER NOT NULL DEFAULT 0,
  updated_at INTEGER NOT NULL,
  PRIMARY KEY (user_id, lesson_id)
);
CREATE INDEX IF NOT EXISTS idx_tr_progress_user ON tr_progress (user_id);

-- 章节考试：挂在**章节**上，不是课程上 —— 学完一章考一章，
-- 才有"当前课程进度未达标，暂不能参加考试"这道门禁的落脚点。
CREATE TABLE IF NOT EXISTS tr_exam (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  chapter_id INTEGER NOT NULL,
  title TEXT NOT NULL,
  pass_score INTEGER NOT NULL DEFAULT 60,
  attempt_limit INTEGER NOT NULL DEFAULT 1, -- 1 = 一次机会（默认，也是真实培训的做法）
  min_progress INTEGER NOT NULL DEFAULT 100,-- 门禁：本章进度低于此百分比不放行
  question_count INTEGER NOT NULL DEFAULT 0,-- 抽题数量（0 = 全部）
  created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_tr_exam_chapter ON tr_exam (chapter_id);

CREATE TABLE IF NOT EXISTS tr_question (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  exam_id INTEGER NOT NULL,
  type TEXT NOT NULL DEFAULT 'single', -- single / multi / judge
  stem TEXT NOT NULL,
  score INTEGER NOT NULL DEFAULT 10,
  sort INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_tr_question_exam ON tr_question (exam_id);

CREATE TABLE IF NOT EXISTS tr_option (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  question_id INTEGER NOT NULL,
  label TEXT NOT NULL,                -- A / B / C…
  content TEXT NOT NULL,
  correct INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_tr_option_question ON tr_option (question_id);

-- 答卷。started 但未 submitted 的 = **已消耗但没交**的机会（见上面 ①）。
CREATE TABLE IF NOT EXISTS tr_sheet (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  user_id INTEGER NOT NULL,
  exam_id INTEGER NOT NULL,
  attempt_no INTEGER NOT NULL DEFAULT 1,
  score INTEGER NOT NULL DEFAULT 0,
  pass INTEGER NOT NULL DEFAULT 0,
  started_at INTEGER NOT NULL,
  submitted_at INTEGER NOT NULL DEFAULT 0  -- 0 = 还没交
);
-- 🔴 这个 UNIQUE 是"一次机会"的物理保证：靠应用层判断总会有并发缝隙，
--    两次同时点开始就变成两张卷子。让数据库来拦，重复直接报错。
CREATE UNIQUE INDEX IF NOT EXISTS idx_tr_sheet_once ON tr_sheet (user_id, exam_id, attempt_no);

CREATE TABLE IF NOT EXISTS tr_answer (
  sheet_id INTEGER NOT NULL,
  question_id INTEGER NOT NULL,
  chosen TEXT NOT NULL DEFAULT '',   -- 存选项 label 串（多选如 "AB"）
  correct INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (sheet_id, question_id)
);
`);

// ---- 培训：真看了多少秒 ----
//
// `position_sec` 是"看到第几秒"，只用于续播 —— 拖一下进度条就能到 95%，
// 拿它当完成度等于没有门禁。所以另开一列记**客户端真数出来的观看秒数**：
// 暂停/缓冲不涨，拖过去的片段不涨，倍速照涨（见 client/lib/core/lesson_progress.dart）。
//
// 只有**内嵌播放器**（手机端视频）填得上这一列；桌面端/文档走系统播放器，
// 拿不到秒数，就一直是 0 —— 看到 0 要知道是"这条路本来就数不出来"，
// 不是"这人一秒没看"。
//
// ⚠️ 位置别往上挪：db.js 是**顺序执行**的，`ensureColumn` 在 require 时就跑，
//    而 `tr_progress` 的 CREATE TABLE 在文件后半段。写在前面会直接
//    `no such table: tr_progress`，服务起不来（2026-09-25 踩过一次）。
ensureColumn('tr_progress', 'watched_sec', 'watched_sec INTEGER NOT NULL DEFAULT 0');

// 老库的 tr_lesson 没有外链列（0.21.5 之前课件只能挂系统文件），在线的库补一列。
// ⚠️ 和上面同一条规则：**只能往下追加**，别往上挪。
ensureColumn('tr_lesson', 'link_url', "link_url TEXT NOT NULL DEFAULT ''");

// 首次启动播种管理员账号，保证 /admin 开箱可用
const existing = db.prepare('SELECT id FROM users WHERE username = ?').get(config.ADMIN_USERNAME);
if (!existing) {
  db.prepare('INSERT INTO users (username, password_hash, nickname, role, created_at) VALUES (?,?,?,?,?)')
    .run(config.ADMIN_USERNAME, hashPassword(config.ADMIN_PASSWORD), '管理员', 'admin', Date.now());
  console.log(`[小智IM] 已创建管理员账号: ${config.ADMIN_USERNAME} / ${config.ADMIN_PASSWORD}`);
}

module.exports = db;
