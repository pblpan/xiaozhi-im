#!/usr/bin/env node
'use strict';

/**
 * 培训中心素材导入器
 *
 *   node server/tools/import_training.js --dir "Y:\培训资料"            # 预览（默认）
 *   node server/tools/import_training.js --dir "Y:\培训资料" --apply
 *   node server/tools/import_training.js --dir "Y:\培训资料" --apply --copy
 *
 * ── 为什么默认只预览 ────────────────────────────────────────
 * 素材盘是 200+ 个文件的真实目录，层级不一定是想象的样子。
 * 直接 --apply 进去，出来的课程结构错了就得一门门删（删还会带走学员进度）。
 * 所以默认**只预览**：先把"我会怎么理解这个目录"打出来，确认了再导。
 *
 * ── 目录怎么被理解 ──────────────────────────────────────────
 *   培训资料/
 *     ├── 生鲜陈列/            ← 一级目录 = 分类（category）
 *     │     ├── 陈列基础/      ← 二级 = 课程
 *     │     │     ├── 01 原则/ ← 三级 = 章节（有就按它分章）
 *     │     │     │     ├── 第一节.mp4   ← 文件 = 课时
 *     │     │     │     └── 课件.pdf
 *     │     │     └── 02 实操/
 *     │     └── 陈列进阶/
 *     └── 防损/…
 *
 * 三级不存在时（课程目录下直接是文件），整门课放进一个"课程名"章节里，
 * 不造空章节 —— 空章节会让学员点进去发现什么都没有。
 *
 * ── 幂等（🔴 这条是重点） ────────────────────────────────────
 * 素材盘会被反复挂、反复导。判据是：
 *   课程 = (category, title)   章节 = (course_id, title)   课时 = (chapter_id, title)
 * 已存在就**跳过**，不新建也不覆盖。所以重复导一次是安全的，
 * 只有新增的文件会被加进去。
 *
 * ── 关于 --copy ────────────────────────────────────────────
 * 默认**只登记原路径**、不复制文件：素材盘本来就在那，复制一份是白占空间。
 * 但如果服务端跑在另一台机器（飞牛 Docker）上，它读不到你本机的盘，
 * 这时用 --copy 把文件复制进 FILES_DIR。
 */

const fs = require('fs');
const path = require('path');
const os = require('os');

// ── 参数 ──────────────────────────────────────────────────
function parseArgs(argv) {
  const a = { dir: '', apply: false, copy: false, dataDir: process.env.DATA_DIR || '', quiet: false, unknown: '' };
  for (let i = 2; i < argv.length; i++) {
    const k = argv[i];
    if (k === '--apply') a.apply = true;
    else if (k === '--copy') a.copy = true;
    else if (k === '--quiet') a.quiet = true;
    else if (k === '--dir') a.dir = argv[++i] || '';
    else if (k === '--data-dir') a.dataDir = argv[++i] || '';
    else if (k === '--help' || k === '-h') a.help = true;
    else if (k.startsWith('-')) a.unknown = a.unknown || k;
  }
  return a;
}

const VIDEO_EXT = ['.mp4', '.mkv', '.mov', '.avi', '.flv', '.wmv', '.webm', '.m4v', '.ts'];
const DOC_EXT = ['.pdf', '.ppt', '.pptx', '.doc', '.docx', '.xls', '.xlsx', '.txt', '.md'];
const isVideo = (f) => VIDEO_EXT.includes(path.extname(f).toLowerCase());
const isDoc = (f) => DOC_EXT.includes(path.extname(f).toLowerCase());

/** 跳过 junk：macOS 的 .DS_Store、Windows 缩略图、临时文件 */
function isJunk(name) {
  return name.startsWith('.') || name === 'Thumbs.db' || name.startsWith('~$');
}

/** "01 陈列原则" → 排序值 1（文件名带序号是最常见的自然排序来源） */
function sortOf(name) {
  const m = /^\s*(\d+)/.exec(name);
  return m ? Number(m[1]) : 999;
}

/**
 * 去掉前缀序号，标题更干净："01 陈列原则" → "陈列原则"
 *
 * 🔴 **不能无脑去掉开头所有数字。** 真素材里有「2024年新规」「2023年度总结」
 * 这种名字，无脑去会变成「年新规」—— 年份不是序号，而且改坏了完全看不出来
 * （标题只是难看一点点，没人会去核对）。
 *
 * 判据：数字后面**必须**是分隔符（空格 / . / _ / - / 、），
 * 或者数字 ≤2 位且后面紧跟着的非数字字符（"01早会"这种不带空格的写法）。
 * "2024年新规" 两条都不满足（4 位、后面是"年"不是分隔符）→ 原样保留。
 */
function titleOf(name) {
  const base = path.basename(name, path.extname(name));
  const m = /^\s*\d{1,4}[._\-、\s]\s*/.exec(base)      // "01 早会" / "123-章节" / "1.绪论"
    || /^\s*\d{1,2}(?!\d)\s*/.exec(base);              // "01早会"（数字后面不能再是数字）
  const stripped = m ? base.slice(m[0].length).trim() : base;
  return stripped || base;
}

// ── 扫描 ──────────────────────────────────────────────────

/**
 * 扫出一个"课程树"。不碰数据库，因此可以纯 dry-run 地验证
 * （测试里造个临时目录就能跑，不需要真素材盘）。
 */
function scan(root) {
  const out = { courses: [], skipped: 0, files: 0 };
  if (!fs.existsSync(root)) throw new Error('目录不存在: ' + root);
  if (!fs.statSync(root).isDirectory()) throw new Error('不是目录: ' + root);

  const entries = fs.readdirSync(root).filter((n) => !isJunk(n));
  const cats = entries.filter((n) => fs.statSync(path.join(root, n)).isDirectory());
  const rootFiles = entries
    .filter((n) => fs.statSync(path.join(root, n)).isFile())
    .filter((n) => isVideo(n) || isDoc(n));

  // 🔴 root **自己就是一门课**的情况（直接 --dir 指到课程目录上）。
  // 不认这种情况的话，扫出来是 0 门课 —— 而且**不报错**，
  // 用户只会看到"导入完成：新增 0"，以为盘里没东西。
  if (rootFiles.length) {
    out.courses.push({
      category: '',
      title: path.basename(root),
      path: root,
      chapters: [{
        title: path.basename(root),
        sort: 0,
        lessons: rootFiles.sort((a, b) => sortOf(a) - sortOf(b) || a.localeCompare(b))
          .map((f) => lessonOf(path.join(root, f))),
      }],
    });
  }

  // 一级目录可能被当成分类，但也可能**它本身就是课程名**
  // （比如素材盘是 培训资料/店长管理/*.mp4，没有再下一层）。
  // 判据：这个目录下有没有"再一层目录"。有 → 它是分类；全是文件 → 它是一门课。
  for (const cat of cats) {
    const catPath = path.join(root, cat);
    const subs = fs.readdirSync(catPath).filter((n) => !isJunk(n));
    const subDirs = subs.filter((n) => fs.statSync(path.join(catPath, n)).isDirectory());
    const subFiles = subs.filter((n) => fs.statSync(path.join(catPath, n)).isFile());

    if (subDirs.length === 0 && subFiles.length > 0) {
      // 一级就是课程：分类留空
      out.courses.push(buildCourse(catPath, '', titleOf(cat)));
      continue;
    }
    for (const cname of subDirs) {
      out.courses.push(buildCourse(path.join(catPath, cname), titleOf(cat), titleOf(cname)));
    }
  }

  for (const c of out.courses) {
    out.files += c.chapters.reduce((n, ch) => n + ch.lessons.length, 0);
    // 一个课时都没有的课程不进列表：点进去是空的，比不显示更让人困惑
  }
  return out;
}

function buildCourse(coursePath, category, courseTitle) {
  const entries = fs.readdirSync(coursePath).filter((n) => !isJunk(n)).sort((a, b) => sortOf(a) - sortOf(b) || a.localeCompare(b));
  const dirs = entries.filter((n) => fs.statSync(path.join(coursePath, n)).isDirectory());
  const files = entries.filter((n) => fs.statSync(path.join(coursePath, n)).isFile())
    .filter((n) => isVideo(n) || isDoc(n));

  const chapters = [];
  if (dirs.length > 0) {
    for (const d of dirs) {
      const ls = collectLessons(path.join(coursePath, d));
      if (ls.length) chapters.push({ title: titleOf(d), sort: sortOf(d), lessons: ls });
    }
    // 课程根目录下散着的文件（没归到任何章节的）也别丢，
    // 归到一个"未分章"里 —— 丢了就是素材静默消失。
    if (files.length) {
      chapters.push({ title: '未分章', sort: 999, lessons: files.map((f) => lessonOf(path.join(coursePath, f))) });
    }
  } else if (files.length) {
    chapters.push({ title: courseTitle, sort: 0, lessons: files.map((f) => lessonOf(path.join(coursePath, f))) });
  }
  return { category, title: courseTitle, path: coursePath, chapters };
}

function collectLessons(dir) {
  const out = [];
  const walk = (d) => {
    for (const n of fs.readdirSync(d).filter((x) => !isJunk(x)).sort((a, b) => sortOf(a) - sortOf(b) || a.localeCompare(b))) {
      const p = path.join(d, n);
      if (fs.statSync(p).isDirectory()) walk(p);
      else if (isVideo(n) || isDoc(n)) out.push(lessonOf(p));
    }
  };
  walk(dir);
  return out;
}

function lessonOf(p) {
  return {
    title: titleOf(path.basename(p)),
    kind: isVideo(p) ? 'video' : 'doc',
    path: p,
    size: (() => { try { return fs.statSync(p).size; } catch { return 0; } })(),
    sort: sortOf(path.basename(p)),
  };
}

// ── 写库 ──────────────────────────────────────────────────

function applyScan(db, tree, { copy, filesDir, log }) {
  const stats = { courses: 0, chapters: 0, lessons: 0, skipped: 0, copied: 0, errors: [] };
  const now = Date.now();
  const ownerId = db.prepare('SELECT id FROM users ORDER BY id LIMIT 1').get()?.id || 0;

  for (const c of tree.courses) {
    if (!c.chapters.reduce((n, ch) => n + ch.lessons.length, 0)) { stats.skipped++; continue; }

    // 🔴 幂等键：(category, title)。重复导入必须命中已有课程，
    //    否则素材盘挂第二次就会多出一整套重复的课。
    let course = db.prepare('SELECT * FROM tr_course WHERE category = ? AND title = ?').get(c.category, c.title);
    if (!course) {
      const info = db.prepare(`
        INSERT INTO tr_course (title, intro, category, required, published, created_by, created_at)
        VALUES (?,?,?,0,1,?,?)`).run(c.title, '', c.category, ownerId, now);
      course = db.prepare('SELECT * FROM tr_course WHERE id = ?').get(info.lastInsertRowid);
      stats.courses++;
      log(`  + 课程「${c.title}」${c.category ? '（' + c.category + '）' : ''}`);
    } else {
      stats.skipped++;
    }

    for (const ch of c.chapters) {
      let chapter = db.prepare('SELECT * FROM tr_chapter WHERE course_id = ? AND title = ?').get(course.id, ch.title);
      if (!chapter) {
        const info = db.prepare('INSERT INTO tr_chapter (course_id, title, sort) VALUES (?,?,?)')
          .run(course.id, ch.title, ch.sort);
        chapter = db.prepare('SELECT * FROM tr_chapter WHERE id = ?').get(info.lastInsertRowid);
        stats.chapters++;
      }
      for (const l of ch.lessons) {
        const dup = db.prepare('SELECT id FROM tr_lesson WHERE chapter_id = ? AND title = ?').get(chapter.id, l.title);
        if (dup) { stats.skipped++; continue; }

        let filePath = l.path;
        if (copy) {
          try {
            fs.mkdirSync(filesDir, { recursive: true });
            const dest = path.join(filesDir, `${Date.now()}-${Math.round(Math.random() * 1e9)}${path.extname(l.path)}`);
            fs.copyFileSync(l.path, dest);
            filePath = dest;
            stats.copied++;
          } catch (e) { stats.errors.push(`复制失败 ${l.path}: ${e.message}`); continue; }
        }

        const finfo = db.prepare('INSERT INTO files (owner_id, name, mime, size, path, created_at) VALUES (?,?,?,?,?,?)')
          .run(ownerId, path.basename(l.path), l.kind === 'video' ? 'video/mp4' : '', l.size, filePath, now);
        db.prepare('INSERT INTO tr_lesson (chapter_id, title, kind, file_id, duration_sec, sort) VALUES (?,?,?,?,0,?)')
          .run(chapter.id, l.title, l.kind, finfo.lastInsertRowid, l.sort);
        stats.lessons++;
      }
    }
  }
  return stats;
}

// ── 主流程 ────────────────────────────────────────────────

function main() {
  const a = parseArgs(process.argv);
  // 未知参数必须报错，不能当没看见：打错一个字母就悄悄变成"只预览"的话，
  // 用户以为导完了、库里其实什么都没有，而且界面上没有任何线索指向这里。
  if (a.unknown) {
    console.error(`不认识的参数：${a.unknown}（用 --help 看可用参数）`);
    process.exit(2);
  }
  if (a.help || !a.dir) {
    console.log(`培训中心素材导入器

  node server/tools/import_training.js --dir <素材目录> [--apply] [--copy]

  --dir      要扫描的素材根目录（如 Y:\\培训资料）
  (默认)     只预览，不写库
  --apply    真的写库
  --copy     把文件复制进 FILES_DIR（服务端不在本机时必须加；默认只登记原路径）
  --data-dir 指定数据目录（默认取环境变量 DATA_DIR）
  --quiet    只打印统计
`);
    process.exit(a.help ? 0 : 2);
  }

  const tree = scan(a.dir);
  const totalLessons = tree.courses.reduce((n, c) => n + c.chapters.reduce((m, ch) => m + ch.lessons.length, 0), 0);
  console.log(`扫描 ${a.dir}`);
  console.log(`  课程 ${tree.courses.length} 门 / 课时 ${totalLessons} 个\n`);

  if (!a.quiet) {
    for (const c of tree.courses) {
      const n = c.chapters.reduce((m, ch) => m + ch.lessons.length, 0);
      if (!n) continue;
      console.log(`  【${c.category || '未分类'}】${c.title}  — ${c.chapters.length} 章 / ${n} 课时`);
      for (const ch of c.chapters) console.log(`      · ${ch.title}（${ch.lessons.length}）`);
    }
    console.log('');
  }

  if (!a.apply) {
    console.log('以上是预览（默认不写库）。确认结构对了再加 --apply。');
    return;
  }

  if (a.dataDir) process.env.DATA_DIR = a.dataDir;
  const config = require(path.resolve(__dirname, '..', 'src', 'config'));
  const db = require(path.resolve(__dirname, '..', 'src', 'db'));

  const stats = applyScan(db, tree, {
    copy: a.copy,
    filesDir: config.FILES_DIR || path.join(os.tmpdir(), 'xz-files'),
    log: (s) => { if (!a.quiet) console.log(s); },
  });
  console.log(`\n导入完成：新增课程 ${stats.courses} / 章节 ${stats.chapters} / 课时 ${stats.lessons}` +
    `；跳过（已存在）${stats.skipped}${stats.copied ? `；复制文件 ${stats.copied}` : ''}`);
  if (stats.errors.length) {
    console.log(`\n⚠️ ${stats.errors.length} 个错误：`);
    for (const e of stats.errors.slice(0, 10)) console.log('  - ' + e);
  }
}

module.exports = { scan, applyScan, titleOf, sortOf, isJunk };

if (require.main === module) main();
