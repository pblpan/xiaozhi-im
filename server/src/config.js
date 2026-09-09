const path = require('path');
const fs = require('fs');

const ROOT = path.resolve(__dirname, '..');
const DATA_DIR = process.env.DATA_DIR || path.join(ROOT, 'data');
const FILES_DIR = path.join(DATA_DIR, 'files');

fs.mkdirSync(FILES_DIR, { recursive: true });

module.exports = {
  PORT: Number(process.env.PORT || 3602),
  JWT_SECRET: process.env.JWT_SECRET || 'change-me-xiaozhi-im-secret',
  DATA_DIR,
  FILES_DIR,
  DB_PATH: process.env.DB_PATH || path.join(DATA_DIR, 'xiaozhi-im.db'),
  ADMIN_USERNAME: process.env.ADMIN_USERNAME || 'admin',
  ADMIN_PASSWORD: process.env.ADMIN_PASSWORD || 'admin123',
  MAX_FILE_MB: Number(process.env.MAX_FILE_MB || 50),
  PUBLIC_URL: process.env.PUBLIC_URL || '',
};
