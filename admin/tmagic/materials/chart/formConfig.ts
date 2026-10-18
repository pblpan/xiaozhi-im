import { defineFormConfig } from '@tmagic/form-schema';
import { COLOR_OPTIONS } from '../_shared/colors';

export default defineFormConfig([
  { name: 'className', type: 'data-source-input', text: 'class' },
  {
    name: 'kind',
    text: '图表类型',
    type: 'select',
    options: [
      { text: '柱状图', value: 'bar' },
      { text: '折线图', value: 'line' },
    ],
  },
  { name: 'dataPath', text: '数据路径', type: 'data-source-input' },
  { name: 'xKey', text: 'X 轴字段', type: 'data-source-input' },
  { name: 'yKey', text: 'Y 轴字段', type: 'data-source-input' },
  { name: 'color', text: '颜色', type: 'select', options: COLOR_OPTIONS },
]);
