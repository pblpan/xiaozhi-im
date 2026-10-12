# -*- coding: utf-8 -*-
"""把「小智IM 服务端」打成 Docker 通用免构建包（tar.gz）。

用法：
    python deploy/docker/pack_docker.py            # 出包 + 复制到桌面
    python deploy/docker/pack_docker.py --no-deliver

产物：
    deploy/docker/build/小智IM_Docker通用版-<版本>.tar.gz

═══ 这包是什么 ═════════════════════════════════════════════════════
  · 源码 + **已装好的 node_modules**（预装依赖），镜像直接 COPY 用，
    客户机 `docker compose up -d --build` 不需要联网、不需要 npm。
  · 跨平台安全：node_modules 里 Windows 专有的 *.node（ssh2 加速模块）
    在 Linux 容器里加载会失败，但 ssh2 内部 try/catch 退回纯 JS 实现，
    已被飞牛 fpk（同一份 node_modules 跑在 ARM Linux）验证可用。
    打包时直接剔除 *.node，干净且不丢功能。
  · 与飞牛 fpk / Windows Setup 服务端代码完全一致，只是运行形态不同。
"""
import argparse
import json
import os
import shutil
import sys
import tarfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))          # xiaozhi-im/
SERVER = os.path.join(ROOT, 'server')
DOCKER = HERE                                         # deploy/docker/
BUILD = os.path.join(HERE, 'build')
DESKTOP_DIR = os.path.join('D:', os.sep, 'Users', 'pblpa', 'Desktop', '小智 IM')

# 进镜像只需要的服务端文件（不含 test/data/tools，瘦身）
SERVER_RUNTIME = ('src', 'public', 'package.json', 'package-lock.json', 'smoketest.js')


def read_version():
    with open(os.path.join(SERVER, 'package.json'), encoding='utf-8') as f:
        return json.load(f)['version']


def copytree_ignore(src, names):
    """跳过版本控制/缓存/日志；node_modules 里剔除平台专有 *.node。"""
    skip = {'.git', '__pycache__', 'node_modules', 'data', 'test', 'tools', '.cache'}
    out = [n for n in names if n in skip]
    # node_modules 单独处理（剔除 *.node），这里不跳过它
    if os.path.basename(src) == 'node_modules':
        out += [n for n in names if n.endswith('.node')]
    return out


def stage(version):
    top = '小智IM_Docker通用版-%s' % version
    stage_root = os.path.join(BUILD, top)
    if os.path.isdir(stage_root):
        shutil.rmtree(stage_root)
    os.makedirs(stage_root)

    srv_dst = os.path.join(stage_root, 'server')
    os.makedirs(srv_dst)

    # --- 服务端运行时文件 ---
    for rel in SERVER_RUNTIME:
        s = os.path.join(SERVER, rel)
        if not os.path.exists(s):
            if rel in ('src', 'public', 'package.json'):
                raise SystemExit('缺少必要文件：%s' % s)
            continue
        d = os.path.join(srv_dst, rel)
        if os.path.isdir(s):
            shutil.copytree(s, d)
        else:
            shutil.copy2(s, d)

    # --- 预装依赖 node_modules（剔除 *.node 平台专有二进制）---
    nm_src = os.path.join(SERVER, 'node_modules')
    nm_dst = os.path.join(srv_dst, 'node_modules')
    if not os.path.isdir(nm_src):
        raise SystemExit('server/node_modules 不存在，先在 server/ 跑 npm install --omit=dev')
    print('[1/4] 拷贝 node_modules（剔除 *.node）…')
    shutil.copytree(nm_src, nm_dst, ignore=copytree_ignore)
    nm_size = sum(os.path.getsize(os.path.join(r, f))
                  for r, _, fs in os.walk(nm_dst) for f in fs) / 1024 / 1024
    print('      node_modules  %.1f MB（已去 *.node）' % nm_size)

    # --- Docker 相关文件 ---
    print('[2/4] 拷贝 Docker 编排与一键脚本…')
    for fn in ('docker-compose.yaml', 'deploy.sh', 'README.md',
               'Dockerfile.prebuilt', 'Dockerfile.build'):
        s = os.path.join(DOCKER, fn)
        if fn in ('Dockerfile.prebuilt', 'Dockerfile.build'):
            shutil.copy2(s, os.path.join(srv_dst, fn))   # 放 build context 里
        else:
            shutil.copy2(s, os.path.join(stage_root, fn))
    # deploy.sh 给执行权限（Linux 客户机直接 ./deploy.sh）
    os.chmod(os.path.join(stage_root, 'deploy.sh'), 0o755)

    # --- coturn 中继配置 ---
    coturn_src = os.path.join(ROOT, 'deploy', 'coturn')
    coturn_dst = os.path.join(stage_root, 'coturn')
    if os.path.isdir(coturn_src):
        os.makedirs(coturn_dst)
        for fn in os.listdir(coturn_src):
            shutil.copy2(os.path.join(coturn_src, fn), os.path.join(coturn_dst, fn))

    return stage_root, top


def make_tar(stage_root, top, version):
    os.makedirs(BUILD, exist_ok=True)
    out_name = '%s.tar.gz' % top
    out_path = os.path.join(BUILD, out_name)
    print('[3/4] 打包 %s …' % out_name)
    with tarfile.open(out_path, 'w:gz', compresslevel=6) as tf:
        # 以 top 为顶层目录加入
        tf.add(stage_root, arcname=top, recursive=True)
    size = os.path.getsize(out_path) / 1024 / 1024
    print('      生成：%s（%.1f MB）' % (out_path, size))
    return out_path


def main():
    ap = argparse.ArgumentParser(description='打包小智IM Docker 通用免构建包')
    ap.add_argument('--no-deliver', action='store_true', help='只出到 build 目录，不复制到桌面')
    args = ap.parse_args()

    version = read_version()
    print('服务端版本：%s（取自 server/package.json）' % version)

    stage_root, top = stage(version)
    out_path = make_tar(stage_root, top, version)

    print('[4/4] 完成')
    if not args.no_deliver and os.path.isdir(DESKTOP_DIR):
        dst = os.path.join(DESKTOP_DIR, os.path.basename(out_path))
        shutil.copy2(out_path, dst)
        print('已复制到桌面：%s' % dst)

    # 清理 staging（保留 tar.gz）
    shutil.rmtree(stage_root, ignore_errors=True)
    return 0


if __name__ == '__main__':
    sys.exit(main())
