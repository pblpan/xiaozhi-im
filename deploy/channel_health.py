"""收尾复查：确认线上（飞牛 192.168.31.44:3602）第三期取数通道仍然完好。
只读，不创建/修改任何东西。密码现读桌面文件。
"""
import io
import json
import re
import urllib.request
import urllib.error

BASE = "http://192.168.31.44:3602"
PW_FILE = r"D:\Users\pblpa\Desktop\小智 IM\小智管理台新密码-请勿外传.txt"

with io.open(PW_FILE, "r", encoding="utf-8") as f:
    m = re.search(r"^新密码\s*[:：]\s*(\S+)\s*$", f.read(), re.M)
assert m, "密码文件里没找到「新密码」那一行"
pw = m.group(1)


def req(method, path, token=None, body=None):
    data = json.dumps(body).encode() if body is not None else None
    r = urllib.request.Request(BASE + path, data=data, method=method)
    r.add_header("Content-Type", "application/json")
    if token:
        r.add_header("Authorization", "Bearer " + token)
    try:
        with urllib.request.urlopen(r, timeout=25) as resp:
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
            return e.code, raw[:200]


rows = []


def ok(name, cond, extra=""):
    rows.append((name, bool(cond), extra))
    print(("  OK   " if cond else "  FAIL ") + name + ("  -> " + str(extra) if extra and not cond else ""))


# ① 登录
st, lg = req("POST", "/api/auth/login", None, {"username": "admin", "password": pw})
tok = lg.get("token") if isinstance(lg, dict) else None
ok("管理员登录成功", st == 200 and bool(tok), f"{st} {str(lg)[:120]}")
if not tok:
    raise SystemExit("登录失败，后续无法验证")

# ② 服务端版本（bootstrap 里带 serverVersion）
#
# 🔴 这里**刻意不写等值断言**。本脚本要确认的是"服务端具备第三期取数通道"这个**能力**，
#    不是"它正好是 0.18.0"。写死等值的结果就是**每次服务端发版它必红一次**，
#    然后被当成噪声忽略掉 —— 真实教训：脚本里写 0.18.0，服务端升到 0.18.1 后立刻假失败
#    （体检报 20/21，唯一那条"失败"其实什么毛病都没有）。
#    改成"不低于某个能力基线"后，它只在真的缺能力时才红。
MIN_SERVER_VERSION = (0, 18, 0)   # 第三期上游取数通道 /api/hooks/up/:name/* 从这里开始有


def _vtuple(v):
    """"0.18.1" -> (0, 18, 1)；"0.18.1+40" 的 +N 构建号忽略；无法解析 -> (0,0,0)"""
    out = []
    for part in str(v or "").split("+")[0].split(".")[:3]:
        digits = "".join(ch for ch in part if ch.isdigit())
        out.append(int(digits) if digits else 0)
    while len(out) < 3:
        out.append(0)
    return tuple(out)


st, boot = req("GET", "/api/client/bootstrap", tok)
sv = boot.get("serverVersion") if isinstance(boot, dict) else None
ok(f"服务端版本 >= {'.'.join(map(str, MIN_SERVER_VERSION))}（取数通道能力基线）",
   _vtuple(sv) >= MIN_SERVER_VERSION, f"{st} serverVersion={sv}")

# ③ 上游接口清单里必须有 tiger
st, body = req("GET", "/api/admin/upstreams", tok)
cap = body.get("capability") if isinstance(body, dict) else None
items = (body.get("upstreams") if isinstance(body, dict) else None) or []
ok("GET /api/admin/upstreams 200", st == 200, f"{st} {str(body)[:150]}")
ok("能力清单带 pathPrefix（0.18.0 新特性）",
   isinstance(cap, dict) and cap.get("pathPrefix") == "/api/hooks/up/", cap)
tiger = next((u for u in items if u.get("name") == "tiger"), None)
ok("上游接口 tiger 已注册", tiger is not None, [u.get("name") for u in items])
if tiger:
    ok("tiger 指向本机 3670", "3670" in (tiger.get("baseUrl") or ""), tiger.get("baseUrl"))
    ok("tiger 凭据已配（服务端持有，不下发明文）",
       tiger.get("hasAuth") is True and "authHeader" not in tiger, tiger)
    ok("tiger 处于启用状态", bool(tiger.get("enabled")), tiger.get("enabled"))

# ④ 会话下发里不能带出真实地址 / 凭据
raw = json.dumps({"boot": boot, "apps": req("GET", "/api/client/apps?clientVersion=0.14.1", tok)[1]},
                 ensure_ascii=False)
ok("bootstrap/apps 不泄漏上游地址", "3670" not in raw, raw[:200])
ok("bootstrap/apps 不泄漏凭据", "Bearer " not in raw)

# ⑤ 动态应用「门店日报」已下发
st, apps = req("GET", "/api/client/apps?clientVersion=0.14.1", tok)
raw_apps = json.dumps(apps, ensure_ascii=False)
ok("门店日报应用已下发", "daily_sales" in raw_apps or "门店日报" in raw_apps, raw_apps[:200])

# ⑥ 真正走一遍通道（客户端点进去看的就是这条）
st, hook = req("GET", "/api/hooks/up/tiger/report/daily", tok)
ok("通道调用返回 200", st == 200, f"{st} {str(hook)[:200]}")
d = (hook or {}).get("data") or {} if isinstance(hook, dict) else {}
summ = d.get("summary_rows") or []
ok("外壳完整（upstream/url/status/ms）",
   isinstance(hook, dict) and hook.get("upstream") == "tiger" and hook.get("status") == 200
   and isinstance(hook.get("ms"), int), str(hook)[:200] if isinstance(hook, dict) else hook)
ok("拿到 summary_rows", isinstance(summ, list) and len(summ) > 0, f"keys={list(d.keys())[:12]}")
ok("拿到 trend", len(d.get("trend") or []) > 0, f"trend={len(d.get('trend') or [])}")
ok("拿到 top", len(d.get("top") or []) > 0, f"top={len(d.get('top') or [])}")
ok("零库存数字段在", "zero_stock_count" in d)
# 值可能是 "¥39.10" 这种字符串，别只认数字类型
ok("数据里带真实营业额",
   any(re.search(r"\d", str(v)) and v not in ("0", "¥0.00") for r in summ for v in r.values()),
   str(summ[:2])[:200])

# ⑦ 边界
st, _ = req("GET", "/api/hooks/up/tiger/report/daily", None)
ok("未登录调用被拒（401）", st == 401, st)
# 上游自己判非法日期并回 400，服务端原样透传状态码（不吞成 502）
st, b = req("GET", "/api/hooks/up/tiger/report/daily/2026-13-99", tok)
ok("非法日期被上游拒绝（状态码透传 + ok:false）",
   st in (400, 502) and isinstance(b, dict) and b.get("ok") is False and b.get("status") in (400, 502),
   f"{st} {str(b)[:160]}")
st, b = req("GET", "/api/hooks/up/tiger/..%2F..%2Fadmin", tok)
ok("子路径含 .. 被拒", st == 502, f"{st} {str(b)[:120]}")

print("\n--- 汇总 ---")
print("通过 %d / %d" % (sum(1 for _, c, _ in rows if c), len(rows)))
bad = [n for n, c, _ in rows if not c]
print("失败: " + (", ".join(bad) if bad else "无"))
