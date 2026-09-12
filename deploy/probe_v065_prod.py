# -*- coding: utf-8 -*-
"""
生产实例只读验证（不建任何测试数据）。

验五件事：
  ① v0.6.3/v0.6.5 的新接口真的注册上了 —— 用「未登录应返回 401 而不是 404」来判定。
     路由不存在时 Express 会直接 404，所以 401/404 是很干净的区分。
  ② 好友备注的数据库迁移真的跑了 —— 直接查表结构。
  ③ 管理台「系统帮助」页真的进了静态产物；且 v0.6.5 起不应再出现「Tailchat」字样。
  ④ ICE 下发现状（turnConfigured / turnSources）。
  ⑤ 服务端版本号已到 v0.6.5。

用法：python deploy/probe_v065_prod.py
"""
import paramiko
import re

HOST, USER, PASS = "192.168.31.44", "pblpan", "Pbl15858505566."
PORT = 3602
S = "echo '%s' | sudo -S " % PASS

c = paramiko.SSHClient()
c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
c.connect(HOST, username=USER, password=PASS, timeout=15)

results = []


def run(cmd, timeout=40):
    _, so, se = c.exec_command(cmd, timeout=timeout)
    return (so.read().decode("utf-8", "replace"),
            se.read().decode("utf-8", "replace"))


def ok(name, cond, extra=""):
    results.append((name, bool(cond), extra))
    print("  %s %s%s" % ("✓" if cond else "✗", name,
                         ("  → " + extra) if (extra and not cond) else ""))


print("=" * 60)
print("生产实例只读验证 — 小智IM v0.6.5")
print("=" * 60)

# ---------- ① 新接口是否注册 ----------
print("\n[1] 新接口注册情况（401=已注册且要鉴权，404=路由不存在）")
base = "http://127.0.0.1:%d" % PORT


def code_of(method, path, data=None):
    cmd = "curl -s -m 8 -o /dev/null -w '%%{http_code}' -X %s %s%s" % (
        method, base + path,
        (" -H 'Content-Type: application/json' -d '%s'" % data) if data else "")
    out, _ = run(cmd)
    return out.strip()


c1 = code_of("PUT", "/api/friends/1/remark", '{"remark":"x"}')
ok("PUT /api/friends/:id/remark 已注册（未登录→401）", c1 == "401", "http=%s" % c1)

c2 = code_of("PUT", "/api/friends/1/remark")
ok("不带 body 也走鉴权而不是 400（说明路由在）", c2 == "401", "http=%s" % c2)

# 老接口回归：确认改造没把它们打坏
c3 = code_of("GET", "/api/friends")
ok("GET /api/friends 仍需鉴权（401）", c3 == "401", "http=%s" % c3)
c4 = code_of("PUT", "/api/friends/templates/1", '{"content":"x"}')
ok("PUT /api/friends/templates/:id 未被新路由抢占（401）", c4 == "401", "http=%s" % c4)

# ---------- ①b v0.6.5 新增：管理台中继配置向导 ----------
# 关键：这些接口能改 .env，**未登录必须 401**，绝不能匿名可写。
c5 = code_of("GET", "/api/admin/turn")
ok("GET /api/admin/turn 已注册且要鉴权（401）", c5 == "401", "http=%s" % c5)
c6 = code_of("POST", "/api/admin/turn/verify", '{"key_id":"a","api_token":"b"}')
ok("POST /api/admin/turn/verify 已注册且要鉴权（401）", c6 == "401", "http=%s" % c6)
c7 = code_of("POST", "/api/admin/turn",
             '{"key_id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","api_token":"b"}')
ok("POST /api/admin/turn 未登录时 401（不能匿名改 .env）", c7 == "401", "http=%s" % c7)
c8 = code_of("DELETE", "/api/admin/turn")
ok("DELETE /api/admin/turn 未登录时 401", c8 == "401", "http=%s" % c8)
# 老路径不能被新路由吃掉
c9 = code_of("GET", "/api/admin/info")
ok("/api/admin/info 未被新路由抢占（401）", c9 == "401", "http=%s" % c9)

# ---------- ② 数据库迁移 ----------
print("\n[2] 好友备注的数据库迁移")
out2, _ = run(S + "docker exec xiaozhi-im node -e \""
              "const {DatabaseSync}=require('node:sqlite');"
              "const db=new DatabaseSync('/data/xiaozhi-im.db');"
              "const c=db.prepare('SELECT name FROM pragma_table_info(?)').all('friendships');"
              "console.log(c.map(x=>x.name).join(','))\"")
cols = out2.strip().splitlines()[-1] if out2.strip() else ""
ok("friendships 表已有 remark 列", "remark" in cols, "列=%s" % cols)

# ---------- ③ 管理台 ----------
print("\n[3] 管理台静态产物")
idx, _ = run("curl -s -m 8 http://127.0.0.1:%d/admin/" % PORT)
ok("/admin/ 可访问", "<div id=\"app\">" in idx or "assets/" in idx)
m = re.search(r'src="([^"]*assets/[^"]*\.js)"', idx)
if m:
    js_path = m.group(1)
    if not js_path.startswith("http"):
        js_path = "http://127.0.0.1:%d%s" % (PORT, js_path)
    js, _ = run("curl -s -m 15 '%s'" % js_path)
    ok("管理台 JS 里有「系统帮助」页", "系统帮助" in js, "已取 %d 字节" % len(js))
    ok("管理台 JS 里有「查看完整系统帮助」入口", "查看完整系统帮助" in js)
    ok("管理台 JS 里提到 Cloudflare TURN 方案", "Cloudflare TURN" in js)
    # v0.6.5：帮助里必须有「从零申请」的完整步骤，且点明「不需要信用卡」
    ok("帮助里有 CF TURN 申请步骤", "不需要信用卡" in js and "TURN 服务器" in js,
       "缺「不需要信用卡」或「TURN 服务器」")
    ok("帮助里给了控制台直达网址", "realtime/turn" in js)
    # v0.6.5：管理台「系统设置」的中继配置向导 UI
    ok("管理台有中继配置向导", "音视频中继配置" in js and "Turn 令牌 ID" in js)
    # 向导不该把明文密钥渲染进静态产物
    ok("管理台产物里没有明文密钥",
       "7839139c2d17a599f2118c6372b2410b" not in js and "e778003f51dd" not in js,
       "产物里出现了真实凭据，必须改成占位符")
    # v0.6.5：说明文案里的「仿 Tailchat 界面」已去掉
    ok("管理台 JS 已不再出现 Tailchat 字样", "Tailchat" not in js,
       "仍存在，需重新构建管理台并热更新")
else:
    ok("能从 index.html 里解析出 JS 入口", False, idx[:200])

# ---------- ④ 服务端版本 ----------
print("\n[4] 服务端版本号")
# 管理台顶栏读的就是 /app/package.json（routes/admin.js: require('../../package.json')）
ver, _ = run(S + "docker exec xiaozhi-im cat /app/package.json")
vm = re.search(r'"version"\s*:\s*"([^"]+)"', ver)
vs = vm.group(1) if vm else ""
ok("服务端 package.json 版本为 0.6.5", vs == "0.6.5", "实际=%s" % vs)

# ---------- ⑤ ICE 下发 ----------
print("\n[5] ICE 下发（中继配置）")
ice, _ = run("curl -s -m 10 http://127.0.0.1:%d/api/call/ice" % PORT)
ok("ICE 接口有响应", len(ice) > 20, ice[:200])
ok("返回 turnConfigured 字段", "turnConfigured" in ice)
ok("返回 turnSources 字段（v0.6.3 新增）", "turnSources" in ice, ice[:300])
ok("不再下发已失效的 stun.qq.com", "stun.qq.com" not in ice, ice[:200])

# ⚠️ 这两条必须做成**会失败的断言**。
# 血泪教训：之前只把中继来源当"打印一行提示"，于是容器里 TURN_URLS 因重建丢失、
# turnSources 变成 [] 时，脚本照样报 15/15 全绿 —— 假通过比没检查更危险。
slim = ice.replace(" ", "")
ok("turnConfigured 为 true", '"turnConfigured":true' in slim, ice[:220])
_m = re.search(r'"turnSources"\s*:\s*\[(.*?)\]', ice)
srcs = [s.strip().strip('"') for s in _m.group(1).split(",") if s.strip()] if _m else []
ok("至少有一条中继可用（turnSources 非空）", bool(srcs),
   "turnSources=%s（容器很可能没读到 .env 里的 TURN_URLS，"
   "需 docker compose up -d --force-recreate）" % srcs)

# 判据要看 turnSources，不能看响应里有没有 "cloudflare" 这个词 ——
# STUN 列表里本来就有 stun.cloudflare.com，按词判会永远误报「已启用」。
if "cloudflare" in srcs and "static" in srcs:
    print("     ✅ Cloudflare + 自建 coturn 双保险")
elif "cloudflare" in srcs:
    print("     ✅ 已启用 Cloudflare 托管中继（免端口映射）")
elif "static" in srcs:
    print("     ⚠ 只有自建 coturn：它要公网端口能进得来才对外可用，目前未放通")
else:
    print("     ❌ 没有任何中继 —— 跨网通话打不通")
if "cloudflareError" in ice:
    print("     ⚠ Cloudflare 签发报错：%s" % ice[ice.find("cloudflareError"):][:200])

# ---------- 汇总 ----------
print("\n" + "=" * 60)
bad = [r for r in results if not r[1]]
print("通过 %d / %d" % (len(results) - len(bad), len(results)))
for n, _, e in bad:
    print("  失败: %s %s" % (n, e))
print("=" * 60)
c.close()
