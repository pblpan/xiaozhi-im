#!/usr/bin/env node
// 把管理台「上游接口」里的**本机地址**同步成当前 IP。
//
//   node deploy/sync_upstream_host.js            # 检测并自动修正
//   node deploy/sync_upstream_host.js --check    # 只看，不改
//
// 为什么必须有这个工具：
//   上游登记里的 baseUrl 写的是"这台 PC 的局域网 IP"，而 PC 走 DHCP。
//   实测 2026-09-18 本机就从 192.168.31.138 变成了 192.168.31.98 ——
//   表现是客户端「门店日报」点开一片空（服务端返回 502 连不上上游），
//   而此刻**服务端、隧道、数据库、端点进程全都是好的**，唯一的坏点是那个 IP。
//   这类"环境漂移"每次人工排查都要花很久，所以做成一条命令。
//
// 安全边界（别误伤别的上游）：
//   只动 **baseUrl 端口等于 `--port`（默认 3670，即本机取数端点的专用端口）** 的那几条。
//   指向别的机器/别的端口的上游一律不碰 —— 脚本没有能力判断"那台机器该不该改"。

const fs = require('fs');
const os = require('os');

const NAS = process.argv.includes('--nas')
  ? process.argv[process.argv.indexOf('--nas') + 1]
  : '192.168.31.44:3602';
const PORT = process.argv.includes('--port')
  ? Number(process.argv[process.argv.indexOf('--port') + 1])
  : 3670;
const CHECK_ONLY = process.argv.includes('--check');
const BASE = 'http://' + NAS;
const PW_FILE = 'D:\\Users\\pblpa\\Desktop\\小智 IM\\小智管理台新密码-请勿外传.txt';

/** 本机所有非回环 IPv4 */
function localIPv4() {
  const out = [];
  for (const list of Object.values(os.networkInterfaces())) {
    for (const it of list || []) {
      if (it.family === 'IPv4' && !it.internal) out.push(it.address);
    }
  }
  return out;
}

/** 挑出与 NAS 同网段的那个（更可能被容器访问到） */
function pickLanIp(ips) {
  const nasNet = NAS.split('.')[0] + '.' + NAS.split('.')[1] + '.';
  return ips.find((i) => i.startsWith(nasNet)) || ips[0] || null;
}

/** 上游列表接口回的是 `{upstreams:[...]}`（不是裸数组）—— 三种形状都认，省得下次改接口又挂 */
function pickList(body) {
  if (Array.isArray(body)) return body;
  return body?.upstreams || body?.list || body?.items || [];
}

async function api(method, p, token, body) {
  const res = await fetch(BASE + p, {
    method,
    headers: {
      'Content-Type': 'application/json',
      ...(token ? { Authorization: 'Bearer ' + token } : {}),
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  let json = null;
  try { json = await res.json(); } catch { /* 可能无 body */ }
  return { status: res.status, body: json };
}

(async () => {
  const ips = localIPv4();
  const mine = pickLanIp(ips);
  console.log('[上游主机同步] NAS=' + NAS + '  仅动端口 ' + PORT + ' 的上游' + (CHECK_ONLY ? '  (只检查)' : ''));
  console.log('  本机地址: ' + ips.join(', ') + '   采用: ' + mine);
  if (!mine) { console.error('  找不到可用本机 IPv4'); process.exit(1); }

  const pw = fs.readFileSync(PW_FILE, 'utf8').match(/^新密码\s*[:：]\s*(\S+)\s*$/m)[1];
  const lg = await api('POST', '/api/auth/login', null, { username: 'admin', password: pw });
  if (!lg.body?.token) { console.error('  登录失败: ' + JSON.stringify(lg.body)); process.exit(1); }
  const tok = lg.body.token;

  const list = await api('GET', '/api/admin/upstreams', tok);
  const items = pickList(list.body);
  if (!items.length) { console.log('  上游接口列表为空（或返回结构不认识）: ' + String(JSON.stringify(list.body)).slice(0, 160)); }

  let changed = 0, same = 0, skipped = 0;
  for (const u of items) {
    const name = u.name;
    const url = String(u.baseUrl || '');
    let host = '', port = 80;
    try { const p = new URL(url); host = p.hostname; port = Number(p.port || 80); } catch { /* 非法地址跳过 */ }
    if (!host) { console.log(`  [跳过] ${name}: 地址无法解析 (${url})`); skipped++; continue; }

    if (port !== PORT) {
      console.log(`  [不碰] ${name}: 端口 ${port} ≠ ${PORT}（不是本机端点）`);
      skipped++;
      continue;
    }
    if (host === mine) {
      console.log(`  [已对] ${name}: ${host}:${port}`);
      same++;
      continue;
    }

    const newUrl = url.replace(host, mine);
    if (CHECK_ONLY) {
      console.log(`  [需改] ${name}: ${host} -> ${mine}  (${newUrl})`);
      changed++;
      continue;
    }

    // 走 POST 的部分更新语义：只提交 name + baseUrl，凭据/白名单等保持原样
    const r = await api('POST', '/api/admin/upstreams', tok, { name, baseUrl: newUrl });
    if (r.status === 200) {
      // 回读确认真的落库了（接口返回 200 不等于写进去了）
      const after = await api('GET', '/api/admin/upstreams', tok);
      const got = pickList(after.body).find((x) => x.name === name);
      const okNow = got && String(got.baseUrl).includes(mine);
      console.log(`  [${okNow ? '已改' : '失败'}] ${name}: ${host} -> ${mine}` + (okNow ? '' : '  回读=' + String(got?.baseUrl)));
      if (okNow) changed++; else process.exitCode = 1;
    } else {
      console.log(`  [失败] ${name}: HTTP ${r.status} ${String(JSON.stringify(r.body)).slice(0, 140)}`);
      process.exitCode = 1;
    }
  }

  console.log(`\n  合计: 需改 ${changed} / 已对 ${same} / 不碰或跳过 ${skipped}`);
  if (CHECK_ONLY) console.log('  （--check 模式，未做任何修改）');
})().catch((e) => { console.error('异常：', e); process.exit(1); });
