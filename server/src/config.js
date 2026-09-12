const path = require('path');
const fs = require('fs');

const ROOT = path.resolve(__dirname, '..');
const DATA_DIR = process.env.DATA_DIR || path.join(ROOT, 'data');
const FILES_DIR = path.join(DATA_DIR, 'files');

fs.mkdirSync(FILES_DIR, { recursive: true });

// ---------------------------------------------------------------------------
// ICE（WebRTC 网络穿透）配置
//
// 为什么不写死在客户端：能不能打通取决于 STUN/TURN 在**当前网络**是否可用。
// 实测 `stun.qq.com` 在黑龙江电信会被直接 RST 掉，而它恰好是客户端里唯一
// 硬编码的 STUN —— 拿不到 srflx 候选，跨网通话必挂。
// 放服务端下发，以后换地址只改环境变量重启，不用重新发安卓包让所有人重装。
//
//   ICE_STUN       逗号分隔，默认四个实测可达的 STUN
//   TURN_URLS      逗号分隔，如 turn:1.2.3.4:3478?transport=udp
//   TURN_USERNAME  / TURN_CREDENTIAL  coturn 静态账号
//   CF_TURN_KEY_ID / CF_TURN_API_TOKEN  Cloudflare Realtime TURN（见下）
// ---------------------------------------------------------------------------
const ICE_STUN = (
  process.env.ICE_STUN ||
  [
    'stun:stun.miwifi.com:3478',
    'stun:stun.chat.bilibili.com:3478',
    'stun:stun.hitv.com:3478',
    // 全球 anycast，免费不限量；实测 233ms，作为前三个的兜底
    'stun:stun.cloudflare.com:3478',
  ].join(',')
)
  .split(',')
  .map((s) => s.trim())
  .filter(Boolean);

// ---------------------------------------------------------------------------
// 中继配置的持久化文件（管理台向导写这里）
//
// ⚠️ 血泪坑：以前向导把凭据写进「compose 的 .env」，路径是
//    `${DATA_DIR}/../docker/.env` —— 在容器里 DATA_DIR=/data，于是解析成
//    `/docker/.env`：一个根本不存在、也没挂载的路径。结果是向导保存后
//    内存里生效（探针看到 cloudflare 已启用），容器一重启就**全丢**，
//    而且 .env 从没被写过，永远恢复不了。
//    更麻烦的是 .env 里的改动还得 `docker compose up -d --force-recreate`
//    才会进进程 —— restart 不重读 env。
//
// 现在改为：写进 `${DATA_DIR}/turn.env`（/data 是挂载到宿主机的共享目录，
// 容器重建也在），启动时加载并覆盖环境变量。好处是改中继配置
// **既不用重建容器、也不会因为重启而丢**。
// ---------------------------------------------------------------------------
const TURN_ENV_FILE = path.join(DATA_DIR, 'turn.env');

/** 允许写进 turn.env 的键（白名单，防止被塞进别的环境变量） */
const TURN_ENV_KEYS = [
  'TURN_URLS',
  'TURN_USERNAME',
  'TURN_CREDENTIAL',
  'CF_TURN_KEY_ID',
  'CF_TURN_API_TOKEN',
];

function turnEnvPath() {
  return TURN_ENV_FILE;
}

/** 读 turn.env，返回 {key: value}；文件不存在或损坏都返回 {}（绝不因此崩） */
function readTurnEnv() {
  try {
    if (!fs.existsSync(TURN_ENV_FILE)) return {};
    const out = {};
    for (const line of fs.readFileSync(TURN_ENV_FILE, 'utf8').split(/\r?\n/)) {
      const s = line.trim();
      if (!s || s.startsWith('#')) continue;
      const i = s.indexOf('=');
      if (i <= 0) continue;
      const k = s.slice(0, i).trim();
      if (!TURN_ENV_KEYS.includes(k)) continue;
      out[k] = s.slice(i + 1).trim();
    }
    return out;
  } catch {
    return {};
  }
}

/** 合并写回 turn.env（只动传入的键，保留其他行） */
function writeTurnEnv(patch) {
  const cur = readTurnEnv();
  const next = { ...cur, ...patch };
  // 空值视为「清除」，不写进文件
  const lines = [
    '# 音视频中继配置 —— 由管理台「系统设置 → 音视频中继配置」写入。',
    '# 这个文件在共享数据目录里，容器重建/重启都不会丢失；',
    '# 改完立即生效，不需要重建容器。手工改也可以，重启后生效。',
  ];
  for (const k of TURN_ENV_KEYS) {
    const v = next[k];
    if (v) lines.push(`${k}=${v}`);
  }
  fs.writeFileSync(TURN_ENV_FILE, lines.join('\n') + '\n', 'utf8');
}

// 启动时先加载持久化的中继配置，再落到下面的变量里。
const _turnEnv = readTurnEnv();

const TURN_URLS = (_turnEnv.TURN_URLS || process.env.TURN_URLS || '')
  .split(',')
  .map((s) => s.trim())
  .filter(Boolean);

const TURN_USERNAME = _turnEnv.TURN_USERNAME || process.env.TURN_USERNAME || '';
const TURN_CREDENTIAL =
  _turnEnv.TURN_CREDENTIAL || process.env.TURN_CREDENTIAL || '';

// ---------------------------------------------------------------------------
// Cloudflare Realtime TURN —— 家宽没有公网 IP 时的正解
//
// 自建 coturn 的前提是「公网能把 UDP/TCP 打进家里」，这需要：
//   ① 真公网 IP + 路由器端口映射，或
//   ② ZeroNews 之类的隧道（免费版不支持 TCP/UDP，要 ¥22/月）
// 两者都办不到时就卡死了。Cloudflare TURN 绕开这个问题：
//   · 只用出站连接，443/TLS 出得去就能用，**完全不需要端口映射**
//   · 免费额度 1TB/月（实测本机到 turn.cloudflare.com 的
//     80/443/5349 都在 200ms 上下，rtc.live 的签发接口 426ms）
//
// 凭据不是静态的，要用 key + API token 现签现用（TTL 可设 1 分钟~24 小时），
// 所以下面的 iceServers() 是 async —— 调用方必须 await。
//
// 开通：dash.cloudflare.com → Realtime → TURN keys 新建，拿到
// KEY ID 与 scope 为 "Calls: Edit" 的 API Token，写进 .env 两项即可。
// ---------------------------------------------------------------------------
// 用 let 而非 const：管理台向导保存后要能**不重启**热加载新凭据。
// （.env 是给"下次启动"用的；进程内存里的这份支持即时生效，
//   两者都更新才不会出现「界面说保存成功、实际没生效」的割裂。）
let CF_TURN_KEY_ID = _turnEnv.CF_TURN_KEY_ID || process.env.CF_TURN_KEY_ID || '';
let CF_TURN_API_TOKEN =
  _turnEnv.CF_TURN_API_TOKEN || process.env.CF_TURN_API_TOKEN || '';
const CF_TURN_TTL = Number(process.env.CF_TURN_TTL || 3600);
// 仅用于测试：可指向本地假 CF，验证签发与缓存逻辑
const CF_TURN_API_BASE =
  process.env.CF_TURN_API_BASE || 'https://rtc.live.cloudflare.com/v1/turn/keys';

// 缓存签发的凭据：客户端每 5 分钟拉一次 /api/call/ice，
// 不缓存的话会把 CF 的签发接口打成筛子。
let _cfCache = { servers: null, expiresAt: 0 };
let _cfLastError = null;

const cfEnabled = () => !!(CF_TURN_KEY_ID && CF_TURN_API_TOKEN);

/**
 * 热加载一对新凭据（管理台向导保存后调用）。
 * 会清掉旧的签发缓存，让下一次 /api/call/ice 立刻用新凭据。
 * **同时落盘到 turn.env** —— 以前只改内存，容器一重启凭据就没了，
 * 表现是「昨天还好好的跨网通话，今天突然打不通」。
 */
function applyTurnCredentials(keyId, apiToken) {
  CF_TURN_KEY_ID = String(keyId || '').trim();
  CF_TURN_API_TOKEN = String(apiToken || '').trim();
  _cfCache = { servers: null, expiresAt: 0 };
  _cfLastError = null;
  try {
    writeTurnEnv({
      CF_TURN_KEY_ID: CF_TURN_KEY_ID,
      CF_TURN_API_TOKEN: CF_TURN_API_TOKEN,
    });
  } catch {
    // 落盘失败不影响本次热生效，但会在 turnInfo 里体现不出来 —— 记录即可
  }
  return cfEnabled();
}

/** 清除 Cloudflare 凭据（管理台「移除」按钮） */
function clearTurnCredentials() {
  CF_TURN_KEY_ID = '';
  CF_TURN_API_TOKEN = '';
  _cfCache = { servers: null, expiresAt: 0 };
  _cfLastError = null;
  try {
    writeTurnEnv({ CF_TURN_KEY_ID: '', CF_TURN_API_TOKEN: '' });
  } catch {
    /* 同上 */
  }
}

/** 向 Cloudflare 签发一组 TURN 凭据；失败时退回上一批（过期了也比没有强） */
async function cfTurnServers() {
  if (!cfEnabled()) return null;
  const now = Date.now();
  if (_cfCache.servers && now < _cfCache.expiresAt) return _cfCache.servers;

  const url =
    CF_TURN_API_BASE.replace(/\/$/, '') +
    '/' +
    encodeURIComponent(CF_TURN_KEY_ID) +
    '/credentials/generate';
  const ctl = new AbortController();
  const timer = setTimeout(() => ctl.abort(), 5000);
  try {
    const res = await fetch(url, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${CF_TURN_API_TOKEN}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ ttl: Math.max(60, Math.min(86400, CF_TURN_TTL)) }),
      signal: ctl.signal,
    });
    if (!res.ok) {
      const body = await res.text().catch(() => '');
      _cfLastError = `HTTP ${res.status} ${body.slice(0, 160)}`;
      return _cfCache.servers;
    }
    const data = await res.json();
    const raw = data && data.iceServers;
    // 不同 SDK 版本返回对象或数组，统一成数组
    const arr = Array.isArray(raw) ? raw : raw ? [raw] : [];
    if (!arr.length) {
      _cfLastError = '响应里没有 iceServers';
      return _cfCache.servers;
    }
    // 提前 10 分钟作废，避免在网络边界上发出去就已经过期
    _cfCache = {
      servers: arr,
      expiresAt: now + Math.max(60, CF_TURN_TTL - 600) * 1000,
    };
    _cfLastError = null;
    return arr;
  } catch (e) {
    _cfLastError = String((e && e.message) || e).slice(0, 160);
    return _cfCache.servers;
  } finally {
    clearTimeout(timer);
  }
}

/** 组装成 flutter_webrtc 的 iceServers 结构 */
async function iceServers() {
  const list = ICE_STUN.map((urls) => ({ urls }));

  const cf = await cfTurnServers();
  if (cf && cf.length) list.push(...cf);

  if (TURN_URLS.length) {
    list.push({
      urls: TURN_URLS,
      username: TURN_USERNAME,
      credential: TURN_CREDENTIAL,
    });
  }
  return list;
}

/** 排障用：说明这次下发的中继是哪来的、有没有出错 */
function turnInfo() {
  return {
    sources: [
      ...(cfEnabled() ? ['cloudflare'] : []),
      ...(TURN_URLS.length ? ['static'] : []),
    ],
    cloudflareEnabled: cfEnabled(),
    cloudflareError: _cfLastError,
    staticTurnUrls: TURN_URLS,
    // 向导要用的遮盖值，绝不回传明文
    cloudflareKeyIdMasked: _mask(CF_TURN_KEY_ID),
    cloudflareTokenMasked: _mask(CF_TURN_API_TOKEN),
  };
}

/** 只露头尾，中间打星；用于管理台回显「已配置成什么样」而不泄露密钥 */
function _mask(s) {
  const v = String(s || '');
  if (!v) return '';
  if (v.length <= 8) return '*'.repeat(v.length);
  return v.slice(0, 4) + '*'.repeat(Math.min(12, v.length - 8)) + v.slice(-4);
}

/**
 * 用「传进来的」凭据实测一次 CF 签发接口，判断这对 key 是否真的可用。
 * 向导必须先把关，否则会把错值写进 .env，重启后接口 500 或静默无中继。
 * 与 cfTurnServers() 的区别：不读环境变量、不写缓存，纯探测。
 * @returns {Promise<{ok:boolean, error?:string, urls?:string[]}>}
 */
async function probeTurnCredentials(keyId, apiToken) {
  const kid = String(keyId || '').trim();
  const tok = String(apiToken || '').trim();
  if (!kid || !tok) return { ok: false, error: 'Key ID 与 API Token 都不能为空' };
  if (!/^[0-9a-f]{32}$/i.test(kid)) {
    return { ok: false, error: 'Key ID 格式不对：应为 32 位十六进制字符' };
  }
  if (!/^[0-9a-f]{64}$/i.test(tok)) {
    return { ok: false, error: 'API Token 格式不对：应为 64 位十六进制字符' };
  }
  try {
    const r = await fetch(
      `${CF_TURN_API_BASE.replace(/\/$/, '')}/${encodeURIComponent(kid)}/credentials/generate`,
      {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${tok}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({ ttl: 60 }),
        signal: AbortSignal.timeout(10000),
      },
    );
    const text = await r.text();
    if (!r.ok) {
      // CF 的报错信息对排查很有用，但要截断防止刷屏
      return { ok: false, error: `Cloudflare 返回 ${r.status}：${text.slice(0, 200)}` };
    }
    let urls = [];
    try {
      const j = JSON.parse(text);
      const s = j && j.iceServers;
      const first = Array.isArray(s) ? s[0] : s;
      if (first && first.urls) {
        urls = Array.isArray(first.urls) ? first.urls : [first.urls];
      }
    } catch { /* 解析失败不影响「凭据有效」的结论 */ }
    return { ok: true, urls };
  } catch (e) {
    const msg = String((e && e.message) || e);
    if (/timeout|abort/i.test(msg)) {
      return { ok: false, error: '连接 Cloudflare 超时，请检查服务端出网是否正常' };
    }
    return { ok: false, error: msg };
  }
}

module.exports = {
  PORT: Number(process.env.PORT || 3602),
  JWT_SECRET: process.env.JWT_SECRET || 'change-me-xiaozhi-im-secret',
  DATA_DIR,
  FILES_DIR,
  DB_PATH: process.env.DB_PATH || path.join(DATA_DIR, 'xiaozhi-im.db'),
  ADMIN_USERNAME: process.env.ADMIN_USERNAME || 'admin',
  ADMIN_PASSWORD: process.env.ADMIN_PASSWORD || 'admin123',
  MAX_FILE_MB: Number(process.env.MAX_FILE_MB || 50),
  PUBLIC_URL: process.env.PUBLIC_URL || '',
  ICE_STUN,
  TURN_URLS,
  TURN_USERNAME,
  TURN_CREDENTIAL,
  // 中继配置持久化文件（管理台向导读写它；在共享数据目录里，重启不丢）
  TURN_ENV_FILE,
  turnEnvPath,
  readTurnEnv,
  writeTurnEnv,
  // 注意：这是**函数**不是常量 —— 向导热加载后它的值会变，
  // 消费方必须每次调用，不能在模块顶层取值缓存。
  CF_TURN_ENABLED: cfEnabled,
  iceServers,
  turnInfo,
  probeTurnCredentials,
  applyTurnCredentials,
  clearTurnCredentials,
};
