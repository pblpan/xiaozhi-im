# -*- coding: utf-8 -*-
"""给 coturn 补上 TURN_PASSWORD —— 它现在空着，coturn 拒绝启动，一直在重启循环。

coturn 的 entrypoint（deploy/coturn/entrypoint.sh）从 docker/.env 读
TURN_PASSWORD，并且**不再有内置默认口令**（0.17.0 的安全整改里刻意删掉的 ——
留默认口令等于把中继账号公开）。于是空值 = 拒绝启动 = restart 循环。

修法（服务端日志里就写着这个修法，照做）：
  1) 生成一个强口令
  2) 同时写进两端且必须一致：
       docker/.env  的 TURN_PASSWORD   （coturn 读它）
       data/turn.env 的 TURN_CREDENTIAL（服务端读它，config.js 优先取 turn.env）
     只改一边会出现「中继看着配好了、跨网通话一连就断」这种极难查的故障。
  3) docker compose up -d --force-recreate coturn

用法：python _fix_turn_password.py [--dry-run]
"""
import argparse
import os
import random
import string
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from fnos_ssh import connect, run  # noqa: E402

DOCKER_ENV = '/vol1/@appcenter/xiaozhi-im/docker/.env'
TURN_ENV = '/vol1/@appshare/xiaozhi-im/data/turn.env'
COMPOSE_DIR = '/vol1/@appcenter/xiaozhi-im/docker'


def gen_pw():
    # coturn 的静态账号口令：字母数字，16 位，够用且不含 shell 元字符
    chars = string.ascii_letters + string.digits
    return ''.join(random.choice(chars) for _ in range(16))


def set_key(text, key, value):
    """逐行替换 key=value；没有这行就追加。保留注释与其它行。"""
    out, hit = [], False
    for line in text.split('\n'):
        stripped = line.lstrip()
        indent = line[:len(line) - len(stripped)]
        if stripped.startswith(key + '='):
            eol = '\r' if line.endswith('\r') else ''
            out.append('%s%s=%s%s' % (indent, key, value, eol))
            hit = True
        else:
            out.append(line)
    if not hit:
        out.append('%s=%s' % (key, value))
        if not out[-2].endswith('\n') and len(out) > 1:
            out.insert(-1, '')
    return '\n'.join(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--dry-run', action='store_true')
    args = ap.parse_args()

    c = connect()
    docker_env = run(c, 'cat %s' % DOCKER_ENV)
    turn_env = run(c, 'cat %s' % TURN_ENV)

    def masked(t):
        return {k: (('空' if not v else '%d 字符' % len(v)))
                for k, v in ((l.split('=', 1)[0].strip(), l.split('=', 1)[1] if '=' in l else '')
                             for l in t.split('\n'))
                if k.startswith('TURN_')}

    print('现状 docker/.env TURN_*  :', masked(docker_env))
    print('现状 turn.env    TURN_*  :', masked(turn_env))

    cred = ''
    for l in turn_env.split('\n'):
        if l.startswith('TURN_CREDENTIAL='):
            cred = l.split('=', 1)[1].strip()
            break
    pw = cred or gen_pw()
    print('将用的中继口令:', ('沿用 turn.env 现有值' if cred else '新生成 16 位强口令'))

    if args.dry_run:
        print('（dry-run，到此为止）')
        c.close()
        return

    ts = time.strftime('%Y%m%d-%H%M%S')
    run(c, 'cp -p %s %s.bak.%s; cp -p %s %s.bak.%s'
        % (DOCKER_ENV, DOCKER_ENV, ts, TURN_ENV, TURN_ENV, ts))
    print('已备份: %s.bak.%s / %s.bak.%s' % (DOCKER_ENV, ts, TURN_ENV, ts))

    with c.open_sftp() as sftp:
        for path, text in ((DOCKER_ENV, set_key(docker_env, 'TURN_PASSWORD', pw)),
                           (TURN_ENV, set_key(turn_env, 'TURN_CREDENTIAL', pw))):
            tmp = path + '.xz_tmp'
            with open(path + '.local_tmp', 'w', encoding='utf-8') as f:
                f.write(text)
            sftp.put(path + '.local_tmp', tmp)
            run(c, 'mv %s %s && chmod 600 %s' % (tmp, path, path))
            os.remove(path + '.local_tmp')
            print('已写入:', path)

    print('=== 拉起 coturn ===')
    run(c, 'cd %s && docker compose up -d --force-recreate coturn 2>&1 | tail -3' % COMPOSE_DIR)
    time.sleep(12)
    print('状态:', run(c, "docker ps --filter name=xiaozhi-im-turn --format '{{.Status}}'").strip())
    print('日志:', run(c, 'docker logs xiaozhi-im-turn --tail 6 2>&1').strip()[-300:])
    c.close()


if __name__ == '__main__':
    main()
