/**
 * 全员群 —— 工作模式下由服务端自动建、自动维护成员的那个群。
 *
 * 为什么要它（2026-10-27 龙哥提）：
 *   切到工作模式后，管理员得自己建一个群、再一个一个把几十号人拉进来；
 *   之后每来一个新员工要记得拉、每走一个人要记得踢。**这件事一定会忘**，
 *   忘了的后果是"新同事在群里看不到通知""离职的人还在接收公司消息"。
 *   所以它不该是手工流程，而应该是组织结构的副产品：
 *     切工作模式 → 建群；入职 → 进群；离职 → 退群。
 *
 * 三个刻意的设计选择：
 *   1) **用 groups.is_org_group 标记，不记 id 在 settings** —— settings 会被免鉴权的
 *      bootstrap 铺出去，群里的事没必要也不适合放在那儿；用列还能防"记串了 id"。
 *   2) **幂等**：ensure() 可反复调用，补人/清人都只动差额，不会重复建群、不会刷屏广播。
 *   3) **只维护成员，不改群本身** —— 群名/公告/禁言这些是管理员的，服务端不碰。
 *      手动解散了也不报错，下次 ensure 会重建一个（比"永远建不起来"好）。
 */
const db = require('./db');
const hub = require('./hub');

const GROUP_NAME = '全员群';

function theOrg() {
  return db.prepare('SELECT id, name, created_by FROM orgs ORDER BY id LIMIT 1').get();
}

/** 当前的全员群（没有则 null） */
function groupRow() {
  return db.prepare('SELECT id, name, owner_id, conversation_id FROM groups WHERE is_org_group=1 ORDER BY id LIMIT 1').get();
}

/**
 * 该在全员群里的人：组织内员工 + 所有系统管理员。
 * 管理员必须显式带上：他们的 org_id 是 NULL（管理员不属于任何组织），
 * 只按 org_id 筛的话群主自己会掉出去。
 */
function shouldBeIn(orgId) {
  return db.prepare("SELECT id FROM users WHERE org_id=? OR role='admin'").all(orgId).map((r) => r.id);
}

function notify(g, action = 'member') {
  hub.broadcastToConversation(db, g.conversation_id, {
    type: 'group:updated', groupId: g.id, conversationId: g.conversation_id, action,
  }, null);
}

/** 建群（4 步写入必须原子，与 routes/groups.js 建群同款 —— 只有 conversation_members
 *  没有 group_members 的后果是"列表里看得到群、永远收不到消息"） */
function create(org) {
  const ownerId = org.created_by;
  db.exec('BEGIN');
  let cid, gid;
  try {
    cid = db.prepare("INSERT INTO conversations (type,created_at) VALUES ('group',?)")
      .run(Date.now()).lastInsertRowid;
    gid = db.prepare('INSERT INTO groups (name,owner_id,conversation_id,created_at,is_org_group) VALUES (?,?,?,?,1)')
      .run(GROUP_NAME, ownerId, cid, Date.now()).lastInsertRowid;
    db.prepare('INSERT INTO group_members (group_id,user_id,role,joined_at) VALUES (?,?,?,?)')
      .run(gid, ownerId, 'owner', Date.now());
    db.prepare('INSERT INTO conversation_members (conversation_id,user_id) VALUES (?,?)')
      .run(cid, ownerId);
    db.exec('COMMIT');
  } catch (e) {
    db.exec('ROLLBACK');
    throw e;
  }
  console.log(`[小智IM] 已创建全员群 group=${gid} conv=${cid}（群主 ${ownerId}）`);
  return { id: gid, name: GROUP_NAME, owner_id: ownerId, conversation_id: cid };
}

function addRaw(g, userId) {
  try {
    db.prepare('INSERT OR IGNORE INTO group_members (group_id,user_id,role,joined_at) VALUES (?,?,?,?)')
      .run(g.id, userId, 'member', Date.now());
    db.prepare('INSERT OR IGNORE INTO conversation_members (conversation_id,user_id) VALUES (?,?)')
      .run(g.conversation_id, userId);
    return true;
  } catch (e) {
    console.warn(`[小智IM] 全员群加人失败 user=${userId}: ${e.message}`);
    return false;
  }
}

function removeRaw(g, userId) {
  const a = db.prepare('DELETE FROM group_members WHERE group_id=? AND user_id=?').run(g.id, userId).changes;
  const b = db.prepare('DELETE FROM conversation_members WHERE conversation_id=? AND user_id=?')
    .run(g.conversation_id, userId).changes;
  return a + b > 0;
}

/**
 * 补齐/清理成员（只动差额）。返回 {added, removed}。
 * 管理员手动踢人后又被这里加回来是**故意的**：全员群的定义就是"组织里所有人都在"，
 * 想让人干净地离开，应该走"移出组织"，而不是在群里踢一脚。
 */
function sync(g) {
  const grp = g || groupRow();
  if (!grp) return { added: 0, removed: 0 };
  const org = theOrg();
  if (!org) return { added: 0, removed: 0 };

  const want = new Set(shouldBeIn(org.id));
  want.add(grp.owner_id);
  const have = new Set(db.prepare('SELECT user_id FROM group_members WHERE group_id=?').all(grp.id)
    .map((r) => r.user_id));

  let added = 0;
  let removed = 0;
  for (const uid of want) {
    if (!have.has(uid) && addRaw(grp, uid)) {
      added++;
      hub.broadcastToUser(uid, { type: 'group:invited', groupId: grp.id, conversationId: grp.conversation_id });
    }
  }
  for (const uid of have) {
    if (!want.has(uid) && uid !== grp.owner_id && removeRaw(grp, uid)) {
      removed++;
      hub.broadcastToUser(uid, {
        type: 'group:updated', groupId: grp.id, conversationId: grp.conversation_id, action: 'member',
      });
    }
  }
  if (added || removed) {
    notify(grp);
    console.log(`[小智IM] 全员群同步：+${added} -${removed}`);
  }
  return { added, removed };
}

/** 建群（没有就建）+ 全员归位。切工作模式时调用。 */
function ensure() {
  const org = theOrg();
  if (!org) return { skipped: 'no-org' };
  let g = groupRow();
  if (!g) g = create(org);
  const r = sync(g);
  return { groupId: g.id, conversationId: g.conversation_id, groupName: g.name, ...r };
}

/** 单个入职：进全员群（没有全员群就先建——工作模式下总会有人先进来） */
function addOne(userId) {
  if (!userId) return;
  const org = theOrg();
  if (!org) return;
  let g = groupRow();
  if (!g) g = create(org);
  if (addRaw(g, userId)) {
    notify(g);
    hub.broadcastToUser(userId, { type: 'group:invited', groupId: g.id, conversationId: g.conversation_id });
    console.log(`[小智IM] 全员群：user=${userId} 入群`);
  }
}

/** 单个离职：退出全员群。用户本身不动（他被移出组织是另一件事），只是不在群里了。 */
function removeOne(userId) {
  if (!userId) return;
  const g = groupRow();
  if (!g) return;
  if (g.owner_id === userId) return; // 群主不踢，否则群就没人管了
  if (removeRaw(g, userId)) {
    notify(g);
    // 客户端认 group:updated 会重拉会话列表，此时群里已经没有他 → 群从列表消失
    hub.broadcastToUser(userId, {
      type: 'group:updated', groupId: g.id, conversationId: g.conversation_id, action: 'member',
    });
    console.log(`[小智IM] 全员群：user=${userId} 退群`);
  }
}

module.exports = { ensure, sync, addOne, removeOne, groupRow, GROUP_NAME };
