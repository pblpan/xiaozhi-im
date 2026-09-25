#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
Windows 上「Dart 子进程能不能跑」的环境体检 —— 一条命令判断这台机器还能不能
`flutter test` / `flutter build`。

【为什么需要这个】
Dart 的 Process 实现（runtime/bin/process_win.cc）用的是**命名管道**
（`\\\\.\\Pipe\\dart_<uuid>_<n>`），而 Node/Python 用的是匿名管道（CreatePipe）。
于是会出现一种很坑的局面：**整台机器别的都好，只有 Dart 全家桶趴窝** ——
`flutter doctor` / `flutter test` / `flutter build` 全部报

    ProcessException: All pipe instances are busy
      (at ../../runtime/bin/process_win.cc:744)
    CreateFile failed 231

231 是 ERROR_PIPE_BUSY。**真正的原因不是管道忙**：某些安全软件（火绒 HipsDaemon、
跨设备/远控类驱动）会拦截"读命名管道里的数据"，并且把拒绝伪装成 231。
原生 Windows 的权限拒绝是 5（ACCESS_DENIED），不是 231 —— 这就是判别指纹。

【实测指纹】（本机 2026-09 故障时）
    服务端 PIPE_ACCESS_OUTBOUND + 客户端 FILE_READ_DATA   -> 231   ← Dart 的 stdin 管道，第一个挂
    服务端 PIPE_ACCESS_OUTBOUND + 客户端 GENERIC_READ      -> 231
    服务端 PIPE_ACCESS_INBOUND  + 客户端 GENERIC_WRITE     -> OK    ← Dart 的 stdout 管道
    服务端 PIPE_ACCESS_INBOUND  + 客户端 GENERIC_READ      -> 5     ← 正常的权限拒绝
    FILE_READ_ATTRIBUTES / SYNCHRONIZE / 0                 -> OK
=> 判据就一条：**能不能请求 FILE_READ_DATA**。

【怎么用】
    python client/tools/check_win_pipe.py
退出码 0 = 可以构建；非 0 = 环境被拦，先按提示处置再重试。

【修好之后怎么验】
重跑本脚本，看 `dart spawn` 那一项变成 ok=8 / 8 即可，不必去猜。
"""
import ctypes
import ctypes.wintypes as wt
import os
import re
import subprocess
import sys
import tempfile
import uuid

# ---------- Win32 ----------
k32 = ctypes.WinDLL('kernel32', use_last_error=True)

PIPE_ACCESS_INBOUND = 0x00000001
PIPE_ACCESS_OUTBOUND = 0x00000002
FILE_FLAG_OVERLAPPED = 0x40000000
GENERIC_READ = 0x80000000
GENERIC_WRITE = 0x40000000
FILE_READ_DATA = 0x00000001
FILE_READ_ATTRIBUTES = 0x00000080
SYNCHRONIZE = 0x00100000
OPEN_EXISTING = 3
INVALID = wt.HANDLE(-1).value

k32.CreateNamedPipeW.restype = wt.HANDLE
k32.CreateNamedPipeW.argtypes = [
    wt.LPCWSTR, wt.DWORD, wt.DWORD, wt.DWORD, wt.DWORD, wt.DWORD, wt.DWORD, wt.LPVOID]
k32.CreateFileW.restype = wt.HANDLE
k32.CreateFileW.argtypes = [
    wt.LPCWSTR, wt.DWORD, wt.DWORD, wt.LPVOID, wt.DWORD, wt.DWORD, wt.HANDLE]

# 疑犯名单（名字里带这些字的进程，出错时会点名）
SUSPECTS = ('hips', 'hr', 'huorong', '360', 'qqpcmgr', 'qhsafe', 'kxe', 'kav',
            'mcafee', 'symantec', 'crowdstrike', 'sophos', 'trend', 'eset',
            'mi', 'xiaomi', 'lenovo', 'gameviewer', 'sunlogin', 'todesk',
            'anydesk', 'rustdesk', 'clink', 'sangfor', 'edr')

results = []


def record(name, ok, detail, hint=''):
    results.append((name, ok, detail, hint))
    mark = '✅' if ok else '🔴'
    print('  %s %-52s %s' % (mark, name, detail))
    if not ok and hint:
        print('       ↳ %s' % hint)


def try_named_pipe(label, srv_mode, cli_access):
    """建一个命名管道，立刻按指定访问权连上去。返回 (成功?, errno)。"""
    name = '\\\\.\\Pipe\\xiaozhi_pipechk_%s_1' % uuid.uuid4()
    h = k32.CreateNamedPipeW(name, srv_mode | FILE_FLAG_OVERLAPPED, 0,
                             1, 1024, 1024, 0, None)
    if h in (INVALID, -1):
        return False, ctypes.get_last_error(), 'CreateNamedPipeW 自己就失败了'
    c = k32.CreateFileW(name, cli_access, 0, None, OPEN_EXISTING, 0, None)
    err = 0 if c not in (INVALID, -1) else ctypes.get_last_error()
    if c not in (INVALID, -1):
        k32.CloseHandle(c)
    k32.CloseHandle(h)
    return (c not in (INVALID, -1)), err, ''


def anonymous_pipe_ok():
    """控制组：匿名管道（Node/Python 走这条）。它必须一直是好的，
    否则「全都红」说明不了任何问题 —— 那是脚本自己坏了。"""
    k32.CreatePipe.restype = wt.BOOL
    r, w = wt.HANDLE(), wt.HANDLE()
    if not k32.CreatePipe(ctypes.byref(r), ctypes.byref(w), None, 0):
        return False
    buf = ctypes.c_char_p(b'x')
    written = wt.DWORD(0)
    k32.WriteFile(w, buf, 1, ctypes.byref(written), None)
    got = ctypes.create_string_buffer(8)
    read = wt.DWORD(0)
    ok = bool(k32.ReadFile(r, got, 1, ctypes.byref(read), None)) and read.value == 1
    k32.CloseHandle(r)
    k32.CloseHandle(w)
    return ok


def find_dart():
    """在几个常见位置找 dart.exe；找不到就跳过那一项（不许假绿）。"""
    here = os.path.dirname(os.path.abspath(__file__))
    cands = [
        os.path.join(here, '..', '..', '..', 'tools', 'flutter', 'bin', 'cache',
                     'dart-sdk', 'bin', 'dart.exe'),
    ]
    for c in cands:
        c = os.path.normpath(c)
        if os.path.exists(c):
            return c
    return None


DART_PROBE = r'''
import 'dart:io';
void main() {
  var ok = 0;
  for (var i = 0; i < 8; i++) {
    try { if (Process.runSync('cmd.exe', ['/c', 'echo ok']).exitCode == 0) ok++; }
    catch (_) {}
  }
  print('SPAWN_RESULT ok=$ok / 8');
}
'''


def run_dart_probe(dart):
    fd, path = tempfile.mkstemp(suffix='.dart', prefix='xiaozhi_spawnchk_')
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as f:
            f.write(DART_PROBE)
        p = subprocess.run([dart, 'run', path], capture_output=True,
                           text=True, encoding='utf-8', errors='replace', timeout=180)
        m = re.search(r'SPAWN_RESULT ok=(\d+) / 8', p.stdout or '')
        if m:
            return int(m.group(1)), 8, (p.stdout or '').strip()
        return None, 8, (p.stderr or p.stdout or '').strip()[:400]
    except Exception as e:                                   # noqa: BLE001
        return None, 8, '%s: %s' % (type(e).__name__, e)
    finally:
        try:
            os.remove(path)
        except OSError:
            pass


def running_processes():
    try:
        out = subprocess.run(['tasklist', '/FO', 'CSV', '/NH'],
                             capture_output=True, text=True, encoding='gbk',
                             errors='replace', timeout=60).stdout
    except Exception:                                        # noqa: BLE001
        return []
    names = sorted({ln.split('","')[0].strip('"').lower()
                    for ln in out.splitlines() if '","' in ln})
    return [n for n in names if any(s in n for s in SUSPECTS)]


def main():
    print('Windows 命名管道 / Dart 子进程体检\n')
    print('① 控制组（匿名管道，Node/Python 走这条）')
    control = anonymous_pipe_ok()
    record('匿名管道 CreatePipe 读写', control,
           'OK' if control else 'FAIL',
           '控制组都挂了 → 不是命名管道的事，脚本结论不可信，先查别的')
    if not control:
        print('\n⚠️ 控制组失败，「下面全红」不能证明是命名管道的问题。')
        return 2

    print('\n② 命名管道（Dart 走这条）')
    ok_w, err_w, extra_w = try_named_pipe('stdout 型', PIPE_ACCESS_INBOUND, GENERIC_WRITE)
    record('INBOUND  服务端 + GENERIC_WRITE 客户端（= Dart stdout 管道）',
           ok_w, extra_w or ('OK' if ok_w else 'err=%d' % err_w))

    ok_r, err_r, extra_r = try_named_pipe('stdin 型', PIPE_ACCESS_OUTBOUND, GENERIC_READ)
    record('🔴 OUTBOUND 服务端 + GENERIC_READ 客户端（= Dart stdin 管道）',
           ok_r, extra_r or ('OK' if ok_r else 'err=%d' % err_r),
           '231 = ERROR_PIPE_BUSY，是安全软件伪造的拒绝（原生权限拒绝是 5）')

    ok_d, err_d, extra_d = try_named_pipe('读数据', PIPE_ACCESS_OUTBOUND, FILE_READ_DATA)
    record('OUTBOUND 服务端 + FILE_READ_DATA（真正读管道数据）',
           ok_d, extra_d or ('OK' if ok_d else 'err=%d' % err_d),
           '这一项红 = 「读命名管道」被整体拦掉，Dart 无解')

    ok_a, err_a, _ = try_named_pipe('只读属性', PIPE_ACCESS_OUTBOUND, FILE_READ_ATTRIBUTES)
    record('OUTBOUND 服务端 + FILE_READ_ATTRIBUTES（不读数据，作对照）',
           ok_a, 'OK' if ok_a else 'err=%d' % err_a)

    print('\n③ 真跑一次 dart（8 次 Process.runSync）')
    dart = find_dart()
    dart_ok = None
    if not dart:
        record('dart.exe 定位', False, '没找到，跳过（不给假绿）',
               '用 --dart 指定，或把 Flutter SDK 放到 tools/flutter')
    else:
        n, total, detail = run_dart_probe(dart)
        if n is None:
            record('dart spawn', False, '跑不出结果：%s' % detail)
            dart_ok = False
        else:
            dart_ok = (n == total)
            record('dart spawn', dart_ok, 'ok=%d / %d' % (n, total))

    print('\n④ 本机在跑的相关进程（出错时点名用）')
    sus = running_processes()
    print('  ' + (', '.join(sus) if sus else '(没发现名单里的进程)'))

    print('\n' + '=' * 66)
    bad = [r for r in results if not r[1]]
    if not bad:
        print('✅ 环境正常 —— flutter test / flutter build 可以跑。')
        return 0
    print('🔴 环境被拦：%d 项失败' % len(bad))
    for n, _, d, _h in bad:
        print('   - %s  (%s)' % (n, d))
    print("""
处置（按顺序，每步做完重跑本脚本，看 ③ 是否变成 ok=8 / 8）：
  1) 临时退出安全软件（火绒：托盘右键「退出」；HipsDaemon 是它的主动防御），重跑。
     好了 → 在火绒「防护中心」给 flutter/dart 目录加信任，或关掉命名管道类防护。
  2) 还在 → 退掉跨设备/远控类软件（小米电脑管家 MiService/PcClipboard、
     联想 LenovoSmartService、GameViewerService、向日葵/ToDesk 等），重跑。
  3) 还在 → 重启机器再试一次（驱动 hook 卡死时重启能恢复）。
  4) 都无效 → 换一台机器构建，或把 Flutter SDK 放到没装这些软件的机器上。

⚠️ 别去 "taskkill /IM dart.exe" 之类地折腾 —— 那个报错跟残留进程无关，
   dart 进程压根不存在；本脚本 ③ 会证明这一点（每次都是干净进程）。""")
    return 1


if __name__ == '__main__':
    sys.exit(main())
