// 消息落库 + 实时广播（REST 与 WebSocket 共用）
const db = require('./db');
const hub = require('./hub');
const events = require('./events');
const push = require('./push');

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
const KINDS = ['text', 'image', 'file', 'emoji', 'audio', 'card', 'call', 'poll'];

/** 卡片配色：外部系统只需给语义色名，具体色值由客户端决定（换肤不用改对接方） */
const CARD_COLORS = ['blue', 'green', 'orange', 'red', 'purple', 'gray'];

/**
 * 告警级别 → 语义色的兜底映射。
 *
 * 【为什么要有这一层】第三方告警系统传的几乎都是 severity / level，而不是 color
 * （网络运维工具箱、Alertmanager、Grafana、各家自建脚本都一样）。没有这层的话，
 * 它们推过来的卡片全部落成默认蓝 —— **严重告警和普通通知长得一模一样**，
 * 值班的人扫一眼分不出轻重，这比"没推"更危险。
 *
 * 只在对接方**没给** color 时生效：明确给了 color 的一律以对接方为准。
 * 级别名从宽收录（大小写不敏感），认不出的回落默认蓝。
 */
const SEVERITY_COLORS = {
  red: ['critical', 'fatal', 'emergency', 'alert', 'error', 'severe', 'major', 'high', 'down', 'fail', 'failed'],
  orange: ['warning', 'warn', 'medium', 'minor', 'degraded'],
  green: ['ok', 'success', 'resolved', 'recovery', 'recovered', 'normal', 'up', 'healthy', 'pass'],
  blue: ['info', 'notice', 'debug', 'low', 'unknown'],
  gray: ['disabled', 'maintenance', 'silent', 'ignored', 'none', 'closed'],
};

function severityToColor(sev) {
  const s = String(sev === null || sev === undefined ? '' : sev).trim().toLowerCase();
  if (!s) return '';
  for (const [color, names] of Object.entries(SEVERITY_COLORS)) {
    if (names.includes(s)) return color;
  }
  return '';
}

/** 单条文字消息上限。留足长文本空间，同时挡住误推整篇日志的情况 */
const MAX_TEXT_LEN = 8000;

/**
 * 只认"本来就是文本"的值：对象/数组一律当空。
 *
 * 【为什么不能直接 String(v)】外部系统（尤其照抄钉钉/企微/飞书格式的对接方）
 * 很爱把文本塞进嵌套对象里。`String({content:'x'})` 得到的是 `"[object Object]"`，
 * 这个字符串会被当成正常内容存库、广播、渲染 —— 一条内容是 `[object Object]` 的
 * 消息就这么进群了，而且看不出是谁发的错。这里拦成空串，
 * 让下层的"至少要有 title/text/fields 之一"或卡片的显式类型检查去报错。
 */
function asText(v) {
  if (v === null || v === undefined) return '';
  if (typeof v === 'object') return '';
  return String(v);
}

function clip(v, n) {
  return asText(v).trim().slice(0, n);
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

  // 文本类字段显式要求是字符串。不拦的话 clip() 会把对象擦成空串，
  // 报错就退化成含糊的「卡片至少要有 title / text / fields 之一」，
  // 对接方根本看不出是"字段类型不对"而不是"字段没填"。
  for (const k of ['title', 'text', 'footer', 'url']) {
    const v = c[k];
    if (v !== undefined && v !== null && typeof v === 'object') {
      throw new Error(`卡片字段 ${k} 必须是字符串，收到的是${Array.isArray(v) ? '数组' : '对象'}`);
    }
  }

  const title = clip(c.title, 80);
  const text = clip(c.text, 2000);
  const fields = (Array.isArray(c.fields) ? c.fields : [])
    .slice(0, 12)
    .map((f, i) => {
      for (const k of ['label', 'value']) {
        const v = f && f[k];
        if (v !== undefined && v !== null && typeof v === 'object') {
          throw new Error(
            `fields[${i}].${k} 必须是字符串，收到的是${Array.isArray(v) ? '数组' : '对象'}`,
          );
        }
      }
      return {
        label: clip(f && f.label, 24),
        value: clip(f && f.value, 200),
        short: !!(f && f.short),
      };
    })
    .filter((f) => f.label || f.value);

  if (!title && !text && !fields.length) {
    throw new Error('卡片至少要有 title / text / fields 之一');
  }

  // 对接方给了 color 就用它；没给才尝试从 severity / level / status 推导，
  // 这样"只填个地址"接进来的告警系统也能推出正确的红/橙/绿，而不是一律蓝。
  const rawColor = String(c.color === null || c.color === undefined ? '' : c.color)
    .trim().toLowerCase();
  const color = CARD_COLORS.includes(rawColor)
    ? rawColor
    : (severityToColor(c.severity !== undefined ? c.severity
      : (c.level !== undefined ? c.level : c.status)) || 'blue');
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

/**
 * 全员禁言下这个人能不能发言。
 * 豁免名单 = 群主 + 群内管理员 + 系统管理员（与单人禁言的"能禁言的人"一致 ——
 * 能管群的人必须永远能说话，否则通知群发不出公告就名存实亡）。
 * 返回 null 表示没被全员禁言拦（继续走单人禁言判断）。
 */
function mutedAllBlock(conversationId, userId) {
  const g = db.prepare('SELECT id, owner_id, muted_all FROM groups WHERE conversation_id = ?').get(conversationId);
  if (!g || !g.muted_all) return null;
  if (g.owner_id === userId) return false;
  const m = db.prepare('SELECT role FROM group_members WHERE group_id = ? AND user_id = ?').get(g.id, userId);
  if (m?.role === 'admin') return false;
  const isSysAdmin = db.prepare('SELECT role FROM users WHERE id = ?').get(userId)?.role === 'admin';
  if (isSysAdmin) return false;
  return true; // 普通成员 → 被拦
}

/**
 * 消息内容的"一句话预览"（通知栏正文用）。
 *
 * 只在服务端做这一层，是因为**只有服务端知道 kind 是什么**：客户端各语言版本、
 * 各平台各写一遍，早晚出现"iOS 上图片消息通知成空白"。
 * 各类型都不带原始内容 —— 通知栏在锁屏上，不该把私聊正文整段摊开给别人看。
 */
function previewOf(m) {
  switch (m.kind) {
    case 'text': return String(m.content || '').slice(0, 120);
    case 'image': return '[图片]';
    case 'audio': return '[语音]';
    case 'file': return '[文件]' + (m.file_name ? ' ' + m.file_name : '');
    case 'call': return '[通话]';
    case 'card': {
      try {
        const c = JSON.parse(m.content || '{}');
        return '[卡片]' + (c.title ? ' ' + c.title : '');
      } catch { return '[卡片]'; }
    }
    case 'poll': {
      // 预览带上投票标题（群列表/通知栏里"[投票] 周末聚餐报名"比光秃秃的 [投票] 有用）
      try {
        const c = JSON.parse(m.content || '{}');
        const p = c.pollId
          ? db.prepare('SELECT title FROM group_polls WHERE id=?').get(c.pollId)
          : null;
        return '[投票]' + (p?.title ? ' ' + p.title : '');
      } catch { return '[投票]'; }
    }
    default: return '[消息]';
  }
}

/** 该用户全部会话的未读数（通知角标用）。一条 COUNT 解决，不逐会话查。 */
function unreadCount(userId) {
  const r = db.prepare(`SELECT COUNT(*) AS n FROM messages m
      JOIN conversation_members cm
        ON cm.conversation_id = m.conversation_id AND cm.user_id = ?
      WHERE m.deleted = 0 AND m.id > COALESCE(cm.last_read_id, 0) AND m.sender_id != ?`)
    .get(userId, userId);
  return r ? r.n : 0;
}

/**
 * 把一条新消息推送到"此刻没连着 WebSocket 的人"的手机上（iOS 专用链路）。
 *
 * 三条纪律：
 *   ① 在线的人**不推** —— 消息已经实时到了，再推就是重复打扰；
 *   ② 自己发的不推 —— 多端登录时自己的其他端靠 WS 同步，不需要通知；
 *   ③ 全程 try/catch + 不 await —— 推送是"锦上添花"，**任何情况下都不能
 *      让发消息这个动作变慢或失败**。APNs 抖动时投递结果只落 push_log。
 *
 * 标题/正文都在这里算（而不是在 push.js 里）：会话名、好友备注、消息类型
 * 都是聊天的产品语义，只有这一层持有。
 */
function notifyPush(full) {
  try {
    if (!push.enabled()) return;
    const convId = full.conversation_id;
    const sender = db.prepare('SELECT id, username, nickname FROM users WHERE id = ?').get(full.sender_id);
    const senderName = sender ? (sender.nickname || sender.username) : '有人';
    const isGroup = db.prepare('SELECT type FROM conversations WHERE id = ?').get(convId)?.type === 'group';
    const members = db.prepare('SELECT user_id FROM conversation_members WHERE conversation_id = ?').all(convId);
    const preview = previewOf(full);

    for (const m of members) {
      if (m.user_id === full.sender_id) continue;
      if (hub.isUserOnline(m.user_id)) continue;
      // 单聊标题取"接收方视角的会话名"——对方给我起的备注应该出现在我的锁屏上
      const conv = conversationTitle(convId, m.user_id);
      const title = conv.title || senderName;
      push.sendToUser(m.user_id, {
        title: String(title).slice(0, 64),
        body: (isGroup ? senderName + '：' : '') + preview,
        // 同一会话的多条合并成一条，群里刷屏不至于把人手机震没电
        collapseId: 'conv-' + convId,
        threadId: 'conv-' + convId,
        badge: unreadCount(m.user_id),
        data: {
          type: 'message',
          conversationId: convId,
          messageId: full.id,
          senderId: full.sender_id,
        },
      }).catch(() => { /* 已落 push_log，这里不再上抛 */ });
    }
  } catch { /* 推送绝不能影响消息本身 */ }
}

/**
 * 断线期间错过的消息（WS 重连后补推用）。
 *
 * 背景（龙哥 2026-10-14 报：PC 与手机聊天记录对不上、丢两条）：
 * hub.send() 对 readyState 不是 OPEN 的 socket 是**静默丢弃**的 —— 没有离线队列；
 * 客户端重连成功后也不会补拉。于是"断线窗口内"别人发来的消息就永久丢了，
 * 除非用户手动重新打开会话页（chat 页的 _loadMsgs 才会拉到）。
 *
 * 补推口径：afterId 是**连接自己申报的**"我已见过的最大消息 id"（客户端维护，
 * 见 client/lib/socket.dart 的 maxSeenMessageId）。服务端不猜、也不按
 * last_read_id 算 —— "已读未读"是产品语义，"见过没有"才是投递语义，
 * 两者不是一回事（把已读消息也补回来是安全的：客户端按 id 幂等去重）。
 *
 * 包含自己其他端发的消息：多端同步需要（手机发的，PC 要能收到）。
 * LIMIT 500 防极端情况（半年不上线）一次推爆连接。
 */
function missedMessages(userId, afterId) {
  const after = Number(afterId) || 0;
  const rows = db.prepare(`SELECT m.* FROM messages m
      JOIN conversation_members cm
        ON cm.conversation_id = m.conversation_id AND cm.user_id = ?
      WHERE m.id > ? AND m.deleted = 0
      ORDER BY m.id ASC LIMIT 500`)
    .all(userId, after);
  return rows.map(withFileInfo);
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
  // 全员禁言：普通成员一律不能发言（群主/管理员/系统管理员豁免）
  if (mutedAllBlock(conversationId, senderId) === true) {
    throw new Error('群主已开启全员禁言，暂时无法发言');
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

  // 「文件助手」是自己↔自己的会话：广播**不能**排除发送者。
  // 排除了就一个接收者都不剩 —— 手机上传的文件，电脑上要手动刷新才看得到，
  // 那这功能就白做了。客户端按消息 id 幂等去重，收到自己刚发的那条不会重复渲染。
  const convType = db.prepare('SELECT type FROM conversations WHERE id = ?').get(conversationId)?.type;
  const excludeSelf = convType === 'filehelper' ? null : senderId;
  hub.broadcastToConversation(db, conversationId, { type: 'message:new', message: full }, excludeSelf);
  // 推给不在线的人（iOS 后台收不到 WS，只能靠通知）
  notifyPush(full);
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

  // 告诉会话内所有人"我读到哪了"。
  // 🔴 2026-10-12 修复：原来第 4 个参数传了 userId，把自己排除在外 ——
  // 结果自己读完一条消息后，自己的会话列表和底部红点不会刷新
  // （conversations.dart 只在收到 message:read 才重算未读角标，而自己收不到自己的）。
  // 改成发给所有人：聊天页收到自己的事件已在 chat.dart:335 用 uid==myId 拦掉，
  // 不会误渲染；会话列表收到后会重算角标，红点立刻消失；
  // 还顺带修好了同一账号多端登录时红点不同步的问题。
  hub.broadcastToConversation(db, conversationId, {
    type: 'message:read',
    conversationId,
    userId,
    lastReadId: target,
  }, null);

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
 * 已读回执：给定一条消息 id，返回发送者、会话类型、以及每个"接收人"
 * （除发送者外的会话成员）是否已读（last_read_id >= 该消息 id 即视为已读）。
 *
 * 口径与 markRead 完全一致——"已读"指"打开会话把水位推过这条消息"，
 * 不是"在通知里瞥了一眼"。管理员后台「谁看了」与「发消息的人长按自己消息查看」
 * 共用同一套口径，避免两套逻辑各算各的。
 *
 * 接收人不包含发送者本人：自己发的自己肯定已读，不计入"谁看了"，
 * 这样群聊里 N/共 M 的 M 是"真正要读这条消息的其他人"。
 */
function readReceipt(messageId) {
  const msg = db.prepare('SELECT id, conversation_id, sender_id, kind, content, created_at FROM messages WHERE id=?')
    .get(messageId);
  if (!msg) return null;
  const conv = db.prepare('SELECT id, type FROM conversations WHERE id=?').get(msg.conversation_id);
  const sender = db.prepare('SELECT id, username, nickname, avatar, is_bot FROM users WHERE id=?').get(msg.sender_id);
  const members = db.prepare(`SELECT cm.user_id, cm.last_read_id, u.username, u.nickname, u.avatar, u.is_bot
    FROM conversation_members cm JOIN users u ON u.id = cm.user_id
    WHERE cm.conversation_id = ?`).all(msg.conversation_id);
  const mk = (m) => ({
    id: m.user_id,
    name: m.nickname || m.username,
    avatar: m.avatar || null,
    isBot: !!m.is_bot,
    lastReadId: m.last_read_id || 0,
    read: (m.last_read_id || 0) >= messageId,
  });
  // 接收人 = 除发送者外的成员（自己发的自己肯定已读，不计入"谁看了"）
  const recipients = members.filter((m) => m.user_id !== msg.sender_id);
  const readList = recipients.filter((m) => (m.last_read_id || 0) >= messageId).map(mk);
  const unreadList = recipients.filter((m) => (m.last_read_id || 0) < messageId).map(mk);
  return {
    messageId,
    conversationId: msg.conversation_id,
    conversationType: conv?.type || null,
    sender: sender
      ? { id: sender.id, name: sender.nickname || sender.username, avatar: sender.avatar || null, isBot: !!sender.is_bot }
      : null,
    kind: msg.kind,
    content: msg.kind === 'text' ? (msg.content || '') : `[${msg.kind}]`,
    createdAt: msg.created_at,
    total: recipients.length,
    readCount: readList.length,
    unreadCount: unreadList.length,
    read: readList,
    unread: unreadList,
  };
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
  // 「文件助手」：自己↔自己，标题固定，客户端也照这个名字渲染
  if (c.type === 'filehelper') return { id: c.id, type: 'filehelper', title: '文件助手' };
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
    notifyPush(full);
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
  recallMessage, markRead, typing, readState, readReceipt,
  conversationTitle, searchMessages, remarkOf,
  forwardMessage, togglePin, pinnedMessage, canPin,
  addFavorite, removeFavorite, listFavorites,
  normalizeMentions, mutedUntilOf, parseMentions, serializeMentions, mentionLike,
  normalizeCard,
  previewOf, unreadCount, notifyPush, missedMessages,
  RECALL_WINDOW_MS, KINDS, CARD_COLORS, MAX_TEXT_LEN, MENTION_ALL,
};
