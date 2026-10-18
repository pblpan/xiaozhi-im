<template>
  <div class="xz-table">
    <table>
      <thead>
        <tr>
          <th v-for="(c, i) in cols" :key="i" :style="{ width: (c.width || 100) + 'px' }">{{ c.label || c.key || '列' }}</th>
        </tr>
      </thead>
      <tbody>
        <tr v-for="(r, i) in fakeRows" :key="i">
          <td v-for="(c, j) in cols" :key="j">{{ c.key ? r[c.key] : '' }}</td>
        </tr>
      </tbody>
    </table>
    <div v-if="!cols.length" class="xz-table__empty">表格（数据路径：{{ config.dataPath || '未配置' }}）</div>
  </div>
</template>

<script lang="ts" setup>
import { computed } from 'vue';

defineOptions({ name: 'xz-material-table' });

const props = defineProps<{ config: any }>();

const cols = computed(() => (Array.isArray(props.config.columns) ? props.config.columns : []));

// 画布预览假数据（列 key 取不到就显示占位）
const fakeRows = computed(() => [
  Object.fromEntries(cols.value.map((c: any) => [c.key, '—'])),
  Object.fromEntries(cols.value.map((c: any) => [c.key, '—'])),
]);
</script>

<style scoped>
.xz-table {
  background: #fff;
  border-radius: 8px;
  overflow-x: auto;
}

.xz-table table {
  width: 100%;
  border-collapse: collapse;
  font-size: 12px;
}

.xz-table th {
  padding: 8px 6px;
  background: #f7f8fa;
  color: #4e5969;
  font-weight: 500;
  text-align: left;
  white-space: nowrap;
}

.xz-table td {
  padding: 8px 6px;
  border-top: 1px solid #f2f3f5;
  color: #1d2129;
  white-space: nowrap;
}

.xz-table__empty {
  padding: 16px;
  font-size: 12px;
  color: #c9cdd4;
  text-align: center;
}
</style>
