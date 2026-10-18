import { defineFormConfig } from '@tmagic/form-schema';

/**
 * 表单物料：fields 用 table 数组编辑器；submit 指向数据源写入接口。
 *
 * 🔴 submit 必须用 fieldset（嵌套对象），不能用 'submit.path' 点号字段名：
 *    tmagic 的 MForm 对点号字段名只当**字面量键**存取——initValueItem /
 *    setValue / 字段组件全是 obj[name]，嵌套对象永远不更新。表现为
 *    "属性面板里填了提交接口、保存后 node.submit.path 还是初始值"，
 *    服务端 validate 直接以「api 的 path 不能为空」拒掉整个模块。
 *    fieldset 的 items 走 initItemsValue → values.submit = {action,path,method}，
 *    子字段的 model 就是 values.submit，读写都是原生嵌套，往返一致。
 *
 * select 字段的动态选项走 optionsFrom（静态 options 数组后续支持）。
 */
export default defineFormConfig([
  { name: 'className', type: 'data-source-input', text: 'class' },
  {
    name: 'fields',
    text: '表单字段',
    type: 'table',
    items: [
      { name: 'key', label: '字段 key' },
      { name: 'label', label: '字段名' },
      {
        name: 'type',
        label: '类型',
        type: 'select',
        options: [
          { text: '文本', value: 'text' },
          { text: '数字', value: 'number' },
          { text: '下拉', value: 'select' },
          { text: '日期', value: 'date' },
          { text: '多行', value: 'textarea' },
          { text: '开关', value: 'switch' },
        ],
      },
      { name: 'required', label: '必填(true/false)' },
      { name: 'placeholder', label: '占位提示' },
      { name: 'optionsFrom', label: '动态选项接口' },
      { name: 'optionsPath', label: '选项列表路径' },
      { name: 'optionLabel', label: '选项标签字段' },
      { name: 'optionValue', label: '选项值字段' },
    ],
    defaultAdd: { key: '', label: '', type: 'text', required: 'false', placeholder: '' },
  },
  {
    name: 'submit',
    text: '提交（表单即录入）',
    type: 'fieldset',
    items: [
      {
        name: 'action',
        text: '提交动作',
        type: 'select',
        options: [
          { text: '写入数据源', value: 'api' },
          { text: '仅留痕', value: 'submit' },
        ],
      },
      { name: 'path', text: '提交接口（须 /api/hooks/ 开头）', type: 'data-source-input' },
      {
        name: 'method',
        text: '请求方法',
        type: 'select',
        options: [
          { text: 'POST', value: 'POST' },
          { text: 'GET', value: 'GET' },
        ],
      },
    ],
  },
]);
