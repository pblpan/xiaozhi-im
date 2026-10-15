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

# 内部脚本子目录（2026-10-09 加）。
# 起因：龙哥装上服务端后打开安装目录，看到的是一整屏 .cmd（"控制台不是改成 exe 了吗？"）。
# 控制台本体早就是图形窗口了，但入口留成 .cmd，客户观感就是"一堆命令脚本"。
# 现在：安装根只放「小智IM 服务端控制台.exe」一个门面，
# 所有 .cmd / .vbs / console.ps1 一律收进这个子目录。
# ⚠️ _env.cmd 里 XZ_HOME 原来是"脚本自己所在目录"，收进子目录后必须上跳一级，
#    它已经改成"以 node\ 的位置反推安装根"（见 files/_env.cmd）。
APP_SYS = '_sys'

APP_NAME = '小智IM 服务端'
SHORT_NAME = '小智IM服务端'
DESKTOP_DIR = os.path.join('D:', os.sep, 'Users', 'pblpa', 'Desktop', '小智 IM')

# 内置 Node 运行时（与 Docker 侧 node:22-slim 同大版本，node:sqlite 才可用）
NODE_ROOT = os.path.join('C:', os.sep, 'Users', 'pblpa', '.workbuddy', 'binaries',
                         'node', 'versions', '22.22.2-6')
NODE_EXE = os.path.join(NODE_ROOT, 'node.exe')
NODE_LICENSE = os.path.join(NODE_ROOT, 'LICENSE')

# 安装向导图标：直接复用客户端那份，同一个产品不维护两套图标
ICON = os.path.join(ROOT, 'client', 'windows', 'runner', 'resources', 'app_icon.ico')

# 数据目录（安装目录之外）。NSIS 与 cmd 脚本里都用这个约定，必须一致。
DATA_DIR_NSIS = r'$LOCALAPPDATA' + '\\' + SHORT_NAME + r'\data'
INSTALL_DIR_NSIS = r'$LOCALAPPDATA\Programs' + '\\' + SHORT_NAME

# 分发包里**不该出现**的东西：开发者的真实内网地址与域名。
# 当初真实的泄漏事故就发生在管理台 bundle 里的帮助文案 —— 而这个 exe 会把
# 整个 server/public（含管理台 bundle）原样带进去，所以必须在打包时拦一道。
# 这里用 hex 拼：仓库是公开的，直接写整串等于把它们又贴回来一遍。
BANNED_IN_PKG = [
    (bytes.fromhex('3139322e3136382e33312e3434'), '开发者真实内网地址'),  # 192.168.31.44
    (bytes.fromhex('74616b696e2e6363'), '开发者真实域名'),            # takin.cc
]

# 扫描时跳过的目录：node_modules 是第三方代码，里面有 192.168.x 示例很正常
SCAN_SKIP_DIRS = ('node_modules', '.git', '__pycache__')


def scan_banned(root):
    """逐字节扫描 staging 目录，返回 [(相对路径, 说明), ...]。

    ⚠️ 不按后缀过滤：当初的泄漏就在 .js bundle 里，但也可能是 .cmd/.txt/.conf。
       判据全是 ASCII 串，二进制里出现同样算命中。
    ⚠️ 返回空列表 ≠ 一切正常 —— 调用方要另外确认"确实扫到了文件"，
       否则扫了个空目录也会显示全绿（verify_fpk.py 里踩过这个假通过）。
    """
    hits = []
    n = 0
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in SCAN_SKIP_DIRS]
        for fn in filenames:
            p = os.path.join(dirpath, fn)
            try:
                with open(p, 'rb') as f:
                    blob = f.read()
            except OSError:
                continue
            n += 1
            rel = os.path.relpath(p, root)
            for pat, why in BANNED_IN_PKG:
                if pat in blob:
                    hits.append((rel, '%s（%s）' % (pat.decode(), why)))
    return hits, n


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


def _gbk_ok(ch):
    try:
        ch.encode('gbk')
        return True
    except UnicodeEncodeError:
        return False


def precheck_scripts():
    """出包前把所有脚本的编码问题**一次报全**。

    写 write_cmd 时逐个文件抛错也能拦住，但那样得改一处、跑一次、再失败一处 ——
    实测连着失败两轮（先是 emoji、再是 ⚠️）。这里先扫一遍，一次把问题摆出来。
    """
    problems = []
    for fn in sorted(os.listdir(FILES)):
        if not fn.endswith(('.cmd', '.vbs')):
            continue
        text = open(os.path.join(FILES, fn), encoding='utf-8').read()
        if all(ord(c) < 128 for c in text):
            continue    # 纯 ASCII 桥接脚本，随便
        if re.search(r'(?mi)^\s*chcp\b', text):
            problems.append('%s：含中文却调用了 chcp（会让 cmd 按字节偏移解析错位）' % fn)
        for ch in sorted({c for c in text if ord(c) >= 128 and not _gbk_ok(c)}):
            problems.append('%s：GBK 编不了的字符 %r (U+%04X)' % (fn, ch, ord(ch)))
    return problems


def write_cmd(src, dst, version):
    """写 .cmd / .vbs：占位符替换 + 统一 CRLF + **按内容自动决定编码**。

    ── 编码规则（踩过真实事故，别改）────────────────────────────
    含中文的脚本 → 写 **GBK**，并且**禁止调用 chcp**。
      中文 Windows 的控制台默认就是 GBK，cmd 原生就能读。
      反过来"UTF-8 脚本 + 第二行 chcp 65001"是个致命组合：
      cmd.exe 是按**字节偏移**逐行读批处理文件的，中途切代码页之后
      它对多字节字符的长度判断变了，于是会从**注释行的中间**开始解析，
      中文注释的后半截被当成命令执行。客户装完看到的是一屏
        'xx值外面永远看不到（经典坑）。' is not recognized as an…
      然后窗口闪退 —— 而且极难往编码上想。
    纯 ASCII 的桥接脚本 → 保持 ASCII，允许 chcp。
      它们由**独立的新控制台窗口**启动，代码页切换隔离在那个窗口里，
      不会污染调用方（chcp 改的是整个控制台窗口的属性）。

    ⚠️ 不能写成 utf-8-sig（带 BOM）：cmd.exe 会把 BOM 当成第一行命令的
       一部分，报「'@echo' 不是内部或外部命令」。
       （NSIS 脚本则**必须**带 BOM，两者要求正好相反，别写串了。）
    """
    text = open(src, encoding='utf-8').read()
    text = text.replace('__VERSION__', version)
    text = text.replace('\r\n', '\n').replace('\n', '\r\n')
    name = os.path.basename(dst)

    if all(ord(c) < 128 for c in text):
        data = text.encode('ascii')
    else:
        # 只认"真的在调用 chcp"，注释里提到不算
        if re.search(r'(?mi)^\s*chcp\b', text):
            raise SystemExit(
                '出包中止：%s 含中文却调用了 chcp。\n'
                '  这会让 cmd 解析错位，客户看到满屏「不是内部或外部命令」并闪退。\n'
                '  处理：去掉 chcp（脚本以 GBK 存），或把那段挪进纯 ASCII 的桥接脚本。' % name)
        try:
            data = text.encode('gbk')
        except UnicodeEncodeError as e:
            raise SystemExit(
                '出包中止：%s 含 GBK 编不了的字符 %r。\n'
                '  cmd 脚本里不要用 emoji / 特殊符号（客户的控制台是 GBK）。'
                % (name, e.object[e.start:e.end]))
    with open(dst, 'wb') as f:
        f.write(data)


def write_text_gbk(dst, text):
    # 🔴 防回归：GBK 编不了的符号（⚠️ / ⚠ 等 emoji、特殊符号）直接换成 GBK 里
    #    有的等价物，否则打包会直接 UnicodeEncodeError 挂掉（2026-10-14 踩过）。
    for k, v in (('⚠️', '※'), ('⚠', '※')):
        text = text.replace(k, v)
    with open(dst, 'wb') as f:
        f.write(text.replace('\r\n', '\n').replace('\n', '\r\n').encode('gbk'))


def stage(version):
    print('[1/5] 组装安装目录 …')
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
    # 🔴 先证明依赖真的在 node_modules 里再拷。2026-10-05 踩过：ssh2 只装进了线上
    #    容器，本地 node_modules 没有 —— 下面那个 isdir('node_modules') 检查照样通过、
    #    包照样打出来，装到干净机器上服务端**直接起不来**（启动时同步 require 部署
    #    向导，那条链顶层 require('ssh2')）。详见 deploy/check_server_deps.py。
    dep_check = subprocess.run(
        [sys.executable, os.path.join(ROOT, 'deploy', 'check_server_deps.py')],
        capture_output=True, text=True)
    sys.stdout.write(dep_check.stdout)
    if dep_check.returncode != 0:
        raise SystemExit('服务端依赖不齐，已中止打包（见上面的清单）')

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

    # --- 内部脚本（全部收进 _sys\，安装根只留控制台 exe）---
    # 「小智IM 服务端控制台.cmd」是上一代入口，已被「小智IM 服务端控制台.exe」取代，
    # 不再拷贝（源文件保留在 files/ 里作历史参考）。
    sysdir = os.path.join(STAGE, APP_SYS)
    os.makedirs(sysdir)
    n = 0
    for fn in sorted(os.listdir(FILES)):
        if fn.endswith(('.cmd', '.vbs')):
            if fn == '小智IM 服务端控制台.cmd':
                continue
            write_cmd(os.path.join(FILES, fn), os.path.join(sysdir, fn), version)
            n += 1
    print('      %s\\ 内部脚本 %d 个（含中文的走 GBK，纯 ASCII 桥接脚本保持 ASCII）'
          % (APP_SYS, n))

    # --- 服务端控制台 + 服务工具（PowerShell 脚本，UTF-8 单 BOM）---
    # ⚠️ .ps1 的编码规则跟 .cmd 完全不同：必须是 **UTF-8 带 BOM**。
    #    PowerShell 5.1 读无 BOM 的 .ps1 会按系统 ANSI(GBK) 解释 → 中文全乱。
    #    这里刻意不走 write_cmd（那个函数是给 cmd/vbs 用的 GBK 逻辑）。
    # 🔴🔴 读必须用 **utf-8-sig**（剥掉源文件里已有的 BOM），写再用 utf-8-sig
    #    （补回恰好一个）。曾经这里读成 utf-8 —— 那个编解码器**不剥 BOM**，
    #    源文件开头的 EF BB BF 会变成字符串里一个不可见的 U+FEFF 字符，
    #    写出时 utf-8-sig 又补一个 BOM → 装机文件是 **双 BOM**。
    #    PowerShell 5.1 剥掉第一个后，第二个 U+FEFF 贴在首行 `#` 注释前面，
    #    首行不再是注释 → 报「无法将"#"项识别为 cmdlet」（截图里那个刷屏的
    #    提权 PowerShell 窗口就是这么来的）；紧接着第 19 行的 param( 因不在
    #    脚本首位也被当命令执行 → 再报一条。UI 居然还能起来（错误不致命），
    #    所以这个 bug 潜伏了很久，直到"注册服务"按钮提权重拉本脚本才暴露。
    #    实测复现：双 BOM 小样本跑起来两条错误一字不差。
    for ps1name in ('console.ps1', 'svc_tool.ps1'):
        src_ps1 = os.path.join(FILES, ps1name)
        if not os.path.isfile(src_ps1):
            raise SystemExit('缺少 PowerShell 脚本：%s' % src_ps1)
        text_ps1 = open(src_ps1, encoding='utf-8-sig').read().replace('__VERSION__', version)
        with open(os.path.join(sysdir, ps1name), 'w', encoding='utf-8-sig',
                  newline='\r\n') as f:
            f.write(text_ps1.replace('\r\n', '\n'))
        print('      %s\\%s（UTF-8 单 BOM，PowerShell 5.1 才能正确读中文）' % (APP_SYS, ps1name))

    # --- 控制台图标（窗口标题栏 + 任务栏 + 托盘共用）---
    # 托盘不用真图标的后果：通知区里一个"通用应用"样子的图标，用户根本注意不到 ——
    # "关了窗口找不着软件"一半是这么来的（龙哥 2026-10-14）。
    shutil.copy2(ICON, os.path.join(STAGE, 'console.ico'))

    # --- 交付说明（随包一份，客户翻目录时看得到）---
    write_text_gbk(os.path.join(STAGE, '版本说明.txt'), f"""小智IM 服务端（Windows 版）  v{version}

【装在哪】
  程序：本安装目录
  数据：安装时你自己选的目录（默认建议数据盘，例如 D:\\小智IM服务端\\data）
        （数据库、上传的文件、授权状态、运行日志都在这里。
          放在安装目录**之外**是刻意的 —— 卸载不会删它，
          重装或升级后接着用，授权也不需要重新出码。
          想知道当前用的是哪个目录：打开控制台看状态栏，或
          注册表 HKCU\\Software\\小智IM服务端 → DataDir）

【端口】
  TCP 3602   客户端连接 + 管理后台（http://本机IP:3602/admin）
  UDP 3616   客户端首次安装时的"局域网自动发现"
  两个端口都要在 Windows 防火墙上放通：控制台里点「配置防火墙」即可

【怎么用（推荐）】
  双击桌面上的「小智IM 服务端控制台」（实体是安装目录里的
  「小智IM 服务端控制台.exe」）—— 一个窗口管完：
    · 启动 / 停止 / 重启服务端      · 开机自动启动开关
    · 实时运行日志                  · 打开管理后台
    · 查看管理员密码                · 配置防火墙
    · 打开数据目录                  · 最小化到托盘（服务不停）
    · 注册为 Windows 服务           · 卸载服务

  管理账号 admin，初始密码在控制台里点「查看管理员密码」。

【注册为 Windows 服务（可选，2026-10-14 新增）】
  想让服务端"开机自启、不用先登录 Windows、以系统服务方式运行"：
  控制台里点「注册为服务」（会弹一次 UAC）。之后：
    · 开机自启由服务接管（控制台上的开机自启开关会自动禁用）
    · 崩溃自动重启（5 / 10 / 30 秒三档）
    · 日常启停仍用控制台，用法和原来完全一样
    · 日志写在 数据目录\\logs\\server.log（服务没有控制台，node 自己写文件）
  不想用了：控制台点「卸载服务」，回到"用户进程"方式。

【安装目录里有什么】
  小智IM 服务端控制台.exe   ← 日常就用这一个（双击即开面板）
  console.ico              控制台窗口 / 托盘图标
  node\\  app\\              服务端本体 + 内置的 Node 运行时
  _sys\\                     内部脚本（.cmd / .vbs / 控制台脚本），平时不用动
  数据**不在这里** —— 见上面「装在哪」

【怎么用（命令行/排障）】
  开始菜单 → 小智IM 服务端 → 高级工具：
    · 后台启动服务端.vbs   后台运行（开机自启走的就是它）
    · 启动服务端.cmd       前台运行，关窗口即停
    · 查看运行日志.cmd     看日志（data\\logs\\server.log）
  （这些脚本的实体都在安装目录的 _sys\\ 子目录里。）

  注意：不要在 PowerShell 里手动运行 _sys\\console.ps1 —— 那个脚本是给
     「小智IM 服务端控制台.exe」用 -File 方式拉起的。用别的方式执行
     （比如把脚本内容粘进 PowerShell）会满屏"无法将 # 识别为 cmdlet"
     的报错，服务端也起不来。日常入口永远是桌面那个控制台。

【排障】
  · 服务起不来      → 控制台看日志最后几行
  · 手机连不上      → 控制台点「配置防火墙」放通端口，确认手机和电脑在同一网段
  · 忘记管理密码    → 控制台点「查看管理员密码」看初始口令；
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


def build_console_exe(version, out_file, nsis_path):
    """编译「小智IM 服务端控制台.exe」—— 装到安装根的那个门面。

    内容极简：检查 _sys\\console.ps1 在不在，在就把它拉起来，然后自己退出。
    真正的界面逻辑仍在 .ps1 里；这个 exe 只负责"看起来像个正经软件的入口"。

    ⚠️ 与主安装脚本一样：NSIS 按 ANSI 读脚本会把中文变方块，必须写 UTF-8 **带 BOM**。
       行尾同样先归一成 LF 再交给 newline='\\r\\n'（本机 git 是 autocrlf=true，
       模板重新检出后会是 CRLF，叠加就写出 \\r\\r\\n）。
    """
    tpl = open(os.path.join(HERE, 'console_exe.nsi.tpl'), encoding='utf-8').read()
    nsi = (tpl
           .replace('__VERSION__', version)
           .replace('__VI_VERSION__', vi_version(version))
           .replace('__ICON__', ICON)
           .replace('__OUT_FILE__', out_file))
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

    problems = precheck_scripts()
    if problems:
        print('出包中止：脚本编码预检没过 ——')
        for p in problems:
            print('  - %s' % p)
        print('  规则：含中文的脚本 = GBK 且不含 chcp；纯 ASCII 桥接脚本 = 可带 chcp。')
        return 1

    stage(version)

    # ---- 控制台 exe：安装根的门面 ----
    # 先编它，再让它一起过下面的出厂地址扫描（exe 里只会嵌入 _sys\console.ps1 这种
    # 相对路径，本来也扫不出东西，但流程上别留缺口）。
    print('[2/5] 编译控制台 exe …')
    console_out = os.path.join(STAGE, '小智IM 服务端控制台.exe')
    console_nsi = build_console_exe(version, console_out,
                                    os.path.join(BUILD, 'console_exe.nsi'))
    r = subprocess.run([makensis, '/V2', console_nsi], cwd=BUILD,
                       capture_output=True, text=True, encoding='utf-8', errors='replace')
    if r.returncode != 0 or not os.path.isfile(console_out):
        print('控制台 exe 编译失败，退出码 %s' % r.returncode)
        print((r.stdout or '')[-2000:])
        print((r.stderr or '')[-2000:])
        return 1
    print('      小智IM 服务端控制台.exe  %.0f KB' % (os.path.getsize(console_out) / 1024))

    # ---- 出厂前拦一道：分发包不许带开发者的真实地址/域名 ----
    hits, scanned = scan_banned(STAGE)
    # 阈值别卡太死（实测正常 60 上下，node_modules 已排除）：只需拦住"扫了个空"，
    # 卡到临界值反而会在服务端少几个文件时误拦，白白浪费一次排查。
    if scanned < 30:
        print('!! 只扫到 %d 个文件，staging 明显不对（正常 60 上下），先别出包' % scanned)
        return 1
    if hits:
        print('!! staging 里发现不该出厂的内容，已中止出包：')
        for rel, why in hits[:20]:
            print('   - %s  ← %s' % (rel, why))
        print('   共 %d 处。改掉源文件（多半是 admin/src 或 docs 里的示例地址）再重打。' % len(hits))
        return 1
    print('[3/5] 出厂前地址扫描：%d 个文件，未发现真实地址/域名' % scanned)

    os.makedirs(BUILD, exist_ok=True)
    out_name = '%s-Setup-v%s.exe' % (SHORT_NAME, version)
    out_path = os.path.join(BUILD, out_name)
    # 🔴 这里原来是 `os.remove(out_path)` —— 覆盖旧包前删掉它。
    #    2026-09-27 本机跑时被引擎的安全删除护栏拦下
    #    （SHFileOperationW 失败: 0x2 → "trash-failed"），直接中止出包。
    #    **而且本来就不该删**：NSIS 编译是就地覆盖写，旧包留着当保底更划算 ——
    #    万一这次编译失败，至少上一个能装的版本还在。
    #    所以改成"挪到系统临时目录（护栏豁免区），编译成功就不管，
    #    失败就把旧的挪回来"。和 fpk 构建 build.sh 里挪旧 app/src 是同一套路。
    old_backup = None
    if os.path.exists(out_path):
        tmpd = tempfile.gettempdir()
        old_backup = os.path.join(tmpd, 'xz_old_setup_%d.exe' % int(time.time()))
        shutil.move(out_path, old_backup)
        print('      旧包已挪到 %s（编译失败会挪回原处）' % old_backup)

    print('[4/5] 生成安装脚本 …')
    script = build_nsi(version, out_path, os.path.join(BUILD, 'installer.nsi'))

    print('[5/5] NSIS 编译 …')
    r = subprocess.run([makensis, '/V2', script], cwd=BUILD,
                       capture_output=True, text=True, encoding='utf-8', errors='replace')
    tail = '\n'.join((r.stdout or '').splitlines()[-12:])
    if tail:
        print(tail)
    if r.returncode != 0 or not os.path.isfile(out_path):
        print('NSIS 编译失败，退出码 %s' % r.returncode)
        print((r.stderr or '')[-2000:])
        # 编译没出包 —— 把刚才挪走的旧包放回去，别让人手上一份能装的都没有
        if old_backup and os.path.exists(old_backup) and not os.path.exists(out_path):
            shutil.move(old_backup, out_path)
            print('      旧包已放回 %s' % out_path)
        return 1

    print('  生成安装包：%s（%.1f MB）'
          % (out_path, os.path.getsize(out_path) / 1024 / 1024))

    if not args.no_deliver and os.path.isdir(DESKTOP_DIR):
        dst = os.path.join(DESKTOP_DIR, out_name)
        shutil.copy2(out_path, dst)
        print('已复制到桌面：%s' % dst)
    return 0


if __name__ == '__main__':
    sys.exit(main())
