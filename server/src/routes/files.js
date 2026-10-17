const router = require('express').Router();
const db = require('../db');
const { verifyToken } = require('../auth');
const multer = require('multer');
const path = require('path');
const fs = require('fs');
const config = require('../config');

function uidOf(req, res) {
  const c = verifyToken(req.headers.authorization?.replace('Bearer ', ''));
  if (!c) { res.status(401).json({ error: 'unauthorized' }); return null; }
  return c.uid;
}

/**
 * 上传文件名乱码修复。
 * 某些情况下 busboy 把 UTF-8 文件名按 Latin-1 解出，中文会变成一串高位字节（0x80–0xFF）。
 * 用 Latin-1 → UTF-8 还原；若原串本来就是正常 Unicode（无高位字节，含正确中文），原样返回，
 * 避免误伤西欧文件名。
 */
function fixFilename(raw) {
  if (!raw) return '';
  if (!/[\u0080-\u00ff]/.test(raw)) return raw;            // 已是正常文字，无需处理
  const restored = Buffer.from(raw, 'latin1').toString('utf8');
  if (!/[\u0080-\u00ff]/.test(restored)) return restored;  // 还原成功（解出正常文字）
  return raw;                                              // 还原失败，保留原串
}

/**
 * 上传文件落盘名：**保留原始文件名**（龙哥 2026-10-17：
 * "上传的文件名还用原文件名，不要重命名"—— 升级包下载地址变成
 * /files/小智IM_0.28.7.apk 一眼能认，时间戳+随机数没法看也没法念）。
 *
 * 保留名 ≠ 放任，四道护栏：
 *   ① 只取 basename（先统一反斜杠再切）—— `../` 穿越、IE 老传统的
 *      `C:\folder\file.apk` 全路径上传，都在这拦掉；
 *   ② 砍控制符与前导点（防隐藏文件）、去首尾空白、去尾部的点/空格
 *      （Windows 落盘会坏）、限长（stem 80 + 扩展名 12）；
 *   ③ 重名不覆盖：已存在就补 ` (2)` ` (3)`…… 直接覆盖会让同一个 URL
 *      前后内容不同 —— 已发出去的聊天文件、已配好的升级包地址，
 *      会悄悄指向另一个文件，这种事故连报错都没有；
 *   ④ 循环有上限（1000），兜底回时间戳后缀，绝不会死循环卡住上传。
 */
function safeDiskName(raw) {
  let name = fixFilename(String(raw || ''));
  name = (name.split(/[\\/]/).pop() || '');
  name = name.replace(/[\u0000-\u001f\u007f]/g, '').replace(/^\.+/, '').trim();
  let ext = path.extname(name).slice(0, 12);
  // `尾点.` 的 extname 就是 '.'（整个"扩展名"只是一个点）—— 这种当没有扩展名，
  // 否则 stem+ext 拼出来还是带尾点，Windows 落盘直接坏
  if (/^\.+$/.test(ext)) ext = '';
  let stem = (path.basename(name, ext) || 'file').slice(0, 80).replace(/[. ]+$/, '');
  if (!stem) stem = 'file';
  let disk = (stem + ext).replace(/[. ]+$/, '') || 'file';
  for (let i = 2; fs.existsSync(path.join(config.FILES_DIR, disk)); i++) {
    if (i > 1000) { disk = `${stem}-${Date.now()}${ext}`; break; }
    disk = `${stem} (${i})${ext}`;
  }
  return disk;
}

/**
 * 上传中间件错误兜底：busboy/multer 的错（文件名带控制符、超过大小上限、
 * multipart 本身畸形）默认会变成 500 HTML 错误页 —— 上传方（管理台/客户端）
 * 看到的是"操作失败"四个字，没法区分"文件太大"和"服务端坏了"。
 * 统一转成 400 + 可读原因。
 */
function guardUpload(mw) {
  return (req, res, next) => mw(req, res, (err) => {
    if (!err) return next();
    const tooBig = err.code === 'LIMIT_FILE_SIZE';
    const limitMb = tooBig && mw === pkgUpload ? PKG_LIMIT_MB : config.MAX_FILE_MB;
    res.status(400).json({
      error: tooBig ? `文件超过 ${limitMb}MB 上限` : '上传失败：' + (err.message || '文件解析错误'),
    });
  });
}

const storage = multer.diskStorage({
  destination: (req, file, cb) => cb(null, config.FILES_DIR),
  filename: (req, file, cb) => cb(null, safeDiskName(file.originalname)),
});
const upload = multer({ storage, limits: { fileSize: config.MAX_FILE_MB * 1024 * 1024 } });

router.post('/upload', guardUpload(upload.single('file')), (req, res) => {
  const uid = uidOf(req, res); if (uid === null) return;
  if (!req.file) return res.status(400).json({ error: 'no file' });
  const name = fixFilename(req.file.originalname);
  const info = db.prepare('INSERT INTO files (owner_id,name,mime,size,path,created_at) VALUES (?,?,?,?,?,?)')
    .run(uid, name, req.file.mimetype, req.file.size, req.file.filename, Date.now());
  res.json({
    id: info.lastInsertRowid,
    name,
    url: `/files/${req.file.filename}`,
    mime: req.file.mimetype,
    size: req.file.size,
  });
});

router.get('/:id/meta', (req, res) => {
  const uid = uidOf(req, res); if (uid === null) return;
  const f = db.prepare('SELECT id,name,mime,size,created_at FROM files WHERE id=?').get(Number(req.params.id));
  if (!f) return res.status(404).json({ error: 'not found' });
  res.json(f);
});

// 安装包上传（APK/EXE 等体积远超普通文件 50MB 上限）。
// 单独开一条高上限通道，不影响消息/头像/培训课件的既有 50MB 限制。
const PKG_LIMIT_MB = Number(process.env.MAX_PACKAGE_MB || 300);
const pkgUpload = multer({
  storage,
  limits: { fileSize: PKG_LIMIT_MB * 1024 * 1024 },
});

router.post('/upload-package', guardUpload(pkgUpload.single('file')), (req, res) => {
  const uid = uidOf(req, res); if (uid === null) return;
  if (!req.file) return res.status(400).json({ error: 'no file' });
  const name = fixFilename(req.file.originalname);
  const info = db.prepare('INSERT INTO files (owner_id,name,mime,size,path,created_at) VALUES (?,?,?,?,?,?)')
    .run(uid, name, req.file.mimetype, req.file.size, req.file.filename, Date.now());
  res.json({
    id: info.lastInsertRowid,
    name,
    url: `/files/${req.file.filename}`,
    mime: req.file.mimetype,
    size: req.file.size,
  });
});

module.exports = router;
