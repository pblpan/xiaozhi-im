const router = require('express').Router();
const { verifyToken } = require('../auth');
const { addFavorite, removeFavorite, listFavorites } = require('../chat');

function uidOf(req, res) {
  const c = verifyToken(req.headers.authorization?.replace('Bearer ', ''));
  if (!c) { res.status(401).json({ error: 'unauthorized' }); return null; }
  return c.uid;
}

// 我的收藏列表（带所在会话 / 发送者信息，可直接跳转）
router.get('/', (req, res) => {
  const uid = uidOf(req, res); if (uid === null) return;
  const { limit, offset } = req.query || {};
  res.json(listFavorites({ userId: uid, limit, offset }));
});

// 收藏一条消息（body: { messageId }）
router.post('/', (req, res) => {
  const uid = uidOf(req, res); if (uid === null) return;
  try {
    res.json(addFavorite({ userId: uid, messageId: Number((req.body || {}).messageId) }));
  } catch (e) { res.status(400).json({ error: e.message }); }
});

// 取消收藏
router.delete('/:messageId', (req, res) => {
  const uid = uidOf(req, res); if (uid === null) return;
  res.json(removeFavorite({ userId: uid, messageId: Number(req.params.messageId) }));
});

module.exports = router;
