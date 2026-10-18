import { defineFormConfig } from '@tmagic/form-schema';
import { COLOR_OPTIONS } from '../_shared/colors';

export default defineFormConfig([
  { name: 'className', type: 'data-source-input', text: 'class' },
  { name: 'text', text: '文本内容', type: 'data-source-input' },
  {
    name: 'size',
    text: '字号',
    type: 'select',
    options: [
      { text: '12', value: 12 },
      { text: '14', value: 14 },
      { text: '15', value: 15 },
      { text: '16', value: 16 },
      { text: '18', value: 18 },
      { text: '20', value: 20 },
      { text: '24', value: 24 },
    ],
  },
  { name: 'color', text: '颜色', type: 'select', options: COLOR_OPTIONS },
  {
    name: 'align',
    text: '对齐',
    type: 'select',
    options: [
      { text: '左', value: 'left' },
      { text: '中', value: 'center' },
      { text: '右', value: 'right' },
    ],
  },
]);
