# -*- coding: utf-8 -*-
"""
回归测试：安装目录里的每个 .cmd / .vbs，在真实 cmd 下跑一遍，**不许出现解析报错**。

为什么需要这个测试（真实事故）：
    win-server 的脚本原来是 UTF-8 + 第二行 `chcp 65001`。cmd.exe 是按**字节偏移**
    逐行读批处理文件的，中途切代码页会让它对多字节字符的长度判断错位，于是从
    **注释行中间**开始解析 —— 中文注释的后半截被当成命令执行。客户装完看到的是：

        'xx值外面永远看不到（经典坑）。' is not recognized as an internal or external command

    然后窗口闪退。这个报错在开发机上"偶尔"能复现，极易被当成偶发问题放过；
    所以必须有一条**每次都跑、跑真实 cmd** 的断言盯着它。

本测试的安全设计（默认就想好了，别删）：
    - 全程在 %TEMP% 的副本里跑，**不碰已安装的实例**；
    - 副本里的端口一律改成 3912、UDP 3917、数据目录指向副本自己；
    - 跑之前先在副本里搜"3602"，还有残留就直接中止 —— 免得把线上服务杀了；
    - 跑之前记录线上 3602 的 PID，跑完核对它没变。

用法：
    python test_scripts_parse.py                 # 用 build/stage
    python test_scripts_parse.py --stage <目录>
"""
import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_STAGE = os.path.join(HERE, 'build', 'stage')

TEST_PORT = 3912
TEST_DISCOVER = 3917
PROD_PORT = 3602

# cmd 解析错位的指纹。GBK / UTF-8 两种解出来的样子都收进来。
BAD_MARKS = [
    'is not recognized as an internal or external command',
    '不是内部或外部命令',
    'The system cannot find the path specified',
    '系统找不到指定的路径',
    'The filename, directory name, or volume label syntax is incorrect',
    '文件名、目录名或卷标语法不正确',
]

PASS, FAIL = [], []


def check(cond, name, extra=''):
    if cond:
        PASS.append(name)
        print('  \u2713 %s' % name)
    else:
        FAIL.append(name)
        print('  \u2717 %s   %s' % (name, extra))
    return cond


def port_pid(port):
    """谁在 LISTENING 这个端口，返回 PID 集合。"""
    out = subprocess.run(['netstat', '-ano'], capture_output=True).stdout.decode('gbk', 'replace')
    pids = set()
    for line in out.splitlines():
        if ':%d ' % port in line and 'LISTENING' in line:
            pids.add(line.split()[-1])
    return pids


def kill_port(port):
    for pid in port_pid(port):
        subprocess.run(['taskkill', '/F', '/PID', pid], capture_output=True)


def both_decodings(data):
    """cmd 的输出可能是 GBK（脚本自身）也可能是 UTF-8（node），两种都看一遍。"""
    return (data.decode('gbk', 'replace') + '\n' + data.decode('utf-8', 'replace'))


def scan_bad(data):
    text = both_decodings(data)
    for m in BAD_MARKS:
        if m in text:
            return m
    return None


def prepare_copy(stage, work):
    """把安装目录原样复制到 %TEMP%，并把端口/数据目录改到隔离值。"""
    dst = os.path.join(work, 'install')
    shutil.copytree(stage, dst)

    envf = os.path.join(dst, '_sys', '_env.cmd')
    t = open(envf, 'rb').read().decode('gbk')
    t = t.replace('set "PORT=%d"' % PROD_PORT, 'set "PORT=%d"' % TEST_PORT)
    t = t.replace(r'%LOCALAPPDATA%\小智IM服务端\data',
                  os.path.join(work, 'data'))
    t += '\r\nset "DISCOVER_PORT=%d"\r\n' % TEST_DISCOVER
    open(envf, 'wb').write(t.encode('gbk'))

    # _stop_silent.cmd 刻意不 call _env.cmd（卸载时数据目录可能已经没了）：
    # 2026-10-05 起它自己从 data\.env 读 PORT、读不到回落写死的 3602，
    # 数据目录也是写死的 LOCALAPPDATA。两处都要按到隔离值，漏一处 =
    # 测试副本把**线上服务杀掉**（2026-10-13 真实发生：本机 3602 被杀）。
    stopf = os.path.join(dst, '_sys', '_stop_silent.cmd')
    t = open(stopf, 'rb').read().decode('gbk')
    t = t.replace(r'%LOCALAPPDATA%\小智IM服务端\data',
                  os.path.join(work, 'data'))
    t = t.replace('set "KILLPORT=%d"' % PROD_PORT,
                  'set "KILLPORT=%d"' % TEST_PORT)
    open(stopf, 'wb').write(t.encode('gbk'))
    return dst


def assert_isolated(dst):
    """副本里不该再有任何指向线上端口 / 真实数据目录的引用。

    只扫 .cmd / .vbs —— 那是**会被执行**的东西，残留一个就可能杀掉线上服务。
    🔴 2026-10-13 教训：只查 `:3602` 漏掉了 `_stop_silent.cmd` 的
    `set "KILLPORT=3602"`（等号不是冒号）—— 隔离替换落空 + 自查没拦住，
    测试副本把本机线上服务杀了。现在三样都查（包括 _stop_silent.cmd
    改写后的成品：prepare_copy 理应把它的两处都改掉，改不干净这里拦）。
    前端 js 里的 `http://192.168.1.100:3602` 是管理台帮助文案里的示例地址，
    属于业务内容，不该跟着测试端口走。
    """
    prod_marks = [
        ':%d' % PROD_PORT,                          # netstat / URL 里的端口
        'KILLPORT=%d' % PROD_PORT,                  # _stop_silent.cmd 的杀端口
        'PORT=%d' % PROD_PORT,                      # set "PORT=3602"
        r'%LOCALAPPDATA%\小智IM服务端\data',         # 写死的真实数据目录
    ]
    leftovers = []
    for root, _, files in os.walk(dst):
        for fn in files:
            if not fn.lower().endswith(('.cmd', '.vbs')):
                continue
            p = os.path.join(root, fn)
            try:
                text = open(p, 'rb').read().decode('gbk', 'replace')
            except Exception:
                continue
            for mark in prod_marks:
                start = 0
                while True:
                    i = text.find(mark, start)
                    if i < 0:
                        break
                    leftovers.append('%s [%s]: %s' % (
                        os.path.relpath(p, dst), mark,
                        text[max(0, i - 30):i + len(mark) + 10].strip()))
                    start = i + 1
    return leftovers


def run_script(dst, name, timeout, env, logfile=None):
    """执行脚本，返回 (rc, 合并输出)。

    ⚠️ 不能用 subprocess.run(capture_output=True)：Windows 上它超时之后还会
       再调一次 communicate() 去收残余输出，而 node 这类**孙进程**一直攥着
       继承来的管道不放 —— 于是永久阻塞，整个测试卡死（踩过一次，9 分钟没动）。
       改成"输出重定向到文件 + Popen.wait(timeout)"：超时可靠，输出照样收得到。

    ⚠️ 用 CREATE_NEW_CONSOLE 而不是共享控制台：脚本里的 `timeout` 命令在
       stdin 被重定向时会直接报错返回，于是"等 30 秒端口就绪"那个循环会
       瞬间空转 30 圈、误判成启动失败。给一个真控制台才和客户双击时一致。
       代价是测试期间会有窗口闪现，忍了。
    """
    path = os.path.join(dst, '_sys', name)
    argv = ['wscript.exe', path] if name.lower().endswith('.vbs') else ['cmd', '/c', path]
    if logfile:
        argv.append(logfile)

    fd, out_file = tempfile.mkstemp(prefix='xzps_', suffix='.out')
    os.close(fd)
    rc = -1
    with open(out_file, 'wb') as f:
        p = subprocess.Popen(argv, stdout=f, stderr=subprocess.STDOUT,
                             stdin=subprocess.DEVNULL, env=env,
                             creationflags=subprocess.CREATE_NEW_CONSOLE)
        try:
            rc = p.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            # /T 连子进程一起收 —— 否则 node 会留下来占着隔离端口
            subprocess.run(['taskkill', '/F', '/T', '/PID', str(p.pid)], capture_output=True)
            rc = -1
    data = b''
    if os.path.isfile(out_file):
        data = open(out_file, 'rb').read()
        try:
            os.unlink(out_file)
        except OSError:
            # 脚本里 `start` 出来的子进程会继承这个文件句柄，一时删不掉。
            # 文件在 %TEMP% 里，留给系统清理即可 —— 硬删会抛 WinError 32 把测试打断。
            pass
    return rc, data


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--stage', default=DEFAULT_STAGE)
    ap.add_argument('--limit', type=int, default=0,
                    help='只跑前 N 个脚本（调试用，避免一跑就是三分钟）')
    args = ap.parse_args()
    stage = os.path.abspath(args.stage)

    if not os.path.isdir(stage):
        raise SystemExit('找不到要测的安装目录：%s\n（先跑一次 pack_server_win.py 生成 build/stage）' % stage)

    prod_before = port_pid(PROD_PORT)
    print('测试前：线上 %d 端口 PID = %s' % (PROD_PORT, sorted(prod_before) or '（没在跑）'))

    work = tempfile.mkdtemp(prefix='xz_parse_test_')
    print('隔离副本：%s\n' % work)
    try:
        dst = prepare_copy(stage, work)
        os.makedirs(os.path.join(work, 'data', 'logs'), exist_ok=True)

        print('[1] 隔离自查：副本里不能再有指向线上端口的引用')
        leftovers = assert_isolated(dst)
        check(not leftovers, '副本与线上端口已完全隔离',
              '；'.join(leftovers[:3]) if leftovers else '')
        if leftovers:
            print('\n中止：隔离没做干净，继续跑有杀掉线上服务的风险。')
            return 1

        env = dict(os.environ)

        print('\n[2] 逐个脚本跑真实 cmd，断言无解析报错')
        # (脚本, 额外参数, 超时秒, 说明)
        # 超时的（前台跑 node 会一直不返回）用 -1 表示"预期超时，取已抓输出"
        CASES = [
            ('_env.cmd', None, 8, '内部：铺环境变量'),
            ('查看管理员密码.cmd', None, 8, '查看管理员密码'),
            ('配置防火墙.cmd', None, 8, '非管理员应只提示、不报错'),
            ('打开管理后台.cmd', None, 8, '打开管理后台（会弹浏览器，正常）'),
            ('查看运行日志.cmd', None, 12, '查看运行日志（会开新窗口）'),
            ('后台启动服务端.vbs', None, 12, 'VBS 隐藏启动'),
            ('首次启动并打开后台.cmd', None, 45, '装完自动启动（等就绪 + 开浏览器）'),
            ('查看管理员密码.cmd', None, 8, '服务起来后再查一次密码'),
            # 放在服务起来之后 —— 否则日志还不存在，测不到 type 那条路径
            ('_ascii_show_log.cmd', 'LOG', 12, '桥接：UTF-8 日志打控制台'),
            ('_ascii_stamp.cmd', 'LOG', 10, '桥接：往日志写 ISO 时间戳行'),
            ('停止服务端.cmd', None, 8, '停止服务端'),
            ('_stop_silent.cmd', None, 8, '静默停止'),
            ('_hidden.cmd', None, 10, '隐藏启动（前台跑 node，预期超时）'),
            ('启动服务端.cmd', None, 10, '前台启动（另开窗口跑 node）'),
            ('_ascii_run_node.cmd', None, 10, '桥接：UTF-8 跑 node（预期超时）'),
        ]
        if args.limit:
            CASES = CASES[:args.limit]
            print('  （--limit %d：只跑前 %d 个）' % (args.limit, args.limit))

        logfile = os.path.join(work, 'data', 'logs', 'server.log')
        for name, extra, timeout, desc in CASES:
            path = os.path.join(dst, '_sys', name)
            if not os.path.isfile(path):
                check(False, '%s（%s）' % (name, desc), '文件不存在')
                continue
            arg = logfile if extra == 'LOG' else None
            rc, out = run_script(dst, name, timeout, env, arg)
            mark = scan_bad(out)
            note = ''
            if rc == -1:
                note = '（预期超时，已取到 %d 字节输出）' % len(out)
            elif rc != 0:
                note = '（退出码 %d）' % rc
            detail = mark or (both_decodings(out).strip().splitlines() or [''])[-1][:90]
            check(mark is None, '%s（%s）%s' % (name, desc, note), detail)
            time.sleep(0.5)

        print('\n[3] 日志编码自查：没有 BOM 之外的乱码')
        if args.limit:
            print('  （--limit 模式只跑前几个脚本，不会启动服务，跳过）')
        elif os.path.isfile(logfile):
            raw = open(logfile, 'rb').read()
            check(raw[:3] == b'\xef\xbb\xbf', '日志首部有 UTF-8 BOM（记事本不乱码）')
            check('\ufffd' not in raw.decode('utf-8', 'replace'), '日志无替换字符（未串入 GBK 字节）')
        else:
            check(False, '日志文件已生成', '没有 %s' % logfile)

        print('\n[4] 线上服务未被波及')
        prod_after = port_pid(PROD_PORT)
        check(prod_after == prod_before, '线上 %d 端口进程未变' % PROD_PORT,
              '之前 %s → 现在 %s' % (sorted(prod_before), sorted(prod_after)))
    finally:
        kill_port(TEST_PORT)
        time.sleep(0.5)
        shutil.rmtree(work, ignore_errors=True)

    print('\n' + '=' * 60)
    print('通过 %d 项，失败 %d 项' % (len(PASS), len(FAIL)))
    if FAIL:
        for f in FAIL:
            print('  失败：%s' % f)
        return 1
    print('全部通过')
    return 0


if __name__ == '__main__':
    sys.exit(main())
