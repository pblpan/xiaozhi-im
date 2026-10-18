/*
 * tmagic editor 的管理台接入（Vue 插件 + monaco workers + element-plus adapter）。
 *
 * 抽成独立模块是为了：验证页（verify-builder）与管理台主入口（src/main.js）
 * 用同一份注册逻辑，不会出现"管理台能跑、验证页跑不起来"的偏差。
 */
import EditorWorker from 'monaco-editor/esm/vs/editor/editor.worker.js?worker';
import CssWorker from 'monaco-editor/esm/vs/language/css/css.worker.js?worker';
import HtmlWorker from 'monaco-editor/esm/vs/language/html/html.worker.js?worker';
import JsonWorker from 'monaco-editor/esm/vs/language/json/json.worker.js?worker';
import TsWorker from 'monaco-editor/esm/vs/language/typescript/ts.worker.js?worker';

import editorPlugin from '@tmagic/editor';
import elementPlusAdapter from '@tmagic/element-plus-adapter';

// 🔴 editor 的样式是独立的（JS 入口不 import css），漏了它整个编辑器没有布局样式：
//    .m-editor-content 的 height:calc(100% - 35px) 就在这个文件里，没有它高度链全断。
import '@tmagic/editor/dist/style.css';

export function installTmagic(app) {
  // tmagic editor 的代码编辑器（属性面板里的 data-source-input 等）走 monaco，
  // worker 必须显式注册（vite 的 ?worker 语法），否则属性面板一开就白屏。
  // 路径是 monaco-editor 0.55 的 esm 布局（不是 editor/editor.worker.js）。
  globalThis.MonacoEnvironment = {
    getWorker(_workerId, label) {
      switch (label) {
        case 'json':
          return new JsonWorker();
        case 'css':
        case 'scss':
        case 'less':
          return new CssWorker();
        case 'html':
        case 'handlebars':
        case 'razor':
          return new HtmlWorker();
        case 'typescript':
        case 'javascript':
          return new TsWorker();
        default:
          return new EditorWorker();
      }
    },
  };

  // editor 以 Vue 插件形态接入：注册 TMagicEditor 组件 + editorService/propsService
  // 等全局单例，属性面板用 element-plus adapter 渲染。
  app.use(editorPlugin, { ...elementPlusAdapter });
}
