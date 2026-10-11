/**
 * 智能薪酬（复刻钉钉的"考勤算工资"那套，2026-10-11）
 *
 * 口径（钉钉同款思路，做了本地化简化）：
 *   日工资   = 月薪基数 / 计薪天数（默认 21.75，可改）
 *   迟到     按"每一次"分档扣：≤30 分钟一档、≤60 分钟一档（金额可配），
 *            超过 60 分钟按每分钟单价（可配）
 *   缺卡     每次扣固定金额（可配）
 *   旷工     旷工一天扣 日工资 × 旷工扣款比例%（可配）
 *   请假     请假天数 × 日工资 × 请假扣款比例%（可配；半天按 0.5 天）
 *   全勤奖   当月无迟到 / 无早退 / 无缺卡 / 无请假 → 发全额（可配）
 *   加班费   休息日出勤的时长 × 时薪（可配，0 = 不计加班）
 *
 * 🔴 只存"怎么算"（规则 + 基数），**不存算出来的结果**：月度报表每次
 *    按 att_records / att_requests 现算。管理员改了打卡记录、审批了请假，
 *    报表立刻是对的 —— 存结果的话就会出现"报表比流水旧"这种说不清的事。
 */
const db = require('./db');
const att = require('./attendance');

const DAY_MS = 86400000;

function round2(n) { return Math.round((Number(n) || 0) * 100) / 100; }

/** 组织的薪酬规则（没配过 = 出厂默认，读取时合成，不落库） */
function configOf(orgId) {
  const row = db.prepare('SELECT * FROM salary_config WHERE org_id=?').get(Number(orgId));
  const d = {
    lateTiers: [{ upTo: 30, amount: 20 }, { upTo: 60, amount: 50 }],
    latePerMinute: 2,
    missingCardDeduct: 50,
    absentDayDeductPct: 100,
    leaveDeductPct: 100,
    fullAttendanceBonus: 100,
    dayDivisor: 21.75,
    overtimePerHour: 0,
  };
  if (!row) return { ...d, customized: false };
  let tiers = [];
  try { tiers = JSON.parse(row.late_tiers) || []; } catch { /* 用默认 */ }
  if (Array.isArray(tiers) && tiers.length) d.lateTiers = tiers;
  return {
    lateTiers: d.lateTiers,
    latePerMinute: row.late_per_minute,
    missingCardDeduct: row.missing_card_deduct,
    absentDayDeductPct: row.absent_day_deduct_pct,
    leaveDeductPct: row.leave_deduct_pct,
    fullAttendanceBonus: row.full_attendance_bonus,
    dayDivisor: row.day_divisor,
    overtimePerHour: row.overtime_per_hour,
    customized: true,
    updatedAt: row.updated_at,
    updatedBy: row.updated_by,
  };
}

function num(v, { min = 0, max = 10000000 } = {}) {
  const n = Number(v);
  if (!Number.isFinite(n)) return null;
  if (n < min || n > max) return null;
  return n;
}

/** 保存规则（全部字段可选，只更新传了的）。规则错了返回 { error }，不写半条。 */
function saveConfig(orgId, patch = {}, by = null) {
  const cur = configOf(orgId);
  const next = { ...cur };

  if (patch.lateTiers !== undefined) {
    if (!Array.isArray(patch.lateTiers) || patch.lateTiers.length > 4) {
      return { error: '迟到扣款档位不合法（最多 4 档）' };
    }
    const tiers = [];
    let prev = 0;
    for (const t of patch.lateTiers) {
      const upTo = num(t.upTo, { min: 1, max: 1440 });
      const amount = num(t.amount, { min: 0, max: 100000 });
      if (upTo === null || amount === null) return { error: '迟到档位金额/分钟数不合法' };
      if (upTo <= prev) return { error: '迟到档位的分钟数必须逐档递增' };
      tiers.push({ upTo, amount });
      prev = upTo;
    }
    next.lateTiers = tiers;
  }

  for (const [k, opt] of Object.entries({
    latePerMinute: { min: 0, max: 1000 },
    missingCardDeduct: { min: 0, max: 100000 },
    absentDayDeductPct: { min: 0, max: 300 },
    leaveDeductPct: { min: 0, max: 300 },
    fullAttendanceBonus: { min: 0, max: 100000 },
    overtimePerHour: { min: 0, max: 100000 },
  })) {
    if (patch[k] !== undefined) {
      const n = num(patch[k], opt);
      if (n === null) return { error: `${k} 数值不合法` };
      next[k] = n;
    }
  }

  if (patch.dayDivisor !== undefined) {
    const n = num(patch.dayDivisor, { min: 1, max: 31 });
    if (n === null) return { error: '计薪天数应在 1~31 之间' };
    next.dayDivisor = n;
  }

  db.prepare(`INSERT INTO salary_config
      (org_id, late_tiers, late_per_minute, missing_card_deduct, absent_day_deduct_pct,
       leave_deduct_pct, full_attendance_bonus, day_divisor, overtime_per_hour, updated_at, updated_by)
      VALUES (?,?,?,?,?,?,?,?,?,?,?)
      ON CONFLICT(org_id) DO UPDATE SET
      late_tiers=excluded.late_tiers, late_per_minute=excluded.late_per_minute,
      missing_card_deduct=excluded.missing_card_deduct, absent_day_deduct_pct=excluded.absent_day_deduct_pct,
      leave_deduct_pct=excluded.leave_deduct_pct, full_attendance_bonus=excluded.full_attendance_bonus,
      day_divisor=excluded.day_divisor, overtime_per_hour=excluded.overtime_per_hour,
      updated_at=excluded.updated_at, updated_by=excluded.updated_by`)
    .run(Number(orgId), JSON.stringify(next.lateTiers), next.latePerMinute,
      next.missingCardDeduct, next.absentDayDeductPct, next.leaveDeductPct,
      next.fullAttendanceBonus, next.dayDivisor, next.overtimePerHour, Date.now(), by);
  return { ok: true, config: configOf(orgId) };
}

function basesOf(orgId) {
  const rows = db.prepare('SELECT user_id, month_base FROM salary_base WHERE org_id=?')
    .all(Number(orgId));
  const m = {};
  for (const r of rows) m[r.user_id] = r.month_base;
  return m;
}

/** 批量保存月薪基数（传谁的更新谁的，没传的不动 —— 全量覆盖会误清没填的人） */
function saveBases(orgId, items = [], by = null) {
  if (!Array.isArray(items)) return { error: 'items 必须是数组' };
  const ins = db.prepare(`INSERT INTO salary_base (org_id, user_id, month_base, updated_at)
    VALUES (?,?,?,?)
    ON CONFLICT(org_id, user_id) DO UPDATE SET month_base=excluded.month_base, updated_at=excluded.updated_at`);
  for (const it of items) {
    const uid = Number(it.userId);
    const base = num(it.monthBase, { min: 0, max: 10000000 });
    if (!uid || base === null) return { error: '员工或基数不合法' };
    ins.run(Number(orgId), uid, base, Date.now());
  }
  void by;
  return { ok: true };
}

/** 单次迟到的扣款金额 */
function lateDeduct(minutes, cfg) {
  const m = Math.max(0, Math.round(minutes));
  for (const t of cfg.lateTiers) {
    if (m <= t.upTo) return t.amount;
  }
  return round2(cfg.lateTiers.length
    ? (m * cfg.latePerMinute)
    : 0);
}

/** 月度薪酬报表（全员现算；judgeRange 一次取数批算，不逐人查库） */
function computeReport({ orgId, month, now = Date.now() }) {
  const cfg = configOf(orgId);
  const bases = basesOf(orgId);
  const members = db.prepare(
    'SELECT id, username, nickname FROM users WHERE org_id=? AND is_bot=0 ORDER BY id')
    .all(Number(orgId));

  const [y, mo] = month.split('-').map(Number);
  const lastDay = new Date(Date.UTC(y, mo, 0)).getUTCDate();
  const from = `${month}-01`;
  const to = `${month}-${String(lastDay).padStart(2, '0')}`;

  const judged = att.judgeRange({ orgId, users: members, from, to, now });
  const byUser = new Map(judged.users.map((u) => [u.userId, u]));

  const items = members.map((u) => {
    const j = byUser.get(u.id);
    const days = j ? j.days : [];
    const sum = j ? j.summary : {
      late: 0, lateMinutes: 0, early: 0, missing: 0, absent: 0, leave: 0,
      missingPunches: 0, overtimeMinutes: 0, present: 0, donePunches: 0,
    };

    // 迟到按"每一次"分档（每天每张上班卡单独算一档）
    let lateCount = 0, lateAmount = 0;
    let missingCount = 0;
    for (const d of days) {
      // 迟到也只在**工作日**数：休息日整日不判出勤（judgeDay 直接 return rest），
      // 休息日来打卡算加班不算迟到
      if (d.status === 'future' || !d.isWorkday) continue;
      for (const p of d.punches || []) {
        if (p.lateMinutes > 0) {
          lateCount++;
          lateAmount += lateDeduct(p.lateMinutes, cfg);
        }
      }
      // 🔴 缺卡只在**工作日**数：底层的卡片判定不分工作日/休息日，休息日
      //    没打卡 missingLabels 照样有值 —— 不按 isWorkday 过滤的话，
      //    每个周末都会被扣两次缺卡费（2026-10-11 实测踩到）。
      // 🔴 旷工天**不重复**扣缺卡费：那天两张卡没打已经按"旷工一天 = 日工资×%"
      //    扣过了，再把两张卡各算一次缺卡就是一笔钱扣两遍（钉钉同口径）。
      if (!d.isWorkday || d.status === 'absent') continue;
      missingCount += (d.missingLabels || []).length;
    }
    lateAmount = round2(lateAmount);

    const absentDays = sum.absent || 0;
    const leaveDays = sum.leave || 0;
    const overtimeMinutes = sum.overtimeMinutes || 0;
    const base = bases[u.id] || 0;
    const dayWage = cfg.dayDivisor > 0 ? base / cfg.dayDivisor : 0;
    const missingAmount = round2(missingCount * cfg.missingCardDeduct);
    const absentAmount = round2(absentDays * dayWage * cfg.absentDayDeductPct / 100);
    const leaveAmount = round2(leaveDays * dayWage * cfg.leaveDeductPct / 100);
    const overtimeAmount = cfg.overtimePerHour > 0
      ? round2(overtimeMinutes / 60 * cfg.overtimePerHour) : 0;
    // 全勤：迟到/早退/缺卡/旷工/请假全无，且当月确实有出勤记录（从没来过的人不发全勤）
    const fullAttendance = lateCount === 0 && sum.early === 0 && missingCount === 0
      && absentDays === 0 && leaveDays === 0 && ((sum.present || 0) > 0 || (sum.donePunches || 0) > 0);
    const bonusAmount = fullAttendance ? cfg.fullAttendanceBonus : 0;

    const rows = [];
    if (base > 0) rows.push({ key: 'base', label: '月薪基数', amount: round2(base), note: `按 ${cfg.dayDivisor} 天折算日工资 ${round2(dayWage)} 元` });
    if (lateCount > 0) rows.push({ key: 'late', label: '迟到扣款', amount: -lateAmount, note: `迟到 ${lateCount} 次共 ${sum.lateMinutes || 0} 分钟` });
    if (missingCount > 0) rows.push({ key: 'missing', label: '缺卡扣款', amount: -missingAmount, note: `缺卡 ${missingCount} 次 × ${cfg.missingCardDeduct} 元` });
    if (absentDays > 0) rows.push({ key: 'absent', label: '旷工扣款', amount: -absentAmount, note: `旷工 ${absentDays} 天 × 日工资 ${round2(dayWage)} 元 × ${cfg.absentDayDeductPct}%` });
    if (leaveDays > 0) rows.push({ key: 'leave', label: '请假扣款', amount: -leaveAmount, note: `请假 ${leaveDays} 天 × 日工资 ${round2(dayWage)} 元 × ${cfg.leaveDeductPct}%` });
    if (bonusAmount > 0) rows.push({ key: 'full', label: '全勤奖', amount: bonusAmount, note: '当月全勤' });
    if (overtimeAmount > 0) rows.push({ key: 'overtime', label: '加班费', amount: overtimeAmount, note: `加班 ${Math.round(overtimeMinutes)} 分钟 × ${cfg.overtimePerHour} 元/时` });

    const net = round2(rows.reduce((s, x) => s + x.amount, 0));
    return {
      userId: u.id, username: u.username, nickname: u.nickname,
      base: round2(base),
      stats: {
        lateCount, lateMinutes: sum.lateMinutes || 0, missingCount,
        earlyCount: sum.early || 0, absentDays, leaveDays, overtimeMinutes,
      },
      items: rows,
      deductions: round2(lateAmount + missingAmount + absentAmount + leaveAmount),
      bonus: round2(bonusAmount + overtimeAmount),
      net,
    };
  });

  return {
    month, from, to,
    config: {
      lateTiers: cfg.lateTiers, latePerMinute: cfg.latePerMinute,
      missingCardDeduct: cfg.missingCardDeduct, absentDayDeductPct: cfg.absentDayDeductPct,
      leaveDeductPct: cfg.leaveDeductPct, fullAttendanceBonus: cfg.fullAttendanceBonus,
      dayDivisor: cfg.dayDivisor, overtimePerHour: cfg.overtimePerHour,
    },
    items,
    totalNet: round2(items.reduce((s, x) => s + x.net, 0)),
    serverTime: now,
  };
}

module.exports = { configOf, saveConfig, basesOf, saveBases, computeReport, lateDeduct };
