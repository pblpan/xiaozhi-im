# -*- coding: utf-8 -*-
"""飞牛 NAS 连接凭据 —— **绝不写进源码**。

⚠️ 安全背景（2026-09-12 事故）：
    本仓库是 **Public**。曾经有 7 个脚本把飞牛 SSH 密码硬编码在文件里
    （`PASS = "Pbl1..."`），并已推送到 GitHub —— 等于把 NAS 的登录密码公开。
    删除文件没用，历史 commit 依然可读，**唯一真正的补救是改密码**。

所以现在统一从下面两个来源取，源码里一个字符都不留：
    1. 环境变量 `FNOS_PASS`（CI / 临时用）
    2. `deploy/.fnos.env`（本地文件，已 gitignore），内容形如：
           FNOS_PASS=你的密码

用法（各脚本里）：
    from fnos_auth import HOST, USER, PASS
"""
import os

# 主机与用户名不是秘密，给默认值方便直接跑。
HOST = os.environ.get('FNOS_HOST', '192.168.31.44')
USER = os.environ.get('FNOS_USER', 'pblpan')

_LOCAL_ENV = os.path.join(os.path.dirname(os.path.abspath(__file__)), '.fnos.env')


def _load_pass():
    p = os.environ.get('FNOS_PASS')
    if p:
        return p
    try:
        with open(_LOCAL_ENV, 'r', encoding='utf-8') as fh:
            for line in fh:
                line = line.strip()
                if line.startswith('FNOS_PASS='):
                    v = line.split('=', 1)[1].strip().strip('"').strip("'")
                    if v:
                        return v
    except FileNotFoundError:
        pass
    raise SystemExit(
        '缺少飞牛 SSH 密码。请任选一种方式提供（源码里不留密码）：\n'
        '  · 设环境变量：          export FNOS_PASS=你的密码\n'
        '  · 或写本地配置文件：    %s\n'
        '                        内容一行：FNOS_PASS=你的密码\n'
        '（deploy/.fnos.env 已在 .gitignore 中，不会被提交）' % _LOCAL_ENV)


PASS = _load_pass()
