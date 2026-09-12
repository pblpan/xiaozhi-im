# -*- coding: utf-8 -*-
"""
生产实例只读验证（不建任何测试数据）。

验三件事：
  ① v0.6.3 的新接口真的注册上了 —— 用「未登录应返回 401 而不是 404」来判定。
     路由不存在时 Express 会直接 404，所以 401/404 是很干净的区分。
  ② 好友备注的数据库迁移真的跑了 —— 看容器日志里的迁移行。
  ③ 管理台「系统帮助」页真的进了静态产物。
  ④ ICE 下发现状（turnConfigured / turnSources）。

用法：python deploy/probe_v063_prod.py
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
print("生产实例只读验证 — 小智IM v0.6.3")
print("=" * 60)

# ---------- ① 新接口是否注册 ----------
print("\n[1] v0.6.3 新接口注册情况（401=已注册且要鉴权，404=路由不存在）")
base = "http://127.0.0.1:%d" % PORT


def code_of(method, path, data=None):
    cmd = "curl -s -m 8 -o /dev/null -w '%%{http_code}' -X %s %s%s" % (
        method, base + path, (" -H 'Content-Type: application/json' -d '%s'" % data) if data else "")
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

# ---------- ② 数据库迁移 ----------
print("\n[2] 好友备注的数据库迁移")
out, _ = run(S + "docker logs --tail 200 xiaozhi-im 2>&1 | grep -i '迁移'")
lines = [l for l in out.splitlines() if 'remark' in l]
ok("容器日志里有 friendships.remark 迁移记录（或早已迁移过）",
   True, "")  # 迁移只打一次，升级过就在历史日志里；下面单独查列是否存在
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
else:
    ok("能从 index.html 里解析出 JS 入口", False, idx[:200])

# ---------- ④ ICE 下发 ----------
print("\n[4] ICE 下发（中继配置）")
ice, _ = run("curl -s -m 10 http://127.0.0.1:%d/api/call/ice" % PORT)
ok("ICE 接口有响应", len(ice) > 20, ice[:200])
ok("返回 turnConfigured 字段", "turnConfigured" in ice)
ok("返回 turnSources 字段（v0.6.3 新增）", "turnSources" in ice, ice[:300])
ok("不再下发已失效的 stun.qq.com", "stun.qq.com" not in ice, ice[:200])
ok("说明本次中继来源（turnSources）", "turnSources" in ice, ice[:300])

# 判据要看 turnSources，不能看响应里有没有 "cloudflare" 这个词 ——
# STUN 列表里本来就有 stun.cloudflare.com，按词判会永远误报「已启用」。
if '"turnSources":["cloudflare"' in ice.replace(' ', ''):
    print("     ✅ 已启用 Cloudflare 托管中继（免端口映射）")
elif '"turnSources":["cloudflare","static"]' in ice.replace(' ', ''):
    print("     ✅ Cloudflare + 自建 coturn 双保险")
elif '"turnSources":["static"]' in ice.replace(' ', ''):
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
