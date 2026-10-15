// 通话运行参数下发
//
// 目前只有一件东西：ICE 服务器列表（STUN / TURN）。
//
// 全部内容就是中继地址与当场签发的临时凭据，不含任何用户数据，所以不强制鉴权 ——
// 客户端在"点下通话按钮就要建连"这个路径上拉配置，少一次鉴权失败就少一次
// 打不通。TURN 凭据泄露的代价只是有人白嫖中继流量，可接受。

const express = require('express');
const config = require('../config');
const settings = require('../settings');

const router = express.Router();

const hasTurn = (list) =>
  list.some((s) => {
    const urls = Array.isArray(s.urls) ? s.urls : [s.urls];
    return urls.some((u) => {
      const x = String(u);
      return x.startsWith('turn:') || x.startsWith('turns:');
    });
  });

/** 把任意输入收敛成 flutter_webrtc 认得的策略值（all / relay）。 */
function normalizeIcePolicy(v) {
  const s = String(v == null ? '' : v).trim().toLowerCase();
  return s === 'relay' ? 'relay' : 'all';
}

/**
 * GET /api/call/ice
 * 客户端在 createPeerConnection 之前拉一次，缓存 5 分钟。
 *
 * 注意是 async：配了 Cloudflare TURN 时这里要现签凭据（内部有 50 分钟缓存，
 * 不会把 CF 的接口打爆）。签发失败不影响 STUN 下发，只是少一条中继。
 *
 * UU-b：额外下发 iceTransportPolicy（all / relay），由服务端决定打洞策略，
 * 客户端不再硬编码 —— 管理台或环境变量即可切换"强制走中继"。
 */
router.get('/ice', async (req, res) => {
  let list = [];
  try {
    list = await config.iceServers();
  } catch (e) {
    // 兜底：至少把 STUN 发出去，别让客户端一个候选都拿不到
    list = config.ICE_STUN.map((urls) => ({ urls }));
  }
  const info = config.turnInfo();

  // 策略优先级：管理台设置 > 环境变量 > 默认 all
  const dbPolicy = settings.get('webrtcIceTransportPolicy');
  const policy = normalizeIcePolicy(
    dbPolicy && dbPolicy !== 'all'
      ? dbPolicy
      : (process.env.WEBRTC_ICE_TRANSPORT_POLICY || 'all'),
  );

  res.set('Cache-Control', 'public, max-age=300');
  res.json({
    iceServers: list,
    iceTransportPolicy: policy,
    ttlSeconds: 300,
    // 只暴露"有没有中继"，方便客户端/排障时区分
    // "打不通是因为没中继" 还是 "配了中继还是打不通"
    turnConfigured: hasTurn(list),
    turnSources: info.sources,
    cloudflareError: info.cloudflareError || undefined,
    ts: Date.now(),
  });
});

module.exports = router;
