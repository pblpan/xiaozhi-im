#!/usr/bin/env python3
import os, sys, re
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from fnos_ssh import connect, put_file, run  # noqa: E402

c = connect()
probe = os.path.join(HERE, "_admin_token_probe.js")
assert os.path.isfile(probe), "缺少 %s" % probe
put_file(c, probe, "/vol1/@appcenter/xiaozhi-im/src/_admin_token_probe.js",
         backup=True, stamp="verify")
out = run(c, "docker exec xiaozhi-im node /app/_admin_token_probe.js /data/xiaozhi-im.db") or ""
tok = None
for line in out.splitlines():
    line = line.strip()
    if re.match(r'^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$', line):
        tok = line
        break
assert tok, "签不到 token，docker exec 输出：\n" + out
dst = r"D:\Users\pblpa\Desktop\小智 IM\_verify_token.txt"
with open(dst, "w", encoding="utf-8") as f:
    f.write(tok)
print("token 长度", len(tok), "已写入", dst)
