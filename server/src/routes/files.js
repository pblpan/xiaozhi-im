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

const storage = multer.diskStorage({
  destination: (req, file, cb) => cb(null, config.FILES_DIR),
  filename: (req, file, cb) => cb(null, `${Date.now()}-${Math.round(Math.random() * 1e9)}${path.extname(file.originalname)}`),
});
const upload = multer({ storage, limits: { fileSize: config.MAX_FILE_MB * 1024 * 1024 } });

router.post('/upload', upload.single('file'), (req, res) => {
  const uid = uidOf(req, res); if (uid === null) return;
  if (!req.file) return res.status(400).json({ error: 'no file' });
  const info = db.prepare('INSERT INTO files (owner_id,name,mime,size,path,created_at) VALUES (?,?,?,?,?,?)')
    .run(uid, req.file.originalname, req.file.mimetype, req.file.size, req.file.filename, Date.now());
  res.json({
    id: info.lastInsertRowid,
    name: req.file.originalname,
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
