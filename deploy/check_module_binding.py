"""校验动态模块的 dataPath 能不能从真实回包里取到东西。

为什么单独做这一步：
  管理台保存模块时**只校验 dataPath 的字符串格式**（如 data.rows 合法），
  它没办法知道这条路径最后能不能取到数组 —— 而"配了却空白"正是这个功能
  唯一的失败方式，且失败时**不报错**：页面正常打开、框都在，就是空的。
  现场只会说"页面是空的"，无从下手。
  所以这里把服务端的真实回包拿下来，按**客户端同一套解析规则**逐条走一遍。

用法：
  python deploy/check_module_binding.py [模块ID ...]
  不带参数 = 校验下面 DEFAULTS 里的那几个。
"""
import io
import json
import os
import re
import sys
import urllib.error
import urllib.request

IM = "http://192.168.31.44:3602"
PW_FILE = r"D:\Users\pblpa\Desktop\小智 IM\小智管理台新密码-请勿外传.txt"
DEFAULTS = ["daily_sales"]


def req(method, path, token=None, body=None):
    data = json.dumps(body).encode() if body is not None else None
    r = urllib.request.Request(IM + path, data=data, method=method)
    r.add_header("Content-Type", "application/json")
    if token:
        r.add_header("Authorization", "Bearer " + token)
    try:
        with urllib.request.urlopen(r, timeout=30) as resp:
            return resp.status, json.loads(resp.read().decode("utf-8", "replace"))
    except urllib.error.HTTPError as e:
        raw = e.read().decode("utf-8", "replace")
        try:
            return e.code, json.loads(raw)
        except ValueError:
            return e.code, {"_raw": raw}


def login():
    with io.open(PW_FILE, "r", encoding="utf-8") as f:
        m = re.search(r"^新密码\s*[:：]\s*(\S+)\s*$", f.read(), re.M)
    return req("POST", "/api/auth/login",
               body={"username": "admin", "password": m.group(1)})[1]["token"]


def resolve(root, path):
    """与客户端 ModuleData.of 同一套规则：点号分段，每段可带 [n]。
    刻意手写一遍而不是"差不多"：两边规则一旦有差别，
    管理台里试跑正常的路径到了手机上就取不到，最难查。"""
    if not path:
        return None
    cur = root
    for seg in path.split("."):
        if cur is None:
            return None
        m = re.match(r"^([^\[\]]+)((\[\d+\])*)$", seg)
        if not m:
            return None
        key, idx = m.group(1), m.group(2) or ""
        if isinstance(cur, dict):
            cur = cur.get(key)
        elif isinstance(cur, list):
            i = int(key) if key.isdigit() else None
            if i is None or i >= len(cur):
                return None
            cur = cur[i]
        else:
            return None
        for im in re.findall(r"\[(\d+)\]", idx):
            if not isinstance(cur, list) or int(im) >= len(cur):
                return None
            cur = cur[int(im)]
    return cur


def walk(components, out, prefix=""):
    """把嵌套结构（card.children）摊平，带上路径方便报错定位"""
    for i, c in enumerate(components or []):
        tag = "%s[%d]%s" % (prefix, i, c.get("component"))
        out.append((tag, c))
        if c.get("component") == "card" and c.get("children"):
            walk(c["children"], out, tag + ".")


def main():
    ids = sys.argv[1:] or DEFAULTS
    token = login()
    bad = 0

    for mid in ids:
        print("=" * 56)
        print("模块 %s" % mid)
        st, body = req("GET", "/api/client/modules/%s?clientVersion=0.14.0" % mid, token)
        if st != 200:
            print("  ✗ 取模块定义失败：%s %s" % (st, body))
            bad += 1
            continue
        mod = body["module"]
        load = mod.get("onLoad") or {}
        print("  取数: %s %s (%s)" % (load.get("method"), load.get("path"), mod.get("title")))

        if not load.get("path"):
            print("  ⚠ 没有 onLoad，静态页面，跳过")
            continue

        # 走客户端那条路径。注意别照抄客户端的"剥 /api"那一步：
        # 客户端是 baseUrl + '/api' + p，而这里的 IM 常量是裸 host，
        # 所以直接用模块里写的完整路径（/api/hooks/...）才对。
        # 我第一次就是照抄了剥前缀，结果自己造出一个 404 假告警。
        sub = load["path"]
        st, resp = req("GET", sub, token)
        print("  回包: HTTP %s" % st)
        if st != 200:
            print("  ✗ 取数失败，页面会是空的：%s" % str(resp)[:200])
            bad += 1
            continue

        # 客户端会把这整包当成 root（ModulePage._asMap）
        root = resp if isinstance(resp, dict) else {"data": {"items": resp}, "items": resp}
        print("  回包外壳: %s" % ", ".join(sorted(root.keys())))

        flat = []
        walk(mod.get("body"), flat)

        checked = 0
        for tag, c in flat:
            comp = c.get("component")
            dp = c.get("dataPath")
            if comp == "list":
                dp = dp or ""
                v = resolve(root, dp)
                checked += 1
                if isinstance(v, list):
                    print("  ✓ %-14s %-22s → %d 条" % (tag, dp, len(v)))
                    if v and isinstance(v[0], dict):
                        print("        首条可用字段: %s" % ", ".join(list(v[0].keys())[:8]))
                    # 模板里的占位符必须真能取到值，否则每行显示成 {{xxx}}。
                    # ⚠️ 数组为空时**无从验证** —— 只能报"没验"，不能报"失败"：
                    #    把"这天恰好没数据"渲染成"配置错了"，会让人去改一个本来没问题的模板。
                    if not v:
                        print("  ⚠ %-14s itemTemplate 未验证（该日无数据，取不到样本）" % tag)
                        continue
                    sample = v[0] if isinstance(v[0], dict) else {}
                    for slot in ("title", "subtitle", "trailing"):
                        tpl = (c.get("itemTemplate") or {}).get(slot) or ""
                        if not tpl:
                            continue
                        miss = [k for k in re.findall(r"\{\{(\w+)\}\}", tpl)
                                if k not in sample]
                        if miss:
                            print("  ✗ %-14s itemTemplate.%s 引用了不存在的字段 %s"
                                  % (tag, slot, miss))
                            bad += 1
                else:
                    print("  ✗ %-14s %-22s → %r（list 需要数组）" % (tag, dp, v))
                    bad += 1
            elif comp in ("table", "chart"):
                v = resolve(root, dp or "")
                checked += 1
                if isinstance(v, list) and v:
                    keys = set()
                    if isinstance(v[0], dict):
                        keys = set(v[0].keys())
                    want = ([c["key"] for c in c.get("columns") or []]
                            if comp == "table" else [c.get("xKey"), c.get("yKey")])
                    miss = [k for k in want if k and k not in keys]
                    if miss:
                        print("  ✗ %-14s %-22s → %d 条，但缺字段 %s（列/轴会是空的）"
                              % (tag, dp, len(v), miss))
                        bad += 1
                    else:
                        print("  ✓ %-14s %-22s → %d 条，字段齐" % (tag, dp, len(v)))
                elif isinstance(v, list):
                    print("  ⚠ %-14s %-22s → 空数组（能取到，但这天没数据）" % (tag, dp))
                else:
                    print("  ✗ %-14s %-22s → %r（%s 需要数组）" % (tag, dp, v, comp))
                    bad += 1
            elif comp == "action":
                pass
            elif comp == "copy" and c.get("dataPath"):
                v = resolve(root, dp)
                print("  %s %-14s %-22s → %r" % ("✓" if v is not None else "✗", tag, dp, v))
                if v is None:
                    bad += 1

        if not checked:
            print("  ⚠ 这个模块没有任何取数组的组件，onLoad 取了数也没人用")
    print("=" * 56)
    print("不合规项：%d" % bad)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
