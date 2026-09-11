// 通话运行参数下发
//
// 目前只有一件东西：ICE 服务器列表（STUN / TURN）。
//
// 全部内容就是几个公开的中继地址，不含任何用户数据，所以不强制鉴权 ——
// 客户端在"点下通话按钮就要建连"这个路径上拉配置，少一次鉴权失败就少一次
// 打不通。TURN 凭据泄露的代价只是有人白嫖中继流量，可接受。

const express = require('express');
const config = require('../config');

const router = express.Router();

/**
 * GET /api/call/ice
 * 客户端在 createPeerConnection 之前拉一次，缓存 5 分钟。
 */
router.get('/ice', (req, res) => {
  res.set('Cache-Control', 'public, max-age=300');
  res.json({
    iceServers: config.iceServers(),
    ttlSeconds: 300,
    // 只暴露"有没有配 TURN"，方便客户端/排障时区分
    // "打不通是因为没中继" 还是 "配了中继还是打不通"
    turnConfigured: config.TURN_URLS.length > 0,
    ts: Date.now(),
  });
});

module.exports = router;
