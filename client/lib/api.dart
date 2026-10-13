import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'core/app_version.dart';
import 'core/config.dart';
import 'core/remote_models.dart';
import 'core/session_manager.dart';
import 'core/storage.dart';

/// REST 异常（带 HTTP 状态码）。
/// 上层据此区分：401（token 失效，清 token 跳登录）vs 网络异常（连接/超时/5xx）。
class ApiException implements Exception {
  /// HTTP 状态码；null 表示底层网络/连接错误（SocketException / TimeoutException）
  final int? status;
  final String message;

  /// 服务端业务码（回包 `{error, code}` 里的 `code`），如盘点上传的
  /// `already_uploaded` / `not_in_diff_set` / `zone_not_found`。
  ///
  /// 🔴 为什么不靠状态码：三个业务分支全是 409/400，只认状态码就只能去
  ///    匹配英文/中文文案 —— 文案一改，判定静默失效，表现是"重传变成了报错"。
  final String? code;

  /// 回包原文（仅错误分支可能有）。用于取 `barcodes` 这类附加清单。
  final Map<String, dynamic>? data;

  const ApiException(this.message, {this.status, this.code, this.data});

  bool get isUnauthorized => status == 401;
  bool get isForbidden => status == 403;
  /// 网络层失败 / 服务端故障（5xx）—— 上层应引导切服务器或重试，不要当作账号问题
  bool get isNetwork => status == null || status! >= 500;
  /// 业务错误（4xx 非 401/403）：账号不对、参数错、被踢等，给原文案
  bool get isBiz => status != null && status! >= 400 && status! < 500;

  @override
  String toString() => message;
}

/// REST API 封装（与服务端 SPEC 一致）
class ImApi {
  static final ImApi _i = ImApi._();
  factory ImApi() => _i;
  ImApi._();

  String? _token;

  /// 写 token：同时更新激活企业档案（多企业各自账号），
  /// 这样切换企业后每个档案都带着自己的登录态。
  void setToken(String t) {
    _token = t;
    final id = SessionManager.instance.activeId;
    if (id != null) {
      // 不 await：落盘失败不影响本次会话；失败也只在下次启动体现
      SessionManager.instance.updateToken(id, t);
    }
  }

  bool get hasToken {
    final a = SessionManager.instance.active;
    if (a?.token != null && a!.token!.isNotEmpty) return true;
    return _token != null && _token!.isNotEmpty;
  }

  /// App 冷启动时恢复登录态：优先激活档案自带的 token，回退到旧 Storage 镜像。
  Future<void> restore() async {
    final a = SessionManager.instance.active;
    _token = a?.token ?? await Storage.getToken();
  }

  void clearToken() {
    _token = null;
    final id = SessionManager.instance.activeId;
    if (id != null) SessionManager.instance.updateToken(id, '');
    Storage.clear();
  }

  /// 鉴权头：**始终取「当前激活企业」的 token**。
  ///
  /// 🔴 多企业（2026-10-01）关键修正：以前 `_token` 是单租户时代的全局量，切换
  /// 企业后它不会跟着变，于是 REST 还拿旧企业的 token 去打新服务器 → 一片 401。
  /// 现在 token 的真源是 [SessionManager.active]（每个档案各自存一份），这里直接读它，
  /// 切换企业后所有 REST 自动命中新服务器的登录态，无需手动同步 `_token`。
  Map<String, String> get _h {
    final t = SessionManager.instance.active?.token ?? _token;
    return {
      'Content-Type': 'application/json',
      if (t != null && t.isNotEmpty) 'Authorization': 'Bearer $t',
    };
  }

  /// 不带鉴权头的 POST（登录/注册专用）。
  /// 多企业"添加企业"登录新服务器时，绝不能把**当前激活企业**的 token 捎带给它。
  Future<dynamic> _postNoAuth(String p, Map<String, dynamic> b) async =>
      _handle(await _send(() => http.post(Uri.parse('${Config.baseUrl}/api$p'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode(b))));

  /// 包一层 http 调用，统一把底层网络异常包装成 ApiException(status: null)
  Future<http.Response> _send(Future<http.Response> Function() fn) async {
    try {
      return await fn().timeout(const Duration(seconds: 15));
    } on SocketException catch (e) {
      throw ApiException('无法连接服务器（${e.osError?.message ?? e.message}）');
    } on TimeoutException {
      throw const ApiException('连接超时，请检查网络或切换服务器');
    } on http.ClientException catch (e) {
      throw ApiException('网络异常：${e.message}');
    } on HandshakeException catch (e) {
      throw ApiException('TLS 握手失败：${e.message}');
    } on HttpException catch (e) {
      throw ApiException('HTTP 异常：${e.message}');
    } on FormatException catch (e) {
      throw ApiException('响应解析失败：${e.message}');
    }
  }

  dynamic _handle(http.Response r) {
    if (r.statusCode >= 200 && r.statusCode < 300) {
      if (r.body.isEmpty) return null;
      try {
        return jsonDecode(r.body);
      } catch (_) {
        return null;
      }
    }
    String msg;
    String? code;
    Map<String, dynamic>? data;
    try {
      final body = jsonDecode(r.body);
      if (body is Map) {
        msg = body['error']?.toString() ?? '请求失败';
        code = body['code']?.toString();
        data = Map<String, dynamic>.from(body);
      } else {
        msg = '请求失败';
      }
    } catch (_) {
      msg = '请求失败 (HTTP ${r.statusCode})';
    }
    throw ApiException(msg, status: r.statusCode, code: code, data: data);
  }

  Future<dynamic> _post(String p, Map<String, dynamic> b) async =>
      _handle(await _send(() => http.post(Uri.parse('${Config.baseUrl}/api$p'),
          headers: _h, body: jsonEncode(b))));

  Future<dynamic> _patch(String p, Map<String, dynamic> b) async =>
      _handle(await _send(() => http.patch(Uri.parse('${Config.baseUrl}/api$p'),
          headers: _h, body: jsonEncode(b))));

  Future<dynamic> _put(String p, Map<String, dynamic> b) async =>
      _handle(await _send(() => http.put(Uri.parse('${Config.baseUrl}/api$p'),
          headers: _h, body: jsonEncode(b))));

  Future<dynamic> _get(String p) async =>
      _handle(await _send(
          () => http.get(Uri.parse('${Config.baseUrl}/api$p'), headers: _h)));

  Future<dynamic> _delete(String p) async =>
      _handle(await _send(() =>
          http.delete(Uri.parse('${Config.baseUrl}/api$p'), headers: _h)));

  /// 测试某个服务器地址是否可用（GET /api/health，不需要登录）。
  /// 返回提示文案用的结果 map；不通则抛 ApiException（status=null 表示连接失败）。
  static Future<Map<String, dynamic>> testServer(String url) async {
    final u = Config.normalize(url);
    if (u.isEmpty) throw const ApiException('请填写服务器地址');
    final uri = Uri.tryParse('$u/api/health');
    if (uri == null) throw const ApiException('地址格式不正确');
    try {
      final r = await http.get(uri).timeout(const Duration(seconds: 6));
      if (r.statusCode != 200) {
        throw ApiException('HTTP ${r.statusCode}', status: r.statusCode);
      }
      final b = jsonDecode(r.body);
      if (b is! Map) throw const ApiException('返回格式不正确');
      return {'ok': b['ok'] == true, 'ts': b['ts']};
    } on TimeoutException {
      throw const ApiException('连接超时');
    } on SocketException catch (e) {
      throw ApiException('无法连接：${e.osError?.message ?? e.message}');
    }
  }

  // ---- 认证 ----
  /// 登录：带 setToken（写激活档案 + 全局）。普通登录/注册走这条。
  Future<Map<String, dynamic>> login(String u, String p) async {
    final d = await _postNoAuth('/auth/login', {'username': u, 'password': p});
    setToken(d['token'] as String);
    return d;
  }

  Future<Map<String, dynamic>> register(String u, String p, String n) async {
    final d = await _postNoAuth('/auth/register',
        {'username': u, 'password': p, 'nickname': n});
    setToken(d['token'] as String);
    return d;
  }

  /// 不写任何 token 的登录/注册（多企业"添加企业"专用）：
  /// 在目标服务器上拿回 token 后，由调用方落成独立档案，**绝不污染当前激活企业**。
  Future<Map<String, dynamic>> loginRaw(String u, String p) async =>
      await _postNoAuth('/auth/login', {'username': u, 'password': p});

  Future<Map<String, dynamic>> registerRaw(String u, String p, String n) async =>
      await _postNoAuth('/auth/register',
          {'username': u, 'password': p, 'nickname': n});

  Future<Map<String, dynamic>> me() async => await _get('/auth/me');

  /// 修改密码（需登录）。旧密码错 → 401；新密码 <6 位 / 与旧密码相同 → 400。
  /// 注意：JWT 无状态，改密后当前会话 token 仍有效（不会被自己踢下线）。
  Future<void> changePassword(String oldP, String newP) async =>
      await _post('/auth/password', {'oldPassword': oldP, 'newPassword': newP});

  // ---- 组织机构（工作模式）----
  /// 我的组织：{ org: {...}|null, members: [...] }。
  /// org=null 表示「我没在组织里 / 本服务器还没建组织」。
  Future<Map<String, dynamic>> myOrg() async => await _get('/orgs/my');

  /// 创建组织（仅管理员；服务端要求工作模式）。
  Future<Map<String, dynamic>> createOrg(String name) async =>
      await _post('/orgs', {'name': name});

  /// 录入员工：工号=登录账号、初始密码=工号，自动与同事互为好友。
  Future<Map<String, dynamic>> addOrgMember(int orgId, String employeeNo, String nickname) async =>
      await _post('/orgs/$orgId/members', {'employeeNo': employeeNo, 'nickname': nickname});

  Future<void> removeOrgMember(int orgId, int uid) async =>
      await _delete('/orgs/$orgId/members/$uid');

  // ---- 用户 / 好友 ----
  Future<List<dynamic>> search(String q) async =>
      await _get('/users/search?q=${Uri.encodeComponent(q)}');

  /// 查看某人的公开资料（个人信息面板 / 好友资料卡都走这里）
  Future<Map<String, dynamic>> userProfile(int id) async => await _get('/users/$id');

  /// 更新我的资料。
  /// 只传要改的字段即可 —— 服务端语义是「字段没传 = 不改，传空串 = 清空」，
  /// 所以想清掉个性签名必须显式传 `''`，省略字段等于不动它。
  Future<Map<String, dynamic>> updateProfile(Map<String, dynamic> patch) async =>
      await _put('/auth/profile', patch);

  /// 发起好友申请。[message] 为认证附言（可选，上限 100 字）。
  Future<Map<String, dynamic>> friendRequest(int id, {String message = ''}) async =>
      await _post('/friends/request', {'friendId': id, 'message': message});

  Future<void> acceptFriend(int id) async =>
      await _post('/friends/accept', {'friendId': id});

  Future<void> rejectFriend(int id) async =>
      await _post('/friends/reject', {'friendId': id});

  /// 好友列表 + 待处理申请（含认证附言）：{ friends: [...], pending: [...] }
  /// friends 里每项带 remark（我给对方起的备注，可为 null）
  Future<Map<String, dynamic>> friends() async => await _get('/friends');

  /// 设置 / 清空好友备注。传空串即清除，之后显示退回对方昵称。
  /// 备注只有自己可见，对方那边不会变。
  Future<Map<String, dynamic>> setFriendRemark(int friendId, String remark) async =>
      await _put('/friends/$friendId/remark', {'remark': remark});

  // ---- 好友申请附言模板（人手一份，首次读取服务端会播种 3 条）----
  Future<List<dynamic>> friendTemplates() async => await _get('/friends/templates');

  Future<Map<String, dynamic>> addFriendTemplate(String content) async =>
      await _post('/friends/templates', {'content': content});

  Future<Map<String, dynamic>> updateFriendTemplate(int id, String content) async =>
      await _put('/friends/templates/$id', {'content': content});

  Future<void> deleteFriendTemplate(int id) async =>
      await _delete('/friends/templates/$id');

  // ---- 会话 / 消息 ----
  Future<Map<String, dynamic>> dm(int userId) async =>
      await _get('/conversations/dm/$userId');

  Future<List<dynamic>> conversations() async => await _get('/conversations');

  /// 「文件助手」会话：获取（没有就新建）。返回 { conversationId }
  Future<Map<String, dynamic>> fileHelper() async =>
      await _get('/conversations/filehelper');

  /// 智能助手：问一个使用问题（#314）。
  /// 返回 { answer, source: 'llm'|'kb'|'fallback', related?: [...], note? }。
  /// aiFailFast=true 时 LLM 故障直接抛错而不是降级（暂未用，留作"重试"场景）。
  Future<dynamic> askAssistant(String question) async =>
      await _post('/assistant/ask', {'question': question});

  /// 会话历史 + 已读状态：
  /// { messages: [...], members: [...], peerLastReadId, minOtherReadId, recallWindowMs }
  Future<Map<String, dynamic>> messages(int cid) async =>
      await _get('/conversations/$cid/messages');

  /// 发送消息。mentions 传被 @ 的用户 id 列表，-1 表示 @所有人。
  Future<Map<String, dynamic>> sendMessage(int cid, String kind, String content,
      [int? fileId, List<int>? mentions]) async {
    final b = <String, dynamic>{'kind': kind, 'content': content};
    if (fileId != null) b['fileId'] = fileId;
    if (mentions != null && mentions.isNotEmpty) b['mentions'] = mentions;
    return await _post('/conversations/$cid/messages', b);
  }

  /// 转发消息到若干会话（返回 { count, items }）
  Future<Map<String, dynamic>> forwardMessage(
          int messageId, List<int> conversationIds) async =>
      await _post('/conversations/forward',
          {'messageId': messageId, 'conversationIds': conversationIds});

  /// 置顶 / 取消置顶（同一 messageId 再调一次即取消）
  /// 返回 { conversationId, pinnedMessageId }
  Future<Map<String, dynamic>> pinMessage(int cid, int messageId) async =>
      await _post('/conversations/$cid/pin', {'messageId': messageId});

  /// 免打扰开关
  Future<Map<String, dynamic>> muteConversation(int cid, bool muted) async =>
      await _post('/conversations/$cid/mute', {'muted': muted});

  // ---- 收藏 ----
  /// 我的收藏列表：{ items: [...], total }
  Future<Map<String, dynamic>> favorites({int limit = 100, int offset = 0}) async =>
      await _get('/favorites?limit=$limit&offset=$offset');

  Future<Map<String, dynamic>> addFavorite(int messageId) async =>
      await _post('/favorites', {'messageId': messageId});

  Future<Map<String, dynamic>> removeFavorite(int messageId) async =>
      await _delete('/favorites/$messageId');

  /// 撤回消息（仅本人、2 分钟内）
  Future<Map<String, dynamic>> recallMessage(int cid, int msgId) async =>
      await _post('/conversations/$cid/messages/$msgId/recall', const {});

  // 编辑已发消息的能力已下线（产品决策：已发出的消息只能撤回，不能修改）。
  // 服务端对应接口返回 410 Gone。这里不再提供方法，而不是留个空壳 ——
  // 留空壳的话，将来有人看到 API 还在就会顺手把右键菜单里的「编辑」接回来。

  /// 标记已读（不传 msgId = 读到该会话最新一条）
  Future<Map<String, dynamic>> markRead(int cid, [int? msgId]) async =>
      await _post('/conversations/$cid/read',
          msgId == null ? const {} : {'messageId': msgId});

  /// 已读回执：发消息的人（仅本人）查看某条消息"谁读了 / 谁没读"。
  /// 返回 { messageId, conversationId, conversationType, sender, kind, content,
  ///   createdAt, total, readCount, unreadCount, read:[...], unread:[...] }。
  Future<Map<String, dynamic>> messageReaders(int cid, int msgId) async =>
      await _get('/conversations/$cid/messages/$msgId/readers');

  /// 全局消息搜索（服务端只在「我参与的会话」里搜，已撤回/非文字不返回）
  /// 返回 { items: [...], total, keyword }
  Future<Map<String, dynamic>> searchMessages(String q,
      {int? conversationId, int limit = 50, int offset = 0}) async {
    final sb = StringBuffer('/conversations/search?q=${Uri.encodeComponent(q)}');
    if (conversationId != null) sb.write('&conversationId=$conversationId');
    sb.write('&limit=$limit&offset=$offset');
    return await _get(sb.toString());
  }

  // ---- 客户端配置中心（SPEC §6）----

  /// 上报本机已生效的配置版本（管理台"同步状态"数据来源）。失败由调用方吞掉。
  Future<void> reportConfigApplied(int configVersion, String deviceId) async {
    await _post('/client/report-applied',
        {'configVersion': configVersion, 'deviceId': deviceId});
  }

  /// 已登录拉取动态模块列表（服务端按角色/用户/版本过滤好，客户端只渲染）
  Future<List<dynamic>> clientModules() async =>
      await _get('/client/config?clientVersion=${Uri.encodeComponent(kAppVersion)}')
          .then((d) => (d is Map && d['modules'] is List) ? d['modules'] as List : <dynamic>[]);

  /// 打开模块时取最新定义（不吃冷启动缓存）
  Future<Map<String, dynamic>> clientModule(String id) async =>
      await _get('/client/modules/$id?clientVersion=${Uri.encodeComponent(kAppVersion)}');

  /// 提交动态表单。data 只放 schema 里声明过的字段。
  Future<Map<String, dynamic>> submitModule(String id, Map<String, dynamic> data) async =>
      await _post('/client/modules/$id/submit',
          {'data': data, 'clientVersion': kAppVersion});

  /// 调用受控转发接口 `/api/hooks/*`（SPEC §4.4）。
  /// 上游地址只能由管理台登记，客户端无法指定完整 URL —— 这是防 SSRF 的关键。
  ///
  /// 服务端（0.18.0 起）在 `/api/hooks/up/<名字>/<子路径>` 上实现了这条转发，
  /// 所以这里传的 path 形如 `/api/hooks/up/tiger/report/daily?day=2026-09-16`。
  ///
  /// 回包是**带 data 外壳**的：`{ ok, upstream, url, status, ms, truncated, data }`，
  /// 模块的 `dataPath` 因此写 `data.rows` / `data.items`（内置模板就是这么写的）。
  /// 别把它当"裸数据"直接用，否则表格永远是空的。
  Future<dynamic> hookCall(String path,
      {String method = 'GET', Map<String, dynamic>? body}) async {
    final p = path.startsWith('/api') ? path.substring(4) : path;
    if (!p.startsWith('/hooks/')) {
      throw const ApiException('非法接口路径（只允许 /api/hooks/ 前缀）');
    }
    if (method.toUpperCase() == 'POST') return _post(p, body ?? const {});
    return _get(p);
  }

  // ---- 商品档案（商档）----
  //
  // 商档现在存在自家服务端（/api/master）：管理台导入一次，所有手机拉同一份。
  // 不再依赖泰格上游桥接那台会关机、IP 会漂的机器 —— 它一断，盘点就没有账单数，
  // 初盘每一行都变成"账上无此商品"，差异集等于全部商品。

  /// 服务端商档总数与最后更新时间（先问这个，才知道要不要拉、拉多少）。
  Future<Map<String, dynamic>> masterCount() async => await _get('/master/count');

  /// 分页拉商档。12 万行一次拉会把手机内存打满、HTTP 也会超时。
  Future<Map<String, dynamic>> masterPage(int page, int pageSize) async =>
      await _get('/master/?page=$page&pageSize=$pageSize');

  // ---- 应用中心（工作台）----

  /// 工作台应用清单：内置应用（考勤打卡 / 我的申请 / 组织通讯录）+ 动态模块。
  /// 服务端已按当前用户的模式/组织/角色过滤好 —— 客户端不做可见性判断，
  /// 只是**认不认识的自己会忽略**（见 core/apps.dart），这样服务端上新应用
  /// 不需要先升级客户端。
  /// 工作台应用列表（内置应用 + 动态模块，服务端合并后下发）。
  ///
  /// ⚠️ **必须带上 clientVersion**：服务端要拿它过滤动态模块的 minClientVersion。
  /// 漏传会被当成"版本不合法"，凡是设了最低版本要求的模块**全部消失** ——
  /// 现象是"管理台明明发布了，客户端工作台里就是没有"。
  Future<Map<String, dynamic>> clientApps() async =>
      await _get('/client/apps?clientVersion=${Uri.encodeComponent(kAppVersion)}');

  // ---- 考勤（工作模式下随工作模式启用）----

  /// 今日考勤：班次、今日已打的卡、今日判定、本月汇总、待审批数。
  /// 未启用时返回 available=false + reason（不是错误），客户端据此显示说明页。
  Future<Map<String, dynamic>> attendanceToday() async => await _get('/attendance/today');

  /// 打卡。type = 'in' | 'out'；slot = 1 | 2（第几段）。
  ///
  /// 一天 4 次卡的班次（上班 / 下班 / 上班 / 下班）靠 slot 区分是哪一段：
  /// 同样是 'out'，slot=1 是第 1 段结束、slot=2 是收工，服务端按两张不同的卡
  /// 存（去重口径带 slot），只发 type 会把第 1 段那张覆盖掉。
  /// 2 次卡的班次只用 slot=1，传 2 会被服务端拒（400）。
  ///
  /// 定位三件套：lat/lng 坐标、accuracy 精度（米）、mock 是否模拟定位。
  /// 服务端据此做地理围栏 + 防伪校验：required 组命中异常（无定位/模拟定位/
  /// 精度过低/超出围栏）直接拒绝；optional 组不拒但会标进报表。
  ///
  /// **不传时间** —— 时刻一律由服务端决定，客户端改本机时间无效。
  Future<Map<String, dynamic>> attendanceClock(String type,
          {int slot = 1, double? lat, double? lng, double? accuracy, bool? mock,
           String? address, String? device}) async =>
      await _post('/attendance/clock', {
        'type': type,
        'slot': slot,
        if (lat != null) 'lat': lat,
        if (lng != null) 'lng': lng,
        if (accuracy != null) 'accuracy': accuracy,
        if (mock != null) 'mock': mock,
        if (address != null) 'address': address,
        if (device != null) 'device': device,
      });

  /// 我的月度考勤（month = 'YYYY-MM'，不传为当月）
  Future<Map<String, dynamic>> attendanceMy({String? month}) async =>
      await _get('/attendance/my${month != null ? '?month=$month' : ''}');

  /// 我的打卡流水（某天，含被更新掉的旧流水）
  Future<Map<String, dynamic>> attendanceRecords({String? day}) async =>
      await _get('/attendance/records${day != null ? '?day=$day' : ''}');

  /// 我的申请列表
  Future<Map<String, dynamic>> attendanceRequests({String? status}) async =>
      await _get('/attendance/requests${status != null ? '?status=$status' : ''}');

  /// 提交申请（请假 / 补卡 / 外出 / 加班）
  Future<Map<String, dynamic>> createAttendanceRequest(Map<String, dynamic> body) async =>
      await _post('/attendance/requests', body);

  /// 撤销待审批的申请
  Future<void> cancelAttendanceRequest(int id) async =>
      await _post('/attendance/requests/$id/cancel', const {});

  // ---- 管理端考勤（仅管理员；工作台「考勤记录」页用）----
  //
  // 与管理台 Web 用的是**同一批接口、同一份口径**：手机上看板和管理台上看板
  // 必须是同一个数字，否则"手机上显示正常、管理台显示缺卡"没人说得清。
  // 服务端 adminGuard 会校验 role=admin，非管理员调用拿 403 —— 客户端不自行判断
  // 自己是不是管理员（可见性一律由服务端算，见 core/apps.dart 的说明）。

  /// 今日（或指定日）打卡看板：stats 汇总 + items 逐人逐卡实况。
  /// 未打卡的人也在 items 里（这正是主管要看的），不会因为"没数据"而消失。
  Future<Map<String, dynamic>> adminAttOverview({String? day}) async =>
      await _get('/admin/attendance/overview${day != null ? '?day=$day' : ''}');

  /// 代员工补卡：直接写一条打卡记录（服务端标记来源为管理员）。
  /// [time] 为 'HH:MM'，[slot] 是第几段卡（2 次卡只有 1，4 次卡还有 2）——
  /// 只给 type 不给 slot，卡会补到错误的段上：看着补了、报表上那天依旧缺卡。
  Future<Map<String, dynamic>> adminAttAddRecord({
    required int userId,
    required String day,
    required String type,
    required int slot,
    required String time,
    String? note,
  }) async =>
      await _post('/admin/attendance/records', {
        'userId': userId,
        'day': day,
        'type': type,
        'slot': slot,
        'time': time,
        if (note != null && note.isNotEmpty) 'note': note,
      });

  /// 管理端申请列表（默认待审批）+ 各状态计数
  Future<Map<String, dynamic>> adminAttRequests({String status = 'pending'}) async =>
      await _get('/admin/attendance/requests?status=$status');

  /// 审批申请（approve=false 即驳回）。补卡通过后服务端会**自动补写打卡记录**。
  Future<Map<String, dynamic>> adminAttReview(int id,
          {bool approve = true, String? note}) async =>
      await _post('/admin/attendance/requests/$id/review', {
        'approve': approve,
        if (note != null && note.isNotEmpty) 'note': note,
      });

  /// 删除某条打卡流水（补错了要能撤）
  Future<void> adminAttDeleteRecord(int id) async =>
      await _delete('/admin/attendance/records/$id');

  // ---- 群组 ----
  Future<Map<String, dynamic>> createGroup(String name) async =>
      await _post('/groups', {'name': name});

  Future<void> addMember(int gid, int uid) async =>
      await _post('/groups/$gid/members', {'userId': uid});

  /// 群详情：{ group, members, my_role, is_owner, can_manage }
  Future<Map<String, dynamic>> groupDetail(int gid) async =>
      await _get('/groups/$gid');

  /// 改群名 / 群公告 / 全员禁言 / 加群验证（群主或管理员）
  Future<Map<String, dynamic>> updateGroup(int gid,
      {String? name, String? announcement, bool? mutedAll, String? joinMode}) async {
    final b = <String, dynamic>{};
    if (name != null) b['name'] = name;
    if (announcement != null) b['announcement'] = announcement;
    if (mutedAll != null) b['mutedAll'] = mutedAll;
    if (joinMode != null) b['joinMode'] = joinMode;
    return await _patch('/groups/$gid', b);
  }

  /// 设/撤管理员（role: admin|member）
  Future<Map<String, dynamic>> setMemberRole(int gid, int uid, String role) async =>
      await _patch('/groups/$gid/members/$uid', {'role': role});

  /// 禁言 / 解除禁言（muteMinutes=0 表示解除）
  Future<Map<String, dynamic>> muteMember(int gid, int uid, int muteMinutes) async =>
      await _patch('/groups/$gid/members/$uid', {'muteMinutes': muteMinutes});

  /// 转让群主
  Future<Map<String, dynamic>> transferOwner(int gid, int uid) async =>
      await _post('/groups/$gid/transfer', {'userId': uid});

  /// 踢人
  Future<Map<String, dynamic>> kickMember(int gid, int uid) async =>
      await _delete('/groups/$gid/members/$uid');

  /// 主动退群
  Future<Map<String, dynamic>> leaveGroup(int gid) async =>
      await _post('/groups/$gid/leave', const {});

  // ---- 群功能面板（2026-10-10）----
  //
  // 群文件/相册/视频三样是**从消息流聚合**出来的，不是单独的表：
  // 消息被撤回，它就从这三个列表里一起消失，不存在"群里还留着一份"的脏数据。

  /// 群文件（群里发过的文件，不含图片）
  Future<List<dynamic>> groupFiles(int gid) async =>
      (await _get('/groups/$gid/files'))['items'] as List<dynamic>? ?? [];

  /// 群相册（群里发过的图片）
  Future<List<dynamic>> groupAlbums(int gid) async =>
      (await _get('/groups/$gid/albums'))['items'] as List<dynamic>? ?? [];

  /// 群视频（群里发过的视频文件）
  Future<List<dynamic>> groupVideos(int gid) async =>
      (await _get('/groups/$gid/videos'))['items'] as List<dynamic>? ?? [];

  /// 群课堂：{ items: [...], canManage: bool }
  Future<Map<String, dynamic>> groupCourses(int gid) async =>
      await _get('/groups/$gid/courses');

  Future<void> linkGroupCourse(int gid, int courseId) async =>
      await _post('/groups/$gid/courses', {'courseId': courseId});

  Future<void> unlinkGroupCourse(int gid, int courseId) async =>
      await _delete('/groups/$gid/courses/$courseId');

  // ---- 群功能 v2（2026-10-13：全员禁言 / 群名片 / 加群审批 / 群投票）----

  /// 改群设置（name / announcement / mutedAll / joinMode 任意组合）
  Future<Map<String, dynamic>> setMyGroupNickname(int gid, String nickname) async =>
      await _patch('/groups/$gid/members/me', {'nickname': nickname});

  /// 群主/管理员改他人群名片
  Future<Map<String, dynamic>> setMemberNickname(int gid, int uid, String nickname) async =>
      await _patch('/groups/$gid/members/$uid/nickname', {'nickname': nickname});

  /// 待审批的入群申请：{ items: [...] }
  Future<List<dynamic>> joinRequests(int gid) async =>
      (await _get('/groups/$gid/joinRequests'))['items'] as List<dynamic>? ?? [];

  Future<void> approveJoinRequest(int gid, int reqId) async =>
      await _post('/groups/$gid/joinRequests/$reqId/approve', const {});

  Future<void> rejectJoinRequest(int gid, int reqId) async =>
      await _post('/groups/$gid/joinRequests/$reqId/reject', const {});

  /// 建投票（同时往群里发一条 poll 卡片消息）→ { pollId }
  Future<Map<String, dynamic>> createPoll(int gid, {
    required String title,
    required List<String> options,
    bool multi = false,
    bool anonymous = false,
  }) async =>
      await _post('/groups/$gid/polls', {
        'title': title, 'options': options, 'multi': multi, 'anonymous': anonymous,
      });

  /// 投票详情 + 计票
  Future<Map<String, dynamic>> pollDetail(int gid, int pollId) async =>
      await _get('/groups/$gid/polls/$pollId');

  /// 投票（单选传一项；改票直接传新选项，服务端清旧票）
  Future<Map<String, dynamic>> votePoll(int gid, int pollId, List<int> optionIndexes) async =>
      await _post('/groups/$gid/polls/$pollId/vote', {'options': optionIndexes});

  Future<void> closePoll(int gid, int pollId) async =>
      await _post('/groups/$gid/polls/$pollId/close', const {});

  /// 全部群（仅系统管理员）—— 用来进那些自己不在里面的群
  Future<List<dynamic>> allGroups() async =>
      (await _get('/groups/all'))['items'] as List<dynamic>? ?? [];

  /// 系统管理员直接加入任意群
  Future<Map<String, dynamic>> joinGroupAsAdmin(int gid) async =>
      await _post('/groups/$gid/join', const {});

  // ---- 通话 ----
  /// 拉取 ICE 服务器配置（STUN / TURN）。
  ///
  /// 穿透地址由服务端下发而非写死在客户端，原因是 STUN 的可用性跟网络环境
  /// 强相关（`stun.qq.com` 在黑龙江电信就会被 RST）。放服务端以后，调穿透
  /// 方案只需改环境变量重启，不用重新发安卓包让所有人重装。
  Future<Map<String, dynamic>> callIce() async {
    final d = await _get('/call/ice');
    return d is Map ? Map<String, dynamic>.from(d) : <String, dynamic>{};
  }

  // ---- 远程协助 ----
  // 注意：这里只有「访问码管理」和「会话审计」两类接口。
  // 屏幕画面和键鼠操作**不走服务端** —— 那是 WebRTC P2P 的事。

  /// 我名下的无人值守访问码列表（不含明文，明文只在生成时返回一次）
  Future<List<RemoteCode>> remoteCodes() async {
    final d = await _get('/remote/codes');
    final items = d is Map && d['items'] is List ? d['items'] as List : <dynamic>[];
    return items
        .whereType<Map>()
        .map((e) => RemoteCode.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  /// 生成一个新访问码。**返回的 code 是唯一一次能看到的明文。**
  Future<Map<String, dynamic>> createRemoteCode({
    String label = '',
    bool singleUse = false,
    int? ttlMinutes,
  }) async {
    final d = await _post('/remote/codes', {
      'label': label,
      'singleUse': singleUse,
      if (ttlMinutes != null) 'ttlMinutes': ttlMinutes,
    });
    return d is Map ? Map<String, dynamic>.from(d) : <String, dynamic>{};
  }

  Future<void> revokeRemoteCode(int id) async {
    await _delete('/remote/codes/$id');
  }

  /// 我的远程协助会话历史（被控 + 控制都算），按时间倒序
  Future<List<RemoteSessionRecord>> remoteSessions({int limit = 50}) async {
    final d = await _get('/remote/sessions?limit=$limit');
    final items = d is Map && d['items'] is List ? d['items'] as List : <dynamic>[];
    return items
        .whereType<Map>()
        .map((e) => RemoteSessionRecord.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  /// 当前进行中的会话（App 重连后可回到控制界面）
  Future<Map<String, dynamic>?> remoteCurrent() async {
    final d = await _get('/remote/current');
    final s = d is Map ? d['session'] : null;
    return s is Map ? Map<String, dynamic>.from(s) : null;
  }

  // ---- 盘点：抽盘授权（M2/P2）----
  //
  // 🔴 这几条只用来**提前告诉用户**（进抽盘前问一句），
  //    权限的最终裁决在服务端 —— 客户端不做任何"猜他有没有权限"的判断：
  //    两边各判一套，必然在某个边界（刚授权/刚解除）上给出不同答案，
  //    表现出来就是"界面说有权、一上传被拒"，最难查的那种。
  //    所以这里拿不到结果时（断网）要**明说拿不到**，不能默认放行也不能默认拦。

  /// 某点位的抽盘授权现状（含"我自己有没有" `mine`）。
  Future<Map<String, dynamic>> stocktakeGrant(String zoneCode) async =>
      await _get('/stocktake/zone/${Uri.encodeComponent(zoneCode)}/grant');

  /// 我能在哪些点位抽盘。管理员返回 `{all: true, zone_codes: [...]}`。
  Future<Map<String, dynamic>> myStocktakeGrants() async =>
      await _get('/stocktake/grants/mine');

  /// 授权某人抽盘（需管理员，或该点位当前持权的人）。
  Future<Map<String, dynamic>> grantStocktake(String zoneCode, int userId) async =>
      await _post('/stocktake/zone/${Uri.encodeComponent(zoneCode)}/grant',
          {'user_id': userId});

  /// 解除抽盘授权（不是删记录，服务端会置 `revoked_at` 留痕）。
  Future<Map<String, dynamic>> revokeStocktake(String zoneCode, int userId) async =>
      await _delete(
          '/stocktake/zone/${Uri.encodeComponent(zoneCode)}/grant?user_id=$userId');

  // ---- 盘点：单据回传（P1 尾巴）----
  //
  // 采集全程离线，只有这一步联网。**服务端上传即归档**（`status=2`），
  // 归档之后默认不让覆盖 —— 允许默认覆盖等于"盘点结果可以事后修饰"。

  /// 回传一张盘点单的明细。
  ///
  /// [rows] 每行 `{barcode, qty, account_qty?, loc_code?, scanned_at?}`；
  /// [zone] 要带上（离线期间新建的点位服务端没有，缺了会 404 `zone_not_found`）。
  ///
  /// 🔴 **不上传 `force`。** 覆盖已归档的单是个需要留痕的例外动作，
  ///    不该藏在手机上一个顺手可点的按钮里 —— 那是给"事后改数"开口子。
  ///
  /// 失败时抛的 [ApiException] 必须看 [ApiException.code]：
  ///   - `already_uploaded`(409)：服务端**已经有**这张单，本地标记已上传即可
  ///   - `not_in_diff_set`(400)：抽盘扫了不在复核清单里的商品，
  ///     `data['barcodes']` 里是具体条码
  ///   - `zone_not_found`(404)：点位没带上，或者服务端确实没有这个点位
  Future<Map<String, dynamic>> uploadStocktakeSheet({
    required String sheetNo,
    required int phase,
    required List<Map<String, dynamic>> rows,
    Map<String, dynamic>? zone,
    List<Map<String, dynamic>>? bindings,
  }) async =>
      await _post('/stocktake/sheet/${Uri.encodeComponent(sheetNo)}/upload',
          <String, dynamic>{
            'phase': phase,
            'rows': rows,
            if (zone != null) 'zone': zone,
            if (bindings != null && bindings.isNotEmpty) 'bindings': bindings,
          });

  /// 上传库房减货单（`/api/deduct`）。
  ///
  /// 🔴 和盘点一样**不传 `force`**：覆盖已上传的单是留痕的例外动作，
  ///    不给手机上一个顺手可点的按钮 —— 减货要对账，事后能改就没意义了。
  ///
  /// 失败时看 [ApiException.code]：
  ///   - `already_uploaded`(409)：服务端已有这张单，归档本地即可（但必须说出来）
  ///   - `wrong_sheet_type`(409)：这个单号属于盘点单（正常流程不会出现）
  /// [startedAt] 必须是**开单那一刻**的真值，不是上传时刻：
  /// 管理台按它排序和按日期筛，落成上传时间的话，
  /// "昨天减的货"会在后台显示成今天，对账对不上。
  Future<Map<String, dynamic>> uploadDeductSheet({
    required String sheetNo,
    required List<Map<String, dynamic>> rows,
    String? deviceId,
    int? startedAt,
  }) async =>
      await _post('/deduct/sheet/${Uri.encodeComponent(sheetNo)}/upload',
          <String, dynamic>{
            'rows': rows,
            if (deviceId != null && deviceId.isNotEmpty) 'device_id': deviceId,
            if (startedAt != null) 'started_at': startedAt,
          });

  /// 减货时查这个条码的「参照数」（`/api/deduct/reference`）。
  ///
  /// 🔴 这个是**软查询**，调用方不要因为它失败就拦住用户：
  ///    减货现场常常没网（库房在仓库最里头）。查不到参照数只是少一条提示，
  ///    绝不能变成"先去盘点才能减货"——临时减货（破损/赠品出库）本来就不盘。
  /// 返回里 `hasRef=false` 表示服务端查不到任何参照（这个码没盘过、也没减过）。
  Future<Map<String, dynamic>> deductReference(String barcode) async {
    final d =
        await _get('/deduct/reference?barcode=${Uri.encodeComponent(barcode)}');
    // 🔴 取不到就返回空 map，不要抛：`hasRef=false` 是正常业务结果，
    //    抛异常会让界面分不清"没数据"和"网络挂了"，处理时会一律当成出错。
    if (d is! Map) return <String, dynamic>{'hasRef': false};
    return Map<String, dynamic>.from(d);
  }

  // ---- 审批中心（M2/P2）----

  /// 提交审批。盘点单走 `kind: 'stocktake'`，`ref` 是盘点单号。
  Future<Map<String, dynamic>> submitApproval({
    required String kind,
    String? ref,
    String? title,
    Object? payload,
  }) async =>
      await _post('/approval/submit', <String, dynamic>{
        'kind': kind,
        if (ref != null) 'ref': ref,
        if (title != null) 'title': title,
        if (payload != null) 'payload': payload,
      });

  /// 我提交的审批（status: pending / approved / rejected，不传=全部）。
  Future<List<Map<String, dynamic>>> myApprovals({String? status}) async {
    final d = await _get(
        '/approval/mine${status == null ? '' : '?status=$status'}');
    final items = d is Map ? d['items'] : null;
    return items is List
        ? items.map((e) => Map<String, dynamic>.from(e as Map)).toList()
        : const <Map<String, dynamic>>[];
  }

  /// 待审列表。`can_approve=false` 表示当前账号只能看、不能批
  /// （界面据此**不显示**按钮，而不是显示了再让服务端 403）。
  Future<Map<String, dynamic>> pendingApprovals() async =>
      await _get('/approval/pending');

  Future<Map<String, dynamic>> approveApproval(int id) async =>
      await _post('/approval/$id/approve', const {});

  /// 驳回。`reason` 必填（服务端也会拦，这里先拦一次省一个来回）。
  Future<Map<String, dynamic>> rejectApproval(int id, String reason) async =>
      await _post('/approval/$id/reject', {'reason': reason});

  /// 撤回（提交人自己，且只在待审时）。
  Future<Map<String, dynamic>> withdrawApproval(int id) async =>
      await _post('/approval/$id/withdraw', const {});

  // ---- 培训中心 ----
  //
  // 命名一律 `/training/...`，与服务端 routes/training.js 对齐。
  // 两个刻意的设计（改之前先看服务端那边的注释）：
  //   · 考试**开始**即消耗一次机会 —— 所以 startExam 失败要按 code 分开处理，
  //     不能一律弹"加载失败"（progress_not_reached 要告诉学员"先把课看完"）。
  //   · 题目里没有正确答案 —— 答案只在交卷后的回包里出现。

  Future<Map<String, dynamic>> trainingCourses(
      {String scope = 'public', String q = ''}) async {
    final p = '/training/courses?scope=$scope' +
        (q.isEmpty ? '' : '&q=${Uri.encodeQueryComponent(q)}');
    return await _get(p);
  }

  Future<Map<String, dynamic>> trainingCourse(int id) async =>
      await _get('/training/courses/$id');

  Future<Map<String, dynamic>> joinCourse(int id) async =>
      await _post('/training/courses/$id/join', const {});

  Future<Map<String, dynamic>> quitCourse(int id) async =>
      await _delete('/training/courses/$id/join');

  /// 上报进度。弱网会重传，服务端按 (user, lesson) 覆盖，重复调用安全。
  ///
  /// [positionSec] 到的最远处，**只用于续播**，服务端不拿它判完成；
  /// [watchedSec] 真看进去的秒数（见 core/lesson_progress.dart 的口径）；
  /// [done] 有没有看满。三者都传，管理台才看得到"到底看了多少"。
  ///
  /// ⚠️ [watchedSec] 必须是客户端真数出来的，不能拿 positionSec 顶替 ——
  ///    那会让"拖到 95%"重新变成"看完了"，白做。
  Future<Map<String, dynamic>> reportLessonProgress(int lessonId,
      {int positionSec = 0, int watchedSec = 0, bool done = false}) async =>
      await _post('/training/progress', <String, dynamic>{
        'lessonId': lessonId,
        'positionSec': positionSec,
        'watchedSec': watchedSec,
        'done': done,
      });

  Future<Map<String, dynamic>> startExam(int examId) async =>
      await _post('/training/exams/$examId/start', const {});

  Future<Map<String, dynamic>> submitSheet(int sheetId,
          List<Map<String, dynamic>> answers) async =>
      await _post('/training/sheets/$sheetId/submit', <String, dynamic>{
        'answers': answers,
      });

  Future<Map<String, dynamic>> trainingSheet(int sheetId) async =>
      await _get('/training/sheets/$sheetId');

  /// 课件下载地址。**必须带 token**（课件接口要鉴权），
  /// 直接用这个 URL 让浏览器打开是 401 —— 要走 FileIo 下载。
  String lessonMediaUrl(int lessonId) =>
      '${Config.baseUrl}/api/training/lessons/$lessonId/media';

  /// 下载课件用的鉴权头（同样取激活企业的 token）
  Map<String, String> get authHeaders {
    final t = SessionManager.instance.active?.token ?? _token;
    return t == null ? const {} : {'Authorization': 'Bearer $t'};
  }

  // ---- 文件 ----
  /// 上传文件。语音等临时录音文件没有规范扩展名时，用 filename 指定（如 voice.m4a）。
  Future<Map<String, dynamic>> upload(File f, {String? filename}) async {
    final req = http.MultipartRequest(
        'POST', Uri.parse('${Config.baseUrl}/api/files/upload'));
    req.headers['Authorization'] = 'Bearer $_token';
    final name = filename ?? f.path.split(Platform.pathSeparator).last;
    req.files.add(await http.MultipartFile.fromPath('file', f.path,
        filename: name));
    final r = await req.send();
    final body = jsonDecode(await r.stream.bytesToString());
    if (r.statusCode >= 200 && r.statusCode < 300) return body;
    throw Exception(body['error'] ?? '上传失败');
  }
}
