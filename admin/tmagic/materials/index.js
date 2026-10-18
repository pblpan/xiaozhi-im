/*
 * 小智物料集中索引 —— ModuleBuilder.vue 从这里取 propsConfigs / propsValues / eventMethodList。
 * 🔴 新增物料：这里加一行，runtime/main.js 注册组件，convert.js FIELD_MAP 加白名单，
 *    三处齐了才发布（否则管理台能拖、客户端不认）。
 */

import textConfig from './text/formConfig';
import textValue from './text/initValue';
import textEvent from './text/event';

import dividerConfig from './divider/formConfig';
import dividerValue from './divider/initValue';
import dividerEvent from './divider/event';

import cardConfig from './card/formConfig';
import cardValue from './card/initValue';
import cardEvent from './card/event';

import listConfig from './list/formConfig';
import listValue from './list/initValue';
import listEvent from './list/event';

import tableConfig from './table/formConfig';
import tableValue from './table/initValue';
import tableEvent from './table/event';

import formConfig from './form/formConfig';
import formValue from './form/initValue';
import formEvent from './form/event';

import actionConfig from './action/formConfig';
import actionValue from './action/initValue';
import actionEvent from './action/event';

import chartConfig from './chart/formConfig';
import chartValue from './chart/initValue';
import chartEvent from './chart/event';

export const propsConfigs = {
  text: textConfig,
  divider: dividerConfig,
  card: cardConfig,
  list: listConfig,
  table: tableConfig,
  form: formConfig,
  action: actionConfig,
  chart: chartConfig,
};

export const propsValues = {
  text: textValue,
  divider: dividerValue,
  card: cardValue,
  list: listValue,
  table: tableValue,
  form: formValue,
  action: actionValue,
  chart: chartValue,
};

export const eventMethodList = {
  text: textEvent,
  divider: dividerEvent,
  card: cardEvent,
  list: listEvent,
  table: tableEvent,
  form: formEvent,
  action: actionEvent,
  chart: chartEvent,
};

export const materialTypes = Object.keys(propsConfigs);
