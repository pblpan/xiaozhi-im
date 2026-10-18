/*
 * tmagic runtime（画布 iframe 宿主）独立构建配置
 *
 * 产物 → admin/public/tmagic-runtime/（vite publicDir，会被拷到 server/public/tmagic-runtime/，
 * 管理台 dev / 生产都通过 /tmagic-runtime/index.html 访问）。
 *
 * 为什么独立 config：主配置的 root 是 admin/src 那套 SPA，runtime 是另一个入口
 * （iframe 应用），且 import 指向 ../vendor ../materials（root 外文件）。
 */
import { fileURLToPath } from 'node:url';
import { defineConfig } from 'vite';
import vue from '@vitejs/plugin-vue';

const here = (p) => fileURLToPath(new URL(p, import.meta.url));

export default defineConfig({
  // 🔴 必须显式 root：vite 默认 root = process.cwd()，npm script 的 cwd 是 admin，
  //    不写 root 会去构建管理台 SPA（admin/index.html → src/main.js → monaco 全家桶），
  //    产物看着"构建成功"其实整个弄错了。
  root: here('.'),
  plugins: [vue()],
  base: './',
  // 🔴 outDir 在 publicDir 里时 vite 的"拷 public 目录"行为未定义（会 warning
  //    "not separate folders"）。runtime 没有静态资源，直接关掉。
  publicDir: false,
  server: {
    // root 在 admin/tmagic/runtime，放行 admin/（node_modules 与物料源码都在那层）
    fs: { allow: [here('../..'), here('../../..')] },
  },
  build: {
    // 🔴 必须绝对路径：vite 的 outDir 相对 cwd 解析（不是 root），
    //    写相对路径会随 npm 脚本的 cwd 漂到工作区根去。
    outDir: here('../../public/tmagic-runtime'),
    emptyOutDir: true,
    target: 'es2020',
    chunkSizeWarningLimit: 4096,
  },
});
