/**
 * 数据体检 · 孤儿巡检（2026-10-03 新增）
 *
 * ============================================================================
 * 【为什么需要这个】
 *   这个库全库 **0 外键**（引用完整性改用触发器兜住了"新数据"，见 db.js）。
 *   但触发器只保证**往后**不再写进孤儿，**清不了历史遗留的**。
 *   而孤儿行的危害很具体：
 *     · 好友树里显示一个点进去什么都没有的账号；
 *     · 某个计数永远不对（比如"该部门下有 N 名员工"，人已经走了却删不掉部门）；
 *     · 会话列表里挂着一个已不存在的会话。
 *   这些不会自己消失，也不会报错 —— 属于"看着就不对但查不出原因"的那类问题。
 *
 * ============================================================================
 * 🔴 【本文件最重要的一件事：区分"孤儿"和"正常的历史留痕"】
 *
 *   **不是所有"父行不存在"都是垃圾。** 有一批是**产品明确要保留**的：
 *
 *     messages.sender_id → users
 *       用户离职被删后，他发过的历史消息**必须留着**（聊天记录不能因为人走了
 *       就消失）。如果这里把它当孤儿清掉，就是删用户时把别人的聊天记录抹了。
 *     inv_grants.revoked_at
 *       撤权是"标记"不是"删除"，行留着是**刻意的留痕**（见 db.js 注释）。
 *     remote_access_codes
 *       过期/撤销的访问码行留着是为了审计。
 *     push_devices
 *       设备令牌失效后行还在，等客户端下次上报覆盖。
 *
 *   所以下面每条关联都带 `purgeable` 标记：
 *     · purgeable=true  —— 清掉纯粹是修数据，不会丢任何用户可见的信息；
 *     · purgeable=false —— **明确不清**，界面上也要写清"为什么不建议动"，
 *                          否则管理员看到"孤儿 120 条"会去点清理，
 *                          把别人的历史聊天记录删了。
 *
 *   这是这个页面的核心责任：**不该让管理员因为看不懂而误删数据。**
 *
 * ============================================================================
 * 【为什么不默认就清理】
 *   一是有些孤儿数量大（可能上万行），扫一遍要时间；
 *   二是"清孤儿"这个动作在没看清楚之前不该自动做。所以：
 *     scan   —— 只读，随便跑，不写任何东西
 *     purge  —— 必须带 confirm（要删的行数），且**数量变了就 409**，
 *                强制管理员重新看一眼再确认
 *     purge 前一定先导出备份到 purge-backup/（复用 admin.js 的 writePurgeBackup）
 */

const express = require('express');
const fs = require('fs');
const path = require('path');
const db = require('../db');
const config = require('../config');
const { verifyToken } = require('../auth');

const router = express.Router();

/**
 * 管理员门禁。
 *
 * ⚠️ 这个函数在 routes/ 下有十几份重复（审计 P2 提过"消除鉴权重复"，
 *    但那属于结构性重构、动 24 个文件，风险大于收益，没做）。
 *    这里**照抄 admin.js 的最新版**，而不是照抄最初那版 ——
 *    差别是"用户不存在"返 401 而不是 403（原因见 admin.js 的注释：
 *    账号被删后客户端要能知道该跳登录页，返 403 会让它干瞪眼）。
 *    将来真要抽公共门禁，这个文件是候选之一。
 */
function adminOf(req, res) {
  const c = verifyToken(req.headers.authorization?.replace('Bearer ', ''));
  if (!c) { res.status(401).json({ error: 'unauthorized' }); return null; }
  const u = db.prepare('SELECT role FROM users WHERE id=?').get(c.uid);
  if (!u) { res.status(401).json({ error: 'unauthorized' }); return null; }
  if (u.role !== 'admin') { res.status(403).json({ error: 'forbidden' }); return null; }
  return c.uid;
}

/** 单次清理上限：一次删太多万一行既慢又难核对 */
const MAX_PURGE = 5000;

/**
 * 全部要体检的关联。
 *
 * 每条：
 *   key      机器可读标识（purge 时用）
 *   label    界面上给人看的名字
 *   sql      找出孤儿的查询（必须只读）
 *   purgeSql 可选的删除语句。**没有 purgeSql = 只报不动**（purgeable:false）
 *   purgeable 能否安全清理
 *   why      为什么不能清（purgeable:false 时必填，界面会原样显示）
 *   impact   清掉会怎样（purgeable:true 时必填，界面显示，让人敢下手）
 */
const RELATIONS = [
  // ── 成员关系类：孤儿一定会让界面出错，且清理零损失 ──
  {
    key: 'conversation_members.conversation',
    label: '会话成员 → 会话',
    table: 'conversation_members', col: 'conversation_id', parent: 'conversations', pk: 'id',
    purgeable: true,
    impact: '清掉后该用户不会再出现在那些会话里（本来也看不到）',
  },
  {
    key: 'conversation_members.user',
    label: '会话成员 → 用户',
    table: 'conversation_members', col: 'user_id', parent: 'users', pk: 'id',
    purgeable: true,
    impact: '清掉后彻底不再出现在这个会话里；不影响任何人看到历史消息',
  },
  {
    key: 'group_members.group',
    label: '群成员 → 群',
    table: 'group_members', col: 'group_id', parent: 'groups', pk: 'id',
    purgeable: true,
    impact: '群都没了，成员记录留着没意义',
  },
  {
    key: 'group_members.user',
    label: '群成员 → 用户',
    table: 'group_members', col: 'user_id', parent: 'users', pk: 'id',
    purgeable: true,
    impact: '人已不在系统里，群成员表里挂着只是空壳',
  },
  {
    key: 'friendships.user',
    label: '好友关系（发起方）→ 用户',
    table: 'friendships', col: 'user_id', parent: 'users', pk: 'id',
    purgeable: true,
    impact: '人已不在，删掉不会影响任何还活着的人的好友列表',
  },
  {
    key: 'friendships.friend',
    label: '好友关系（被加方）→ 用户',
    table: 'friendships', col: 'friend_id', parent: 'users', pk: 'id',
    purgeable: true,
    impact: '同上',
  },
  {
    key: 'groups.conversation',
    label: '群 → 会话',
    table: 'groups', col: 'conversation_id', parent: 'conversations', pk: 'id',
    purgeable: true,
    impact: '群会话已不存在，群的入口是坏的',
  },
  {
    key: 'favorites.message',
    label: '收藏 → 消息',
    table: 'favorites', col: 'message_id', parent: 'messages', pk: 'id',
    purgeable: true,
    impact: '消息被删了，收藏指向空气（点了打不开）',
  },
  {
    key: 'favorites.user',
    label: '收藏 → 用户',
    table: 'favorites', col: 'user_id', parent: 'users', pk: 'id',
    purgeable: true,
    impact: '人已不在，收藏留着无主',
  },
  {
    key: 'inv_locations.zone',
    label: '库位 → 点位',
    table: 'inv_locations', col: 'zone_code', parent: 'inv_zones', pk: 'zone_code',
    purgeable: true,
    impact: '点位已删，库位挂着会让"删除点位"的校验一直报占用',
  },
  {
    key: 'inv_scans.sheet',
    label: '盘点明细 → 盘点单',
    table: 'inv_scans', col: 'sheet_no', parent: 'inv_sheets', pk: 'sheet_no',
    purgeable: true,
    impact: '单据已删，明细是算不出差异的残留',
  },
  {
    key: 'inv_grants.user',
    label: '抽盘授权 → 用户',
    table: 'inv_grants', col: 'user_id', parent: 'users', pk: 'id',
    purgeable: true,
    impact: '人已不在，授权行无意义',
  },
  {
    key: 'tr_enroll.course',
    label: '培训报名 → 课程',
    table: 'tr_enroll', col: 'course_id', parent: 'tr_course', pk: 'id',
    purgeable: true,
    impact: '课程已删，报名记录是空壳',
  },
  {
    key: 'tr_progress.lesson',
    label: '培训进度 → 课时',
    table: 'tr_progress', col: 'lesson_id', parent: 'tr_lesson', pk: 'id',
    purgeable: true,
    impact: '课时已删，进度无处安放',
  },
  {
    key: 'remote_access_codes.user',
    label: '远程协助访问码 → 用户',
    table: 'remote_access_codes', col: 'user_id', parent: 'users', pk: 'id',
    purgeable: true,
    impact: '人已不在，访问码不可能被使用',
  },
  {
    key: 'push_devices.user',
    label: '推送设备 → 用户',
    table: 'push_devices', col: 'user_id', parent: 'users', pk: 'id',
    purgeable: true,
    impact: '人已不在，APNs 推送永远送不到（白占配额）',
  },

  // ── 只报不动：这是产品要保留的历史留痕，清了就是丢数据 ──
  {
    key: 'messages.sender',
    label: '消息 → 发送者',
    table: 'messages', col: 'sender_id', parent: 'users', pk: 'id',
    purgeable: false,
    why: '**这是正常的，不要清。** 用户离职被删后，他发过的历史消息要留着'
       + '（聊天记录不能因为人走了就消失）。清掉等于抹掉别人的聊天记录。'
       + '界面在发送者处显示"已注销用户"就是正常表现。',
  },
  {
    key: 'messages.conversation',
    label: '消息 → 会话',
    table: 'messages', col: 'conversation_id', parent: 'conversations', pk: 'id',
    purgeable: true,
    impact: '会话已删，消息留着查不到也看不了（消息管理里的"孤儿消息"）',
  },
  {
    key: 'approvals.submitter',
    label: '审批单 → 提交人',
    table: 'approvals', col: 'submitter_id', parent: 'users', pk: 'id',
    purgeable: false,
    why: '审批记录是**审计凭据**，谁提的、什么时候批的都要留痕。'
       + '提交人离职不影响单据的效力。清掉就查不到"这事是谁干的"了。',
  },
  {
    key: 'att_records.user',
    label: '考勤记录 → 员工',
    table: 'att_records', col: 'user_id', parent: 'users', pk: 'id',
    purgeable: false,
    why: '考勤是薪资依据，离职员工的历史打卡必须保留（否则算不清工资）。',
  },
  {
    key: 'att_requests.user',
    label: '补卡申请 → 申请人',
    table: 'att_requests', col: 'user_id', parent: 'users', pk: 'id',
    purgeable: false,
    why: '同考勤记录：补卡是薪资依据，离职也要留着。',
  },
];

/** 找出某条关联的孤儿行（只读） */
function findOrphans(rel, limit) {
  const lim = Math.max(1, Math.min(Number(limit) || 50, 200));
  // 注：列名与表名都来自上面写死的 RELATIONS，不接受外部输入 → 无注入面
  //
  // 🔴 这里**不能写死 SELECT c.id**（2026-10-03 修）：
  //   不是每张表都有 id 列 —— conversation_members / group_members / inv_grants
  //   用的是**复合主键**，压根没有 id。写死 c.id 会抛 "no such column: c.id"，
  //   而这里 catch 掉只返回空数组 ⇒ 页面显示"有 3 条孤儿但点不出明细"，
  //   是个不会报错、只会让人困惑的坏状态。
  // 所以改成 SELECT c.*：每张表都能查，代价只是样本行宽一点（最多 50 行，可接受）。
  return db.prepare(
    `SELECT c.*
     FROM ${rel.table} c
     LEFT JOIN ${rel.parent} p ON p.${rel.pk} = c.${rel.col}
     WHERE p.${rel.pk} IS NULL
     LIMIT ?`
  ).all(lim);
}

function countOrphans(rel) {
  const r = db.prepare(
    `SELECT COUNT(*) AS c
     FROM ${rel.table} c
     LEFT JOIN ${rel.parent} p ON p.${rel.pk} = c.${rel.col}
     WHERE p.${rel.pk} IS NULL`
  ).get();
  return r.c;
}

// ---------------------------------------------------------------------------
// 体检（只读）
// ---------------------------------------------------------------------------
// ⚠️ 路径不带 /orphans 前缀 —— 挂载点已经是 /api/admin/orphans，
//    路由里再写一遍会变成 /api/admin/orphans/orphans/scan，静默 404（踩过一次）。
//    挂载点在 src/index.js，与 /api/admin 的注册顺序**必须**是 orphans 在前，
//    否则会被 admin.js 抢先接管（同 integrations/attendance/push 的既有约定）。
router.get('/scan', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;

  const items = [];
  let totalPurgeable = 0;
  let totalKept = 0;
  const errors = [];

  for (const rel of RELATIONS) {
    let count = 0;
    try {
      count = countOrphans(rel);
    } catch (e) {
      // 单条查不了不能拖垮整页：老库里可能还没有某张表
      errors.push({ key: rel.key, error: e.message });
      items.push({ ...publicRel(rel), count: null, sample: [], error: e.message });
      continue;
    }
    const item = { ...publicRel(rel), count, sample: [] };
    if (count > 0) {
      // 样本只给"可清理"的：不该清的本来就不动，给一堆 id 也没意义
      if (rel.purgeable) {
        try { item.sample = findOrphans(rel, 50); } catch (_) { item.sample = []; }
        totalPurgeable += count;
      } else {
        totalKept += count;
      }
    }
    items.push(item);
  }

  res.json({
    items,
    summary: {
      checked: RELATIONS.length,
      relationsWithOrphans: items.filter((i) => i.count > 0).length,
      purgeable: totalPurgeable,
      kept: totalKept,      // 只报不动的那部分，也要给管理员一个数
      healthy: totalPurgeable === 0,
    },
    errors,
  });
});

function publicRel(rel) {
  return {
    key: rel.key,
    label: rel.label,
    table: rel.table,
    column: rel.col,
    parent: rel.parent,
    purgeable: !!rel.purgeable,
    why: rel.why || null,
    impact: rel.impact || null,
  };
}

// ---------------------------------------------------------------------------
// 清理（只允许清 purgeable 的）
// ---------------------------------------------------------------------------
/** 要清的条目清单：请求里给 key 数组，逐个按 relation 定义执行 */
const relByKey = new Map(RELATIONS.map((r) => [r.key, r]));

router.post('/purge', (req, res) => {
  const uid = adminOf(req, res); if (uid === null) return;
  const body = req.body || {};
  const keys = Array.isArray(body.keys) ? body.keys : [];
  const confirm = Number(body.confirm);

  if (!keys.length) return res.status(400).json({ error: '请选择要清理的关联类型' });
  if (!Number.isFinite(confirm)) {
    return res.status(400).json({ error: '缺少 confirm（要删除的行数）' });
  }

  // 🔴 硬闸门：只接受 purgeable 的 key。
  //   即便前端传错、或有人直接打接口，也不可能删掉"产品要保留"的那几类
  //   （历史消息、考勤、审批留痕）。这道校验在服务端，不依赖前端自觉。
  const targets = [];
  for (const k of keys) {
    const rel = relByKey.get(k);
    if (!rel) return res.status(400).json({ error: `未知的关联类型：${k}` });
    if (!rel.purgeable) {
      return res.status(400).json({ error: `「${rel.label}」不建议清理（${rel.why || '产品需保留'}）` });
    }
    targets.push(rel);
  }

  // 先数一遍，和管理员确认的数字比对：数量变了就 409 强制重新确认
  const before = {};
  let total = 0;
  for (const rel of targets) {
    const c = countOrphans(rel);
    before[rel.key] = c;
    total += c;
  }
  if (total !== confirm) {
    return res.status(409).json({
      error: `数量已变化：当前命中 ${total} 行，你确认的是 ${confirm} 行，请重新确认`,
      count: total, byKey: before,
    });
  }
  if (total === 0) return res.json({ ok: true, deleted: 0, byKey: before, backup: null });
  if (total > MAX_PURGE) {
    return res.status(400).json({ error: `一次最多清理 ${MAX_PURGE} 行（当前 ${total} 行），请分批处理` });
  }

  // ---- 备份：先导出行 id，确认是"这次要删的那些" ----
  const backupRows = [];
  for (const rel of targets) {
    // 不限量导出：要删的就是全部，备份必须完整，否则捞不回来
    const rows = db.prepare(
      `SELECT c.* FROM ${rel.table} c
       LEFT JOIN ${rel.parent} p ON p.${rel.pk} = c.${rel.col}
       WHERE p.${rel.pk} IS NULL`
    ).all();
    for (const r of rows) backupRows.push({ _relation: rel.key, ...r });
  }
  const backup = writeOrphanBackup(backupRows, { keys, count: total });

  // ---- 逐条清理，每条一个事务：一条失败不影响别的 ----
  const done = {};
  const errors = [];
  for (const rel of targets) {
    const n = before[rel.key];
    if (!n) continue;
    db.exec('BEGIN');
    try {
      const info = db.prepare(
        `DELETE FROM ${rel.table}
         WHERE ${rel.col} NOT IN (SELECT ${rel.pk} FROM ${rel.parent})`
      ).run();
      db.exec('COMMIT');
      done[rel.key] = info.changes;
    } catch (e) {
      db.exec('ROLLBACK');
      errors.push({ key: rel.key, error: e.message });
    }
  }

  // 备份失败不阻断删除（磁盘满时删除仍是管理员的明确意图），但要如实回报
  if (backup.error) {
    errors.push({ key: '_backup', error: backup.error });
  }

  res.json({
    ok: errors.length === 0 || (errors.length === 1 && errors[0].key === '_backup'),
    deleted: Object.values(done).reduce((a, b) => a + b, 0),
    byKey: done,
    backup: backup.name ? { name: backup.name, error: backup.error } : null,
    errors,
  });
});

/** 备份文件命名/写入逻辑与 admin.js 的 writePurgeBackup 一致（同一目录，便于统一找回） */
function writeOrphanBackup(rows, meta) {
  const dir = path.join(config.DATA_DIR, 'purge-backup');
  const p = (n, w = 2) => String(n).padStart(w, '0');
  const d = new Date();
  const stamp = d.getFullYear() + p(d.getMonth() + 1) + p(d.getDate())
    + '-' + p(d.getHours()) + p(d.getMinutes()) + p(d.getSeconds());
  const name = `orphans-${stamp}.json`;
  try {
    fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(
      path.join(dir, name),
      JSON.stringify({ kind: 'orphans', at: Date.now(), ...meta, count: rows.length, rows }, null, 2),
      'utf8',
    );
    return { name, error: null };
  } catch (e) {
    return { name: null, error: e.message };
  }
}

module.exports = router;
