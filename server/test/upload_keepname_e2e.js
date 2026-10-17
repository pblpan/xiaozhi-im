// 上传保留原文件名 e2e（龙哥 2026-10-17：「上传的文件名还用原文件名，不要重命名」）
//
// 覆盖：
//   ① /api/files/upload         保留原名（含中文），磁盘上就是这个名字，URL 一眼能认
//   ② 重名不覆盖 —— 第二次同名上传落 `名字 (2).ext`，两个 URL 内容各自独立
//   ③ 恶意/怪异文件名护栏：路径穿越、全路径、前导点、控制符、尾点
//   ④ /api/files/upload-package 同样保留名（升级包 APK/EXE 走这条）
//   ⑤ GET /files/<原名> 取得内容；GET /files/ 不再吐 index.html
//
//   node server/test/upload_keepname_e2e.js

const { spawn } = require('child_process');
const path = require('path');
const fs = require('fs');
const os = require('os');

const PORT = 3696;
const BASE = `http://127.0.0.1:${PORT}`;
const SERVER_DIR = path.resolve(__dirname, '..');
const DATA_DIR = path.join(os.tmpdir(), 'xiaozhi-keepname-' + Date.now());

let passed = 0;
let failed = 0;
const failures = [];

function ok(name, cond, extra) {
  if (cond) { passed++; console.log(`  ✓ ${name}`); }
  else { failed++; failures.push(name + (extra ? ` — ${extra}` : '')); console.log(`  ✗ ${name}${extra ? '  → ' + extra : ''}`); }
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

/** 上传（multipart，文件名原样交给 FormData —— 穿越名也走这条，服务端必须自己拦） */
async function upload(token, filename, mime, content, endpoint = '/api/files/upload') {
  const fd = new FormData();
  fd.append('file', new Blob([content], { type: mime }), filename);
  const res = await fetch(BASE + endpoint, {
    method: 'POST',
    headers: { Authorization: 'Bearer ' + token },
    body: fd,
  });
  return { status: res.status, body: await res.json().catch(() => null) };
}

async function getRaw(p) {
  const res = await fetch(BASE + p);
  return { status: res.status, text: await res.text() };
}

async function main() {
  fs.mkdirSync(DATA_DIR, { recursive: true });
  const child = spawn(process.execPath, ['src/index.js'], {
    cwd: SERVER_DIR,
    env: {
      ...process.env,
      PORT: String(PORT),
      DATA_DIR,
      DB_PATH: path.join(DATA_DIR, 'test.db'),
      ADMIN_USERNAME: 'admin',
      ADMIN_PASSWORD: 'admin-test-pw',
    },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  child.stdout.on('data', () => {});
  child.stderr.on('data', (d) => process.stderr.write('[server] ' + d));

  const shutdown = () => {
    try { child.kill(); } catch { /* ignore */ }
    try { fs.rmSync(DATA_DIR, { recursive: true, force: true }); } catch { /* ignore */ }
  };
  process.on('exit', shutdown);

  let up = false;
  for (let i = 0; i < 60; i++) {
    try { const r = await fetch(BASE + '/api/health'); if (r.ok) { up = true; break; } } catch { /* 还没起来 */ }
    await sleep(200);
  }
  if (!up) throw new Error('服务端未能在 12 秒内启动');

  const admin = (await api('POST', '/api/auth/login', {
    body: { username: 'admin', password: 'admin-test-pw' },
  })).body?.token;
  ok('管理员登录', !!admin);

  const filesDir = path.join(DATA_DIR, 'files');
  const disk = (n) => path.join(filesDir, n);

  // ---------- ① 保留原名（中文 + 常见版本号名） ----------
  console.log('\n① 保留原文件名');
  let r = await upload(admin, '小智IM_0.28.7.apk', 'application/vnd.android.package-archive', 'APK-BODY-1');
  ok('上传 200', r.status === 200, JSON.stringify(r.body));
  ok('  name = 原文件名', r.body?.name === '小智IM_0.28.7.apk', r.body?.name);
  ok('  url = /files/原文件名', r.body?.url === '/files/小智IM_0.28.7.apk', r.body?.url);
  ok('  磁盘上就是这个名字', fs.existsSync(disk('小智IM_0.28.7.apk')));
  ok('  磁盘内容正确', fs.readFileSync(disk('小智IM_0.28.7.apk'), 'utf8') === 'APK-BODY-1');

  // ---------- ② 重名不覆盖 ----------
  // 注意：响应里的 name 是「显示名」（= 原始文件名，聊天列表/文件管理用它），
  // 磁盘名在 url 里（重名时带 (2) 后缀）—— 两个字段本来就不该一样。
  console.log('\n② 重名不覆盖');
  r = await upload(admin, '小智IM_0.28.7.apk', 'application/vnd.android.package-archive', 'APK-BODY-2');
  ok('第二次同名上传 200', r.status === 200);
  ok('  url 落成 /files/名字 (2).ext', r.body?.url === '/files/小智IM_0.28.7 (2).apk', r.body?.url);
  ok('  显示名仍是原文件名', r.body?.name === '小智IM_0.28.7.apk', r.body?.name);
  ok('  第一个文件内容没被改', fs.readFileSync(disk('小智IM_0.28.7.apk'), 'utf8') === 'APK-BODY-1');
  ok('  第二个文件内容是新的', fs.readFileSync(disk('小智IM_0.28.7 (2).apk'), 'utf8') === 'APK-BODY-2');
  r = await upload(admin, '小智IM_0.28.7.apk', 'application/vnd.android.package-archive', 'APK-BODY-3');
  ok('第三次 → url 带 (3)', r.body?.url === '/files/小智IM_0.28.7 (3).apk', r.body?.url);

  // ---------- ③ 恶意/怪异文件名 ----------
  console.log('\n③ 文件名护栏');
  r = await upload(admin, '../../etc/passwd', 'text/plain', 'x');
  ok('路径穿越只落 basename', r.body?.url === '/files/passwd', r.body?.url);
  ok('  没写到 files 目录外', !fs.existsSync(path.join(DATA_DIR, '..', 'etc', 'passwd')) && fs.existsSync(disk('passwd')));
  r = await upload(admin, 'C:\\Users\\t\\安装包.exe', 'application/octet-stream', 'x');
  ok('Windows 全路径只取末段', r.body?.url === '/files/安装包.exe', r.body?.url);
  r = await upload(admin, '.hidden', 'text/plain', 'x');
  ok('前导点被剥（不落隐藏文件）', r.body?.url === '/files/hidden', r.body?.url);
  r = await upload(admin, '带\u0001控制符.txt', 'text/plain', 'x');
  ok('控制符名被干净拒掉（400，不是 500）', r.status === 400, `status=${r.status} body=${JSON.stringify(r.body)}`);
  ok('  错误信息可读', /上限|上传失败/.test(r.body?.error || ''), r.body?.error);
  r = await upload(admin, '尾点.', 'text/plain', 'x');
  ok('尾点被剥（Windows 落盘不坏）', r.body?.url === '/files/尾点', r.body?.url);
  r = await upload(admin, '', 'text/plain', 'x');
  ok('空名干净拒掉（400，不是 500）', r.status === 400, `status=${r.status}`);

  // ---------- ④ 升级包通道同样保留名 ----------
  console.log('\n④ upload-package（升级包通道）');
  r = await upload(admin, '小智IM_Setup_0.28.9.exe', 'application/octet-stream', 'EXE-BODY', '/api/files/upload-package');
  ok('上传 200', r.status === 200, JSON.stringify(r.body));
  ok('  保留原名', r.body?.name === '小智IM_Setup_0.28.9.exe', r.body?.name);
  ok('  磁盘在位', fs.existsSync(disk('小智IM_Setup_0.28.9.exe')));
  ok('  内容正确', fs.readFileSync(disk('小智IM_Setup_0.28.9.exe'), 'utf8') === 'EXE-BODY');

  // ---------- ⑤ 下载与目录根 ----------
  console.log('\n⑤ 下载与静态挂载');
  r = await getRaw('/files/' + encodeURIComponent('小智IM_0.28.7.apk'));
  ok('GET /files/<中文名> 200', r.status === 200, `status=${r.status}`);
  ok('  内容对', r.text === 'APK-BODY-1', r.text.slice(0, 40));
  r = await getRaw('/files/小智IM_0.28.7.apk');   // 不编码直接打（部分客户端这么干）
  ok('GET /files/<中文名 不编码> 200', r.status === 200, `status=${r.status}`);
  await upload(admin, 'index.html', 'text/html', '<h1>not-a-directory-index</h1>');
  r = await getRaw('/files/');
  ok('GET /files/ 不再吐上传的 index.html', r.status !== 200 || !r.text.includes('not-a-directory-index'),
    `status=${r.status} body=${r.text.slice(0, 60)}`);

  console.log(`\n通过 ${passed} / ${failed}`);
  if (failed) {
    console.log('失败项：');
    for (const f of failures) console.log('  - ' + f);
    process.exitCode = 1;
  }
}

main().catch((e) => { console.error(e); process.exit(1); });
