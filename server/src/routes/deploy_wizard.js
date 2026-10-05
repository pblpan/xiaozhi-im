// 管理台「部署向导」—— 把换云服务器的整条链路产品化：
//   ① VPS 一键部署（frps + coturn，SSH 自动执行，日志实时回显）
//   ② frp 隧道接入（飞牛 frpc 切换 + 容器重建）
//   ③ 通话 TURN 中继（turn.env 追加 + 容器重启，与 Cloudflare 并存）
//   ④ 客户端地址候选（前端直接调既有 clientconfig 接口，本文件不负责）
//   完成页健康检查（/health 四项）。
//
// 安全边界（2026-10-05 定）：
//   · 凭据存 DATA_DIR/deploy-creds.json，chmod 600，绝不入库、绝不下发明文。
//   · SSH 只执行本文件内置的白名单脚本常量，接口不接受任意命令。
//   · 所有写操作前后都有断言，失败即停（部署纪律：假成功比失败更危险）。
'use strict';

const express = require('express');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const config = require('../config');
const { verifyToken } = require('../auth');
const { sshExec, tcpProbe, mergeTurnUrls } = require('../deploylib');

const router = express.Router();

// ---------------------------------------------------------------------------
// 凭据存储
// ---------------------------------------------------------------------------

const CREDS_FILE = path.join(config.DATA_DIR, 'deploy-creds.json');

/** 端口默认值（可被 creds.ports 覆盖；都允许自定义 —— 2026-10-05 龙哥需求） */
const DEFAULT_PORTS = { server: 3602, frp: 7000, turn: 3478 };

function normPorts(ports) {
  const p = { ...DEFAULT_PORTS, ...(ports || {}) };
  for (const k of Object.keys(DEFAULT_PORTS)) {
    const v = Number(p[k]);
    p[k] = v >= 1 && v <= 65535 ? v : DEFAULT_PORTS[k];
  }
  return p;
}

function loadCreds() {
  try {
    const j = JSON.parse(fs.readFileSync(CREDS_FILE, 'utf8'));
    return {
      vps: j.vps || null,
      fnos: j.fnos || null,
      frpToken: j.frpToken || '',
      ports: normPorts(j.ports),
    };
  } catch {
    return { vps: null, fnos: null, frpToken: '', ports: { ...DEFAULT_PORTS } };
  }
}

function saveCreds(next) {
  const dir = path.dirname(CREDS_FILE);
  if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
  const data = JSON.stringify(next, null, 2);
  fs.writeFileSync(CREDS_FILE, data, 'utf8');
  try { fs.chmodSync(CREDS_FILE, 0o600); } catch { /* Windows 上无效，线上是 Linux */ }
}

/** 服务端实际监听端口（Win/飞牛通用：env PORT，默认 3602） */
function serverPort() {
  return Number(process.env.PORT || 3602) || 3602;
}

function maskSecret(s) {
  if (!s) return '';
  return s.length <= 4 ? '****' : s.slice(0, 2) + '****' + s.slice(-2);
}

// ---------------------------------------------------------------------------
// 鉴权（与 admin.js 的 adminOf 同款语义：401 = 登录态不成立，403 = 非管理员）
// ---------------------------------------------------------------------------

function adminOf(req, res) {
  const c = verifyToken(req.headers.authorization?.replace('Bearer ', ''));
  if (!c) { res.status(401).json({ error: 'unauthorized' }); return null; }
  const u = require('../db').prepare('SELECT role FROM users WHERE id=?').get(c.uid);
  if (!u) { res.status(401).json({ error: 'unauthorized' }); return null; }
  if (u.role !== 'admin') { res.status(403).json({ error: 'forbidden' }); return null; }
  return c.uid;
}

// ---------------------------------------------------------------------------
// 任务引擎（一次只跑一个部署任务；日志存内存，向导页 1.5s 轮询）
// ---------------------------------------------------------------------------

let task = null;

function newTask(kind, stepDefs) {
  task = {
    kind,
    state: 'running', // running | done | error
    steps: stepDefs.map((s) => ({ key: s.key, label: s.label, state: 'pending' })),
    logs: [],
    error: null,
    startedAt: Date.now(),
    endedAt: null,
    result: {},
  };
  return task;
}

function taskLog(stepKey, line) {
  if (!task) return;
  task.logs.push({ ts: Date.now(), step: stepKey, line: String(line).replace(/\s+$/, '') });
  if (task.logs.length > 800) task.logs.splice(0, task.logs.length - 800); // 防爆内存
  const st = task.steps.find((s) => s.key === stepKey);
  if (st && st.state === 'pending') st.state = 'running';
}

function stepDone(stepKey) {
  const st = task && task.steps.find((s) => s.key === stepKey);
  if (st) st.state = 'done';
}

function stepFail(stepKey, err) {
  const st = task && task.steps.find((s) => s.key === stepKey);
  if (st) st.state = 'fail';
  if (task) {
    task.state = 'error';
    task.error = String(err && err.message || err);
    task.endedAt = Date.now();
  }
  taskLog(stepKey, `❌ ${task ? task.error : err}`);
}

/** 必须成功的执行：非 0 退出码直接把任务打失败并抛出 */
async function must(ctx, stepKey, promise, { timeoutMs, sudo } = {}) {
  const r = await promise;
  if (r.code !== 0) {
    const tail = (r.stdout + '\n' + r.stderr).trim().split('\n').slice(-4).join('\n');
    throw Object.assign(new Error(`命令失败(rc=${r.code}): ${tail}`), { step: stepKey });
  }
  return r;
}

// ---------------------------------------------------------------------------
// 部署脚本常量（白名单 —— 接口不接受任意命令）
// ---------------------------------------------------------------------------

const FRP_VER = '0.61.1';

const TURN_RELAY_PORTS = 'min-port=49160\nmax-port=49200';

// ---------------------------------------------------------------------------
// 路由
// ---------------------------------------------------------------------------

/** 凭据查看（密码只给掩码，前端回显用） */
router.get('/creds', (req, res) => {
  if (!adminOf(req, res)) return;
  const c = loadCreds();
  res.json({
    // 服务端跑在什么系统上决定第 2 步的形态：win32 = 本机模式（无 SSH），
    // 其他（飞牛容器）= SSH 到飞牛宿主。frpc 必须跟服务端同机，不用用户选。
    platform: process.platform,
    serverPort: serverPort(),
    ports: c.ports,
    vps: c.vps ? { host: c.vps.host, port: c.vps.port, user: c.vps.user, hasPassword: !!c.vps.password, passwordMask: maskSecret(c.vps.password) } : null,
    fnos: c.fnos ? { host: c.fnos.host, port: c.fnos.port, user: c.fnos.user, hasPassword: !!c.fnos.password, passwordMask: maskSecret(c.fnos.password) } : null,
    hasFrpToken: !!c.frpToken,
  });
});

/** 凭据保存（vps / fnos / ports 可分开提交；留空 password 表示沿用已存的） */
router.post('/creds', (req, res) => {
  if (!adminOf(req, res)) return;
  const { vps, fnos, ports } = req.body || {};
  const cur = loadCreds();
  if (ports) cur.ports = normPorts(ports);
  const norm = (x) => x && ({
    host: String(x.host || '').trim(),
    port: Number(x.port || 22),
    user: String(x.user || '').trim(),
    password: String(x.password || ''),
  });
  if (vps) {
    const n = norm(vps);
    if (!n.host || !n.user) return res.status(400).json({ error: 'VPS 缺 host/user' });
    if (!n.password && cur.vps) n.password = cur.vps.password; // 沿用
    if (!n.password) return res.status(400).json({ error: 'VPS 缺密码' });
    cur.vps = n;
  }
  if (fnos) {
    const n = norm(fnos);
    if (!n.host || !n.user) return res.status(400).json({ error: '飞牛缺 host/user' });
    if (!n.password && cur.fnos) n.password = cur.fnos.password;
    if (!n.password) return res.status(400).json({ error: '飞牛缺密码' });
    cur.fnos = n;
  }
  if (!cur.frpToken) cur.frpToken = crypto.randomBytes(16).toString('hex');
  saveCreds(cur);
  res.json({ ok: true });
});

/** SSH 连接测试（vps 或 fnos） */
router.post('/test', async (req, res) => {
  if (!adminOf(req, res)) return;
  const which = req.body && req.body.which;
  const c = loadCreds();
  const conn = which === 'fnos' ? c.fnos : c.vps;
  if (!conn) return res.status(400).json({ error: `${which} 凭据未保存` });
  const t0 = Date.now();
  try {
    const r = await sshExec(conn, 'echo ok', { timeoutMs: 25000, sudoPassword: which === 'fnos' ? conn.password : '' });
    if (!/ok/.test(r.stdout)) throw new Error('连接成功但回显异常');
    res.json({ ok: true, ms: Date.now() - t0 });
  } catch (e) {
    res.status(502).json({ ok: false, error: e.message });
  }
});

/** ① VPS 一键部署（frps + coturn）。后台任务，前端轮询 /status */
router.post('/vps-deploy', (req, res) => {
  if (!adminOf(req, res)) return;
  if (task && task.state === 'running') {
    return res.status(409).json({ error: '已有部署任务在跑', kind: task.kind });
  }
  const creds = loadCreds();
  if (!creds.vps) return res.status(400).json({ error: '请先保存 VPS 凭据' });
  if (!creds.frpToken) { creds.frpToken = crypto.randomBytes(16).toString('hex'); saveCreds(creds); }

  // 通话中继要用的账号对：优先服务端已配的 TURN 账号；没有就现生成
  const turnEnv = config.readTurnEnv();
  const turnUser = turnEnv.TURN_USERNAME || 'xiaozhi';
  const turnCred = turnEnv.TURN_CREDENTIAL || crypto.randomBytes(24).toString('hex');

  newTask('vps', [
    { key: 'conn', label: 'SSH 连接' },
    { key: 'apt', label: '系统准备' },
    { key: 'frps', label: '安装 frps' },
    { key: 'frpsconf', label: 'frps 配置' },
    { key: 'frpsrun', label: 'frps 启动' },
    { key: 'coturn', label: '安装 coturn' },
    { key: 'turnconf', label: 'TURN 配置' },
    { key: 'turnrun', label: 'TURN 启动与自测' },
  ]);

  const c = creds.vps;
  const ports = creds.ports;
  (async () => {
    const S = 'conn';
    taskLog(S, `连接 ${c.user}@${c.host}:${c.port || 22} ...`);
    await must({ task }, S, sshExec(c, 'echo ok && uname -m', { timeoutMs: 30000 }));
    const arch = /aarch64/i.test(task.logs[task.logs.length - 1].line) ? 'arm64' : 'amd64';
    taskLog(S, `✅ 连接成功（架构 ${arch}）`);
    stepDone(S);

    // ---- 系统准备 ----
    const S2 = 'apt';
    taskLog(S2, 'apt-get update ...');
    await must(task, S2, sshExec(c, 'apt-get update -qq 2>&1 | tail -1; echo APT_DONE', { timeoutMs: 240000 }));
    taskLog(S2, '✅ 包索引就绪');
    stepDone(S2);

    // ---- frps 安装（GitHub 直连二进制）----
    const S3 = 'frps';
    taskLog(S3, `下载 frp ${FRP_VER} linux/${arch}（GitHub 直连）...`);
    const dl = await sshExec(c,
      `curl -fsSL --connect-timeout 15 -o /tmp/frp.tgz https://github.com/fatedier/frp/releases/download/v${FRP_VER}/frp_${FRP_VER}_linux_${arch}.tar.gz && echo DL_OK`,
      { timeoutMs: 300000 });
    if (!/DL_OK/.test(dl.stdout)) {
      throw Object.assign(new Error('GitHub 下载失败 —— 商业机房不该出现，请检查服务器网络'), { step: S3 });
    }
    await must(task, S3, sshExec(c,
      `tar xzf /tmp/frp.tgz -C /tmp && install -m 755 /tmp/frp_${FRP_VER}_linux_${arch}/frps /usr/local/bin/frps && /usr/local/bin/frps --version`,
      { timeoutMs: 60000 }));
    taskLog(S3, '✅ frps 已安装');
    stepDone(S3);

    // ---- frps 配置（frp 端口可自定义，默认 7000）----
    const S4 = 'frpsconf';
    await must(task, S4, sshExec(c,
      `mkdir -p /etc/frp && printf 'bindPort = %s\\nauth.token = "%s"\\n' '${ports.frp}' '${creds.frpToken}' > /etc/frp/frps.toml && chmod 600 /etc/frp/frps.toml`,
      { timeoutMs: 30000 }));
    taskLog(S4, `✅ /etc/frp/frps.toml 已写入（bindPort=${ports.frp}，token 自动生成并保存）`);
    stepDone(S4);

    // ---- frps 启动 ----
    const S5 = 'frpsrun';
    await must(task, S5, sshExec(c,
      `cat > /etc/systemd/system/frps.service <<'EOF'\n[Unit]\nDescription=frp server (xiaozhi relay)\nAfter=network.target\n[Service]\nExecStart=/usr/local/bin/frps -c /etc/frp/frps.toml\nRestart=always\nRestartSec=5\n[Install]\nWantedBy=multi-user.target\nEOF\nsystemctl daemon-reload && systemctl enable --now frps`,
      { timeoutMs: 60000 }));
    let up = false;
    for (let i = 0; i < 15; i++) {
      const r = await sshExec(c, `ss -tln | grep -q ':${ports.frp} ' && echo LISTEN_OK || echo NO`, { timeoutMs: 20000 });
      if (/LISTEN_OK/.test(r.stdout)) { up = true; break; }
      await new Promise((r2) => setTimeout(r2, 1000));
    }
    if (!up) throw Object.assign(new Error(`15 秒内 ${ports.frp} 未监听`), { step: S5 });
    taskLog(S5, `✅ frps 常驻运行，${ports.frp} 监听中`);
    stepDone(S5);

    // ---- coturn 安装 ----
    const S6 = 'coturn';
    taskLog(S6, 'apt-get install coturn ...');
    await must(task, S6, sshExec(c, 'apt-get install -y -qq coturn >/dev/null 2>&1; which turnserver', { timeoutMs: 300000 }));
    taskLog(S6, '✅ coturn 已安装');
    stepDone(S6);

    // ---- TURN 配置（凭据与飞牛 turn.env 对齐；TURN 端口可自定义，默认 3478）----
    const S7 = 'turnconf';
    const conf = [
      `listening-port=${ports.turn}`,
      `listening-ip=${c.host}`,
      `relay-ip=${c.host}`,
      `external-ip=${c.host}`,
      TURN_RELAY_PORTS,
      `user=${turnUser}:${turnCred}`,
      'realm=xiaozhi-im',
      'no-cli', 'no-tls', 'no-dtls', 'simple-log',
    ].join('\n');
    await must(task, S7, sshExec(c,
      `cat > /etc/turnserver.conf <<'TEOF'\n${conf}\nTEOF\nsed -i 's/^TURNSERVER_ENABLED=.*/TURNSERVER_ENABLED=1/' /etc/default/coturn 2>/dev/null; grep -q '^TURNSERVER_ENABLED=1' /etc/default/coturn 2>/dev/null || echo TURNSERVER_ENABLED=1 >> /etc/default/coturn`,
      { timeoutMs: 30000 }));
    taskLog(S7, `✅ /etc/turnserver.conf 已写入（账号 ${turnUser}，与服务端下发自动对齐）`);
    stepDone(S7);

    // ---- TURN 启动 + 自测 ----
    const S8 = 'turnrun';
    await must(task, S8, sshExec(c, 'systemctl enable --now coturn >/dev/null 2>&1; systemctl restart coturn', { timeoutMs: 60000 }));
    let turnUp = false;
    for (let i = 0; i < 12; i++) {
      const r = await sshExec(c, `ss -uln | grep -q ':${ports.turn} ' && echo OK || echo NO`, { timeoutMs: 20000 });
      if (/OK/.test(r.stdout)) { turnUp = true; break; }
      await new Promise((r2) => setTimeout(r2, 1000));
    }
    if (!turnUp) throw Object.assign(new Error(`${ports.turn} 未监听`), { step: S8 });
    const self = await sshExec(c,
      `turnutils_uclient -y -u ${turnUser} -w ${turnCred} -p ${ports.turn} ${c.host} 2>&1 | tail -3`,
      { timeoutMs: 120000 });
    taskLog(S8, '中继分配自测：\n' + self.stdout.trim());
    if (/Total lost packets 0 \(/.test(self.stdout) || /tot_recv_msgs/.test(self.stdout)) {
      taskLog(S8, '✅ 中继分配可用');
    } else {
      throw Object.assign(new Error('中继自测未通过，已中止（避免把坏中继下发出去）'), { step: S8 });
    }
    stepDone(S8);

    task.state = 'done';
    task.endedAt = Date.now();
    task.result = { host: c.host, frpToken: creds.frpToken };
  })().catch((e) => stepFail(e.step || 'conn', e));

  res.json({ ok: true, started: true });
});

/** ② 隧道接入。形态自动判定：frpc 必须跟服务端同机 ——
 *   · win32（Win 服务端）= 本机模式：写数据目录 frpc\frpc.toml + 自动下 frpc.exe
 *     + 启动文件夹自启，全程 child_process，无 SSH。
 *   · 其他（飞牛容器）= SSH 到飞牛宿主改 /vol1/system/frpc 并重建容器。 */
router.post('/tunnel', (req, res) => {
  if (!adminOf(req, res)) return;
  if (task && task.state === 'running') {
    return res.status(409).json({ error: '已有部署任务在跑', kind: task.kind });
  }
  const creds = loadCreds();
  if (!creds.vps) return res.status(400).json({ error: '请先完成第 1 步（VPS 部署）' });
  const ports = creds.ports;
  const winMode = process.platform === 'win32';

  if (winMode) {
    // ---------------- Windows 本机模式 ----------------
    newTask('tunnel', [
      { key: 'conf', label: '生成 frpc.toml' },
      { key: 'exe', label: 'frpc.exe 就位' },
      { key: 'autostart', label: '开机自启' },
      { key: 'run', label: '启动并验证' },
    ]);
    const os = require('os');
    const dataDir = config.DATA_DIR;
    const frpcDir = path.join(dataDir, 'frpc');
    const tomlPath = path.join(frpcDir, 'frpc.toml');
    const exePath = path.join(frpcDir, 'frpc.exe');
    const logPath = path.join(frpcDir, 'frpc.log');
    const vpsHost = creds.vps.host;

    (async () => {
      const { execFile } = require('child_process');
      const ex = (cmd, args, opts = {}) => new Promise((resolve, reject) => {
        execFile(cmd, args, { windowsHide: true, timeout: opts.timeout || 120000, ...opts }, (err, stdout, stderr) => {
          if (err) return reject(Object.assign(err, { stderr }));
          resolve({ stdout: String(stdout), stderr: String(stderr) });
        });
      });
      const httpGet = (url, dest) => new Promise((resolve, reject) => {
        const fs2 = require('fs');
        const get = (u, redirs) => {
          if (redirs > 5) return reject(new Error('重定向过多'));
          require('https').get(u, (r) => {
            if (r.statusCode >= 300 && r.statusCode < 400 && r.headers.location) {
              r.resume();
              return get(r.headers.location, redirs + 1);
            }
            if (r.statusCode !== 200) return reject(new Error(`下载失败 HTTP ${r.statusCode}`));
            const f = fs2.createWriteStream(dest);
            r.pipe(f);
            f.on('finish', () => f.close(resolve));
            f.on('error', reject);
          }).on('error', reject);
        };
        get(url, 0);
      });

      fs.mkdirSync(frpcDir, { recursive: true });
      // 1. frpc.toml：Win 服务端只有小智一个服务，代理就一条（别的服务在别的机器上）
      const confObj = {
        serverAddr: vpsHost,
        serverPort: ports.frp,
        auth: { token: creds.frpToken },
        log: { to: logPath, level: 'info', maxDays: 3 },
        proxies: [
          { name: 'xiaozhi', type: 'tcp', localIP: '127.0.0.1', localPort: serverPort(), remotePort: ports.server },
        ],
      };
      fs.writeFileSync(tomlPath, JSON.stringify(confObj, null, 2), 'utf8');
      taskLog('conf', `✅ ${tomlPath}`);
      taskLog('conf', `    serverAddr=${vpsHost}:${ports.frp}  本机服务 ${serverPort()} → 公网 ${ports.server}`);
      stepDone('conf');

      // 2. frpc.exe：有就跳过，没有从 GitHub 下载 zip 后解包
      if (fs.existsSync(exePath)) {
        taskLog('exe', '✅ frpc.exe 已存在，跳过下载');
      } else {
        taskLog('exe', '从 GitHub 下载 frpc（windows-amd64）...');
        const zip = path.join(frpcDir, 'frp.zip');
        await httpGet(`https://github.com/fatedier/frp/releases/download/v${FRP_VER}/frp_${FRP_VER}_windows_amd64.zip`, zip);
        taskLog('exe', '下载完成，解压中...');
        await ex('powershell', ['-NoProfile', '-Command',
          `Expand-Archive -Force -Path '${zip}' -DestinationPath '${frpcDir}\\_pkg'`], { timeout: 300000 });
        const inner = path.join(frpcDir, '_pkg', `frp_${FRP_VER}_windows_amd64`, 'frpc.exe');
        if (!fs.existsSync(inner)) throw new Error('解压后没找到 frpc.exe');
        fs.renameSync(inner, exePath);
        fs.rmSync(path.join(frpcDir, '_pkg'), { recursive: true, force: true });
        fs.rmSync(zip, { force: true });
        taskLog('exe', '✅ frpc.exe 就位');
      }
      stepDone('exe');

      // 3. 开机自启：写进当前用户的「启动」文件夹（无需管理员权限）
      taskLog('autostart', '注册开机自启（用户启动文件夹）...');
      const startup = path.join(os.homedir(), 'AppData', 'Roaming',
        'Microsoft', 'Windows', 'Start Menu', 'Programs', 'Startup');
      fs.mkdirSync(startup, { recursive: true });
      const bat = [
        '@echo off',
        `start "" "${exePath}" -c "${tomlPath}"`,
      ].join('\r\n');
      fs.writeFileSync(path.join(startup, '小智IM隧道.cmd'), bat, 'utf8');
      taskLog('autostart', `✅ ${path.join(startup, '小智IM隧道.cmd')}`);
      stepDone('autostart');

      // 4. 启动 frpc 并读日志验证（先杀旧的，避免双实例抢端口）
      taskLog('run', '启动 frpc ...');
      await ex('taskkill', ['/F', '/IM', 'frpc.exe']).catch(() => {});
      const { spawn } = require('child_process');
      const child = spawn(exePath, ['-c', tomlPath], { windowsHide: true, detached: false, stdio: 'ignore' });
      child.unref();
      let okLogin = false;
      for (let i = 0; i < 15; i++) {
        await new Promise((r) => setTimeout(r, 1000));
        try {
          if (/login to server success/.test(fs.readFileSync(logPath, 'utf8'))) { okLogin = true; break; }
        } catch { /* 日志还没写出来 */ }
      }
      if (!okLogin) throw Object.assign(new Error('frpc 15 秒内未登录成功（看 frpc.log）'), { step: 'run' });
      taskLog('run', '✅ login to server success（日志：' + logPath + '）');
      stepDone('run');

      task.state = 'done';
      task.endedAt = Date.now();
    })().catch((e) => stepFail(e.step || 'conf', e));

    return res.json({ ok: true, started: true, mode: 'win' });
  }

  // ---------------- 飞牛 SSH 模式（原有） ----------------
  if (!creds.fnos) return res.status(400).json({ error: '请先保存飞牛 SSH 凭据' });

  newTask('tunnel', [
    { key: 'conn', label: '连接飞牛' },
    { key: 'conf', label: 'frpc 配置切换' },
    { key: 'run', label: '重建 frpc 容器' },
    { key: 'verify', label: '注册验证' },
  ]);

  const f = { ...creds.fnos };
  if (!f.host) throw new Error('未填写飞牛的局域网地址（形如 192.168.1.10）');
  const vpsHost = creds.vps.host;

  (async () => {
    const sudo = (cmd) => sshExec(f, cmd, { timeoutMs: 180000, sudoPassword: f.password });

    taskLog('conn', `连接飞牛 ${f.user}@${f.host} ...`);
    await must(task, 'conn', sshExec(f, 'echo ok', { timeoutMs: 30000, sudoPassword: f.password }));
    taskLog('conn', '✅ 已连接');
    stepDone('conn');

    // 读旧配置 → 备份 → 写新配置（JSON；0.61.x 先试 JSON 解析）
    taskLog('conf', '读取现有 /vol1/system/frpc/frpc.toml ...');
    const old = await must(task, 'conf', sudo('cat /vol1/system/frpc/frpc.toml 2>/dev/null || echo __NOFILE__'));
    if (!/__NOFILE__/.test(old.stdout)) {
      await must(task, 'conf', sudo(`cp /vol1/system/frpc/frpc.toml /vol1/system/frpc/frpc.toml.bak-$(date +%m%d%H%M)`));
      taskLog('conf', '旧配置已备份（frpc.toml.bak-*）');
    }
    // 代理列表：沿用旧配置里的 proxies（localPort/remotePort 原样保留 ——
    // 那是各服务在自己机器上的端口，不该被向导猜）；只有小智这条随服务端口走
    let proxies = [
      { name: 'factory', type: 'tcp', localIP: '127.0.0.1', localPort: 3601, remotePort: 3601 },
      { name: 'xiaozhi', type: 'tcp', localIP: '127.0.0.1', localPort: serverPort(), remotePort: ports.server },
      { name: 'netops', type: 'tcp', localIP: '127.0.0.1', localPort: 5000, remotePort: 5000 },
    ];
    const m = old.stdout.match(/"proxies"\s*:\s*(\[[\s\S]*?\])\s*\}/);
    if (m) {
      try {
        const oldList = JSON.parse(m[1]);
        for (const p of oldList) {
          if (p.name === 'xiaozhi') continue; // 小智这条用新端口
          proxies.push(p); // 其余（factory/netops 等）原样保留
        }
      } catch { /* 用默认 */ }
    }
    const newConf = JSON.stringify({
      serverAddr: vpsHost,
      serverPort: ports.frp,
      auth: { token: creds.frpToken },
      proxies,
    });
    const b64 = Buffer.from(newConf, 'utf8').toString('base64');
    await must(task, 'conf', sudo(
      `mkdir -p /vol1/system/frpc && echo ${b64} | base64 -d > /vol1/system/frpc/frpc.toml && grep -q '${vpsHost}' /vol1/system/frpc/frpc.toml`));
    taskLog('conf', `✅ frpc.toml 已指向 ${vpsHost}:${ports.frp}（${proxies.length} 个代理）`);
    stepDone('conf');

    // 重建容器（rm 与 run 都要 root —— 整体包 bash -c）
    taskLog('run', '拉起 frpc 容器（host 网络 · 开机自启）...');
    await must(task, 'run', sudo(
      `docker rm -f frpc 2>/dev/null; docker run -d --name frpc --network host --restart unless-stopped ` +
      `-v /vol1/system/frpc/frpc.toml:/frp/frpc.toml:ro stilleshan/frpc:0.61.1`));
    taskLog('run', '✅ 容器已启动');
    stepDone('run');

    // 注册验证（最多等 20 秒）
    let okLogin = false, okProxy = false, logsOut = '';
    for (let i = 0; i < 10; i++) {
      await new Promise((r) => setTimeout(r, 2000));
      const r = await must(task, 'verify', sudo('docker logs --tail 40 frpc 2>&1'));
      logsOut = r.stdout;
      okLogin = /login to server success/.test(logsOut);
      okProxy = (logsOut.match(/start proxy success/g) || []).length >= 1;
      if (okLogin && okProxy) break;
    }
    taskLog('verify', logsOut.split('\n').filter((l) => /login|proxy/.test(l)).join('\n'));
    if (!okLogin || !okProxy) throw Object.assign(new Error(`frpc 未注册成功（login=${okLogin}, proxy=${okProxy}）`), { step: 'verify' });
    taskLog('verify', '✅ login success + 代理全部注册');
    stepDone('verify');

    task.state = 'done';
    task.endedAt = Date.now();
  })().catch((e) => stepFail(e.step || 'conn', e));

  res.json({ ok: true, started: true, mode: 'fnos' });
});

/** ③ TURN 中继：进程内追加 turn.env（不需要 SSH），返回合并结果 */
router.post('/turn', (req, res) => {
  if (!adminOf(req, res)) return;
  const creds = loadCreds();
  if (!creds.vps) return res.status(400).json({ error: '请先完成第 1 步（VPS 部署）' });
  const env = config.readTurnEnv();
  if (!env.TURN_USERNAME || !env.TURN_CREDENTIAL) {
    return res.status(400).json({ error: '服务端还没有 TURN 账号（TURN_USERNAME/CREDENTIAL 为空），请先在 VPS 部署或手工配置' });
  }
  const merged = mergeTurnUrls(env.TURN_URLS || '', [
    `turn:${creds.vps.host}:${creds.ports.turn}?transport=udp`,
    `turn:${creds.vps.host}:${creds.ports.turn}?transport=tcp`,
  ]);
  config.writeTurnEnv({ TURN_URLS: merged });
  res.json({
    ok: true,
    turnUrls: merged.split(','),
    platform: process.platform,
    note: process.platform === 'win32'
      ? 'turn.env 已更新。Windows 服务端请用「停止服务端.cmd」+「后台启动服务端.vbs」重启后生效。'
      : 'turn.env 已更新。需要重启服务端容器生效 —— 向导会自动执行并等待恢复。',
  });
});

/** ③b 重启服务端容器（仅飞牛形态 —— Win 形态没有守护进程，前端提示手动重启）
 *      会让本进程短暂失联 —— 前端轮询 /api/health 等恢复 */
router.post('/restart-self', async (req, res) => {
  if (!adminOf(req, res)) return;
  if (process.platform === 'win32') {
    return res.status(400).json({ error: 'Windows 服务端请手动重启（停止服务端.cmd → 后台启动服务端.vbs）' });
  }
  const creds = loadCreds();
  if (!creds.fnos) return res.status(400).json({ error: '请先保存飞牛 SSH 凭据' });
  const f = { ...creds.fnos };
  res.json({ ok: true, note: '重启中，约 10-20 秒后恢复' });
  // 给响应留出送达时间再动手（res.json 已 flush，这里只是稳妥）
  setTimeout(() => {
    sshExec(f, 'cd /vol1/@appcenter/xiaozhi-im/docker && docker restart xiaozhi-im',
      { timeoutMs: 120000, sudoPassword: f.password }).catch(() => {});
  }, 800);
});

/** ③c 重启恢复后的验证：iceServers 里必须包含 VPS 中继 */
router.get('/verify-ice', async (req, res) => {
  if (!adminOf(req, res)) return;
  const creds = loadCreds();
  const list = await config.iceServers();
  const want = creds.vps ? `turn:${creds.vps.host}:${creds.ports.turn}` : null;
  const blob = JSON.stringify(list);
  res.json({
    ok: !!want && blob.includes(want),
    hasCloudflare: /cloudflare/.test(blob),
    hasVps: !!want && blob.includes(want),
    iceServers: list,
  });
});

/** 任务状态（前端 1.5s 轮询） */
router.get('/status', (req, res) => {
  if (!adminOf(req, res)) return;
  res.json(task || { kind: null, state: 'idle', steps: [], logs: [] });
});

/** 健康检查（完成页/随时可看）：能快的先并行，SSH/本机慢的兜底 */
router.get('/health', async (req, res) => {
  if (!adminOf(req, res)) return;
  const creds = loadCreds();
  const ports = creds.ports;
  const winMode = process.platform === 'win32';
  const out = [];
  if (creds.vps) {
    const [pFrp, pTurn] = await Promise.all([
      tcpProbe(creds.vps.host, ports.frp),
      tcpProbe(creds.vps.host, ports.turn),
    ]);
    out.push({ key: 'frps', label: `frps ${ports.frp}（${creds.vps.host}）`, ok: pFrp });
    out.push({ key: 'turn', label: `TURN ${ports.turn}（udp/tcp 入口）`, ok: pTurn });
  } else {
    out.push({ key: 'frps', label: 'frps', ok: false, detail: 'VPS 凭据未配置' });
    out.push({ key: 'turn', label: 'TURN', ok: false, detail: 'VPS 凭据未配置' });
  }
  let ice = null;
  try {
    const list = await config.iceServers();
    const blob = JSON.stringify(list);
    const hasVps = creds.vps && blob.includes(`turn:${creds.vps.host}:${ports.turn}`);
    const hasCf = /cloudflare/.test(blob);
    ice = { hasVps, hasCf };
    out.push({ key: 'ice', label: 'iceServers 下发', ok: !!(hasVps || hasCf), detail: `${hasVps ? 'VPS ' : ''}${hasCf ? 'Cloudflare' : ''}`.trim() || '均未配置' });
  } catch (e) {
    out.push({ key: 'ice', label: 'iceServers 下发', ok: false, detail: e.message });
  }
  // frpc 状态：Win = 本机进程；飞牛 = SSH docker ps（慢，放最后，失败不算整体失败）
  if (winMode) {
    const frpcLog = path.join(config.DATA_DIR, 'frpc', 'frpc.log');
    let ok = false, detail = '未配置（先跑第 2 步）';
    try {
      const txt = fs.readFileSync(frpcLog, 'utf8');
      ok = /login to server success/.test(txt);
      detail = ok ? 'frpc 已登录中继' : '日志存在但未见登录成功';
    } catch { /* 没跑过第 2 步 */ }
    out.push({ key: 'frpc', label: 'frpc 隧道（本机）', ok, detail });
  } else if (creds.fnos) {
    try {
      const r = await sshExec(creds.fnos,
        'docker ps --filter name=frpc --format "{{.Names}} {{.Status}}"',
        { timeoutMs: 30000, sudoPassword: creds.fnos.password });
      const running = /frpc\s+Up/.test(r.stdout);
      out.push({ key: 'frpc', label: 'frpc 容器', ok: running, detail: r.stdout.trim() || '未运行' });
    } catch (e) {
      out.push({ key: 'frpc', label: 'frpc 容器', ok: false, detail: 'SSH 失败: ' + e.message });
    }
  }
  res.json({ items: out, allOk: out.every((x) => x.ok) });
});

/** 清除凭据（管理台可随时删） */
router.delete('/creds', (req, res) => {
  if (!adminOf(req, res)) return;
  try { fs.unlinkSync(CREDS_FILE); } catch { /* 不存在就算了 */ }
  res.json({ ok: true });
});

module.exports = router;
