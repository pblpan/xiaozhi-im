/*
 * 小智 IM 自定义应用 runtime（tmagic 画布 iframe 宿主）
 *
 * 双模式：
 *  - 编辑器模式：被 @tmagic/editor 以 iframe 嵌入，window.magic 由编辑器预埋，
 *    走 useEditorDsl（增删改节点走 magic.onRuntimeReady 协议）。
 *  - 预览模式：iframe src 带 ?preview=1，DSL 由父页面写入 sessionStorage['xz-tmagic-dsl']，
 *    走 useDsl（静态渲染，供管理台「预览」与发布后效果核对）。
 *
 * 组件注册两套：
 *  - tmagic 容器系（Apache-2.0，源自 Tencent tmagic-editor vue-components，保留版权头）
 *  - 小智物料 8 种（text/divider/card/list/table/form/action/chart，字段直拷小智 module schema）
 */

import { createApp } from 'vue';
import TMagicApp, { DataSourceManager, DeepObservedData } from '@tmagic/core';
import '@tmagic/core/resetcss.css';

import App from './App.vue';

// ---- tmagic 容器系（vendor，Apache-2.0）----
import Page from '../vendor/vue-components/page/index.vue';
import Container from '../vendor/vue-components/container/Container.vue';
import PageFragment from '../vendor/vue-components/page-fragment/PageFragment.vue';
import PageFragmentContainer from '../vendor/vue-components/page-fragment-container/PageFragmentContainer.vue';

// ---- 小智物料 8 种 ----
import Text from '../materials/text/index.vue';
import Divider from '../materials/divider/index.vue';
import Card from '../materials/card/index.vue';
import List from '../materials/list/index.vue';
import Table from '../materials/table/index.vue';
import Form from '../materials/form/index.vue';
import Action from '../materials/action/index.vue';
import Chart from '../materials/chart/index.vue';

DataSourceManager.registerObservedData(DeepObservedData);

const isEditor = typeof window.magic !== 'undefined';
const isPreview = new URLSearchParams(window.location.search).get('preview') === '1';

let initialConfig = null;
if (isPreview) {
  try {
    initialConfig = JSON.parse(sessionStorage.getItem('xz-tmagic-dsl') || 'null');
  } catch (e) {
    console.error('[xz-runtime] sessionStorage DSL 解析失败', e);
  }
}

const app = new TMagicApp({
  ua: window.navigator.userAgent,
  platform: 'editor',
  config: initialConfig || undefined,
});

// 空 DSL 兜底（编辑器模式由 magic 协议推送 root；预览模式无 DSL 给个空白页）
if (!initialConfig) {
  app.setConfig({
    items: [
      {
        id: `page_${Date.now()}`,
        type: 'page',
        items: [],
      },
    ],
  });
}

app.setDesignWidth(window.document.documentElement.getBoundingClientRect().width || 375);

const registry = {
  page: Page,
  container: Container,
  'page-fragment': PageFragment,
  'page-fragment-container': PageFragmentContainer,
  text: Text,
  divider: Divider,
  card: Card,
  list: List,
  table: Table,
  form: Form,
  action: Action,
  chart: Chart,
};

Object.entries(registry).forEach(([type, component]) => {
  app.registerComponent(type, component);
});

const vueApp = createApp(App);
vueApp.config.globalProperties.app = app;
vueApp.provide('app', app);

// 预览模式：父页面（ModuleBuilder）通过 postMessage 更新 DSL
if (isPreview) {
  window.addEventListener('message', (event) => {
    if (event.data && event.data.type === 'xz-tmagic-dsl-update') {
      const config = event.data.dsl;
      const rootId = config?.items?.[0]?.id;
      app.setConfig(config, rootId);
    }
  });
  // 通知父页面预览就绪
  if (window.parent !== window) {
    window.parent.postMessage({ type: 'xz-tmagic-preview-ready' }, '*');
  }
}

vueApp.mount('#app');
