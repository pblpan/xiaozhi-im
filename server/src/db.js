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
// 机器人的归属人（谁创建的，便于后台追责与清理）
ensureColumn('users', 'bot_owner_id', 'bot_owner_id INTEGER');

// 首次启动播种管理员账号，保证 /admin 开箱可用
const existing = db.prepare('SELECT id FROM users WHERE username = ?').get(config.ADMIN_USERNAME);
if (!existing) {
  db.prepare('INSERT INTO users (username, password_hash, nickname, role, created_at) VALUES (?,?,?,?,?)')
    .run(config.ADMIN_USERNAME, hashPassword(config.ADMIN_PASSWORD), '管理员', 'admin', Date.now());
  console.log(`[小智IM] 已创建管理员账号: ${config.ADMIN_USERNAME} / ${config.ADMIN_PASSWORD}`);
}

module.exports = db;
