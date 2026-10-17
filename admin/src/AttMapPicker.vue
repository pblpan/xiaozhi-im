<template>
  <el-dialog
    :model-value="modelValue"
    @update:model-value="(v) => emit('update:modelValue', v)"
    title="地图选点"
    width="720px"
    :close-on-click-modal="false"
    @closed="destroy"
  >
    <!-- 没配 key：给申请指引 + 填 key 的表单。不配也能用「获取当前定位」，所以
         这只是降级不是死路 -->
    <div v-if="!hasKey || showKeyForm" class="key-pane">
      <el-alert type="info" :closable="false" title="配置腾讯地图 Key 后即可在地图上选点">
        <template #default>
          <ol class="steps">
            <li>打开腾讯位置服务官网 <b>lbs.qq.com</b>，注册登录后进「控制台 → 应用管理 → 我的应用」，创建应用，能力勾选 <b>Web端(JS API GL)</b>；</li>
            <li>把生成的 Key 填到下面保存（个人用户免费额度够用）；</li>
            <li>建议在腾讯控制台给这个 Key 配 <b>Referer 白名单</b>（填管理台的访问地址）—— Key 在前端是明文的，配了白名单别人拿去也用不了。</li>
          </ol>
          <p class="dim">暂时不配也行：打卡点位弹窗里的「获取当前定位」不需要 Key。</p>
        </template>
      </el-alert>
      <div class="key-row">
        <el-input v-model="keyInput" placeholder="粘贴腾讯地图 Key" @keyup.enter="saveKey" />
        <el-button type="primary" :loading="saving" @click="saveKey">保存并加载地图</el-button>
        <el-button v-if="hasKey" @click="showKeyForm = false">返回地图</el-button>
      </div>
    </div>

    <div v-else>
      <div v-loading="loading" id="att-map-box" class="map-box"></div>
      <div v-if="mapErr" class="map-err">{{ mapErr }}</div>
      <div class="map-foot">
        <span>{{ pickText }}</span>
        <el-link type="primary" :underline="false" @click="showKeyForm = true">更换 Key</el-link>
      </div>
    </div>

    <template #footer>
      <el-button @click="emit('update:modelValue', false)">取消</el-button>
      <el-button type="primary" :disabled="!picked" @click="confirm">使用该位置</el-button>
    </template>
  </el-dialog>
</template>

<script setup>
/**
 * 打卡点位的地图选点（龙哥 2026-10-16：「考勤经纬度设置增加一键获取当前经纬度，
 * 最好有当前地图选点」）。
 *
 * 两条硬约束，写代码前必须知道：
 *
 * 1) 合规：国内地图底图只能用有审图号的供应商（腾讯/高德/百度/天地图）。
 *    这里用腾讯地图 GL JS。key 由管理员自己在腾讯位置服务官网申请
 *    （lbs.qq.com，个人免费），存服务端 settings，经 /api/admin/attendance/map-key
 *    下发 —— 加载 SDK 的是管理员本人的浏览器，key 到浏览器是功能前提，
 *    防泄露靠官网配 Referer 白名单（界面上有引导）。
 *
 * 2) 坐标系：库里存的是 **WGS-84**（手机 GPS 原始读数，服务端 haversine 直接
 *    硬算距离），腾讯地图是 **GCJ-02**。地图上点哪就存哪会差出几百米，
 *    现象是"半径设 500 还提示不在范围内"且极难查。所以：
 *      · 进地图：存量坐标 WGS-84 → GCJ-02 显示；
 *      · 出地图：点出来的 GCJ-02 → WGS-84 再交回表单。
 *    转换在 coord.js（往返误差实测 < 0.01 米）。
 */
import { ref, watch, nextTick } from 'vue';
import { ElMessage } from 'element-plus';
import api from './api';
import { wgs84ToGcj02, gcj02ToWgs84 } from './coord';

const props = defineProps({
  modelValue: { type: Boolean, default: false },
  // 表单里已有的坐标（WGS-84）。没有就空着，地图默认定位到当前位置/北京。
  lat: { type: [Number, String, null], default: null },
  lng: { type: [Number, String, null], default: null },
});
const emit = defineEmits(['update:modelValue', 'confirm']); // confirm(wgsLat, wgsLng)

const hasKey = ref(false);
const showKeyForm = ref(false);
const keyInput = ref('');
const saving = ref(false);
const loading = ref(false);
const mapErr = ref('');
const picked = ref(null); // 地图上选中的点，GCJ-02

let mapInst = null;
let markerLayer = null;
let sdkPromise = null;

const TMAP_SDK = 'https://map.qq.com/api/gljs?v=1.exp';

const pickText = ref('在地图上点一下要选的位置');
watch(picked, (p) => {
  if (!p) { pickText.value = '在地图上点一下要选的位置'; return; }
  const w = gcj02ToWgs84(p.lat, p.lng);
  pickText.value = `已选点（火星 ${p.lat.toFixed(6)}, ${p.lng.toFixed(6)}）`
    + ` → 将存入 WGS-84（${w.lat.toFixed(6)}, ${w.lng.toFixed(6)}）`;
});

// ---- key ----

async function fetchKey() {
  try {
    const { data } = await api.get('/admin/attendance/map-key');
    hasKey.value = !!data.hasKey;
    keyInput.value = data.key || '';
  } catch (e) {
    mapErr.value = '读取地图配置失败：' + (e.response?.data?.error || e.message);
  }
}

async function saveKey() {
  saving.value = true;
  try {
    const { data } = await api.put('/admin/attendance/map-key', { key: keyInput.value });
    hasKey.value = !!data.hasKey;
    keyInput.value = data.key || '';
    showKeyForm.value = false;
    ElMessage.success(data.hasKey ? 'Key 已保存，正在加载地图' : 'Key 已清除');
    if (data.hasKey) await initMap();
  } catch (e) {
    ElMessage.error(e.response?.data?.error || '保存失败');
  } finally {
    saving.value = false;
  }
}

// ---- SDK 与地图 ----

function loadSdk(key) {
  if (window.TMap) return Promise.resolve(window.TMap);
  if (sdkPromise) return sdkPromise;
  sdkPromise = new Promise((resolve, reject) => {
    const s = document.createElement('script');
    s.src = `${TMAP_SDK}&key=${encodeURIComponent(key)}`;
    s.onload = () => (window.TMap
      ? resolve(window.TMap)
      : reject(new Error('SDK 加载完成但未找到 TMap 对象（key 可能不正确）')));
    s.onerror = () => reject(new Error('腾讯地图 SDK 加载失败：请检查网络连接'));
    document.head.appendChild(s);
  });
  sdkPromise.catch(() => { sdkPromise = null; });
  return sdkPromise;
}

const DEFAULT_CENTER = { lat: 39.9087, lng: 116.3975 }; // 北京，兜底中的兜底

async function initMap() {
  loading.value = true;
  mapErr.value = '';
  try {
    const TMap = await loadSdk(keyInput.value);
    await nextTick();
    // 弹窗有展开动画，等一拍再量容器；高度在 CSS 里钉死（GL 地图容器必须有确定高度）
    await new Promise((r) => setTimeout(r, 60));
    const box = document.getElementById('att-map-box');
    if (!box) throw new Error('地图容器不在文档里');

    const oldLat = Number(props.lat), oldLng = Number(props.lng);
    let center = DEFAULT_CENTER;
    if (Number.isFinite(oldLat) && Number.isFinite(oldLng) && oldLat !== 0 && oldLng !== 0) {
      center = wgs84ToGcj02(oldLat, oldLng); // 存量 WGS-84 → GCJ-02 显示
    } else {
      // 没配过点位：试着把地图开到管理员当前位置（拿不到就静默用默认中心，
      // 不弹错误 —— 定位失败不该挡住选点这个主流程）
      const g = await browserPos();
      if (g) center = wgs84ToGcj02(g.lat, g.lng);
    }

    mapInst = new TMap.Map('att-map-box', {
      center: new TMap.LatLng(center.lat, center.lng),
      zoom: 16,
    });
    const pin = 'data:image/svg+xml,' + encodeURIComponent(
      '<svg xmlns="http://www.w3.org/2000/svg" width="26" height="36" viewBox="0 0 26 36">'
      + '<path d="M13 0C5.8 0 0 5.8 0 13c0 9.8 13 23 13 23s13-13.2 13-23C26 5.8 20.2 0 13 0z" fill="#e34d59"/>'
      + '<circle cx="13" cy="13" r="5.2" fill="#fff"/></svg>');
    markerLayer = new TMap.MultiMarker({
      map: mapInst,
      styles: {
        pick: new TMap.MarkerStyle({ width: 26, height: 36, src: pin, anchor: { x: 13, y: 36 } }),
      },
      geometries: [],
    });
    if (center !== DEFAULT_CENTER) setPick(center.lat, center.lng); // 已有点位：标记摆上去
    mapInst.on('click', (evt) => {
      const ll = evt && evt.latLng;
      if (!ll) return;
      setPick(ll.lat, ll.lng);
    });
  } catch (e) {
    mapErr.value = String(e.message || e);
  } finally {
    loading.value = false;
  }
}

function setPick(lat, lng) {
  picked.value = { lat, lng };
  if (markerLayer && window.TMap) {
    markerLayer.updateGeometries([
      { id: 'p', styleId: 'pick', position: new window.TMap.LatLng(lat, lng) },
    ]);
  }
}

/** 浏览器定位（WGS-84）。拿不到返回 null，不抛。 */
function browserPos() {
  return new Promise((resolve) => {
    if (!navigator.geolocation) return resolve(null);
    navigator.geolocation.getCurrentPosition(
      (pos) => resolve({ lat: pos.coords.latitude, lng: pos.coords.longitude }),
      () => resolve(null),
      { timeout: 6000, maximumAge: 60000 },
    );
  });
}

function destroy() {
  try { if (mapInst && mapInst.destroy) mapInst.destroy(); } catch (_) { /* 销毁失败就交给 GC */ }
  mapInst = null;
  markerLayer = null;
  picked.value = null;
}

function confirm() {
  if (!picked.value) return;
  // 🔴 GCJ-02 → WGS-84：不转换的话员工拿 GPS 打卡会差几百米（见文件头注释）
  const w = gcj02ToWgs84(picked.value.lat, picked.value.lng);
  emit('confirm', w.lat, w.lng);
  emit('update:modelValue', false);
}

// 打开时拿 key / 建图；关掉时清理
watch(() => props.modelValue, async (open) => {
  if (!open) return;
  picked.value = null;
  mapErr.value = '';
  showKeyForm.value = false;
  await fetchKey();
  if (hasKey.value) await initMap();
  else showKeyForm.value = true;
});
</script>

<style scoped>
/* 🔴🔴 2026-10-17 线上事故修复：地图弹窗点不动、只能刷新页面才退得出去。
 *
 * 根因（Playwright + 真腾讯地图 SDK 复现，铁证）：
 *   TMap GL JS 在地图容器里造的内层容器是
 *     <div style="position:absolute;left:0;top:0;z-index:1000;width:100%;height:100%">
 *   它要找一个"定位祖先"当包含块。.map-box 当时是 position:static，
 *   于是它一路向上找到 .el-dialog（Element Plus 的 .el-dialog 恰好是 position:relative），
 *   结果这层按"整个弹窗"展开 —— 实测 720x569（地图框只有 690x420），
 *   把标题栏的 X、取消、使用该位置 全盖住，pointer-events 全被它吃掉。
 *   现象：地图能点、能选点，但所有按钮点了没反应，只能刷新页面退出。
 *
 * 修法：给 .map-box 补 position:relative（+ overflow:hidden 防圆角溢出），
 *   把 TMap 的内层容器按在地图框内。实测修复后内层容器 = 688x420，
 *   按钮 elementFromPoint 命中自身，点「使用该位置」正常回填并关闭弹窗。
 *
 * ⚠️ 以后任何把第三方地图/图表 SDK 塞进 Element Plus 弹窗的容器，
 *    都必须显式写 position:relative —— 这类 SDK 一律用 absolute 内层。 */
.map-box {
  position: relative; /* 🔴 TMap 内层 absolute 容器的定位父级，删了就会重现上面的事故 */
  height: 420px;
  width: 100%;
  border: 1px solid var(--el-border-color);
  border-radius: 6px;
  overflow: hidden;
}
.map-err {
  margin-top: 8px;
  color: var(--el-color-danger);
  font-size: 12.5px;
}
.map-foot {
  margin-top: 8px;
  display: flex;
  align-items: center;
  justify-content: space-between;
  font-size: 12.5px;
  color: var(--el-text-color-secondary);
}
.key-row {
  margin-top: 12px;
  display: flex;
  gap: 8px;
}
.steps {
  margin: 0;
  padding-left: 18px;
  line-height: 1.9;
}
.dim {
  margin: 6px 0 0;
  color: var(--el-text-color-secondary);
}
</style>
