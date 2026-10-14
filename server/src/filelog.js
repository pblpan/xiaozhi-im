// 文件日志镜像：把 console 输出复制一份到文件（仅设了 XZ_LOG_FILE 时启用）。
//
// 为什么需要它：Windows 服务**没有控制台**，node 的 stdout/stderr 直接进黑洞 ——
// 服务模式下排障时什么都看不到（前台双击 / 后台 .cmd 都有重定向或窗口）。
// 注册服务时由安装链路在服务的 Environment 里设 XZ_LOG_FILE，node 启动时
// 发现这个变量就把 console.log/error 镜像一份到该文件。
//
// 三条纪律：
//   ① 没设 XZ_LOG_FILE 就完全不启用 —— 前台/后台启动的行为一字节不变；
//   ② 日志写失败**绝不影响服务**：任何一步 try/catch，失败就静默转纯 console；
//   ③ 单代轮转 5MB（与 _hidden.cmd 同口径）：常驻服务日志只增不减的话，
//      跑几个月能吃掉几百 MB，客户只会发现"盘莫名其妙少了一块"。
'use strict';

const fs = require('fs');

const MAX_BYTES = 5 * 1024 * 1024;

let stream = null;

/** 把任意参数安全拼成一行（对齐 console 的行为：字符串原样，其余 JSON 化） */
function fmt(args) {
  return args
    .map((a) => {
      if (typeof a === 'string') return a;
      try { return JSON.stringify(a); } catch { return String(a); }
    })
    .join(' ');
}

/** 超过 5MB 就把当前日志改名成 <file>.1（旧的直接覆盖）。 */
function rotateIfBig(file) {
  try {
    if (fs.existsSync(file) && fs.statSync(file).size > MAX_BYTES) {
      fs.renameSync(file, file + '.1');
    }
  } catch { /* 动不了就算了，日志不值得为它冒险 */ }
}

/**
 * @param {string|null|undefined} file 目标日志文件路径
 * @returns {{enabled: boolean, file: string|null, reason?: string}}
 */
function init(file) {
  const target = file && String(file).trim() ? String(file).trim() : null;
  if (!target) return { enabled: false, file: null };

  try {
    rotateIfBig(target);
    // 首写先写 UTF-8 BOM：记事本遇到无 BOM 的 UTF-8 会按 ANSI(GBK) 解释，
    // 打开就是满屏乱码，客户反而以为服务端出问题了（与 _hidden.cmd 同理由）。
    if (!fs.existsSync(target)) fs.writeFileSync(target, '\ufeff');
    // 🔴 先**同步**试开一次再交给 WriteStream：createWriteStream 是懒打开的，
    //    "路径是个目录 / 没有写权限"不会同步抛错，而要等异步 error 事件 ——
    //    那时 init 早就返回了 enabled:true，调用方会在状态栏里显示一个假的
    //    "文件日志已启用"，排障时反而被误导。同步 openSync 失败就是真失败。
    // 🔴 先**同步**验证目标真的可写，再交给 WriteStream：
    //    createWriteStream 是懒打开的，"路径是个目录 / 没有写权限"不会同步
    //    抛错，而要等异步 error 事件 —— 那时 init 早就返回了 enabled:true，
    //    调用方会在状态栏里显示一个假的"文件日志已启用"，排障时反而被误导。
    //    （Windows 上 openSync 对目录竟然不报错，所以目录要单独查。）
    try {
      const st = fs.statSync(target);
      if (st.isDirectory()) throw new Error('日志路径是一个目录');
    } catch (e) {
      if (e && e.code !== 'ENOENT') {
        return { enabled: false, file: target, reason: String(e.message || e) };
      }
      // ENOENT = 首次创建，正常
    }
    const fd = fs.openSync(target, 'a');
    fs.closeSync(fd);
    stream = fs.createWriteStream(target, { flags: 'a' });
    stream.on('error', () => { stream = null; });
  } catch (e) {
    stream = null;
    return { enabled: false, file: target, reason: String(e && e.message || e) };
  }

  const patch = (orig) =>
    function patched(...args) {
      orig(...args);
      try {
        if (stream) stream.write(fmt(args) + '\n');
      } catch { /* 日志绝不能搞崩服务 */ }
    };
  console.log = patch(console.log.bind(console));
  console.warn = patch(console.warn.bind(console));
  console.error = patch(console.error.bind(console));
  return { enabled: true, file: target };
}

module.exports = { init, MAX_BYTES };
