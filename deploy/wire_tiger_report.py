"""把 tiger-bridge 接进小智，并建一个「门店日报」模块 —— 也就是"点进来看"那条完整链路。

做的事：
  ① 登记上游 tiger → http://192.168.31.138:3670（凭据由服务端保存，不下发客户端）
  ② 探活 + 试跑，确认地址与凭据都对
  ③ 走**客户端那条路径**取一次数，证明"点进去"真能拿到数据
  ④ 建一个动态模块（汇总表 + 趋势图 + TOP表 + 库存预警列表），入口出现在工作台

凭据（serve.token）从 tiger-bridge/config.json 现读，不打印、不写进本文件。
"""
import io
import json
import os
import re
import sys
import urllib.error
import urllib.request

IM = "http://192.168.31.44:3602"
BRIDGE = "http://192.168.31.138:3670"
PW_FILE = r"D:\Users\pblpa\Desktop\小智 IM\小智管理台新密码-请勿外传.txt"
HERE = os.path.dirname(os.path.abspath(__file__))          # xiaozhi-im/deploy
CFG_FILE = os.path.join(os.path.dirname(os.path.dirname(HERE)), "tiger-bridge", "config.json")

MODULE_ID = "daily_sales"
# 用于验证"有数据"的那一天：库里 9/15 有支付流水、9/12 有退货（见 test/run.js 的集成用例）
PROBE_DAY = "2026-09-15"

passed, failed = [], []


def ok(name, cond, extra=""):
    (passed if cond else failed).append(name)
    print(("  \u2713 " if cond else "  \u2717 ") + name + (("  \u2192 " + str(extra)) if (extra and not cond) else ""))


def req(method, path, token=None, body=None, base=IM):
    data = json.dumps(body).encode() if body is not None else None
    r = urllib.request.Request(base + path, data=data, method=method)
    r.add_header("Content-Type", "application/json")
    if token:
        r.add_header("Authorization", "Bearer " + token)
    try:
        with urllib.request.urlopen(r, timeout=30) as resp:
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
    with io.open(PW_FILE, "r", encoding="utf-8") as f:
        m = re.search(r"^新密码\s*[:：]\s*(\S+)\s*$", f.read(), re.M)
    if not m:
        sys.exit("密码文件里没找到「新密码」那一行")
    return m.group(1)


def serve_token():
    with io.open(CFG_FILE, "r", encoding="utf-8") as f:
        cfg = json.load(f)
    t = str((cfg.get("serve") or {}).get("token") or "").strip()
    if len(t) < 16:
        sys.exit("tiger-bridge/config.json 里 serve.token 没配或太短，先跑 tools/set_serve_config.js")
    return t


def main():
    pw = admin_password()
    tok = serve_token()
    print("凭据已就绪（serve.token 长度 %d，不在日志里回显）\n" % len(tok))

    admin = req("POST", "/api/auth/login",
                body={"username": "admin", "password": pw})[1].get("token")
    if not admin:
        sys.exit("管理员登录失败")
    ok("管理员登录", True)

    # ---------------- ① 登记上游 ----------------
    print("\n① 登记上游 tiger（地址 + 凭据都由服务端持有）")
    st, body = req("POST", "/api/admin/upstreams", admin, {
        "name": "tiger",
        "label": "泰格POS 日报（tiger-bridge）",
        "baseUrl": BRIDGE,
        "authHeader": "Bearer " + tok,
        "timeoutMs": 8000,
    })
    ok("登记成功", st == 200, "%s %s" % (st, body))
    rows = req("GET", "/api/admin/upstreams", admin)[1].get("upstreams") or []
    row = next((x for x in rows if x["name"] == "tiger"), None)
    ok("清单里有它、且只回 hasAuth 不回传明文",
       row is not None and row["hasAuth"] is True and "authHeader" not in row, row)
    ok("清单里没有把 token 漏出去",
       tok not in json.dumps(rows, ensure_ascii=False))

    # ---------------- ② 探活 + 试跑 ----------------
    print("\n② 探活 + 试跑（管理台配完就能当场验）")
    st, body = req("POST", "/api/admin/upstreams/%d/probe" % row["id"], admin)
    ok("探活通（容器到本机 3670 网络可达）",
       st == 200 and body.get("reachable") is True, "%s %s" % (st, body))

    st, body = req("POST", "/api/admin/upstreams/%d/test" % row["id"], admin,
                   {"subPath": "report/daily/" + PROBE_DAY})
    ok("试跑拿到真实日报（%s）" % PROBE_DAY, st == 200 and isinstance(body.get("data"), dict),
       "%s %s" % (st, str(body)[:300]))
    d = body.get("data") or {}
    ok("日报里有汇总行 / 趋势 / TOP 三类数据",
       bool(d.get("summary_rows")) and isinstance(d.get("trend"), list)
       and isinstance(d.get("top"), list),
       "summary=%s trend=%s top=%s" % (len(d.get("summary_rows") or []),
                                       len(d.get("trend") or []), len(d.get("top") or [])))
    official = next((x for x in (d.get("summary_rows") or []) if "营业额" in x.get("label", "")), None)
    print("        ↳ %s = %s ，笔数 %s" % (
        official and official["label"],
        official and official["value"],
        next((x["value"] for x in (d.get("summary_rows") or []) if x.get("label") == "笔数"), "?")))
    ok("营业额不是 ¥0.00（真空报表会让人以为系统坏了）",
       official and official["value"] not in ("¥0.00", "-"), official)

    # ---------------- ③ 客户端那条路径 ----------------
    print("\n③ 客户端路径（员工点进去走的就是这条）")
    st, body = req("GET", "/api/hooks/up/tiger/report/daily", admin)
    ok("GET /api/hooks/up/tiger/report/daily → 200", st == 200, "%s %s" % (st, str(body)[:200]))
    ok("默认给昨天（不用传参，所以模块里塞得进路径正则）",
       isinstance(body, dict) and body.get("data", {}).get("day"), body.get("data", {}).get("day"))
    st2, body2 = req("GET", "/api/hooks/up/tiger/report/daily/" + PROBE_DAY, admin)
    ok("路径形式指定日期也认（模块 onLoad.path 不允许 ? 号）",
       st2 == 200 and body2.get("data", {}).get("day") == PROBE_DAY, "%s %s" % (st2, str(body2)[:200]))
    st3, _ = req("GET", "/api/hooks/up/tiger/report/daily")
    ok("未登录取经营数据 → 401", st3 == 401, st3)
    st4, body4 = req("GET", "/api/hooks/up/tiger/report/daily/2026-13-99", admin)
    ok("非法日期 → 上游的 400 原样透传（没被吞成一份空报表）",
       st4 == 400, "%s %s" % (st4, str(body4)[:200]))

    # ---------------- ④ 建模块 ----------------
    print("\n④ 建「门店日报」模块（汇总表 + 趋势图 + TOP 表 + 库存预警）")
    cap = req("GET", "/api/admin/modules", admin)[1].get("capability") or {}
    icons = cap.get("icons") or []
    ok("拿到能力清单（图标白名单非空）", bool(icons), len(icons))
    icon = "assessment" if "assessment" in icons else (icons[0] if icons else "dashboard")

    module = {
        "moduleId": MODULE_ID,
        "title": "门店日报",
        "icon": icon,
        "sort": 10,
        "enabled": True,
        "visibleTo": {"roles": [], "userIds": []},   # 留空 = 所有登录用户
        "onLoad": {"action": "api", "path": "/api/hooks/up/tiger/report/daily", "method": "GET"},
        "body": [
            {"component": "text", "text": "默认显示昨天。趋势为最近 7 天；下拉刷新可重新取数。",
             "size": 12.5, "color": "muted", "align": "left"},
            {"component": "table", "dataPath": "data.summary_rows",
             "columns": [{"key": "label", "label": "指标", "width": 140},
                         {"key": "value", "label": "数值"}]},
            {"component": "chart", "dataPath": "data.trend", "xKey": "day", "yKey": "income",
             "kind": "line"},
            {"component": "table", "dataPath": "data.top",
             "columns": [{"key": "item_name", "label": "品名"},
                         {"key": "out_qty", "label": "数量", "width": 70},
                         {"key": "net_amt", "label": "金额", "width": 90},
                         {"key": "margin", "label": "毛利率%", "width": 90}]},
            {"component": "list", "dataPath": "data.low_stock",
             "itemTemplate": {"title": "{{item_name}}", "trailing": "库存 {{stock_qty}}"}},
        ],
    }
    st, body = req("POST", "/api/admin/modules", admin, module)
    ok("模块保存成功", st in (200, 201), "%s %s" % (st, str(body)[:300]))

    # ---------------- ⑤ 员工端能看到 ----------------
    print("\n⑤ 工作台里能看到这个入口（否则员工点不到）")
    st, body = req("GET", "/api/client/apps?clientVersion=0.14.0", admin)
    apps = (body or {}).get("apps") if isinstance(body, dict) else None
    if apps is None and isinstance(body, dict):
        apps = body.get("items") or body.get("list")
    ids = [a.get("id") or a.get("moduleId") or a.get("appId") for a in (apps or [])]
    ok("GET /api/client/apps 里出现 daily_sales", MODULE_ID in ids, ids)

    st, body = req("GET", "/api/client/modules/" + MODULE_ID + "?clientVersion=0.14.0", admin)
    m = (body or {}).get("module") or {}
    ok("模块详情带 onLoad 取数动作",
       isinstance(m.get("onLoad"), dict) and m["onLoad"].get("path") == "/api/hooks/up/tiger/report/daily",
       m.get("onLoad"))
    ok("模块详情里 body 有 5 个内容块", len(m.get("body") or []) == 5, len(m.get("body") or []))

    # ---------------- ⑥ 免鉴权接口不能漏数据 ----------------
    # 可见范围留空 = 模块**定义**会写进免鉴权的 bootstrap（这样没登录也能看到入口）。
    # 必须确认漏出去的只有"标题/图标/取数路径"，没有一条经营数据。
    print("\n⑥ 免鉴权启动接口只给壳，不给数据")
    st, boot = req("GET", "/api/client/bootstrap")
    blob = json.dumps(boot, ensure_ascii=False)
    ok("bootstrap 免鉴权可访问", st == 200, st)
    ok("bootstrap 里确实有模块定义（否则登录前看不到入口）",
       MODULE_ID in blob, blob[:200])
    # 拿真实数据里的品名去反查 —— 比"看有没有敏感词"精确得多：
    # 品名只可能来自数据库，出现即泄漏。
    real_name = (d.get("top") or [{}])[0].get("item_name") if d.get("top") else None
    if real_name:
        ok("bootstrap 里没有出现任何真实品名（%s）" % real_name, real_name not in blob)
    ok("bootstrap 里没有金额符号 ¥（报表里的钱不该出现在未登录接口）", "¥" not in blob)
    # 拿"有辨识度"的金额串去反查。别用 "3" 这种短数字 —— 它在任何 JSON 里都能撞上，
    # 只会造出假失败（我第一次就是这么写的，白排查一轮）。
    nums = []
    for t in (d.get("trend") or []):
        v = t.get("income")
        if isinstance(v, (int, float)) and abs(v) >= 1:
            nums.append("%.2f" % v)
    for x in (d.get("summary_rows") or []):
        v = str(x.get("value", ""))
        if v.startswith("¥") and len(v) >= 6:
            nums.append(v.replace("¥", "").replace(",", ""))
    nums = [n for n in dict.fromkeys(nums) if len(n) >= 5]
    hit = [n for n in nums if n in blob]
    ok("bootstrap 里没有出现任何一个真实金额数字（查了 %d 个）" % len(nums), not hit, hit)

    print("\n" + "=" * 52)
    print("通过 %d / %d" % (len(passed), len(passed) + len(failed)))
    if failed:
        print("\n失败项：")
        for f in failed:
            print("  - " + f)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
