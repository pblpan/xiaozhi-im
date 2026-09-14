#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""在飞牛上设置/轮换 TURN 中继口令 —— 三处一起改，保持一致。

为什么要专门做这件事：
    中继口令在两处存在，而**服务端优先读其中一份**：
      · docker/.env 的 TURN_PASSWORD      -> coturn 容器创建时烘进环境变量
      · /data/turn.env 的 TURN_CREDENTIAL -> 服务端优先读它，下发给客户端
    只改一份 = 客户端拿着 A 去认证 B -> 失败 -> ICE 悄悄丢掉中继候选
    -> 「同 WiFi 通话一切正常、跨网一连就断」。从现象上完全看不出是口令问题。

用法：
    python deploy/fnos_set_turn_password.py                 # 生成强口令并应用
    python deploy/fnos_set_turn_password.py --keep-current  # 只检查三处是否一致
    python deploy/fnos_set_turn_password.py --no-recreate    # 只改文件，不重建容器
    python deploy/fnos_set_turn_password.py --password XXX   # 指定口令（尽量别用）

口令不会打印。改完请自行留存。
"""
import argparse
import os
import secrets
import sys
import tempfile
from datetime import datetime

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from fnos_ssh import connect, put_file, run  # noqa: E402

APPDIR = "/vol1/@appcenter/xiaozhi-im"
DOCKER_DIR = APPDIR + "/docker"
ENV_FILE = DOCKER_DIR + "/.env"
TURN_ENV_CANDIDATES = [
    "/vol1/@appshare/xiaozhi-im/data/turn.env",
    "/var/apps/xiaozhi-im/shares/xiaozhi-im/data/turn.env",
]
LEGACY = "xiaozhi-turn-2026"


def find_turn_env(c):
    for p in TURN_ENV_CANDIDATES:
        if run(c, "test -f %s && echo yes || echo no" % p).strip().endswith("yes"):
            return p
    return TURN_ENV_CANDIDATES[0]


def get_key(text, key):
    if not text:
        return ""
    for line in text.splitlines():
        if line.startswith(key + "="):
            return line.split("=", 1)[1].strip()
    return ""


def set_key(text, key, value):
    """就地把 `KEY=` 那行改成 value；没有该键则追加。保留其它行原样。"""
    lines = (text or "").splitlines()
    hit = False
    out = []
    for line in lines:
        if line.startswith(key + "="):
            out.append("%s=%s" % (key, value))
            hit = True
        else:
            out.append(line)
    if not hit:
        out.append("%s=%s" % (key, value))
    return "\n".join(out) + "\n"


def tag(v):
    if not v:
        return "(未设置)"
    if v == LEGACY:
        return "公开仓库默认值 ← 等于没设"
    return "已设置（%d 位，%s…）" % (len(v), v[:4])


def inspect(c, turn_env):
    env_pw = get_key(run(c, "cat %s 2>/dev/null || true" % ENV_FILE), "TURN_PASSWORD")
    te_pw = get_key(run(c, "cat %s 2>/dev/null || true" % turn_env), "TURN_CREDENTIAL")
    co_pw = run(
        c, "docker inspect xiaozhi-im-turn --format "
           "'{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null "
           "| grep '^TURN_PASSWORD=' | cut -d= -f2- || true").strip()
    return env_pw, te_pw, co_pw


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--password", help="指定口令（默认随机 64 位 hex）")
    ap.add_argument("--keep-current", action="store_true", help="不改，只检查一致性")
    ap.add_argument("--no-recreate", action="store_true", help="只改文件，不重建容器")
    a = ap.parse_args()

    c = connect()
    try:
        turn_env = find_turn_env(c)
        env_pw, te_pw, co_pw = inspect(c, turn_env)

        print("当前状态：")
        print("  docker/.env    TURN_PASSWORD   = %s" % tag(env_pw))
        print("  %s" % turn_env)
        print("  turn.env       TURN_CREDENTIAL = %s" % tag(te_pw))
        print("  运行中 coturn  TURN_PASSWORD   = %s" % tag(co_pw))
        consistent = bool(env_pw) and env_pw == te_pw == co_pw
        print("\n三处一致：%s" % ("是 ✓" if consistent else "否 ✗ —— 这正是「同 WiFi 通、跨网断」的原因"))

        if a.keep_current:
            return 0 if consistent else 1

        pw = a.password or secrets.token_hex(32)
        print("\n应用新口令：%d 位 hex（不打印内容）" % len(pw))
        stamp = datetime.now().strftime("%m%d%H%M")

        # 两份文件都在本地改好再推 —— 不在远端拼 shell（复合命令在 sudo 下
        # 会被外层 shell 拆开，静默漏执行；见 fnos_ssh 模块顶部注释）
        env_text = run(c, "cat %s 2>/dev/null || true" % ENV_FILE)
        te_text = run(c, "cat %s 2>/dev/null || true" % turn_env)
        env_new = set_key(env_text, "TURN_PASSWORD", pw)
        te_new = set_key(set_key(te_text, "TURN_CREDENTIAL", pw), "TURN_USERNAME", "xiaozhi")

        tmpdir = tempfile.mkdtemp(prefix="xz_turn_")
        for name, text, remote, mode in [
            ("env", env_new, ENV_FILE, "644"),
            ("turn.env", te_new, turn_env, "666"),
        ]:
            lp = os.path.join(tmpdir, name)
            with open(lp, "w", encoding="utf-8", newline="\n") as f:
                f.write(text)
            ok, size = put_file(c, lp, remote, mode=mode, backup=True, stamp=stamp)
            print("  %s -> %s  %s" % (name, remote, "✓" if ok else "✗ 字节数不符 %s" % size))

        if not a.no_recreate:
            print("  重建容器（环境变量只在**创建**时生效，restart 不顶用）...")
            out = run(c, "docker compose --project-directory %s -f %s/docker-compose.yaml "
                         "up -d --force-recreate coturn xiaozhi-im 2>&1 | tail -12"
                      % (DOCKER_DIR, DOCKER_DIR), timeout=420)
            print("  " + (out.replace("\n", "\n  ") if out else "(无输出)"))

            env_pw2, te_pw2, co_pw2 = inspect(c, turn_env)
            ok = bool(env_pw2) and env_pw2 == te_pw2 == co_pw2 and env_pw2 != LEGACY
            print("\n复核：三处一致且非默认值 = %s" % ("✓" if ok else "✗"))
            if not ok:
                print("  .env=%s  turn.env=%s  coturn=%s"
                      % (tag(env_pw2), tag(te_pw2), tag(co_pw2)))
            else:
                print("新口令已在服务器上生效（本脚本不留副本，请自行留存）。")
            return 0 if ok else 1

        print("\n（--no-recreate：文件已改，容器未重建，改动尚未生效）")
        return 0
    finally:
        c.close()


if __name__ == "__main__":
    sys.exit(main())
