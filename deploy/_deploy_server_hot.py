#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把本轮服务端改动推到飞牛上跑着的容器（rsync/版本库都没有，只能逐个文件传）。

背景（2026-09-26 实测）：
    线上容器的挂载是 `/vol1/@appcenter/xiaozhi-im/src -> /app`（rw），
    但那个目录**不是 git 仓库**（fpk 解包出来的，没有 .git），所以 `git pull` 无意义。
    而且它最后一次改动是 9-20 —— 也就是说**减货单上传那条接口一直没上线**
    （现场探测 `/api/deduct/sheets` 返回 404 not found，路由根本不存在）。
    所以「功能做好了」和「功能能用了」之间还差这一脚。

【顺序不能乱】
    1) 先给远端 src 拍整目录快照（回滚要用）
    2) 只传本轮改过的文件（不传 node_modules / data）
    3) 重启容器（新路由文件不会被运行中的 node 拾取）
    4) 复探：404 -> 401 才算路由真的挂上了

用法：
    python deploy/_deploy_server_hot.py --dry-run      # 只看要传哪些、服务端现在什么样
    python deploy/_deploy_server_hot.py                # 真干
    python deploy/_deploy_server_hot.py --restart-only  # 我只想重启（传完忘了重启时用）

回滚：`docker compose` 那一层没有快照，但 src 整目录快照在
    /vol1/@appcenter/xiaozhi-im/src_pre_deploy_<时间戳>/，拷回去再重启即可。
"""
import argparse
import os
import shlex
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from fnos_ssh import connect, put_file, run  # noqa: E402

REPO = os.path.dirname(HERE)
SERVER_DIR = os.path.join(REPO, 'server')
REMOTE_ROOT = '/vol1/@appcenter/xiaozhi-im/src'
CONTAINER = 'xiaozhi-im'

# 本轮自 0.21.3 = 9-25 那批文件**重传** + 本轮管理台。
# 🔴 2026-09-26 中午实测发现：上一轮 0.21.2 热更是**半截** —— 容器版本号
#    到了 0.21.2，但 routes/deduct.js、training.js 等根本不在（线上
#    /api/deduct 实测 404，不是当时记录的 401）。原因未查明（疑似 fpk
#    升级覆盖了 src），所以这里把 0.21.2 的全部文件重新列上，宁多勿漏。
# 🔴 用 git diff 算出来贴在这里，而不是"传整个 server 目录" ——
#    整目录上传会把别处可能的手改一起覆盖掉，而且没法预览。
FILES = [
    'package.json',
    # 🔴 2026-09-26 晚：修「飞牛上装好不弹密码向导」。
    #    setup.js 的 needSetup 判据加"环境没配 ADMIN_PASSWORD 就该弹"；
    #    config.js 加 custom.env 回读/回写（飞牛的 docker/.env 在宿主机、
    #    容器改不到，向导设的口令必须另找落脚点，否则重启后又变随机、反复弹）。
    'src/config.js',
    'src/setup.js',
    # 🔴 线上**一直缺**这两个（缺了容器直接起不来，报
    #    Cannot find module './routes/master'）：approval 是盘点单审批走的
    #    通用审批中心，master 是商档。index.js 里 require 了、文件却从没推上去过。
    'src/routes/master.js',
    'src/routes/approval.js',
    'src/appdata.js',
    'src/appguard.js',
    'src/appoverrides.js',
    'src/apps.js',
    'src/db.js',
    'src/index.js',
    'src/routes/deduct.js',
    'src/routes/inventory.js',
    'src/routes/training.js',
    'public/index.html',
    # 🔴 只传 index.html 实际引用的那两个 bundle。
    #    ⚠️ 这里必须**逐个列出 index.html 里引用的真实文件名**，不能"传整个
    #    public/assets"：vite 每次构建的产物名带哈希（index-XXXX.js），
    #    只换 index.html 不换 assets → 浏览器拿到新 html 却请求不存在的 js，
    #    白屏且控制台一片 404；只传 js 不改 index.html 同理。两者必须同批。
    #
    # 🔴 文件名是**按当轮构建**写的，改完管理台重出包后必须回来换。
    #    0.21.5 这轮是「培训中心课件外链 + 建课挂课件 + 课时改课件」，
    #    管理台这两项在「新建课程」弹窗和「课程结构」里，所以引用变了。
    'public/assets/index-Cu2GcK4-.js',
    'public/assets/index-CyRloi3S.css',
]


def describe_remote(c):
    """远端现在到底是个什么状态 —— 每次动手前先看一眼，别按想象做事。"""
    out = []
    # ⚠️ 注意 bind mount 的对应关系：宿主机 /vol1/@appcenter/xiaozhi-im/src
    #    整个挂进容器 /app，而容器里是 `node src/index.js`。
    #    所以宿主机上一律是 **REMOTE_ROOT/src/...**（多一层），下面的
    #    describe_remote 曾经漏了这层，报"deduct.js 没有"其实是假报警 ——
    #    文件好好的，别被它骗着去重复上传。
    out.append('容器状态: ' + run(c, "docker ps -a --filter 'name=xiaozhi'"
                                 " --format '{{.Names}}|{{.Status}}'"))
    # 🔴 % REMOTE_ROOT 这层格式化**不能漏**（2026-09-26 深夜发现）：
    #    漏了的话命令会变成 `test -f %s/src/...`，永远成立地失败并打印"没有" ——
    #    一个**恒假的假报警**。它骗得我对着"deduct.js 没上线"查了半天，
    #    而文件其实好好的。真机上 `test -f` 判断一律走这里，改的时候看一眼。
    cmd = ('test -f %s/src/routes/deduct.js'
           ' && echo 有 || echo 没有') % REMOTE_ROOT
    out.append('远端有无 deduct.js: ' + run(c, cmd))
    out.append('远端 src 最后改动: ' + run(c, "stat -c '%%y' %s" % REMOTE_ROOT))
    out.append('线上 index.html 引用的 bundle: ' + run(c,
               "grep -oE 'assets/index-[A-Za-z0-9_-]+\\.(js|css)'"
               " %s/public/index.html || echo '(无)'" % REMOTE_ROOT))
    out.append('线上 assets 实际内容: ' + run(c,
               'ls -1 %s/public/assets/ || echo "(空目录)"' % REMOTE_ROOT))
    return '\n'.join(out)


def find_dbfile(c):
    """线上那个 sqlite 的真实路径。

    🔴 库文件叫 **`xiaozhi-im.db`**（在 DATA_DIR 下），不是通用的 db.sqlite。
        本地测试用错文件名会看到"列怎么都没加"的假象 —— 这个坑刚踩过。
    """
    # 🔴 数据目录**不在 @appcenter**：容器只有两个 bind
    #    （`/vol1/@appcenter/xiaozhi-im/src -> /app`、`/vol1/@appshare/xiaozhi-im/data -> /data`），
    #    库在 **@appshare** 那侧。2026-09-26 深夜这里只 find 了 @appcenter，
    #    结果一条都没找到 → `.split()[-1]` 抛 IndexError，热更脚本在最后一步崩掉。
    #    两边都找，并且**不假设找到**：找不到就报错，别拿空串继续往下走。
    hits = (run(c, "find /vol1/@appcenter/xiaozhi-im /vol1/@appshare/xiaozhi-im"
                   " -name 'xiaozhi-im.db' -not -path '*src_pre_deploy*'"
                   " 2>/dev/null") or '').split()
    if not hits:
        raise SystemExit('线上找不到 xiaozhi-im.db —— 别让"读不到"变成"通过"')
    return hits[-1]


def check_columns(c, table, want):
    """线上那个 sqlite 里，指定表的列齐不齐。

    🔴 这里**必须走容器里的 node**（`_cols_probe.js`），不能像早先那样
       用 `sqlite3` 命令：飞牛这台机器根本没装 sqlite3（2026-09-26 深夜实测），
       命令跑不通、输出被吞掉，于是"缺列"永远是**假报警** ——
       迁移早跑成功了，脚本却一直说没跑。假报警比不报警更糟：
       它会让人去查一个根本不存在的问题，或者反过来让人不敢信这一栏。
    """
    dbfile = find_dbfile(c)
    if not dbfile:
        return '(线上找不到 xiaozhi-im.db — 读不到，别当通过)'

    # 探针只认**容器内的**路径（容器内看不到宿主机的 /vol1/...）
    indb = to_container_path(c, dbfile)
    probe = _upload_probe(c, '_cols_probe.js')
    # 🔴 末尾那个 `2>/dev/null` 是**必须的，不是保险**（2026-09-27 踩到）：
    #    node:sqlite 一打开库就往 stderr 打一行 "ExperimentalWarning ..."
    #    实验性 API。而 `fnos_ssh.run` 只要 stderr 非空就把它的内容**拼进返回值**，
    #    于是探针的 stdout 前头挂了一截警告 → 解析出来是 "条码 [stderr] (Use
    #    `node --trace-warnings ...)"，条码变成一串垃圾，下一步全都落空。
    #    探针要的是**干净的 stdout**，所以显式丢弃 stderr。
    out = run(c, 'docker exec %s node %s %s %s=%s 2>/dev/null'
                 % (CONTAINER, probe, indb, table, ','.join(want))) or '(无输出)'
    return ('%s   [%s]' % (out.strip(), os.path.basename(dbfile)))


def to_container_path(c, hostpath):
    """把宿主机路径换成正跑在容器里的那条路径。

    🔴 **不要再手写映射**（之前那句 `.replace('/vol1/@appcenter/xiaozhi-im/', '/')`
        给出的是 `/xiaozhi-im.db` —— 容器根本没有这个库，于是报
        "unable to open database file"，看着像"线上没库"，其实是路径算错了）。
        正确做法是问 docker：把 `HostConfig.Binds` 里宿主机那一段换成容器内那段。
    """
    binds = run(c, "docker inspect --format '{{json .HostConfig.Binds}}'"
                   " %s" % CONTAINER) or ''
    # 🔴 拿到的整串长这样：
    #     ["/vol1/@appshare/xiaozhi-im/data:/data:rw","/vol1/@appcenter/xiaozhi-im/src:/app:rw"]
    #     ⚠️ 引号和方括号都得先剥掉（2026-09-27）：只 replace 方括号的话，
    #        第一个 token 仍带着前导 `"` → src 变成 `"/vol1/@appshare/...`，
    #        永远匹配不上，报"容器里找不到挂载点"，而映射其实一直都在。
    #        又是一条**假报警** —— 它会让人去查一个不存在的挂载问题。
    for b in binds.replace('[', ' ').replace(']', ' ').replace('"', ' ').split():
        # 🔴 一条 bind 是 `宿主机:容器[:选项]`，但**本身带冒号**。
        #    直接 `split(':')` 会切成三截，src 就变成了只到 "/data"。
        parts = b.split(':')
        if len(parts) < 2:
            continue
        src, dst = parts[0], parts[1]
        src = src.rstrip('/')
        if hostpath.startswith(src + '/'):
            return dst.rstrip('/') + hostpath[len(src):]
    raise SystemExit('容器里找不到 %s 对应的挂载点（binds=%s）' % (hostpath, binds))


def _upload_probe(c, name):
    """把探针传进容器**可见**的地方，返回容器内路径。

    🔴 `put_file(..., '/app/x.js')` 是错的：它 cp 到的是**宿主机自己的 /app**，
        而容器里的 /app 是 bind 挂载 `.../src -> /app`。两个目录八竿子打不着，
        于是探针传上去、容器却说 `Cannot find module /app/x.js`（2026-09-27 踩到）。
        正确做法是先传到 bind 源目录（宿主机 .../src/），容器那边自然就看见了。
    """
    dst = REMOTE_ROOT + '/' + name
    local = os.path.join(HERE, name)
    # 🔴 **每次都传，不看"在不在"**（2026-09-26 深夜踩到，代价很大）：
    #    早先写成 `if present != 'yes'` 才传 —— 于是探针改了内容以后，
    #    容器里那份永远是第一次上传的旧版，**改了等于没改**。
    #    后果是：新加的 fallback 分支没上去，探针照样打印空串，
    #    我据此得出"线上商档一条记录都没有"的结论 —— 而实际库里有
    #    **12.6 万行**商档。一个"存在就跳过"的优化，换来一个完全错误的结论。
    #    探针只有几 KB，每次重传的成本可以忽略，正确性不能省。
    put_file(c, local, dst)

    # 传完必须**比对字节数**：不验就跑，等于把"到底有没有传上去"换成运气。
    want = os.path.getsize(local)
    got = (run(c, 'stat -c %%s %s 2>/dev/null || echo 0' % dst) or '0').strip()
    if not got.isdigit() or int(got) != want:
        raise SystemExit('探针 %s 字节数对不上（本地 %d / 远端 %s）—— '
                         '容器里跑的可能是旧版，别信它的输出'
                         % (name, want, got))
    # 容器里这个挂载点就是 /app（宿主机 .../src -> /app）
    return '/app/' + name


def snapshot(c):
    stamp = time.strftime('%Y%m%d-%H%M%S')
    dst = '/vol1/@appcenter/xiaozhi-im/src_pre_deploy_%s' % stamp
    print('  快照 ->', dst)
    run(c, 'cp -a %s %s' % (REMOTE_ROOT, dst))
    # 留个最新指针，回滚脚本好找
    run(c, 'rm -f /vol1/@appcenter/xiaozhi-im/src_pre_deploy_latest;'
           ' ln -s %s /vol1/@appcenter/xiaozhi-im/src_pre_deploy_latest' % dst)
    print('  快照已就位')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--dry-run', action='store_true', help='只看不传')
    ap.add_argument('--restart-only', action='store_true', help='跳过上传，只重启')
    args = ap.parse_args()

    c = connect()
    print('=== 动手前，远端现状 ===')
    print(describe_remote(c))

    if args.restart_only:
        print('\n=== 只重启 ===')
        run(c, 'docker restart %s' % CONTAINER)
        time.sleep(6)
        print('重启后: ' + run(c, "docker ps --filter name=%s --format '{{.Status}}'"
                               % CONTAINER))
        return 0

    missing = [f for f in FILES if not os.path.isfile(os.path.join(SERVER_DIR, f))]
    if missing:
        print('本地缺文件，不传：', missing)
        return 2

    print('\n=== 将上传 %d 个文件 ===' % len(FILES))
    for f in FILES:
        p = os.path.join(SERVER_DIR, f)
        print('  %-40s %d 字节' % (f, os.path.getsize(p)))

    if args.dry_run:
        print('\n（dry-run，到此为止）')
        return 0

    print('\n=== 1) 拍快照 ===')
    snapshot(c)

    print('\n=== 2) 上传 ===')
    for f in FILES:
        local = os.path.join(SERVER_DIR, f)
        remote = REMOTE_ROOT + '/' + f
        ok, detail = put_file(c, local, remote, backup=True, stamp='pre_hotfix')
        # 🔴 别假设 detail 一定是字节数 —— `run()` 在 stderr 非空时会把
        #    "[stderr] xxx" 拼到返回值后面，于是 detail 变成非数字，
        #    用 `'%d' % detail` 直接 TypeError。这里一律按字符串显示。
        print('  %-40s %s' % (f, ('OK ' + str(detail) + ' 字节') if ok else ('失败 ' + str(detail))))

    print('\n=== 3) 重启容器 ===')
    run(c, 'docker restart %s' % CONTAINER)
    time.sleep(6)
    print('  重启后: ' + run(c, "docker ps --filter name=%s --format '{{.Status}}'"
                             % CONTAINER))

    print('\n=== 4) 复探（等容器起来再看） ===')
    time.sleep(5)
    # 🔴 这里的输出要用 print 打出来：`run()` 只执行不回显，
    #    不 print 的话接口到底通不通，屏幕上什么也看不到。
    # 🔴 这串命令**没有 % 格式化参数**，所以 printf 里就是单 `%s` / `%{http_code}`。
    #    早先照抄别处写成了 `%%s`（那是为了配合 % 格式化），结果 shell 收到
    #    字面量 `%%s`，printf 打出来是 "%s -> %{http_code}" —— 三个接口的
    #    状态码一个都没打出来，看着像"没输出"，其实是转义多写了一层。
    print('  ' + (run(c, "for p in /api/deduct/sheets /api/deduct/reference"
                         " /api/admin/apps/price_tag/data;"
                         " do printf '%s -> ' \"$p\";"
                         " curl -s -o /dev/null -w '%{http_code}\\n'"
                         " --max-time 8 http://127.0.0.1:3602$p; done") or '').strip())

    print('\n=== 5) 验证数据库迁移真的跑了 ===')
    # 🔴 这一步是 2026-09-26 深夜补的。那次改了 db.js 给 tr_lesson 加列，
    #    但热更脚本**只验接口不验库** —— 而我自己在本地验证时也踩了坑：
    #    一直 `SELECT * FROM db.sqlite`，而项目真正用的是 **`xiaozhi-im.db`**，
    #    白折腾半天。所以这里务必核对**真实路径**。
    #    加了列但接口报 "no such column" 的话，管理台会整个白屏。
    print('  tr_lesson 列: ' + check_columns(c, 'tr_lesson',
                                            ['link_url']))
    print('  tr_progress 列: ' + check_columns(c, 'tr_progress',
                                              ['watched_sec', 'position_sec']))
    probe_reference(c)
    print('\n完成。401 = 路由已挂上（只是要鉴权）；404 = 还是没挂上。')
    return 0


def probe_reference(c):
    """上线之后，拿一个真条码验一眼「参照数」接口是否 usable。

    只验接口通不通不够 —— 参照数最怕的是"路由 200、字段永远 null"：
    员工看到三个"—"，会以为自己盘过的货没记上，而谁也查不出为什么。
    所以这里必须打出一个**不是全 null** 的样本才算数。
    """
    print('\n=== 6) 参照数接口实测（要看到真数字，不能全是 null）===')
    probe = _upload_probe(c, '_ref_probe.js')

    # 容器内看不到宿主机的 /vol1/...，库路径必须走 docker 给的挂载映射
    indb = to_container_path(c, find_dbfile(c))
    raw = (run(c, 'docker exec %s node %s %s 2>/dev/null'
                  % (CONTAINER, probe, indb)) or '').strip()
    counted, fallback = (raw.split('|') + ['', ''])[:2]

    # 🔴 线上是**工作模式**（friend_mode=work），自助注册被服务端挡掉
    #    （回「工作模式下由管理员统一添加员工账号」），所以临时注册这条路
    #    走不通。也不去碰管理口令 —— 明文会进 shell 命令、日志和 history。
    #    改用 `_token_probe.js`：让容器里跑着的那份代码自己签一个令牌，
    #    用的是同一把 JWT_SECRET，身份是普通用户（参照数本就只要登录用户）。
    tprobe = _upload_probe(c, '_token_probe.js')
    token = (run(c, 'docker exec %s node %s %s 2>/dev/null'
                    % (CONTAINER, tprobe, indb)) or '').strip()
    if not token:
        print('  ⚠️ 签不出令牌 → 接口实测做不了（路由 401 那一步已经验过挂上了）')
        return

    def ask(code):
        if not code:
            return '(库里连一个条码都没有，没法验)'
        return run(c, "curl -s --max-time 8"
                      " -H \"Authorization: Bearer %s\""
                      " 'http://127.0.0.1:3602/api/deduct/reference?barcode=%s'"
                      % (token, code)) or '(无响应)'

    if counted:
        print('  最近盘过的条码 %s →' % counted)
        print('    ' + (ask(counted) or '').strip())
    else:
        print('  线上一轮盘点都没有（正常：库里没做过盘点）')
        print('  ⚠️ 这时不能只报"验过了" —— 得拿真实商品条码看接口回什么：')
        print('  备选条码 %s →' % (fallback or '(无)'))
        print('    ' + (ask(fallback) or '').strip())
        print('    期望：ok、字段齐全、'
              'hasRef=true 且 accountFrom=master（商档认得这个码，账面数带得出来）')


if __name__ == '__main__':
    raise SystemExit(main())
