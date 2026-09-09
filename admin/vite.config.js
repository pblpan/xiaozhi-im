import { defineConfig } from 'vite';
import vue from '@vitejs/plugin-vue';

export default defineConfig({
  plugins: [vue()],
  base: '/admin/',
  server: { proxy: { '/api': 'http://localhost:3602' } },
  build: { outDir: '../server/public', emptyOutDir: true },
});
