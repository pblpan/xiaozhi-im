// 部署向导的 SSH 执行层 —— 管理台「部署向导」专用（admin 触发，白名单脚本）。
//
// 为什么自己封装而不用现成 CLI：
//   · 服务端容器里没有 ssh 客户端，也没有 sshpass；ssh2 是纯 JS，装进
//     node_modules 就能用，不依赖系统二进制。
//   · 部署向导要「点按钮 → 实时看日志」，需要逐条 exec 并把输出流回任务日志。
//
// ⚠️ 纪律（2026-10-05 手工部署踩过的三个坑，全部固化在这里）：
//   1. 每条特权命令都自带 `sudo -S` 喂密码 —— sudo 凭据缓存跨 SSH exec 会话不可靠。
//   2. 要传数据流的命令用 `sudo -S bash -c '<内部处理>'`，密码和数据流分开。
//   3. 多条特权命令整体包进 `sudo -S bash -c '...'`，别写 `sudo cmd1; cmd2`。
'use strict';

const { Client } = require('ssh2');

/** 单引号 shell 转义（等价 python shlex.quote） */
function shQuote(s) {
  return "'" + String(s).replace(/'/g, "'\\''") + "'";
}

/** 飞牛这类 sudo 用户跑特权命令：密码经 stdin 喂给 sudo -S，命令整体进 sh -c */
function sudoCmd(password, cmd) {
  return `echo ${shQuote(password)} | sudo -S sh -c ${shQuote(cmd)} 2>&1`;
}

/**
 * 执行一条远程命令，收齐输出。
 * @returns {Promise<{code:number, stdout:string, stderr:string}>}
 */
function sshExec(connOpts, cmd, { timeoutMs = 120000, sudoPassword = '' } = {}) {
  const full = sudoPassword ? sudoCmd(sudoPassword, cmd) : cmd;
  return new Promise((resolve, reject) => {
    const conn = new Client();
    const timer = setTimeout(() => {
      try { conn.end(); } catch { /* ignore */ }
      reject(new Error(`SSH 命令超时(${Math.round(timeoutMs / 1000)}s): ${cmd.slice(0, 80)}`));
    }, timeoutMs);
    conn.on('error', (e) => { clearTimeout(timer); reject(e); });
    conn.on('ready', () => {
      conn.exec(full, { pty: false }, (err, stream) => {
        if (err) { clearTimeout(timer); conn.end(); return reject(err); }
        let stdout = '';
        let stderr = '';
        stream.on('close', (code) => {
          clearTimeout(timer);
          conn.end();
          resolve({ code: code || 0, stdout, stderr });
        });
        stream.on('data', (d) => { stdout += d.toString(); });
        stream.stderr.on('data', (d) => { stderr += d.toString(); });
      });
    });
    conn.connect({
      host: connOpts.host,
      port: Number(connOpts.port || 22),
      username: connOpts.user,
      password: connOpts.password,
      readyTimeout: 20000,
      tryKeyboard: false,
    });
  });
}

/** 并发 TCP 探测（公网端口健康检查用），2.5s 超时 */
function tcpProbe(host, port, timeoutMs = 2500) {
  return new Promise((resolve) => {
    const net = require('net');
    const s = net.createConnection({ host, port: Number(port) });
    const done = (ok) => { try { s.destroy(); } catch { /* ignore */ } resolve(ok); };
    s.setTimeout(timeoutMs, () => done(false));
    s.on('connect', () => done(true));
    s.on('error', () => done(false));
  });
}

/** TURN_URLS 合并去重（保持原顺序，新的追加在尾部） */
function mergeTurnUrls(existing, adds) {
  const list = (existing || '')
    .split(',').map((s) => s.trim()).filter(Boolean);
  for (const u of adds || []) {
    if (!list.includes(u)) list.push(u);
  }
  return list.join(',');
}

module.exports = { sshExec, sudoCmd, shQuote, tcpProbe, mergeTurnUrls };
