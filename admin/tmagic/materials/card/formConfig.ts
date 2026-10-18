import { defineFormConfig } from '@tmagic/form-schema';

export default defineFormConfig([
  { name: 'className', type: 'data-source-input', text: 'class' },
  { name: 'title', text: '卡片标题', type: 'data-source-input' },
  { name: 'subtitle', text: '卡片副标题', type: 'data-source-input' },
]);
