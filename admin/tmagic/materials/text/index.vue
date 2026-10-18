<template>
  <p
    :style="{
      fontSize: (config.size || 15) + 'px',
      color: semanticColor(config.color),
      textAlign: config.align || 'left',
      margin: 0,
      lineHeight: 1.45,
      wordBreak: 'break-all',
    }"
  >
    {{ config.text || '（空文本）' }}
  </p>
</template>

<script lang="ts" setup>
import { semanticColor } from '../_shared/colors';

defineOptions({ name: 'xz-material-text' });

defineProps<{ config: any }>();
</script>
