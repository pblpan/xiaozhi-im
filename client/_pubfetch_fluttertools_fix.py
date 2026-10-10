# -*- coding: utf-8 -*-
"""坑14救法：flutter_tools 的 package_config（pub.flutter-io.cn host）缺包，
按配置钉死的版本从 pub.dev 拉对应版本补齐（只补缺的，不动已有的）。"""
import json, os, io, hashlib, tarfile, urllib.request

CFG = r"C:/Users/pblpa/WorkBuddy/2026-09-08-11-01-42/tools/flutter_sdk2/flutter/packages/flutter_tools/.dart_tool/package_config.json"
HOST = "pub.flutter-io.cn"
HOST_DIR = f"C:/Users/pblpa/AppData/Local/Pub/Cache/hosted/{HOST}"

cfg = json.load(open(CFG, encoding="utf-8"))
miss = []
for pkg in cfg["packages"]:
    uri = pkg["rootUri"]
    if not uri.startswith("file:"):
        continue
    path = uri.replace("file:///", "").replace("file://", "")
    name = pkg["name"]
    if not os.path.isdir(path):
        ver = os.path.basename(path).rsplit("-", 1)[-1]
        miss.append((name, ver, path))

print(f"缺 {len(miss)} 个包，开始补……")
fail = []
for name, ver, path in miss:
    url = f"https://pub.dev/api/archives/{name}-{ver}.tar.gz"
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "pub-fetch-rescue/1.0"})
        data = urllib.request.urlopen(req, timeout=90).read()
        os.makedirs(path, exist_ok=True)
        with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as tf:
            tf.extractall(path)
        print(f"[ok] {name}-{ver}  sha={hashlib.sha256(data).hexdigest()[:10]}")
    except Exception as e:
        fail.append((name, ver, str(e)))
        print(f"[FAIL] {name}-{ver}: {e}")

# 复核
cfg2 = json.load(open(CFG, encoding="utf-8"))
still = [p["name"] for p in cfg2["packages"]
         if p["rootUri"].startswith("file:")
         and not os.path.isdir(p["rootUri"].replace("file:///", "").replace("file://", ""))]
print(f"复核：仍缺 {len(still)} {still if still else ''}")
print("FAIL" if (fail or still) else "DONE")
