/// 错误文案中文化（龙哥 2026-10-14 要求：界面上不许出现英文错误）。
///
/// ── 为什么要在客户端做这层映射 ──────────────────────────────
/// 服务端几十个路由文件里散着 `{ error: 'invalid credentials' }` 这类英文错误码，
/// 逐个改服务端文件既慢又会漏（而且旧服务端 + 新客户端混用时又冒出来）。
/// 客户端 `_handle` 是所有 REST 错误的唯一汇合口，在这里做一次映射，
/// 新老服务端、新老版本混用都一律中文化。
///
/// ── 匹配规则 ────────────────────────────────────────────────
/// 1. 只对**纯英文错误码**（ASCII、无空格或少量空格的小写短语）做映射；
/// 2. 服务端已经返回中文的原样放行（大部分业务错误早就是中文 throw）；
/// 3. 未命中的英文错误**保留原文**——服务端可能新增了错误码，
///    保留原文比瞎翻更有利于排障；新码稳定后再补进表。
library;

/// 把服务端/系统抛出的错误文案翻成中文。无法识别时原样返回。
String friendlyError(String raw) {
  var s = raw.trim();
  // 剥掉常见包装前缀（Exception: 、Error: 、Bad state: 等）
  for (final p in const ['Exception: ', 'Error: ', 'Bad state: ']) {
    if (s.startsWith(p)) s = s.substring(p.length).trim();
  }
  if (s.isEmpty) return '操作失败，请重试';

  final hit = _map[s.toLowerCase()];
  if (hit != null) return hit;

  // 已经含中文的文案（服务端业务错误大多是中文 throw）原样放行
  if (_hasCjk(s)) return s;

  // 英文但不在表里：保留原文，附一句中文说明，别让用户对着天书发呆
  return '$s（服务端返回，可尝试重试或联系管理员）';
}

/// 纯英文系统异常（HandshakeException / SocketException 等）的中文化。
/// 这些不走 _handle，是 http 包直接抛的，message 里全是英文。
String friendlySystemError(Object e) {
  final s = e.toString().toLowerCase();
  if (s.contains('handshake') || s.contains('certificate')) {
    return '安全连接失败：服务器证书不被信任（若为内网地址，请改用 http://）';
  }
  if (s.contains('connection refused')) return '服务器拒绝了连接（服务端可能没启动）';
  if (s.contains('connection reset')) return '连接被重置（网络波动或服务端重启）';
  if (s.contains('network is unreachable') || s.contains('no route to host')) {
    return '网络不可达（请检查手机/电脑是否连上网）';
  }
  if (s.contains('timed out') || s.contains('timeout')) return '连接超时，请重试';
  if (s.contains('socket') || s.contains('failed host lookup')) {
    return '连不上服务器（地址可能不对或服务端没开）';
  }
  return '网络异常：${e.toString()}';
}

bool _hasCjk(String s) {
  for (final r in s.runes) {
    if (r >= 0x4E00 && r <= 0x9FFF) return true; // CJK 统一表意
    if (r >= 0x3000 && r <= 0x303F) return true; // CJK 标点
    if (r >= 0xFF00 && r <= 0xFFEF) return true; // 全角
  }
  return false;
}

/// 服务端英文错误码 → 中文。键统一小写。
///
/// 来源：`grep "error: '[a-z ]+'" server/src` 全量扫描（2026-10-14）。
/// 新增路由时如果又冒出英文错误，补到这里即可。
const Map<String, String> _map = {
  // ── 登录 / 鉴权 ──
  'invalid credentials': '账号或密码错误',
  'unauthorized': '登录状态已失效，请重新登录',
  'forbidden': '没有操作权限',
  'invalid token': '登录凭证无效，请重新登录',
  'token revoked': '登录状态已失效，请重新登录',
  'token expired': '登录状态已过期，请重新登录',
  'missing credentials': '未提供登录凭证，请重新登录',
  'token owner not found': '账号不存在，请重新登录',
  'username too short': '账号至少需要 3 个字符',
  'username taken': '该账号已被注册',
  'password too short': '密码至少 6 位',
  'wrong password': '原密码不正确',
  // ── 资源不存在 ──
  'not found': '内容不存在或已被删除',
  'user not found': '用户不存在',
  'group not found': '群组不存在或已解散',
  'message not found': '消息不存在或已撤回',
  'file not found': '文件不存在或已删除',
  'conversation not found': '会话不存在',
  'delivery not found': '投递记录不存在',
  'hook not found': '接口不存在',
  // ── 群 / 成员 ──
  'not a group member': '你不是该群成员',
  'already a member': '已经在这个群里了',
  'name required': '名称不能为空',
  'cannot delete self': '不能删除自己',
  'owner cannot leave': '群主不能退群，请先转让群主',
  // ── 文件 / 上传 ──
  'no file': '没有选择文件',
  'file too large': '文件太大了',
  'unsupported type': '不支持的文件类型',
  // ── 限流 / 通用 ──
  'too many requests': '操作太频繁，请稍后再试',
  'bad request': '请求格式不正确',
  'internal error': '服务器内部出错，请稍后再试',
  'method not allowed': '不支持的请求方式',
};
