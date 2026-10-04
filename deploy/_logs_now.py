import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from fnos_auth import HOST, USER, PASS
import paramiko
cli = paramiko.SSHClient(); cli.set_missing_host_key_policy(paramiko.AutoAddPolicy())
cli.connect(HOST, username=USER, password=PASS, timeout=15, banner_timeout=15, auth_timeout=15)
cmd = 'echo "%s" | sudo -S docker logs --tail 40 xiaozhi-im 2>&1 | tail -40' % PASS
_, o, e = cli.exec_command(cmd, timeout=60, get_pty=True)
print(o.read().decode('utf-8', 'replace'))
cli.close()
