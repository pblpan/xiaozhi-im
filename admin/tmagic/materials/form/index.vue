<template>
  <div class="xz-form">
    <div v-for="(f, i) in fields" :key="i" class="xz-form__field">
      <label>
        {{ f.label || f.key || '字段' }}
        <span v-if="f.required" style="color: #f53f3f">*</span>
      </label>
      <div class="xz-form__control">
        <span v-if="f.type === 'select'" class="xz-form__placeholder">请选择 ▾</span>
        <span v-else-if="f.type === 'date'" class="xz-form__placeholder">选择日期 ▾</span>
        <span v-else-if="f.type === 'switch'" class="xz-form__switch"></span>
        <span v-else class="xz-form__placeholder">{{ f.placeholder || '请输入' }}</span>
      </div>
    </div>
    <div class="xz-form__submit">{{ submitLabel }}</div>
  </div>
</template>

<script lang="ts" setup>
import { computed } from 'vue';

defineOptions({ name: 'xz-material-form' });

const props = defineProps<{ config: any }>();

const fields = computed(() => (Array.isArray(props.config.fields) ? props.config.fields : []));

const submitLabel = computed(() => {
  const a = props.config.submit?.action;
  if (a === 'api' || a === 'submit') return '提交（写入 ' + (props.config.submit?.path || '未配置接口') + '）';
  return '提交';
});
</script>

<style scoped>
.xz-form {
  background: #fff;
  border-radius: 8px;
  padding: 12px;
}

.xz-form__field {
  margin-bottom: 12px;
}

.xz-form__field label {
  display: block;
  margin-bottom: 4px;
  font-size: 13px;
  color: #4e5969;
}

.xz-form__control {
  height: 36px;
  padding: 0 10px;
  border: 1px solid #e5e6eb;
  border-radius: 6px;
  display: flex;
  align-items: center;
}

.xz-form__placeholder {
  font-size: 13px;
  color: #c9cdd4;
}

.xz-form__switch {
  width: 36px;
  height: 20px;
  border-radius: 10px;
  background: #e5e6eb;
}

.xz-form__submit {
  height: 38px;
  line-height: 38px;
  text-align: center;
  border-radius: 6px;
  background: #0054e1;
  color: #fff;
  font-size: 14px;
}
</style>
