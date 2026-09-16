# -*- coding: utf-8 -*-
"""小智IM 服务端（Windows 版）安装后的端到端冒烟测试。

用法：
    # 对**已安装**的服务端跑一遍冒烟
    python deploy/win-server/smoke_server.py

    # 先静默安装（覆盖安装也行）再冒烟
    python deploy/win-server/smoke_server.py --install "deploy/win-server/build/小智IM服务端-Setup-v0.17.0.exe"

    # 顺便在最后卸载（默认不卸，留着方便手动看）
    python deploy/win-server/smoke_server.py --uninstall

═══ 为什么要走脚本而不是我手动敲命令 ═══════════════════════════════════
1) 启动链路（VBS → _hidden.cmd → _env.cmd → node）**必须端到端跑一次**。
   「进程活着」证明不了什么 —— 端口没起来照样是个活进程。
   所以这里的成功判据是「HTTP 200 + 能登录」，而不是「进程还存在」。
2) 最关键的一条：**用 data\\.env 里的口令真去登录一次**。
   客户拿到的就是完成页上那串密码，如果它对不上，等于系统装好了人也进不去。
3) 收尾要干净：按端口停进程（不 taskkill /IM node.exe），端口必须真的释放。

退出码：0 = 全部通过；1 = 有失败项。
"""
import argparse
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request

if hasattr(sys.stdout, 'reconfigure'):
    sys.stdout.reconfigure(encoding='utf-8')

SHORT_NAME = '小智IM服务端'
def installed_dir():
    """实际安装目录 —— 先问注册表，问不到再用默认值。

    别写死 %LOCALAPPDATA%\\Programs：NSIS 的 `InstallDirRegKey` 会在重新安装时
    沿用注册表里上次的 InstallLocation，客户完全可能把服务端装到 D 盘
    （实测就是这样）。写死的话脚本会去一个空目录里找文件，然后报"缺 N 个文件"，
    看着像安装失败，其实只是找错了地方。
    """
    try:
        import winreg
        with winreg.OpenKey(
                winreg.HKEY_CURRENT_USER,
                r'Software\Microsoft\Windows\CurrentVersion\Uninstall\XiaozhiIMServer') as k:
            path, _ = winreg.QueryValueEx(k, 'InstallLocation')
            if path and os.path.isdir(path):
                return path
    except OSError:
        pass
    return os.path.join(os.environ.get('LOCALAPPDATA', ''), 'Programs', SHORT_NAME)


INSTALL_DIR = installed_dir()
DATA_DIR = os.path.join(os.environ.get('LOCALAPPDATA', ''), SHORT_NAME, 'data')
PORT = 3602

FAILS = []
OKS = []


def ok(name, extra=''):
    OKS.append(name)
    print('  \u2713 %s%s' % (name, ('  [' + extra + ']') if extra else ''))


def bad(name, extra=''):
    FAILS.append(name)
    print('  \u2717 %s%s' % (name, ('  [' + extra + ']') if extra else ''))


def check(cond, name, extra=''):
    (ok if cond else bad)(name, extra)
    return cond


def http(method, path, body=None, token=None, timeout=8):
    """返回 (状态码, 响应文本)。连不上返回 (None, 错误)。"""
    url = 'http://127.0.0.1:%d%s' % (PORT, path)
    data = None
    headers = {}
    if body is not None:
        data = json.dumps(body).encode('utf-8')
        headers['Content-Type'] = 'application/json'
    if token:
        headers['Authorization'] = 'Bearer ' + token
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, r.read().decode('utf-8', 'replace')
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode('utf-8', 'replace')
    except Exception as e:
        return None, str(e)


def listening():
    """端口是否在 LISTENING（用 netstat，不依赖第三方库）"""
    try:
        out = subprocess.run(['netstat', '-ano'], capture_output=True, text=True,
                             encoding='gbk', errors='replace', timeout=20).stdout
    except Exception:
        return False
    for line in out.splitlines():
        if ':%d ' % PORT in line and 'LISTENING' in line:
            return True
    return False


def read_env(path):
    kv = {}
    with open(path, encoding='utf-8') as f:
        for line in f:
            if not line.strip() or line.lstrip().startswith('#'):
                continue
            if '=' in line:
                k, v = line.split('=', 1)
                kv[k.strip()] = v.strip()
    return kv


def run_cmd(script, cwd=None, timeout=60):
    """用 cmd.exe 跑一个 .cmd（Python 侧 subprocess，不走被安全策略拦的通道）

    输出按 UTF-8 解码：脚本里 `chcp 65001` 之后，它 echo 出去的就是 UTF-8 字节。
    """
    return subprocess.run(['cmd', '/c', script], cwd=cwd, capture_output=True,
                          text=True, encoding='utf-8', errors='replace', timeout=timeout)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--install', default=None, help='安装包路径；给了就先静默安装')
    ap.add_argument('--uninstall', action='store_true', help='冒烟结束后卸载')
    ap.add_argument('--force', action='store_true',
                    help='允许在"已经装过"的机器上跑（结论会失真，自担其责）')
    args = ap.parse_args()

    print('=' * 70)
    print('小智IM 服务端（Windows）端到端冒烟')
    print('安装目录：%s' % INSTALL_DIR)
    print('数据目录：%s' % DATA_DIR)
    print('=' * 70)

    # ---------- 0. 需要的话先静默安装 ----------
    if args.install:
        # 这台机器上已经装过就别跑了：本脚本验的是「**全新安装**」，里面有断言
        # 依赖"data\.env 是这次新生成的""日志里有「已创建管理员账号」"。数据目录
        # 已存在时（本机装过、或上次冒烟留下的）这些必然失败，报出来的错看着像
        # **安装包坏了**，其实只是机器不干净 —— 比不跑更危险。
        if os.path.isfile(os.path.join(DATA_DIR, '.env')) and not args.force:
            print('\n!! 这台机器上已经装过了：%s 存在。' % os.path.join(DATA_DIR, '.env'))
            print('   本脚本验的是「全新安装」，在这种机器上跑会报出一堆**假失败**。')
            print('   要么先卸载并清掉数据目录，要么加 --force 自担其责。')
            return 2
        print('[0] 静默安装 %s' % os.path.basename(args.install))
        r = subprocess.run([args.install, '/S'], capture_output=True, text=True,
                           timeout=300)
        check(r.returncode == 0, '安装器退出码为 0', '实际 %s' % r.returncode)
        time.sleep(3)

    # ---------- 1. 文件清单 ----------
    print('\n[1] 安装文件')
    if not check(os.path.isdir(INSTALL_DIR), '安装目录存在'):
        print('\n安装目录不存在，先装一次。')
        return 1
    must = ['node/node.exe', 'app/src/index.js', 'app/public/index.html',
            'app/package.json', 'app/tools/init-env.js',
            '_env.cmd', '_hidden.cmd', '_stop_silent.cmd',
            '启动服务端.cmd', '后台启动服务端.vbs', '停止服务端.cmd',
            '打开管理后台.cmd', '查看管理员密码.cmd', '配置防火墙.cmd',
            '设为开机自启.cmd', '取消开机自启.cmd', '首次启动并打开后台.cmd',
            '版本说明.txt', 'uninst.exe']
    for rel in must:
        p = os.path.join(INSTALL_DIR, rel.replace('/', os.sep))
        check(os.path.isfile(p), '有 %s' % rel,
              '%.1f KB' % (os.path.getsize(p) / 1024) if os.path.isfile(p) else '')
    nm = os.path.join(INSTALL_DIR, 'app', 'node_modules')
    check(os.path.isdir(nm) and len(os.listdir(nm)) > 50,
          'node_modules 已随包（不是空壳）',
          '%d 个包' % len(os.listdir(nm)) if os.path.isdir(nm) else '')

    # ---------- 2. 数据目录与口令 ----------
    print('\n[2] 数据目录与配置')
    env_file = os.path.join(DATA_DIR, '.env')
    if not check(os.path.isfile(env_file), '生成 data\\.env（含随机初始口令）'):
        return 1
    env = read_env(env_file)
    pw = env.get('ADMIN_PASSWORD', '')
    check(len(pw) >= 16, 'ADMIN_PASSWORD 是强随机口令（不是 admin123 之类）',
          '%d 位' % len(pw))
    check(pw != 'admin123' and pw != 'admin', '口令不是任何默认值')
    check(re.search(r'^[0-9a-f]{16,}$', pw) is not None, '口令形如随机 hex')
    check(len(env.get('JWT_SECRET', '')) >= 32, 'JWT_SECRET 已生成且够长',
          '%d 位' % len(env.get('JWT_SECRET', '')))
    check(not os.path.isfile(os.path.join(DATA_DIR, '.install-result.ini')),
          '安装中间文件 .install-result.ini 已清理')
    check(os.path.isdir(os.path.join(DATA_DIR, 'logs')), '有 logs 目录')

    # ---------- 3. 启动（走真实链路：VBS → _hidden.cmd → _env.cmd）----------
    print('\n[3] 启动服务端（VBS 隐藏启动，与开机自启同一条路径）')
    if listening():
        ok('服务端已在运行，跳过启动')
    else:
        vbs = os.path.join(INSTALL_DIR, '后台启动服务端.vbs')
        subprocess.run(['cmd', '/c', 'start', '', vbs], cwd=INSTALL_DIR,
                       capture_output=True, text=True, timeout=60)
        ready = False
        for _ in range(40):
            if listening():
                ready = True
                break
            time.sleep(1)
        check(ready, '服务端在 40 秒内起来并监听 %d 端口' % PORT)

    if not listening():
        print('\n端口没起来，后面没法继续。')
        log = os.path.join(DATA_DIR, 'logs', 'server.log')
        if os.path.isfile(log):
            print('--- 日志尾部 ---')
            print('\n'.join(open(log, encoding='utf-8', errors='replace').read().splitlines()[-25:]))
        return 1

    # ---------- 4. 接口 ----------
    print('\n[4] HTTP 接口')
    code, text = http('GET', '/api/health')
    check(code == 200, 'GET /api/health 返回 200', 'code=%s' % code)

    code, text = http('GET', '/api/client/bootstrap')
    ver = ''
    if code == 200:
        try:
            ver = json.loads(text).get('serverVersion', '')
        except Exception:
            pass
    check(code == 200, 'GET /api/client/bootstrap 返回 200', 'code=%s' % code)
    pkg_ver = json.load(open(os.path.join(INSTALL_DIR, 'app', 'package.json'),
                             encoding='utf-8'))['version']
    check(ver == pkg_ver, '服务端自报版本与包内 package.json 一致',
          'bootstrap=%s pkg=%s' % (ver, pkg_ver))

    code, _ = http('GET', '/api/admin/stats')
    check(code in (401, 403), '未带令牌访问管理接口被拒（鉴权生效）', 'code=%s' % code)

    # ---------- 5. 用 .env 里的口令真登录一次（最关键的一条）----------
    print('\n[5] 用 data\\.env 里的口令登录管理台接口')
    code, text = http('POST', '/api/auth/login',
                      {'username': env.get('ADMIN_USERNAME', 'admin'), 'password': pw})
    token = ''
    if code == 200:
        try:
            token = json.loads(text).get('token', '')
        except Exception:
            pass
    check(code == 200 and token != '',
          '拿 .env 里的初始口令能登录成功（客户拿完成页那串密码就能进）',
          'code=%s' % code)
    if token:
        code, _ = http('GET', '/api/admin/stats', token=token)
        check(code == 200, '带上令牌能访问管理接口', 'code=%s' % code)

    # ---------- 6. 日志 ----------
    print('\n[6] 日志')
    log = os.path.join(DATA_DIR, 'logs', 'server.log')
    # utf-8-sig：日志开头有 BOM（_hidden.cmd 首次创建时写的，为的是让记事本
    # 能正确识别 UTF-8 —— 没有它，客户打开日志是满屏乱码）
    txt = open(log, encoding='utf-8-sig', errors='replace').read() if os.path.isfile(log) else ''
    check(len(txt) > 0, '后台启动的日志确实写进了 data\\logs\\server.log', '%d 字节' % len(txt))
    # 启动标记是 _hidden.cmd 交给 _ascii_stamp.cmd 写的，形如
    #   ================ 2026-09-16 22:47:45 start v0.17.1 ================
    # 那行**只能是 ASCII**：_hidden.cmd 是 GBK，它 echo 中文出去就是往 UTF-8 的
    # 日志里混 GBK 字节，记事本里一片花屏。所以标记词是 `start` 不是「启动」。
    # （原先这里找的是「启动 v」，永远命中不了 —— 一条不可能通过的断言。）
    check(re.search(r'start v\d+\.\d+\.\d+', txt) is not None,
          '日志里有本次启动标记（_ascii_stamp 写的 start vX.Y.Z 行）')
    # 「中文没乱码」这条单独验：服务端自己打印的中文行必须原样可读。
    # 只判断"出现过中文"等于没判 —— 乱码后同样是"出现过中文"。
    check('服务端已启动: http://localhost' in txt,
          '日志里有服务端自己的中文启动行（中文没乱码 —— 编码统一为 UTF-8）')
    check('\ufffd' not in txt, '日志里没有替换字符（说明没有编码错位）')
    # 服务端首次建库时会打印「已创建管理员账号: admin / <口令>」。
    # 判据要精确到这句 —— 只判断"日志里出现过'管理员'"等于没判（任何管理台相关日志都含它）。
    m = re.search(r'已创建管理员账号:\s*(\S+)\s*/\s*(\S+)', txt)
    check(m is not None, '日志里有「已创建管理员账号」记录')
    if m:
        check(m.group(2) == pw,
              '日志里打印的口令与 data\\.env 里的一致（两处看到的是同一个，不会互相打架）')
    check('EADDRINUSE' not in txt, '日志里没有端口占用错误')

    # ---------- 7. 停止（走真实链路 _stop_silent.cmd）----------
    print('\n[7] 停止服务端（_stop_silent.cmd，安装/卸载用的同一条路径）')
    r = run_cmd(os.path.join(INSTALL_DIR, '_stop_silent.cmd'), cwd=INSTALL_DIR)
    stopped = False
    for _ in range(15):
        if not listening():
            stopped = True
            break
        time.sleep(1)
    check(stopped, '端口 %d 已释放（进程被停掉了）' % PORT)

    # ---------- 8. 可选卸载 ----------
    if args.uninstall:
        print('\n[8] 卸载')
        r = subprocess.run([os.path.join(INSTALL_DIR, 'uninst.exe'), '/S'],
                           capture_output=True, text=True, timeout=300)
        time.sleep(5)
        check(not os.path.isdir(INSTALL_DIR) or not os.listdir(INSTALL_DIR),
              '安装目录已清空')
        check(os.path.isdir(DATA_DIR) and os.path.isfile(env_file),
              '数据目录**保留**（卸载不删聊天记录/上传文件/授权）')
        run = subprocess.run(['reg', 'query',
                              r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run',
                              '/v', 'XiaozhiIMServer'],
                             capture_output=True, text=True, timeout=30)
        check(run.returncode != 0, '开机自启注册表项已清除')
    else:
        print('\n[8] 跳过卸载（要卸加 --uninstall）')

    print('\n' + '=' * 70)
    print('通过 %d 项，失败 %d 项' % (len(OKS), len(FAILS)))
    if FAILS:
        for f in FAILS:
            print('  ✗ ' + f)
        print('=' * 70)
        return 1
    print('全部通过')
    print('=' * 70)
    return 0


if __name__ == '__main__':
    sys.exit(main())
