import { defineConfig } from 'vite';
import vue from '@vitejs/plugin-vue';

export default defineConfig({
  plugins: [vue()],
  base: '/admin/',
  server: {
    proxy: {
      // dev 代理目标：默认本机测试服务端 3610（DATA_DIR=工作区 _local_test_data，
      // 与线上 3602 完全隔离，管理台改模块不会动线上数据）。
      // 要连线上就把这里改成 3602 —— 但那时保存模块会直接改线上，慎用。
      '/api': process.env.ADMIN_API_ORIGIN || 'http://localhost:3610',
    },
  },
  build: { outDir: '../server/public', emptyOutDir: true },
});
