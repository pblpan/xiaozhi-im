// 线上带权限实测：「文件存储目录自定义」链路 + 2026-10-05 死循环事故的回归验证。
//
//   python deploy/_exec_in_container.py deploy/_probe_filesdir_live.js
//
// 🔴 这次的核心判据不是"回 400"，而是"**多快**回 400"。
//    事故现象是 POST /proc/... 把整个服务端挂死（容器 CPU 97%，全站超时）。
//    所以每一步都计时，并断言 < 3000ms —— 挂死时这条必红。
//
// 🔴 线上不许真改文件目录（改了会在下次重启把 /data/files 搬走）。所以：
//    ① GET /info                    只读
//    ② POST 数据目录本身             必然 400（且在 mkdir 之前就被拦）
//    ③ POST /proc/...                必然 400 且**必须快** ← 事故原样重放
//    ④ 无 token                     必然 401（顺带验门禁）
//    ⑤ 回读 paths.env                确认失败请求没污染配置
//    ⑥ 正向：POST 当前目录（/data/files，语义上等于默认）
//       → 200；再 DELETE 还原。选"当前目录"是故意让它**零行为差异**：
//       FILESDIR 写成默认值等价于没写，就算中间被重启也不会搬任何文件。
//    线上不做"改到新目录 + 重启搬迁"—— 那条在本地用 node 模拟重启验过（见交付说明）。
//
// ⚠️ 必自杀：容器无 kill/ps，残留进程持有 SQLite 会把 1 核打满。
'use strict';

const WATCHDOG = setTimeout(() => {
  process.stdout.write('\n[watchdog] 超时，强制退出（服务端可能又卡住了）\n');
  process.exit(9);
}, 45000);

const fsm = require('fs');
const jwt = require('/app/src/auth.js');
const db = require('/app/src/db.js');
const cfg = require('/app/src/config.js');

let pass = 0, bad = 0;
const ok = (n, c, d) => { c ? (pass++, console.log('  ✓ ' + n + (d ? ' — ' + d : '')))
                           : (bad++, console.log('  ✗ ' + n + (d ? ' — ' + d : ''))); };

const PORT = cfg.PORT || 3602;
const BASE = 'http://127.0.0.1:' + PORT;
const SLOW_MS = 3000;   // 超过这个数就是"疑似卡住"

function pathsEnvRaw() {
  try { return fsm.readFileSync(cfg.PATHS_ENV_FILE, 'utf8'); } catch { return null; }
}
function pathsEnvKeys() {
  const raw = pathsEnvRaw();
  if (!raw) return [];
  return raw.split(/\r?\n/).map((l) => l.split('=')[0].trim()).filter((k) => k && !k.startsWith('#'));
}

/** 发一个请求并计时；超时用 AbortController 掐断，免得把自己拖死 */
async function timed(label, url, opt) {
  const t0 = Date.now();
  const ac = new AbortController();
  const killer = setTimeout(() => ac.abort(), 8000);
  try {
    const r = await fetch(url, Object.assign({ signal: ac.signal }, opt || {}));
    const text = await r.text();
    return { status: r.status, text, ms: Date.now() - t0, aborted: false };
  } catch (e) {
    return { status: 0, text: String(e && e.message), ms: Date.now() - t0, aborted: !!ac.signal.aborted };
  } finally {
    clearTimeout(killer);
  }
}

const admin = db.prepare("SELECT id,username,role FROM users WHERE role='admin' ORDER BY id LIMIT 1").get();
if (!admin) { console.log('找不到管理员账号，放弃'); process.exit(0); }
const token = jwt.signToken({ uid: admin.id, role: admin.role });
const H = { Authorization: 'Bearer ' + token, 'Content-Type': 'application/json' };
console.log('  容器内服务端 v' + require('/app/package.json').version + '  端口 ' + PORT + '  admin=' + admin.username);

(async () => {
  /* ---------- ① 只读：新字段在不在 ---------- */
  console.log('\n【① GET /api/admin/info】');
  const info = (await timed('info', BASE + '/api/admin/info', { headers: H }));
  let infoJson = null;
  try { infoJson = JSON.parse(info.text); } catch { /* ignore */ }
  ok('接口回 200', info.status === 200, 'status=' + info.status + '  ' + info.ms + 'ms');
  ok('有 files_dir / files_dir_default / files_dir_custom',
     infoJson && typeof infoJson.files_dir === 'string'
     && typeof infoJson.files_dir_default === 'string'
     && typeof infoJson.files_dir_custom === 'boolean',
     infoJson ? infoJson.files_dir + '（默认 ' + infoJson.files_dir_default + '，自定义=' + infoJson.files_dir_custom + '）' : '-');

  const before = pathsEnvRaw();

  /* ---------- ② 数据目录本身：必须 400 ---------- */
  console.log('\n【② POST 数据目录本身】');
  const r2 = await timed('self', BASE + '/api/admin/files-dir',
    { method: 'POST', headers: H, body: JSON.stringify({ dir: cfg.DATA_DIR }) });
  ok('回 400 且够快', r2.status === 400 && r2.ms < SLOW_MS, r2.status + '  ' + r2.ms + 'ms  ' + r2.text.slice(0, 90));

  /* ---------- ③ 事故重放：procfs 路径 ---------- */
  console.log('\n【③ POST /proc/xz_nope/files —— 2026-10-05 就是这条把服务端挂死的】');
  const r3 = await timed('proc', BASE + '/api/admin/files-dir',
    { method: 'POST', headers: H, body: JSON.stringify({ dir: '/proc/xz_nope/files' }) });
  ok('回 400', r3.status === 400, r3.status + '  ' + r3.text.slice(0, 110));
  ok('★ 是**快速**拒绝，不是卡住', r3.ms < SLOW_MS, r3.ms + 'ms（修复前：请求永不返回，容器 CPU 97%，全站超时）');
  ok('没有导致请求被掐断', !r3.aborted, r3.aborted ? '被 AbortController 掐了 → 服务端没响应' : '正常返回');

  /* ---------- ④ 门禁 ---------- */
  console.log('\n【④ 无 token 调用】');
  const r4 = await timed('noauth', BASE + '/api/admin/files-dir',
    { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ dir: '/tmp/xz' }) });
  ok('回 401', r4.status === 401, 'status=' + r4.status);

  /* ---------- ⑤ 失败请求没污染配置 ---------- */
  console.log('\n【⑤ paths.env 有没有被上面的失败请求弄脏 —— 硬判据】');
  const after = pathsEnvRaw();
  ok('文件内容与测试前一致', after === before,
     before === null ? '（本来就不存在，且仍不存在）' : 'len=' + (after || '').length);
  ok('没有落下 FILESDIR', !pathsEnvKeys().includes('FILESDIR'), pathsEnvKeys().join(',') || '（空）');
  ok('没有落下 PREVFILESDIR', !pathsEnvKeys().includes('PREVFILESDIR'), pathsEnvKeys().join(',') || '（空）');
  ok('没有在 /proc 里留下东西', !fsm.existsSync('/proc/xz_nope'));

  /* ---------- ⑥ 正向：写当前目录 → 还原 ---------- */
  console.log('\n【⑥ 正向写入路径（写"当前目录"，语义等于默认，零行为差异）】');
  const cur = (infoJson && infoJson.files_dir) || cfg.FILES_DIR;
  const r6 = await timed('set', BASE + '/api/admin/files-dir',
    { method: 'POST', headers: H, body: JSON.stringify({ dir: cur }) });
  let j6 = null; try { j6 = JSON.parse(r6.text); } catch { /* ignore */ }
  ok('写入回 200', r6.status === 200, r6.status + '  ' + r6.text.slice(0, 120));
  ok('回了 needRestart 提示', !!(j6 && j6.needRestart === true), j6 ? String(j6.message || '').slice(0, 80) : '-');
  ok('paths.env 写进了 FILESDIR=' + cur, pathsEnvKeys().includes('FILESDIR'), (pathsEnvRaw() || '').replace(/\n/g, ' | '));

  const r7 = await timed('del', BASE + '/api/admin/files-dir', { method: 'DELETE', headers: H });
  ok('DELETE 回 200（还原）', r7.status === 200, r7.status + '  ' + r7.text.slice(0, 100));
  const fin = pathsEnvRaw() || '';
  ok('还原后没有 FILESDIR', !pathsEnvKeys().includes('FILESDIR'), 'paths.env: ' + (fin.replace(/\n/g, ' | ') || '（不存在）'));
  console.log('    说明：DELETE 会留一行 PREVFILESDIR=' + cur + '（指向默认目录）——');
  console.log('          启动时的 migrateFilesIfNeeded 判定 prev === 默认目录，会直接清掉这行，');
  console.log('          **不会搬任何文件**（代码分支：prev === DEFAULT → cleanup 后 return）。');

  /* ---------- ⑦ 收尾：服务端还活着吗 ---------- */
  console.log('\n【⑦ 收尾自检：整轮折腾完，服务端还活着吗】');
  const r8 = await timed('health', BASE + '/api/health');
  ok('/api/health 回 200 且够快', r8.status === 200 && r8.ms < SLOW_MS, r8.status + '  ' + r8.ms + 'ms');
  const r9 = await timed('info2', BASE + '/api/admin/info', { headers: H });
  ok('带权限接口仍正常', r9.status === 200 && r9.ms < SLOW_MS, r9.status + '  ' + r9.ms + 'ms');

  console.log('\n结论：通过 ' + pass + ' 项，失败 ' + bad + ' 项');
  clearTimeout(WATCHDOG);
  process.exit(0);
})().catch((e) => {
  console.log('探针异常：' + (e && e.message));
  process.exit(1);
});
