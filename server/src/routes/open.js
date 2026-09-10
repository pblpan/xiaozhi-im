// 开放 API：外部软件用 API Token 调用的运行时接口
//
//   Authorization: Bearer xz_xxxxxxxx...
//
// 与 /api/admin 的区别：admin 是给人用的管理台（JWT + 管理员角色），
// open 是给程序用的（长期令牌 + scope 白名单 + 只暴露必要能力）。
const express = require('express');
const multer = require('multer');
const path = require('path');
const db = require('../db');
const config = require('../config');
const { requireScope, SCOPES, listBots } = require('../integration');
const { sendMessage, withFileInfo } = require('../chat');

const router = express.Router();

// 与 /api/files 同一套存储策略（文件名随机化，避免覆盖与路径穿越）
const upload = multer({
  storage: multer.diskStorage({
    destination: (req, file, cb) => cb(null, config.FILES_DIR),
    filename: (req, file, cb) => cb(null,
      `${Date.now()}-${Math.round(Math.random() * 1e9)}${path.extname(file.originalname)}`),
  }),
  limits: { fileSize: config.MAX_FILE_MB * 1024 * 1024 },
});

/** 会话概要：外部系统最需要的是"我该往哪个 conversationId 推" */
function convSummary(cid, uid) {
  const c = db.prepare('SELECT id, type, created_at FROM conversations WHERE id = ?').get(cid);
  if (!c) return null;
  if (c.type === 'group') {
    const g = db.prepare('SELECT id, name FROM groups WHERE conversation_id = ?').get(cid);
    return { id: c.id, type: 'group', groupId: g ? g.id : null, title: g ? g.name : null, createdAt: c.created_at };
  }
  const other = db.prepare(`SELECT u.id, u.nickname, u.username, u.is_bot FROM conversation_members cm
    JOIN users u ON u.id = cm.user_id WHERE cm.conversation_id = ? AND cm.user_id != ?`).get(cid, uid);
  return {
    id: c.id, type: 'dm',
    title: other ? (other.nickname || other.username) : null,
    peerId: other ? other.id : null,
    peerIsBot: !!(other && other.is_bot),
    createdAt: c.created_at,
  };
}

function memberOf(cid, uid) {
  return db.prepare('SELECT user_id FROM conversation_members WHERE conversation_id = ? AND user_id = ?')
    .get(Number(cid), uid);
}

/* ==================== 元信息 ==================== */

// 令牌自检：返回身份与权限，方便对接方启动时先探一下
router.get('/me', (req, res) => {
  const auth = requireScope(req, res, 'conversation:read');
  if (!auth) return;
  const u = db.prepare('SELECT id, username, nickname, is_bot FROM users WHERE id = ?').get(auth.userId);
  res.json({
    ok: true,
    tokenName: auth.tokenName || null,
    identity: {
      id: u.id,
      username: u.username,
      nickname: u.nickname,
      isBot: !!u.is_bot,
    },
    scopes: auth.scopes,
    allScopes: SCOPES,
  });
});

/* ==================== 会话 ==================== */

// 我（令牌身份）能发消息的会话列表 —— 对接方第一步就是从这里拿 conversationId
router.get('/conversations', (req, res) => {
  const auth = requireScope(req, res, 'conversation:read');
  if (!auth) return;
  const rows = db.prepare(`SELECT c.id FROM conversations c
    JOIN conversation_members cm ON cm.conversation_id = c.id
    WHERE cm.user_id = ?
    ORDER BY (SELECT MAX(created_at) FROM messages m WHERE m.conversation_id = c.id) DESC`).all(auth.userId);
  res.json({ items: rows.map((r) => convSummary(r.id, auth.userId)).filter(Boolean) });
});

// 会话成员（推 @ 之前先看看有谁）
router.get('/conversations/:id/members', (req, res) => {
  const auth = requireScope(req, res, 'conversation:read');
  if (!auth) return;
  const cid = Number(req.params.id);
  if (!memberOf(cid, auth.userId)) return res.status(403).json({ error: 'forbidden' });
  const rows = db.prepare(`SELECT u.id, u.username, u.nickname, u.is_bot
    FROM conversation_members cm JOIN users u ON u.id = cm.user_id
    WHERE cm.conversation_id = ?`).all(cid);
  res.json({ items: rows.map((u) => ({ ...u, is_bot: !!u.is_bot })) });
});

// 读消息（增量拉取：?sinceId= 只拿更新的，适合外部系统做同步）
router.get('/conversations/:id/messages', (req, res) => {
  const auth = requireScope(req, res, 'message:read');
  if (!auth) return;
  const cid = Number(req.params.id);
  if (!memberOf(cid, auth.userId)) return res.status(403).json({ error: 'forbidden' });

  const limit = Math.min(Math.max(Number(req.query.limit) || 50, 1), 200);
  const sinceId = Math.max(Number(req.query.sinceId) || 0, 0);
  const rows = db.prepare(`SELECT m.*, u.is_bot AS sender_is_bot, u.nickname AS sender_name, u.username AS sender_username
    FROM messages m LEFT JOIN users u ON u.id = m.sender_id
    WHERE m.conversation_id = ? AND m.id > ?
    ORDER BY m.id ASC LIMIT ?`).all(cid, sinceId, limit);

  res.json({
    conversation: convSummary(cid, auth.userId),
    items: rows.map((r) => ({
      ...withFileInfo(r),
      sender_name: r.sender_name || r.sender_username || null,
      sender_is_bot: !!r.sender_is_bot,
    })),
  });
});

// 发消息：外部系统最主要的动作
router.post('/conversations/:id/messages', (req, res) => {
  const auth = requireScope(req, res, 'message:send');
  if (!auth) return;
  const cid = Number(req.params.id);
  if (!memberOf(cid, auth.userId)) return res.status(403).json({ error: 'forbidden' });

  const b = req.body || {};
  let kind = b.kind;
  let content = b.content;
  // 没写 kind 时按内容猜：有 title/fields 就是卡片，否则当文字
  if (!kind) {
    if (b.title !== undefined || b.fields !== undefined || b.color !== undefined) {
      kind = 'card'; content = b;
    } else if (b.text !== undefined || b.markdown !== undefined) {
      kind = 'text'; content = b.text !== undefined ? b.text : b.markdown;
    }
  }
  if (!kind) return res.status(400).json({ error: 'kind required（或提供 text / title+fields）' });

  try {
    const msg = sendMessage({
      conversationId: cid,
      senderId: auth.userId,
      kind,
      content,
      fileId: b.fileId,
      mentions: b.mentions,
    });
    res.json(msg);
  } catch (e) { res.status(400).json({ error: e.message }); }
});

/* ==================== 用户 / 机器人 ==================== */

router.get('/users', (req, res) => {
  const auth = requireScope(req, res, 'user:read');
  if (!auth) return;
  const q = String(req.query.q || '').trim();
  const like = '%' + q.replace(/[\\%_]/g, (ch) => '\\' + ch) + '%';
  const rows = q
    ? db.prepare(`SELECT id, username, nickname, avatar, is_bot FROM users
        WHERE (username LIKE ? ESCAPE '\\' OR nickname LIKE ? ESCAPE '\\') ORDER BY id ASC LIMIT 100`)
      .all(like, like)
    : db.prepare('SELECT id, username, nickname, avatar, is_bot FROM users ORDER BY id ASC LIMIT 100').all();
  res.json({ items: rows.map((u) => ({ ...u, is_bot: !!u.is_bot })) });
});

// 机器人清单：对接方可以据此选择"以谁的身份发言"
router.get('/bots', (req, res) => {
  const auth = requireScope(req, res, 'conversation:read');
  if (!auth) return;
  res.json({ items: listBots() });
});

/* ==================== 文件 ==================== */

router.post('/files', upload.single('file'), (req, res) => {
  const auth = requireScope(req, res, 'file:upload');
  if (!auth) return;
  if (!req.file) return res.status(400).json({ error: 'no file（表单字段名用 file）' });
  const info = db.prepare('INSERT INTO files (owner_id,name,mime,size,path,created_at) VALUES (?,?,?,?,?,?)')
    .run(auth.userId, req.file.originalname, req.file.mimetype, req.file.size, req.file.filename, Date.now());
  res.json({
    id: Number(info.lastInsertRowid),
    name: req.file.originalname,
    url: `/files/${req.file.filename}`,
    mime: req.file.mimetype,
    size: req.file.size,
  });
});

module.exports = router;
