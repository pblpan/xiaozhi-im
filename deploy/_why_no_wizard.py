# -*- coding: utf-8 -*-
"""只读：把 needSetup 判据的每一步在真机上摊开，看它卡在哪一环。

setup.js 的判据顺序：
  ① settings 里有 admin_pw_set_at           -> false（向导走过）
  ② 环境里没配 ADMIN_PASSWORD 且无 custom.env -> true（刚装好，该弹）
  ③ admin 用户 / password_hash 缺失          -> true
  ④ 环境变量与库里 hash 对得上               -> true
这里把 ①②③ 的真实值打印出来，④ 由服务端内部判断（不吐密码）。
"""
import json
import sys

sys.path.insert(0, __file__.rsplit('\\', 1)[0])
from fnos_ssh import connect, run

JS = r"""
const{DatabaseSync}=require('node:sqlite');
const db=new DatabaseSync('/data/xiaozhi.db',{readOnly:true});
const fs=require('fs');
const mark=db.prepare("select value from settings where key='admin_pw_set_at'").get();
const u=db.prepare("select id,length(password_hash) hl from users where username='admin' and role='admin'").get();
const custom=(()=>{try{const t=fs.readFileSync('/data/custom.env','utf8');
  const m=t.match(/^\s*ADMIN_PASSWORD=(.*)$/m);return m&&m[1].trim()?('有值 '+m[1].length+' 字符'):'空';}catch(_){return '文件不存在';}})();
process.stdout.write(JSON.stringify({
  mark: mark?mark.value:null,
  admin: u||null,
  custom,
  envLen: (process.env.ADMIN_PASSWORD||'').length,
}));
"""

CMD = "docker exec xiaozhi-im node -e '" + JS.replace("'", "'\\''").join(["'", "'"]) + "'"


def main():
    c = connect()
    print('容器     :', run(c, "docker ps --filter name=^xiaozhi-im$ --format '{{.Status}}'").strip())
    print('版本     :', run(c, "docker exec xiaozhi-im node -e \"console.log(require('/app/package.json').version)\" 2>&1 | tail -1").strip())
    print('① 向导标记:', run(c, "docker exec xiaozhi-im node -e \"const{DatabaseSync}=require('node:sqlite');const db=new DatabaseSync('/data/xiaozhi.db',{readOnly:true});const r=db.prepare(\\\"select value from settings where key='admin_pw_set_at'\\\").get();console.log(r?r.value:'(无)');\" 2>&1 | tail -1").strip())
    print('② custom.env:', run(c, "docker exec xiaozhi-im sh -c \"if [ -f /data/custom.env ]; then awk -F= '/^ADMIN_PASSWORD=/{print (length(\\\$2)>0? \\\"有值 \\\" length(\\\$2) \\\" 字符\\\" : \\\"空值\\\")} END{}' /data/custom.env; else echo 文件不存在; fi\" 2>&1 | tail -2").strip())
    print('③ admin 用户:', run(c, "docker exec xiaozhi-im node -e \"const{DatabaseSync}=require('node:sqlite');const db=new DatabaseSync('/data/xiaozhi-im.db',{readOnly:true});const r=db.prepare(\\\"select id,length(password_hash) hl from users where username='admin' and role='admin'\\\").get();console.log(r?JSON.stringify(r):'(无)');\" 2>&1 | tail -1").strip())
    print('④ 环境变量长度:', run(c, "docker exec xiaozhi-im sh -c \"printenv ADMIN_PASSWORD | wc -c\"").strip())
    print('接口返回 :', run(c, 'curl -s --max-time 8 http://127.0.0.1:3602/api/setup/status').strip())
    c.close()


if __name__ == '__main__':
    main()
