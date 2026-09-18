# -*- coding: utf-8 -*-
"""飞牛小智服务端升级工具（0.16.0 -> 0.17.1）

用法：
    python fnos_upgrade.py diff      只读比对，列出需推送的文件
    python fnos_upgrade.py backup    远程打包备份（docker/ 配置 + src/ 代码）
    python fnos_upgrade.py push      推送有差异的代码文件
    python fnos_upgrade.py restart   重启容器（force-recreate）
    python fnos_upgrade.py verify    验证版本/健康/数据完整

设计原则：
- 绝不碰 /data（数据库、上传文件、license.json、turn.env）
- 绝不覆盖 docker/.env（里面有本机随机密钥与数据目录声明）
- 只推进「代码」：src/ + public/ + 根级 package.json 等
"""
import sys, os, hashlib, posixpath, stat as statmod

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from fnos_auth import HOST, USER, PASS
import paramiko

APP = '/vol1/@appcenter/xiaozhi-im'
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))  # -> xiaozhi-im/
LOCAL_SRV = os.path.join(ROOT, 'server')

SKIP_DIRS = {'node_modules', '.git', '__pycache__', '.github'}
# 只同步这些「代码」目标；docker/ 与 data/ 永不同步
TARGETS = [
    ('src', os.path.join(LOCAL_SRV, 'src'), f'{APP}/src/src'),
    ('public', os.path.join(LOCAL_SRV, 'public'), f'{APP}/src/public'),
]
ROOT_FILES = ['package.json', 'package-lock.json', 'smoketest.js']


def connect():
    cli = paramiko.SSHClient()
    cli.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    cli.connect(HOST, username=USER, password=PASS,
                timeout=15, banner_timeout=15, auth_timeout=15)
    return cli


def walk_local(root):
    out = {}
    for dp, dn, fn in os.walk(root):
        dn[:] = [d for d in dn if d not in SKIP_DIRS]
        for f in fn:
            p = os.path.join(dp, f)
            rel = os.path.relpath(p, root).replace(os.sep, '/')
            try:
                out[rel] = hashlib.md5(open(p, 'rb').read()).hexdigest()
            except Exception:
                out[rel] = 'ERR'
    return out


def walk_remote(sftp, root):
    out = {}

    def rec(cur, rel):
        try:
            items = sftp.listdir_attr(cur)
        except Exception:
            return
        for it in items:
            rp = posixpath.join(rel, it.filename) if rel else it.filename
            full = cur + '/' + it.filename
            if statmod.S_ISDIR(it.st_mode):
                if it.filename in SKIP_DIRS:
                    continue
                rec(full, rp)
            else:
                try:
                    with sftp.open(full) as f:
                        out[rp] = hashlib.md5(f.read()).hexdigest()
                except Exception:
                    out[rp] = 'ERR'

    rec(root, '')
    return out


def compute_plan(sftp):
    """返回 (add, chg, nochange, extra) 四组相对路径列表，另含根文件。"""
    plan = {}
    for label, lroot, rroot in TARGETS:
        L = walk_local(lroot)
        R = walk_remote(sftp, rroot)
        add = sorted(set(L) - set(R))
        chg = sorted(k for k in set(L) & set(R) if L[k] != R[k])
        same = sorted(k for k in set(L) & set(R) if L[k] == R[k])
        extra = sorted(set(R) - set(L))
        plan[label] = dict(add=add, chg=chg, same=same, extra=extra,
                           lroot=lroot, rroot=rroot)
    rf = {}
    R = walk_remote(sftp, f'{APP}/src')
    for f in ROOT_FILES:
        lp = os.path.join(LOCAL_SRV, f)
        b = hashlib.md5(open(lp, 'rb').read()).hexdigest() if os.path.exists(lp) else 'MISSING'
        a = R.get(f)
        rf[f] = (a, b, a == b)
    return plan, rf


def cmd_diff():
    cli = connect()
    sftp = cli.open_sftp()
    plan, rf = compute_plan(sftp)
    tot_a = tot_c = tot_s = 0
    for label, p in plan.items():
        print(f"\n########## {label} ##########")
        print(f"  新增 {len(p['add'])} / 变更 {len(p['chg'])} / 一致 {len(p['same'])} / 仅飞牛有 {len(p['extra'])}")
        tot_a += len(p['add']); tot_c += len(p['chg']); tot_s += len(p['same'])
        if p['add']:
            print("  [新增] " + "\n         ".join(p['add']))
        if p['chg']:
            print("  [变更] " + "\n         ".join(p['chg']))
        if p['extra']:
            print("  [仅飞牛有（0.17.1 已删，升级时应移除）] " + "\n         ".join(p['extra']))
    print("\n########## 根文件 ##########")
    for f, (a, b, same) in rf.items():
        if not same:
            tot_c += 1
        print(f"  {f:<20} 飞牛={str(a)[:12]:<14} 本地={b[:12]:<14} {'一致' if same else '需更新'}")
    print(f"\n>>> 需推送：新增 {tot_a}，变更 {tot_c}；已一致 {tot_s}")
    sftp.close(); cli.close()


def cmd_backup():
    cli = connect()
    _, o, e = cli.exec_command(
        f'cd {APP} && TS=$(date +%Y%m%d-%H%M%S) && '
        f'B=/vol1/@appcenter/xiaozhi-im/_upgrade_backup_$TS && mkdir -p $B && '
        f'cp -a docker/docker-compose.yaml docker/.env $B/ 2>/dev/null; '
        f'tar czf $B/src-$TS.tar.gz -C {APP} src 2>/dev/null; '
        f'ls -la $B && echo "BACKUP_DIR=$B"',
        timeout=300, get_pty=True)
    print(o.read().decode('utf-8', 'replace'))
    err = e.read().decode('utf-8', 'replace')
    if err.strip():
        print('[stderr]', err[:500])
    cli.close()


def cmd_push():
    cli = connect()
    sftp = cli.open_sftp()
    plan, rf = compute_plan(sftp)
    pushed = 0
    failed = []
    for label, p in plan.items():
        for rel in p['add'] + p['chg']:
            lp = os.path.join(p['lroot'], rel.replace('/', os.sep))
            rp = p['rroot'] + '/' + rel
            # 确保远端目录存在
            d = posixpath.dirname(rp)
            try:
                sftp.stat(d)
            except Exception:
                parts = d.split('/')
                cur = ''
                for part in parts:
                    cur = cur + '/' + part if cur else part
                    try:
                        sftp.stat(cur)
                    except Exception:
                        sftp.mkdir(cur)
            try:
                sftp.put(lp, rp)
                pushed += 1
            except Exception as ex:
                failed.append((rel, str(ex)))
    for f, (a, b, same) in rf.items():
        if same:
            continue
        lp = os.path.join(LOCAL_SRV, f)
        if not os.path.exists(lp):
            continue
        try:
            sftp.put(lp, f'{APP}/src/{f}')
            pushed += 1
        except Exception as ex:
            failed.append((f, str(ex)))
    print(f">>> 已推送 {pushed} 个文件")
    if failed:
        print("!!! 失败:")
        for r, m in failed:
            print("   ", r, m)
    # 移除 0.17.1 已删的文件
    for label, p in plan.items():
        for rel in p['extra']:
            try:
                sftp.remove(p['rroot'] + '/' + rel)
                print(f"   [清理] 已移除 {label}/{rel}")
            except Exception as ex:
                print(f"   [清理失败] {label}/{rel} {ex}")
    sftp.close(); cli.close()


def cmd_restart():
    cli = connect()
    cmd = (
        f'cd {APP}/docker && '
        f'echo "{PASS}" | sudo -S docker compose down --remove-orphans 2>&1 | tail -5 && '
        f'echo "--- up ---" && '
        f'echo "{PASS}" | sudo -S docker compose up -d --force-recreate 2>&1 | tail -15'
    )
    _, o, e = cli.exec_command(cmd, timeout=600, get_pty=True)
    print(o.read().decode('utf-8', 'replace'))
    err = e.read().decode('utf-8', 'replace')
    if err.strip():
        print('[stderr]', err[:800])
    cli.close()


def cmd_verify():
    cli = connect()
    cmd = (
        f'echo "--- 容器 ---" && echo "{PASS}" | sudo -S docker ps --format "{{{{.Names}}}}|{{{{.Status}}}}|{{{{.Ports}}}}" 2>/dev/null | grep xiaozhi; '
        f'echo "--- 启动日志 ---" && echo "{PASS}" | sudo -S docker logs xiaozhi-im --tail 30 2>&1 | tail -30; '
        f'echo "--- 容器内版本 ---" && echo "{PASS}" | sudo -S docker exec xiaozhi-im node -e "console.log(require(\\"/app/package.json\\").version)" 2>&1'
    )
    _, o, e = cli.exec_command(cmd, timeout=180, get_pty=True)
    print(o.read().decode('utf-8', 'replace'))
    err = e.read().decode('utf-8', 'replace')
    if err.strip():
        print('[stderr]', err[:600])
    cli.close()


if __name__ == '__main__':
    mode = sys.argv[1] if len(sys.argv) > 1 else 'diff'
    fn = {'diff': cmd_diff, 'backup': cmd_backup, 'push': cmd_push,
          'restart': cmd_restart, 'verify': cmd_verify}.get(mode)
    if not fn:
        print(__doc__); sys.exit(1)
    fn()
