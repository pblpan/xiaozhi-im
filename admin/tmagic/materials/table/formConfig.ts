import { defineFormConfig } from '@tmagic/form-schema';

/**
 * 表格物料：columns 用 table 类型数组编辑器（增删行、每行 key/label/width）。
 * width 是 number，table 单元格默认文本输入，保存时由转换层 Number() 校正。
 */
export default defineFormConfig([
  { name: 'className', type: 'data-source-input', text: 'class' },
  { name: 'dataPath', text: '数据路径', type: 'data-source-input' },
  {
    name: 'columns',
    text: '列定义',
    type: 'table',
    items: [
      { name: 'key', label: '字段 key' },
      { name: 'label', label: '列名' },
      { name: 'width', label: '宽度(px)' },
    ],
    defaultAdd: { key: '', label: '', width: 100 },
  },
]);
