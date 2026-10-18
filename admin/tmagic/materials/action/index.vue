<template>
  <button
    :style="{
      width: '100%',
      height: '40px',
      border: 'none',
      borderRadius: '6px',
      background: semanticColor(config.color),
      color: '#fff',
      fontSize: '15px',
    }"
  >
    {{ config.label || '按钮' }}
  </button>
</template>

<script lang="ts" setup>
import { semanticColor } from '../_shared/colors';

defineOptions({ name: 'xz-material-action' });

defineProps<{ config: any }>();
</script>
