<template>
  <div class="xz-card" @click="clickHandler">
    <div v-if="config.title" class="xz-card__title">{{ config.title }}</div>
    <div v-if="config.subtitle" class="xz-card__subtitle">{{ config.subtitle }}</div>
    <div class="xz-card__body">
      <slot>
        <ItemComponent
          v-for="(item, index) in config.items"
          :key="item.id"
          :config="item"
          :index="index"
          :iterator-index="iteratorIndex"
          :iterator-container-id="iteratorContainerId"
          :page-fragment-container-id="pageFragmentContainerId"
        ></ItemComponent>
      </slot>
    </div>
  </div>
</template>

<script lang="ts" setup>
import { inject } from 'vue';

import type TMagicApp from '@tmagic/core';
import { COMMON_EVENT_PREFIX, type Id, type MContainer } from '@tmagic/core';
import { type ComponentProps, registerNodeHooks, useNode } from '@tmagic/vue-runtime-help';

import ItemComponent from './Component';

interface CardSchema extends Omit<MContainer, 'id'> {
  id?: Id;
  type?: 'card';
  title?: string;
  subtitle?: string;
}

defineOptions({
  name: 'xz-material-card',
});

const props = defineProps<ComponentProps<CardSchema>>();

const app = inject<TMagicApp>('app');
const node = useNode(props, app);
registerNodeHooks(node);

const clickHandler = () => {
  if (app && node) {
    app.emit(`${COMMON_EVENT_PREFIX}click`, node);
  }
};
</script>

<style scoped>
.xz-card {
  box-sizing: border-box;
  width: 100%;
  min-height: 40px;
  padding: 12px;
  border-radius: 8px;
  background: #ffffff;
  box-shadow: 0 1px 4px rgba(29, 33, 41, 0.08);
}

.xz-card__title {
  font-size: 15px;
  font-weight: 600;
  color: #1d2129;
}

.xz-card__subtitle {
  margin-top: 2px;
  font-size: 12px;
  color: #86909c;
}

.xz-card__body {
  margin-top: 8px;
}
</style>
