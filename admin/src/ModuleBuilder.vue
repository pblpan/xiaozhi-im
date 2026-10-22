<template>
  <el-dialog
    v-model="visible"
    :title="`可视化搭建 · ${moduleTitle || '未命名模块'}`"
    fullscreen
    destroy-on-close
    :before-close="beforeClose"
    :close-on-click-modal="false"
    class="xz-builder-dialog"
  >
    <div class="xz-builder">
      <div class="xz-builder__bar">
        <span class="xz-builder__hint">
          左侧拖物料到中间画布；点画布中的元素，在右侧改字段。保存时自动转成客户端 module 格式（服务端还会校验一遍）。
          不会用？看「系统帮助 → 八、可视化搭建（拖拽画布）怎么用」，有详细步骤和插入案例。
        </span>
        <span class="xz-builder__ops">
          <el-button size="small" @click="previewOpen = true">预览</el-button>
          <el-button size="small" :loading="saving" type="primary" @click="save">保存到模块</el-button>
        </span>
      </div>

      <TMagicEditor
        v-if="editorMounted"
        v-model="dsl"
        ref="editorRef"
        class="xz-builder__editor"
        :runtime-url="runtimeUrl"
        :component-group-list="componentGroupList"
        :props-configs="propsConfigs"
        :props-values="propsValues"
        :event-method-list="eventMethodList"
        :stage-rect="stageRect"
        :auto-scroll-into-view="true"
      ></TMagicEditor>
    </div>

    <!-- 预览：runtime iframe（preview 模式，DSL 由 postMessage 推送） -->
    <el-dialog v-model="previewOpen" title="预览" :width="stageRect.width + 40" append-to-body>
      <iframe
        v-if="previewOpen"
        ref="previewIframe"
        class="xz-builder__preview"
        :style="{ height: stageRect.height + 'px' }"
        :src="runtimeUrl + '?preview=1'"
        @load="pushDslToPreview"
      ></iframe>
    </el-dialog>
  </el-dialog>
</template>

<script setup>
/*
 * 小智自定义应用 · 可视化搭建器
 *
 * 架构：
 *  - 编辑器 = @tmagic/editor（左物料 / 中画布 iframe / 右属性面板）
 *  - 画布 iframe = tmagic/runtime 构建产物（/tmagic-runtime/index.html），
 *    注册了 8 种小智物料 + tmagic 容器系（page/container/page-fragment/...）
 *  - 保存链路：serializeConfig(DSL) → dslToBody() → emit('save') → 父组件 POST /admin/modules
 *    （服务端 appmodules.js validate 做最终兜底：封闭组件集 / 动作白名单 / hooks 前缀）
 */
import { computed, nextTick, onBeforeUnmount, ref, shallowRef, toRaw, watch } from 'vue';
import { ElMessage, ElMessageBox } from 'element-plus';
import { editorService, TMagicEditor } from '@tmagic/editor';

import componentGroupList from '../tmagic/componentGroupList';
import { propsConfigs, propsValues, eventMethodList } from '../tmagic/materials';
import { bodyToDsl, dslToBody } from '../tmagic/convert';

const props = defineProps({
  modelValue: { type: Boolean, default: false },
  /** 当前模块的 body（ModuleComponent JSON 数组） */
  body: { type: Array, default: () => [] },
  moduleTitle: { type: String, default: '' },
});

const emit = defineEmits(['update:modelValue', 'save']);

const visible = computed({
  get: () => props.modelValue,
  set: (v) => emit('update:modelValue', v),
});

// 画布 iframe 地址。管理台 base 是 /admin/，publicDir 内容挂在 base 下，
// 所以 runtime 产物在 /admin/tmagic-runtime/（dev 与生产一致）。
const runtimeUrl = '/admin/tmagic-runtime/index.html';

// 手机画布尺寸（与客户端工作台一致的口径：375 宽）
const stageRect = ref({ width: 375, height: 720 });

const editorRef = shallowRef();
const editorMounted = ref(false);
const saving = ref(false);
const previewOpen = ref(false);
const previewIframe = ref();

// DSL = tmagic 的 MApp 形状；打开时由 body 转来
const dsl = ref(bodyToDsl(props.body));

// beforeDoAdd：物料落画布前的兜底。
// 🔴 约定（BaseService 插件机制）：beforeXxx 的返回数组会**整体替换**原方法参数，
//    所以必须 return [config, parent] 把收到的 parent 原样传回；
//    返回 [config, undefined] 会把父节点抹没，doAdd 里读 parent.type 直接抛。
editorService.usePlugin({
  beforeDoAdd: (config, parent) => {
    // 容器类物料（card）必须带 items，否则画布递归渲染报错
    if (config.type === 'card' && !Array.isArray(config.items)) {
      config.items = [];
    }
    return [config, parent];
  },
});

onBeforeUnmount(() => {
  editorService.removeAllPlugins();
});

async function save() {
  saving.value = true;
  try {
    // 🔴 别用 serializeConfig：它返回的是 serialize-javascript 的字符串
    //    （键名连引号都没有），当对象用 items 全是 undefined。toRaw 拿原始对象即可。
    const body = dslToBody(toRaw(dsl.value));
    emit('save', body);
    visible.value = false;
  } catch (e) {
    ElMessage.error({ message: '转换失败：' + (e.message || e), duration: 6000 });
  } finally {
    saving.value = false;
  }
}

function pushDslToPreview() {
  const win = previewIframe.value?.contentWindow;
  if (!win) return;
  win.postMessage({ type: 'xz-tmagic-dsl-update', dsl: toRaw(dsl.value) }, '*');
}

async function beforeClose(done) {
  // 画布内容与打开时不一致就拦一下（DSL 深比较用 JSON，模块 body 都是纯数据）
  const opened = JSON.stringify(bodyToDsl(props.body));
  const current = JSON.stringify(dsl.value);
  if (opened !== current) {
    try {
      await ElMessageBox.confirm('画布有未保存的修改，关闭后不生效。确定关闭？', '未保存修改', { type: 'warning' });
    } catch {
      return; // 用户取消，保持打开
    }
  }
  done();
}

// 对话框打开后延时挂载 editor（destroy-on-close 下每次打开都是全新实例，
// 而 runtime iframe 的 magic 协议握手需要 editor DOM 就绪后再建立）
watch(
  () => props.modelValue,
  async (open) => {
    if (open) {
      dsl.value = bodyToDsl(props.body);
      editorMounted.value = false;
      await nextTick();
      editorMounted.value = true;
    }
  },
  { immediate: true },
);
</script>

<style scoped>
.xz-builder {
  display: flex;
  flex-direction: column;
  /* 🔴 高度链必须全链路确定高度，少一环 .m-editor 就会被内容撑到几千像素：
       el-dialog(fullscreen,100vh) → __body(flex:1) → xz-builder(flex:1)
       → xz-builder__editor(flex:1) → .m-editor(height:100%) → .m-editor-content(calc(100%-35px))
       tmagic 样式表没给 .m-editor 写 height（它自己的 playground 是显式补的）。 */
  flex: 1;
  min-height: 0;
}

.xz-builder__bar {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
  padding: 8px 4px;
  flex: none;
}

.xz-builder__hint {
  font-size: 12px;
  color: #909399;
}

.xz-builder__editor {
  flex: 1;
  min-height: 0;
}

/* TMagicEditor 的根就是 .m-editor（传入的 class 合并到它根上，是同一个元素），
   所以是并列类选择器而不是后代；tmagic 样式表没给 .m-editor 写 height，
   它自己 playground 里是显式补 height:100% 的。 */
.xz-builder__editor.m-editor {
  height: 100%;
}

.xz-builder__preview {
  width: 100%;
  border: none;
  background: #fff;
}
</style>

<!-- 🔴 这里必须是无 scoped 的全局块：el-dialog 用 teleport 渲染到 body，
     其根元素拿不到本组件的 scoped attr，:deep() 选择器匹配不到。
     类名带 xz- 前缀防撞。 -->
<style>
/* element-plus 2.x 的 dialog 是 block + height:100% + overflow:auto，
   改成 flex column 后 .xz-builder 的 flex:1 才有高度可依。 */
.xz-builder-dialog.el-dialog {
  display: flex;
  flex-direction: column;
}

.xz-builder-dialog .el-dialog__body {
  display: flex;
  flex-direction: column;
  flex: 1;
  min-height: 0;
  overflow: hidden;
  padding: 0 12px 12px;
}

/* flex item 默认 min-height:auto 会被内容（左侧组件树/图层面板）撑到几千像素，
   高度链全断。显式给 0 让 flex 算法接管。 */
.xz-builder-dialog .m-editor-content,
.xz-builder-dialog .m-editor-layout-center,
.xz-builder-dialog .m-editor-workspace,
.xz-builder-dialog .m-editor-scroll-viewer-container {
  min-height: 0;
}
</style>
