import { createApp } from 'vue';
import ElementPlus from 'element-plus';
import zhCn from 'element-plus/es/locale/lang/zh-cn';
import 'element-plus/dist/index.css';

import { installTmagic } from './tmagic-plugin';
import App from './App.vue';

const app = createApp(App);
// Element Plus 组件（下拉框占位符、表格空态、分页器等）走中文语言包。
// 不挂的话 Select 占位符会显示英文 "Select"，和整站中文界面不一致。
app.use(ElementPlus, { locale: zhCn });
installTmagic(app);

app.mount('#app');
