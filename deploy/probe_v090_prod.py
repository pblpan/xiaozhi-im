# -*- coding: utf-8 -*-
"""
生产实例只读验证（不建任何测试数据）。

验九件事：
  ① 新接口真的注册上了 —— 用「未登录应返回 401 而不是 404」来判定。
     路由不存在时 Express 会直接 404，所以 401/404 是很干净的区分。
  ② v0.8.0 客户端配置下发：/api/client/bootstrap **必须免鉴权返回 200**
     （App 冷启动还没登录，此时最需要拿地址；要求鉴权就是"连不上→拿不到
     配置→永远连不上"死锁）。同时验证它只吐公开信息。
  ③ 配置相关的数据库表真的建了（client_configs / config_applied）。
  ④ 管理台「客户端配置」页真的进了静态产物。
  ⑤ 服务端版本号已到 v0.8.0。
  ⑥ v0.7.0 多方通话代码仍健在（回归，防热更新漏推）。
  ⑦ v0.8.0 配置中心代码真的进容器 —— 同样必须验代码本体，
     只看版本号会被「只推了 package.json 没推 clientconfig.js」骗过去。
  ⑧ ICE 下发现状（turnConfigured / turnSources）。
  ⑨ v0.9.0 动态模块（第二期）真的进容器与静态产物：
     appmodules.js 本体（三道闸门：封闭组件集 / 动作白名单 / 语义色）、
     模板库 4 套、app_modules 与 module_submissions 两张表、
     bootstrap 只下发「所有人可见」的模块（免鉴权口子不能泄漏权限结构）。

用法：python deploy/probe_v080_prod.py
"""
import json
import re

import paramiko

# ⚠️ 凭据一律不进源码（本仓库是 Public）：从环境变量 FNOS_PASS
#    或 deploy/.fnos.env 读取，详见 deploy/fnos_auth.py
from fnos_auth import HOST, PASS, USER  # noqa: E402
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
print("生产实例只读验证 — 小智IM v0.9.0")
print("=" * 60)

# ---------- ① 接口注册 ----------
print("\n[1] 接口注册情况（401=已注册且要鉴权，404=路由不存在）")
base = "http://127.0.0.1:%d" % PORT


def code_of(method, path, data=None):
    cmd = "curl -s -m 8 -o /dev/null -w '%%{http_code}' -X %s %s%s" % (
        method, base + path,
        (" -H 'Content-Type: application/json' -d '%s'" % data) if data else "")
    out, _ = run(cmd)
    return out.strip()


c1 = code_of("PUT", "/api/friends/1/remark", '{"remark":"x"}')
ok("PUT /api/friends/:id/remark 已注册（未登录→401）", c1 == "401", "http=%s" % c1)
c3 = code_of("GET", "/api/friends")
ok("GET /api/friends 仍需鉴权（401）", c3 == "401", "http=%s" % c3)

# 管理台中继配置向导：能改 .env，未登录必须 401，绝不能匿名可写
c5 = code_of("GET", "/api/admin/turn")
ok("GET /api/admin/turn 已注册且要鉴权（401）", c5 == "401", "http=%s" % c5)
c7 = code_of("POST", "/api/admin/turn",
             '{"key_id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","api_token":"b"}')
ok("POST /api/admin/turn 未登录时 401（不能匿名改 .env）", c7 == "401", "http=%s" % c7)
c9 = code_of("GET", "/api/admin/info")
ok("/api/admin/info 未被新路由抢占（401）", c9 == "401", "http=%s" % c9)

# v0.8.0：管理台客户端配置接口 —— 同样必须 401，谁都能改配置是灾难
c10 = code_of("GET", "/api/admin/client-config")
ok("GET /api/admin/client-config 已注册且要鉴权（401）", c10 == "401", "http=%s" % c10)
c11 = code_of("POST", "/api/admin/client-config", '{"payload":{}}')
ok("POST /api/admin/client-config 未登录时 401", c11 == "401", "http=%s" % c11)
c12 = code_of("POST", "/api/admin/client-config/rollback", '{"version":1}')
ok("POST /api/admin/client-config/rollback 未登录时 401", c12 == "401", "http=%s" % c12)
c13 = code_of("GET", "/api/admin/client-config/applied")
ok("GET /api/admin/client-config/applied 已注册且要鉴权（401）", c13 == "401",
   "http=%s" % c13)

# v0.9.0：动态模块接口 —— 三条管理台接口 + 两条客户端接口，全部必须鉴权。
# 这几条如果匿名可达，等于任何人都能往所有客户端下发页面（最坏是个钓鱼页面）。
c16 = code_of("GET", "/api/admin/modules")
ok("GET /api/admin/modules 已注册且要鉴权（401）", c16 == "401", "http=%s" % c16)
c17 = code_of("POST", "/api/admin/modules", '{"moduleId":"x","title":"x","body":[]}')
ok("POST /api/admin/modules 未登录时 401（不能匿名下发页面）", c17 == "401",
   "http=%s" % c17)
c18 = code_of("GET", "/api/admin/modules/demo/submissions")
ok("GET /api/admin/modules/:id/submissions 已注册且要鉴权（401）", c18 == "401",
   "http=%s" % c18)
c19 = code_of("GET", "/api/client/modules/demo")
ok("GET /api/client/modules/:id 已注册且要鉴权（401）", c19 == "401", "http=%s" % c19)
c20 = code_of("POST", "/api/client/modules/demo/submit", '{"data":{}}')
ok("POST /api/client/modules/:id/submit 需鉴权（401）", c20 == "401", "http=%s" % c20)
# 反向确认：新路由没有把老路由吃掉
c21 = code_of("GET", "/api/client/config")
ok("/api/client/config 未被 /modules/:id 抢占（仍是 401）", c21 == "401", "http=%s" % c21)

# ---------- ② 客户端配置下发 ----------
# bootstrap 是**唯一**免鉴权的口子，这里必须断言它返回 200。
# 如果哪天有人给它加了鉴权中间件，客户端会集体拿不到地址 —— 这条会先炸。
print("\n[2] v0.8.0 客户端配置下发（bootstrap 必须免鉴权）")
boot, _ = run("curl -s -m 10 http://127.0.0.1:%d/api/client/bootstrap" % PORT)
ok("/api/client/bootstrap 返回内容", len(boot) > 20, boot[:200])
try:
    b = json.loads(boot)
except Exception:
    b = {}
ok("bootstrap 免鉴权（能解析出 JSON 即未被 401 拦下）", bool(b), boot[:200])
ok("bootstrap 带 configVersion", isinstance(b.get("configVersion"), int),
   "实际=%r" % b.get("configVersion"))
ok("bootstrap 带 serverVersion", bool(b.get("serverVersion")),
   "实际=%r" % b.get("serverVersion"))
pl = b.get("payload")
ok("bootstrap 带 payload 对象", isinstance(pl, dict), "实际=%r" % type(pl).__name__)

# 硬边界：bootstrap 对未授权者可见，所以只能吐公开信息。
# 顶层键必须是白名单内的，多一个键都说明有人把不该下发的东西塞进去了。
ALLOWED_PAYLOAD_KEYS = {
    "serverAddresses", "features", "minClientVersion",
    "upgradeUrl", "announcements", "maintenance",
}
if isinstance(pl, dict):
    extra = set(pl.keys()) - ALLOWED_PAYLOAD_KEYS
    ok("payload 只含白名单键（未泄漏用户/凭据数据）", not extra,
       "多余键=%s" % sorted(extra))
    ok("payload 顶层键齐全（客户端按结构解析，缺键会走默认值）",
       ALLOWED_PAYLOAD_KEYS.issubset(set(pl.keys())),
       "缺=%s" % sorted(ALLOWED_PAYLOAD_KEYS - set(pl.keys())))
    ok("serverAddresses 是数组", isinstance(pl.get("serverAddresses"), list),
       "实际=%r" % type(pl.get("serverAddresses")).__name__)
    ok("features 是对象", isinstance(pl.get("features"), dict),
       "实际=%r" % type(pl.get("features")).__name__)

# v0.9.0：bootstrap 还要带动态模块列表。硬边界在这里体现为**只给全员可见的**：
# 一旦把"仅管理员可见"的模块也塞进来，等于向未登录者公开了权限结构。
# 注意 modules **不在** payload 里（payload 仍是老白名单），属于平级的独立字段。
mods = b.get("modules")
ok("bootstrap 带 modules 数组（未登录也能拿到入口）", isinstance(mods, list),
   "实际=%r" % type(mods).__name__)
if isinstance(mods, list):
    targeted = [m.get("moduleId") for m in mods
                if (m.get("visibleTo") or {}).get("roles")
                or (m.get("visibleTo") or {}).get("userIds")]
    ok("bootstrap 只下发「所有人可见」的模块（不泄漏权限结构）", not targeted,
       "混入了定向模块=%s" % targeted)
    bad_mod = [m.get("moduleId") for m in mods
               if not m.get("moduleId") or "body" not in m]
    ok("下发的每个模块都带 moduleId 与 body（客户端可直接渲染）", not bad_mod,
       "残缺=%s" % bad_mod)
    ok("下发模块里没有停用的（enabled=false）",
       not [m for m in mods if m.get("enabled") is False],
       "混入停用模块")

# 登录态接口仍需鉴权（配置内容与用户定向预留位）
c14 = code_of("GET", "/api/client/config")
ok("GET /api/client/config 需鉴权（401）", c14 == "401", "http=%s" % c14)
c15 = code_of("POST", "/api/client/report-applied", '{"configVersion":1}')
ok("POST /api/client/report-applied 需鉴权（401）", c15 == "401", "http=%s" % c15)

# ---------- ③ 数据库表 ----------
print("\n[3] v0.8.0 配置表")
tables, _ = run(S + "docker exec xiaozhi-im node -e \""
                "const {DatabaseSync}=require('node:sqlite');"
                "const db=new DatabaseSync('/data/xiaozhi-im.db');"
                "console.log(db.prepare("
                "\\\"SELECT name FROM sqlite_master WHERE type='table'\\\""
                ").all().map(x=>x.name).join(','))\"")
tl = tables.strip().splitlines()[-1] if tables.strip() else ""
ok("client_configs 表已建", "client_configs" in tl, "表=%s" % tl[:200])
ok("config_applied 表已建", "config_applied" in tl, "表=%s" % tl[:200])
ok("app_modules 表已建（v0.9.0 动态模块定义）", "app_modules" in tl,
   "表=%s" % tl[:300])
ok("module_submissions 表已建（v0.9.0 表单提交记录）",
   "module_submissions" in tl, "表=%s" % tl[:300])

# 有版本快照：懒播种保证至少有一条 version=1（客户端永远拿得到合法结构）
cnt, _ = run(S + "docker exec xiaozhi-im node -e \""
             "const {DatabaseSync}=require('node:sqlite');"
             "const db=new DatabaseSync('/data/xiaozhi-im.db');"
             "console.log(db.prepare('SELECT COUNT(*) n FROM client_configs')"
             ".get().n)\"")
n_raw = cnt.strip().splitlines()[-1] if cnt.strip() else ""
ok("client_configs 至少有 1 条版本快照", n_raw.isdigit() and int(n_raw) >= 1,
   "count=%r" % n_raw)

# ---------- ④ 管理台 ----------
print("\n[4] 管理台静态产物")
idx, _ = run("curl -s -m 8 http://127.0.0.1:%d/admin/" % PORT)
ok("/admin/ 可访问", "<div id=\"app\">" in idx or "assets/" in idx)
m = re.search(r'src="([^"]*assets/[^"]*\.js)"', idx)
if m:
    js_path = m.group(1)
    if not js_path.startswith("http"):
        js_path = "http://127.0.0.1:%d%s" % (PORT, js_path)
    js, _ = run("curl -s -m 15 '%s'" % js_path)
    ok("管理台 JS 里有「系统帮助」页", "系统帮助" in js, "已取 %d 字节" % len(js))
    ok("管理台有中继配置向导", "音视频中继配置" in js and "Turn 令牌 ID" in js)
    # v0.8.0：客户端配置页
    ok("管理台有「客户端配置」页", "客户端配置" in js, "未进产物 → 需重新构建管理台")
    ok("管理台配置页有同步状态展示", "同步状态" in js)
    # v0.9.0：动态模块页（判据与本地 verify_release.py 保持一致）
    ok("管理台有「动态模块」页", "模块清单" in js, "未进产物 → 需重新构建管理台")
    ok("动态模块页有模板库入口", "模板库" in js)
    ok("动态模块页有可见范围设置", "可见范围" in js)
    ok("管理台 JS 已不再出现 Tailchat 字样", "Tailchat" not in js)
    # ⚠️ 判据按**形态**检测，绝不写真实凭据 —— 本仓库公开，
    #    把真值写进脚本等于自曝 KEY_ID / API Token（踩过这个坑）。
    cred_leak = re.search(
        r'CF_TURN_(?:KEY_ID|API_TOKEN)\s*[:=\'"]+\s*[0-9a-fA-F]{16,}', js)
    ok("管理台产物里没有明文密钥", not cred_leak,
       "产物里出现了凭据键值对，必须改成占位符/遮盖回显")
else:
    ok("能从 index.html 里解析出 JS 入口", False, idx[:200])

# ---------- ⑤ 服务端版本 ----------
print("\n[5] 服务端版本号")
ver, _ = run(S + "docker exec xiaozhi-im cat /app/package.json")
vm = re.search(r'"version"\s*:\s*"([^"]+)"', ver)
vs = vm.group(1) if vm else ""
ok("服务端 package.json 版本为 0.9.0", vs == "0.9.0", "实际=%s" % vs)

# ---------- ⑥ v0.7.0 多方通话回归 ----------
print("\n[6] v0.7.0 多方通话代码仍健在（回归）")
calljs, _ = run(S + "docker exec xiaozhi-im cat /app/src/call.js")
if len(calljs) > 500:
    for token, label in [
        ("participants", "参与者模型"),
        ("activeMembers", "在线人数统计"),
        ("MAX_PARTICIPANTS", "人数上限"),
        ("isOneToOne", "1v1 判定"),
        ("call:peer-joined", "新人加入广播"),
    ]:
        ok("call.js 含 %s（%s）" % (token, label), token in calljs)
    ok("1v1 判定只看 group、没回退去数 participants.size",
       "participants.size <= 2" not in calljs,
       "又出现用 size 判 1v1 的写法，群通话收尾会误判")
else:
    ok("能读到容器内 /app/src/call.js", False, "长度=%d" % len(calljs))
wsjs, _ = run(S + "docker exec xiaozhi-im cat /app/src/ws.js")
ok("ws.js 已接入 call:join", "call:join" in wsjs)

# ---------- ⑦ v0.8.0 配置中心代码进容器 ----------
print("\n[7] v0.8.0 配置中心代码已进容器")
ccjs, _ = run(S + "docker exec xiaozhi-im cat /app/src/clientconfig.js")
if len(ccjs) > 500:
    for token, label in [
        ("client_configs", "版本快照表"),
        ("validate", "白名单校验"),
        ("publish", "发布"),
        ("rollback", "回滚"),
        ("reportApplied", "生效上报"),
        ("appliedStatus", "同步状态"),
        ("minClientVersion", "最低版本策略"),
    ]:
        ok("clientconfig.js 含 %s（%s）" % (token, label), token in ccjs)
else:
    ok("能读到容器内 /app/src/clientconfig.js", False, "长度=%d" % len(ccjs))

cjs, _ = run(S + "docker exec xiaozhi-im cat /app/src/routes/client.js")
ok("routes/client.js 有 bootstrap 路由", "/bootstrap" in cjs)
ok("routes/client.js 有 report-applied 路由", "/report-applied" in cjs)
# bootstrap 必须免鉴权：截取它到下一个 router.get 之间的函数体，
# 里面不该出现鉴权调用（uidOf 定义在文件上方，不能用"文件里有 uidOf"来判）。
seg = b""
raw = cjs.encode("utf-8")
if b"'/bootstrap'" in raw:
    seg = raw.split(b"'/bootstrap'", 1)[1].split(b"router.get", 1)[0]
ok("bootstrap 处理函数体未做鉴权（否则未登录客户端拿不到地址）",
   bool(seg) and b"uidOf" not in seg and b"verifyToken" not in seg,
   "函数体里出现了鉴权调用")

# ---------- ⑦b v0.9.0 动态模块代码进容器 ----------
print("\n[7b] v0.9.0 动态模块代码已进容器")
amjs, _ = run(S + "docker exec xiaozhi-im cat /app/src/appmodules.js")
if len(amjs) > 500:
    # 挑的都是"闸门"证据，不是普通函数名 —— 缺了任何一条，动态页面就从
    # "运营能力"变成"攻击面"（任意 URL 转发 / 写死色值 / 伪造字段落库）。
    for token, label in [
        ("COMPONENTS", "封闭组件集（8 种）"),
        ("ACTIONS", "动作白名单"),
        ("/api/hooks/", "只允许 /api/hooks/ 前缀（防 SSRF）"),
        ("COLORS", "颜色语义枚举（深色主题自适应）"),
        ("MAX_DEPTH", "嵌套深度上限"),
        ("MAX_COMPONENTS", "组件总数上限"),
        ("TEMPLATES", "模板库"),
        ("sanitizeSubmission", "提交按服务端 schema 清洗"),
        ("listVisible", "可见性过滤"),
        ("versionGte", "最低版本闸门"),
    ]:
        ok("appmodules.js 含 %s（%s）" % (token, label), token in amjs)
    tpl_ids = re.findall(r"moduleId: '([a-z_]+)'", amjs)
    ok("模板库至少 4 套（设备报修/库存概览/值班表/销售看板）",
       len(set(tpl_ids)) >= 4, "实际=%s" % sorted(set(tpl_ids)))
    ok("模板库覆盖表单类模板（设备报修）", "device_repair" in amjs)
else:
    ok("能读到容器内 /app/src/appmodules.js", False, "长度=%d" % len(amjs))

cjs2, _ = run(S + "docker exec xiaozhi-im cat /app/src/routes/client.js")
ok("routes/client.js 有 modules/:id 路由", "/modules/:id" in cjs2)
ok("routes/client.js 有 modules/:id/submit 路由", "/modules/:id/submit" in cjs2)
if b"'/bootstrap'" in cjs2.encode("utf-8"):
    seg2 = cjs2.encode("utf-8").split(b"'/bootstrap'", 1)[1].split(b"router.get", 1)[0]
    ok("bootstrap 分支确实按可见性过滤了模块（不是全量下发）",
       b"listVisible" in seg2 and b"visibleTo" in seg2 and b"list()" not in seg2,
       "bootstrap 里可能直接吐了全部模块")

admjs, _ = run(S + "docker exec xiaozhi-im cat /app/src/routes/admin.js")
ok("admin.js 有模块 CRUD 路由", "'/modules'" in admjs and "appmodules" in admjs)
ok("admin.js 的模块接口返回能力清单与模板库",
   "capability" in admjs and "templates" in admjs)

# ---------- ⑧ ICE 下发 ----------
print("\n[8] ICE 下发（中继配置）")
ice, _ = run("curl -s -m 10 http://127.0.0.1:%d/api/call/ice" % PORT)
ok("ICE 接口有响应", len(ice) > 20, ice[:200])
ok("返回 turnSources 字段", "turnSources" in ice, ice[:300])
ok("不再下发已失效的 stun.qq.com", "stun.qq.com" not in ice, ice[:200])

# ⚠️ 这两条必须做成**会失败的断言**。
# 血泪教训：之前只把中继来源当"打印一行提示"，于是容器里 TURN_URLS 因重建丢失、
# turnSources 变成 [] 时，脚本照样报全绿 —— 假通过比没检查更危险。
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
    print("     ⚠ 只有自建 coturn：它要公网端口能进得来才对外可用")
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
