# -*- coding: utf-8 -*-
"""清掉「首次运行向导」的完成标记，让管理台重新弹出设置密码页。

【为什么需要它】
  龙哥在飞牛上装完 0.21.3，管理台死活不弹「设置密码向导」。查下来是判据 ①：
  settings.admin_pw_set_at 里有值（1789655632556），needSetup() 第一步就 break 了。
  而这个标记是历史上某次 runSetup 留下的 —— 那次的口令是 db.js 用
  config.ADMIN_PASSWORD（env 空 → randomSecret()）建的**一次性随机串**，
  从没持久化到任何文件，所以：
    · 没人知道那个密码是什么（重启即失效，因为每次都是新随机）
    · 向导又因为"已初始化"永不弹出
  → 装好了一套服务器，反而进不去管理台。
  清掉标记后：needSetup 走到 ②（环境没配 ADMIN_PASSWORD）→ true → 向导弹出，
  管理员自己设一个能记住的密码，向导随即写入 custom.env 收口。

【保守之处】
  · 只删这一行，其它设置一行不动；
  · 删之前把原值写一份到 /data/_admin_pw_marker.bak，需要回滚随时填回；
  · 不动 password_hash —— 向导设新密码时会覆盖它。

用法：python _reset_setup_marker.py [--dry-run]
"""
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from fnos_ssh import connect, put_file, run  # noqa: E402

DRY = '--dry-run' in sys.argv
JS = r"""
const{DatabaseSync}=require('node:sqlite');
const fs=require('fs');
const DB='/data/xiaozhi-im.db';
const KEY='admin_pw_set_at';
const d=new DatabaseSync(DB,{timeout:8000});
const row=d.prepare('select value from settings where key=?').get(KEY);
const val=row?row.value:null;
if (%(dry)s) {
  process.stdout.write('DRY-RUN 现值=' + (val||'(无)'));
} else {
  if (val) fs.writeFileSync('/data/_admin_pw_marker.bak', val+'\n', {mode:0o600});
  const info=d.prepare('delete from settings where key=?').run(KEY);
  const after=d.prepare('select value from settings where key=?').get(KEY);
  process.stdout.write('删除 ' + info.changes + ' 行，删除后=' + (after? after.value : 'null') +
    '；原值已备份到 /data/_admin_pw_marker.bak');
}
"""

JS = JS % {'dry': 'true' if DRY else 'false'}


def main():
    local = os.path.join(HERE, '_reset_marker.js')
    with open(local, 'w', encoding='utf-8') as f:
        f.write(JS)
    c = connect()
    put_file(c, local, '/vol1/@appshare/xiaozhi-im/data/_reset_marker.js')
    tag = '（dry-run，只看不删）' if DRY else ''
    print('=== 清标记 %s ===' % tag)
    print(run(c, 'docker exec xiaozhi-im node /data/_reset_marker.js 2>&1 | tail -2').strip())

    if not DRY:
        print('=== 重启容器 ===')
        run(c, 'docker restart xiaozhi-im')
        time.sleep(10)
        print('状态: ' + run(c, "docker ps --filter name=^xiaozhi-im$ --format '{{.Status}}'").strip())
        time.sleep(5)
        print('setup/status: ' + run(c, 'curl -s --max-time 8 http://127.0.0.1:3602/api/setup/status').strip())
    c.close()
    os.remove(local)


if __name__ == '__main__':
    main()
