# -*- coding: utf-8 -*-
"""重启服务端并验证 M1 盘点接口真的起来了。

🔴 两个踩过的坑（都在这份脚本里修掉了，别再犯）：
  1. `sudo -S cd /path && docker compose ...` **不生效**：cd 是 shell 内建命令，
     sudo 执行不了它，于是整条命令静默什么都没做（容器时间纹丝不动，
     看着像"重启了但没生效"）。要用 `docker compose -f <绝对路径>`。
  2. 路由前缀是 **/api/stocktake**，不是 /api/inventory（文件名才叫 inventory）。
     拿错路径去探会得到 404，会被误判成"没部署上"。

判据（401 = 路由挂上了只是没登录；404 = 路由没挂 = 代码没生效）：
  GET /api/stocktake/zones     → 期望 401
  GET /api/client/apps         → 期望 401
  POST /api/stocktake/sheet    → 期望 401
"""
import os
import sys
import time

import paramiko

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from fnos_auth import HOST, PASS, USER  # noqa: E402

COMPOSE = '/vol1/@appcenter/xiaozhi-im/docker/docker-compose.yaml'


def run(c, cmd, timeout=180):
    _, so, se = c.exec_command("echo '%s' | sudo -S %s" % (PASS, cmd), timeout=timeout)
    out = so.read().decode('utf-8', 'replace').strip()
    err = se.read().decode('utf-8', 'replace').strip()
    # 飞牛上登录用户 pblpan 没有 home 目录，ssh 每次都会吐这一句。
    # **必须过滤**：不过滤的话"致命错误扫描"会把这句当成错误，
    # 结论直接变红（2026-09-19 就被它骗了一次）。
    noise = ('Could not chdir', 'password for')
    err = '\n'.join(l for l in err.splitlines()
                    if not any(n.lower() in l.lower() for n in noise)).strip()
    out = '\n'.join(l for l in out.splitlines()
                    if 'Could not chdir' not in l).strip()
    if err:
        out = (out + '\n[stderr] ' + err[:500]).strip()
    return out


def main():
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(HOST, username=USER, password=PASS, timeout=20)
    ok = True
    try:
        print('=== 重启前 ===')
        print(run(c, 'docker ps --filter name=^xiaozhi-im$ --format "{{.Status}}"'))

        print('\n=== 重启 ===')
        print(run(c, 'docker compose -f %s restart xiaozhi-im 2>&1 | tail -5' % COMPOSE))
        time.sleep(12)

        print('\n=== 重启后（Up 时间应该很短）===')
        after = run(c, 'docker ps --filter name=^xiaozhi-im$ --format "{{.Status}}"')
        print(after)
        if 'Up 9 hours' in after or 'Up 1' in after and 'seconds' not in after:
            print('  ⚠️ 容器看起来没重启（Up 时间没变）')

        print('\n=== 致命错误扫描 ===')
        bad = run(c, "docker logs --tail 250 xiaozhi-im 2>&1 | "
                     "grep -iE 'MODULE_NOT_FOUND|Cannot find module|SyntaxError|"
                     "SQLITE_ERROR|no such table|Error: listen' | head -10")
        print(bad.strip() if bad.strip() else '✅ 无致命错误')
        ok = ok and not bad.strip()

        print('\n=== 判据：路由挂上没（401=挂上了，404=没挂）===')
        for m, p in (('GET', '/api/stocktake/zones'),
                     ('GET', '/api/client/apps'),
                     ('POST', '/api/stocktake/sheet')):
            code = run(c, "curl -s -m 8 -o /dev/null -w '%%{http_code}' -X %s "
                          "http://127.0.0.1:3602%s" % (m, p))
            code = code.strip()
            good = code in ('401', '403')
            print('  %-5s %-24s HTTP %-4s %s' % (m, p, code, 'OK' if good else '<<<'))
            ok = ok and good

        print('\n=== 【可选】有 token 时再验一次"能写库"（不只是路由在）===')
        print('  （没设 ADMIN_PASSWORD_FOR_PROBE 环境变量就会跳过，'
              '**不影响上面的结论**）')
        # 登录拿 token，再真的建一个点位：证明不只是"路由在"，而是**能写库**
        tok = run(c, "curl -s -m 8 -X POST http://127.0.0.1:3602/api/auth/login "
                     "-H 'Content-Type: application/json' "
                     "-d '{\"username\":\"admin\",\"password\":\"%s\"}' "
                     "| python3 -c \"import sys,json;"
                     "print(json.load(sys.stdin).get('token',''))\"" % os.environ.get('ADMIN_PASSWORD_FOR_PROBE', ''))
        print('  token 长度: %d' % len(tok.strip()))
        if tok.strip() and len(tok.strip()) > 20:
            r = run(c, "curl -s -m 8 -X POST http://127.0.0.1:3602/api/stocktake/zone "
                       "-H 'Authorization: Bearer %s' -H 'Content-Type: application/json' "
                       "-d '{\"zone_code\":\"M1PROBE\",\"zone_name\":\"部署自检点位\"}' "
                       "| head -c 300" % tok.strip())
            print('  建盘点位: %s' % r)
        else:
            print('  （没拿到 token，跳过写库验证 —— 需要管理员密码）')
    finally:
        c.close()
    print('\n结论：%s' % ('盘点接口已上线 ✅' if ok else '有问题 ❌'))
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
