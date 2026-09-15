# -*- coding: utf-8 -*-
"""线上只读探针运行器：把 probe_apps_prod.js 送进**容器内部**跑。

为什么不在这台机器上直接跑：
    探针要签一个合法 JWT，而签它需要生产的 JWT_SECRET。那个值只活在飞牛的
    docker/.env 里；把它拉到本地、写进环境变量、再出现在命令行里，每一步都是
    多余的泄漏面（本仓库是 Public，历史上就因为硬编码凭据翻过一次车）。
    容器自己就有 JWT_SECRET 环境变量 —— 让脚本**在容器里读**，
    密文一次都不落在这台机器上，输出里自然也不会有。

用法：
    python deploy/probe_apps_prod.py [uid:role ...]
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from fnos_ssh import connect, put_file, run  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
LOCAL = os.path.join(HERE, 'probe_apps_prod.js')
STAGE = '/tmp/xz_probe_apps.js'
CONTAINER = 'xiaozhi-im'


def main():
    who = sys.argv[1:]
    extra = (' ' + ' '.join(who)) if who else ''

    print('== 上传探针到 NAS %s' % STAGE)
    c = connect()
    try:
        put_file(c, LOCAL, STAGE, mode='644')
        print('== 拷入容器')
        print(run(c, 'docker cp %s %s:/tmp/probe_apps_prod.js' % (STAGE, CONTAINER))
              or '   (拷贝完成)')
        print('== 在容器内运行（XZ_SECRET 取自容器自身环境）\n')
        cmd = ('docker exec %s sh -c \'XZ_SECRET="$JWT_SECRET" '
               'node /tmp/probe_apps_prod.js%s\'' % (CONTAINER, extra))
        print(run(c, cmd))
    finally:
        c.close()


if __name__ == '__main__':
    main()
