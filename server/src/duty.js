'use strict';

/**
 * 排班引擎（自定义模块「排班表」三件套的数据那一件）
 *
 * ─────────────────────────────────────────────────────────────
 * 它解决的是什么问题
 * ─────────────────────────────────────────────────────────────
 * 之前「自定义模块」只有界面没有数据：管理员在管理台点一下「排班表」模板，
 * 手机上得到一副空表格 —— **加数据的地方根本没有**。排班这件事因此
 * 在整个产品里是断的。
 *
 * 这一层把排班做成"创建即有功能"：
 *   · 数据底座 duty_schedules（db.js），一天一人一行，改哪天就动哪天；
 *   · 班次不另起一套，直接引用考勤的 att_shifts（几点上下班/休息/跨天班
 *     都是现成的，且考勤判定用的就是它 —— 排的是考勤的班，不是纸上的班）；
 *   · 管理台周视图 / 手机表单 / 模块表格，三个入口共用本文件的同一组函数，
 *     口径只有一份。
 *
 * ─────────────────────────────────────────────────────────────
 * 三个入口，一个引擎
 * ─────────────────────────────────────────────────────────────
 *   ① 管理台周视图      → week() + save() + batchFill() + remove()
 *   ② 手机「排班」表单  → save()（表单提交经 /api/hooks/local/duty/schedules）
 *   ③ 模块表格取数      → listRange()（GET 同一个数据源）
 *
 * 都走本文件而不是各写一遍 SQL：写三遍的结果一定是"管理台改了手机上看不见"
 * "表单提交的和周视图算的不是一张表"，而这种不一致谁都说不清是哪边的错。
 *
 * ─────────────────────────────────────────────────────────────
 * 安全口径
 * ─────────────────────────────────────────────────────────────
 * 写操作只有两条路：管理台接口（admin 身份）或数据源 POST（源自己声明
 * write 权限）。本文件不判身份（那是路由层的活），但**所有输入都在这里校验：
 * 日期必须真实存在、人必须在这个组织、班次必须存在且没停用**。
 * 校验放在引擎而不是路由，是因为三个入口都必须过同一关 —— 放在路由层
 * 总有一个入口会漏。
 */

const db = require('./db');
const att = require('./attendance');

const MAX_NOTE = 200;
const MAX_POSITION = 60;
/** 批量填充一次最多动多少行：组织全员是常见输入，给个上限防手滑把一年的排班都覆了 */
const MAX_BATCH = 500;
/** 周视图/列表一次最多看多少天：手机上一屏的东西，不给"一次拉一年" */
const MAX_RANGE_DAYS = 93;

/**
 * 日期校验，复用考勤的 isValidDay。
 *
 * 🔴 为什么不自己写 /^\d{4}-\d{2}-\d{2}$/：那个正则会放过 '2026-13-45'，
 *     Date 归一化后它变成 2027-02-14，于是排班表里出现一条"2 月 14 日"
 *    而没人知道它是从 13 月 45 日来的。考勤那边已经栽过这个跟头
 *    （见 attendance.js isValidDay 的注释），这里直接借它的实现。
 */
function validDay(day) {
  const s = String(day == null ? '' : day).trim();
  return att.isValidDay(s) ? s : null;
}

/** 文本字段：trim + 限长 + 空串归一成 null（空串存进去比 NULL 难查得多） */
function textOf(v, max) {
  if (v === undefined || v === null) return null;
  const s = String(v).trim();
  if (!s) return null;
  return s.length > max ? s.slice(0, max) : s;
}

/**
 * 解析班次引用。shiftId 为空 = 休息（合法，返回 null）；不合法返回 { error }。
 *
 * 'rest'（不区分大小写）= 休息的显式哨兵：表单下拉里"休息"是一项，
 * 它的 value 不能是空串（客户端的必填校验会把空串当成"没填"），
 * 所以约定用 'rest' 这个词，引擎在这里翻译成"没有班次"。
 */
function shiftOf(orgId, shiftId) {
  if (shiftId === null || shiftId === undefined || shiftId === '') return null;
  if (typeof shiftId === 'string' && shiftId.trim().toLowerCase() === 'rest') return null;
  if (typeof shiftId === 'object') return { error: '班次只能是 id 或空（休息）' };
  const id = Number(shiftId);
  if (!Number.isInteger(id) || id <= 0) return { error: `班次 id 不合法：${shiftId}` };
  // 复用考勤的班次规范化（名称/时间段/跨天/休息都由它算），不自己拼字符串
  const s = att.listShifts(orgId).find((x) => x.id === id);
  if (!s) return { error: `组织下没有班次 #${id}（它可能已被删除）` };
  return s;
}

/** 班次的展示文本：「早班 08:00-17:00」。跨天班补一个"次日"，否则看着像写错了 */
function shiftText(s) {
  if (!s) return '休息';
  const end = s.crossDay ? `${s.workEnd}（次日）` : s.workEnd;
  return `${s.name} ${s.workStart}-${end}`;
}

/** 组织在册成员（周视图的行、批量填充的默认对象） */
function members(orgId) {
  return db.prepare(`
    SELECT u.id, u.username, u.nickname, u.employee_no, u.role,
      d.name AS dept_name, p.name AS position_name
    FROM users u
    LEFT JOIN org_depts d ON d.id = u.dept_id
    LEFT JOIN org_positions p ON p.id = u.position_id
    WHERE u.org_id = ?
    ORDER BY u.id`).all(Number(orgId)).map((r) => ({
    id: r.id,
    who: r.nickname || r.username || `用户${r.id}`,
    employeeNo: r.employee_no || r.username || '',
    dept: r.dept_name || '',
    position: r.position_name || '',
    isAdmin: r.role === 'admin',
  }));
}

/** 取一段日期内的排班（摊平行）。模块表格与管理台共用这一份形状 */
function listRange(orgId, fromDay, toDay) {
  const from = validDay(fromDay);
  const to = validDay(toDay);
  if (!from || !to) return { error: '日期范围不合法（需要 YYYY-MM-DD × 2）', code: 400 };
  if (from > to) return { error: '开始日期不能晚于结束日期', code: 400 };
  const rows = db.prepare(`
    SELECT s.id, s.day, s.user_id, s.shift_id, s.position, s.note, s.created_at,
      u.nickname, u.username, u.employee_no,
      sh.name AS shift_name, sh.work_start, sh.work_end, sh.cross_day, sh.enabled AS shift_enabled
    FROM duty_schedules s
    LEFT JOIN users u ON u.id = s.user_id
    LEFT JOIN att_shifts sh ON sh.id = s.shift_id
    WHERE s.org_id = ? AND s.day >= ? AND s.day <= ?
    ORDER BY s.day, s.user_id`).all(Number(orgId), from, to);
  return {
    rows: rows.map((r) => ({
      id: r.id,
      day: r.day,
      userId: r.user_id,
      who: r.nickname || r.username || `用户${r.user_id}`,
      employeeNo: r.employee_no || r.username || '',
      shiftId: r.shift_id,
      shift: r.shift_id == null ? null : shiftText({
        name: r.shift_name || '班次', workStart: r.work_start, workEnd: r.work_end, crossDay: !!r.cross_day,
      }),
      // 班次被删/停用不能假装没事：界面要能显示"这个格子指向一个坏班次"
      shiftDeleted: r.shift_id != null && r.shift_name == null,
      shiftDisabled: r.shift_id != null && r.shift_enabled === 0,
      position: r.position || '',
      note: r.note || '',
      createdText: r.created_at ? `${att.dayOf(r.created_at)} ${att.hhmmOf(r.created_at)}` : '',
    })),
  };
}

/**
 * 周视图网格：行 = 员工，列 = 日期。
 *
 * 为什么由服务端拼好网格而不是把一堆行丢给前端让前端分组：管理台 Vue 和
 * 手机 Flutter 两边都要画这张表，各自分组一次就是两处口径；而且"这天休息"
 * 和"这天没排"是两回事（休息 = 有记录且 shift 为空；没排 = 根本没有记录），
 * 这个区别必须在一处说清。
 */
function week(orgId, fromDay) {
  const from = validDay(fromDay);
  if (!from) return { error: '开始日期不合法', code: 400 };
  const days = [];
  for (let i = 0; i < 7; i++) days.push(att.addDays(from, i));
  const to = days[6];
  const list = listRange(orgId, from, to);
  if (list.error) return list;
  const users = members(orgId);
  const cells = Object.create(null);
  for (const r of list.rows) {
    cells[`${r.userId}:${r.day}`] = {
      id: r.id,
      shiftId: r.shiftId,
      shift: r.shift,
      shiftDeleted: r.shiftDeleted,
      shiftDisabled: r.shiftDisabled,
      position: r.position,
      note: r.note,
      rest: r.shiftId == null,
    };
  }
  // 每人本周排班天数（休息不计）：周视图右侧"5 天"就是这么来的，服务端算，
  // 免得两边一个按记录数一个按非空 shift 数，对不上
  const workedDays = Object.create(null);
  for (const r of list.rows) {
    if (r.shiftId == null) continue;
    workedDays[r.userId] = (workedDays[r.userId] || 0) + 1;
  }
  return { days, users, cells, workedDays };
}

/**
 * 公共校验：日期 + 班次 + 岗位/备注（save 与 batchFill 共用）。
 * 单独拆出来是因为批量填充没有"某一个 userId"—— 它一次填一批人，
 * 把 userId 校验混进公共部分会让批量入口永远过不了关。
 */
function parseCommon(orgId, input) {
  const b = input && typeof input === 'object' && !Array.isArray(input) ? input : {};
  const day = validDay(b.day);
  if (!day) return { error: '日期不合法或缺失（需要 YYYY-MM-DD）', code: 400 };
  const shift = shiftOf(orgId, b.shiftId);
  if (shift && shift.error) return { error: shift.error, code: 400 };
  if (shift && !shift.enabled) {
    return { error: `班次「${shift.name}」已停用，请先到考勤管理里启用它`, code: 400 };
  }
  return {
    day,
    shiftId: shift ? shift.id : null,
    position: textOf(b.position, MAX_POSITION),
    note: textOf(b.note, MAX_NOTE),
  };
}

/** 校验一次 save 的输入。返回 { day, userId, shiftId, position, note } 或 { error } */
function parseInput(orgId, input) {
  const p = parseCommon(orgId, input);
  if (p.error) return p;
  const b = input && typeof input === 'object' && !Array.isArray(input) ? input : {};
  const uid = Number(b.userId);
  if (!Number.isInteger(uid) || uid <= 0) return { error: '员工不合法', code: 400 };
  const u = db.prepare('SELECT id, org_id FROM users WHERE id=?').get(uid);
  if (!u) return { error: `没有这个员工：#${uid}`, code: 400 };
  if (Number(u.org_id) !== Number(orgId)) {
    return { error: '这个员工不在当前组织，不能给他排班', code: 400 };
  }
  return { ...p, userId: uid };
}

/**
 * 落一条排班（ upsert：一天一人一行，重复提交 = 更新）。
 *
 * 🔴 用 ON CONFLICT 而不是"先 SELECT 再 INSERT/UPDATE"：两个入口（管理台 /
 *    手机表单）可能同时改同一天，先查后写之间那一瞬就是丢更新。
 */
function save(orgId, byUid, input) {
  const p = parseInput(orgId, input);
  if (p.error) return p;
  const now = Date.now();
  db.prepare(`
    INSERT INTO duty_schedules (org_id, day, user_id, shift_id, position, note, created_by, created_at, updated_at)
    VALUES (?,?,?,?,?,?,?,?,?)
    ON CONFLICT(org_id, day, user_id) DO UPDATE SET
      shift_id = excluded.shift_id,
      position = excluded.position,
      note = excluded.note,
      created_by = excluded.created_by,
      updated_at = excluded.updated_at
  `).run(Number(orgId), p.day, p.userId, p.shiftId, p.position, p.note, Number(byUid) || 0, now, now);
  return { ok: true, day: p.day, userId: p.userId, shiftId: p.shiftId };
}

/**
 * 批量填充：把一个班次一次填给一批人（周视图"整列填充"就是它）。
 *
 * userIds 为空 = 组织全员。整批一个事务：填到一半失败不能留半列，
 * 否则界面上"看起来填好了"实际只填了前几个人。
 */
function batchFill(orgId, byUid, input) {
  const b = input && typeof input === 'object' && !Array.isArray(input) ? input : {};
  const p = parseCommon(orgId, b);
  if (p.error) return p;
  let ids;
  if (b.userIds === undefined || b.userIds === null || (Array.isArray(b.userIds) && !b.userIds.length)) {
    ids = members(orgId).map((m) => m.id);
  } else if (!Array.isArray(b.userIds)) {
    return { error: 'userIds 必须是数组（不传 = 全员）', code: 400 };
  } else {
    ids = b.userIds.map(Number);
  }
  if (!ids.length) return { error: '组织里没有员工，无从填起', code: 400 };
  if (ids.length > MAX_BATCH) return { error: `一次最多填 ${MAX_BATCH} 人`, code: 400 };
  // 逐个过人校验：批量入口最容易漏的就是"其中一个人上周离职了"，漏掉的结果
  // 是整批 500 行有一个静默没进去，而界面显示"已填 500"
  for (const id of ids) {
    const u = db.prepare('SELECT org_id FROM users WHERE id=?').get(id);
    if (!u || Number(u.org_id) !== Number(orgId)) {
      return { error: `员工 #${id} 不在当前组织，已整批中止`, code: 400 };
    }
  }
  const now = Date.now();
  db.exec('BEGIN');
  try {
    const stmt = db.prepare(`
      INSERT INTO duty_schedules (org_id, day, user_id, shift_id, position, note, created_by, created_at, updated_at)
      VALUES (?,?,?,?,?,?,?,?,?)
      ON CONFLICT(org_id, day, user_id) DO UPDATE SET
        shift_id = excluded.shift_id,
        position = excluded.position,
        note = excluded.note,
        created_by = excluded.created_by,
        updated_at = excluded.updated_at
    `);
    for (const id of ids) {
      stmt.run(Number(orgId), p.day, id, p.shiftId, p.position, p.note, Number(byUid) || 0, now, now);
    }
    db.exec('COMMIT');
  } catch (e) {
    db.exec('ROLLBACK');
    return { error: '批量填充失败：' + e.message, code: 500 };
  }
  return { ok: true, filled: ids.length, day: p.day, shiftId: p.shiftId };
}

/** 删一个格子（把某人某天改回"没排"） */
function remove(orgId, day, userId) {
  const d = validDay(day);
  const uid = Number(userId);
  if (!d || !Number.isInteger(uid) || uid <= 0) return { error: '参数不合法', code: 400 };
  const info = db.prepare('DELETE FROM duty_schedules WHERE org_id=? AND day=? AND user_id=?')
    .run(Number(orgId), d, uid);
  return { ok: true, deleted: info.changes };
}

/** 清空一整天（整列清空）。返回删了几条，删 0 条也是正常结果（那天本来没排） */
function removeDay(orgId, day) {
  const d = validDay(day);
  if (!d) return { error: '日期不合法', code: 400 };
  const info = db.prepare('DELETE FROM duty_schedules WHERE org_id=? AND day=?').run(Number(orgId), d);
  return { ok: true, deleted: info.changes };
}

/** 清一段日期（周视图"清空本周"） */
function removeRange(orgId, fromDay, toDay) {
  const from = validDay(fromDay);
  const to = validDay(toDay);
  if (!from || !to || from > to) return { error: '日期范围不合法', code: 400 };
  const days = (new Date(`${to}T00:00:00Z`) - new Date(`${from}T00:00:00Z`)) / 86400000 + 1;
  if (days > MAX_RANGE_DAYS) return { error: `一次最多清 ${MAX_RANGE_DAYS} 天`, code: 400 };
  const info = db.prepare('DELETE FROM duty_schedules WHERE org_id=? AND day>=? AND day<=?')
    .run(Number(orgId), from, to);
  return { ok: true, deleted: info.changes };
}

/** 某个员工一段日期的排班（"我的排班"用） */
function myRange(orgId, userId, fromDay, toDay) {
  const from = validDay(fromDay);
  const to = validDay(toDay);
  if (!from || !to || from > to) return { error: '日期范围不合法', code: 400 };
  const list = listRange(orgId, from, to);
  if (list.error) return list;
  return { rows: list.rows.filter((r) => r.userId === Number(userId)) };
}

module.exports = {
  validDay, textOf, shiftOf, shiftText, members,
  listRange, week, save, batchFill, remove, removeDay, removeRange, myRange,
  MAX_NOTE, MAX_POSITION, MAX_BATCH,
};
