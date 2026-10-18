/*
 * 画布左侧物料面板分组。
 * 🔴 这里的 type 与 convert.js FIELD_MAP 的键一一对应（= 小智 module schema 组件名）。
 *    新增物料时同步：componentGroupList + propsConfigs + runtime 注册 + 服务端白名单 + 客户端渲染。
 */

import {
  ChatDotSquare,
  DataLine,
  Files,
  Grid,
  Minus,
  Pointer,
  ScaleToOriginal,
  Tickets,
} from '@element-plus/icons-vue';

export default [
  {
    title: '布局',
    items: [
      { icon: Files, text: '卡片', type: 'card' },
      { icon: Minus, text: '分割线', type: 'divider' },
    ],
  },
  {
    title: '内容',
    items: [
      { icon: ChatDotSquare, text: '文本', type: 'text' },
      { icon: Tickets, text: '列表', type: 'list' },
      { icon: Grid, text: '表格', type: 'table' },
      { icon: DataLine, text: '图表', type: 'chart' },
    ],
  },
  {
    title: '交互',
    items: [
      { icon: Pointer, text: '按钮', type: 'action' },
      { icon: ScaleToOriginal, text: '表单', type: 'form' },
    ],
  },
];
