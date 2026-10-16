/**
 * 坐标系转换：GCJ-02（火星坐标，腾讯/高德地图用）↔ WGS-84（手机 GPS 原始读数）。
 *
 * ─────────────────────────────────────────────────────────────
 * 为什么需要它（这是个会 silently 出错几百米的坑）
 * ─────────────────────────────────────────────────────────────
 * 打卡定位的存储基准是 **WGS-84**：客户端把 Geolocator 的原始读数直接上报，
 * 服务端 haversine 拿点位和打卡坐标硬算距离（server/src/attendance.js 的注释
 * 写明了"两头同一基准，距离才准"）。
 *
 * 而腾讯地图 GL JS 的瓦片和一切返回值都是 **GCJ-02**（国家规定的火星偏移）。
 * 如果在地图上点哪就直接存哪，存进去的是 GCJ-02，员工拿着 WGS-84 的 GPS 来打卡，
 * 两头能差出 100~500 米 —— 现象是"围栏半径都设 500 了还提示不在范围内"，
 * 而看数据库两边坐标都"差不多"，极难查。
 *
 * 所以本模块两个方向都要：
 *   · wgs84ToGcj02：把库里/表单里的 WGS-84 点位显示到腾讯地图上；
 *   · gcj02ToWgs84：把地图上点出来的 GCJ-02 坐标转回 WGS-84 再存。
 *
 * ─────────────────────────────────────────────────────────────
 * 精度说明（不承诺、不夸大）
 * ─────────────────────────────────────────────────────────────
 * 正向（WGS→GCJ）是确定变换；反向（GCJ→WGS）是数值迭代求解，国内绝大多数
 * 地点误差在几米内、边界地区可能到几十米。对"围栏半径几十上百米"的打卡场景
 * 够用；如果谁拿它做测绘级定位，那是用错了工具。
 *
 * 算法是业界公开的 eviltransform 思路（a=6378245.0, ee=0.00669342162296594323），
 * 不是本文件独创 —— 这种基础变换越贴近公开实现越好，方便和网上工具交叉验证。
 */

const PI = Math.PI;
const AXIS = 6378245.0; // 克氏椭球长半轴
const OFFSET = 0.00669342162296594323; // 扁率相关常量 ee

/** 是否在中国坐标体系范围内（境外不偏移，原样返回） */
function outOfChina(lat, lng) {
  return !(lng > 73.66 && lng < 135.05 && lat > 3.86 && lat < 53.55);
}

function transformLat(x, y) {
  let ret = -100.0 + 2.0 * x + 3.0 * y + 0.2 * y * y + 0.1 * x * y + 0.2 * Math.sqrt(Math.abs(x));
  ret += (20.0 * Math.sin(6.0 * x * PI) + 20.0 * Math.sin(2.0 * x * PI)) * 2.0 / 3.0;
  ret += (20.0 * Math.sin(y * PI) + 40.0 * Math.sin(y / 3.0 * PI)) * 2.0 / 3.0;
  ret += (160.0 * Math.sin(y / 12.0 * PI) + 320 * Math.sin(y * PI / 30.0)) * 2.0 / 3.0;
  return ret;
}

function transformLng(x, y) {
  let ret = 300.0 + x + 2.0 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * Math.sqrt(Math.abs(x));
  ret += (20.0 * Math.sin(6.0 * x * PI) + 20.0 * Math.sin(2.0 * x * PI)) * 2.0 / 3.0;
  ret += (20.0 * Math.sin(x * PI) + 40.0 * Math.sin(x / 3.0 * PI)) * 2.0 / 3.0;
  ret += (150.0 * Math.sin(x / 12.0 * PI) + 300.0 * Math.sin(x / 30.0 * PI)) * 2.0 / 3.0;
  return ret;
}

function delta(lat, lng) {
  let dLat = transformLat(lng - 105.0, lat - 35.0);
  let dLng = transformLng(lng - 105.0, lat - 35.0);
  const radLat = lat / 180.0 * PI;
  let magic = Math.sin(radLat);
  magic = 1 - OFFSET * magic * magic;
  const sqrtMagic = Math.sqrt(magic);
  dLat = (dLat * 180.0) / ((AXIS * (1 - OFFSET)) / (magic * sqrtMagic) * PI);
  dLng = (dLng * 180.0) / (AXIS / sqrtMagic * Math.cos(radLat) * PI);
  return { dLat, dLng };
}

/**
 * WGS-84 → GCJ-02。用于把存储/表单里的点位显示到腾讯地图上。
 * @returns {{lat:number,lng:number}} 境外原样返回
 */
export function wgs84ToGcj02(lat, lng) {
  if (outOfChina(lat, lng)) return { lat, lng };
  const { dLat, dLng } = delta(lat, lng);
  return { lat: lat + dLat, lng: lng + dLng };
}

/**
 * GCJ-02 → WGS-84。用于把地图上点出来的坐标转回存储基准。
 * 迭代逼近：正向变换是单调的，几次迭代即收敛到亚米级。
 * @returns {{lat:number,lng:number}} 境外原样返回
 */
export function gcj02ToWgs84(lat, lng) {
  if (outOfChina(lat, lng)) return { lat, lng };
  let wLat = lat, wLng = lng;
  for (let i = 0; i < 5; i++) {
    const g = wgs84ToGcj02(wLat, wLng);
    wLat += lat - g.lat;
    wLng += lng - g.lng;
  }
  return { lat: wLat, lng: wLng };
}
