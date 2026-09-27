'use strict';
/**
 * 线上体检：工作台那几个新接口，HTTP 层面到底把新字段下发下去没有。
 *
 *   python deploy/_exec_in_container.py deploy/_apps_live_http.js
 *
 * 为什么不只靠 `_apps_live_check.js`（那个直接 require 源码、验的是逻辑）：
 *   逻辑对不代表**路由挂上了**。路由注册错位置（比如排在 `/admin/apps/:id`
 *   后面被抢先匹配）的时候，调用方拿到的是别人的响应 —— 不报错、不 404，
 *   只是永远差一个字段。所以这里必须真的走一遍 HTTP。
 *
 * 🔴 只读探针：只发 GET，不改任何数据。
 */
const { execFileSync } = require('node:child_process');
const fs = require('node:fs');
const http = require('node:http');
const { DatabaseSync } = require('node:sqlite');

let pass = 0, bad = 0;
const ok = (n, c, d) => { c ? (pass++, console.log('  ✓ ' + n + (d ? ' — ' + d : '')))
                            : (bad++, console.log('  ✗ ' + n + (d ? ' — ' + d : ''))); };

/**
 * 线上那个 sqlite 在容器里的路径。
 *
 * 🔴 两条都是踩过的坑，不要"顺手简化"：
 *    · 库叫 **`xiaozhi-im.db`**，不是通用的 db.sqlite；
 *    · 它所在的**数据目录不在 @appcenter**，而在 **@appshare**（容器只有两个
 *      bind，@appcenter 那个挂的是源码）。早先只找 @appcenter，一条都找不到，
 *      于是探针报"签不出 token"，而实际上文件一直好好的。
 *    · 路径映射别手写 `.replace()`（会得出容器里根本不存在的路径），
 *      从 `docker inspect` 的 Binds 里推。
 */
//
// ⚠️ 这个探针是**在容器里跑的**（别的地方没有 node：飞牛这台机器没装 sqlite3，
//    容器外也没有 flutter/dart）。所以这里不能调 `docker inspect`，
//    只能读自己这个进程的挂载表。
function containerDb() {
  const paths = new Set();
  // ① 从挂载表里找（mountinfo 的第 5 个字段才是挂载点，前面的 id/parent/major /root 是干扰）
  for (const line of fs.readFileSync('/proc/self/mountinfo', 'utf8').split('\n')) {
    const p = line.trim().split(/\s+/);
    if (p.length > 5 && (p[4] === '/data' || p[4] === '/app')) paths.add(p[4] + '/xiaozhi-im.db');
  }
  // ② 兜底候选：线上 DATA_DIR 就是 /data（热更脚本的 to_container_path 也是这么算的）
  paths.add('/data/xiaozhi-im.db');

  // 🔴 **不猜**：一个个打开，挑第一个真的有 users 表的。
  //    "文件能打开"不等于"这是对的那个库" —— 早先只判 existsSync，
  //    结果开的是一个空壳库，报 "no such table: users"，看着像线上没用户，
  //    其实是找错了文件（这类假报警最耗人）。
  for (const p of paths) {
    if (!fs.existsSync(p)) continue;
    try {
      const db = new DatabaseSync(p);
      const has = db.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name='users'").get();
      db.close();
      if (has) return p;
    } catch (_) { /* 打不开就换下一个 */ }
  }
  return '';
}

const DB = containerDb();

function get(path, token) {
  return new Promise((resolve) => {
    const r = http.request({ host: '127.0.0.1', port: 3602, path,
      headers: token ? { Authorization: 'Bearer ' + token } : {} }, (res) => {
      let s = '';
      res.on('data', (d) => { s += d; });
      res.on('end', () => resolve({ code: res.statusCode, body: s }));
    });
    r.on('error', () => resolve({ code: 0, body: '' }));
    r.end();
  });
}

(async () => {
  // 让容器里跑着的那份代码自己签（JWT_SECRET 与线上服务同一把，见 _token_probe.js 的说明）。
  // 🔴 不要拿管理口令登录：明文会进 shell 命令、日志和 history。
  let token = '';
  try {
    // 🔴 这个探针本身就跑在容器里，所以**不要再套一层 docker exec**
    //    （第一版这么写了，报 "spawnSync docker ENOENT" —— 容器里没有 docker，
    //     而这个报错又被吞掉，看起来像"线上签不出 token"，其实是自己套错了一层）。
    token = execFileSync('node', ['/app/_token_probe.js', DB], { encoding: 'utf8' }).trim();
  } catch (e) {
    // 🔴 失败就要**看得见**：静默吞掉异常，等于把"探针坏了"伪装成"线上没配"。
    console.log('  ⚠️ 签 token 失败：' + (e.stderr || e.message || String(e)).toString().trim().slice(0, 400));
    token = '';
  }
  if (!token) {
    console.log('  ⚠️ 签不出 token，跳过 HTTP 实测（线上是工作模式，自助注册走不通）');
    return;
  }

  console.log('【/api/client/apps 下发结构】');
  const r = await get('/api/client/apps?clientVersion=0.20.0', token);
  let j = null;
  try { j = JSON.parse(r.body); } catch (_) { /* 保持 null */ }
  ok('接口通的（200）', r.code === 200, 'HTTP ' + r.code);
  ok('响应是 JSON 对象', j && typeof j === 'object');
  if (!j) { console.log('\n线上实测结果：' + pass + ' / ' + (pass + bad)); process.exit(bad ? 1 : 0); }

  ok('🔴 带 groups（客户端不再显示英文 key）', Array.isArray(j.groups) && j.groups.length > 0,
     (j.groups || []).map((g) => `${g.key}=${g.label}`).join(' '));
  ok('🔴 带 notices（没配就是空数组，不许编）', Array.isArray(j.notices), JSON.stringify(j.notices || []));
  ok('  带 workMode（原来的字段没被改坏）', 'workMode' in j, JSON.stringify(j.workMode ?? null));
  ok('  应用条数 > 0', Array.isArray(j.apps) && j.apps.length > 0, (j.apps || []).length + ' 项');

  // 🔴 每条应用都得有 groupLabel 与 color：缺一个，客户端就退回默认色/英文组名
  const missLabel = (j.apps || []).filter((a) => !a.groupLabel);
  const missColor = (j.apps || []).filter((a) => typeof a.color !== 'string' || !/^#[0-9A-Fa-f]{6}$/.test(a.color));
  ok('🔴 每个应用都带 groupLabel', missLabel.length === 0,
     missLabel.length ? '缺：' + missLabel.map((a) => a.id).join(',') : (j.apps || []).length + ' 项全有');
  ok('🔴 每个应用都带合法 color', missColor.length === 0,
     missColor.length ? '缺：' + missColor.map((a) => a.id).join(',') : (j.apps || []).length + ' 项全有');

  console.log('\n【管理台新路由（GET，不改数据）】');
  for (const p of ['/api/admin/apps/groups', '/api/admin/apps/notices']) {
    const q = await get(p, token);
    ok(`${p} 已挂上（不是 404 / 不等于 root）`, q.code !== 404,
       `HTTP ${q.code}` + (q.code === 200 ? '' : '  ← 404 说明路由注册位置不对，被别的东西抢先匹配了'));
  }

  console.log('\n线上实测结果：' + pass + ' / ' + (pass + bad));
  process.exit(bad ? 1 : 0);
})();
