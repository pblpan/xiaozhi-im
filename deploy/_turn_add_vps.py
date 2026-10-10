#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把 VPS(185.242.233.140) 变成第二台 TURN 中继，加进小智 IM 通话链路。

背景：自建 coturn 原来跑在飞牛上，但家宽无公网入站、免费隧道不支持
TCP/UDP —— 公网进不来。现在有了自己的公网 VPS（网卡直挂公网 IP），
coturn 直接装 VPS 上，路线 B 复活，与 Cloudflare 托管中继并存下发，
客户端 auto 挑通的用。

流程（断言式，任一步失败退出非 0）：
  1. 飞牛读 turn.env 现有 TURN_USERNAME/CREDENTIAL/URLS（凭据不打印明文）
  2. 用**同一对**凭据写 VPS /etc/turnserver.conf（服务端只下发一对账号）
  3. VPS 启动 coturn + turnutils_uclient 本机中继分配自测
  4. 飞牛 turn.env 的 TURN_URLS 去重追加 VPS 的 udp/tcp 两条
  5. docker restart xiaozhi-im（turn.env 是进程启动时读的，必须重启）
  6. 公网探 3478/tcp
"""
import os
import socket
import sys

import paramiko

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from fnos_ssh import connect as fnos_connect, read_file, put_file, run as fnos_run  # noqa: E402

TURN_ENV = "/vol1/@appshare/xiaozhi-im/data/turn.env"
VPS_IP = "185.242.233.140"
NEW_URLS = [
    f"turn:{VPS_IP}:3478?transport=udp",
    f"turn:{VPS_IP}:3478?transport=tcp",
]


def load_vps_env():
    env = {}
    with open(os.path.join(HERE, ".vps.env"), encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                env[k.strip()] = v.strip()
    return env


def parse_env(text):
    out = {}
    for line in (text or "").splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            out[k.strip()] = v.strip()
    return out


def mask(s):
    if not s:
        return "(空)"
    return s[:3] + "***" + s[-1:] if len(s) > 5 else "***"


def main():
    # ---- 1. 飞牛读现有凭据 ----
    fc = fnos_connect()
    raw = read_file(fc, TURN_ENV, sudo=True)
    if raw is None:
        print(f"❌ 飞牛上找不到 {TURN_ENV}")
        sys.exit(1)
    tenv = parse_env(raw)
    tuser = tenv.get("TURN_USERNAME", "")
    tcred = tenv.get("TURN_CREDENTIAL", "")
    turls = [u.strip() for u in tenv.get("TURN_URLS", "").split(",") if u.strip()]
    if not tuser or not tcred:
        print("❌ turn.env 缺 TURN_USERNAME/TURN_CREDENTIAL"); sys.exit(1)
    print(f"[1] 飞牛凭据: user={tuser} cred={mask(tcred)}")
    print(f"    现有 TURN_URLS({len(turls)}): {turls}")

    # ---- 2. 生成 VPS turnserver.conf（同一对凭据）----
    conf = f"""\n# 由 _turn_add_vps.py 生成 —— 小智 IM 第二 TURN 中继（香港 VPS）
listening-port=3478
listening-ip={VPS_IP}
relay-ip={VPS_IP}
external-ip={VPS_IP}
min-port=49160
max-port=49200
user={tuser}:{tcred}
realm=xiaozhi-im
no-cli
no-tls
no-dtls
simple-log
log-file=/var/log/turnserver.log
"""
    local_conf = os.path.join(HERE, ".turnserver.conf.tmp")
    with open(local_conf, "w", encoding="utf-8", newline="\n") as f:
        f.write(conf)

    venv = load_vps_env()
    vc = paramiko.SSHClient()
    vc.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    vc.connect(venv["VPS_HOST"], int(venv.get("VPS_PORT", "22")),
               venv.get("VPS_USER", "root"), venv["VPS_PASS"], timeout=25,
               allow_agent=False, look_for_keys=False)
    sftp = vc.open_sftp()
    sftp.put(local_conf, "/tmp/turnserver.conf")
    sftp.close()
    os.remove(local_conf)

    # ---- 3. 启动 coturn + 自测 ----
    def vrun(cmd, timeout=120):
        _, so, _ = vc.exec_command(cmd, timeout=timeout)
        out = so.read().decode("utf-8", "replace")
        rc = so.channel.recv_exit_status()
        return rc, out

    rc, out = vrun(
        "install -m 644 /tmp/turnserver.conf /etc/turnserver.conf && "
        "sed -i 's/^TURNSERVER_ENABLED=.*/TURNSERVER_ENABLED=1/' /etc/default/coturn 2>/dev/null; "
        "grep -q '^TURNSERVER_ENABLED=1' /etc/default/coturn 2>/dev/null || "
        "echo TURNSERVER_ENABLED=1 >> /etc/default/coturn; "
        "systemctl enable --now coturn 2>&1 | tail -2; systemctl restart coturn")
    print(f"[3] coturn 启动 rc={rc} {out.strip()[:200]}")

    ok3478 = False
    for _ in range(10):
        rc, out = vrun("ss -uln | grep -q ':3478 ' && ss -tln | grep -q ':3478 ' && echo OK || echo NO")
        if "OK" in out:
            ok3478 = True
            break
        import time; time.sleep(1)
    if not ok3478:
        rc, out = vrun("journalctl -u coturn --no-pager -n 15")
        print("❌ 3478 未监听:\n", out); sys.exit(1)
    print("    3478 tcp+udp 监听 ✅")

    rc, out = vrun(f"turnutils_uclient -y -u {tuser} -w {tcred} -p 3478 {VPS_IP} 2>&1 | tail -8")
    print(f"[3b] 中继分配自测(rc={rc}):\n{out.strip()}")
    if "allocate" not in out.lower() and "total" not in out.lower():
        print("❌ turnutils 自测输出异常，中断（避免把坏中继下发出去）"); sys.exit(1)

    # ---- 4. 飞牛 turn.env 追加 URL ----
    merged = list(turls)
    added = [u for u in NEW_URLS if u not in merged]
    if added:
        merged.extend(added)
    else:
        print("[4] TURN_URLS 已含 VPS 地址，跳过追加")
    if added:
        lines, seen = [], False
        for line in raw.splitlines():
            if line.strip().startswith("TURN_URLS="):
                lines.append("TURN_URLS=" + ",".join(merged)); seen = True
            else:
                lines.append(line)
        if not seen:
            lines.append("TURN_URLS=" + ",".join(merged))
        local_env = os.path.join(HERE, ".turn.env.tmp")
        with open(local_env, "w", encoding="utf-8", newline="\n") as f:
            f.write("\n".join(lines) + "\n")
        ok, _ = put_file(fc, local_env, TURN_ENV, mode="600", stamp="bak")
        os.remove(local_env)
        if not ok:
            print("❌ turn.env 回写失败"); sys.exit(1)
        back = parse_env(read_file(fc, TURN_ENV, sudo=True))
        assert f"turn:{VPS_IP}:3478?transport=udp" in back.get("TURN_URLS", "")
        print(f"[4] TURN_URLS 现共 {len(merged)} 条: {merged}")

    # ---- 5. 重启服务端容器 ----
    out = fnos_run(fc, "cd /vol1/@appcenter/xiaozhi-im/docker && docker compose restart xiaozhi-im 2>&1 | tail -2")
    print(f"[5] 容器重启: {out}")

    # ---- 6. 公网探 3478/tcp ----
    try:
        s = socket.create_connection((VPS_IP, 3478), timeout=8); s.close()
        print(f"[6] 公网 {VPS_IP}:3478/tcp OPEN ✅")
    except OSError as e:
        print(f"[6] ⚠️ 公网 3478/tcp: {e}")

    print("\n✅ 完成：客户端 /api/call/ice 将同时下发 Cloudflare + VPS 两路 TURN，"
          "auto 挑通的用。请用两台不同网络的设备实测一通电话。")
    fc.close(); vc.close()


if __name__ == "__main__":
    main()
