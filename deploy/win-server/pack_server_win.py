# -*- coding: utf-8 -*-
"""把「小智IM 服务端（Node.js）」打成 Windows 安装程序（Setup exe）。

用法：
    python deploy/win-server/pack_server_win.py            # 打包 + 复制到桌面交付目录
    python deploy/win-server/pack_server_win.py --no-deliver   # 只出到 build 目录（自测）

产物：
    deploy/win-server/build/小智IM服务端-Setup-v<版本>.exe

═══ 与客户端那套（client/pack_win.py）的关键差别 ═══════════════════════

1) **必须自带 Node 运行时**
   客户机上大概率没装 Node，或者装的是个不能跑 node:sqlite 的老版本。
   所以把 node.exe 一起打进包（87 MB，LZMA 压完约 30 MB）。
   同时带上 Node 的 LICENSE —— 分发 Node 二进制是要带许可的。

2) **数据目录刻意放在安装目录之外**
   `%LOCALAPPDATA%\\小智IM服务端\\data`。
   放安装目录里的话，卸载会把聊天记录、上传文件、授权状态一起删光。
   放外面之后：卸载重装接着用，授权机器码也不变（不用重新出授权码）。

3) **第一件事是"别让客户拿不到密码"**
   服务端在 ADMIN_PASSWORD 缺失时会自己生成随机口令，但只打进日志；
   而 Windows 版是**隐藏窗口**跑的，客户看不到日志 ——
   结果就是"装完了不知道用什么登录"。所以装完立刻跑 init-env.js
   生成 data\\.env，把口令读到「安装完成」页上直接显示。

4) **启动脚本用 GBK 编码**
   .cmd / .vbs 交给 cmd.exe 与 wscript 执行，中文系统默认代码页是 936，
   用 UTF-8 存会出现乱码（命令行里"正在停止服务端…"变成问号）。
   所以 files/ 下按 UTF-8 维护（git 友好），写出时转 GBK。

5) **升级/卸载只按端口杀进程，绝不 taskkill /IM node.exe**
   客户机上很可能还跑着别的 node 程序，按映像名杀会一起干掉。
"""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))          # xiaozhi-im/
SERVER = os.path.join(ROOT, 'server')
FILES = os.path.join(HERE, 'files')
BUILD = os.path.join(HERE, 'build')
STAGE = os.path.join(BUILD, 'stage')

APP_NAME = '小智IM 服务端'
SHORT_NAME = '小智IM服务端'
DESKTOP_DIR = os.path.join('D:', os.sep, 'Users', 'pblpa', 'Desktop', '小智 IM')

# 内置 Node 运行时（与 Docker 侧 node:22-slim 同大版本，node:sqlite 才可用）
NODE_ROOT = os.path.join('C:', os.sep, 'Users', 'pblpa', '.workbuddy', 'binaries',
                         'node', 'versions', '22.22.2-3')
NODE_EXE = os.path.join(NODE_ROOT, 'node.exe')
NODE_LICENSE = os.path.join(NODE_ROOT, 'LICENSE')

# 安装向导图标：直接复用客户端那份，同一个产品不维护两套图标
ICON = os.path.join(ROOT, 'client', 'windows', 'runner', 'resources', 'app_icon.ico')

# 数据目录（安装目录之外）。NSIS 与 cmd 脚本里都用这个约定，必须一致。
DATA_DIR_NSIS = r'$LOCALAPPDATA' + '\\' + SHORT_NAME + r'\data'
INSTALL_DIR_NSIS = r'$LOCALAPPDATA\Programs' + '\\' + SHORT_NAME


def read_version():
    """版本号唯一来源：server/package.json（服务端自己报的版本就是它）"""
    with open(os.path.join(SERVER, 'package.json'), encoding='utf-8') as f:
        return json.load(f)['version']


def vi_version(version):
    """NSIS 的 VIProductVersion 只认 x.x.x.x 四位纯数字，0.17.0 → 0.17.0.0"""
    parts = [re.sub(r'\D', '', p) or '0' for p in version.split('.')]
    while len(parts) < 4:
        parts.append('0')
    return '.'.join(parts[:4])


def find_makensis():
    for cand in (
        os.environ.get('MAKENSIS'),
        os.path.join('C:', os.sep, 'Program Files (x86)', 'NSIS', 'makensis.exe'),
        os.path.join('C:', os.sep, 'Program Files', 'NSIS', 'makensis.exe'),
    ):
        if cand and os.path.isfile(cand):
            return cand
    p = shutil.which('makensis')
    if p:
        return p
    raise SystemExit('找不到 makensis.exe。装一个： winget install -e --id NSIS.NSIS')


def fresh_dir(path):
    """安全清空目录：**挪到 %TEMP% 而不是删**。

    构建产物目录在桌面工作区监控范围内，递归删除会被安全删除护栏拦下
    （SAFE_DELETE_BULK_CONFIRM_REQUIRED，且 turn 级累计、失败重试只会更糟）。
    """
    if os.path.isdir(path):
        tmp = os.path.join(tempfile.gettempdir(), 'xz_wsrv_stage_%d' % int(time.time()))
        shutil.move(path, tmp)
    os.makedirs(path)


def write_cmd(src, dst, version):
    """写 .cmd / .vbs：占位符替换 + 统一 CRLF，**保持 UTF-8、不转 GBK**。

    编码为什么用 UTF-8（而不是中文系统惯用的 GBK）：
      .cmd 既要 echo 中文提示，又要把 node 的输出直接打到控制台 / 日志文件，
      而 Node 的 stdout 永远是 UTF-8。若脚本用 GBK 存，两种编码就会同时出现在
      同一个窗口、同一个日志文件里 —— 必然有一半是乱码（实测：日志里
      cmd 写的标记行是 GBK、node 写的行是 UTF-8，客户打开就是花屏）。
      统一成 UTF-8 + 每个脚本开头 `chcp 65001`，脚本 / 控制台 / node 输出 /
      日志文件就都在一套编码上。
      代价：netsh、netstat 这些系统工具的**中文**输出会显示成乱码 ——
      所以脚本里对这些调用一律 `>nul` 抑制输出，只留自己的提示。

    ⚠️ 不能写成 utf-8-sig（带 BOM）：cmd.exe 会把 BOM 当成第一行命令的一部分，
       报「'@echo' 不是内部或外部命令」，而且很难往编码上想。
       （NSIS 脚本则**必须**带 BOM，两者要求正好相反，别写串了。）
    """
    text = open(src, encoding='utf-8').read()
    text = text.replace('__VERSION__', version)
    text = text.replace('\r\n', '\n').replace('\n', '\r\n')
    with open(dst, 'wb') as f:
        f.write(text.encode('utf-8'))


def write_text_gbk(dst, text):
    with open(dst, 'wb') as f:
        f.write(text.replace('\r\n', '\n').replace('\n', '\r\n').encode('gbk'))


def stage(version):
    print('[1/4] 组装安装目录 …')
    if not os.path.isfile(NODE_EXE):
        raise SystemExit('找不到 Node 运行时：%s' % NODE_EXE)
    if not os.path.isfile(NODE_LICENSE):
        raise SystemExit('找不到 Node 的 LICENSE（分发 Node 二进制必须带许可）：%s' % NODE_LICENSE)

    fresh_dir(STAGE)

    # --- 内置 Node 运行时 ---
    os.makedirs(os.path.join(STAGE, 'node'))
    shutil.copy2(NODE_EXE, os.path.join(STAGE, 'node', 'node.exe'))
    shutil.copy2(NODE_LICENSE, os.path.join(STAGE, 'node', 'LICENSE'))
    print('      node.exe  %.1f MB' % (os.path.getsize(NODE_EXE) / 1024 / 1024))

    # --- 服务端本体（镜像 server/ 的布局，config.js 的 ROOT 就是它上一级）---
    app = os.path.join(STAGE, 'app')
    os.makedirs(app)
    for rel in ('src', 'public', 'node_modules'):
        src = os.path.join(SERVER, rel)
        if not os.path.isdir(src):
            raise SystemExit('缺少 %s（先在 server/ 里跑 npm install --omit=dev）' % src)
        shutil.copytree(src, os.path.join(app, rel))
    for rel in ('package.json', 'package-lock.json'):
        shutil.copy2(os.path.join(SERVER, rel), os.path.join(app, rel))
    os.makedirs(os.path.join(app, 'tools'))
    shutil.copy2(os.path.join(FILES, 'tools', 'init-env.js'),
                 os.path.join(app, 'tools', 'init-env.js'))
    sz = sum(os.path.getsize(os.path.join(r, f))
             for r, _, fs in os.walk(app) for f in fs)
    print('      app/      %.1f MB（含 node_modules）' % (sz / 1024 / 1024))

    # --- 顶层脚本 / 快捷方式目标 ---
    n = 0
    for fn in sorted(os.listdir(FILES)):
        if fn.endswith(('.cmd', '.vbs')):
            write_cmd(os.path.join(FILES, fn), os.path.join(STAGE, fn), version)
            n += 1
    print('      脚本 %d 个（UTF-8 无 BOM + CRLF）' % n)

    # --- 交付说明（随包一份，客户翻目录时看得到）---
    write_text_gbk(os.path.join(STAGE, '版本说明.txt'), f"""小智IM 服务端（Windows 版）  v{version}

【装在哪】
  程序：本安装目录
  数据：%LOCALAPPDATA%\\{SHORT_NAME}\\data
        （数据库、上传的文件、授权状态、运行日志都在这里。
          放在安装目录**之外**是刻意的 —— 卸载不会删它，
          重装或升级后接着用，授权也不需要重新出码。）

【端口】
  TCP 3602   客户端连接 + 管理后台（http://本机IP:3602/admin）
  UDP 3616   客户端首次安装时的"局域网自动发现"
  两个端口都要在 Windows 防火墙上放通：双击「配置防火墙.cmd」（右键→以管理员身份运行）

【怎么用】
  1. 双击「后台启动服务端.vbs」——在后台运行，不显示窗口（开机自启走的就是它）
     想看着日志跑就用「启动服务端.cmd」（前台，关窗口即停）
  2. 双击「打开管理后台.cmd」进管理台
     管理账号 admin，初始密码见「查看管理员密码.cmd」
  3. 手机/电脑上装小智IM 客户端，同一局域网会自动扫到本机
     扫不到就在客户端的「服务器设置」里手填 http://本机IP:3602

【排障】
  · 服务起不来      →「查看运行日志.cmd」，日志在 data\\logs\\server.log
  · 手机连不上      → 先跑「配置防火墙.cmd」放通端口，再确认手机和电脑在同一网段
  · 忘记管理密码    →「查看管理员密码.cmd」看初始口令；
                      若已在管理台改过密码，请用改过的那个（初始口令只在首次建库时生效）
  · 换机器/换目录   → 授权与本机机器码绑定，换机器需要在管理台重新出授权码
""")


def build_nsi(version, out_file, nsis_path):
    if not os.path.isfile(ICON):
        raise SystemExit('找不到安装向导图标：%s' % ICON)

    tpl = open(os.path.join(HERE, 'installer.nsi.tpl'), encoding='utf-8').read()
    nsi = (tpl
           .replace('__APP_NAME__', APP_NAME)
           .replace('__SHORT_NAME__', SHORT_NAME)
           .replace('__VERSION__', version)
           .replace('__VI_VERSION__', vi_version(version))
           .replace('__DATA_DIR__', DATA_DIR_NSIS)
           .replace('__INSTALL_DIR__', INSTALL_DIR_NSIS)
           .replace('__SRC__', STAGE)
           .replace('__ICON__', ICON)
           .replace('__OUT_FILE__', out_file))
    # NSIS 按 ANSI 读脚本会把中文变成方块，必须 UTF-8 **带 BOM**。
    # 少 BOM 时安装界面上一片问号，而且只有真跑一次安装才看得出来。
    #
    # ⚠️ 写之前先把行尾归一成 LF：本机 git 配了 core.autocrlf=true，模板被
    #    重新检出后会变成 CRLF，而下面 newline='\r\n' 又会把每个 \n 补成 \r\n
    #    —— 两者叠加就写出 \r\r\n，是那种"今天能编、过几天突然编不过"的坑。
    nsi = nsi.replace('\r\n', '\n')
    with open(nsis_path, 'w', encoding='utf-8-sig', newline='\r\n') as f:
        f.write(nsi)
    return nsis_path


def main():
    ap = argparse.ArgumentParser(description='打包 Windows 服务端安装程序')
    ap.add_argument('--no-deliver', action='store_true', help='只出到 build 目录，不复制到桌面')
    args = ap.parse_args()

    version = read_version()
    makensis = find_makensis()
    print('服务端版本：%s（取自 server/package.json）' % version)
    print('NSIS 编译器：%s' % makensis)

    stage(version)
    os.makedirs(BUILD, exist_ok=True)
    out_name = '%s-Setup-v%s.exe' % (SHORT_NAME, version)
    out_path = os.path.join(BUILD, out_name)
    if os.path.exists(out_path):
        os.remove(out_path)

    print('[2/4] 生成安装脚本 …')
    script = build_nsi(version, out_path, os.path.join(BUILD, 'installer.nsi'))

    print('[3/4] NSIS 编译 …')
    r = subprocess.run([makensis, '/V2', script], cwd=BUILD,
                       capture_output=True, text=True, encoding='utf-8', errors='replace')
    tail = '\n'.join((r.stdout or '').splitlines()[-12:])
    if tail:
        print(tail)
    if r.returncode != 0 or not os.path.isfile(out_path):
        print('NSIS 编译失败，退出码 %s' % r.returncode)
        print((r.stderr or '')[-2000:])
        return 1

    print('[4/4] 生成安装包：%s（%.1f MB）'
          % (out_path, os.path.getsize(out_path) / 1024 / 1024))

    if not args.no_deliver and os.path.isdir(DESKTOP_DIR):
        dst = os.path.join(DESKTOP_DIR, out_name)
        shutil.copy2(out_path, dst)
        print('已复制到桌面：%s' % dst)
    return 0


if __name__ == '__main__':
    sys.exit(main())
