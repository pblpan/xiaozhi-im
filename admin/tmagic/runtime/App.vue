<template>
  <component v-if="pageConfig" :is="pageComponent" :key="pageConfig.id" :config="pageConfig"></component>
</template>

<script lang="ts" setup>
import { inject } from 'vue';
import { useComponent, useDsl, useEditorDsl } from '@tmagic/vue-runtime-help';
import type TMagicApp from '@tmagic/core';

// 编辑器模式（window.magic 由 @tmagic/editor 预埋）走 magic 协议；
// 预览模式走 app.page.data。
const app = inject<TMagicApp>('app');
const isEditor = typeof window.magic !== 'undefined';

const { pageConfig } = isEditor ? useEditorDsl(app) : useDsl(app);

const pageComponent = useComponent('page');
</script>
