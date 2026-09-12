import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'core/config.dart';
import 'core/storage.dart';

/// REST 异常（带 HTTP 状态码）。
/// 上层据此区分：401（token 失效，清 token 跳登录）vs 网络异常（连接/超时/5xx）。
class ApiException implements Exception {
  /// HTTP 状态码；null 表示底层网络/连接错误（SocketException / TimeoutException）
  final int? status;
  final String message;
  const ApiException(this.message, {this.status});

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
  void setToken(String t) => _token = t;

  bool get hasToken => _token != null && _token!.isNotEmpty;

  /// App 冷启动时从本地存储恢复登录态，否则后续请求都会 401。
  Future<void> restore() async {
    _token = await Storage.getToken();
  }

  void clearToken() => _token = null;

  Map<String, String> get _h => {
        'Content-Type': 'application/json',
        if (_token != null) 'Authorization': 'Bearer $_token',
      };

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
    try {
      final body = jsonDecode(r.body);
      msg = body is Map ? (body['error']?.toString() ?? '请求失败') : '请求失败';
    } catch (_) {
      msg = '请求失败 (HTTP ${r.statusCode})';
    }
    throw ApiException(msg, status: r.statusCode);
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
  Future<Map<String, dynamic>> login(String u, String p) async {
    final d = await _post('/auth/login', {'username': u, 'password': p});
    _token = d['token'];
    await Storage.saveToken(_token!);
    return d;
  }

  Future<Map<String, dynamic>> register(String u, String p, String n) async {
    final d = await _post('/auth/register',
        {'username': u, 'password': p, 'nickname': n});
    _token = d['token'];
    await Storage.saveToken(_token!);
    return d;
  }

  Future<Map<String, dynamic>> me() async => await _get('/auth/me');

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

  /// 全局消息搜索（服务端只在「我参与的会话」里搜，已撤回/非文字不返回）
  /// 返回 { items: [...], total, keyword }
  Future<Map<String, dynamic>> searchMessages(String q,
      {int? conversationId, int limit = 50, int offset = 0}) async {
    final sb = StringBuffer('/conversations/search?q=${Uri.encodeComponent(q)}');
    if (conversationId != null) sb.write('&conversationId=$conversationId');
    sb.write('&limit=$limit&offset=$offset');
    return await _get(sb.toString());
  }

  // ---- 群组 ----
  Future<Map<String, dynamic>> createGroup(String name) async =>
      await _post('/groups', {'name': name});

  Future<void> addMember(int gid, int uid) async =>
      await _post('/groups/$gid/members', {'userId': uid});

  /// 群详情：{ group, members, my_role, is_owner, can_manage }
  Future<Map<String, dynamic>> groupDetail(int gid) async =>
      await _get('/groups/$gid');

  /// 改群名 / 群公告（群主或管理员）
  Future<Map<String, dynamic>> updateGroup(int gid,
      {String? name, String? announcement}) async {
    final b = <String, dynamic>{};
    if (name != null) b['name'] = name;
    if (announcement != null) b['announcement'] = announcement;
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
