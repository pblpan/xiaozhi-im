# -*- coding: utf-8 -*-
"""把本地脚本拷进飞牛容器执行（避免命令行引号地狱）"""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from fnos_auth import HOST, USER, PASS
import paramiko

local = sys.argv[1]
remote = '/tmp/' + os.path.basename(local)

cli = paramiko.SSHClient(); cli.set_missing_host_key_policy(paramiko.AutoAddPolicy())
cli.connect(HOST, username=USER, password=PASS, timeout=15, banner_timeout=15, auth_timeout=15)
sftp = cli.open_sftp()
sftp.put(local, remote)
print('[上传] %s -> %s' % (os.path.basename(local), remote))

cmd = ('echo "%s" | sudo -S docker cp %s xiaozhi-im:%s && '
       'echo "%s" | sudo -S docker exec xiaozhi-im node %s 2>&1 '
       '| grep -v Experimental | grep -v trace-warnings') % (PASS, remote, remote, PASS, remote)
_, o, e = cli.exec_command(cmd, timeout=180, get_pty=True)
print(o.read().decode('utf-8', 'replace'))
err = e.read().decode('utf-8', 'replace')
if err.strip() and 'password for' not in err:
    print('[stderr]', err[:400])
sftp.close(); cli.close()
