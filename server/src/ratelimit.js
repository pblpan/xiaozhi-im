/**
 * 通用限流器（内存滑动窗口）
 *
 * ─────────────────────────────────────────────────────────────────
 * 为什么要有这个模块
 *   限流逻辑此前在 routes/setup.js 里内联实现。登录接口同样需要它，
 *   而且登录比"设置初始密码"更该限流：
 *     · 登录是**可反复尝试**的（爆破弱口令），而设密码只做一次；
 *     · 登录的密码校验走 `crypto.scryptSync` —— **同步且 CPU 密集**，
 *       每次校验约几十到上百毫秒。不限流的话，几十个并发请求就能把
 *       Node 的事件循环整段占死（scryptSync 不让出事件循环），
 *       表现是**所有接口一起卡住**，连健康检查都响应不了。
 *       也就是说登录接口既是爆破面，也是 DoS 面。
 *   所以抽出来共用一份，而不是把 setup.js 那段复制过去。
 *
 * ─────────────────────────────────────────────────────────────────
 * 特性
 *   · 滑动窗口（不是固定窗口）：固定窗口在边界处允许 2 倍突发，
 *     滑动窗口按真实时间戳计数，限得更准。
 *   · 自动清理：Map 里的键会随时间失效，但键本身不会自己消失。
 *     定期扫一遍删掉过期条目，防止长期运行后被大量 IP 撑爆内存
 *     （服务端可能常年不重启）。MAX_KEYS 是兜底上限。
 *   · failCount：给"账号维度"限流用。同一 IP 换账号刷不影响这个计数，
 *     而同一账号被多处爆破则会被单独锁住。
 *
 * ─────────────────────────────────────────────────────────────────
 * 【已知取舍，勿当成漏洞】
 *   · 状态在内存里，**多进程/多实例部署时各算各的**。当前部署是单容器单进程
 *     （飞牛 Docker），成立。以后要横向扩容，这块得换 Redis。
 *   · 信任 X-Forwarded-For 是**刻意**的：小智IM 常挂在 Cloudflare Tunnel / frp 后面，
 *     那时 req.socket.remoteAddress 是隧道进程自己（永远 127.0.0.1），
 *     不信任 XFF 会把所有真人算成同一个人，一个人的连续失败就锁死所有人。
 *     代价是能伪造 XFF 绕过 IP 维度 —— 但账号维度还在，且这里防的是脚本刷，
 *     不是精确审计。
 */

/** 取来源 IP。理由见上方说明。 */
function ipOf(req) {
  const xff = req.headers['x-forwarded-for'];
  const first = String(xff || '').split(',')[0].trim();
  return first || req.socket.remoteAddress || '?';
}

class RateLimiter {
  /**
   * @param {object} opt
   * @param {number} opt.windowMs  窗口长度（毫秒）
   * @param {number} opt.max       窗口内允许的最大次数
   * @param {number} [opt.maxKeys] 键数量上限，超过则淘汰过期条目（防内存涨）
   */
  constructor({ windowMs, max, maxKeys = 512 }) {
    this.windowMs = windowMs;
    this.max = max;
    this.maxKeys = maxKeys;
    this.hits = new Map();       // key -> number[]（时间戳升序）
    this.failCount = new Map();  // key -> 连续失败次数（成功要显式清零）
  }

  /** 记一次尝试，返回是否仍然放行 */
  allow(key) {
    const now = Date.now();
    const list = (this.hits.get(key) || []).filter((t) => now - t < this.windowMs);
    list.push(now);
    this.hits.set(key, list);
    if (this.hits.size > this.maxKeys) this.sweep(now);
    return list.length <= this.max;
  }

  /** 只查不记（用于"登录失败后才计数"的场景） */
  isBlocked(key) {
    const now = Date.now();
    const list = (this.hits.get(key) || []).filter((t) => now - t < this.windowMs);
    return list.length > this.max;
  }

  /** 成功一次：把这个键的失败计数清零 */
  clearFails(key) {
    this.failCount.delete(key);
  }

  /** 失败一次，返回累计失败次数 */
  fail(key) {
    const n = (this.failCount.get(key) || 0) + 1;
    this.failCount.set(key, n);
    return n;
  }

  /** 连续失败次数（没有记录返回 0） */
  failsOf(key) {
    return this.failCount.get(key) || 0;
  }

  /** 删掉完全过期的键，防 Map 无限增长 */
  sweep(now = Date.now()) {
    for (const [k, list] of this.hits) {
      if (!list.some((t) => now - t < this.windowMs)) this.hits.delete(k);
    }
    for (const [k, _] of this.failCount) {
      if (!(this.hits.get(k))) this.failCount.delete(k);
    }
  }
}

module.exports = { RateLimiter, ipOf };
