# -*- coding: utf-8 -*-
"""给新飞牛签发并激活授权码。

流程：宿主机放 token 探针 → docker cp 进容器 → 容器内 node 现签管理员 token
→ 本地起 urllib 调 /api/license/activate。密码全程走环境变量。
"""
import os, sys, re, json, urllib.request, urllib.error
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from fnos_auth import HOST, USER, PASS
import paramiko

LICENSE = sys.argv[1]
DB = '/data/xiaozhi-im.db'

cli = paramiko.SSHClient()
cli.set_missing_host_key_policy(paramiko.AutoAddPolicy())
cli.connect(HOST, username=USER, password=PASS, timeout=15,
            banner_timeout=15, auth_timeout=15)


def ssh(cmd, timeout=120):
    _, o, e = cli.exec_command(cmd, timeout=timeout, get_pty=True)
    out = o.read().decode('utf-8', 'replace')
    err = e.read().decode('utf-8', 'replace')
    return out, err


# ① 把探针脚本送到宿主机 /tmp
sftp = cli.open_sftp()
sftp.put(os.path.join(HERE, '_admin_token_probe.js'), '/tmp/_admin_token_probe.js')
sftp.close()

# ② 进容器签 token
out, err = ssh('echo "%s" | sudo -S docker cp /tmp/_admin_token_probe.js '
               'xiaozhi-im:/app/_admin_token_probe.js && '
               'echo "%s" | sudo -S docker exec xiaozhi-im node /app/_admin_token_probe.js %s'
               % (PASS, PASS, DB))
tok = None
for line in out.splitlines():
    line = line.strip()
    if re.match(r'^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$', line):
        tok = line
        break
if not tok:
    print('签不到 token。输出：\n', out, '\n', err[:400])
    cli.close()
    sys.exit(1)
print('✓ 已现签管理员 token（长度 %d）' % len(tok))

# ③ 激活
url = 'http://%s:3602/api/license/activate' % HOST
body = json.dumps({'token': LICENSE}).encode()
req = urllib.request.Request(url, data=body, method='POST', headers={
    'Content-Type': 'application/json',
    'Authorization': 'Bearer ' + tok,
})
try:
    with urllib.request.urlopen(req, timeout=20) as r:
        print('激活返回 %d：%s' % (r.status, r.read().decode('utf-8', 'replace')))
except urllib.error.HTTPError as e:
    print('激活失败 HTTP %d：%s' % (e.code, e.read().decode('utf-8', 'replace')))

# ④ 回读状态
with urllib.request.urlopen('http://%s:3602/api/license' % HOST, timeout=20) as r:
    print('当前授权状态：', r.read().decode('utf-8', 'replace'))

cli.close()
