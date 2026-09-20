// 培训中心素材导入器测试
//
//   node server/test/import_training_test.js
//
// 【为什么这个测试用假目录而不是真素材盘】
// `Y:\培训资料` 是一块网络映射盘，说没就没（写这个测试的时候它就挂着不上）。
// 测试要是依赖它，就等于"盘不在时整套测试变红"，而那跟代码对错无关。
// 所以这里造一棵临时目录树 —— 反正导入器吃的是"目录长什么样"，不是"素材在哪"。
//
// 【重点验的是幂等】
// 素材盘会被反复挂、反复导。导第二次必须**一门课都不多出来**，
// 否则学员会看到两个一模一样的课程，进度还各记一份。

const fs = require('fs');
const path = require('path');
const os = require('os');

const importer = require('../tools/import_training');

let passed = 0;
let failed = 0;
const failures = [];
function ok(name, cond, extra) {
  if (cond) { passed++; console.log(`  \u2713 ${name}`); }
  else {
    failed++; failures.push(name + (extra ? ` — ${extra}` : ''));
    console.log(`  \u2717 ${name}${extra ? `  → ${extra}` : ''}`);
  }
}

const ROOT = path.join(os.tmpdir(), 'xz-import-test-' + Date.now());

/** 造一棵目录树：两种形态都要有（"分类/课程/章节" 和 "一级就是课程"） */
function buildTree() {
  const mk = (p) => fs.mkdirSync(p, { recursive: true });
  const wr = (p, n = 10) => fs.writeFileSync(p, Buffer.alloc(n, 1));

  // 形态一：分类 / 课程 / 章节 / 文件
  mk(path.join(ROOT, '生鲜陈列', '陈列基础', '01 原则'));
  wr(path.join(ROOT, '生鲜陈列', '陈列基础', '01 原则', '01 先进先出.mp4'));
  wr(path.join(ROOT, '生鲜陈列', '陈列基础', '01 原则', '课件.pdf'));
  mk(path.join(ROOT, '生鲜陈列', '陈列基础', '02 实操'));
  wr(path.join(ROOT, '生鲜陈列', '陈列基础', '02 实操', '01 堆头.mp4'));

  // 形态二：分类 / 课程 / 直接是文件（没有章节层）
  mk(path.join(ROOT, '防损', '防盗基本法'));
  wr(path.join(ROOT, '防损', '防盗基本法', '01 内盗.mp4'));
  wr(path.join(ROOT, '防损', '防盗基本法', '02 外盗.mp4'));

  // 形态三：一级目录就是课程（分类为空）
  mk(path.join(ROOT, '店长管理'));
  wr(path.join(ROOT, '店长管理', '01 晨会.mp4'));

  // 垃圾文件：不该被当成课时。
  // 🔴 这里特意用 `~$课件.pptx` —— Office 正在编辑时留下的临时文件，
  //    它的**扩展名是合法的文档格式**，光靠"是不是媒体文件"拦不住，
  //    只有 isJunk 能拦。如果用 .DS_Store / Thumbs.db 来测，
  //    扩展名过滤就已经把它们挡在外面了，isJunk 有没有都一样 ——
  //    那样这条断言是**恒真**的，测不出任何东西（变异测试就是这么发现的）。
  wr(path.join(ROOT, '生鲜陈列', '陈列基础', '01 原则', '~$课件.pptx'));
}

(async () => {
  buildTree();

  console.log('【一】扫描');
  const tree = importer.scan(ROOT);
  // ROOT 下三个分类：生鲜陈列/陈列基础、防损/防盗基本法、店长管理（一级即课程）
  ok('扫到 3 门课', tree.courses.length === 3,
    JSON.stringify(tree.courses.map((c) => `${c.category || '-'}/${c.title}`)));

  const base = tree.courses.find((c) => c.title === '陈列基础');
  ok('「陈列基础」被归到「生鲜陈列」分类', base?.category === '生鲜陈列', JSON.stringify(base?.category));
  ok('  它有两个章节', base?.chapters.length === 2, JSON.stringify(base?.chapters.map((c) => c.title)));
  ok('  🔴 章节标题去掉了序号前缀（"01 原则" → "原则"）',
    base?.chapters?.[0]?.title === '原则', JSON.stringify(base?.chapters?.[0]?.title));
  ok('  🔴 课时标题也去掉了序号（"01 先进先出" → "先进先出"）',
    base?.chapters?.[0]?.lessons?.some((l) => l.title === '先进先出'),
    JSON.stringify(base?.chapters?.[0]?.lessons?.map((l) => l.title)));
  ok('  pdf 被认成 doc，mp4 被认成 video',
    base?.chapters?.[0]?.lessons?.some((l) => l.kind === 'doc' && l.title === '课件')
    && base?.chapters?.[0]?.lessons?.some((l) => l.kind === 'video'),
    JSON.stringify(base?.chapters?.[0]?.lessons));

  const noChap = tree.courses.find((c) => c.title === '防盗基本法');
  ok('🔴 没有章节层时，课装进一个同名章节（不造空章节）',
    noChap?.chapters.length === 1 && noChap.chapters[0].title === '防盗基本法',
    JSON.stringify(noChap?.chapters.map((c) => c.title)));

  const flat = tree.courses.find((c) => c.title === '店长管理');
  ok('一级目录就是课程时，分类留空而不是瞎编一个',
    flat && flat.category === '', JSON.stringify(flat?.category));

  ok('🔴 Office 临时文件（~$开头、扩展名合法）没被当成课时',
    !JSON.stringify(tree).includes('~$'), JSON.stringify(tree).slice(0, 300));
  ok('  同时正常的 pptx 还是被收进来了（说明上面不是"一律不收"）',
    base?.chapters?.[0]?.lessons?.some((l) => l.title === '课件'),
    JSON.stringify(base?.chapters?.[0]?.lessons?.map((l) => l.title)));

  /**
   * 调 applyScan，但把"抛异常"变成一条**可读的失败断言**。
   *
   * 🔴 不包的话，判据被改坏时进程是**崩溃退出**的：变异脚本能看出"红了"，
   *    但看不到抓到了哪几条用例 —— 那种红没法定位，也没法和"假红"区分开。
   *    包起来之后失败信息里直接带上异常原因。
   *    抛异常时返回 {} 让后面的断言继续跑完，一次能看到全部失败项。
   */
  function apply(label, db2, tree2, opts) {
    try { return importer.applyScan(db2, tree2, opts); }
    catch (e) { ok(label + '：applyScan 不该抛异常', false, e.message); return {}; }
  }

  console.log('\n【二】幂等（🔴 这条最重要）');
  process.env.DATA_DIR = path.join(os.tmpdir(), 'xz-import-db-' + Date.now());
  process.env.ADMIN_PASSWORD = 'ImportTest_123';
  const db = require('../src/db');

  const st1 = apply('第一次导入', db, tree, { copy: false, filesDir: os.tmpdir(), log: () => {} });
  ok('第一次导入：3 门课', st1.courses === 3, JSON.stringify(st1));
  const lessons1 = db.prepare('SELECT COUNT(*) n FROM tr_lesson').get().n;

  const st2 = apply('第二次导入', db, tree, { copy: false, filesDir: os.tmpdir(), log: () => {} });
  ok('🔴 第二次导入：一门课都没多出来', st2.courses === 0, JSON.stringify(st2));
  ok('  一个章节都没多出来', st2.chapters === 0, JSON.stringify(st2));
  ok('  一个课时都没多出来', st2.lessons === 0, JSON.stringify(st2));
  const lessons2 = db.prepare('SELECT COUNT(*) n FROM tr_lesson').get().n;
  ok('  课时总数没变', lessons1 === lessons2, `${lessons1} → ${lessons2}`);

  // 新增一个文件后再导：只加这一个
  fs.writeFileSync(path.join(ROOT, '防损', '防盗基本法', '03 盘点防损.mp4'), Buffer.alloc(10, 1));
  const tree2 = importer.scan(ROOT);
  const st3 = apply('新增文件后再导', db, tree2, { copy: false, filesDir: os.tmpdir(), log: () => {} });
  ok('🔴 新增一个文件后再导：只多出这 1 个课时，课程章节不重复',
    st3.courses === 0 && st3.chapters === 0 && st3.lessons === 1, JSON.stringify(st3));

  console.log('\n【三】--copy 模式');
  const filesDir = path.join(os.tmpdir(), 'xz-import-files-' + Date.now());
  // 用一棵**没导过**的新树，否则会被幂等跳过，就测不到复制了
  const ROOT2 = path.join(os.tmpdir(), 'xz-import-copy-' + Date.now());
  fs.mkdirSync(path.join(ROOT2, '新课件'), { recursive: true });
  fs.writeFileSync(path.join(ROOT2, '新课件', '01 新课.mp4'), Buffer.alloc(10, 1));
  const tree3 = importer.scan(ROOT2);
  ok('新树扫到 1 门课', tree3.courses.length === 1, JSON.stringify(tree3.courses.map((c) => c.title)));
  const st4 = apply('--copy 导入', db, tree3, { copy: true, filesDir, log: () => {} });
  ok('文件被复制进 FILES_DIR', st4.copied >= 1, JSON.stringify(st4));
  const copiedPath = db.prepare('SELECT path FROM files ORDER BY id DESC LIMIT 1').get()?.path;
  ok('  库里登记的是复制后的路径（不是原盘路径）',
    !!copiedPath && copiedPath.startsWith(filesDir), String(copiedPath));
  ok('  复制后的文件真的在磁盘上', !!copiedPath && fs.existsSync(copiedPath), String(copiedPath));
  // 反向：不带 --copy 时**不应该**复制（素材盘本来就在，复制一份是白占空间）
  const tree4 = importer.scan(path.join(ROOT2, '新课件'));
  ok('  直接指到课程目录也能扫（不会静默返回 0 门）', tree4.courses.length === 1,
    JSON.stringify(tree4.courses.map((c) => c.title)));

  console.log('\n【四】边界');
  let threw = false;
  try { importer.scan(path.join(ROOT, '不存在的目录')); } catch { threw = true; }
  ok('目录不存在 → 报错（不是静默导了个空）', threw);
  const empty = importer.scan(path.join(ROOT, '店长管理'));
  ok('单个课程目录也能扫', empty.courses.length >= 1, String(empty.courses.length));

  // ============================================================
  // 【五】标题清洗 + 命令行参数纪律
  // ============================================================
  console.log('\n【五】标题清洗与参数');
  // 🔴 真素材盘的目录名几乎都带序号（`01 门店日常管理`）。序号带进课程名，
  //    学员看到的就是"01 门店日常管理"这种目录味儿的标题 ——
  //    原来只有**章节和课时**去了序号，课程名/分类名没去（不一致）。
  const P = path.join(os.tmpdir(), 'xz-import-prefix-' + Date.now());
  fs.mkdirSync(path.join(P, '1 店长管理', '01 门店日常管理'), { recursive: true });
  fs.writeFileSync(path.join(P, '1 店长管理', '01 门店日常管理', '01 早会怎么开.mp4'), 'x');
  const tp = importer.scan(P);
  const c0 = tp.courses[0];
  ok('课程名去掉了序号前缀', c0?.title === '门店日常管理', JSON.stringify(c0?.title));
  ok('  分类名也去掉了序号前缀', c0?.category === '店长管理', JSON.stringify(c0?.category));
  ok('  课时名去掉了序号前缀', c0?.chapters?.[0]?.lessons?.[0]?.title === '早会怎么开',
    JSON.stringify(c0?.chapters?.[0]?.lessons?.map((l) => l.title)));
  // 反向：不要"去得太狠"把正常名字吃掉了
  fs.mkdirSync(path.join(P, '2 防损', '2024年新规'), { recursive: true });
  fs.writeFileSync(path.join(P, '2 防损', '2024年新规', '第3讲 防损.mp4'), 'x');
  const tp2 = importer.scan(P);
  const c2 = tp2.courses.find((c) => c.title.includes('2024'));
  ok('🔴 「2024年新规」不能被吃成「年新规」（年份不是序号）',
    c2?.title === '2024年新规', JSON.stringify(tp2.courses.map((c) => c.title)));
  fs.rmSync(P, { recursive: true, force: true });

  // 🔴 未知参数必须报错退出。
  //    不报错的话，`--dryrun`（少一个横杠）/`--dry-run`（这个参数根本不存在）
  //    会被当作"没传"，安静地变成一次预览 —— 用户以为导完了，
  //    库里其实一门课都没有，而且没有任何线索指向这里。
  const { execFileSync } = require('child_process');
  const CLI = path.join(__dirname, '..', 'tools', 'import_training.js');
  let code = 0; let errText = '';
  try {
    execFileSync(process.execPath, [CLI, '--dir', ROOT, '--dry-run'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
  } catch (e) { code = e.status == null ? -1 : e.status; errText = String(e.stderr || ''); }
  ok('🔴 不认识的参数 → 退出码 2（不是当没看见、安静变成预览）', code === 2, `code=${code}`);
  ok('  报错里点名了是哪个参数', errText.includes('--dry-run'), JSON.stringify(errText.slice(0, 120)));

  try { fs.rmSync(ROOT, { recursive: true, force: true }); } catch { /* ignore */ }
  console.log(`\n[导入器测试] 通过 ${passed} / 失败 ${failed}`);
  if (failures.length) { console.log('失败项：'); for (const f of failures) console.log('  ✗ ' + f); }
  process.exit(failed ? 1 : 0);
})().catch((e) => { console.error(e); process.exit(1); });
