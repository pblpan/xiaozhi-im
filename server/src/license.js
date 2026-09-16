'use strict';
/**
 * 授权校验（Ed25519 非对称签名）
 * ============================================================
 * 三种凭证，一个公钥，私钥只在本机「注册机」里（绝不入库）：
 *
 *   device + exp  → 按年订阅，到期后业务接口全拦
 *   device 无 exp → 一次性买断，绑机器码，永久有效
 *   master        → 主密钥，任意机器可用（应急 / 自用）
 *
 * 未激活时走 45 天全功能试用，到期转「只读门禁」：能登录、能看状态、
 * 能激活，业务接口一律 403 —— 让管理员看得见「为什么用不了」，
 * 而不是对着一个打不开的软件干瞪眼。
 *
 * ------------------------------------------------------------
 * 三处刻意偏离通用做法（都是被小智的实际环境逼出来的，别改回去）：
 *
 * 1) 机器指纹**必须由宿主机提供**，不能用容器内的东西
 *    实测容器里：hostname = 容器 ID（每次重建都变）、
 *    /etc/machine-id 不存在（Docker 默认不挂载）、eth0 是虚拟网卡。
 *    用它们做指纹的后果是 —— 客户/龙哥自己 `docker compose up -d --force-recreate`
 *    升级一次，机器码就变了，**授权当场失效**。所以 compose 把宿主机的
 *    /etc/machine-id 只读挂进 /host/machine-id，指纹从那里取：
 *    容器重建不变、换机器必变、连 /data 一起拷走也没用。
 *
 * 2) license.json 里的 location **只记录不拦截**
 *    通用做法是「数据目录变了就要求重新激活」。但换目录（挂载点调整、
 *    迁移数据）是很正常的运维动作，拦下来只会制造事故，而且挡不住真正的
 *    翻拷 —— 那件事已经由「机器码绑在签名里」挡住了（拷到别的机器，
 *    machine-id 不同 → 验签里的 mc 对不上）。所以这里只在管理台提示。
 *
 * 3) 试用期起点**双写**（license.json + settings 表），取两者最早的
 *    只写文件的话，删掉 license.json 就等于重置试用期，无限试用。
 *    两处分开存，客户要重置得同时知道并清掉两个地方。
 */

const crypto = require('crypto');
const fs = require('fs');
const os = require('os');
const path = require('path');
const config = require('./config');
const db = require('./db');

/** 试用天数（龙哥 2026-09-16 定：45 天全功能） */
const TRIAL_DAYS = 45;
const DAY_MS = 24 * 60 * 60 * 1000;

/** 公钥：与注册机里的私钥配对。私钥只存在本机注册机，服务端拿它反推不出私钥 */
const PUBLIC_KEY_B64 = 'MCowBQYDK2VwAyEAaLJiVWVtcUNlaVZDdWJ01b/nzFl8wPJ1BGXCp37sC0I=';

/** 机器码盐值：换个产品/换套密钥时改它，避免码型撞车 */
const MC_SALT = 'xiaozhi-im/license/v1';

/** 宿主机 machine-id 在容器内的挂载点（compose 里配置） */
const HOST_ID_FILE = '/host/machine-id';

/** 时钟回拨容差：小于这个幅度的往回跳（NTP 校正、时区手滑）不算异常 */
const CLOCK_SKEW_MS = 6 * 60 * 60 * 1000;

/** lastSeen 落盘节流：状态是每个请求都要算的，别每次都写盘 */
const LASTSEEN_WRITE_GAP = 60 * 1000;

/** state() 结果缓存：同一秒内的多个请求不重复读盘/验签 */
const STATE_CACHE_MS = 1000;

const LICENSE_FILE = path.join(config.DATA_DIR, 'license.json');
const DB_KEY = 'license_installed_at';

// ---------------------------------------------------------------- 机器指纹

let _fpCache = null;

/**
 * 取宿主机指纹种子。按可靠性排序，返回 { source, raw, hint }。
 *
 * source 会回显到管理台 —— 这是**最要紧的一处可观测性**：
 * 客户忘了挂载宿主机标识时，指纹会退化成容器 ID，界面上必须明确警示，
 * 否则他会遇到「升级一次授权就没了」这种最坏体验。
 */
function fingerprint() {
  if (_fpCache) return _fpCache;

  // 1) 部署方显式指定（最明确，可用于灾难恢复）
  const envId = String(process.env.XIAOZHI_MACHINE_ID || '').trim();
  if (envId) {
    _fpCache = { source: 'env', raw: envId, hint: '由环境变量 XIAOZHI_MACHINE_ID 指定' };
    return _fpCache;
  }

  // 2) 宿主机 machine-id（compose 挂载；容器重建不变、换机器必变）
  for (const p of [HOST_ID_FILE, '/etc/machine-id']) {
    try {
      const st = fs.statSync(p);
      if (!st.isFile() || st.size < 8 || st.size > 256) continue;
      const raw = fs.readFileSync(p, 'utf8').trim();
      if (!raw) continue;
      _fpCache = {
        source: p === HOST_ID_FILE ? 'host-machine-id' : 'machine-id',
        raw,
        hint: p === HOST_ID_FILE ? '取自宿主机 /etc/machine-id（容器重建不受影响）'
          : '取自本机 /etc/machine-id',
      };
      return _fpCache;
    } catch { /* 下一个 */ }
  }

  // 3) 裸机兜底（Windows exe 版服务端、无 systemd 的系统）
  //    虚拟网卡要排掉：VMware / Hyper-V / VirtualBox 的 MAC 每次开机都可能变，
  //    拿它当指纹等于给客户埋一颗定时炸弹。
  const skip = /vmware|virtualbox|hyper-?v|vethernet|vmnet|loopback|virtual|docker|tailscale|zerotier|npcap|tap/i;
  const macs = [];
  try {
    for (const [name, addrs] of Object.entries(os.networkInterfaces())) {
      if (skip.test(name)) continue;
      for (const a of addrs || []) {
        if (a.internal || !a.mac || a.mac === '00:00:00:00:00:00') continue;
        if (a.family !== 'IPv4' && a.family !== 4) continue;   // 同一网卡只收一次
        macs.push(a.mac.toLowerCase());
      }
    }
  } catch { /* ignore */ }
  macs.sort();

  if (macs.length) {
    _fpCache = {
      source: 'hostname+mac',
      raw: `${os.hostname()}|${macs[0]}`,
      hint: '取自主机名与物理网卡（未找到 machine-id；换网卡或改主机名会改变机器码）',
    };
    return _fpCache;
  }

  // 4) 最后的兜底：只能保证「同一容器生命周期内一致」。
  //    这种情况必须让客户看见警告 —— 重建容器就要重新出码。
  _fpCache = {
    source: 'hostname-only',
    raw: `${os.hostname()}|${os.platform()}`,
    hint: '⚠ 未取到宿主机标识，指纹可能随容器重建而改变（请检查 compose 是否挂载了 /etc/machine-id）',
  };
  return _fpCache;
}

/** 机器码：给人抄写的形式，XZ-XXXX-XXXX-XXXX-XXXX */
function machineCode() {
  const h = crypto.createHash('sha256')
    .update(`${MC_SALT}|${fingerprint().raw}`, 'utf8')
    .digest('hex').toUpperCase();
  return 'XZ-' + h.slice(0, 16).replace(/(.{4})(?=.)/g, '$1-');
}

/** 指纹是否可靠（不可靠时管理台要提示，但不影响授权本身） */
function fingerprintReliable() {
  return fingerprint().source !== 'hostname-only';
}

// ---------------------------------------------------------------- 凭据存储

function readStore() {
  try {
    const raw = fs.readFileSync(LICENSE_FILE, 'utf8');
    const o = JSON.parse(raw);
    return o && typeof o === 'object' ? o : {};
  } catch {
    return {};
  }
}

let _storeCache = null;
function store() {
  if (!_storeCache) _storeCache = readStore();
  return _storeCache;
}

function writeStore(patch) {
  const next = Object.assign({}, store(), patch, { v: 1 });
  next.location = config.DATA_DIR;
  try {
    fs.mkdirSync(path.dirname(LICENSE_FILE), { recursive: true });
    // 先写临时文件再改名：避免写一半断电留下坏 JSON，导致「授权莫名失效」
    const tmp = LICENSE_FILE + '.tmp';
    fs.writeFileSync(tmp, JSON.stringify(next, null, 2), 'utf8');
    fs.renameSync(tmp, LICENSE_FILE);
  } catch (e) {
    console.error('[license] 写入失败:', e.message);
    return false;
  }
  _storeCache = next;
  return true;
}

function dbInstalledAt() {
  try {
    const row = db.prepare('SELECT value FROM settings WHERE key=?').get(DB_KEY);
    if (!row) return null;
    const n = Number(JSON.parse(row.value));
    return Number.isFinite(n) && n > 0 ? n : null;
  } catch {
    return null;
  }
}

function setDbInstalledAt(ts) {
  try {
    db.prepare(`INSERT INTO settings (key,value,updated_at,updated_by) VALUES (?,?,?,?)
      ON CONFLICT(key) DO UPDATE SET value=excluded.value, updated_at=excluded.updated_at, updated_by=excluded.updated_by`)
      .run(DB_KEY, JSON.stringify(ts), Date.now(), 'license');
  } catch (e) {
    console.error('[license] 试用期起点入库失败:', e.message);
  }
}

/**
 * 试用期起点。两处取最早，并顺手把缺失/被改大的那一份补回最早值。
 * 「改大」也要挡：把 installedAt 往后改等于延长试用。
 *
 * ⚠ 必须接收调用方的 now，**不要在里面重新 Date.now()**：
 * 首次写入时若取的是晚几毫秒的另一个时间戳，`trialEnd - now` 就会比
 * 45 天多出几毫秒，界面上的"剩余天数"立刻显示成 46 天（首日就多一天）。
 */
function installedAt(now) {
  const f = Number(store().installedAt);
  const fOk = Number.isFinite(f) && f > 0 ? f : null;
  const d = dbInstalledAt();

  const vals = [fOk, d].filter((x) => x !== null);
  if (!vals.length) {
    writeStore({ installedAt: now });
    setDbInstalledAt(now);
    return now;
  }

  const earliest = Math.min(...vals);
  if (fOk !== earliest) writeStore({ installedAt: earliest });
  if (d !== earliest) setDbInstalledAt(earliest);
  return earliest;
}

// ---------------------------------------------------------------- 验签

let _publicKey = null;
function publicKey() {
  if (!_publicKey) {
    _publicKey = crypto.createPublicKey({
      key: Buffer.from(PUBLIC_KEY_B64, 'base64'),
      format: 'der',
      type: 'spki',
    });
  }
  return _publicKey;
}

/**
 * 校验一枚授权码。返回 { ok, payload } 或 { ok:false, error }。
 * token 形式：base64url(payloadJson).base64url(ed25519Sig)
 */
function verifyToken(token) {
  const s = String(token || '').trim().replace(/\s+/g, '');
  if (!s) return { ok: false, error: '授权码为空' };
  const parts = s.split('.');
  if (parts.length !== 2) return { ok: false, error: '授权码格式不对（应为两段，以「.」分隔）' };

  let payloadBuf;
  try {
    payloadBuf = Buffer.from(parts[0], 'base64url');
  } catch {
    return { ok: false, error: '授权码内容无法解析' };
  }

  let sigOk = false;
  try {
    sigOk = crypto.verify(null, payloadBuf, publicKey(), Buffer.from(parts[1], 'base64url'));
  } catch {
    sigOk = false;
  }
  if (!sigOk) return { ok: false, error: '授权码签名无效（不是本产品签发的，或抄写时漏了字符）' };

  let p;
  try {
    p = JSON.parse(payloadBuf.toString('utf8'));
  } catch {
    return { ok: false, error: '授权码内容不是合法数据' };
  }

  if (!p || p.v !== 1) return { ok: false, error: '授权码版本不受支持' };
  if (p.typ !== 'device' && p.typ !== 'master') return { ok: false, error: '授权码类型不受支持' };

  // 设备授权必须绑定本机 —— 这是防「拷给同行」的核心，
  // 客户把服务端源码全看了也造不出别人机器的授权码。
  if (p.typ === 'device') {
    const mc = machineCode();
    if (String(p.mc || '') !== mc) {
      return {
        ok: false,
        error: '授权码不是发给这台机器的',
        machineMismatch: true,
        expect: mc,
        got: String(p.mc || '(空)'),
      };
    }
  }

  if (Number.isFinite(Number(p.exp)) && p.exp > 0) {
    if (Date.now() > Number(p.exp)) {
      return { ok: false, error: '授权码已到期', payload: p, expired: true };
    }
  }

  return { ok: true, payload: p };
}

// ---------------------------------------------------------------- 状态

let _stateCache = null;
let _stateAt = 0;

/** 当前授权状态。带 1 秒缓存，避免每个请求都读盘 */
function state() {
  const now = Date.now();
  if (_stateCache && now - _stateAt < STATE_CACHE_MS) return _stateCache;

  const st = computeState(now);
  _stateCache = st;
  _stateAt = now;

  // lastSeen 节流落盘：用于发现系统时间被往回拨
  const last = Number(store().lastSeen) || 0;
  if (now - last > LASTSEEN_WRITE_GAP) writeStore({ lastSeen: now });

  return st;
}

function computeState(now) {
  const s = store();
  const mc = machineCode();
  const fp = fingerprint();
  const base = {
    machineCode: mc,
    trialDays: TRIAL_DAYS,
    dataDir: config.DATA_DIR,
    fingerprintSource: fp.source,
    fingerprintHint: fp.hint,
    fingerprintReliable: fingerprintReliable(),
    locationMismatch: !!s.location && s.location !== config.DATA_DIR,
    checkedAt: now,
  };

  // 时钟回拨：记了 lastSeen 就往回跳，说明有人想用改系统时间的方式骗过到期检查
  const last = Number(s.lastSeen) || 0;
  if (last && now < last - CLOCK_SKEW_MS) {
    return Object.assign(base, {
      ok: false, mode: 'none', reason: 'clock_back', gated: true,
      message: '系统时间被检测到往回调整，授权校验已暂停。请把系统时间校准后重试。',
    });
  }

  const iat = installedAt(now);

  // ---- 已激活：先看凭证 ----
  if (s.token) {
    const r = verifyToken(s.token);
    if (r.ok) {
      const p = r.payload;
      const exp = Number(p.exp) > 0 ? Number(p.exp) : null;
      return Object.assign(base, {
        ok: true,
        mode: p.typ === 'master' ? 'master' : 'device',
        perpetual: !exp,
        reason: null,
        gated: false,
        installedAt: iat,
        activatedAt: Number(s.activatedAt) || null,
        expiresAt: exp,
        daysLeft: exp ? Math.ceil((exp - now) / DAY_MS) : null,
        message: exp
          ? '订阅授权有效'
          : (p.typ === 'master' ? '主密钥（通用授权）' : '买断授权，永久有效'),
      });
    }
    // 凭证存在但无效（换机器 / 到期 / 被篡改）→ 不回落到试用，
    // 否则「激活一次就永久获得 45 天试用」成立
    const expired = !!r.expired;
    return Object.assign(base, {
      ok: false, mode: 'none', reason: expired ? 'expired' : 'bad_token', gated: true,
      installedAt: iat,
      expiresAt: expired ? Number(r.payload?.exp) : null,
      daysLeft: 0,
      message: r.error + (r.machineMismatch ? `。本机机器码：${mc}，授权码绑定的是：${r.got}` : ''),
      machineMismatch: !!r.machineMismatch,
    });
  }

  // ---- 未激活：走试用 ----
  const trialEnd = iat + TRIAL_DAYS * DAY_MS;
  if (now <= trialEnd) {
    return Object.assign(base, {
      ok: true, mode: 'trial', perpetual: false, reason: null, gated: false,
      installedAt: iat, expiresAt: trialEnd,
      daysLeft: Math.max(0, Math.ceil((trialEnd - now) / DAY_MS)),
      message: `试用期（共 ${TRIAL_DAYS} 天）`,
    });
  }

  return Object.assign(base, {
    ok: false, mode: 'none', reason: 'trial_expired', gated: true,
    installedAt: iat, expiresAt: trialEnd, daysLeft: 0,
    message: `${TRIAL_DAYS} 天试用期已结束。请在管理台「授权管理」里填写授权码后继续使用（登录不受影响）。`,
  });
}

/** 给客户端/管理台的对外视图（不泄露 token 本身） */
function publicState() {
  const st = state();
  return {
    ok: st.ok,
    gated: st.gated,
    mode: st.mode,
    reason: st.reason || null,
    message: st.message || '',
    machineCode: st.machineCode,
    trialDays: st.trialDays,
    daysLeft: st.daysLeft === undefined ? null : st.daysLeft,
    expiresAt: st.expiresAt || null,
    installedAt: st.installedAt || null,
    activatedAt: st.activatedAt || null,
    perpetual: !!st.perpetual,
    fingerprint: { source: st.fingerprintSource, hint: st.fingerprintHint, reliable: st.fingerprintReliable },
    locationMismatch: !!st.locationMismatch,
  };
}

// ---------------------------------------------------------------- 激活

/** 写入授权码。成功返回 { ok:true, state }，失败返回 { error } */
function activate(token, by) {
  const r = verifyToken(token);
  if (!r.ok) {
    // 机器不匹配时把两个码都回给管理员，省得来回问「我的机器码是啥」
    const extra = r.machineMismatch ? { machineCode: machineCode() } : {};
    return Object.assign({ error: r.error }, extra);
  }
  if (!writeStore({ token: String(token).trim().replace(/\s+/g, ''), activatedAt: Date.now(), issuedBy: String(by || 'admin').slice(0, 60) })) {
    return { error: '授权文件写入失败，请检查数据目录权限' };
  }
  _stateCache = null;   // 立刻重算，别让缓存的一秒把人挡在门外
  return { ok: true, state: publicState() };
}

/** 解绑（仅用于排查/换机器前的准备，不删除试用期记录） */
function deactivate(by) {
  const ok = writeStore({ token: null, activatedAt: null, deactivatedAt: Date.now(), issuedBy: String(by || 'admin').slice(0, 60) });
  _stateCache = null;
  return ok ? { ok: true, state: publicState() } : { error: '写入失败' };
}

// ---------------------------------------------------------------- 门禁

/** 到期也一律放行：登录、看状态、激活、健康检查、客户端冷启动握手 */
const ALLOW = [
  '/api/health',
  '/api/license',
  '/api/auth/login',
  '/api/auth/register',
  '/api/auth/me',
  '/api/auth/password',
  '/api/client/bootstrap',
  // 首次运行向导：授权未激活（或刚过期）时更要能进门设密码，
  // 否则"没授权"和"不知道密码"两件事撞在一起，管理员连门都进不去看原因。
  '/api/setup',
];

function isAllowed(url) {
  const p = String(url || '').split('?')[0].replace(/\/+$/, '') || '/';
  return ALLOW.some((a) => p === a || p.startsWith(a + '/'));
}

/** Express 中间件：挂在 /api 路由之前 */
function gate(req, res, next) {
  const st = state();
  if (st.ok) return next();
  if (isAllowed(req.originalUrl)) return next();
  return res.status(403).json({
    error: st.message || '授权不可用',
    code: 'LICENSE_REQUIRED',
    reason: st.reason || null,
    license: publicState(),
  });
}

// ---------------------------------------------------------------- 到期踢连接

let _wasOk = null;
let _timer = null;

/** 从「可用」翻转为「不可用」的那一刻，把在线连接全部断开：
 *  否则已经连上的人还能继续收发消息，与「业务全停」不符。 */
function watchAndKick() {
  const st = state();
  if (_wasOk === true && !st.ok) {
    let n = 0;
    try {
      const hub = require('./hub');
      for (const set of hub.userSockets.values()) {
        for (const ws of set) {
          try {
            hub.send(ws, { type: 'license', payload: publicState() });
            ws.close(4003, 'license');
            n++;
          } catch { /* ignore */ }
        }
      }
    } catch (e) {
      console.error('[license] 断开连接失败:', e.message);
    }
    console.warn(`[license] 授权已失效（${st.reason}），已断开 ${n} 个在线连接`);
  }
  _wasOk = st.ok;
}

/** 启动：打印一次状态，并起巡检 */
function init() {
  const st = publicState();
  const f = st.fingerprint;
  console.log(`[小智IM] 授权状态: ${st.mode}${st.ok ? '' : '（已停用业务接口）'} / ${st.message}`);
  console.log(`[小智IM] 机器码:   ${st.machineCode}   （指纹来源: ${f.source}）`);
  if (!f.reliable) console.warn(`[小智IM] ⚠ ${f.hint}`);
  if (st.daysLeft !== null && st.daysLeft !== undefined && st.ok) {
    console.log(`[小智IM] 剩余天数: ${st.daysLeft} 天`);
  }
  _wasOk = st.ok;
  if (_timer) clearInterval(_timer);
  _timer = setInterval(watchAndKick, 60 * 1000);
  if (_timer.unref) _timer.unref();
}

module.exports = {
  TRIAL_DAYS,
  init,
  gate,
  state,
  publicState,
  verifyToken,
  activate,
  deactivate,
  machineCode,
  fingerprint,
  LICENSE_FILE,
};
