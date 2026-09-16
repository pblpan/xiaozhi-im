FROM node:22-slim

WORKDIR /app

# 先装生产依赖（利用层缓存）
COPY package.json ./
RUN npm install --omit=dev

# 拷贝应用（含已构建的管理后台 public/）
COPY . .

# 不给 JWT_SECRET / ADMIN_PASSWORD 留构建期默认值（2026-09-16 整改）：
# 从前这里是 change-me-xiaozhi-im 与 admin123，而本仓库有过一段 Public 历史
# —— 谁 clone 一次就拿到了管理台密码。现在改为运行时由 docker/.env 注入；
# 万一没注入，服务端会各自生成随机值（JWT 那个还会持久化，避免重启把所有人踢下线）。
ENV PORT=3602 \
    DATA_DIR=/data \
    ADMIN_USERNAME=admin \
    MAX_FILE_MB=50

RUN mkdir -p /data/files

VOLUME ["/data"]
EXPOSE 3602

CMD ["node", "src/index.js"]
