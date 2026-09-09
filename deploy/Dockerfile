FROM node:22-slim

WORKDIR /app

# 先装生产依赖（利用层缓存）
COPY package.json ./
RUN npm install --omit=dev

# 拷贝应用（含已构建的管理后台 public/）
COPY . .

ENV PORT=3602 \
    DATA_DIR=/data \
    JWT_SECRET=change-me-xiaozhi-im \
    ADMIN_USERNAME=admin \
    ADMIN_PASSWORD=admin123 \
    MAX_FILE_MB=50

RUN mkdir -p /data/files

VOLUME ["/data"]
EXPOSE 3602

CMD ["node", "src/index.js"]
