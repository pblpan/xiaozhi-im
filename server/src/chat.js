// 消息落库 + 实时广播（REST 与 WebSocket 共用）
const db = require('./db');
const hub = require('./hub');
const events = require('./events');

/** 撤回时限：2 分钟（与主流 IM 一致） */
const RECALL_WINDOW_MS = 2 * 60 * 1000;

// 给消息行补上文件访问地址（历史消息 content 存的是原始名，实际要按 files.path 取）
function withFileInfo(row) {
  if (!row) return row;
  // mentions 落库是 JSON 字符串，出口统一转成数组，客户端直接用
  const base = { ...row, mentions: parseMentions(row.mentions) };
  if (row.deleted) return { ...base, file_url: null, file_name: null, file_mime: null, file_size: null };
  if (!row.file_id) return { ...base, file_url: null };
  const f = db.prepare('SELECT name,mime,size,path FROM files WHERE id=?').get(row.file_id);
  if (!f) return { ...base, file_url: null };
  return { ...base, file_url: `/files/${f.path}`, file_name: f.name, file_mime: f.mime, file_size: f.size };
}

/** mentions 列（",1,11," 形式）→ 数字数组；非法值一律当空 */
function parseMentions(raw) {
  if (!raw) return [];
  return String(raw).split(',')
    .map((s) => s.trim())
    .filter((s) => s !== '')
    .map(Number)
    .filter((n) => Number.isInteger(n));
}

/** 数字数组 → ",1,11," 形式。用逗号包裹是为了 LIKE '%,1,%' 能精确命中，避免 uid=1 误匹配 [11] */
function serializeMentions(ids) {
  return ids.length ? ',' + ids.join(',') + ',' : null;
}

/** 生成"精确匹配某个提及 id"的 LIKE 模式 */
function mentionLike(id) {
  return '%,' + Number(id) + ',%';
}

/** 允许的消息类型（audio=语音，content 存时长秒数；card=结构化卡片，content 存 JSON；
 *  call=通话记录，content 存 {mode,status,duration,caller,callee} JSON） */
const KINDS = ['text', 'image', 'file', 'emoji', 'audio', 'card', 'call'];

/** 卡片配色：外部系统只需给语义色名，具体色值由客户端决定（换肤不用改对接方） */
const CARD_COLORS = ['blue', 'green', 'orange', 'red', 'purple', 'gray'];

/** 单条文字消息上限。留足长文本空间，同时挡住误推整篇日志的情况 */
const MAX_TEXT_LEN = 8000;

function clip(v, n) {
  const s = v === null || v === undefined ? '' : String(v);
  return s.trim().slice(0, n);
}

/**
 * 卡片内容归一化。外部系统常直接甩业务 JSON 过来，这里做一层"擦洗"：
 *   - 字段类型/长度全部收敛，避免脏数据把客户端渲染搞崩
 *   - 数量设上限，防止有人塞 1000 行把消息表撑爆
 *   - 至少要有一个可展示的部分，纯空卡片直接拒绝
 */
function normalizeCard(content) {
  let c = content;
  if (typeof c === 'string') {
    try { c = JSON.parse(c); }
    catch { throw new Error('卡片内容不是合法 JSON'); }
  }
  if (!c || typeof c !== 'object' || Array.isArray(c)) throw new Error('卡片必须是 JSON 对象');

  const title = clip(c.title, 80);
  const text = clip(c.text, 2000);
  const fields = (Array.isArray(c.fields) ? c.fields : [])
    .slice(0, 12)
    .map((f) => ({
      label: clip(f && f.label, 24),
      value: clip(f && f.value, 200),
      short: !!(f && f.short),
    }))
    .filter((f) => f.label || f.value);

  if (!title && !text && !fields.length) {
    throw new Error('卡片至少要有 title / text / fields 之一');
  }

  const color = CARD_COLORS.includes(String(c.color)) ? String(c.color) : 'blue';
  const url = clip(c.url, 500);
  const out = {
    title, text, fields, color,
    footer: clip(c.footer, 120),
    url: /^https?:\/\//i.test(url) ? url : '',
  };

  // 兜底体积上限：正常卡片几 KB，超过说明塞了不该塞的东西
  if (JSON.stringify(out).length > 8192) throw new Error('卡片内容过大（上限 8KB）');
  return out;
}

/** @所有人 的哨兵值（存进 mentions JSON 数组） */
const MENTION_ALL = -1;

/**
 * 规范化 @提及列表：
 * - 允许传数字 id 或字符串（'all' / '-1' 表示所有人）
 * - 只保留当前会话的真实成员，防止 @ 到会话外的人（越权探测）
 * - 非群聊忽略 @所有人
 */
function normalizeMentions(raw, conversationId) {
  if (!raw) return [];
  const arr = Array.isArray(raw) ? raw : [raw];
  const memberIds = new Set(
    db.prepare('SELECT user_id FROM conversation_members WHERE conversation_id = ?')
      .all(conversationId).map((r) => r.user_id),
  );
  const isGroup = db.prepare('SELECT type FROM conversations WHERE id = ?').get(conversationId)?.type === 'group';

  const out = new Set();
  for (const v of arr) {
    const s = String(v).trim().toLowerCase();
    if (s === 'all' || s === '-1') {
      if (isGroup) out.add(MENTION_ALL);
      continue;
    }
    const id = Number(v);
    if (Number.isInteger(id) && memberIds.has(id)) out.add(id);
  }
  return [...out];
}

/** 取群成员的禁言到期时间（非群成员 / 非群聊返回 0） */
function mutedUntilOf(conversationId, userId) {
  const g = db.prepare('SELECT id, owner_id FROM groups WHERE conversation_id = ?').get(conversationId);
  if (!g) return 0;
  if (g.owner_id === userId) return 0; // 群主永不被禁言
  const m = db.prepare('SELECT muted_until FROM group_members WHERE group_id = ? AND user_id = ?').get(g.id, userId);
  return m?.muted_until || 0;
}

function sendMessage({ conversationId, senderId, kind, content, fileId, mentions }) {
  const conv = db.prepare('SELECT id FROM conversations WHERE id = ?').get(conversationId);
  if (!conv) throw new Error('conversation not found');
  const member = db.prepare('SELECT user_id FROM conversation_members WHERE conversation_id = ? AND user_id = ?')
    .get(conversationId, senderId);
  if (!member) throw new Error('not a member of this conversation');

  // 群内被禁言的成员不能发言
  const muted = mutedUntilOf(conversationId, senderId);
  if (muted > Date.now()) {
    const mins = Math.ceil((muted - Date.now()) / 60000);
    throw new Error(`你已被禁言，还需 ${mins} 分钟`);
  }

  const k = kind || 'text';
  if (!KINDS.includes(k)) throw new Error('不支持的消息类型: ' + k);
  // 媒体类消息必须带文件；文字类必须带内容
  if ((k === 'image' || k === 'file' || k === 'audio') && !fileId) {
    throw new Error(k + ' 消息缺少文件');
  }
  if (k === 'text' && !String(content || '').trim()) throw new Error('内容不能为空');
  // 外部系统可能误推超长文本（整篇日志/HTML），落库前收敛，避免撑爆消息表与客户端渲染
  if (k === 'text' && String(content).length > MAX_TEXT_LEN) {
    throw new Error(`文字消息过长（上限 ${MAX_TEXT_LEN} 字）`);
  }

  // 语音时长归一化：限制在 1~600 秒，非法值兜底 1
  let body = content ?? null;
  if (k === 'audio') {
    const sec = Math.round(Number(content));
    body = String(Number.isFinite(sec) ? Math.min(Math.max(sec, 1), 600) : 1);
  }
  // 卡片：内容归一化成规范 JSON 串，非法结构直接拒绝
  if (k === 'card') body = JSON.stringify(normalizeCard(content));

  const ms = normalizeMentions(mentions, conversationId);
  const res = db.prepare(`INSERT INTO messages
    (conversation_id, sender_id, kind, content, file_id, created_at, edited, deleted, mentions)
    VALUES (?,?,?,?,?,?,0,0,?)`)
    .run(conversationId, senderId, k, body, fileId || null, Date.now(),
      serializeMentions(ms));

  // 发消息视为已读到本条，避免自己发的消息显示未读
  db.prepare(`UPDATE conversation_members SET last_read_id = ?
    WHERE conversation_id = ? AND user_id = ? AND last_read_id < ?`)
    .run(res.lastInsertRowid, conversationId, senderId, res.lastInsertRowid);

  const msg = db.prepare('SELECT * FROM messages WHERE id = ?').get(res.lastInsertRowid);
  const full = withFileInfo(msg);
  hub.broadcastToConversation(db, conversationId, { type: 'message:new', message: full }, senderId);
  // 对外事件：外部系统（工厂V2/OA/脚本）订阅后即可拿到每条新消息
  events.emitMessageCreated(full);
  return full;
}

/** 撤回消息：仅本人、2 分钟内、未被撤回。广播给会话全体（含自己的其他端）。 */
function recallMessage({ messageId, userId }) {
  const m = db.prepare('SELECT * FROM messages WHERE id = ?').get(messageId);
  if (!m) throw new Error('消息不存在');
  if (m.sender_id !== userId) throw new Error('只能撤回自己的消息');
  if (m.deleted) throw new Error('该消息已撤回');
  if (Date.now() - m.created_at > RECALL_WINDOW_MS) throw new Error('超过 2 分钟，无法撤回');

  db.prepare('UPDATE messages SET deleted = 1, content = NULL, file_id = NULL WHERE id = ?').run(messageId);

  const payload = {
    type: 'message:recall',
    messageId,
    conversationId: m.conversation_id,
    senderId: userId,
  };
  hub.broadcastToConversation(db, m.conversation_id, payload, null);
  events.emit('message.recalled', {
    conversationId: m.conversation_id,
    selfId: userId,
    data: { messageId, senderId: userId },
  });
  return payload;
}

/**
 * 已发送的消息**不支持编辑**（产品决策：只能撤回）。
 *
 * 这里刻意不再提供实现，而不是留个空壳：留空壳的话，将来有人看到
 * `editMessage` 存在就会顺手接上路由，等于把口子又开回来。
 * messages.js / ws.js 里对编辑请求统一回 410 + 中文提示，
 * 兜住还在用旧版客户端（<= v0.5.2）的用户。
 *
 * `messages.edited` 列保留：历史数据里可能有 edited=1 的消息，
 * 客户端仍会渲染「已编辑」标记，删列会让老消息显示异常。
 */

/** 标记已读：把会话成员的 last_read_id 推进到指定消息（缺省=该会话最新一条）。 */
function markRead({ conversationId, userId, messageId }) {
  const member = db.prepare('SELECT last_read_id FROM conversation_members WHERE conversation_id = ? AND user_id = ?')
    .get(conversationId, userId);
  if (!member) throw new Error('not a member of this conversation');

  let target = Number(messageId) || 0;
  if (!target) {
    const row = db.prepare('SELECT MAX(id) AS mid FROM messages WHERE conversation_id = ?').get(conversationId);
    target = row?.mid || 0;
  }
  const cur = member.last_read_id || 0;
  if (target <= cur) return { conversationId, userId, lastReadId: cur, changed: false };

  db.prepare('UPDATE conversation_members SET last_read_id = ? WHERE conversation_id = ? AND user_id = ?')
    .run(target, conversationId, userId);

  // 告诉会话内其他人"我读到哪了"（用于对方渲染已读回执）
  hub.broadcastToConversation(db, conversationId, {
    type: 'message:read',
    conversationId,
    userId,
    lastReadId: target,
  }, userId);

  return { conversationId, userId, lastReadId: target, changed: true };
}

/** 输入中状态：不落库，纯透传给会话内其他人。 */
function typing({ conversationId, userId }) {
  const member = db.prepare('SELECT user_id FROM conversation_members WHERE conversation_id = ? AND user_id = ?')
    .get(conversationId, userId);
  if (!member) return;
  hub.broadcastToConversation(db, conversationId, {
    type: 'typing',
    conversationId,
    userId,
  }, userId);
}

/** 会话成员的已读位置快照（供历史接口返回，渲染已读回执）。 */
function readState(conversationId) {
  return db.prepare('SELECT user_id, last_read_id FROM conversation_members WHERE conversation_id = ?')
    .all(conversationId);
}

/**
 * 取「我给某人起的备注」（好友备注）。
 *
 * 备注是 owner 这一侧的私有属性，存在 friendships(user_id=owner, friend_id=peer)
 * 这一行上，对方看不到。没设备注时返回 null，调用方用
 * `remark || nickname || username` 兜底成原来的展示名。
 */
function remarkOf(ownerId, peerId) {
  const r = db.prepare('SELECT remark FROM friendships WHERE user_id = ? AND friend_id = ?')
    .get(ownerId, peerId);
  return r && r.remark ? r.remark : null;
}

/** 取会话展示名（单聊=我给对方的备注/对方昵称，群聊=群名） */
function conversationTitle(conversationId, uid) {
  const c = db.prepare('SELECT id, type FROM conversations WHERE id = ?').get(conversationId);
  if (!c) return { id: conversationId, type: null, title: null };
  if (c.type === 'dm') {
    const other = db.prepare(`SELECT u.id, u.username, u.nickname FROM conversation_members cm
      JOIN users u ON u.id = cm.user_id
      WHERE cm.conversation_id = ? AND cm.user_id != ?`).get(conversationId, uid);
    const remark = other ? remarkOf(uid, other.id) : null;
    return {
      id: c.id, type: 'dm',
      // 备注优先：我给对方起的名字应该出现在聊天标题里
      title: remark || (other ? (other.nickname || other.username) : null),
      peer: other ? { ...other, remark } : other,
    };
  }
  const g = db.prepare('SELECT name FROM groups WHERE conversation_id = ?').get(conversationId);
  return { id: c.id, type: 'group', title: g ? g.name : null };
}

/**
 * 全局消息搜索：仅在「我参与的会话」里搜，排除已撤回。
 * 只搜 text / card 类——图片/文件/语音的 content 不是可读文本，命中无意义；
 * 卡片是 JSON 但里面含标题与正文，能搜到「那条库存预警」很有用。
 * 关键词里的 LIKE 通配符（% _ \）做转义，避免用户输入 % 变全表匹配。
 */
function searchMessages({ userId, q, conversationId, limit = 50, offset = 0 }) {
  const kw = String(q || '').trim();
  if (!kw) return { items: [], total: 0, keyword: '' };

  const cap = Math.min(Math.max(Number(limit) || 50, 1), 200);
  const off = Math.max(Number(offset) || 0, 0);
  const like = '%' + kw.replace(/[\\%_]/g, (ch) => '\\' + ch) + '%';

  const params = [userId, like];
  let extra = '';
  if (conversationId) {
    extra = ' AND m.conversation_id = ?';
    params.push(Number(conversationId));
  }

  const from = `FROM messages m
    JOIN conversation_members cm ON cm.conversation_id = m.conversation_id AND cm.user_id = ?
    WHERE m.deleted = 0 AND m.kind IN ('text','card') AND m.content LIKE ? ESCAPE '\\'${extra}`;

  const total = db.prepare(`SELECT COUNT(*) AS n ${from}`).get(...params).n;
  const rows = db.prepare(`SELECT m.* ${from} ORDER BY m.id DESC LIMIT ? OFFSET ?`)
    .all(...params, cap, off);

  const items = rows.map((r) => {
    const conv = conversationTitle(r.conversation_id, userId);
    const s = db.prepare('SELECT username, nickname FROM users WHERE id = ?').get(r.sender_id);
    return {
      ...withFileInfo(r),
      conv_title: conv.title,
      conv_type: conv.type,
      peer: conv.peer || null,
      sender_name: s ? (s.nickname || s.username) : null,
      mine: r.sender_id === userId,
    };
  });

  return { items, total, keyword: kw, limit: cap, offset: off };
}

/**
 * 转发消息到若干会话：内容原样复制（新的 sender 是我），不复制 @提及。
 * 只允许转发「我参与的原会话」里的消息；目标会话必须是我是成员。
 */
function forwardMessage({ messageId, userId, conversationIds }) {
  const src = db.prepare('SELECT * FROM messages WHERE id = ?').get(messageId);
  if (!src) throw new Error('消息不存在');
  if (src.deleted) throw new Error('该消息已撤回，无法转发');
  const srcMember = db.prepare('SELECT user_id FROM conversation_members WHERE conversation_id = ? AND user_id = ?')
    .get(src.conversation_id, userId);
  if (!srcMember) throw new Error('无权转发该消息');

  const ids = [...new Set(
    (Array.isArray(conversationIds) ? conversationIds : [conversationIds])
      .map(Number).filter(Number.isInteger),
  )];
  if (!ids.length) throw new Error('请选择转发目标');
  if (ids.length > 20) throw new Error('一次最多转发到 20 个会话');

  const now = Date.now();
  const done = [];
  for (const cid of ids) {
    const m = db.prepare('SELECT user_id FROM conversation_members WHERE conversation_id = ? AND user_id = ?')
      .get(cid, userId);
    if (!m) continue;                                   // 非成员静默跳过
    if (mutedUntilOf(cid, userId) > now) continue;       // 被禁言的会话跳过

    const res = db.prepare(`INSERT INTO messages
      (conversation_id, sender_id, kind, content, file_id, created_at, edited, deleted, mentions)
      VALUES (?,?,?,?,?,?,0,0,NULL)`)
      .run(cid, userId, src.kind, src.content, src.file_id, now);
    db.prepare(`UPDATE conversation_members SET last_read_id = ?
      WHERE conversation_id = ? AND user_id = ? AND last_read_id < ?`)
      .run(res.lastInsertRowid, cid, userId, res.lastInsertRowid);

    const full = withFileInfo(db.prepare('SELECT * FROM messages WHERE id = ?').get(res.lastInsertRowid));
    hub.broadcastToConversation(db, cid, { type: 'message:new', message: full }, userId);
    events.emitMessageCreated(full);
    done.push({ conversationId: cid, message: full });
  }
  if (!done.length) throw new Error('没有可转发的会话');
  return { count: done.length, items: done };
}

/** 群聊置顶需要群主/管理员；单聊任意成员可置顶。 */
function canPin(conversationId, userId) {
  const g = db.prepare('SELECT id, owner_id FROM groups WHERE conversation_id = ?').get(conversationId);
  if (!g) return true;
  if (g.owner_id === userId) return true;
  const m = db.prepare('SELECT role FROM group_members WHERE group_id = ? AND user_id = ?').get(g.id, userId);
  return m?.role === 'admin';
}

/** 置顶/取消置顶一条消息（同一个 messageId 再调一次即取消）。 */
function togglePin({ conversationId, userId, messageId }) {
  const member = db.prepare('SELECT user_id FROM conversation_members WHERE conversation_id = ? AND user_id = ?')
    .get(conversationId, userId);
  if (!member) throw new Error('not a member of this conversation');
  if (!canPin(conversationId, userId)) throw new Error('只有群主或管理员可以置顶消息');

  const conv = db.prepare('SELECT pinned_message_id FROM conversations WHERE id = ?').get(conversationId);
  const mid = Number(messageId);
  let pinned = null;
  if (Number(conv?.pinned_message_id) !== mid) {
    const m = db.prepare('SELECT id FROM messages WHERE id = ? AND conversation_id = ? AND deleted = 0')
      .get(mid, conversationId);
    if (!m) throw new Error('消息不存在或已撤回');
    pinned = m.id;
  }
  db.prepare('UPDATE conversations SET pinned_message_id = ? WHERE id = ?').run(pinned, conversationId);

  const payload = { type: 'conversation:pin', conversationId, pinnedMessageId: pinned };
  hub.broadcastToConversation(db, conversationId, payload, null);
  return payload;
}

/** 会话置顶消息详情（供会话顶部展示） */
function pinnedMessage(conversationId) {
  const conv = db.prepare('SELECT pinned_message_id FROM conversations WHERE id = ?').get(conversationId);
  const mid = conv?.pinned_message_id;
  if (!mid) return null;
  const m = db.prepare('SELECT * FROM messages WHERE id = ?').get(mid);
  if (!m || m.deleted) return null;
  const s = db.prepare('SELECT username, nickname FROM users WHERE id = ?').get(m.sender_id);
  return { ...withFileInfo(m), sender_name: s ? (s.nickname || s.username) : null };
}

// ---------- 消息收藏 ----------

function addFavorite({ userId, messageId }) {
  const m = db.prepare('SELECT * FROM messages WHERE id = ?').get(messageId);
  if (!m) throw new Error('消息不存在');
  if (m.deleted) throw new Error('该消息已撤回，无法收藏');
  const mem = db.prepare('SELECT user_id FROM conversation_members WHERE conversation_id = ? AND user_id = ?')
    .get(m.conversation_id, userId);
  if (!mem) throw new Error('无权收藏该消息');
  db.prepare('INSERT OR IGNORE INTO favorites (user_id, message_id, created_at) VALUES (?,?,?)')
    .run(userId, messageId, Date.now());
  return { ok: true, messageId };
}

function removeFavorite({ userId, messageId }) {
  db.prepare('DELETE FROM favorites WHERE user_id = ? AND message_id = ?').run(userId, messageId);
  return { ok: true, messageId };
}

function listFavorites({ userId, limit = 100, offset = 0 }) {
  const cap = Math.min(Math.max(Number(limit) || 100, 1), 200);
  const off = Math.max(Number(offset) || 0, 0);
  const rows = db.prepare(`SELECT m.*, f.created_at AS favorited_at
    FROM favorites f JOIN messages m ON m.id = f.message_id
    WHERE f.user_id = ? ORDER BY f.id DESC LIMIT ? OFFSET ?`).all(userId, cap, off);
  const total = db.prepare('SELECT COUNT(*) n FROM favorites WHERE user_id = ?').get(userId).n;

  const items = rows.map((r) => {
    const conv = conversationTitle(r.conversation_id, userId);
    const s = db.prepare('SELECT username, nickname FROM users WHERE id = ?').get(r.sender_id);
    return {
      ...withFileInfo(r),
      conv_title: conv.title,
      conv_type: conv.type,
      peer: conv.peer || null,
      sender_name: s ? (s.nickname || s.username) : null,
      mine: r.sender_id === userId,
    };
  });
  return { items, total, limit: cap, offset: off };
}

module.exports = {
  sendMessage, withFileInfo,
  recallMessage, markRead, typing, readState,
  conversationTitle, searchMessages, remarkOf,
  forwardMessage, togglePin, pinnedMessage, canPin,
  addFavorite, removeFavorite, listFavorites,
  normalizeMentions, mutedUntilOf, parseMentions, serializeMentions, mentionLike,
  normalizeCard,
  RECALL_WINDOW_MS, KINDS, CARD_COLORS, MAX_TEXT_LEN, MENTION_ALL,
};
