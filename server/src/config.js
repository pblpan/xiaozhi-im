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
//   ICE_STUN       逗号分隔，默认三个国内实测可达的 STUN
//   TURN_URLS      逗号分隔，如 turn:1.2.3.4:3478?transport=udp
//   TURN_USERNAME  / TURN_CREDENTIAL  coturn 静态账号
// ---------------------------------------------------------------------------
const ICE_STUN = (
  process.env.ICE_STUN ||
  [
    'stun:stun.miwifi.com:3478',
    'stun:stun.chat.bilibili.com:3478',
    'stun:stun.hitv.com:3478',
  ].join(',')
)
  .split(',')
  .map((s) => s.trim())
  .filter(Boolean);

const TURN_URLS = (process.env.TURN_URLS || '')
  .split(',')
  .map((s) => s.trim())
  .filter(Boolean);

/** 组装成 flutter_webrtc 的 iceServers 结构 */
function iceServers() {
  const list = ICE_STUN.map((urls) => ({ urls }));
  if (TURN_URLS.length) {
    list.push({
      urls: TURN_URLS,
      username: process.env.TURN_USERNAME || '',
      credential: process.env.TURN_CREDENTIAL || '',
    });
  }
  return list;
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
  iceServers,
};
