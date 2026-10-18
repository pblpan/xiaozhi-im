import { defineFormConfig } from '@tmagic/form-schema';
import { COLOR_OPTIONS } from '../_shared/colors';

/**
 * 按钮物料：label + color 直接对应小智 action 组件字段；
 * onTap 用 fieldset 包住 {action, path, method, page, text, url} 六个子字段。
 *
 * 🔴 为什么用 fieldset 而不是 'onTap.path' 点号字段名：tmagic 的 MForm 对
 *    点号字段名只当字面量键存取（obj[name]），嵌套对象永远不更新——
 *    面板里填了路径，node.onTap.path 仍是初始值，服务端 validate 拒收。
 *    fieldset 的 items 走 initItemsValue 建 values.onTap 嵌套对象，
 *    子字段 model 即该对象，读写往返一致（见 form/formConfig.ts 同款注释）。
 *
 * 🔴 服务端 validate 会卡：api/submit 的 path 必须以 /api/hooks/ 开头，
 *    openUrl 只允许 https —— 画布上不拦，保存时服务端兜底（错误会原样展示）。
 */
export default defineFormConfig([
  { name: 'className', type: 'data-source-input', text: 'class' },
  { name: 'label', text: '按钮文字', type: 'data-source-input' },
  { name: 'color', text: '颜色', type: 'select', options: COLOR_OPTIONS },
  {
    name: 'onTap',
    text: '点击动作',
    type: 'fieldset',
    items: [
      {
        name: 'action',
        text: '动作类型',
        type: 'select',
        options: [
          { text: '调接口（刷新数据）', value: 'api' },
          { text: '提交表单', value: 'submit' },
          { text: '跳页面', value: 'navigate' },
          { text: '复制', value: 'copy' },
          { text: '打开链接', value: 'openUrl' },
        ],
      },
      { name: 'path', text: '接口路径（api/submit，须 /api/hooks/ 开头）', type: 'data-source-input' },
      {
        name: 'method',
        text: '请求方法',
        type: 'select',
        options: [
          { text: 'GET', value: 'GET' },
          { text: 'POST', value: 'POST' },
        ],
      },
      { name: 'page', text: '目标页面（navigate）', type: 'data-source-input' },
      { name: 'text', text: '复制内容（copy）', type: 'data-source-input' },
      { name: 'url', text: '链接（openUrl，须 https）', type: 'data-source-input' },
    ],
  },
]);
