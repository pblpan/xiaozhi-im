'use strict';

/**
 * 培训中心接口（training 模块 · M4）
 *
 * ── 这个模块在解决什么 ──────────────────────────────────────
 * 门店培训的痛点不是"没有资料"，是**不知道谁学了、学到哪、会不会**。
 * 200+ 视频/课件丢在共享盘里，等于没培训。所以这里做的是一套最小 LMS：
 *   课程 → 章节 → 课时（看视频、记进度）→ 章节考试（判分、留档）
 *
 * ── 两条从真实培训体系里搬来的硬规则 ────────────────────────
 * ① **考试机会在「开始」时就消耗。**
 *    只在"提交"时才算用掉的话，学员可以点进去看一眼题目、退出、再点进去，
 *    题目就漏光了，而且**全程没有任何报错**。所以 start 即落卷（submitted_at=0）。
 *    这条规则在界面上必须明说（"退出将浪费本次考试机会"），否则就是坑学员。
 *
 * ② **进度不达标不放行考试。**
 *    "学完再考"是培训的意义所在；能跳过视频直接考试的话，
 *    完成率这个数字就是假的 —— 而且假得看不出来。
 *
 * ── 判分口径 ──────────────────────────────────────────────
 * · 单选/判断：选中即得分
 * · 多选：**全对才得分**（漏选、错选都 0 分）—— 部分给分会诱导出"蒙几个选项"的玩法
 * · 总分 = 各题得分之和；及格线按 exam.pass_score
 *
 * 🔴 分数在**提交那一刻**按当时的题目算，之后改题不影响历史成绩
 *    （tr_answer 存的是当时的判定结果，不是"现在对不对"）。
 *    不落库的话，老师改了一道题，所有人的历史成绩会集体漂移。
 */
const express = require('express');
const path = require('path');
const fs = require('fs');
const db = require('../db');
const config = require('../config');
const { verifyToken } = require('../auth');
const { parseList, envelope } = require('../paging');
const appoverrides = require('../appoverrides');

const router = express.Router();      // 挂 /api/training

const MAX_TITLE = 120;
const MAX_STEM = 1000;
const MAX_OPTION = 500;
const MAX_LESSONS_PER_COURSE = 500;   // 护栏：导入器扫错目录时不至于灌爆一个课程

// ============================================================
// 小工具
// ============================================================

function auth(req, res, { needAdmin = false } = {}) {
  const c = verifyToken(req.headers.authorization?.replace('Bearer ', ''));
  if (!c) { res.status(401).json({ error: 'unauthorized' }); return null; }
  const u = db.prepare('SELECT id,username,nickname,role FROM users WHERE id = ?').get(c.uid);
  if (!u) { res.status(401).json({ error: 'unauthorized' }); return null; }
  if (needAdmin && u.role !== 'admin') { res.status(403).json({ error: 'forbidden' }); return null; }
  return u;
}

const str = (v, max) => String(v == null ? '' : v).trim().slice(0, max || 200);
const num = (v, dflt) => {
  const n = Number(v);
  return Number.isFinite(n) ? n : dflt;
};
const now = () => Date.now();

// 外链地址：只认 http/https。别的协议（javascript:、file:）一律当场打回，
// 不让它存进去 —— 存进去的就是一个等着被点的坑。
function linkUrl(v) {
  const s = str(v, 2000);
  if (!s) return '';
  if (!/^https?:\/\//i.test(s)) return '';
  return s;
}

/**
 * 把请求体里的课件字段整理成落库用的形状。
 *
 * 🔴 课件是**两条路，不是一条**：
 * · 系统文件（file_id）：走上传，进度能真数、能缓存，学员断网也能看；
 * · 外链（link_url）：共享盘 / 视频号 / 腾讯文档之类塞进 files 表的，
 *   只记个地址，学员点了就跳出去。
 * 之前只有 file_id，管理台上"填不了课件链接"就是这么来的。
 */
function lessonFields(body) {
  return {
    title: str(body?.title, MAX_TITLE),
    kind: body?.kind === 'doc' ? 'doc' : 'video',
    fileId: num(body?.fileId, 0) || null,
    linkUrl: linkUrl(body?.linkUrl),
    durationSec: Math.max(0, Math.floor(num(body?.durationSec, 0))),
    sort: num(body?.sort, 0),
  };
}

/** 章节进度百分比：看完了的课时 / 本章课时总数（没有课时算 0，不是 100） */
function chapterProgressPct(userId, chapterId) {
  const total = db.prepare('SELECT COUNT(*) n FROM tr_lesson WHERE chapter_id = ?').get(chapterId).n;
  if (total === 0) return 0;
  const done = db.prepare(`
    SELECT COUNT(*) n FROM tr_lesson l
      JOIN tr_progress p ON p.lesson_id = l.id AND p.user_id = ?
     WHERE l.chapter_id = ? AND p.done = 1
  `).get(userId, chapterId).n;
  return Math.round((done / total) * 100);
}

function courseProgressPct(userId, courseId) {
  const total = db.prepare(`
    SELECT COUNT(*) n FROM tr_lesson l JOIN tr_chapter c ON c.id = l.chapter_id
     WHERE c.course_id = ?`).get(courseId).n;
  if (total === 0) return 0;
  const done = db.prepare(`
    SELECT COUNT(*) n FROM tr_lesson l
      JOIN tr_chapter c ON c.id = l.chapter_id
      JOIN tr_progress p ON p.lesson_id = l.id AND p.user_id = ?
     WHERE c.course_id = ? AND p.done = 1`).get(userId, courseId).n;
  return Math.round((done / total) * 100);
}

/** 课时上带"我学到哪了" —— 客户端靠它续播、靠它打勾 */
function lessonWithProgress(userId, l) {
  const p = db.prepare('SELECT position_sec, watched_sec, done, updated_at FROM tr_progress WHERE user_id = ? AND lesson_id = ?')
    .get(userId, l.id);
  const doneCount = 0;
  return {
    id: l.id,
    title: l.title,
    kind: l.kind,
    fileId: l.file_id,
    // 外链课件：共享盘 / 视频号 / 腾讯文档这类进不了系统文件的，走这条。
    // 老库没有这一列时会是 undefined，统一补成 ''（客户端判空看的是字符串是否为空）。
    linkUrl: l.link_url || '',
    durationSec: l.duration_sec,
    sort: l.sort,
    // 看到第几秒 → 续播用。**不是完成度**（拖一下就到 95%）。
    positionSec: p?.position_sec || 0,
    // 真看了多少秒 → 给学员自己看"我到底看了多少"。
    // 桌面端/文档走系统播放器时数不出来，恒为 0（见 db.js 里那列的注释）。
    watchedSec: p?.watched_sec || 0,
    done: !!p?.done,
    updatedAt: p?.updated_at || 0,
    _doneCount: doneCount,
  };
}

// ============================================================
// 课程：列表 / 详情
// ============================================================

/**
 * GET /api/training/courses?scope=public|mine
 *
 * 为什么要分公共课和我的课：200+ 素材铺开是一张很长的表，
 * 学员真正要的是"我要学的那几门"。不加这个区分，
 * 列表就退化成"全部课程"，学员每次都要从头找。
 */
router.get('/courses', (req, res) => {
  const u = auth(req, res); if (!u) return;
  const list = parseList(req.query);
  if (list.error) return res.status(400).json({ error: list.error });
  const scope = req.query.scope === 'mine' ? 'mine' : 'public';

  const params = [];
  let join = '';
  let where = 'WHERE c.published = 1';
  if (scope === 'mine') {
    join = 'JOIN tr_enroll e ON e.course_id = c.id AND e.user_id = ?';
    params.push(u.id);
  }
  const q = str(req.query.q, 60);
  if (q) {
    where += ' AND (c.title LIKE ? ESCAPE \'\\\' OR c.category LIKE ? ESCAPE \'\\\')';
    const like = '%' + q.replace(/[\\%_]/g, (ch) => '\\' + ch) + '%';
    params.push(like, like);
  }

  const total = db.prepare(`SELECT COUNT(*) n FROM tr_course c ${join} ${where}`).get(...params).n;
  const rows = db.prepare(`
    SELECT c.*, (SELECT COUNT(*) FROM tr_chapter ch WHERE ch.course_id = c.id) chapter_count,
           (SELECT COUNT(*) FROM tr_lesson l JOIN tr_chapter ch2 ON ch2.id = l.chapter_id
             WHERE ch2.course_id = c.id) lesson_count
      FROM tr_course c ${join} ${where}
     ORDER BY c.id DESC LIMIT ? OFFSET ?`)
    .all(...params, list.pageSize, list.offset);

  const items = rows.map((c) => ({
    id: c.id,
    title: c.title,
    intro: c.intro,
    category: c.category,
    required: !!c.required,
    chapterCount: c.chapter_count,
    lessonCount: c.lesson_count,
    // 🔴 就算没有数据也要回 0，不能省这个字段 —— 客户端"有数据才渲染"的
    // 老毛病就是这么来的（进度条不显示 → 用户以为没记录）。
    progressPct: courseProgressPct(u.id, c.id),
    joined: scope === 'mine' ? true
      : !!db.prepare('SELECT 1 FROM tr_enroll WHERE user_id = ? AND course_id = ?').get(u.id, c.id),
  }));
  res.json(envelope(list, items, total));
});

router.get('/courses/:id', (req, res) => {
  const u = auth(req, res); if (!u) return;
  const cid = Number(req.params.id);
  const c = db.prepare('SELECT * FROM tr_course WHERE id = ?').get(cid);
  if (!c) return res.status(404).json({ error: '课程不存在' });

  const chapters = db.prepare('SELECT * FROM tr_chapter WHERE course_id = ? ORDER BY sort, id').all(cid)
    .map((ch) => {
      const lessons = db.prepare('SELECT * FROM tr_lesson WHERE chapter_id = ? ORDER BY sort, id').all(ch.id)
        .map((l) => lessonWithProgress(u.id, l));
      const exams = db.prepare('SELECT id, title, pass_score, attempt_limit, min_progress FROM tr_exam WHERE chapter_id = ? ORDER BY id')
        .all(ch.id).map((e) => ({
          ...e,
          progressPct: chapterProgressPct(u.id, ch.id),
          // 已用掉几次机会（含"开始了没交"的）
          usedAttempts: db.prepare('SELECT COUNT(*) n FROM tr_sheet WHERE user_id = ? AND exam_id = ?')
            .get(u.id, e.id).n,
          bestScore: (db.prepare('SELECT MAX(score) s FROM tr_sheet WHERE user_id = ? AND exam_id = ? AND submitted_at > 0')
            .get(u.id, e.id).s) || 0,
        }));
      return {
        id: ch.id, title: ch.title, sort: ch.sort,
        progressPct: chapterProgressPct(u.id, ch.id),
        lessons, exams,
      };
    });

  res.json({
    course: {
      id: c.id, title: c.title, intro: c.intro, category: c.category,
      required: !!c.required, published: !!c.published,
      coverFileId: c.cover_file_id,
    },
    progressPct: courseProgressPct(u.id, c.id),
    joined: !!db.prepare('SELECT 1 FROM tr_enroll WHERE user_id = ? AND course_id = ?').get(u.id, c.id),
    chapters,
  });
});

/** POST /api/training/courses/:id/join —— 加入课程（幂等） */
router.post('/courses/:id/join', (req, res) => {
  const u = auth(req, res); if (!u) return;
  const cid = Number(req.params.id);
  if (!db.prepare('SELECT 1 FROM tr_course WHERE id = ? AND published = 1').get(cid)) {
    return res.status(404).json({ error: '课程不存在或未发布' });
  }
  db.prepare('INSERT OR IGNORE INTO tr_enroll (user_id, course_id, joined_at) VALUES (?,?,?)')
    .run(u.id, cid, now());
  res.json({ ok: true, courseId: cid });
});

router.delete('/courses/:id/join', (req, res) => {
  const u = auth(req, res); if (!u) return;
  db.prepare('DELETE FROM tr_enroll WHERE user_id = ? AND course_id = ?').run(u.id, Number(req.params.id));
  res.json({ ok: true });
});

// ============================================================
// 学习进度
// ============================================================

/**
 * POST /api/training/progress
 * body: { lessonId, positionSec, watchedSec, done }
 *
 * 🔴 幂等是刚需：客户端"退出播放时上报"，弱网下会重传。
 *    走 UPSERT，重复的只覆盖，不会变成两行（两行的后果是进度来回跳）。
 *
 * 🔴 done 由客户端判（看满 90% 才传），服务端照记 —— 但**判分/门禁只看 done**，
 *    不看 positionSec。因为"看到 95%"不算学完，而"看到 95%"这个值
 *    在拖动进度条时可以随便造。用它当门禁等于没有门禁。
 *
 * 🔴 positionSec / watchedSec 都取 MAX，不取最新值：
 *    客户端是"周期性上报 + 退出时兜底上报"，两条链路到达顺序不定，
 *    取最新会把"退出时那次"覆盖回一个更小的数（比如退播前 seek 回开头）。
 *    这两个数在语义上都是**只增不减**的，取 MAX 才对得上语义。
 */
router.post('/progress', (req, res) => {
  const u = auth(req, res); if (!u) return;
  const lessonId = num(req.body?.lessonId, 0);
  if (!lessonId) return res.status(400).json({ error: 'lessonId 必填' });
  if (!db.prepare('SELECT 1 FROM tr_lesson WHERE id = ?').get(lessonId)) {
    return res.status(404).json({ error: '课时不存在' });
  }
  const positionSec = Math.max(0, Math.floor(num(req.body?.positionSec, 0)));
  const watchedSec = Math.max(0, Math.floor(num(req.body?.watchedSec, 0)));
  const done = req.body?.done ? 1 : 0;

  db.prepare(`
    INSERT INTO tr_progress (user_id, lesson_id, position_sec, watched_sec, done, updated_at)
    VALUES (?,?,?,?,?,?)
    ON CONFLICT(user_id, lesson_id) DO UPDATE SET
      position_sec = MAX(position_sec, excluded.position_sec),
      watched_sec = MAX(watched_sec, excluded.watched_sec),
      done = MAX(done, excluded.done),
      updated_at = excluded.updated_at
  `).run(u.id, lessonId, positionSec, watchedSec, done, now());

  const p = db.prepare('SELECT * FROM tr_progress WHERE user_id = ? AND lesson_id = ?').get(u.id, lessonId);
  res.json({
    ok: true,
    lessonId,
    positionSec: p.position_sec,
    watchedSec: p.watched_sec,
    done: !!p.done,
  });
});

/**
 * 把 files.path 解析成真实磁盘路径。
 *
 * 🔴 库里 `files.path` 有**两种写法**，都得认：
 *   · 客户端/管理台上传 → 存的是**文件名**（相对 FILES_DIR）  ← routes/files.js
 *   · 导入器 --copy     → 存的是复制后的**绝对路径**
 *   · 导入器不带 --copy → 存的是素材盘上的**绝对路径**（200G 视频不复制到 NAS）
 * 只写 `path.resolve(f.path)` 的话，相对那批会被拿到**进程 cwd** 下找，
 * 于是"上传的课件播不了、导入的能播"——这种一半好一半坏最难查。
 */
function resolveFilePath(p) {
  return path.isAbsolute(p) ? p : path.join(require('../config').FILES_DIR, p);
}

/**
 * GET /api/training/lessons/:id/media —— 播放/下载课件
 *
 * 为什么单独开一个口子，而不是复用 /api/files：
 *   视频播放要 **Range**（拖动进度条、续播都靠它），而原来的文件接口是整文件下发。
 *   大视频没有 206 的话，拖一下进度条就要把整个文件重下一遍，
 *   在 NAS 上基本等于"播不动"。
 */
router.get('/lessons/:id/media', (req, res) => {
  const u = auth(req, res); if (!u) return;
  const lid = Number(req.params.id);
  const l = db.prepare('SELECT * FROM tr_lesson WHERE id = ?').get(lid);
  if (!l || !l.file_id) return res.status(404).json({ error: '课时没有课件' });
  const f = db.prepare('SELECT * FROM files WHERE id = ?').get(l.file_id);
  if (!f) return res.status(404).json({ error: '课件文件不存在' });

  const full = resolveFilePath(f.path);
  if (!fs.existsSync(full)) return res.status(404).json({ error: '课件文件已丢失' });

  const size = fs.statSync(full).size;
  const type = f.mime || (l.kind === 'video' ? 'video/mp4' : 'application/octet-stream');
  res.setHeader('Accept-Ranges', 'bytes');
  res.setHeader('Content-Type', type);

  const range = req.headers.range;
  if (!range) {
    res.setHeader('Content-Length', size);
    // 播放场景主流是带 Range 的；整文件下发这里给 inline 而不是 attachment，
    // 否则浏览器一律下载、播放不了。
    res.setHeader('Content-Disposition', 'inline');
    return fs.createReadStream(full).pipe(res);
  }

  // 形如 bytes=100-200 / bytes=100- / bytes=-200
  const m = /^bytes=(\d*)-(\d*)$/.exec(String(range).trim());
  if (!m) {
    res.setHeader('Content-Range', `bytes */${size}`);
    return res.status(416).json({ error: 'Range 不合法' });
  }
  let start = m[1] === '' ? null : Number(m[1]);
  let end = m[2] === '' ? null : Number(m[2]);
  if (start === null && end === null) {
    res.setHeader('Content-Range', `bytes */${size}`);
    return res.status(416).json({ error: 'Range 不合法' });
  }
  if (start === null) { start = Math.max(0, size - end); end = size - 1; }
  if (end === null || end >= size) end = size - 1;
  if (start > end || start >= size) {
    res.setHeader('Content-Range', `bytes */${size}`);
    return res.status(416).json({ error: 'Range 超出范围' });
  }

  res.status(206);
  res.setHeader('Content-Range', `bytes ${start}-${end}/${size}`);
  res.setHeader('Content-Length', end - start + 1);
  fs.createReadStream(full, { start, end }).pipe(res);
});

// ============================================================
// 考试
// ============================================================

/**
 * POST /api/training/exams/:id/start —— 开始考试（**这一刻就消耗一次机会**）
 *
 * 两道闸：
 *   ① 进度门禁：本章进度 < min_progress → 403 progress_not_reached
 *   ② 机会用尽 → 403 no_attempt_left
 *
 * 返回题目（**不带正确答案** —— 答案下发到客户端等于开卷）。
 */
router.post('/exams/:id/start', (req, res) => {
  const u = auth(req, res); if (!u) return;
  const eid = Number(req.params.id);
  const e = db.prepare('SELECT * FROM tr_exam WHERE id = ?').get(eid);
  if (!e) return res.status(404).json({ error: '考试不存在' });

  const ch = db.prepare('SELECT course_id FROM tr_chapter WHERE id = ?').get(e.chapter_id);
  if (!ch) return res.status(404).json({ error: '章节不存在' });

  const pct = chapterProgressPct(u.id, e.chapter_id);
  if (pct < e.min_progress) {
    return res.status(403).json({
      error: `本章进度 ${pct}%，未达到 ${e.min_progress}% 不能参加考试`,
      code: 'progress_not_reached',
      progressPct: pct,
      minProgress: e.min_progress,
    });
  }

  const used = db.prepare('SELECT COUNT(*) n FROM tr_sheet WHERE user_id = ? AND exam_id = ?').get(u.id, eid).n;
  if (used >= e.attempt_limit) {
    return res.status(403).json({
      error: `考试机会已用完（${e.attempt_limit} 次）`,
      code: 'no_attempt_left',
      used,
    });
  }

  // 🔴 并发保护靠 tr_sheet 上的 UNIQUE(user_id, exam_id, attempt_no)，
  //    不是靠上面那个 COUNT —— 两次同时点开始，COUNT 会同时读到 0。
  let sheetId;
  try {
    const info = db.prepare(`
      INSERT INTO tr_sheet (user_id, exam_id, attempt_no, started_at) VALUES (?,?,?,?)`)
      .run(u.id, eid, used + 1, now());
    sheetId = info.lastInsertRowid;
  } catch (_) {
    return res.status(409).json({ error: '本次考试已开始，请勿重复点击', code: 'already_started' });
  }

  let qs = db.prepare('SELECT * FROM tr_question WHERE exam_id = ? ORDER BY sort, id').all(eid);
  // 抽题：随机取 question_count 道（0 = 全部）。
  // 随机是为了"两个人考的不是一个卷"，但对同一个人**必须稳定**
  // —— 所以抽中的题 ids 存进 tr_answer（占位）里，续考时按这张卷子来。
  if (e.question_count > 0 && qs.length > e.question_count) {
    const picked = [];
    const pool = qs.slice();
    while (picked.length < e.question_count && pool.length) {
      picked.push(pool.splice(Math.floor(Math.random() * pool.length), 1)[0]);
    }
    qs = picked.sort((a, b) => a.sort - b.sort || a.id - b.id);
  }
  // 🔴 占位行必须**四个参数全传**。只传两个的话 chosen 会拿到 NULL，
  //    触发 NOT NULL —— 而 `OR IGNORE` 会把这个失败**静默吞掉**，
  //    结果是一张"看起来发下去了、其实一道题都没有"的空卷子，
  //    交卷时每题都因为"不在本卷"被跳过，学员拿 0 分，全程没有任何报错。
  //    （这个 bug 就是这么出的，最后靠"detail 是空的"才反查出来。）
  for (const q of qs) {
    db.prepare('INSERT OR IGNORE INTO tr_answer (sheet_id, question_id, chosen, correct) VALUES (?,?,?,?)')
      .run(sheetId, q.id, '', 0);
  }
  // 兜底：真没插进去就当场报错，绝不发空卷。
  // 上面那个静默失败的代价是"学员考了 0 分但没人知道为什么"。
  const seeded = db.prepare('SELECT COUNT(*) n FROM tr_answer WHERE sheet_id = ?').get(sheetId).n;
  if (qs.length && seeded !== qs.length) {
    return res.status(500).json({ error: '生成答卷失败（题目未落卷），请联系管理员', code: 'sheet_seed_failed' });
  }
  if (!qs.length) {
    return res.status(400).json({ error: '这场考试还没有题目', code: 'no_question' });
  }

  res.json({
    sheetId,
    attemptNo: used + 1,
    exam: { id: e.id, title: e.title, passScore: e.pass_score, attemptLimit: e.attempt_limit },
    startedAt: db.prepare('SELECT started_at FROM tr_sheet WHERE id = ?').get(sheetId).started_at,
    questions: qs.map((q) => ({
      id: q.id,
      type: q.type,
      stem: q.stem,
      score: q.score,
      // 🔴 不带 correct 字段：答案下发到客户端就是开卷考试
      options: db.prepare('SELECT id, label, content FROM tr_option WHERE question_id = ? ORDER BY id').all(q.id),
    })),
  });
});

/**
 * POST /api/training/sheets/:id/submit —— 交卷判分
 * body: { answers: [{ questionId, chosen }] }  chosen 是 label 串（多选如 "AB"）
 *
 * 🔴 只能交一次：交完再交必须 409，否则可以"交一次看分数、改答案再交一次"。
 */
router.post('/sheets/:id/submit', (req, res) => {
  const u = auth(req, res); if (!u) return;
  const sid = Number(req.params.id);
  const sheet = db.prepare('SELECT * FROM tr_sheet WHERE id = ? AND user_id = ?').get(sid, u.id);
  if (!sheet) return res.status(404).json({ error: '答卷不存在' });
  if (sheet.submitted_at > 0) {
    return res.status(409).json({ error: '本卷已提交，不能重复交卷', code: 'already_submitted' });
  }

  const e = db.prepare('SELECT * FROM tr_exam WHERE id = ?').get(sheet.exam_id);
  const answers = Array.isArray(req.body?.answers) ? req.body.answers : [];
  // 交卷时读一次应用参数（管理台可关掉"回显正确答案"）
  const showAnswer = appoverrides.paramOf('training', 'showAnswer') !== false;

  let score = 0;
  const detail = [];
  for (const a of answers) {
    const qid = Number(a?.questionId);
    if (!qid) continue;
    // 🔴 只判**这张卷子抽到的题**：拿别的题 id 来刷分必须无效
    const inSheet = db.prepare('SELECT 1 FROM tr_answer WHERE sheet_id = ? AND question_id = ?').get(sid, qid);
    if (!inSheet) continue;
    const q = db.prepare('SELECT * FROM tr_question WHERE id = ?').get(qid);
    if (!q) continue;

    const chosen = String(a?.chosen == null ? '' : a.chosen).trim().slice(0, 20);
    const opts = db.prepare('SELECT label, correct FROM tr_option WHERE question_id = ?').all(qid);
    const right = new Set(opts.filter((o) => o.correct).map((o) => o.label));
    const got = new Set(chosen.split('').filter((c) => /^[A-Za-z0-9]$/.test(c)).map((c) => c.toUpperCase()));
    // 多选：全对才得分；单选/判断：选中即得分。集合相等同时覆盖两种情况
    const correct = right.size > 0 && got.size === right.size && [...right].every((x) => got.has(x));
    if (correct) score += q.score;

    db.prepare('UPDATE tr_answer SET chosen = ?, correct = ? WHERE sheet_id = ? AND question_id = ?')
      .run(chosen, correct ? 1 : 0, sid, qid);
    detail.push({ questionId: qid, chosen, correct, score: correct ? q.score : 0 });
  }

  const pass = score >= e.pass_score ? 1 : 0;
  db.prepare('UPDATE tr_sheet SET score = ?, pass = ?, submitted_at = ? WHERE id = ?')
    .run(score, pass, now(), sid);

  res.json({
    sheetId: sid,
    score,
    passScore: e.pass_score,
    pass: !!pass,
    // 判完就把正确答案回给客户端（对答案用）—— 未提交的卷子不给答案。
    //
    // 🔴 但这是**可关的**（app_overrides → training.showAnswer）：
    //    考试的目的是让人会，不是让人把答案传下去。关掉之后只少给答案，
    //    分数、及格线、每题对错（correct）照给 —— 那些是成绩单的一部分，
    //    不是答案本身。所以关掉它不会让学员看不懂自己的成绩。
    answerHidden: !showAnswer,
    detail: detail.map((d) => {
      const opts = db.prepare('SELECT label, content, correct FROM tr_option WHERE question_id = ? ORDER BY id')
        .all(d.questionId);
      return {
        ...d,
        // 关掉时给 null 而不是空串：空串会被读成"这题没有正确答案"，那是另一回事
        rightLabels: showAnswer ? opts.filter((o) => o.correct).map((o) => o.label).join('') : null,
      };
    }),
  });
});

/** GET /api/training/sheets/:id —— 看自己的答卷（已交卷才有答案） */
router.get('/sheets/:id', (req, res) => {
  const u = auth(req, res); if (!u) return;
  const s = db.prepare('SELECT * FROM tr_sheet WHERE id = ? AND user_id = ?').get(Number(req.params.id), u.id);
  if (!s) return res.status(404).json({ error: '答卷不存在' });
  const answers = db.prepare('SELECT question_id, chosen, correct FROM tr_answer WHERE sheet_id = ?').all(s.id);
  res.json({
    sheet: {
      id: s.id, examId: s.exam_id, attemptNo: s.attempt_no,
      score: s.score, pass: !!s.pass,
      startedAt: s.started_at, submittedAt: s.submitted_at,
      submitted: s.submitted_at > 0,
    },
    answers: answers.map((a) => ({ questionId: a.question_id, chosen: a.chosen, correct: !!a.correct })),
  });
});

// ============================================================
// 管理端：课程 / 章节 / 课时 / 考试的增删改
// ============================================================

/**
 * POST /api/training/admin/courses
 *
 * 建课程时可以顺手把课件带上（`sections`），一次建完 课程 → 章节 → 课时。
 * 为什么要能一次建：管理台上"新建课程"里填完还要再点进去建章节、建课时、
 * 再逐条挂课件，走一遍下来一条课就十几次点击，人直接放弃。
 *
 * 不带 `sections` 就是老行为（只建一个空课程），前端两边共用一个接口。
 * ⚠️ 整个 sections 落在**同一个事务**里：建到一半炸了不能留下半个课程。
 */
router.post('/admin/courses', (req, res) => {
  const u = auth(req, res, { needAdmin: true }); if (!u) return;
  const title = str(req.body?.title, MAX_TITLE);
  if (!title) return res.status(400).json({ error: '课程名必填' });

  const info = db.prepare(`
    INSERT INTO tr_course (title, intro, category, required, published, created_by, created_at)
    VALUES (?,?,?,?,?,?,?)`)
    .run(title, str(req.body?.intro, 2000), str(req.body?.category, 60),
      req.body?.required ? 1 : 0, req.body?.published ? 1 : 0, u.id, now());
  const cid = info.lastInsertRowid;

  const sections = Array.isArray(req.body?.sections) ? req.body.sections : null;
  if (sections) {
    db.exec('BEGIN');
    try {
      for (const sec of sections) {
        const chTitle = str(sec?.title, MAX_TITLE);
        if (!chTitle) continue;
        const lessons = Array.isArray(sec?.lessons) ? sec.lessons : [];
        const chInfo = db.prepare('INSERT INTO tr_chapter (course_id, title, sort) VALUES (?,?,?)')
          .run(cid, chTitle, num(sec?.sort, 0));
        const chId = chInfo.lastInsertRowid;
        lessons.slice(0, MAX_LESSONS_PER_COURSE).forEach((raw, i) => {
          const f = lessonFields(raw);
          if (!f.title) return;
          db.prepare(`
            INSERT INTO tr_lesson (chapter_id, title, kind, file_id, link_url, duration_sec, sort)
            VALUES (?,?,?,?,?,?,?)`)
            .run(chId, f.title, f.kind, f.fileId, f.linkUrl, f.durationSec, num(raw?.sort, i));
        });
      }
      db.exec('COMMIT');
    } catch (err) {
      db.exec('ROLLBACK');
      // ⚠️ 课程已经插进去了，回滚只能撤销结构。这里不删课程：删了的话前端拿
      //    到的 id 会指向一门空课，反而更难查。让外层报原样错误即可。
      return res.status(500).json({ error: '建课时失败：' + err.message, courseId: cid });
    }
  }
  res.json({ ok: true, id: cid });
});

router.patch('/admin/courses/:id', (req, res) => {
  const u = auth(req, res, { needAdmin: true }); if (!u) return;
  const id = Number(req.params.id);
  if (!db.prepare('SELECT 1 FROM tr_course WHERE id = ?').get(id)) {
    return res.status(404).json({ error: '课程不存在' });
  }
  const set = [];
  const args = [];
  if (typeof req.body?.title === 'string' && req.body.title.trim()) { set.push('title = ?'); args.push(str(req.body.title, MAX_TITLE)); }
  if (typeof req.body?.intro === 'string') { set.push('intro = ?'); args.push(str(req.body.intro, 2000)); }
  if (typeof req.body?.category === 'string') { set.push('category = ?'); args.push(str(req.body.category, 60)); }
  if (req.body?.required !== undefined) { set.push('required = ?'); args.push(req.body.required ? 1 : 0); }
  if (req.body?.published !== undefined) { set.push('published = ?'); args.push(req.body.published ? 1 : 0); }
  if (!set.length) return res.status(400).json({ error: '没有要改的字段' });
  args.push(id);
  db.prepare(`UPDATE tr_course SET ${set.join(', ')} WHERE id = ?`).run(...args);
  res.json({ ok: true, id });
});

router.delete('/admin/courses/:id', (req, res) => {
  const u = auth(req, res, { needAdmin: true }); if (!u) return;
  const id = Number(req.params.id);
  // 级联：课程没了，它的章节/课时/考试/报名/进度都得跟着走，
  // 不然会留下一堆孤儿行（列表里不显示，但进度统计会莫名偏高）。
  db.exec('BEGIN');
  try {
    const chs = db.prepare('SELECT id FROM tr_chapter WHERE course_id = ?').all(id).map((r) => r.id);
    for (const ch of chs) {
      const exams = db.prepare('SELECT id FROM tr_exam WHERE chapter_id = ?').all(ch).map((r) => r.id);
      for (const e of exams) {
        const qs = db.prepare('SELECT id FROM tr_question WHERE exam_id = ?').all(e).map((r) => r.id);
        for (const q of qs) db.prepare('DELETE FROM tr_option WHERE question_id = ?').run(q);
        db.prepare('DELETE FROM tr_question WHERE exam_id = ?').run(e);
        db.prepare('DELETE FROM tr_sheet WHERE exam_id = ?').run(e);
      }
      const ls = db.prepare('SELECT id FROM tr_lesson WHERE chapter_id = ?').all(ch).map((r) => r.id);
      for (const l of ls) db.prepare('DELETE FROM tr_progress WHERE lesson_id = ?').run(l);
      db.prepare('DELETE FROM tr_lesson WHERE chapter_id = ?').run(ch);
    }
    db.prepare('DELETE FROM tr_chapter WHERE course_id = ?').run(id);
    db.prepare('DELETE FROM tr_enroll WHERE course_id = ?').run(id);
    db.prepare('DELETE FROM tr_course WHERE id = ?').run(id);
    db.exec('COMMIT');
  } catch (err) {
    db.exec('ROLLBACK');
    return res.status(500).json({ error: err.message });
  }
  res.json({ ok: true, id });
});

router.post('/admin/chapters', (req, res) => {
  const u = auth(req, res, { needAdmin: true }); if (!u) return;
  const courseId = num(req.body?.courseId, 0);
  const title = str(req.body?.title, MAX_TITLE);
  if (!courseId || !title) return res.status(400).json({ error: 'courseId 与 title 必填' });
  if (!db.prepare('SELECT 1 FROM tr_course WHERE id = ?').get(courseId)) {
    return res.status(404).json({ error: '课程不存在' });
  }
  const info = db.prepare('INSERT INTO tr_chapter (course_id, title, sort) VALUES (?,?,?)')
    .run(courseId, title, num(req.body?.sort, 0));
  res.json({ ok: true, id: info.lastInsertRowid });
});

router.post('/admin/lessons', (req, res) => {
  const u = auth(req, res, { needAdmin: true }); if (!u) return;
  const chapterId = num(req.body?.chapterId, 0);
  const f = lessonFields(req.body);
  if (!chapterId || !f.title) return res.status(400).json({ error: 'chapterId 与 title 必填' });
  if (!db.prepare('SELECT 1 FROM tr_chapter WHERE id = ?').get(chapterId)) {
    return res.status(404).json({ error: '章节不存在' });
  }
  const cnt = db.prepare('SELECT COUNT(*) n FROM tr_lesson l JOIN tr_chapter c ON c.id = l.chapter_id WHERE c.id = ?').get(chapterId).n;
  if (cnt >= MAX_LESSONS_PER_COURSE) {
    return res.status(400).json({ error: `单个章节课时数上限 ${MAX_LESSONS_PER_COURSE}` });
  }
  const info = db.prepare(`
    INSERT INTO tr_lesson (chapter_id, title, kind, file_id, link_url, duration_sec, sort)
    VALUES (?,?,?,?,?,?,?)`)
    .run(chapterId, f.title, f.kind, f.fileId, f.linkUrl, f.durationSec, f.sort);
  res.json({ ok: true, id: info.lastInsertRowid });
});

/**
 * PATCH /api/training/admin/lessons/:id —— 改课时（含改课件）
 *
 * 🔴 这是补一个真 bug：0.21.5 之前只有"新增课时"，没有改。管理台上建完课时后
 *    发现挂错课件 / 想补个外链链接，只能删掉重建 —— 而**历史进度跟着 lesson
 *    一起没了**，学员的学习记录凭空消失，界面上还看不出来。
 *    改文案也要重建的话，这个口子必须补上。
 *
 * 课件（fileId / linkUrl）和文字（title / kind / durationSec）可以只改一边，
 * 所以逐个字段判断，没传就保持原值。
 */
router.patch('/admin/lessons/:id', (req, res) => {
  const u = auth(req, res, { needAdmin: true }); if (!u) return;
  const id = Number(req.params.id);
  if (!db.prepare('SELECT 1 FROM tr_lesson WHERE id = ?').get(id)) {
    return res.status(404).json({ error: '课时不存在' });
  }

  const set = [];
  const args = [];
  if (req.body?.title !== undefined) {
    const t = str(req.body.title, MAX_TITLE);
    if (!t) return res.status(400).json({ error: '课时名不能为空' });
    set.push('title = ?'); args.push(t);
  }
  if (req.body?.kind !== undefined) {
    const k = req.body.kind === 'doc' ? 'doc' : 'video';
    set.push('kind = ?'); args.push(k);
  }
  if (req.body?.fileId !== undefined) {
    set.push('file_id = ?'); args.push(num(req.body.fileId, 0) || null);
  }
  // 传空串 = 清掉外链；传了非 http(s) 的乱七八糟东西 = 不打进库。
  if (req.body?.linkUrl !== undefined) { set.push('link_url = ?'); args.push(linkUrl(req.body.linkUrl)); }
  if (req.body?.durationSec !== undefined) {
    set.push('duration_sec = ?'); args.push(Math.max(0, Math.floor(num(req.body.durationSec, 0))));
  }
  if (req.body?.sort !== undefined) { set.push('sort = ?'); args.push(num(req.body.sort, 0)); }
  if (!set.length) return res.status(400).json({ error: '没有要改的字段' });

  args.push(id);
  db.prepare(`UPDATE tr_lesson SET ${set.join(', ')} WHERE id = ?`).run(...args);
  res.json({ ok: true, id });
});

/** 考试 + 题目一次建好（题目是考试的组成部分，分开建会出现"没有题的考试"） */
router.post('/admin/exams', (req, res) => {
  const u = auth(req, res, { needAdmin: true }); if (!u) return;
  const chapterId = num(req.body?.chapterId, 0);
  const title = str(req.body?.title, MAX_TITLE);
  if (!chapterId || !title) return res.status(400).json({ error: 'chapterId 与 title 必填' });
  if (!db.prepare('SELECT 1 FROM tr_chapter WHERE id = ?').get(chapterId)) {
    return res.status(404).json({ error: '章节不存在' });
  }

  const questions = Array.isArray(req.body?.questions) ? req.body.questions : [];
  db.exec('BEGIN');
  try {
    const info = db.prepare(`
      INSERT INTO tr_exam (chapter_id, title, pass_score, attempt_limit, min_progress, question_count, created_at)
      VALUES (?,?,?,?,?,?,?)`)
      .run(chapterId, title,
        Math.max(0, Math.floor(num(req.body?.passScore, 60))),
        Math.max(1, Math.floor(num(req.body?.attemptLimit, 1))),
        Math.min(100, Math.max(0, Math.floor(num(req.body?.minProgress, 100)))),
        Math.max(0, Math.floor(num(req.body?.questionCount, 0))),
        now());
    const eid = info.lastInsertRowid;

    questions.forEach((q, qi) => {
      const stem = str(q?.stem, MAX_STEM);
      if (!stem) return;
      const type = ['single', 'multi', 'judge'].includes(q?.type) ? q.type : 'single';
      const qi2 = db.prepare('INSERT INTO tr_question (exam_id, type, stem, score, sort) VALUES (?,?,?,?,?)')
        .run(eid, type, stem, Math.max(0, Math.floor(num(q?.score, 10))), num(q?.sort, qi));
      const qid = qi2.lastInsertRowid;
      const labels = ['A', 'B', 'C', 'D', 'E', 'F', 'G', 'H'];
      (Array.isArray(q?.options) ? q.options : []).slice(0, labels.length).forEach((o, oi) => {
        db.prepare('INSERT INTO tr_option (question_id, label, content, correct) VALUES (?,?,?,?)')
          .run(qid, labels[oi], str(o?.content, MAX_OPTION), o?.correct ? 1 : 0);
      });
    });
    db.exec('COMMIT');
    res.json({ ok: true, id: eid });
  } catch (err) {
    db.exec('ROLLBACK');
    res.status(500).json({ error: err.message });
  }
});

// ============================================================
// 管理端：课程详情 / 删除子项 / 成绩
// ============================================================

/**
 * GET /api/training/admin/courses —— 管理端课程列表（**含未发布**）
 *
 * 学员侧列表只给 published=1；管理端必须能看到草稿，否则"建好了但忘了发布"
 * 会表现为"学员说没有这门课、管理员说有"，两边都对着自己的界面说话。
 */
router.get('/admin/courses', (req, res) => {
  const u = auth(req, res, { needAdmin: true }); if (!u) return;
  const rows = db.prepare(`
    SELECT c.*,
           (SELECT COUNT(*) FROM tr_chapter x WHERE x.course_id = c.id) AS chapter_count,
           (SELECT COUNT(*) FROM tr_lesson l JOIN tr_chapter x ON x.id = l.chapter_id
              WHERE x.course_id = c.id) AS lesson_count,
           (SELECT COUNT(*) FROM tr_exam e JOIN tr_chapter x ON x.id = e.chapter_id
              WHERE x.course_id = c.id) AS exam_count,
           (SELECT COUNT(*) FROM tr_enroll r WHERE r.course_id = c.id) AS enroll_count
    FROM tr_course c
    ORDER BY c.published DESC, c.id DESC`).all();
  res.json({ items: rows, total: rows.length });
});

/** GET /api/training/admin/courses/:id —— 详情（章节 + 课时 + 考试 + 题目），用于编辑页 */
router.get('/admin/courses/:id', (req, res) => {
  const u = auth(req, res, { needAdmin: true }); if (!u) return;
  const id = Number(req.params.id);
  const course = db.prepare('SELECT * FROM tr_course WHERE id = ?').get(id);
  if (!course) return res.status(404).json({ error: '课程不存在' });

  const chapters = db.prepare('SELECT * FROM tr_chapter WHERE course_id = ? ORDER BY sort, id').all(id);
  for (const ch of chapters) {
    ch.lessons = db.prepare('SELECT * FROM tr_lesson WHERE chapter_id = ? ORDER BY sort, id').all(ch.id);
    ch.exams = db.prepare('SELECT * FROM tr_exam WHERE chapter_id = ? ORDER BY id').all(ch.id);
    for (const e of ch.exams) {
      const qs = db.prepare('SELECT * FROM tr_question WHERE exam_id = ? ORDER BY sort, id').all(e.id);
      for (const q of qs) {
        q.options = db.prepare('SELECT id,label,content,correct FROM tr_option WHERE question_id = ? ORDER BY id').all(q.id);
      }
      e.questions = qs;
    }
  }
  res.json({ course, chapters });
});

/** 删章节：课时/考试/进度/答卷要一起走，否则留下孤儿行（列表不显示，但统计会莫名偏高） */
router.delete('/admin/chapters/:id', (req, res) => {
  const u = auth(req, res, { needAdmin: true }); if (!u) return;
  const id = Number(req.params.id);
  db.exec('BEGIN');
  try {
    const exams = db.prepare('SELECT id FROM tr_exam WHERE chapter_id = ?').all(id).map((r) => r.id);
    for (const e of exams) {
      const qs = db.prepare('SELECT id FROM tr_question WHERE exam_id = ?').all(e).map((r) => r.id);
      for (const q of qs) db.prepare('DELETE FROM tr_option WHERE question_id = ?').run(q);
      db.prepare('DELETE FROM tr_question WHERE exam_id = ?').run(e);
      db.prepare('DELETE FROM tr_sheet WHERE exam_id = ?').run(e);
    }
    const ls = db.prepare('SELECT id FROM tr_lesson WHERE chapter_id = ?').all(id).map((r) => r.id);
    for (const l of ls) db.prepare('DELETE FROM tr_progress WHERE lesson_id = ?').run(l);
    db.prepare('DELETE FROM tr_lesson WHERE chapter_id = ?').run(id);
    db.prepare('DELETE FROM tr_chapter WHERE id = ?').run(id);
    db.exec('COMMIT');
  } catch (err) {
    db.exec('ROLLBACK');
    return res.status(500).json({ error: err.message });
  }
  res.json({ ok: true, id });
});

router.delete('/admin/lessons/:id', (req, res) => {
  const u = auth(req, res, { needAdmin: true }); if (!u) return;
  const id = Number(req.params.id);
  db.prepare('DELETE FROM tr_progress WHERE lesson_id = ?').run(id);
  db.prepare('DELETE FROM tr_lesson WHERE id = ?').run(id);
  res.json({ ok: true, id });
});

router.delete('/admin/exams/:id', (req, res) => {
  const u = auth(req, res, { needAdmin: true }); if (!u) return;
  const id = Number(req.params.id);
  db.exec('BEGIN');
  try {
    const qs = db.prepare('SELECT id FROM tr_question WHERE exam_id = ?').all(id).map((r) => r.id);
    for (const q of qs) db.prepare('DELETE FROM tr_option WHERE question_id = ?').run(q);
    db.prepare('DELETE FROM tr_question WHERE exam_id = ?').run(id);
    db.prepare('DELETE FROM tr_sheet WHERE exam_id = ?').run(id);
    db.prepare('DELETE FROM tr_exam WHERE id = ?').run(id);
    db.exec('COMMIT');
  } catch (err) {
    db.exec('ROLLBACK');
    return res.status(500).json({ error: err.message });
  }
  res.json({ ok: true, id });
});

/**
 * GET /api/training/admin/sheets —— 成绩查询
 *
 * 培训中心的意义全在这个接口上：**谁学了、考了多少、过没过**。
 * 没有它，课程做得再漂亮也只是个视频播放器。
 *
 * 过滤：examId / courseId / userId / passed=1|0；分页按 paging 的通用口径。
 * ⚠️ 默认时间窗是 30 天（`parseList` 的默认），而成绩是要查历史的 ——
 *    所以这里显式传 allTime 语义：`allTime=1` 或传了 from/to 才按时间过滤，
 *    否则**不限时间**。不这么写的话，三个月前考的卷子会静默消失，
 *    界面上还看不出来是被截断了。
 */
router.get('/admin/sheets', (req, res) => {
  const u = auth(req, res, { needAdmin: true }); if (!u) return;
  const list = parseList(req.query, { defaultPageSize: 50 });
  if (list.error) return res.status(400).json({ error: list.error });

  const where = ['1=1'];
  const params = [];

  const examId = num(req.query.examId, 0);
  if (examId) { where.push('s.exam_id = ?'); params.push(examId); }

  const courseId = num(req.query.courseId, 0);
  if (courseId) {
    where.push(`s.exam_id IN (SELECT e.id FROM tr_exam e
                 JOIN tr_chapter c ON c.id = e.chapter_id WHERE c.course_id = ?)`);
    params.push(courseId);
  }

  const userId = num(req.query.userId, 0);
  if (userId) { where.push('s.user_id = ?'); params.push(userId); }

  if (req.query.passed === '1') where.push('s.pass = 1');
  else if (req.query.passed === '0') where.push('s.pass = 0');

  // 时间窗：只在显式传了 from/to 时才生效（成绩要能查历史，不能默认截 30 天）
  const from = req.query.from === undefined || req.query.from === '' ? null : num(req.query.from, NaN);
  const to = req.query.to === undefined || req.query.to === '' ? null : num(req.query.to, NaN);
  if (from !== null && Number.isFinite(from)) { where.push('s.started_at >= ?'); params.push(from); }
  if (to !== null && Number.isFinite(to)) { where.push('s.started_at <= ?'); params.push(to); }

  const w = where.join(' AND ');
  const total = db.prepare(`SELECT COUNT(*) n FROM tr_sheet s WHERE ${w}`).get(...params).n;
  const rows = db.prepare(`
    SELECT s.*, u.username, u.nickname,
           e.title AS exam_title, e.pass_score,
           c.id AS course_id, c.title AS course_title
    FROM tr_sheet s
    LEFT JOIN users u ON u.id = s.user_id
    LEFT JOIN tr_exam e ON e.id = s.exam_id
    LEFT JOIN tr_chapter ch ON ch.id = e.chapter_id
    LEFT JOIN tr_course c ON c.id = ch.course_id
    WHERE ${w}
    ORDER BY s.started_at DESC, s.id DESC
    LIMIT ? OFFSET ?`).all(...params, list.pageSize, list.offset);
  res.json(envelope(list, rows, total));
});

/* ==================== 培训文件管理（独立的培训文件区） ====================
 * 培训中心之前没有"独立的培训文件管理"——课件/封面图散落在通用文件管理里，
 * 管理员想清理、想看哪些文件被哪些课程引用，得去翻全部文件。这里把
 * "被培训模块引用过的文件"单独拎出来成一块，并支持删除（仅限无引用残留的）。
 */

/** GET /api/training/admin/files —— 列出被培训课程/课时引用的文件 */
router.get('/admin/files', (req, res) => {
  const u = auth(req, res, { needAdmin: true }); if (!u) return;
  const files = db.prepare(`
    SELECT f.id, f.name, f.mime, f.size, f.path, f.created_at,
      (SELECT COUNT(*) FROM tr_lesson l WHERE l.file_id = f.id) lesson_refs,
      (SELECT COUNT(*) FROM tr_course c WHERE c.cover_file_id = f.id) cover_refs
    FROM files f
    WHERE f.id IN (SELECT file_id FROM tr_lesson WHERE file_id IS NOT NULL)
       OR f.id IN (SELECT cover_file_id FROM tr_course WHERE cover_file_id IS NOT NULL)
    ORDER BY f.created_at DESC
  `).all().map((f) => ({
    id: f.id, name: f.name, mime: f.mime, size: f.size,
    path: f.path, createdAt: f.created_at,
    lessonRefs: f.lesson_refs, coverRefs: f.cover_refs,
    refs: f.lesson_refs + f.cover_refs,
  }));
  res.json({ files });
});

/** DELETE /api/training/admin/files/:id —— 删培训文件（仅限已无任何引用的） */
router.delete('/admin/files/:id', (req, res) => {
  const u = auth(req, res, { needAdmin: true }); if (!u) return;
  const id = Number(req.params.id);
  const refs = db.prepare(`
    SELECT (SELECT COUNT(*) FROM tr_lesson WHERE file_id=?) + (SELECT COUNT(*) FROM tr_course WHERE cover_file_id=?) n
  `).get(id, id).n;
  if (refs > 0) return res.status(400).json({ error: '该文件仍被培训课程引用，不能删除（先去课程结构里解绑）' });
  const f = db.prepare('SELECT * FROM files WHERE id=?').get(id);
  if (!f) return res.status(404).json({ error: '文件不存在' });
  db.prepare('DELETE FROM files WHERE id=?').run(id);
  try { fs.unlinkSync(path.join(config.FILES_DIR, f.path)); } catch {}
  res.json({ ok: true });
});

module.exports = router;
