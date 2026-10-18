<template>
  <div style="display: flex; align-items: flex-end; gap: 6px; height: 90px; padding: 8px 0">
    <div
      v-for="(h, i) in bars"
      :key="i"
      :style="{
        flex: 1,
        height: h + '%',
        background: semanticColor(config.color),
        borderRadius: '2px 2px 0 0',
        minHeight: '4px',
      }"
    ></div>
  </div>
</template>

<script lang="ts" setup>
import { computed } from 'vue';
import { semanticColor } from '../_shared/colors';

defineOptions({ name: 'xz-material-chart' });

const props = defineProps<{ config: any }>();

// 画布预览用的假数据（真机数据来自 onLoad 取数 + dataPath）
const bars = computed(() => {
  const n = props.config.kind === 'line' ? 7 : 5;
  return Array.from({ length: n }, (_, i) => 30 + ((i * 37) % 60));
});
</script>
