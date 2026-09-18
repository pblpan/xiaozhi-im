"""线上验证：飞牛 0.18.0 的「上游接口」受控转发是否真的通了。

为什么单独跑这一个而不是复用 test/upstream_e2e.js：
  本地 e2e 跑的是**本机临时实例 + 假上游**，它证明"代码逻辑对"；
  线上要证明的是另一件事 —— 容器**果然能出网、能打到内网地址**、
  管理台新页面**确实下发到了浏览器**、以及**部分更新真的落库**（本地是内存里的新库，
  线上是 0.17.1 升上来的老库，多了迁移这一层）。

用法：python deploy/upstream_live_check.py
密码从桌面「小智管理台新密码-请勿外传.txt」现读，不写进源码。
"""
import io
import json
import os
import re
import sys
import urllib.error
import urllib.request

BASE = "http://192.168.31.44:3602"
PW_FILE = r"D:\Users\pblpa\Desktop\小智 IM\小智管理台新密码-请勿外传.txt"

passed = []
failed = []


def ok(name, cond, extra=""):
    (passed if cond else failed).append(name)
    print(("  \u2713 " if cond else "  \u2717 ") + name + (("  \u2192 " + str(extra)) if (extra and not cond) else ""))


def req(method, path, token=None, body=None):
    data = json.dumps(body).encode() if body is not None else None
    r = urllib.request.Request(BASE + path, data=data, method=method)
    r.add_header("Content-Type", "application/json")
    if token:
        r.add_header("Authorization", "Bearer " + token)
    try:
        with urllib.request.urlopen(r, timeout=20) as resp:
            raw = resp.read().decode("utf-8", "replace")
            try:
                return resp.status, json.loads(raw)
            except ValueError:
                return resp.status, raw
    except urllib.error.HTTPError as e:
        raw = e.read().decode("utf-8", "replace")
        try:
            return e.code, json.loads(raw)
        except ValueError:
            return e.code, raw


def admin_password():
    if not os.path.exists(PW_FILE):
        sys.exit("找不到密码文件：%s" % PW_FILE)
    with io.open(PW_FILE, "r", encoding="utf-8") as f:
        text = f.read()
    m = re.search(r"^新密码\s*[:：]\s*(\S+)\s*$", text, re.M)
    if not m:
        sys.exit("密码文件里没找到「新密码」那一行")
    return m.group(1)


def main():
    pw = admin_password()
    st, body = req("POST", "/api/auth/login", body={"username": "admin", "password": pw})
    token = body.get("token") if isinstance(body, dict) else None
    ok("管理员登录（新密码仍有效）", st == 200 and bool(token), "%s %s" % (st, body))
    if not token:
        return finish()

    print("\n① 新接口在线（0.18.0 已生效）")
    st, body = req("GET", "/api/admin/upstreams", token)
    cap = body.get("capability") if isinstance(body, dict) else None
    ok("GET /api/admin/upstreams 200", st == 200, "%s %s" % (st, body))
    ok("能力清单带 pathPrefix（管理台靠它拼路径）",
       isinstance(cap, dict) and cap.get("pathPrefix") == "/api/hooks/up/", cap)
    ok("方法白名单只放 GET/POST",
       isinstance(cap, dict) and sorted(cap.get("methods") or []) == ["GET", "POST"], cap)

    print("\n② 登记一条指向服务端自身的上游（验证容器能出网打到 127.0.0.1:3602）")
    st, body = req("POST", "/api/admin/upstreams", token, {
        "name": "selftest",
        "label": "线上连通性自检（用完即删）",
        "baseUrl": "http://127.0.0.1:3602/api",
        "timeoutMs": 5000,
    })
    ok("登记成功", st == 200, "%s %s" % (st, body))

    print("\n③ 客户端那条路径真的取到数（这是\"点进来看\"走的那条）")
    st, body = req("GET", "/api/hooks/up/selftest/health", token)
    ok("GET /api/hooks/up/selftest/health 200", st == 200, "%s %s" % (st, body))
    ok("回包是带 data 外壳的（dataPath 写 data.xxx）",
       isinstance(body, dict) and "data" in body and "upstream" in body, body)
    ok("上游真实数据到位（/api/health 的 ok=true 原样透传）",
       isinstance(body, dict) and isinstance(body.get("data"), dict)
       and body["data"].get("ok") is True, body.get("data"))
    ok("带 upstream/status/ms/url（排障要用）",
       isinstance(body, dict) and body.get("upstream") == "selftest"
       and body.get("status") == 200 and isinstance(body.get("ms"), int), body)

    print("\n④ 安全边界（线上也要成立，不能只在本地测试里成立）")
    st, _ = req("GET", "/api/hooks/up/selftest/health")
    ok("未登录 → 401", st == 401, st)
    st, body = req("GET", "/api/hooks/up/nosuchthing/x", token)
    ok("未登记的接口名 → 502 且说\"没有登记\"",
       st == 502 and "没有登记" in str(body), "%s %s" % (st, body))
    st, body = req("GET", "/api/hooks/up/selftest/..%2F..%2Fadmin", token)
    ok("子路径含 .. → 被拒", st == 502, "%s %s" % (st, body))
    st, body = req("GET", "/api/hooks/up/selftest/health?x=1", token)
    ok("带 query 正常（上游参数不该被改写）", st == 200, "%s %s" % (st, body))
    st, body = req("PUT", "/api/hooks/up/selftest/health", token)
    ok("PUT → 被拒（不能拿它打别人的写接口）", st == 502, "%s %s" % (st, body))

    print("\n⑤ 部分更新在**线上老库**上真的落库（本地是新库，测不到迁移这一层）")
    st, body = req("POST", "/api/admin/upstreams", token, {"name": "selftest", "enabled": False})
    ok("只提交 enabled:false → 200（不会因\"没带地址\"被 400）", st == 200, "%s %s" % (st, body))
    st, body = req("GET", "/api/hooks/up/selftest/health", token)
    ok("停用后 → 502 且说\"已停用\"", st == 502 and "已停用" in str(body), "%s %s" % (st, body))
    st, body = req("GET", "/api/admin/upstreams", token)
    row = next((x for x in (body.get("upstreams") or []) if x["name"] == "selftest"), None)
    ok("清单里 enabled 真的变成 false（状态落库，不是内存标记）",
       row is not None and row["enabled"] is False, row)
    ok("清单不回传凭据明文（只有 hasAuth 标志）",
       row is not None and "authHeader" not in row and "hasAuth" in row, row)

    st, body = req("POST", "/api/admin/upstreams", token, {"name": "selftest", "enabled": True})
    ok("恢复启用 → 200", st == 200, "%s %s" % (st, body))
    st, _ = req("GET", "/api/hooks/up/selftest/health", token)
    ok("恢复后立刻又通", st == 200, st)

    print("\n⑥ 管理台新页面已下发（浏览器里能看到「上游接口」）")
    with urllib.request.urlopen(BASE + "/admin", timeout=20) as resp:
        html = resp.read().decode("utf-8", "replace")
    # 静态资源挂在 /admin/assets/ 下（不是 /assets/）—— 按首页里写的原样取，别自己拼前缀
    m = re.search(r'src="(/admin/assets/index-[A-Za-z0-9_-]+\.js)"', html)
    ok("管理台首页引用了新构建的 bundle", bool(m), html[:200])
    if m:
        with urllib.request.urlopen(BASE + m.group(1), timeout=30) as resp:
            js = resp.read().decode("utf-8", "replace")
        ok("bundle 里含「上游接口」导航项", "上游接口" in js)
        ok("bundle 里含试跑/探活入口", "试跑" in js and "探活" in js)
        ok("bundle 里含上游接口的几个接口路径",
           "/admin/upstreams" in js and "hooks/up/" in js)

    print("\n⑦ 清理自检数据")
    st, body = req("GET", "/api/admin/upstreams", token)
    row = next((x for x in (body.get("upstreams") or []) if x["name"] == "selftest"), None)
    if row:
        st, body = req("DELETE", "/api/admin/upstreams/%d" % row["id"], token)
        ok("删除自检上游", st == 200, "%s %s" % (st, body))
        st, _ = req("GET", "/api/hooks/up/selftest/health", token)
        ok("删除后立即失效", st == 502, st)

    return finish()


def finish():
    print("\n" + "=" * 52)
    print("通过 %d / %d" % (len(passed), len(passed) + len(failed)))
    if failed:
        print("\n失败项：")
        for f in failed:
            print("  - " + f)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
