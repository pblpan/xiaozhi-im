# -*- coding: utf-8 -*-
"""线上只读探针：在容器内用同一把 JWT_SECRET 现签 admin token，
打本轮新增/修改的接口，**必须看到 200 与真数据**才算上线成功。

🔴 为什么不能只看 401（踩过的坑）：
   未登录访问照样回 401（路由注册了就 401），看着像"上线了"；实际上文件没推上去、
   或 require 的模块还是旧的，要带 token 才 500。
   那次就是 admin.js 上去了、它 require 的 remote.js 还是旧的。

用法: python deploy/_verify_0_22_0_live.py
凭据: from fnos_auth import HOST, USER, PASS（不落盘）
"""
import base64
import json
import sys
import os
import shlex

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
# 🔴 用现成的 fnos_ssh（别自己拼 paramiko）：它的 run() 默认走 `sudo -S`，
#    而 SSH 那个账号不在 docker 组 —— 直接 docker exec 会 permission denied。
from fnos_ssh import connect, run  # noqa: E402
from fnos_auth import HOST  # noqa: E402

PASS_N = 0
FAIL_N = 0


def ok(cond, name, extra=""):
    global PASS_N, FAIL_N
    if cond:
        print("  \033[32m✓\033[0m " + name)
        PASS_N += 1
    else:
        print("  \033[31m✗\033[0m " + name + (("  → " + str(extra)) if extra else ""))
        FAIL_N += 1


# 容器内跑的探针代码。路径 /app 就是 server 目录（bind mount）。
PROBE = r"""
const jwt = require('/app/src/auth.js');
const db  = require('/app/src/db.js');
const cfg = require('/app/src/config.js');
const admin = db.prepare('SELECT id,username,role FROM users WHERE username=?').get(cfg.ADMIN_USERNAME);
if (!admin) { console.log('PROBE:' + JSON.stringify({err:'no admin user'})); process.exit(0); }
const token = jwt.signToken({ uid: admin.id, role: admin.role });
const H = { 'Content-Type': 'application/json', Authorization: 'Bearer ' + token };
const out = {};
const J = 'http://127.0.0.1:3602';

async function main() {
  // ① 新增：数据体检（本轮全新接口）
  const r1 = await fetch(J + '/api/admin/orphans/scan', { headers: H });
  out.orphanScanStatus = r1.status;
  const j1 = await r1.json().catch(() => null);
  out.orphanChecked = j1 && j1.summary ? j1.summary.checked : null;
  out.orphanPurgeable = j1 && j1.summary ? j1.summary.purgeable : null;
  out.orphanKept = j1 && j1.summary ? j1.summary.kept : null;
  out.keptHasWhy = !!(j1 && j1.items && j1.items.some(i => i.purgeable === false && i.why));
  out.itemsCount = j1 && j1.items ? j1.items.length : 0;

  // ② 新增：/api/ready（会真查库）
  const r2 = await fetch(J + '/api/ready');
  out.readyStatus = r2.status;
  out.readyBody = await r2.json().catch(() => null);

  // ③ 新增：双令牌（登录返回 refreshToken 且已落库）
  const r4 = await fetch(J + '/api/auth/login', {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ username: cfg.ADMIN_USERNAME, password: cfg.ADMIN_PASSWORD })
  });
  const j4 = await r4.json().catch(() => null);
  out.loginStatus = r4.status;
  out.loginHasToken = !!(j4 && j4.token);
  out.loginHasRefresh = !!(j4 && j4.refreshToken);
  out.refreshInDb = !!(j4 && j4.refreshToken &&
    db.prepare('SELECT COUNT(*) c FROM refresh_tokens').get().c > 0);

  // ④ 新增：索引与触发器真的进了库
  out.friendshipsIdx = db.prepare(
    "SELECT name FROM sqlite_master WHERE type='index' AND name='idx_friendships_friend'").get() ? 1 : 0;
  out.fkTriggers = db.prepare(
    "SELECT COUNT(*) c FROM sqlite_master WHERE type='trigger' AND name LIKE 'trg_fk%'").get().c;

  // ⑤ 改：401/403 语义（不存在的 uid → 该 401 不是 403）
  const bad = jwt.signToken({ uid: 999999, role: 'admin' });
  const r6 = await fetch(J + '/api/admin/orphans/scan', { headers: { Authorization: 'Bearer ' + bad } });
  out.ghostUserStatus = r6.status;

  // ⑥ 改：登录限流（连打 8 次错密码，应出现 429）
  const codes = [];
  for (let i = 0; i < 8; i++) {
    const rr = await fetch(J + '/api/auth/login', {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ username: 'nobody_probe', password: 'wrong' })
    });
    codes.push(rr.status);
  }
  out.loginRateLimitHit429 = codes.includes(429);
  out.rateLimitCodes = codes.join(',');

  console.log('PROBE:' + JSON.stringify(out));
}
main().catch(e => console.log('PROBE:' + JSON.stringify({ fatal: String(e && e.message) })));
"""


def main():
    b64 = base64.b64encode(PROBE.encode()).decode()
    cmd = "docker exec xiaozhi-im sh -c %s" % shlex.quote("echo %s | base64 -d | node" % b64)

    print("线上验证 0.22.0（带管理员 token，不只看 401）")
    print("连 %s …\n" % HOST)
    c = connect()
    try:
        out = run(c, cmd, timeout=150)
    finally:
        try:
            c.close()
        except Exception:
            pass

    line = [l for l in out.splitlines() if l.startswith("PROBE:")]
    if not line:
        print("💥 没拿到探针输出。原始输出：\n" + out[:1500])
        return 1

    d = json.loads(line[0][len("PROBE:"):])
    if d.get("fatal"):
        print("💥 容器内脚本报错：" + d["fatal"])
        return 1
    if d.get("err"):
        print("💥 " + d["err"])
        return 1

    print("=== 新增：数据体检（孤儿巡检）===")
    ok(d.get("orphanScanStatus") == 200, "GET /api/admin/orphans/scan → 200", d.get("orphanScanStatus"))
    ok((d.get("orphanChecked") or 0) >= 20,
       "体检了 %s 项关联（应 ≥20）" % d.get("orphanChecked"))
    ok(d.get("itemsCount", 0) >= 20, "返回 %s 条关联明细" % d.get("itemsCount"))
    ok(d.get("keptHasWhy") is True, "保留类给出了「为什么不建议清」的说明")
    print("    实测：可清理 %s 行 / 保留 %s 行" % (d.get("orphanPurgeable"), d.get("orphanKept")))

    print("\n=== 新增：就绪检查 ===")
    ok(d.get("readyStatus") == 200, "GET /api/ready → 200", d.get("readyStatus"))
    ok((d.get("readyBody") or {}).get("db") == "ready", "/api/ready 报 db=ready（真查了库）")

    print("\n=== 新增：双令牌 ===")
    ok(d.get("loginStatus") == 200, "登录 → 200", d.get("loginStatus"))
    ok(d.get("loginHasToken"), "返回 access token（字段名没变，旧客户端不受影响）")
    ok(d.get("loginHasRefresh"), "返回 refreshToken（新增字段）")
    ok(d.get("refreshInDb"), "refresh 令牌已落库（只存哈希）")

    print("\n=== 新增：索引与触发器已进库 ===")
    ok(d.get("friendshipsIdx") == 1, "idx_friendships_friend 索引已建")
    ok((d.get("fkTriggers") or 0) >= 14, "引用完整性触发器 %s 个（应 ≥14）" % d.get("fkTriggers"))

    print("\n=== 改：401/403 语义修正 ===")
    ok(d.get("ghostUserStatus") == 401, "用户已不存在的 token → 401（不是 403）", d.get("ghostUserStatus"))

    print("\n=== 改：登录限流 ===")
    ok(d.get("loginRateLimitHit429"), "连续错密码触发了 429（无限流已修）", d.get("rateLimitCodes"))
    print("    返回码序列：%s" % d.get("rateLimitCodes"))

    print("\n" + "=" * 52)
    print("通过 %d / %d" % (PASS_N, PASS_N + FAIL_N))
    print("=" * 52)
    return 0 if FAIL_N == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
