// 管理台仪表盘统计（/api/admin/stats 的时间维度）—— 端到端测试
//
//   node test/admin_stats_e2e.js
//
// 【这个测试真正在防什么】
// 仪表盘新增了「今日新增」与「近 7 天活跃」。这两个数字有个**看不出来的错法**：
// 容器里 TZ 通常是 UTC（飞牛上就是），若用 SQLite 的 date('now') 算"今天"，
// 边界就落在 UTC 零点 = 北京时间早上 8 点。后果是北京时间 0:00-8:00 之间发的消息
// 全被算成"昨天"，而当天的数字在早上看起来偏小 —— 没人会怀疑是时区问题，
// 只会觉得"今天大家没怎么说话"。
//
// 所以本测试**故意把进程 TZ 设成 UTC、ATT_TIMEZONE 设成 Asia/Shanghai**
// （完全复刻飞牛容器的实际环境），再往"北京时间今天 00:30"这个点上插数据：
// 北京恒为 UTC-8h（中国无夏令时），所以「UTC 今天」= 北京 [今天08:00, 明天08:00)，
// 而正确的窗口是北京 [今天00:00, 明天00:00) —— 北京时间凌晨那 8 小时是两者唯一的差集。
// "北京今天 00:30"这条样本正好落在这个差集里：正确口径算今天、UTC 口径算昨天。
//
// ⚠️ 注意这个鉴别方向是**单向**的：因为 UTC 恒落后于北京，不存在
// "北京昨天"被 UTC 算成今天的情况（北京昨天 23:30 = UTC 昨天 15:30，两边同一天）。
// 所以只需往"北京凌晨"放样本；反向样本在数学上不存在，不要硬凑。
//
// 测试里把错误口径（UTC 窗口）会得到的条数**真的算出来**并断言它 ≠ 正确值，
// 以此证明 msgsToday === 3 是一条有鉴别力的断言，而不是碰巧通过；并额外用
// 24 个整点做"全天候自检"，证明这条判据**在任何钟点跑都成立**（见下方注释）。
// ⚠️ 早期版本把 naive 条数写死成 1，结果北京时间 00:00-08:00 跑必红（假失败）。

const { spawn } = require('child_process');
const path = require('path');
const fs = require('fs');
const os = require('os');
const { DatabaseSync } = require('node:sqlite');

const PORT = 3703;
const BASE = `http://127.0.0.1:${PORT}`;
const SERVER_DIR = path.resolve(__dirname, '..');
const DATA_DIR = path.join(os.tmpdir(), 'xiaozhi-adminstats-e2e-' + Date.now());
const DB_PATH = path.join(DATA_DIR, 'xiaozhi-im.db');

// 复刻飞牛容器：进程时区是 UTC，业务时区是北京时间
const TZ_NAME = 'Asia/Shanghai';

let passed = 0;
let failed = 0;
const failures = [];

function ok(name, cond, extra) {
  if (cond) { passed++; console.log(`  \u2713 ${name}`); }
  else {
    failed++;
    failures.push(name + (extra ? ` — ${extra}` : ''));
    console.log(`  \u2717 ${name}${extra ? '  → ' + extra : ''}`);
  }
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function api(method, p, { token, body } = {}) {
  const res = await fetch(BASE + p, {
    method,
    headers: {
      'Content-Type': 'application/json',
      ...(token ? { Authorization: 'Bearer ' + token } : {}),
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  let json = null;
  try { json = await res.json(); } catch { /* 空响应 */ }
  return { status: res.status, body: json };
}

function withDb(fn) {
  const d = new DatabaseSync(DB_PATH);
  try {
    d.exec('PRAGMA busy_timeout = 8000');
    return fn(d);
  } finally {
    try { d.close(); } catch { /* ignore */ }
  }
}

let serverProc = null;
let serverLog = '';

async function startServer() {
  serverProc = spawn(process.execPath, [path.join(SERVER_DIR, 'src', 'index.js')], {
    env: {
      ...process.env,
      PORT: String(PORT),
      DATA_DIR,
      ADMIN_PASSWORD: 'TestAdmin_123',
      TZ: 'UTC',                    // 进程时区：UTC（= 飞牛容器）
      ATT_TIMEZONE: TZ_NAME,        // 业务时区：北京时间
    },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  serverProc.stdout.on('data', (d) => { serverLog += d.toString(); });
  serverProc.stderr.on('data', (d) => { serverLog += d.toString(); });
  for (let i = 0; i < 80; i++) {
    try {
      const r = await fetch(BASE + '/api/health');
      if (r.ok) return;
    } catch { /* 还没起来 */ }
    await sleep(250);
  }
  throw new Error('服务端启动超时\n' + serverLog);
}

function stopServer() {
  if (serverProc) { try { serverProc.kill(); } catch { /* ignore */ } }
  try { fs.rmSync(DATA_DIR, { recursive: true, force: true }); } catch { /* ignore */ }
}

/* ============ 用与实现无关的方式算"北京时间某天某刻" ============
   不 require 被测模块（那等于拿实现验证实现），这里独立算：
   北京时间 = UTC+8，且中国无夏令时 → 直接减 8 小时。
   写死 +8 是刻意的：被测代码若把时区搞错，这个独立口径才能把它揭出来。 */
const CN_OFFSET_MS = 8 * 3600 * 1000;
function cnDay(d = new Date()) {
  return new Date(d.getTime() + CN_OFFSET_MS).toISOString().slice(0, 10);
}
function cnAt(day, hhmm) {
  const [y, mo, d] = day.split('-').map(Number);
  const [h, mi] = hhmm.split(':').map(Number);
  return Date.UTC(y, mo - 1, d, h, mi) - CN_OFFSET_MS;
}
/** UTC 口径的"今天"（用来证明用例真的有鉴别力） */
function utcDay(ts) { return new Date(ts).toISOString().slice(0, 10); }

async function main() {
  console.log('== 启动服务端（TZ=UTC, ATT_TIMEZONE=' + TZ_NAME + '）==');
  await startServer();

  const login = await api('POST', '/api/auth/login', {
    body: { username: 'admin', password: 'TestAdmin_123' },
  });
  ok('管理员登录 200', login.status === 200);
  const token = login.body?.token;
  if (!token) throw new Error('拿不到 token，后续无法继续');

  // 造一个会话 + 一个发送者（用接口建用户，走真实路径）
  const u1 = await api('POST', '/api/admin/users', {
    token, body: { username: 'zz1', password: 'zz1pass', nickname: '张三' },
  });
  const u2 = await api('POST', '/api/admin/users', {
    token, body: { username: 'zz2', password: 'zz2pass', nickname: '李四' },
  });
  ok('建两个普通用户', u1.status === 200 && u2.status === 200);
  const id1 = u1.body?.id || u1.body?.user?.id;
  const id2 = u2.body?.id || u2.body?.user?.id;

  const today = cnDay();
  const yesterday = cnDay(new Date(Date.now() - 86400000));
  const longAgo = cnDay(new Date(Date.now() - 12 * 86400000));

  console.log('\n== 准备数据（北京时间口径）==');
  // 样本时刻先算好，插入与"鉴别力"自检共用同一组值
  const tEarly = cnAt(today, '00:30');       // 北京今天凌晨 → UTC 昨天 16:30（关键样本）
  const tLate = cnAt(yesterday, '23:30');    // 北京昨晚 → UTC 昨天 15:30
  const tNoon = cnAt(today, '12:00');        // 北京今天中午 → UTC 今天 04:00
  const tNight = cnAt(today, '23:30');       // 北京今天深夜（与中午同侧，保证判据全天成立）
  const tLong = cnAt(longAgo, '10:00');      // 12 天前
  const SAMPLES = [tEarly, tLate, tNoon, tNight, tLong];

  const cid = withDb((d) => {
    d.exec('BEGIN');
    // conversations 只有 (id,type,created_at)，没有 title 列
    const c = d.prepare("INSERT INTO conversations (type,created_at) VALUES ('group',?)")
      .run(Date.now());
    const id = Number(c.lastInsertRowid);
    const ins = d.prepare(`INSERT INTO messages (conversation_id,sender_id,kind,content,file_id,created_at,edited,deleted)
      VALUES (?,?,?,?,?,?,0,0)`);
    const f = d.prepare('INSERT INTO files (owner_id,name,mime,size,path,created_at) VALUES (?,?,?,?,?,?)');

    ins.run(id, id1, 'text', 'TODAY_EARLY', null, tEarly);
    ins.run(id, id1, 'text', 'YESTERDAY_LATE', null, tLate);
    ins.run(id, id2, 'text', 'TODAY_NOON', null, tNoon);
    ins.run(id, id2, 'text', 'TODAY_NIGHT', null, tNight);
    ins.run(id, id2, 'text', 'LONG_AGO', null, tLong);

    // 文件：今天 1 个 + 12 天前 1 个
    f.run(id1, 'today.txt', 'text/plain', 10, 'today.txt', cnAt(today, '09:00'));
    f.run(id1, 'old.txt', 'text/plain', 10, 'old.txt', tLong);

    d.exec('COMMIT');
    return id;
  });
  console.log(`  北京时间今天 = ${today}，昨天 = ${yesterday}`);

  /* 证明用例真的有鉴别力（而不是碰巧通过）—— 而且**任何钟点跑都必须成立**。
     北京时间恒等于 UTC-8h（中国无夏令时），UTC 窗口换算成北京时间是：
       · 北京 <08:00：UTC 今天 = 北京昨天 → 窗口 = 北京[昨天08:00, 今天08:00)
       · 北京 ≥08:00：UTC 今天 = 北京今天 → 窗口 = 北京[今天08:00, 明天08:00)
     正确窗口恒为 北京[今天00:00, 明天00:00)。
       正确口径命中 = {今天00:30, 今天12:00, 今天23:30} = 3 条；
       UTC 口径：<08:00 命中 {昨天23:30, 今天00:30}；≥08:00 命中 {今天12:00, 今天23:30}
       —— 两种情况下都是 **2 条，且命中集合与正确集合不同**。
     下面把错误口径**真的算出来**并断言它俩不同，这样 msgsToday===3 才是有鉴别力的断言。
     ⚠️ 2026-09-21 07:04 真踩到的坑：早期版本只放 00:30/12:00 两个"今天"样本、
        并把 naive 条数写死成 1 —— 北京时间 00:00-08:00 跑的时候 naive 恰好也是 2，
        判据必红（而产品断言 msgsToday===2 本身是对的）→ 纯假失败。
     ⚠️ 也**不能只断言"两边条数不同"**：某些钟点两边条数会撞、只是**命中的行不同**，
        所以下面同时比较命中集合。样本里放"今天23:30"就是为把两种口径的命中集合
        在**全天任何时刻**都错开（它和"今天12:00"同侧，永远落在同一个窗口里）。 */
  const nowD = new Date();
  const utcStart = Date.UTC(nowD.getUTCFullYear(), nowD.getUTCMonth(), nowD.getUTCDate());
  const utcEnd = utcStart + 86400000;
  const correctHit = SAMPLES.filter((t) => cnDay(new Date(t)) === today);
  const naiveHit = SAMPLES.filter((t) => t >= utcStart && t < utcEnd);
  ok('[鉴别力] 北京今天00:30 在 UTC 口径下落在昨天（UTC 实现必然漏掉它）',
    utcDay(tEarly) === yesterday, `utc 看到的是 ${utcDay(tEarly)}`);
  ok('[鉴别力] 正确口径命中 3 条（凌晨 / 中午 / 深夜）', correctHit.length === 3,
    `实际 ${correctHit.length}`);
  ok('[鉴别力] UTC 口径的命中集合 ≠ 正确集合（鉴别的对象不同，不是碰巧条数相同）',
    naiveHit.length !== correctHit.length || naiveHit.join() !== correctHit.join(),
    `correct ${correctHit.length} 条 / naive ${naiveHit.length} 条`);

  /* 全天候自检：把 24 个整点依次当成"现在"，验证上面那条鉴别判据在**每一个钟点**
     都真能揭出 UTC 实现。不做这一步的话，"当前钟点碰巧成立"和"全天成立"分辨不出来
     —— 上一版就是只在白天成立。 */
  let badHour = null;
  for (let h = 0; h < 24; h++) {
    const at = cnAt(today, String(h).padStart(2, '0') + ':00');
    const d = new Date(at);
    const us = Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate());
    const ue = us + 86400000;
    const cHit = SAMPLES.filter((t) => cnDay(new Date(t)) === today).length;
    const nHit = SAMPLES.filter((t) => t >= us && t < ue).length;
    if (nHit === cHit) { badHour = `${h}:00 两个口径都是 ${cHit} 条（这一小时判据失效）`; break; }
  }
  ok('[鉴别力] 全天候自检：24 个整点里每一个 UTC 口径都与正确口径不同',
    badHour === null, badHour || '24/24 都有鉴别力');

  console.log('\n== /stats 时间字段 ==');
  const r = await api('GET', '/api/admin/stats', { token });
  ok('GET /stats → 200', r.status === 200);
  const s = r.body || {};

  ok('返回 day 字段且为北京时间今天', s.day === today, `day=${s.day}（期望 ${today}）`);
  ok('返回 tz 字段', s.tz === TZ_NAME, `tz=${s.tz}`);

  // 今天共 3 条（①北京00:30 + ③北京12:00 + ⑤北京23:30）；②是昨天的、④是12天前的
  ok('msgsToday = 3（北京时间口径：凌晨 + 中午 + 深夜）', s.msgsToday === 3, `实际 ${s.msgsToday}`);
  // 丢掉"北京凌晨"样本 或 直接拿 UTC 口径算，都会得到 2 → 这条判据全天都有鉴别力
  ok('msgsToday 未漏掉「北京今天00:30」凌晨样本（≠ 2）', s.msgsToday !== 2, `实际 ${s.msgsToday}`);
  ok('msgsToday 未把「北京昨天23:30」算进来（≠ 4）', s.msgsToday !== 4, `实际 ${s.msgsToday}`);

  ok('filesToday = 1', s.filesToday === 1, `实际 ${s.filesToday}`);
  ok('activeUsers7d = 2（id1、id2 各一条在 7 天内）',
    s.activeUsers7d === 2, `实际 ${s.activeUsers7d}`);
  ok('usersToday >= 2（刚建的两个用户）', (s.usersToday || 0) >= 2, `实际 ${s.usersToday}`);

  // 增量必须与累计自洽：今日新增不可能超过总数
  ok('msgsToday <= messages（自洽）', s.msgsToday <= s.messages,
    `${s.msgsToday} vs ${s.messages}`);
  ok('messages 累计 = 5', s.messages === 5, `实际 ${s.messages}`);

  console.log('\n== 回归：原有字段不能少（仪表盘与上手向导都依赖）==');
  for (const k of ['users', 'groups', 'files', 'friendships', 'text', 'images', 'audios',
    'cards', 'recalled', 'edited', 'bots', 'tokens', 'hooks_in', 'hooks_out',
    'deliveries_failed', 'pubkeys', 'orgs', 'orgMembers', 'depts',
    'attPending', 'attShifts', 'attGroups']) {
    ok(`  含字段 ${k}`, typeof s[k] === 'number', `实际 ${typeof s[k]}`);
  }
  ok('  含字段 attendanceEnabled（布尔）', typeof s.attendanceEnabled === 'boolean');
  ok('deliveries_failed = 0（新库无失败投递）', s.deliveries_failed === 0);

  console.log('\n== 时间字段不会随重复请求漂移 ==');
  const r2 = await api('GET', '/api/admin/stats', { token });
  ok('两次请求 day / msgsToday 一致',
    r2.body?.day === s.day && r2.body?.msgsToday === s.msgsToday);

  console.log('\n== 未鉴权 ==');
  const noauth = await api('GET', '/api/admin/stats');
  ok('无 token → 401', noauth.status === 401, `实际 ${noauth.status}`);

  stopServer();
  console.log('\n' + '='.repeat(52));
  if (failed) {
    console.log(`失败 ${failed} / 通过 ${passed}`);
    console.log('失败项：');
    for (const f of failures) console.log('  · ' + f);
    process.exit(1);
  }
  console.log(`通过 ${passed} / ${passed}`);
  console.log('='.repeat(52));
}

main().catch((e) => {
  console.error('测试异常：', e);
  console.error('--- 服务端日志 ---\n' + serverLog);
  stopServer();
  process.exit(1);
});
