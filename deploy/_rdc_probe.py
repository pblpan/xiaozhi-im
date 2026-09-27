# -*- coding: utf-8 -*-
"""线上只读探针：验证「远程协助默认控制码」三个接口真的挂上了。

手法跟 console-ui-live-verify 那套一致 —— **不碰密码**：
在容器里用服务端自己的 JWT_SECRET 现签一个 admin token，然后打真实 HTTP。
打真实 HTTP（而不是直接调函数）是为了连"路由有没有注册"一起验掉。

只读：只做 GET，不真的生成/吊销码（那会改线上状态）。
"""
import sys

sys.path.insert(0, 'deploy')
from fnos_auth import HOST, USER, PASS  # noqa: E402

import paramiko  # noqa: E402

# 容器里执行的脚本：签 admin token + 打三个接口
NODE = r'''
const jwt = require('/app/node_modules/jsonwebtoken');
const config = require('/app/src/config.js');
const db = require('/app/src/db.js');

const row = db.prepare("SELECT id, role FROM users WHERE role='admin' ORDER BY id LIMIT 1").get();
if (!row) { console.log('NO_ADMIN'); process.exit(0); }
const t = jwt.sign({ uid: row.id, role: 'admin', exp: Math.floor(Date.now()/1000) + 300 },
                   config.JWT_SECRET);

const H = { Authorization: 'Bearer ' + t, 'Content-Type': 'application/json' };
const base = 'http://127.0.0.1:' + (process.env.PORT || 3602);

(async () => {
  // 1) 未登录 → 401
  let r = await fetch(base + '/api/admin/remote/default-code');
  console.log('未登录 GET      -> ' + r.status + '  (期望 401)');
  // 2) 管理员 GET → 200 且给元信息
  r = await fetch(base + '/api/admin/remote/default-code', { headers: H });
  const b = await r.json();
  console.log('管理员 GET      -> ' + r.status + '  (期望 200) body=' + JSON.stringify(b));
  // 3) 未登录 DELETE → 401（路由挂上了，只是要鉴权）
  r = await fetch(base + '/api/admin/remote/default-code', { method: 'DELETE' });
  console.log('未登录 DELETE   -> ' + r.status + '  (期望 401)');
  console.log('ADMIN_UID=' + row.id);
})().catch(e => { console.log('ERR ' + e.message); });
'''


def main():
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(HOST, username=USER, password=PASS, auth_timeout=15, timeout=30)
    try:
        # 把脚本写进容器再执行（避免引号嵌套把脚本打烂）
        cmd = (
            "docker exec -i xiaozhi-im bash -c 'cat > /tmp/_rdc.js' ; "
            "docker exec xiaozhi-im bash -lc 'cd /app && node /tmp/_rdc.js 2>&1 | grep -v ExperimentalWarning'"
        )
        stdin, stdout, stderr = c.exec_command(cmd, timeout=120)
        stdin.write(NODE)
        stdin.flush()
        stdin.channel.shutdown_write()
        out = stdout.read().decode('utf-8', 'replace')
        err = stderr.read().decode('utf-8', 'replace')
        print(out)
        if err.strip():
            print('[stderr]', err[:500])
    finally:
        c.close()


if __name__ == '__main__':
    main()
