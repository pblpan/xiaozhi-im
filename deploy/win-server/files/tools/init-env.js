#!/usr/bin/env node
/**
 * 小智IM 服务端（Windows 版）—— 安装时的本地初始化
 *
 * 由安装程序在**装完文件之后**调用一次：
 *     node.exe init-env.js <数据目录>
 *
 * 做三件事：
 *   1) 建数据目录 / 日志目录（服务端自己也建，但这里先建好，安装程序才好往下走）
 *   2) 首次安装生成 data\.env —— 随机的管理台初始口令 + JWT 密钥
 *   3) 探测本机局域网 IP，交给安装程序显示在「安装完成」页
 *
 * ── 为什么非得有这一步 ───────────────────────────────────────────────
 * 服务端在 ADMIN_PASSWORD 缺失时会自己生成一个随机口令，但它把口令**打进日志**。
 * Windows 版是隐藏窗口跑在后台的，客户根本看不到日志 ——
 * 结果就是"装完了不知道拿什么登录"，比给个默认口令更糟。
 * 所以这里显式生成、落到 data\.env，安装完成页直接读出来显示给客户。
 *
 * ── 幂等 ───────────────────────────────────────────────────────────
 * data\.env 已存在（重装 / 升级 / 修复安装）就**一个字都不改** ——
 * 客户可能已经改过管理台密码，重装把密码冲掉会让人在门口进不去。
 *
 * 输出（供安装程序用 ExecToStack 抓，一行一个 KEY=VALUE）：
 *     XIAOZHI_ENV_FILE=...
 *     XIAOZHI_DATA_DIR=...
 *     XIAOZHI_ADMIN_PASSWORD=...
 *     XIAOZHI_LAN_IP=192.168.x.x
 *     XIAOZHI_FRESH=1|0        （1=这次新生成的密码，0=沿用旧的）
 */
'use strict';

const crypto = require('crypto');
const fs = require('fs');
const os = require('os');
const path = require('path');

const HERE = __dirname;

/** 管理台初始口令：20 位 hex（80 bit 熵），人能手抄，也扛得住在线爆破 */
function genPassword() {
  return crypto.randomBytes(10).toString('hex');
}

/** JWT 密钥用 base64url：不含 + / 和易看错的符号 */
function genJwtSecret() {
  return crypto.randomBytes(32).toString('base64url');
}

/**
 * 挑一个"别人能访问到的"局域网地址。
 * 排除：回环、169.254 链路本地（没有 DHCP 时的自分配地址）、虚拟网卡常见的 192.168.56.x。
 * 优先 192.168.x → 10.x → 172.16-31.x，都没有就退回第一个非内部 IPv4。
 */
function lanIp() {
  const cands = [];
  const ifaces = os.networkInterfaces();
  for (const name of Object.keys(ifaces)) {
    for (const a of ifaces[name] || []) {
      // Node 18+ 的 family 是数字 4，老版本是字符串 'IPv4'，两种都认
      const isV4 = a.family === 4 || a.family === 'IPv4';
      if (!isV4 || a.internal) continue;
      if (a.address.startsWith('169.254.')) continue;
      cands.push({ name, ip: a.address });
    }
  }
  const score = (ip) => {
    if (ip.startsWith('192.168.')) return 0;
    if (ip.startsWith('10.')) return 1;
    if (/^172\.(1[6-9]|2\d|3[01])\./.test(ip)) return 2;
    return 3;
  };
  cands.sort((x, y) => score(x.ip) - score(y.ip));
  return cands.length ? cands[0].ip : '127.0.0.1';
}

function readKv(file) {
  const out = {};
  try {
    const text = fs.readFileSync(file, 'utf8');
    for (const line of text.split(/\r?\n/)) {
      if (!line.trim() || line.trim().startsWith('#')) continue;
      const i = line.indexOf('=');
      if (i < 0) continue;
      out[line.slice(0, i).trim()] = line.slice(i + 1).trim();
    }
  } catch (_) { /* 还没有这个文件 */ }
  return out;
}

function main() {
  const dataDir = process.argv[2] || path.join(HERE, '..', '..', 'data');
  const logsDir = path.join(dataDir, 'logs');
  const filesDir = path.join(dataDir, 'files');
  for (const d of [dataDir, logsDir, filesDir]) {
    fs.mkdirSync(d, { recursive: true });
  }

  const envFile = path.join(dataDir, '.env');
  const old = readKv(envFile);

  let pass = old.ADMIN_PASSWORD || '';
  let secret = old.JWT_SECRET || '';
  let fresh = 0;

  if (!pass) {
    pass = genPassword();
    fresh = 1;
  }
  if (!secret) {
    secret = genJwtSecret();
  }

  if (!fs.existsSync(envFile) || fresh === 1 || !old.JWT_SECRET) {
    // 行尾显式用 CRLF：这个文件会被 .cmd 的 `for /f` 逐行读，
    // 老版本 cmd 对"最后一行没有行尾"会吃掉最后一行，统一 CRLF 最省事。
    const body = [
      '# 小智IM 服务端（Windows 版）本地配置 —— 由安装程序生成，一般不用手改。',
      '#',
      '# ADMIN_PASSWORD  管理台初始口令，只在**首次建库**时用来创建 admin 账号。',
      '#                 忘了密码看这里，或跑安装目录下的「查看管理员密码.cmd」。',
      '#                 改密码请到管理台「系统设置」，改了这里不生效（账号已存在）。',
      '# JWT_SECRET       签发登录凭证用的密钥，泄漏等于别人能伪造管理员登录。',
      '#                 删掉它会导致所有人重新登录（服务端会再生成一个）。',
      '',
      'ADMIN_USERNAME=admin',
      'ADMIN_PASSWORD=' + pass,
      'JWT_SECRET=' + secret,
      '',
    ].join('\r\n');
    fs.writeFileSync(envFile, body, { encoding: 'utf8', mode: 0o600 });
  }

  const ip = lanIp();

  // 额外写一份标准 INI 给**安装程序**读。
  // 为什么不用 stdout：NSIS 拿到 ExecToStack 的输出后要做字符串解析，
  // 而 ReadINIStr 是它内建的、不用自己切字符串（少一处"装出来密码是空的"）。
  // 安装程序读完会把它删掉 —— .env 才是长期保存的那一份。
  try {
    fs.writeFileSync(
      path.join(dataDir, '.install-result.ini'),
      '[install]\r\n' +
      'adminPassword=' + pass + '\r\n' +
      'lanIp=' + ip + '\r\n' +
      'dataDir=' + dataDir + '\r\n' +
      'envFile=' + envFile + '\r\n' +
      'fresh=' + fresh + '\r\n',
      { encoding: 'utf8' },
    );
  } catch (_) { /* 写不进去也不影响：安装完成页会退化成"请看 data\.env" */ }

  const out = [
    'XIAOZHI_ENV_FILE=' + envFile,
    'XIAOZHI_DATA_DIR=' + dataDir,
    'XIAOZHI_ADMIN_PASSWORD=' + pass,
    'XIAOZHI_LAN_IP=' + ip,
    'XIAOZHI_FRESH=' + fresh,
  ];
  process.stdout.write(out.join('\n') + '\n');
}

main();
