/**
 * 首次运行初始化 —— 管理台密码设置向导（服务端部分）
 *
 * ── 为什么要有这个模块 ──────────────────────────────────────────────
 * 管理台密码只在**建库那一刻**由 ADMIN_PASSWORD 决定；建完库之后想改，就必须
 * 先能登进去。于是"安装时那串密码"成了唯一入口，而它有两处会失手：
 *
 *   ① Windows 安装包：数据目录里已经有 .env（**卸载是刻意保留数据的**，重装、
 *      或上一轮测试留下的目录都会命中）时，安装向导会跳过「设置管理后台密码」
 *      那一页 —— 客户以为"没让我设密码"，其实是被人替他设过了。
 *   ② 飞牛 fpk / Docker：口令由装机脚本随机生成写进 .env，客户得自己去翻文件
 *      或容器日志才拿得到。
 *
 * 两种情况的表现一模一样：**打开管理台只看到登录页，不知道拿什么登录。**
 *
 * 所以补一条不依赖安装程序的通道：只要管理台密码**仍然是安装时那一串**（说明
 * 从来没人改过），打开管理台就先请管理员自己设一个。Windows 与飞牛同一套逻辑。
 *
 * ── 判据为什么是"能否用种子口令验过" ────────────────────────────────
 * 不用另存"初始化过没有"的标记（标记在老库上升级时会集体缺失，于是所有老客户
 * 升级后都凭空多出一个向导，那比不做还糟）。直接拿 config.ADMIN_PASSWORD 去验
 * 库里的 password_hash：
 *
 *   · 验得过  = 密码还是安装时那串，没人动过   → 该引导他设一个自己的
 *   · 验不过  = 要么有人改过密码，要么这是个老库（种子口令早就不在了）→ 不打扰
 *
 * 这个判据是**自维护**的：管理员在「系统设置」里改完密码，条件自然就不成立了，
 * 不需要任何地方记得去"清标记"。
 *
 * 唯一的例外是环境变量缺失的情形：那时 config.ADMIN_PASSWORD 是进程启动时现
 * 生成的随机值，只有"本进程刚播过种"的库才可能验得过 —— 恰好就是全新安装，
 * 正是我们想要的行为。
 */
const fs = require('fs');
const path = require('path');
const db = require('./db');
const config = require('./config');
const { hashPassword, verifyPassword } = require('./auth');

// 与安装程序（deploy/win-server/files/tools/init-env.js 的 CUSTOM_PW_RE）保持一致。
//
// 为什么用这么克制的字符集：这串密码还要写进 data\.env，而 Windows 那边是
// `for /f ... delims==` 逐行读的 —— `=` 会把值截断、`#` 开头的行被当注释整行
// 跳过、`%` 会被 cmd 二次解析。限制在"够用且到处都安全"的符号上，省掉一整类
// "密码明明输对了却登不上"的疑难杂症。
const PW_RE = /^[A-Za-z0-9._@!*+?-]{6,64}$/;
const PW_MIN = 6;
const PW_MAX = 64;

// 「管理员自己设过密码」的标记。**故意不进 settings.js 的 KEYS**：
// 那是"管理台能改的设置项"，这个只是内部状态，不该出现在系统设置里被人改掉。
const MARK_KEY = 'admin_pw_set_at';

// needSetup 要跑一次 scrypt（约 50~100ms CPU）。/status 是免鉴权接口，
// 不加缓存等于把这点 CPU 白送给任何人刷。缓存 10 秒足够 —— 界面只在打开时问一次。
const CACHE_MS = 10 * 1000;
let _cache = { at: 0, value: false };

/** 种子管理员（按用户名 + 角色定位；role 也校验，避免误改同名普通用户） */
function adminRow() {
  return db.prepare('SELECT id, username, password_hash FROM users WHERE username=? AND role=?')
    .get(config.ADMIN_USERNAME, 'admin');
}

function markerAt() {
  let raw;
  try {
    const row = db.prepare('SELECT value FROM settings WHERE key=?').get(MARK_KEY);
    raw = row ? row.value : null;
  } catch (_) {
    return 0;
  }
  if (!raw) return 0;
  try {
    return Number(JSON.parse(raw)) || 0;
  } catch (_) {
    return 0;
  }
}

function setMarker(by) {
  const now = Date.now();
  db.prepare(`INSERT INTO settings (key,value,updated_at,updated_by) VALUES (?,?,?,?)
    ON CONFLICT(key) DO UPDATE SET value=excluded.value, updated_at=excluded.updated_at, updated_by=excluded.updated_by`)
    .run(MARK_KEY, JSON.stringify(now), now, String(by || 'setup').slice(0, 60));
  _cache = { at: 0, value: false };
}

/**
 * 是否还该给管理员看"设置密码"的向导。
 * 返回 true 的唯一情形：本服务器的管理台密码**还是安装时那一串**，且从未走过向导。
 */
function needSetup() {
  const now = Date.now();
  if (now - _cache.at < CACHE_MS) return _cache.value;

  let value = false;
  do {
    if (markerAt()) break; // 向导已经走过（环境变量可能也被同步过，别再看 hash）
    // 🔴 2026-09-26 补的一条：环境里压根没配 ADMIN_PASSWORD（飞牛/Docker 部署里
    // docker/.env 在宿主机上，容器够不着，值恒为空）—— 过去只会走到下面去比对
    // 一个每次重启都变新的随机串，结果恒 false，**向导永远弹不出来**。
    // "刚装好还没设过密码"本身就是该弹的理由，不必等到比对成功。
    if (!config.ADMIN_PASSWORD_CONFIGURED) { value = true; break; }
    const u = adminRow();
    if (!u || !u.password_hash) { value = true; break; }
    try {
      value = verifyPassword(config.ADMIN_PASSWORD, u.password_hash);
    } catch (_) {
      // 老库里可能是别的哈希格式/长度不同，timingSafeEqual 会抛错 —— 当作"改过"
      value = false;
    }
  } while (false);

  _cache = { at: now, value };
  return value;
}

/** 校验新口令。返回 { value } 或 { error } */
function cleanPassword(input) {
  const s = String(input ?? '');
  if (!s) return { error: '请输入密码' };
  if (s !== s.trim()) return { error: '密码首尾不能有空格' };
  if (s.length < PW_MIN) return { error: `密码至少 ${PW_MIN} 位` };
  if (s.length > PW_MAX) return { error: `密码最多 ${PW_MAX} 位` };
  if (!PW_RE.test(s)) {
    return { error: '密码只能用字母、数字和 . _ - @ ! * + ? ，不能有空格或引号' };
  }
  return { value: s };
}

/**
 * 把新口令同步进 <DATA_DIR>/.env。
 *
 * 为什么值得做：Windows 版安装目录里有个「查看管理员密码.cmd」，它的全部价值
 * 就是"忘了密码能查回来"。向导改了库里的密码却不改这份文件，那个脚本就开始撒谎
 * ——比没有它更坏事。
 *
 * 只在文件已存在时改（飞牛/Docker 没有这个文件，返回 'no-file' 直接跳过：
 * 那边的口令在 docker/.env，容器里够不着，属于部署层面的凭据，不该由网页改）。
 */
function syncEnvFile(password) {
  const file = path.join(config.DATA_DIR, '.env');
  let text;
  try {
    text = fs.readFileSync(file, 'utf8');
  } catch (_) {
    return 'no-file';
  }
  // 逐行处理但保留原行尾：这个文件是 CRLF（cmd 的 for /f 读最后一行时更稳）
  const lines = text.split('\n');
  let hit = false;
  for (let i = 0; i < lines.length; i++) {
    const bare = lines[i].replace(/\r$/, '');
    if (!bare.startsWith('ADMIN_PASSWORD=')) continue;
    lines[i] = 'ADMIN_PASSWORD=' + password + (lines[i].endsWith('\r') ? '\r' : '');
    hit = true;
  }
  if (!hit) return 'no-key';
  try {
    fs.writeFileSync(file, lines.join('\n'), { encoding: 'utf8', mode: 0o600 });
    return 'ok';
  } catch (e) {
    return 'fail:' + e.message;
  }
}

/**
 * 执行初始化：写入新密码 + 记标记（+ 同步 .env）。
 * 返回 { ok, uid, envSync } 或 { error }。
 *
 * 注意：这里**不做** needSetup 判定，那是调用方（路由）的职责 —— 判定和写入之
 * 间必须尽量贴近，路由里是先判后写，中间没有 await，不存在竞态窗口。
 */
function runSetup(password, by) {
  const u = adminRow();
  if (!u) return { error: '管理员账号不存在，无法设置密码' };
  db.prepare('UPDATE users SET password_hash=? WHERE id=?').run(hashPassword(password), u.id);
  setMarker(by);
  const envSync = syncEnvFile(password);
  // 飞牛/Docker 没有 DATA_DIR/.env（那边的口令在宿主机的 docker/.env，容器改不到），
  // syncEnvFile 会返回 'no-file'。这时必须把口令落到容器够得着的 custom.env，
  // 否则下次启动又变随机、向导会一遍遍弹出来骚扰。
  if (envSync === 'no-file') {
    try {
      config.writeCustomPassword(password);
    } catch (e) {
      console.warn('[小智IM] 写 custom.env 失败（%s）：下次启动可能又弹向导', e.message);
    }
  }
  // 这一行很重要：谁在什么时候把这台服务器的管理密码定下来的，日志里要留痕
  console.log('[小智IM] 管理台密码已通过「首次运行向导」设置（来源 %s，.env 同步：%s）', by || '未知', envSync);
  return { ok: true, uid: u.id, envSync };
}

module.exports = { needSetup, cleanPassword, runSetup, PW_MIN, PW_MAX, PW_RE, MARK_KEY };
