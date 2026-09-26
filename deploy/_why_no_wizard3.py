# -*- coding: utf-8 -*-
"""两库对照：到底哪个库才是服务端在用的，settings / users 在哪。

上一次探针报 "no such table: settings"，是因为 /data 下躺着两个库文件
（xiaozhi.db 与 xiaozhi-im.db）。db.js 的 DB_PATH 可能指向其中一个，
另一个是历史遗留。**判据查错了库，等于什么都没查。**
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from fnos_ssh import connect, put_file, run  # noqa: E402

JS = r"""
const{DatabaseSync}=require('node:sqlite');
const out=[];
for (const f of ['xiaozhi-im.db','xiaozhi.db']) {
  try {
    const d=new DatabaseSync('/data/'+f,{readOnly:true});
    const tables=d.prepare("select name from sqlite_master where type='table'").all().map(r=>r.name);
    const has=(t)=>tables.indexOf(t)>=0;
    let mark='n/a', user='n/a';
    if (has('settings')) { const r=d.prepare("select value from settings where key='admin_pw_set_at'").get(); mark=r?r.value:'none'; }
    if (has('users')) { const r=d.prepare("select id,role,length(password_hash) hl from users where username='admin'").get(); user=r?JSON.stringify(r):'none'; }
    out.push(f+': 表'+tables.length+' settings='+has('settings')+' users='+has('users')+' mark='+mark+' admin='+user);
  } catch(e) { out.push(f+': ERR '+e.message); }
}
process.stdout.write(out.join('\n'));
"""

CMD_DBPATH = "grep -n \"DB_PATH\\|DB_FILE\" /vol1/@appcenter/xiaozhi-im/src/src/db.js | head -4"


def main():
    local = os.path.join(HERE, '_probe_wizard3.js')
    with open(local, 'w', encoding='utf-8') as f:
        f.write(JS)
    c = connect()
    put_file(c, local, '/vol1/@appshare/xiaozhi-im/data/_probe_wizard3.js')
    print('=== 库对照 ===')
    print(run(c, 'docker exec xiaozhi-im node /data/_probe_wizard3.js 2>&1 | tail -4').strip())
    print('=== db.js 的库路径 ===')
    print(run(c, CMD_DBPATH).strip())
    print('=== 接口 ===')
    print(run(c, 'curl -s --max-time 8 http://127.0.0.1:3602/api/setup/status').strip())
    c.close()
    os.remove(local)


if __name__ == '__main__':
    main()
