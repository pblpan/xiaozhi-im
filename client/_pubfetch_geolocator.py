# -*- coding: utf-8 -*-
"""geolocator 依赖落地：本机 pub get 被拦（Dart 起子进程受限），
按 skill「坑14 救法」把 geolocator 闭包手动放进 pub 缓存 + 补两份配置。
1. 从 pub.dev 下载 tarball -> pub.dev host 目录（client 的 package_config 用 pub.dev）
2. package_config.json 追加条目
3. pubspec.lock 追加条目（CI 的 pub get 会校验/自愈）
"""
import hashlib, io, json, os, re, sys, tarfile, urllib.request

CLIENT = r"C:/Users/pblpa/WorkBuddy/2026-09-08-11-01-42/xiaozhi-im/client"
HOST_DIR = r"C:/Users/pblpa/AppData/Local/Pub/Cache/hosted/pub.dev"
# (name, version, is_direct)
PKGS = [
    ("geolocator", "14.1.1", True),
    ("geolocator_android", "5.1.0", False),
    ("geolocator_apple", "2.3.14", False),
    ("geolocator_platform_interface", "4.4.0", False),
    ("geolocator_web", "4.1.4", False),
    ("geolocator_windows", "0.2.3", False),
    ("geolocator_linux", "0.2.6", False),
]

def fetch(url, timeout=90):
    req = urllib.request.Request(url, headers={"User-Agent": "pub-fetch-rescue/1.0"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read()

results = []
for name, ver, direct in PKGS:
    d = os.path.join(HOST_DIR, f"{name}-{ver}")
    sha = None
    if os.path.isdir(d) and os.path.isfile(os.path.join(d, "pubspec.yaml")):
        print(f"[skip] {name}-{ver} 已在缓存")
    else:
        url = f"https://pub.dev/api/archives/{name}-{ver}.tar.gz"
        data = fetch(url)
        sha = hashlib.sha256(data).hexdigest()
        os.makedirs(d, exist_ok=True)
        with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as tf:
            tf.extractall(d)  # pub 的 tar 没有根目录，直接解到 <host>/<名>-<版>/
        print(f"[ok] {name}-{ver} 下载并解包（sha256={sha[:12]}…）")
    # 从解出的 pubspec 读 languageVersion（environment.sdk 下限）
    pubspec = open(os.path.join(d, "pubspec.yaml"), encoding="utf-8").read()
    m = re.search(r"sdk:\s*['\"]?(\^|>=)(\d+)\.(\d+)", pubspec)
    lv = f"{m.group(2)}.{m.group(3)}" if m else "3.0"
    results.append((name, ver, direct, sha, lv))

# ---- package_config.json ----
cfg_path = os.path.join(CLIENT, ".dart_tool", "package_config.json")
cfg = json.load(open(cfg_path, encoding="utf-8"))
have = {p["name"] for p in cfg["packages"]}
added = 0
for name, ver, direct, sha, lv in results:
    if name in have:
        continue
    cfg["packages"].append({
        "name": name,
        "rootUri": f"file:///{HOST_DIR.replace(chr(92), '/')}/{name}-{ver}",
        "packageUri": "lib/",
        "languageVersion": lv,
    })
    added += 1
json.dump(cfg, open(cfg_path, "w", encoding="utf-8"), indent=2)
print(f"package_config: 追加 {added} 条")

# ---- pubspec.lock ----
lock_path = os.path.join(CLIENT, "pubspec.lock")
lock = open(lock_path, encoding="utf-8").read()
missing = []
for name, ver, direct, sha, lv in results:
    if re.search(rf"^  {re.escape(name)}:\n", lock, re.M):
        continue
    if sha is None:  # 之前就在缓存里的包，重新算 sha
        sha = hashlib.sha256(open(os.path.join(HOST_DIR, f"{name}-{ver}", ".sha_src"), "rb").read()).hexdigest() \
            if os.path.isfile(os.path.join(HOST_DIR, f"{name}-{ver}", ".sha_src")) else None
    missing.append((name, ver, direct, sha))
if missing:
    need_sha = [(n, v, dr) for n, v, dr, s in missing if s is None]
    for n, v, dr in need_sha:  # 缓存命中过的包补下 sha
        data = fetch(f"https://pub.dev/api/archives/{n}-{v}.tar.gz")
        open(os.path.join(HOST_DIR, f"{n}-{v}", ".sha_src"), "wb").write(data)
    block = []
    for name, ver, direct, sha in missing:
        if sha is None:
            sha = hashlib.sha256(open(os.path.join(HOST_DIR, f"{name}-{ver}", ".sha_src"), "rb").read()).hexdigest()
        dep = '"direct main"' if direct else "transitive"
        block.append(
            f"  {name}:\n"
            f"    dependency: {dep}\n"
            f"    description:\n"
            f"      name: {name}\n"
            f"      sha256: \"{sha}\"\n"
            f"      url: \"https://pub.dev\"\n"
            f"    source: hosted\n"
            f"    version: \"{ver}\"")
    # pubspec.lock 条目按字母序插；简单起见按名字排序后整体重写这段
    anchor = re.search(r"^  (gapless|geolocator|get|glob|html|http):", lock, re.M)
    text = "\n".join(block) + "\n"
    if anchor:
        lock = lock[:anchor.start()] + text + lock[anchor.start():]
    else:
        lock = lock + text
    open(lock_path, "w", encoding="utf-8", newline="\n").write(lock)
    print(f"pubspec.lock: 追加 {len(missing)} 条")
else:
    print("pubspec.lock: 无需改动")

print("DONE")
