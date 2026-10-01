const router = require('express').Router();
const db = require('../db');
const { verifyToken } = require('../auth');
const multer = require('multer');
const path = require('path');
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

const storage = multer.diskStorage({
  destination: (req, file, cb) => cb(null, config.FILES_DIR),
  filename: (req, file, cb) => cb(null, `${Date.now()}-${Math.round(Math.random() * 1e9)}${path.extname(file.originalname)}`),
});
const upload = multer({ storage, limits: { fileSize: config.MAX_FILE_MB * 1024 * 1024 } });

router.post('/upload', upload.single('file'), (req, res) => {
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

module.exports = router;
