# -*- coding: utf-8 -*-
"""只读探针：查飞牛上这套服务的「首次运行设置密码向导」为什么不弹。

判据来自 server/src/setup.js 的 needSetup()：
  ① settings 里有 admin_pw_set_at 标记       -> 向导走过（或密码被改过），不弹
  ② 环境变量 ADMIN_PASSWORD 与库里 admin 的
     password_hash 对得上                      -> 还是出厂口令，该弹
  ③ 对不上                                    -> 已经不是出厂口令，不弹（设计如此）

不需要知道真实密码：②的判定在服务端内部做，这里只取回一个布尔结果。
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from fnos_ssh import connect, run

JS_SETUP = """
const{DatabaseSync}=require('node:sqlite');
const db=new DatabaseSync('/data/xiaozhi.db',{readOnly:true});
const r=db.prepare("select value from settings where key='admin_pw_set_at'").get();
const u=db.prepare("select username,length(password_hash) hl from users where username='admin' and role='admin'").get();
process.stdout.write(JSON.stringify({mark: r?r.value:null, admin: u||null}));
"""

CMD = (
    "docker exec xiaozhi-im node -e %s 2>&1 | tail -2"
    % ("'" + JS_SETUP.replace("'", "'\\''").join(["'", "'"]) + "'")
)


def main():
    c = connect()
    print('容器状态 :', run(c, "docker ps --filter name=xiaozhi-im --format '{{.Status}}'").strip() or '(没在跑)')
    print('服务端版本:', run(c, "docker exec xiaozhi-im node -e \"console.log(require('/app/package.json').version)\" 2>&1 | tail -1").strip())
    print('数据库文件:', run(c, "docker exec xiaozhi-im sh -c \"ls /data/*.db 2>/dev/null | head -3\"").strip())

    out = run(c, CMD).strip()
    print('库内标记 :', out)
    env = run(c, "docker exec xiaozhi-im sh -c \"printenv ADMIN_PASSWORD | head -c 3\"").strip()
    print('环境变量前3位:', (env or '(空)') + '...')
    print('端口探测 :', run(c, 'curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:3602/api/setup/status').strip())
    c.close()


if __name__ == '__main__':
    main()
