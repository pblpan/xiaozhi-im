// 小智物料共享：语义色映射（红线：颜色只允许语义枚举，画布预览用近似色，
// 真机颜色由客户端主题令牌决定 —— 管理台预览只是"大概齐"）
export const SEMANTIC_COLORS: Record<string, string> = {
  primary: '#0054e1',
  success: '#00b42a',
  danger: '#f53f3f',
  warning: '#ff7d00',
  muted: '#86909c',
  default: '#1d2129',
};

export function semanticColor(name: string | undefined): string {
  return SEMANTIC_COLORS[name || 'default'] || SEMANTIC_COLORS.default;
}

/** 属性面板共用的语义色下拉选项 */
export const COLOR_OPTIONS = [
  { text: '主色', value: 'primary' },
  { text: '成功', value: 'success' },
  { text: '危险', value: 'danger' },
  { text: '警告', value: 'warning' },
  { text: '弱化', value: 'muted' },
  { text: '默认', value: 'default' },
];
