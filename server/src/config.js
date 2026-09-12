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

const TURN_URLS = (process.env.TURN_URLS || '')
  .split(',')
  .map((s) => s.trim())
  .filter(Boolean);

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
const CF_TURN_KEY_ID = process.env.CF_TURN_KEY_ID || '';
const CF_TURN_API_TOKEN = process.env.CF_TURN_API_TOKEN || '';
const CF_TURN_TTL = Number(process.env.CF_TURN_TTL || 3600);
const CF_TURN_ENABLED = !!(CF_TURN_KEY_ID && CF_TURN_API_TOKEN);
// 仅用于测试：可指向本地假 CF，验证签发与缓存逻辑
const CF_TURN_API_BASE =
  process.env.CF_TURN_API_BASE || 'https://rtc.live.cloudflare.com/v1/turn/keys';

// 缓存签发的凭据：客户端每 5 分钟拉一次 /api/call/ice，
// 不缓存的话会把 CF 的签发接口打成筛子。
let _cfCache = { servers: null, expiresAt: 0 };
let _cfLastError = null;

/** 向 Cloudflare 签发一组 TURN 凭据；失败时退回上一批（过期了也比没有强） */
async function cfTurnServers() {
  if (!CF_TURN_ENABLED) return null;
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
      username: process.env.TURN_USERNAME || '',
      credential: process.env.TURN_CREDENTIAL || '',
    });
  }
  return list;
}

/** 排障用：说明这次下发的中继是哪来的、有没有出错 */
function turnInfo() {
  return {
    sources: [
      ...(CF_TURN_ENABLED ? ['cloudflare'] : []),
      ...(TURN_URLS.length ? ['static'] : []),
    ],
    cloudflareEnabled: CF_TURN_ENABLED,
    cloudflareError: _cfLastError,
    staticTurnUrls: TURN_URLS,
  };
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
  CF_TURN_ENABLED,
  iceServers,
  turnInfo,
};
