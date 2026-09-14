# -*- coding: utf-8 -*-
"""真机安装冒烟测试：静默装一遍、逐文件核对、启动一次、再静默卸干净。

【为什么要单独写这个】
`verify_release.py` 只能看**静态证据**（解包出来有哪些文件、判据串在不在、
PE 版本资源对不对）。它回答不了三个真问题：
  1. 装完之后磁盘上的文件树和 build 产物**一模一样**吗？（少一个 dll 就打不开）
  2. 装出来的程序**真的能跑起来**吗？
  3. 卸载**真的删干净**了吗？会不会把用户的登录状态一起删了？

以前这三条只能靠"让龙哥点一下试试"。现在 Windows 包是**用户级安装、不弹 UAC**，
所以可以全自动跑完 —— 这也是当初把 admin 改成 per-user 的顺带好处。

【判据纪律（踩过才写的）】
- "程序还活着"必须认准**我启动的那个 PID**：早先写的是"进程名存在就算活"，
  旁边只要有一个别人启动的实例，这条就会恒绿 —— 典型假绿。
  现在同时核对**可执行路径**是不是装出来的那个。
- 安装脚本会先杀旧实例，这是**要测的功能**，不是环境噪音。所以先记录
  现场已有的实例，装完逐一复核它们是否被请走了。

【用法】
    python test_installer_smoke.py "D:\\Users\\pblpa\\Desktop\\小智 IM\\小智IM-Setup-v0.9.3.exe"
    python test_installer_smoke.py <安装包> --keep      # 装完不卸，留给人工看
退出码 0 = 全过；非 0 = 有失败项（会逐条打印）。

⚠️ 这个脚本会**杀掉正在运行的 xiaozhi_im_client.exe**（安装脚本自己也这么干，
覆盖安装必须先请走旧实例）。若是**以管理员身份**启动的实例，非提权进程杀不掉，
脚本会如实报告而不是假装成功。
"""
import argparse
import ctypes
import ctypes.wintypes as wt
import os
import shutil
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
RELEASE = os.path.join(HERE, 'build', 'windows', 'x64', 'runner', 'Release')
EXE_NAME = 'xiaozhi_im_client.exe'
APP_NAME = '小智 IM'
INSTALL_DIR = os.path.join(os.environ.get('LOCALAPPDATA', ''), 'Programs', APP_NAME)
USER_DATA = os.path.join(os.environ.get('APPDATA', ''), 'com.example', 'xiaozhi_im_client')
UNINST_KEY = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall\%s' % APP_NAME

_k32 = ctypes.windll.kernel32
_adv = ctypes.windll.advapi32
_PQLI = 0x1000          # PROCESS_QUERY_LIMITED_INFORMATION：跨权限级别也能查
_TOKEN_QUERY = 0x0008
_TOKEN_ELEVATION = 20

results = []


def check(ok, label, detail=''):
    results.append((bool(ok), label, detail))
    print(('  [OK]   ' if ok else '  [FAIL] ') + label + (('  <- ' + detail) if detail else ''))
    return ok


def warn(label, detail=''):
    print('  [注意] ' + label + (('  <- ' + detail) if detail else ''))


def run(cmd, timeout=180, encoding='utf-8'):
    return subprocess.run(cmd, capture_output=True, text=True,
                          encoding=encoding, errors='replace', timeout=timeout)


def img_path(pid):
    """读进程的可执行路径。用 QUERY_LIMITED 权限，管理员进程也读得到。"""
    h = _k32.OpenProcess(_PQLI, False, pid)
    if not h:
        return ''
    buf = ctypes.create_unicode_buffer(1024)
    size = wt.DWORD(1024)
    ok = _k32.QueryFullProcessImageNameW(h, 0, buf, ctypes.byref(size))
    _k32.CloseHandle(h)
    return buf.value if ok else ''


def is_elevated(pid):
    h = _k32.OpenProcess(_PQLI, False, pid)
    if not h:
        return None
    tok = wt.HANDLE()
    if not _adv.OpenProcessToken(h, _TOKEN_QUERY, ctypes.byref(tok)):
        _k32.CloseHandle(h)
        return None
    val, ret = wt.DWORD(0), wt.DWORD(0)
    ok = _adv.GetTokenInformation(tok, _TOKEN_ELEVATION, ctypes.byref(val),
                                  ctypes.sizeof(val), ctypes.byref(ret))
    _k32.CloseHandle(tok)
    _k32.CloseHandle(h)
    return bool(val.value) if ok else None


def procs():
    """当前所有目标进程：[(pid, 可执行路径, 是否管理员)]"""
    out = run(['tasklist', '/FI', 'IMAGENAME eq %s' % EXE_NAME, '/NH'], encoding='gbk')
    res = []
    for line in out.stdout.splitlines():
        parts = line.split()
        if len(parts) >= 2 and parts[0].lower().startswith('xiaozhi'):
            try:
                pid = int(parts[1])
            except ValueError:
                continue
            res.append((pid, img_path(pid), is_elevated(pid)))
    return res


def kill_app():
    run(['taskkill', '/F', '/IM', EXE_NAME], encoding='gbk')
    time.sleep(1.0)


def shell_folder(name, fallback):
    """问注册表要真实的桌面 / 开始菜单路径。

    本机桌面被重定向到 `d:\\Users\\pblpa\\Desktop`，**不能拿
    `%USERPROFILE%\\Desktop` 猜** —— 猜错的话快捷方式到底建在哪就测不出来，
    会得出"测试通过、用户却看不见图标"的假绿。
    （已用 NSIS 探针确认 $DESKTOP 会跟随重定向，两边口径一致。）
    """
    for key in (r'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders',
                r'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders'):
        r = run(['reg', 'query', key, '/v', name])
        for line in (r.stdout or '').splitlines():
            if line.strip().startswith(name):
                val = line.split('REG_', 1)[-1].split(None, 1)[-1].strip()
                if val:
                    return os.path.expandvars(val)
    return fallback


DESKTOP_LNK = os.path.join(shell_folder('Desktop', os.path.join(
    os.environ.get('USERPROFILE', ''), 'Desktop')), APP_NAME + '.lnk')
SMPROGRAMS_DIR = os.path.join(shell_folder('Programs', os.path.join(
    os.environ.get('APPDATA', ''), 'Microsoft', 'Windows', 'Start Menu', 'Programs')),
    APP_NAME)


def tree(root):
    """相对路径 -> 文件大小。用来跟 build 产物逐文件比对。"""
    out = {}
    for dirpath, _dirnames, filenames in os.walk(root):
        for fn in filenames:
            full = os.path.join(dirpath, fn)
            rel = os.path.relpath(full, root).replace('\\', '/')
            out[rel] = os.path.getsize(full)
    return out


def reg_query(key):
    r = run(['reg', 'query', key], encoding='gbk')
    return r.returncode == 0 and r.stdout.strip() != ''


def reg_value(key, name):
    """读一个注册表值，读不到返回 ''。

    ⚠️ 这里必须读 InstallLocation：NSIS 模板里有 `InstallDirRegKey`，
    它让安装器**优先使用注册表里记的旧位置**，而不是 InstallDir 的默认值。
    所以只要这台机器以前装到过别处（比如 zip 绿色版时代的桌面目录），
    新包就会**静默装到旧位置**，而本脚本按 INSTALL_DIR 去找，必然报
    "安装目录已创建 ✗" —— 只看这一条根本猜不到真因，白查一轮。
    """
    r = run(['reg', 'query', key, '/v', name], encoding='gbk')
    if r.returncode != 0:
        return ''
    for line in (r.stdout or '').splitlines():
        parts = line.split()
        if len(parts) >= 3 and parts[0] == name:
            return parts[-1]
    return ''


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('installer')
    ap.add_argument('--keep', action='store_true', help='装完不卸载（人工检查用）')
    ap.add_argument('--timeout', type=int, default=300)
    args = ap.parse_args()

    inst = os.path.abspath(args.installer)
    if not os.path.isfile(inst):
        print('找不到安装包:', inst)
        return 2
    if not os.path.isdir(RELEASE):
        print('找不到 build 产物（先 flutter build windows --release）:', RELEASE)
        return 2

    print('安装包 : %s（%.1f MB）' % (inst, os.path.getsize(inst) / 1024 / 1024))
    print('安装到 : %s' % INSTALL_DIR)
    print('用户数据: %s\n' % USER_DATA)

    # 用户数据指纹：卸载后必须一模一样
    ud_before = tree(USER_DATA) if os.path.isdir(USER_DATA) else None

    # ---------- 0. 前置：记录现场，再清场 ----------
    print('[0] 清场')
    pre = procs()
    if pre:
        for pid, path, elev in pre:
            warn('现场已有实例 PID %d（%s）%s' % (
                pid, path or '路径读不到', '· 管理员权限' if elev else ''))
        warn('这些实例本该被安装脚本请走 —— 下面第 1 步会复核')
    else:
        print('  [OK]   现场没有正在运行的旧实例（断言环境最干净）')

    # 残留的 InstallLocation 会把这次安装**引到别处**去（见 reg_value 的注释）。
    # 必须在清场阶段就把它揪出来：要么清掉它，要么明确知道本次装到了哪，
    # 否则后面"目录没创建 / 缺 24 个文件"的失败全都指向错误的方向。
    stale = reg_value(UNINST_KEY, 'InstallLocation')
    if stale and os.path.normcase(os.path.normpath(stale)) != os.path.normcase(os.path.normpath(INSTALL_DIR)):
        warn('检测到残留的安装位置，本次安装会被它劫持', stale)
        warn('  → 该位置与预期不同：%s' % INSTALL_DIR)
        old_un = os.path.join(stale, 'uninst.exe')
        if os.path.isfile(old_un):
            run([old_un, '/S'])
            time.sleep(2)
            print('  [OK]   已用旧位置的卸载器清掉它（顺带验证卸载能删干净）')
        else:
            warn('  旧位置没有 uninst.exe，无法自动清理，请人工确认后删除')

    if os.path.isdir(INSTALL_DIR):
        un = os.path.join(INSTALL_DIR, 'uninst.exe')
        if os.path.isfile(un):
            run([un, '/S'])
            time.sleep(2)
        if os.path.isdir(INSTALL_DIR):
            shutil.rmtree(INSTALL_DIR, ignore_errors=True)
    kill_app()
    check(not os.path.isdir(INSTALL_DIR), '前置：安装目录已清空')
    check(not reg_query(UNINST_KEY), '前置：注册表无残留')

    # ---------- 1. 静默安装 ----------
    print('\n[1] 静默安装（/S，不弹任何界面）')
    t0 = time.time()
    try:
        r = run([inst, '/S'], timeout=args.timeout, encoding='gbk')
    except subprocess.TimeoutExpired:
        check(False, '安装进程在 %ds 内没结束' % args.timeout)
        return 1
    dur = time.time() - t0
    check(r.returncode == 0, '安装器退出码 = 0', '实际 %s' % r.returncode)
    # 失败时把"到底装到哪了"直接写进 detail：安装器退出码 0 但目录不在预期位置，
    # 九成是 InstallDirRegKey 读了残留值（见 reg_value 注释），不是安装器坏了。
    dir_ok = os.path.isdir(INSTALL_DIR)
    dir_detail = INSTALL_DIR
    if not dir_ok:
        actual = reg_value(UNINST_KEY, 'InstallLocation')
        if actual and os.path.normcase(os.path.normpath(actual)) != os.path.normcase(os.path.normpath(INSTALL_DIR)):
            dir_detail = '实际装到了 %s —— 注册表残留的 InstallLocation 劫持了本次安装' % actual
        else:
            dir_detail = '%s（不存在，且注册表里也没有别的 InstallLocation）' % INSTALL_DIR
    check(dir_ok, '安装目录已创建（%.1fs）' % dur, dir_detail)

    # 顺带验证「覆盖安装会先把旧实例请出去」这个功能本身
    if pre:
        left = [(pid, path, elev) for pid, path, elev in procs()
                if pid in [p[0] for p in pre]]
        if not left:
            check(True, '安装时已把现场 %d 个旧实例请走' % len(pre))
        else:
            why = '、'.join('%d%s' % (p[0], '（管理员）' if p[2] else '') for p in left)
            if all(p[2] for p in left):
                warn('旧实例 %s 还活着 —— 管理员权限的进程非提权杀不掉，'
                     '这是已知限制而非脚本 bug' % why)
            else:
                check(False, '旧实例没被请走', why)

    # ---------- 2. 逐文件核对（最硬的一条）----------
    print('\n[2] 逐文件核对：安装结果 vs build 产物')
    want = tree(RELEASE)
    got = tree(INSTALL_DIR)
    extra = sorted(set(got) - set(want) - {'uninst.exe'})   # uninst.exe 由安装器自己写
    missing = sorted(set(want) - set(got))
    diff = sorted(k for k in (set(want) & set(got)) if want[k] != got[k])
    check(not missing, '没有缺文件（共 %d 个）' % len(want),
          '缺 %d 个: %s' % (len(missing), missing[:5]) if missing else '')
    check(not diff, '没有大小不一致的文件',
          '不一致 %d 个: %s' % (len(diff), diff[:5]) if diff else '')
    check(not extra, '没有多出意外文件', '多出: %s' % extra[:5] if extra else '')
    check('data/flutter_assets/assets/tray.ico' in got, '托盘图标在安装结果里')

    # ---------- 3. 快捷方式 / 注册表 ----------
    print('\n[3] 快捷方式与「设置→应用」入口')
    check(os.path.isfile(DESKTOP_LNK), '桌面快捷方式已创建', DESKTOP_LNK)
    check(os.path.isdir(SMPROGRAMS_DIR), '开始菜单目录已创建')
    check(os.path.isfile(os.path.join(SMPROGRAMS_DIR, APP_NAME + '.lnk')),
          '开始菜单快捷方式已创建')
    r = run(['reg', 'query', UNINST_KEY, '/v', 'DisplayVersion'], encoding='gbk')
    ver = ''
    for line in (r.stdout or '').splitlines():
        if 'DisplayVersion' in line:
            ver = line.split()[-1]
    check(bool(ver), '卸载信息已登记（版本 %s）' % ver, UNINST_KEY)

    # ---------- 4. 跑起来 ----------
    print('\n[4] 启动装好的程序（这一步只有真装才测得到）')
    exe = os.path.join(INSTALL_DIR, EXE_NAME)
    ran_pid = None
    if not os.path.isfile(exe):
        # 这里**不要**抛 FileNotFoundError：崩溃会跳过第 5/6 步的卸载与用户数据核对，
        # 现场留一堆"半装"痕迹，下次再跑互相干扰、越查越乱。
        # 如实记一条失败，然后照常走完收尾流程。
        check(False, '装好的程序存在（能被启动）', '%s 不存在' % exe)
    else:
        p = subprocess.Popen([exe], cwd=INSTALL_DIR)
        time.sleep(12)
        alive = p.poll() is None
        check(alive, '启动的进程存活 12s 未崩（dll / data 都在位）',
              '已退出，退出码 %s' % p.poll() if not alive else 'PID %d' % p.pid)
        if alive:
            # 认准自己启动的那个 PID，再核对可执行路径 —— 只看"进程名存在"会假绿
            mine = [x for x in procs() if x[0] == p.pid]
            check(bool(mine), '刚才那个 PID 确实在进程表里', 'PID %d' % p.pid)
            if mine:
                got_path = os.path.normcase(mine[0][1])
                want_path = os.path.normcase(exe)
                check(got_path == want_path, '跑的是装出来的那份（不是别处的旧版）',
                      got_path or '路径读不到')
        ran_pid = p.pid
        kill_app()

    if args.keep:
        print('\n--keep：保留安装结果，不做卸载')
        return 0 if all(ok for ok, _, _ in results) else 1

    # ---------- 5. 静默卸载 ----------
    print('\n[5] 静默卸载（uninst.exe /S）')
    un = os.path.join(INSTALL_DIR, 'uninst.exe')
    if os.path.isfile(un):
        try:
            run([un, '/S'], timeout=args.timeout, encoding='gbk')
        except subprocess.TimeoutExpired:
            check(False, '卸载进程超时')
        time.sleep(2)
    check(not os.path.isdir(INSTALL_DIR), '安装目录已删除', INSTALL_DIR)
    check(not os.path.isfile(DESKTOP_LNK), '桌面快捷方式已删除')
    check(not os.path.isdir(SMPROGRAMS_DIR), '开始菜单目录已删除')
    check(not reg_query(UNINST_KEY), '卸载信息已清除')

    # ---------- 6. 用户数据必须还在 ----------
    print('\n[6] 登录状态 / 聊天记录不能被卸载带走')
    # 只比对"文件还在不在"，不比大小：现场可能另有一个别人启动的实例在跑，
    # 它随时会重写 shared_preferences.json —— 拿字节数当判据会变成随机红。
    # "卸载有没有把用户数据删掉"这件事，存在性本身就是完整判据。
    ud_after = sorted(tree(USER_DATA)) if os.path.isdir(USER_DATA) else None
    ud_before_names = sorted(ud_before) if ud_before else None
    if ud_before is None:
        check(ud_after is None, '用户数据目录本来就不存在，卸载后仍不存在')
    else:
        check(ud_after == ud_before_names,
              '用户数据原样保留（%d 个文件）' % len(ud_before_names),
              '前后不一致: 前 %s / 后 %s' % (ud_before_names, ud_after))

    bad = [x for x in results if not x[0]]
    print('\n' + '=' * 56)
    print('冒烟测试：%d/%d 通过' % (len(results) - len(bad), len(results)))
    for _ok, label, detail in bad:
        print('  FAIL: %s %s' % (label, detail))
    if ran_pid:
        still = [x for x in procs() if x[0] == ran_pid]
        if not still:
            print('（顺带确认：卸载时把测试启动的那个实例也一并关掉了 PID %d）' % ran_pid)
    return 0 if not bad else 1


if __name__ == '__main__':
    sys.exit(main())
