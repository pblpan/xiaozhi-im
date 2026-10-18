import { defineFormConfig } from '@tmagic/form-schema';

export default defineFormConfig([
  { name: 'className', type: 'data-source-input', text: 'class' },
  { name: 'dataPath', text: '数据路径', type: 'data-source-input' },
  { name: 'itemTemplate.title', text: '标题字段', type: 'data-source-input' },
  { name: 'itemTemplate.subtitle', text: '副标题字段', type: 'data-source-input' },
  { name: 'itemTemplate.trailing', text: '右侧字段', type: 'data-source-input' },
]);
