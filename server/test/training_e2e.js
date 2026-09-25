// 培训中心（M4）—— 端到端测试
//
//   node server/test/training_e2e.js
//
// 【这一层最怕的是哪种"假绿"】
// "学完了、考过了、分数也对"这一条通过说明不了太多 —— 它可能在
// **没有门禁、没有机会限制**的情况下也通过。真正证明系统成立的是这几个反面：
//   · 进度没到 → **不放行**考试（否则"学完再考"这回事就不存在）
//   · 机会用完 → **不能再考**（而且"开始了没交"也算用掉）
//   · 交过的卷子 → **不能重交**（否则可以交一次看分、改答案再交）
//   · 拿别人的题 id 来答 → **不算分**
//   · 题目下发 → **不带正确答案**（带了就是开卷）
// 少一条，对应的空子就敞着，而且**没有任何报错**。
//
// 【判据纪律】
// 不只认状态码：403 下面有 progress_not_reached / no_attempt_left，
// 409 有 already_submitted / already_started —— 逐条对 code，
// 否则"因为别的原因被拒"也会算过。

const { spawn } = require('child_process');
const path = require('path');
const fs = require('fs');
const os = require('os');

const PORT = 3718;
const BASE = `http://127.0.0.1:${PORT}`;
const SERVER_DIR = path.resolve(__dirname, '..');
const DATA_DIR = path.join(os.tmpdir(), 'xz-training-e2e-' + Date.now());

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
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/**
 * 直连测试库的句柄（子进程服务端用的是同一个 DATA_DIR）。
 *
 * ⚠️ 只用来**造数据 / 改历史数据**，不用来替代接口断言 ——
 * 用 SQL 直接改出来的"通过"证明不了接口对。
 * 需要它的场景是"把成绩改成半年前"这类：接口没法把时间倒回去。
 */
let _dbh = null;
function dbh() {
  if (!_dbh) {
    process.env.DATA_DIR = DATA_DIR;
    process.env.ADMIN_PASSWORD = 'TrainAdmin_123';
    _dbh = require(path.join(SERVER_DIR, 'src', 'db'));
  }
  return _dbh;
}

async function api(method, p, { token, body } = {}) {
  const res = await fetch(BASE + p, {
    method,
    headers: {
      ...(body != null ? { 'Content-Type': 'application/json' } : {}),
      ...(token ? { Authorization: 'Bearer ' + token } : {}),
    },
    body: body == null ? undefined : JSON.stringify(body),
  });
  let json = null;
  try { json = await res.json(); } catch { /* 空响应 */ }
  return { status: res.status, body: json };
}

let serverProc = null;
let serverLog = '';
async function startServer() {
  serverProc = spawn(process.execPath, [path.join(SERVER_DIR, 'src', 'index.js')], {
    env: { ...process.env, PORT: String(PORT), DATA_DIR, ADMIN_PASSWORD: 'TrainAdmin_123' },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  serverProc.stdout.on('data', (d) => { serverLog += d.toString(); });
  serverProc.stderr.on('data', (d) => { serverLog += d.toString(); });
  for (let i = 0; i < 60; i++) {
    try { const r = await fetch(BASE + '/api/health'); if (r.ok) return; } catch { /* 等 */ }
    await sleep(250);
  }
  throw new Error('服务端启动超时\n' + serverLog);
}
function stopServer() {
  if (serverProc) { try { serverProc.kill(); } catch { /* ignore */ } }
  try { fs.rmSync(DATA_DIR, { recursive: true, force: true }); } catch { /* ignore */ }
}

(async () => {
  await startServer();
  console.log('[培训中心 E2E] 服务端已就绪 ' + BASE + '\n');

  let r = await api('POST', '/api/auth/login', { body: { username: 'admin', password: 'TrainAdmin_123' } });
  const ADMIN = r.body?.token;
  ok('管理员登录', !!ADMIN, JSON.stringify(r.body));
  if (!ADMIN) { stopServer(); process.exit(1); }

  // 造一个学员账号（管理员不参加培训考试，用普通账号跑学员侧）
  r = await api('POST', '/api/admin/users', { token: ADMIN, body: { username: 'student1', password: 'Student_123', nickname: '学员一' } });
  const stuId = r.body?.id;
  let lr = await api('POST', '/api/auth/login', { body: { username: 'student1', password: 'Student_123' } });
  if (!lr.body?.token) {
    lr = await api('POST', '/api/auth/login', { body: { username: 'student1', password: 'Student_123' } });
  }
  const STU = lr.body?.token;
  ok('学员账号登录', !!STU, JSON.stringify(lr.body).slice(0, 200));
  if (!STU) { console.log('  建用户返回: ' + JSON.stringify(r.body).slice(0, 200)); stopServer(); process.exit(1); }

  // ── 建一门课：2 章，每章 1 个课时；第 1 章带考试 ──
  r = await api('POST', '/api/training/admin/courses', {
    token: ADMIN, body: { title: '生鲜陈列基础', intro: '陈列原则与实操', category: '生鲜陈列', required: true, published: true },
  });
  const courseId = r.body?.id;
  ok('建课程', !!courseId, JSON.stringify(r.body));

  r = await api('POST', '/api/training/admin/chapters', { token: ADMIN, body: { courseId, title: '第一章 陈列原则', sort: 1 } });
  const ch1 = r.body?.id;
  r = await api('POST', '/api/training/admin/chapters', { token: ADMIN, body: { courseId, title: '第二章 实操', sort: 2 } });
  const ch2 = r.body?.id;
  ok('建两个章节', !!ch1 && !!ch2, JSON.stringify({ ch1, ch2 }));

  r = await api('POST', '/api/training/admin/lessons', { token: ADMIN, body: { chapterId: ch1, title: '陈列三原则', kind: 'video', durationSec: 600, sort: 1 } });
  const lesson1 = r.body?.id;
  r = await api('POST', '/api/training/admin/lessons', { token: ADMIN, body: { chapterId: ch2, title: '实操演示', kind: 'video', durationSec: 300, sort: 1 } });
  ok('建课时', !!lesson1, JSON.stringify(r.body));

  // ============================================================
  // 【一】课程列表：未发布的不下发 / 加入课程
  // ============================================================
  console.log('\n【一】课程列表');
  r = await api('POST', '/api/training/admin/courses', {
    token: ADMIN, body: { title: '草稿课（不该被看到）', published: false },
  });
  const draftId = r.body?.id;
  r = await api('GET', '/api/training/courses?scope=public', { token: STU });
  const titles = (r.body?.items || []).map((c) => c.title);
  ok('🔴 未发布的课程学员侧**看不到**', !titles.includes('草稿课（不该被看到）'), titles.join(','));
  ok('  已发布的能看到', titles.includes('生鲜陈列基础'), titles.join(','));
  ok('  🔴 就算没学过，进度字段也在（回 0 不省略，客户端才画得出进度条）',
    (r.body?.items || []).every((c) => typeof c.progressPct === 'number'),
    JSON.stringify(r.body?.items?.[0]));

  r = await api('GET', '/api/training/courses?scope=mine', { token: STU });
  ok('没加入时「我的课程」是空的', (r.body?.items || []).length === 0, JSON.stringify(r.body?.items));
  await api('POST', `/api/training/courses/${courseId}/join`, { token: STU });
  await api('POST', `/api/training/courses/${courseId}/join`, { token: STU }); // 重复加入
  r = await api('GET', '/api/training/courses?scope=mine', { token: STU });
  ok('加入后出现在「我的课程」，且重复加入只有一条', (r.body?.items || []).length === 1,
    JSON.stringify(r.body?.items?.length));

  // ============================================================
  // 【二】进度：上报 + 幂等
  // ============================================================
  console.log('\n【二】学习进度');
  r = await api('POST', '/api/training/progress', { token: STU, body: { lessonId: lesson1, positionSec: 120, done: false } });
  ok('上报进度', r.status === 200 && r.body?.positionSec === 120, JSON.stringify(r.body));
  // 弱网重传：同一个课时再报一次
  await api('POST', '/api/training/progress', { token: STU, body: { lessonId: lesson1, positionSec: 300, done: false } });
  r = await api('GET', `/api/training/courses/${courseId}`, { token: STU });
  const l1 = r.body?.chapters?.[0]?.lessons?.[0];
  ok('🔴 重传不产生第二条记录（进度是覆盖不是叠加）', l1?.positionSec === 300, JSON.stringify(l1));

  // ── 真进度：positionSec 是"看到哪"，watchedSec 才是"看了多少" ──
  // 客户端内嵌播放器每秒 tick 一次，退出时还会**兜底再报一次**（dispose 里发的）。
  // 两条链路到达顺序不定，所以服务端这两个数都取 MAX —— 否则退出那次
  // （比如已经 seek 回开头）会把真进度冲小。
  r = await api('POST', '/api/training/progress', {
    token: STU, body: { lessonId: lesson1, positionSec: 300, watchedSec: 260, done: false },
  });
  ok('上报真观看秒数（watchedSec）', r.status === 200 && r.body?.watchedSec === 260, JSON.stringify(r.body));
  r = await api('POST', '/api/training/progress', {
    token: STU, body: { lessonId: lesson1, positionSec: 12, watchedSec: 5, done: false },
  });
  ok('🔴 退出时的兜底上报不会把真进度冲小（两个值都取 MAX）',
    r.body?.watchedSec === 260 && r.body?.positionSec === 300, JSON.stringify(r.body));
  r = await api('GET', `/api/training/courses/${courseId}`, { token: STU });
  ok('  课程详情里带得出 watchedSec（学员看得见自己真看了多少）',
    r.body?.chapters?.[0]?.lessons?.[0]?.watchedSec === 260,
    JSON.stringify(r.body?.chapters?.[0]?.lessons?.[0]));
  // 🔴 反向：把进度条拖到 99999 秒，一秒没真看 —— 服务端**不能**因此判完成。
  //    （判完成是客户端按 watchedSec 定的；这里钉的是"服务端不会自己拿位置算"）
  r = await api('POST', '/api/training/progress', {
    token: STU, body: { lessonId: lesson1, positionSec: 99999, watchedSec: 0, done: false },
  });
  ok('🔴 只把位置拖到头、没真看 → 服务端不算完成（位置不当完成度）',
    r.status === 200 && r.body?.done === false && r.body?.positionSec === 99999,
    JSON.stringify(r.body));
  ok('  done 只升不降（报一次 done=1 后再报 done=0 也不会掉回去）',
    await (async () => {
      await api('POST', '/api/training/progress', { token: STU, body: { lessonId: lesson1, positionSec: 10, done: true } });
      await api('POST', '/api/training/progress', { token: STU, body: { lessonId: lesson1, positionSec: 20, done: false } });
      const rr = await api('GET', `/api/training/courses/${courseId}`, { token: STU });
      return rr.body?.chapters?.[0]?.lessons?.[0]?.done === true;
    })(), '');

  // ============================================================
  // 【三】考试门禁：进度不到不放行
  // ============================================================
  console.log('\n【三】考试门禁（这条守的是"学完再考"）');
  r = await api('POST', '/api/training/admin/exams', {
    token: ADMIN,
    body: {
      chapterId: ch1, title: '第一章考试', passScore: 60, attemptLimit: 1, minProgress: 100,
      questions: [
        { type: 'single', stem: '陈列的第一个原则是什么？', score: 10, options: [{ content: '先进先出', correct: true }, { content: '好看就行' }] },
        { type: 'multi', stem: '哪些属于陈列要求？（多选）', score: 10, options: [{ content: '整齐', correct: true }, { content: '饱满', correct: true }, { content: '随意堆' }] },
        { type: 'judge', stem: '价签必须一货一签。', score: 10, options: [{ content: '对', correct: true }, { content: '错' }] },
      ],
    },
  });
  const exam1 = r.body?.id;
  ok('建考试（含单选/多选/判断）', !!exam1, JSON.stringify(r.body));

  r = await api('POST', `/api/training/exams/${exam1}/start`, { token: STU });
  ok('🔴 第一章进度已 100%，放行考试', r.status === 200, JSON.stringify(r.body).slice(0, 200));
  const startedSheet = r.body?.sheetId;
  const qs = r.body?.questions || [];
  ok('  下发的题目**不带正确答案**（带了就是开卷）',
    !JSON.stringify(qs).includes('correct') && !JSON.stringify(qs).includes('rightLabels'),
    JSON.stringify(qs).slice(0, 200));
  ok('  题目数对得上', qs.length === 3, String(qs.length));

  // 用另一个章节做"进度不足"的反向用例
  r = await api('POST', '/api/training/admin/exams', {
    token: ADMIN,
    body: {
      chapterId: ch2, title: '第二章考试', passScore: 60, attemptLimit: 1, minProgress: 100,
      questions: [{ type: 'single', stem: '演示里第一步做什么？', score: 10, options: [{ content: '洗手', correct: true }, { content: '上货' }] }],
    },
  });
  const exam2 = r.body?.id;
  r = await api('POST', `/api/training/exams/${exam2}/start`, { token: STU });
  ok('🔴 第二章还没学 → 403 progress_not_reached（不放行）',
    r.status === 403 && r.body?.code === 'progress_not_reached', JSON.stringify(r.body));

  // ============================================================
  // 【四】一次机会：开始了没交，也算用掉
  // ============================================================
  console.log('\n【四】考试机会（这条守的是"题目不漏"）');
  r = await api('POST', `/api/training/exams/${exam1}/start`, { token: STU });
  ok('🔴 上一份卷子没交就再点开始 → 403 no_attempt_left（机会在**开始**时就消耗了）',
    r.status === 403 && r.body?.code === 'no_attempt_left', JSON.stringify(r.body));

  // ============================================================
  // 【五】交卷判分
  // ============================================================
  console.log('\n【五】交卷与判分');
  // 🔴 拿到题目是后面所有判分用例的前提。没有它就**明确报失败并收尾**，
  //    不要继续往下跑 —— 否则会在 `single.id` 上抛 TypeError，
  //    进程崩溃退出 1，看起来也是"红了"，但那是崩溃不是断言失败。
  //    变异测试里分不清这两种红，就会把"崩溃"当成"判据被抓到"。
  if (!startedSheet || qs.length !== 3 || !qs.find((q) => q.type === 'multi')) {
    ok('🔴 考试能正常开始且题目齐全（后面判分依赖这一步）',
      false, JSON.stringify({ startedSheet, count: qs.length, body: r.body }).slice(0, 300));
    console.log('\n前提不成立，后续判分用例跳过。');
    console.log(`\n[培训中心 E2E] 通过 ${passed} / 失败 ${failed}`);
    for (const f of failures) console.log('  ✗ ' + f);
    stopServer();
    process.exit(1);
  }
  const single = qs.find((q) => q.type === 'single');
  const multi = qs.find((q) => q.type === 'multi');
  const judge = qs.find((q) => q.type === 'judge');

  r = await api('POST', `/api/training/sheets/${startedSheet}/submit`, {
    token: STU,
    // 单选对、多选**只选一个**（漏选）、判断对
    body: { answers: [
      { questionId: single.id, chosen: 'A' },
      { questionId: multi.id, chosen: 'A' },
      { questionId: judge.id, chosen: 'A' },
    ] },
  });
  ok('🔴 多选题漏选 → 该题不得分（全对才给分）', r.status === 200 && r.body?.score === 20, JSON.stringify(r.body));
  ok('  返回的判定里标出了哪题错了',
    r.body?.detail?.some((d) => d.questionId === multi.id && d.correct === false),
    JSON.stringify(r.body?.detail));
  ok('  交完才给正确答案（对答案用）',
    r.body?.detail?.every((d) => typeof d.rightLabels === 'string'),
    JSON.stringify(r.body?.detail).slice(0, 200));

  r = await api('POST', `/api/training/sheets/${startedSheet}/submit`, { token: STU, body: { answers: [{ questionId: single.id, chosen: 'A' }] } });
  ok('🔴 已交的卷子再交一次 → 409 already_submitted（防"交一次看分再改"）',
    r.status === 409 && r.body?.code === 'already_submitted', JSON.stringify(r.body));

  // ============================================================
  // 【六】拿别人的题 id 刷分
  // ============================================================
  console.log('\n【六】刷分防护');
  r = await api('POST', '/api/training/admin/exams', {
    token: ADMIN,
    body: {
      chapterId: ch2, title: '第二章考试B', passScore: 1, attemptLimit: 1, minProgress: 0,
      questions: [{ type: 'single', stem: '1+1=?', score: 10, options: [{ content: '2', correct: true }, { content: '3' }] }],
    },
  });
  const exam3 = r.body?.id;
  r = await api('POST', `/api/training/exams/${exam3}/start`, { token: STU });
  const sheet3 = r.body?.sheetId;
  const q3 = r.body?.questions?.[0];
  r = await api('POST', `/api/training/sheets/${sheet3}/submit`, {
    token: STU,
    body: { answers: [
      { questionId: q3.id, chosen: 'A' },
      { questionId: single.id, chosen: 'A' },   // 别的一场考试的题
      { questionId: 999999, chosen: 'A' },      // 根本不存在的题
    ] },
  });
  ok('🔴 别场考试的题 id 不算分（只判本卷抽到的题）',
    r.status === 200 && r.body?.score === 10, JSON.stringify(r.body));

  // ============================================================
  // 【七】课件 Range 播放
  // ============================================================
  console.log('\n【七】课件播放（Range）');
  // 造一个真文件并登记进 files，挂到课时上
  const mediaPath = path.join(DATA_DIR, 'demo-lesson.mp4');
  fs.writeFileSync(mediaPath, Buffer.alloc(5000, 7));
  const fileId = (() => {
    const db = (() => {
      process.env.DATA_DIR = DATA_DIR;
      process.env.ADMIN_PASSWORD = 'TrainAdmin_123';
      return require(path.join(SERVER_DIR, 'src', 'db'));
    })();
    const info = db.prepare('INSERT INTO files (owner_id, name, mime, size, path, created_at) VALUES (?,?,?,?,?,?)')
      .run(1, 'demo-lesson.mp4', 'video/mp4', 5000, mediaPath, Date.now());
    const fid = info.lastInsertRowid;
    db.prepare('UPDATE tr_lesson SET file_id = ? WHERE id = ?').run(fid, lesson1);
    return fid;
  })();
  ok('课件已挂到课时上', !!fileId, String(fileId));

  const head = await fetch(`${BASE}/api/training/lessons/${lesson1}/media`, { headers: { Authorization: 'Bearer ' + STU } });
  ok('整文件请求 200 + Accept-Ranges',
    head.status === 200 && head.headers.get('accept-ranges') === 'bytes', `status=${head.status}`);

  const part = await fetch(`${BASE}/api/training/lessons/${lesson1}/media`, {
    headers: { Authorization: 'Bearer ' + STU, Range: 'bytes=100-199' },
  });
  ok('🔴 带 Range → 206 Partial Content', part.status === 206, `status=${part.status}`);
  ok('  Content-Range 对得上', part.headers.get('content-range') === 'bytes 100-199/5000',
    String(part.headers.get('content-range')));
  const buf = Buffer.from(await part.arrayBuffer());
  ok('  真的只回了 100 字节（拖进度条不会重下整个文件）', buf.length === 100, String(buf.length));

  const bad = await fetch(`${BASE}/api/training/lessons/${lesson1}/media`, {
    headers: { Authorization: 'Bearer ' + STU, Range: 'bytes=999999-' },
  });
  ok('  Range 超出 → 416（不是 200 也不是 500）', bad.status === 416, `status=${bad.status}`);

  const noAuth = await fetch(`${BASE}/api/training/lessons/${lesson1}/media`);
  ok('  没登录不能看课件', noAuth.status === 401, `status=${noAuth.status}`);

  // 🔴 反向：库里 files.path **有两种写法** —— 上传接口存的是文件名（相对 FILES_DIR），
  //    导入器存的是绝对路径。只按一种解析的话，另一种表现为
  //    "上传的课件播不了、导入的能播"（或反过来），而且**没有任何报错**能指向这里。
  const relName = 'demo-relative.mp4';
  const filesDir = path.join(DATA_DIR, 'files');
  fs.mkdirSync(filesDir, { recursive: true });
  fs.writeFileSync(path.join(filesDir, relName), Buffer.alloc(3000, 9));
  const lessonRel = dbh().prepare(`
    INSERT INTO tr_lesson (chapter_id, title, kind, file_id, duration_sec, sort)
    VALUES (?,?,?,?,0,?)`)
    .run(ch1, '相对路径课件', 'video',
      dbh().prepare('INSERT INTO files (owner_id,name,mime,size,path,created_at) VALUES (?,?,?,?,?,?)')
        .run(1, relName, 'video/mp4', 3000, relName, Date.now()).lastInsertRowid, 9)
    .lastInsertRowid;
  const rel = await fetch(`${BASE}/api/training/lessons/${lessonRel}/media`, {
    headers: { Authorization: 'Bearer ' + STU, Range: 'bytes=0-9' },
  });
  ok('🔴 相对路径的课件（上传接口那种写法）也能播 → 206',
    rel.status === 206, `status=${rel.status}`);

  // ============================================================
  // 【八】权限
  // ============================================================
  console.log('\n【八】权限');
  r = await api('POST', '/api/training/admin/courses', { token: STU, body: { title: '学员建的课' } });
  ok('学员不能建课 → 403', r.status === 403, JSON.stringify(r.body));
  const noToken = await fetch(BASE + '/api/training/courses');
  ok('没登录不能看课程 → 401', noToken.status === 401, String(noToken.status));

  // ============================================================
  // 【九】管理端：看得到草稿、查得到成绩
  // ============================================================
  console.log('\n【九】管理端查询');
  r = await api('GET', '/api/training/admin/courses', { token: ADMIN });
  ok('管理端能列出全部课程（含未发布的）',
    r.status === 200 && Array.isArray(r.body?.items) && r.body.items.length >= 1,
    JSON.stringify(r.body).slice(0, 200));

  // 建一门草稿课（published=0）：学员侧必须看不见，管理端必须看得见
  r = await api('POST', '/api/training/admin/courses', {
    token: ADMIN, body: { title: '草稿课-防损', category: '防损', published: false },
  });
  const draftId2 = r.body?.id;
  ok('建草稿课成功', !!draftId2, JSON.stringify(r.body));
  r = await api('GET', '/api/training/courses', { token: STU });
  const pubTitles = (r.body?.items || r.body || []).map((c) => c.title);
  ok('🔴 学员侧看不见未发布的课', !titles.includes('草稿课-防损'), JSON.stringify(pubTitles));
  r = await api('GET', '/api/training/admin/courses', { token: ADMIN });
  ok('  管理端看得见未发布的课',
    (r.body?.items || []).some((c) => c.id === draftId2), 'draftId2=' + draftId2);

  r = await api('GET', `/api/training/admin/courses/${courseId}`, { token: ADMIN });
  ok('管理端能取到课程详情（章节/课时/考试/题目）',
    r.status === 200 && Array.isArray(r.body?.chapters) && r.body.chapters.length >= 1,
    JSON.stringify(r.body).slice(0, 200));
  const ch0 = r.body.chapters[0];
  ok('  详情里带考试题目与选项',
    (ch0?.exams?.[0]?.questions?.[0]?.options || []).length >= 2,
    JSON.stringify(ch0?.exams?.[0]?.questions?.[0] || {}).slice(0, 200));

  r = await api('GET', '/api/training/admin/courses/999999', { token: ADMIN });
  ok('  课程不存在 → 404（不是 200 空对象）', r.status === 404, String(r.status));
  r = await api('GET', '/api/training/admin/courses', { token: STU });
  ok('  学员不能调管理端列表 → 403', r.status === 403, String(r.status));

  // 成绩
  r = await api('GET', '/api/training/admin/sheets', { token: ADMIN });
  ok('成绩列表能查到刚才那张卷子',
    r.status === 200 && (r.body?.items || []).length >= 1, JSON.stringify(r.body).slice(0, 240));
  const sheet0 = (r.body?.items || [])[0];
  ok('  成绩里带姓名与课程名（不然只是一堆 id，看不出是谁）',
    !!sheet0 && !!sheet0.exam_title && !!sheet0.course_title && (sheet0.username != null),
    JSON.stringify(sheet0 || {}).slice(0, 240));

  // 🔴 反向：成绩是**历史**，不能默认只给最近 30 天（考完三个月再查就查不到了）
  const oldAt = Date.now() - 200 * 86400000;
  dbh().prepare('UPDATE tr_sheet SET started_at = ? WHERE id = ?').run(oldAt, sheet0.id);
  r = await api('GET', '/api/training/admin/sheets', { token: ADMIN });
  ok('🔴 半年前的成绩也查得到（不按默认 30 天窗截断）',
    (r.body?.items || []).some((x) => x.id === sheet0.id),
    'total=' + r.body?.total + ' 首页 id=' + JSON.stringify((r.body?.items || []).map((x) => x.id)));
  dbh().prepare('UPDATE tr_sheet SET started_at = ? WHERE id = ?').run(Date.now(), sheet0.id);

  r = await api('GET', '/api/training/admin/sheets?passed=1', { token: ADMIN });
  ok('按及格过滤只出及格的',
    (r.body?.items || []).every((x) => x.pass === 1),
    JSON.stringify((r.body?.items || []).map((x) => x.pass)));
  r = await api('GET', `/api/training/admin/sheets?courseId=${courseId}`, { token: ADMIN });
  ok('按课程过滤只出该课程的卷子',
    (r.body?.items || []).every((x) => x.course_id === courseId),
    JSON.stringify((r.body?.items || []).map((x) => x.course_id)));

  // 删子项要级联，不留孤儿
  const someLesson = dbh().prepare('SELECT id FROM tr_lesson LIMIT 1').get()?.id;
  if (someLesson) {
    dbh().prepare('INSERT OR REPLACE INTO tr_progress (user_id, lesson_id, position_sec, done, updated_at) VALUES (1,?,10,1,1)')
      .run(someLesson);
    r = await api('DELETE', `/api/training/admin/lessons/${someLesson}`, { token: ADMIN });
    ok('删课时连进度一起删（不留孤儿进度行）',
      r.status === 200 &&
      dbh().prepare('SELECT COUNT(*) n FROM tr_progress WHERE lesson_id = ?').get(someLesson).n === 0,
      JSON.stringify(r.body));
  }

  stopServer();
  console.log(`\n[培训中心 E2E] 通过 ${passed} / 失败 ${failed}`);
  if (failures.length) { console.log('失败项：'); for (const f of failures) console.log('  ✗ ' + f); }
  process.exit(failed ? 1 : 0);
})().catch((e) => { console.error(e); stopServer(); process.exit(1); });
