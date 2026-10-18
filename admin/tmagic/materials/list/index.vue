<template>
  <div class="xz-list">
    <div v-for="(row, i) in fakeRows" :key="i" class="xz-list__item">
      <div class="xz-list__main">
        <div class="xz-list__title">{{ row.t }}</div>
        <div v-if="row.s" class="xz-list__subtitle">{{ row.s }}</div>
      </div>
      <div v-if="row.tr" class="xz-list__trailing">{{ row.tr }}</div>
    </div>
    <div v-if="!fakeRows.length" class="xz-list__empty">列表（取数路径：{{ config.dataPath || '未配置' }}）</div>
  </div>
</template>

<script lang="ts" setup>
import { computed } from 'vue';

defineOptions({ name: 'xz-material-list' });

const props = defineProps<{ config: any }>();

// 画布预览假数据（真机由 onLoad 取数 + dataPath 决定）
const fakeRows = computed(() => [
  { t: '第一项', s: props.config.itemTemplate?.subtitle ? '副标题' : '', tr: props.config.itemTemplate?.trailing ? '右侧' : '' },
  { t: '第二项', s: props.config.itemTemplate?.subtitle ? '副标题' : '', tr: props.config.itemTemplate?.trailing ? '右侧' : '' },
]);
</script>

<style scoped>
.xz-list {
  background: #fff;
  border-radius: 8px;
  overflow: hidden;
}

.xz-list__item {
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 12px;
  border-bottom: 1px solid #f2f3f5;
}

.xz-list__item:last-child {
  border-bottom: none;
}

.xz-list__title {
  font-size: 14px;
  color: #1d2129;
}

.xz-list__subtitle {
  margin-top: 2px;
  font-size: 12px;
  color: #86909c;
}

.xz-list__trailing {
  font-size: 13px;
  color: #0054e1;
}

.xz-list__empty {
  padding: 16px;
  font-size: 12px;
  color: #c9cdd4;
  text-align: center;
}
</style>
