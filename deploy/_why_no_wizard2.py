# -*- coding: utf-8 -*-
"""把 needSetup 判据每一步摊开（只读）。

背景：龙哥在飞牛上装完 0.21.3，管理台没弹「首次运行设置密码向导」。
改完 setup.js / config.js 热更上去之后接口仍返回 needSetup=false，
得知道它卡在哪一环，而不是猜。

判据顺序（server/src/setup.js）：
  ① settings.admin_pw_set_at 存在      -> false（向导走过)
  ② 环境未配 ADMIN_PASSWORD            -> true（刚装好，该弹）
  ③ admin 用户或 password_hash 缺失    -> true
  ④ 环境变量 == 库里 password_hash     -> true

注意：所有查询都写成临时脚本丢进容器再 node 执行 —— 之前用 `node -e "..."` 叠
引号，转义一多就变成"node 报语法错"，看着像"查不到"，其实是根本没跑起来。
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from fnos_ssh import connect, put_file, run  # noqa: E402

JS = r"""
const{DatabaseSync}=require('node:sqlite');
const db=new DatabaseSync('/data/xiaozhi.db',{readOnly:true});
const mark=db.prepare("select value from settings where key='admin_pw_set_at'").get();
const user=db.prepare("select id,role,length(password_hash) hl from users where username='admin'").get();
const cfg=require('/app/src/config.js');
process.stdout.write([
  'mark=' + (mark ? mark.value : 'none'),
  'admin=' + (user ? JSON.stringify(user) : 'none'),
  'configured=' + cfg.ADMIN_PASSWORD_CONFIGURED,
  'envLen=' + String((process.env.ADMIN_PASSWORD || '').length),
  'customEnv=' + cfg.CUSTOM_ENV,
].join(' | '));
"""


def main():
    c = connect()
    local = os.path.join(HERE, '_why_no_wizard.js')
    with open(local, 'w', encoding='utf-8') as f:
        f.write(JS)
    # 🔴 必须落在 **/data**（= 容器内 /data 的挂载源）。放到宿主机 /tmp 的话
    #    docker exec 在容器自己的 /tmp 里找，永远报 "Cannot find module"。
    put_file(c, local, '/vol1/@appshare/xiaozhi-im/data/_probe_wizard.js')

    for name, cmd in [
        ('库内事实', 'docker exec xiaozhi-im node /data/_probe_wizard.js 2>&1 | tail -3'),
        ('线上 config 新判据', 'grep -c ADMIN_PASSWORD_CONFIGURED /vol1/@appcenter/xiaozhi-im/src/src/config.js'),
        ('线上 setup 新判据', 'grep -c ADMIN_PASSWORD_CONFIGURED /vol1/@appcenter/xiaozhi-im/src/src/setup.js'),
        ('DATA_DIR 内容', 'ls -a /vol1/@appshare/xiaozhi-im/data/ | tr "\\n" " "'),
        ('接口返回', 'curl -s --max-time 8 http://127.0.0.1:3602/api/setup/status'),
    ]:
        print('%-20s %s' % (name + ':', run(c, cmd).strip().replace('\n', ' | ')[:240]))
    c.close()
    os.remove(local)


if __name__ == '__main__':
    main()
