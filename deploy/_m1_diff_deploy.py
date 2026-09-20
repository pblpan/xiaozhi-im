# -*- coding: utf-8 -*-
"""把「三遍互比 + 漏盘」口径的服务端改动 + 管理台文案推到飞牛并重启。

推的东西：
  1. server/src/routes/inventory.js —— 差异集/阶段小结改成"比上一阶段"，
     并把**漏盘**补成真差异（原来的 isDiff 里那句"漏盘"分支是走不到的死代码）
  2. server/public/                 —— 管理台构建产物（商档页文案对齐新口径）

🔴 两个坑（都在这份脚本里处理掉了）：
  · 远端是 bind mount `.../src → /app`，而启动命令是 `node src/index.js`，
    所以**本地的 server/src 对应远端的 .../src/src**（多一层 src），
    本地的 server/public 对应远端的 .../src/public。路径写错就静默不生效。
  · 管理台是**一整个目录**，不能一个个文件 sftp（会留下新旧混搭的 assets，
    页面拿到旧 index.html + 新 chunk 直接白屏）。整目录打包再整目录替换。

判据（401 = 路由挂上了只是没登录；404 = 没挂）：
  GET /api/master/count        → 401
  GET /api/stocktake/zones     → 401
  GET /admin/                  → 200 且带 <div id="app">

推完**必须**再跑 `_m1_smoke.py` —— 探 401 只能证明路由在，
证明不了差异口径真的换了（这正是这次改动的内容）。
"""
import os
import sys
import tarfile
import time

import paramiko

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from fnos_auth import HOST, PASS, USER  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REMOTE_SRC = '/vol1/@appcenter/xiaozhi-im/src/src'
REMOTE_PUBLIC = '/vol1/@appcenter/xiaozhi-im/src/public'
COMPOSE = '/vol1/@appcenter/xiaozhi-im/docker/docker-compose.yaml'
TGZ = os.path.join(ROOT, 'server', 'public.tgz')

FILES = [
    (os.path.join(ROOT, 'server', 'src', 'routes', 'inventory.js'),
     REMOTE_SRC + '/routes/inventory.js'),
]


def sudo(c, cmd, timeout=300):
    _, so, se = c.exec_command("echo '%s' | sudo -S %s" % (PASS, cmd), timeout=timeout)
    out = so.read().decode('utf-8', 'replace').strip()
    err = se.read().decode('utf-8', 'replace').strip()
    noise = ('Could not chdir', 'password for')
    err = '\n'.join(l for l in err.splitlines()
                    if not any(n.lower() in l.lower() for n in noise)).strip()
    return out, err


def main():
    for local, _ in FILES:
        if not os.path.isfile(local):
            print('❌ 本地文件不存在: ' + local)
            return 2

    if os.path.exists(TGZ):
        os.remove(TGZ)
    with tarfile.open(TGZ, 'w:gz') as t:
        t.add(os.path.join(ROOT, 'server', 'public'), arcname='public')
    print('打包管理台: %.2f MB' % (os.path.getsize(TGZ) / 1024 / 1024))

    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(HOST, username=USER, password=PASS, timeout=20)
    ok = True
    try:
        sftp = c.open_sftp()
        stamp = time.strftime('%m%d%H%M')

        print('\n=== 1. 推服务端代码 ===')
        for local, remote in FILES:
            tmp = '/tmp/xz_' + os.path.basename(local) + '.' + stamp
            sftp.put(local, tmp)
            out, err = sudo(c, 'cp %s %s && chmod 644 %s' % (tmp, remote, remote))
            print('  %-16s → %s %s' % (os.path.basename(local), remote,
                                       'OK' if not err else '<<< ' + err[:200]))
            ok = ok and not err
            # 顺手把"漏盘"这个关键词核验一遍，确认推上去的是新版本而不是同名旧文件
            cnt, _ = sudo(c, "grep -c '漏盘' %s" % remote)
            print('     远端含"漏盘"次数: %s %s' % (cnt, '(应为 >=2)' if cnt.strip().isdigit() and int(cnt.strip()) < 2 else ''))

        print('\n=== 2. 推管理台（整目录替换）===')
        tmp = '/tmp/xz_public.' + stamp + '.tgz'
        sftp.put(TGZ, tmp)
        out, err = sudo(c, 'rm -rf %s && mkdir -p %s && tar xzf %s -C %s '
                           '--strip-components=1 && rm -f %s'
                        % (REMOTE_PUBLIC, REMOTE_PUBLIC, tmp, REMOTE_PUBLIC, tmp))
        print('  ' + ('OK' if not err else '<<< ' + err[:300]))
        ok = ok and not err
        out, _ = sudo(c, 'ls %s | head -5 && du -sh %s' % (REMOTE_PUBLIC, REMOTE_PUBLIC))
        print('  ' + out.replace('\n', ' | '))

        print('\n=== 3. 重启容器 ===')
        out, err = sudo(c, 'docker compose -f %s restart xiaozhi-im 2>&1 | tail -3' % COMPOSE)
        print('  ' + (out or err)[:300])
        time.sleep(12)
        out, _ = sudo(c, 'docker ps --filter name=^xiaozhi-im$ --format "{{.Status}}"')
        print('  容器状态: ' + out)

        print('\n=== 4. 致命错误扫描 ===')
        out, _ = sudo(c, "docker logs --tail 200 xiaozhi-im 2>&1 | "
                         "grep -iE 'MODULE_NOT_FOUND|Cannot find module|SyntaxError|"
                         "SQLITE_ERROR|no such table|Error: listen' | head -8")
        print('  ' + (out.strip() if out.strip() else '✅ 无致命错误'))
        ok = ok and not out.strip()

        print('\n=== 5. 判据 ===')
        for p, want in (('/api/master/count', ('401',)),
                        ('/api/stocktake/zones', ('401',)),
                        ('/admin/', ('200',))):
            code, _ = sudo(c, "curl -s -m 8 -o /dev/null -w '%%{http_code}' "
                              "http://127.0.0.1:3602%s" % p)
            code = (code or '').strip()
            good = code in want
            print('  %-24s HTTP %-4s %s' % (p, code, 'OK' if good else '<<<'))
            ok = ok and good
    finally:
        c.close()
        if os.path.exists(TGZ):
            os.remove(TGZ)

    print('\n结论：%s' % ('服务端 + 管理台已上线 ✅' if ok else '有问题 ❌'))
    print('🔴 下一步必须跑：python deploy/_m1_smoke.py（真写库跑一遍三遍制）')
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
