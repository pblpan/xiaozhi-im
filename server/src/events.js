// 事件总线：把 IM 内部动作翻译成对外事件，交给 dispatcher 投递
//
// 所有 emit 都必须是「安全」的：调用方在消息主流程里，事件出错绝不能影响发消息。
const db = require('./db');
const dispatcher = require('./dispatcher');

/** 对外事件清单（管理后台下拉框、文档都用这份） */
const EVENTS = [
  { name: 'message.created', desc: '有新消息（含文字/图片/文件/语音/卡片）' },
  { name: 'message.mention', desc: '消息里 @了人（含 @所有人）' },
  { name: 'message.recalled', desc: '消息被撤回' },
  { name: 'message.edited', desc: '消息被编辑' },
  { name: 'member.joined', desc: '有成员加入群聊' },
  { name: 'member.left', desc: '有成员退出/被移出群聊' },
  { name: 'conversation.created', desc: '新建会话（单聊或群聊）' },
  { name: 'ping', desc: '测试事件（用于验证地址与签名）' },
];

const EVENT_NAMES = EVENTS.map((e) => e.name);

/** 会话概要（不含成员敏感信息，够外部系统定位即可） */
function convInfo(conversationId, selfId) {
  const c = db.prepare('SELECT id, type FROM conversations WHERE id = ?').get(Number(conversationId));
  if (!c) return null;
  if (c.type === 'group') {
    const g = db.prepare('SELECT id, name FROM groups WHERE conversation_id = ?').get(c.id);
    return { id: c.id, type: 'group', groupId: g ? g.id : null, title: g ? g.name : null };
  }
  const rows = db.prepare(`SELECT u.id, u.nickname, u.username FROM conversation_members cm
    JOIN users u ON u.id = cm.user_id WHERE cm.conversation_id = ?`).all(c.id);
  const peer = rows.find((u) => u.id !== selfId) || rows[0];
  return {
    id: c.id, type: 'dm',
    title: peer ? (peer.nickname || peer.username) : null,
    peerId: peer ? peer.id : null,
  };
}

/** 找出生效的订阅：active、订阅了该事件、且会话范围匹配 */
function matchingHooks(event, conversationId) {
  const hooks = db.prepare('SELECT * FROM outgoing_hooks WHERE active = 1').all();
  return hooks.filter((h) => {
    if (!dispatcher.hookWants(h, event)) return false;
    if (h.conversation_id && Number(h.conversation_id) !== Number(conversationId)) return false;
    return true;
  });
}

/**
 * 发一个事件。
 * @param {string} event 事件名，见 EVENTS
 * @param {object} opts  { conversationId, selfId, data }
 * @returns {number} 生成的投递条数（0 = 没人订阅）
 */
function emit(event, { conversationId = null, selfId = null, data = {} } = {}) {
  try {
    const hooks = matchingHooks(event, conversationId);
    if (!hooks.length) return 0;

    const payload = {
      event,
      ts: Date.now(),
      conversation: conversationId ? convInfo(conversationId, selfId) : null,
      data: data || {},
    };
    let n = 0;
    for (const hook of hooks) {
      // deliveryId 由 dispatcher 落库后回填，保证 body 与 header 一致
      dispatcher.enqueue(hook, event, { ...payload, hook: hook.name });
      n++;
    }
    return n;
  } catch (e) {
    console.warn('[小智IM] 事件投递失败(已忽略):', event, e.message);
    return 0;
  }
}

/** 消息对象 → 对外精简结构（去掉内部字段，补上发送者名字与是否机器人） */
function publicMessage(m, senderName, senderIsBot) {
  if (!m) return null;
  return {
    id: m.id,
    conversationId: m.conversation_id,
    senderId: m.sender_id,
    senderName: senderName || null,
    senderIsBot: !!senderIsBot,
    kind: m.kind,
    content: m.deleted ? null : m.content,
    fileId: m.file_id || null,
    fileUrl: m.file_url || null,
    mentions: Array.isArray(m.mentions) ? m.mentions : [],
    edited: !!m.edited,
    deleted: !!m.deleted,
    createdAt: m.created_at,
  };
}

/** 发消息后触发（含被 @ 的定向事件） */
function emitMessageCreated(msg) {
  const s = db.prepare('SELECT nickname, username, is_bot FROM users WHERE id = ?').get(msg.sender_id);
  const senderName = s ? (s.nickname || s.username) : null;
  const body = publicMessage(msg, senderName, s && s.is_bot);
  const n = emit('message.created', {
    conversationId: msg.conversation_id,
    selfId: msg.sender_id,
    data: { message: body },
  });
  // 被 @ 到的人单独收一份，外部系统可以只对"点名"做提醒
  const mentions = Array.isArray(msg.mentions) ? msg.mentions : [];
  if (mentions.length) {
    emit('message.mention', {
      conversationId: msg.conversation_id,
      selfId: msg.sender_id,
      data: { message: body, mentions },
    });
  }
  return n;
}

module.exports = { EVENTS, EVENT_NAMES, emit, emitMessageCreated, convInfo, publicMessage };
