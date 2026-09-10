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

// 首次启动播种管理员账号，保证 /admin 开箱可用
const existing = db.prepare('SELECT id FROM users WHERE username = ?').get(config.ADMIN_USERNAME);
if (!existing) {
  db.prepare('INSERT INTO users (username, password_hash, nickname, role, created_at) VALUES (?,?,?,?,?)')
    .run(config.ADMIN_USERNAME, hashPassword(config.ADMIN_PASSWORD), '管理员', 'admin', Date.now());
  console.log(`[小智IM] 已创建管理员账号: ${config.ADMIN_USERNAME} / ${config.ADMIN_PASSWORD}`);
}

module.exports = db;
