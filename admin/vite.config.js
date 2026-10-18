import { defineConfig } from 'vite';
import vue from '@vitejs/plugin-vue';

/**
 * tmagic-editor 没有内置 i18n（@tmagic/editor 里没有语言包），样式面板的
 * 字段标签是写死在 dist 配置里的英文：left / top / right / bottom / zIndex、
 * 盒模型图的 PADDING / MARGIN。这里在构建时对 @tmagic/editor 的产物做
 * 精确的字符串替换，换成中文 —— 只动这几处标签文本，不碰任何逻辑分支
 * （`text:"left"` 这种形态只出现在表单标签定义里；选项值仍是 'left'）。
 *
 * 升级 @tmagic/editor 后如果标签又变英文，先看这里匹配串是否还对得上。
 */
function localizeTmagic() {
  // 注意：dist 里是 `text: "left"`（冒号后有空格），不能写成无空格的死串；
  // 用正则容忍空白与单双引号，替换后保留原有引号风格。
  const MAP = [
    ['left', '左'],
    ['top', '上'],
    ['right', '右'],
    ['bottom', '下'],
    ['zIndex', '层级'],
    ['MARGIN', '外边距'],
    ['PADDING', '内边距'],
  ];
  return {
    name: 'localize-tmagic',
    enforce: 'pre',
    transform(code, id) {
      if (!id.includes('@tmagic/editor')) return null;
      let out = code;
      let hit = false;
      for (const [from, to] of MAP) {
        const re = new RegExp(`(\\btext:\\s*)(["'])${from}\\2`, 'g');
        const next = out.replace(re, (_m, p1, q) => `${p1}${q}${to}${q}`);
        if (next !== out) {
          out = next;
          hit = true;
        }
      }
      return hit ? { code: out, map: null } : null;
    },
  };
}

export default defineConfig({
  plugins: [vue(), localizeTmagic()],
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
