#!/usr/bin/env bash
# 飞牛 fpk docker 模式启动脚本
# 前提：镜像 xiaozhi-im-server:0.1.0 已预构建并加载到飞牛（见 deploy/README.md）
set -e
cd "$(dirname "$0")/.."
docker compose up -d
echo "[小智IM] 已启动，访问 http://<飞牛IP>:3602/admin"
