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
 *   att_shifts        班次：几点上下班、午休窗口、弹性与宽限（一个组织可有多套）
 *   att_groups        考勤组：一批人用哪套班次、要不要定位、允不允许外勤
 *   att_group_members 考勤组的「点名」成员
 *   att_group_depts   考勤组按部门纳入（部门内所有人自动算成员，新员工自动进组）
 *   att_records       打卡流水
 *   att_requests      请假/补卡/外出/加班申请单
 *
 * 【一天打几次卡，由班次有没有午休窗口决定】
 *   填了午休开始/结束（如 12:00 / 13:00）→ 一天 4 次：
 *       上班(in,1) 午休下班(out,1) 午休上班(in,2) 下班(out,2)
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
  rest_start TEXT,                       -- 'HH:MM' 午休开始(上午下班)。与 rest_end 同时有值 = 一天 4 次卡
  rest_end TEXT,                         -- 'HH:MM' 午休结束(下午上班)
  rest_minutes INTEGER NOT NULL DEFAULT 0,   -- 不填午休窗口时的休息时长（仅展示/扣工时）
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

// 首次启动播种管理员账号，保证 /admin 开箱可用
const existing = db.prepare('SELECT id FROM users WHERE username = ?').get(config.ADMIN_USERNAME);
if (!existing) {
  db.prepare('INSERT INTO users (username, password_hash, nickname, role, created_at) VALUES (?,?,?,?,?)')
    .run(config.ADMIN_USERNAME, hashPassword(config.ADMIN_PASSWORD), '管理员', 'admin', Date.now());
  console.log(`[小智IM] 已创建管理员账号: ${config.ADMIN_USERNAME} / ${config.ADMIN_PASSWORD}`);
}

module.exports = db;
