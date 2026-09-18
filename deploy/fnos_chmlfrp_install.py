#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把 ChmlFrp 客户端（frpc，ARM64）装到飞牛 NAS 并做成开机自启。

【为什么自己装，而不是跑官方一键脚本】
  1) 官方脚本落到 `/usr/local/frpc`。飞牛是 Debian，系统更新时 `/usr/local` 保不保留
     不可控；本项目统一把可执行文件放在**数据卷** `/vol1/@appdata/<app>/` 下
     （飞牛自带的 zeronews 应用也是这个布局），重启/系统更新都不丢。
  2) 自己装能明确知道改了哪几个文件，回滚有据可查（本脚本自带 --uninstall）。

【飞牛环境（已实测）】
  · aarch64 / Debian 12 bookworm  → 必须下 linux_arm64 包
  · 小智服务端端口已由 Docker 映射到宿主机：`0.0.0.0:3602->3602/tcp`
    → 所以 frpc.ini 里 `local_ip` 填 `127.0.0.1` 就通（frpc 跑在飞牛本机）

【🔴 凭据纪律】
  frpc.ini 里含账户 token（`user=`）与统一鉴权串（`token=`），属于凭据。
  本脚本**刻意不接受把 token 写在命令行**（会进 shell history 和进程列表），
  只从本地文件读（默认 `deploy/.chmlfrp.ini`，已在 .gitignore）。
  落盘到飞牛后权限收紧成 600。

用法：
    python deploy/fnos_chmlfrp_install.py --ini deploy/.chmlfrp.ini
    python deploy/fnos_chmlfrp_install.py --status
    python deploy/fnos_chmlfrp_install.py --uninstall
    python deploy/fnos_chmlfrp_install.py --ini ... --expect-url http://sj-2.frp.one:36542
"""
import argparse
import os
import re
import shlex
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from fnos_ssh import connect, put_file, run  # noqa: E402

APP_DIR = '/vol1/@appdata/chmlfrp'
BIN = APP_DIR + '/frpc'
INI = APP_DIR + '/frpc.ini'
UNIT = '/etc/systemd/system/chmlfrp.service'
SERVICE = 'chmlfrp'

DEFAULT_URL = ('https://cf-v1.uapis.cn/download/'
               'ChmlFrp-0.51.2_251023_linux_arm64.tar.gz')

UNIT_TMPL = """[Unit]
Description=ChmlFrp client (frpc) - xiaozhi-im tunnel
Documentation=https://docs.chmlfrp.net
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=simple
ExecStart={bin} -c {ini}
Restart=always
RestartSec=5
# 日志不进 syslog，避免刷爆：journalctl -u {svc} 仍可看
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
"""

REQUIRED_COMMON = ('server_addr', 'server_port', 'user', 'token')


def parse_ini(text):
    """极简 ini 解析：返回 [(section, {k: v})]。够用且不引第三方依赖。"""
    out, cur, kv = [], None, {}
    for raw in text.splitlines():
        ln = raw.strip()
        if not ln or ln.startswith(('#', ';')):
            continue
        m = re.match(r'^\[(.+)\]$', ln)
        if m:
            if cur is not None:
                out.append((cur, kv))
            cur, kv = m.group(1).strip(), {}
            continue
        if '=' in ln and cur is not None:
            k, v = ln.split('=', 1)
            kv[k.strip()] = v.strip()
    if cur is not None:
        out.append((cur, kv))
    return out


def validate(text):
    """装之前先校验，别把明显错的配置推到远端再回头查。"""
    secs = parse_ini(text)
    if not secs:
        raise SystemExit('配置内容为空或解析不出来')

    common = next((kv for name, kv in secs if name.lower() == 'common'), None)
    if common is None:
        raise SystemExit('缺少 [common] 段 —— ChmlFrp 控制台生成的配置应当包含它')

    missing = [k for k in REQUIRED_COMMON if not common.get(k)]
    if missing:
        raise SystemExit('[common] 缺少必填项: %s\n'
                         '（请到控制台「配置文件」页重新复制完整内容）' % ', '.join(missing))

    tunnels = [(n, kv) for n, kv in secs if n.lower() != 'common']
    if not tunnels:
        raise SystemExit('配置里没有任何隧道段落 —— 只有 [common] 的话 frpc 连上去也不转发')

    # 隧道必须指向本机 3602：这是小智服务端。指错了等于白装。
    ok_port = []
    for name, kv in tunnels:
        lp = kv.get('local_port', '')
        ok_port.append((name, kv.get('type', '?'), lp, kv.get('remote_port', '?')))
    if not any(lp == '3602' for _, _, lp, _ in ok_port):
        raise SystemExit('没有任何隧道指向 local_port=3602，当前是：%s\n'
                         '小智服务端在 3602，指别的端口这条隧道就白建了。' % ok_port)

    return common, ok_port


def cmd_install(c, args):
    if not os.path.isfile(args.ini):
        raise SystemExit('找不到本地配置文件: %s' % args.ini)
    text = open(args.ini, encoding='utf-8').read()
    common, tunnels = validate(text)

    print('配置校验通过')
    print('  frps 地址 : %s:%s' % (common['server_addr'], common['server_port']))
    print('  账户 token: %s…（已省略）' % common['user'][:6])
    for name, typ, lp, rp in tunnels:
        print('  隧道      : [%s] %s  127.0.0.1:%s -> remote_port %s' % (name, typ, lp, rp))
    print()

    # ---- 1) 本机下 arm64 包（比让飞牛去下更可控，且能先校验）----
    cache = args.cache
    if not os.path.isfile(cache) or os.path.getsize(cache) < 1024 * 1024:
        print('[1/6] 下载客户端包 …')
        rc = os.system('curl -sL --max-time 280 -o %s %s' % (shlex.quote(cache), shlex.quote(args.url)))
        if rc != 0 or not os.path.isfile(cache):
            raise SystemExit('下载失败：%s' % args.url)
    print('[1/6] 客户端包就绪: %s（%.1f MB）' % (cache, os.path.getsize(cache) / 1048576))

    # 校验是合法 gzip（截断的包在这里就拦住，别学 libwebrtc 那次的教训）
    with open(cache, 'rb') as f:
        if f.read(2) != b'\x1f\x8b':
            raise SystemExit('下载到的不是 gzip 包（可能被截断或拿到 HTML 错误页），删掉重下')

    # ---- 2) 远端准备目录 + 落地压缩包 ----
    print('[2/6] 准备远端目录 %s …' % APP_DIR)
    run(c, 'mkdir -p %s' % shlex.quote(APP_DIR), check=True)
    remote_tar = APP_DIR + '/pkg.tar.gz'
    put_file(c, cache, remote_tar, mode='644', backup=False)

    # ---- 3) 解包并挑出 frpc ----
    print('[3/6] 解包并安装可执行文件 …')
    out = run(c, 'cd %s && tar -xzf pkg.tar.gz && find . -maxdepth 3 -type f -name frpc | head -1'
             % shlex.quote(APP_DIR), check=True)
    found = out.strip().splitlines()[-1].strip() if out.strip() else ''
    if not found or 'frpc' not in found:
        listing = run(c, 'ls -la %s' % shlex.quote(APP_DIR))
        raise SystemExit('解包后没找到 frpc 可执行文件。目录内容：\n%s' % listing)
    # 解包出来的目录名不确定，动态处理；用 install 一步到位（自带 chmod）
    run(c, 'cd %s && install -m 755 %s %s' % (shlex.quote(APP_DIR), shlex.quote(found), BIN),
        check=True)
    run(c, 'rm -f %s %s' % (shlex.quote(remote_tar), shlex.quote(APP_DIR + '/pkg.tar.gz.1')),
        check=False)
    arch = run(c, 'file %s 2>/dev/null || true' % BIN)
    print('      %s' % (arch.strip() or '(file 命令不可用)'))

    # ---- 4) 落配置（含 token，权限 600）----
    print('[4/6] 写入 frpc.ini（权限 600）…')
    put_file(c, args.ini, INI, mode='600', backup=True, stamp='chmlfrp')

    # ---- 5) 装 systemd 服务 ----
    print('[5/6] 安装 systemd 服务 %s …' % SERVICE)
    unit = UNIT_TMPL.format(bin=BIN, ini=INI, svc=SERVICE)
    local_unit = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                              '.chmlfrp.service.tmp')
    with open(local_unit, 'w', encoding='utf-8', newline='\n') as f:
        f.write(unit)
    put_file(c, local_unit, UNIT, mode='644', backup=True, stamp='chmlfrp')
    os.remove(local_unit)
    run(c, 'systemctl daemon-reload && systemctl enable %s >/dev/null 2>&1; '
           'systemctl restart %s' % (SERVICE, SERVICE), check=False)

    # ---- 6) 验证 ----
    print('[6/6] 验证 …')
    return verify(c, args)


def verify(c, args):
    bad = 0

    def chk(label, cond, detail=''):
        nonlocal bad
        if not cond:
            bad += 1
        print('  %s %s%s' % ('OK  ' if cond else 'FAIL', label,
                             ('  -> ' + detail) if detail else ''))
        return cond

    active = run(c, 'systemctl is-active %s 2>&1' % SERVICE).strip()
    chk('服务处于 active', active == 'active', active)

    enabled = run(c, 'systemctl is-enabled %s 2>&1' % SERVICE).strip()
    chk('已设为开机自启（enabled）', enabled == 'enabled', enabled)

    binok = run(c, 'test -x %s && echo yes' % BIN).strip()
    chk('可执行文件存在且可执行', binok == 'yes', BIN)

    # ⚠️ 这里的 %%a 必须是双写：这个字符串后面跟着 % 格式化，
    #    `stat -c '%a'` 的单 %a 会被 Python 当占位符吃掉，
    #    报 "not enough arguments for format string"（本轮真实踩过）。
    perms = run(c, "stat -c '%%a' %s" % INI).strip()
    chk('frpc.ini 权限为 600（内含 token）', perms == '600', perms)

    log = run(c, 'journalctl -u %s -n 40 --no-pager 2>&1' % SERVICE)
    # 🔴 这里必须同时认中英两套日志串 —— ChmlFrp 的 frpc 是**魔改版，日志是中文**，
    #    只按原版 frp 的英文串去匹配会**必然假失败**（本轮就踩了：隧道明明
    #    "成功登录至服务器 / 映射启动成功"，脚本却报 3 项 FAIL，差点去查一个
    #    根本不存在的故障）。
    zh_login = '成功登录至服务器' in log
    en_login = ('login to server success' in log) or ('login to the server success' in log)
    logged_in = zh_login or en_login
    cn_fix = not logged_in
    if cn_fix:
        print('      ↳ 若确认隧道正常但这里报红，说明客户端换日志文案了，需同步更新判据')
    chk('已登录到 frps', logged_in, log.splitlines()[-1][:120] if log.strip() else '无日志')

    zh_proxy = '映射启动成功' in log
    en_proxy = 'start proxy success' in log
    proxy_ok = zh_proxy or en_proxy
    chk('隧道已建立（映射启动成功）', proxy_ok,
        '' if proxy_ok else '日志里没有 —— 往上翻 journalctl 看具体报错')

    # 反向验证：本机 3602 必须还在监听（frpc 不该把它搞掉）
    listen = run(c, "ss -lnt 2>/dev/null | grep -c ':3602'").strip()
    chk('本机 3602 仍在监听', listen.isdigit() and int(listen) > 0, listen)

    if args.expect_url:
        print()
        print('外网可达性（从飞牛发起，最多试 %d 次）:' % args.retries)
        # ⚠️ 必须重试：实测这条链路会有"服务端主动断开→9 秒后重连"的窗口，
        #    单次 curl 撞上窗口就报 000，看起来像"隧道没通"，其实是假的。
        url = args.expect_url.rstrip('/') + '/api/health'
        last = ''
        hit = False
        for i in range(1, args.retries + 1):
            code = run(c, "curl -s -o /dev/null -w '%%{http_code}' --max-time 20 %s"
                       % shlex.quote(url)).strip()
            last = code
            print('     第 %d 次: %s' % (i, code or '(空)'))
            if code == '200':
                hit = True
                break
            time.sleep(3)
        chk('外网 %s 返回 200' % url, hit, '最后一次=%s' % last)

    print()
    print('--- 汇总 ---')
    if bad == 0:
        print('全部通过 ✅')
    else:
        print('失败 %d 项 ❌  → 下一步：journalctl -u %s -n 80 --no-pager' % (bad, SERVICE))
    return 1 if bad else 0


def main():
    ap = argparse.ArgumentParser(description='把 ChmlFrp 客户端装到飞牛 NAS')
    ap.add_argument('--ini', default=os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                                  '.chmlfrp.ini'),
                    help='本地 frpc 配置文件（默认 deploy/.chmlfrp.ini）')
    ap.add_argument('--url', default=DEFAULT_URL, help='客户端包下载地址（默认 arm64）')
    ap.add_argument('--cache', default=os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                                    '.chmlfrp-pkg.tar.gz'),
                    help='客户端包本地缓存路径')
    ap.add_argument('--expect-url', default='',
                    help='可选：隧道的外网访问地址，用于做端到端 200 验证')
    ap.add_argument('--retries', type=int, default=5,
                    help='外网验证的重试次数（默认 5；隧道有重连窗口，单次必假失败）')
    ap.add_argument('--status', action='store_true', help='只看状态，不改动')
    ap.add_argument('--uninstall', action='store_true', help='停止并卸载服务（保留配置目录）')
    a = ap.parse_args()

    c = connect()
    try:
        if a.status:
            print('=== chmlfrp 服务状态 ===')
            print(run(c, 'systemctl status %s --no-pager 2>&1 | head -12' % SERVICE))
            print()
            print('=== 最近日志 ===')
            print(run(c, 'journalctl -u %s -n 25 --no-pager 2>&1' % SERVICE))
            print()
            print('=== 目录 ===')
            print(run(c, 'ls -la %s' % shlex.quote(APP_DIR)))
            return 0
        if a.uninstall:
            print(run(c, 'systemctl disable --now %s 2>&1; rm -f %s; systemctl daemon-reload; '
                         'echo uninstalled' % (SERVICE, UNIT)))
            print('已卸载（配置目录 %s 保留，内含 token，需要删请自行确认）' % APP_DIR)
            return 0
        return cmd_install(c, a)
    finally:
        c.close()


if __name__ == '__main__':
    sys.exit(main())
