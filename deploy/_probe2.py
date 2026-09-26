# -*- coding: utf-8 -*-
"""只读摊开：向导标记 / admin 行 / 线上 config 是否有新判据。

上一版脚本栽在引号嵌套上（node 报语法错，看起来像"查不到"其实是"没执行"）。
这次全部走本地拼好的命令串，不在一行 python -c 里叠三层转义。
"""
import sys

sys.path.insert(0, __file__.rsplit('\\', 1)[0])
from fnos_ssh import connect, run

DECK = r"""
const{DatabaseSync}=require('node:sqlite');
const db=new DatabaseSync('/data/xiaozhi.db',{readOnly:true});
const mark=db.prepare("select value from settings where key='admin_pw_set_at'").get();
const u=db.prepare("select id,role,length(password_hash) hl from users where username='admin'").get();
process.stdout.write('mark=' + (mark? mark.value : 'none') + ' | admin=' + (u? JSON.stringify(u) : 'none'));
"""

CMDS = [
    ('向导标记/admin 行', "docker exec xiaozhi-im node -e %s" % ("'" + DECK.replace("'", "'\"'\"'") + "'")),
    ('线上 config 有新判据', "grep -c ADMIN_PASSWORD_CONFIGURED /app/src/config.js"),
    ('线上 setup.js 有新判据', "grep -c ADMIN_PASSWORD_CONFIGURED /app/src/setup.js"),
    ('DATA_DIR 内容', "ls -a /data/ | tr '\\n' ' '"),
]


def main():
    c = connect()
    for name, cmd in CMDS:
        out = run(c, cmd + ' 2>&1 | tail -3').strip()
        print('%-22s %s' % (name + ':', out.replace('\n', ' | ')[:220]))
    c.close()


if __name__ == '__main__':
    main()
