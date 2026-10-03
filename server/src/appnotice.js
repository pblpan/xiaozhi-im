'use strict';

/**
 * 工作台公告位（客户端工作台顶部那条横幅）
 *
 * ─────────────────────────────────────────────────────────────
 * 为什么工作台要有这一条，而不是只靠群消息
 * ─────────────────────────────────────────────────────────────
 * 钉钉 / 企业微信 / 飞书的工作台顶部都有"公告 / 新闻"位。它不是群消息的副本，
 * 而是**管理员单方面要所有人看见的一句话**：
 *   "明天盘点，全店 9 点前把货架归位"
 *   "这周起考勤改成 4 次卡"
 * 走群消息的问题是：员工可以置顶忽略、可以不看，而公告位在每个人打开工作台
 * 第一眼就在那儿。它是"必须读到"的，不是"可能读到"的。
 *
 * ─────────────────────────────────────────────────────────────
 * 三条刻意的设计取舍
 * ─────────────────────────────────────────────────────────────
 * 1. **横幅只有一句话，但点开能看到"正文"**。
 *    早期版本横幅只能写一句话、且没有任何详情入口（怕为一个横幅引入
 *    webview 外部跳转通道不值）。后来加了 `content` 正文 + 客户端点横幅
 *    弹**应用内详情**（不是外部链接），管理员想多说几句不用再去发群消息。
 *
 * 2. **"停用"而不是"删除"**。
 *    急事撤回时，员工手机上那条已经读到一半的公告需要立刻消失；
 *    而等到下一轮清理再删，中间这段时间它是活的。所以停用的语义是"立刻隐去"，
 *    删掉的语义是"以后不再出现" —— 两个动作管两个时间段。
 *
 * 3. **下发条数上限（不超过 3 条）**。
 *    三条以上横幅就把应用网格顶下去了。宁可让管理员挑最重要的三条，
 *    也不要让一个爱发公告的人把工作台变成公告墙。
 */

const db = require('./db');

const TEXT_MAX = 60;       // 横幅上那句话（标题）的上限
const CONTENT_MAX = 2000;  // 点开详情看的正文上限（正文可为空）
const MAX_DOWNLOAD = 3;

db.exec(`
CREATE TABLE IF NOT EXISTS workbench_notices (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  text       TEXT NOT NULL,          -- 公告正文（纯文本，不渲染富文本）
  sort       INTEGER NOT NULL DEFAULT 100,
  enabled    INTEGER NOT NULL DEFAULT 1,
  updated_at INTEGER NOT NULL,
  updated_by TEXT
);
`);

// 背景图（v0.22.0 新增）：老库没有这一列，首次启动补上。
// 幂等：列已存在时 ALTER 会报 "duplicate column"，忽略即可。
try { db.exec('ALTER TABLE workbench_notices ADD COLUMN bg_file_id INTEGER'); } catch {}
// 正文（本轮新增）：横幅那句话之外，点开还能看的正文。老库同样补列。
try { db.exec('ALTER TABLE workbench_notices ADD COLUMN content TEXT'); } catch {}

/* ---------------- 读 ---------------- */

/** 拼出背景图可访问地址；没有背景图返回 ''（客户端据此判断是否叠背景） */
function bgUrl(row) {
  if (!row || !row.bg_file_id) return '';
  const f = db.prepare('SELECT path FROM files WHERE id=?').get(row.bg_file_id);
  return f && f.path ? `/files/${f.path}` : '';
}

/** 当前生效的公告（管理台"预览客户端看到什么"用） */
function listEnabled(limit) {
  const n = limit == null ? MAX_DOWNLOAD : Math.max(1, Math.min(MAX_DOWNLOAD, Number(limit) || 1));
  return db.prepare(
    'SELECT id, text, content, sort, bg_file_id FROM workbench_notices WHERE enabled=1 ORDER BY sort ASC, id ASC LIMIT ?',
  ).all(n).map((r) => ({ id: r.id, text: r.text, content: r.content || '', sort: r.sort, bgUrl: bgUrl(r) }));
}

/** 全部公告（含已停用的，管理台列表要给"停用/启用"这个开关） */
function listAll() {
  return db.prepare('SELECT * FROM workbench_notices ORDER BY sort ASC, id ASC').all()
    .map((r) => ({
      id: r.id, text: r.text, content: r.content || '', sort: r.sort, enabled: !!r.enabled,
      bgFileId: r.bg_file_id || 0,
      bgUrl: bgUrl(r),
      updatedAt: r.updated_at, updatedBy: r.updated_by || '',
    }));
}

/* ---------------- 写 ---------------- */

function cleanText(raw) {
  const s = String(raw == null ? '' : raw).trim();
  if (!s) return { error: '公告内容不能为空' };
  if ([...s].length > TEXT_MAX) return { error: `公告最多 ${TEXT_MAX} 个字（当前 ${[...s].length} 个）` };
  return { value: s };
}

function cleanSort(raw) {
  const n = Number(raw);
  if (!Number.isFinite(n)) return { error: '排序号需要是数字' };
  return { value: Math.max(0, Math.min(9999, Math.trunc(n))) };
}

/** 正文允许为空（只发一句话也行），但太长要拦住 */
function cleanContent(raw) {
  const s = String(raw == null ? '' : raw);
  if ([...s].length > CONTENT_MAX) return { error: `公告正文最多 ${CONTENT_MAX} 个字（当前 ${[...s].length} 个）` };
  return { value: s };
}

/** 新增一条公告（可带背景图 fileId + 正文 content） */
function add(text, by, bgFileId, content) {
  const t = cleanText(text);
  if (t.error) return t;
  const c = cleanContent(content);
  if (c.error) return c;
  const s = cleanSort(100);
  let bg = null;
  if (bgFileId !== null && bgFileId !== undefined && bgFileId !== '') {
    bg = Number(bgFileId);
    if (!Number.isFinite(bg)) return { error: '背景图参数不合法' };
  }
  const now = Date.now();
  const info = db.prepare(
    'INSERT INTO workbench_notices (text, content, sort, enabled, bg_file_id, updated_at, updated_by) VALUES (?,?,?,1,?,?,?)',
  ).run(t.value, c.value, s.value, bg, now, String(by || 'admin').slice(0, 60));
  const id = Number(info.lastInsertRowid);
  return { id, notice: { id, text: t.value, content: c.value, sort: s.value, enabled: true, bgFileId: bg || 0, bgUrl: bgUrl({ bg_file_id: bg }) } };
}

/** 改一条（PATCH 语义） */
function update(id, patch, by) {
  const row = db.prepare('SELECT * FROM workbench_notices WHERE id=?').get(Number(id));
  if (!row) return { error: `公告不存在：${id}` };
  if (!patch || typeof patch !== 'object') return { error: '提交内容必须是一个对象' };

  let text = row.text;
  let content = row.content || '';
  let sort = Number(row.sort);
  let enabled = !!row.enabled;
  let bgFileId = row.bg_file_id || null;

  if ('text' in patch) {
    if (patch.text === null) text = row.text;
    else {
      const t = cleanText(patch.text);
      if (t.error) return t;
      text = t.value;
    }
  }
  if ('content' in patch) {
    const c = cleanContent(patch.content);
    if (c.error) return c;
    content = c.value;
  }
  if ('sort' in patch) {
    if (patch.sort === null) sort = Number(row.sort);
    else {
      const s = cleanSort(patch.sort);
      if (s.error) return s;
      sort = s.value;
    }
  }
  if ('enabled' in patch) enabled = !!patch.enabled;
  if ('bgFileId' in patch) {
    const v = patch.bgFileId;
    bgFileId = (v === null || v === undefined || v === '' || Number(v) === 0) ? null : Number(v);
    if (bgFileId !== null && !Number.isFinite(bgFileId)) return { error: '背景图参数不合法' };
  }

  db.prepare(`
    UPDATE workbench_notices
       SET text=?, content=?, sort=?, enabled=?, bg_file_id=?, updated_at=?, updated_by=?
     WHERE id=?
  `).run(text, content, sort, enabled ? 1 : 0, bgFileId, Date.now(), String(by || 'admin').slice(0, 60), Number(id));
  return { notice: { id: Number(id), text, content, sort, enabled, bgFileId: bgFileId || 0, bgUrl: bgUrl({ bg_file_id: bgFileId }) } };
}

/** 删一条（只删，不动别人 —— 这是"以后不再出现"的语义） */
function remove(id) {
  const info = db.prepare('DELETE FROM workbench_notices WHERE id=?').run(Number(id));
  return { removed: info.changes > 0 };
}

/** 清掉全部已停用的（管理台"清理"按钮，只清停用，生效的不动） */
function purgeDisabled() {
  const info = db.prepare('DELETE FROM workbench_notices WHERE enabled=0').run();
  return { removed: info.changes };
}

module.exports = {
  TEXT_MAX, CONTENT_MAX, MAX_DOWNLOAD,
  listEnabled, listAll,
  add, update, remove, purgeDisabled,
};
