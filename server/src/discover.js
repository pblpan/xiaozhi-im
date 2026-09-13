/**
 * 局域网发现服务（UDP）
 *
 * 客户端首装时不知道服务器地址，靠 UDP 广播问一句"这里有内网 IM 服务器吗"：
 *   客户端 → 广播 "XIAOZHI_DISCOVER_V1" 到 <broadcast>:3616
 *   服务端 → 回 JSON { app, httpPort, companyName, friendMode, serverVersion }
 *
 * 设计要点：
 * - 只应答不广播：收到探测才回包给来源地址，绝不在网段里喊话。
 * - 回复内容 = bootstrap 免鉴权可取的公开信息（公司名/模式/版本），
 *   不含任何用户数据，符合 SPEC §6.1 的免鉴权硬边界。
 * - 端口被占/绑定失败只记警告不崩：发现服务挂了主服务照常跑，
 *   客户端大不了手填地址（服务器设置里本来就有）。
 */
const dgram = require('dgram');
const os = require('os');
const config = require('./config');
const settings = require('./settings');
const pkg = require('../package.json');

const PROBE = 'XIAOZHI_DISCOVER_V1';
const DISCOVER_PORT = Number(process.env.DISCOVER_PORT || 3616);

let socket = null;

function start() {
  if (socket) return;
  const s = dgram.createSocket({ type: 'udp4', reuseAddr: true });
  s.on('error', (e) => {
    console.warn(`[发现服务] UDP ${DISCOVER_PORT} 不可用：${e.message}（手填地址不受影响）`);
    try { s.close(); } catch { /* 已经关了 */ }
    socket = null;
  });
  s.on('message', (msg, rinfo) => {
    if (msg.toString('utf8').trim() !== PROBE) return; // 不是本协议的探测，装没听见
    const reply = Buffer.from(JSON.stringify({
      app: 'xiaozhi-im',
      httpPort: config.PORT,
      companyName: settings.get('companyName'),
      friendMode: settings.get('friendMode'),
      serverVersion: pkg.version,
      hostname: os.hostname(),
    }), 'utf8');
    // 只回给探测来源 —— 单播应答，不向网段广播
    s.send(reply, rinfo.port, rinfo.address, () => { /* 发完即止 */ });
  });
  s.bind(DISCOVER_PORT, () => {
    socket = s;
    console.log(`[小智IM] 发现服务:   udp://${DISCOVER_PORT}（局域网首装自动找到服务器）`);
  });
}

function stop() {
  if (socket) {
    try { socket.close(); } catch { /* ignore */ }
    socket = null;
  }
}

module.exports = { start, stop, DISCOVER_PORT, PROBE };
