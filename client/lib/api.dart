import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'core/config.dart';
import 'core/storage.dart';

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

  dynamic _handle(http.Response r) {
    final body = jsonDecode(r.body);
    if (r.statusCode >= 200 && r.statusCode < 300) return body;
    throw Exception(body is Map ? (body['error'] ?? '请求失败') : '请求失败');
  }

  Future<dynamic> _post(String p, Map<String, dynamic> b) async {
    final r = await http.post(Uri.parse('${Config.baseUrl}/api$p'),
        headers: _h, body: jsonEncode(b));
    return _handle(r);
  }

  Future<dynamic> _patch(String p, Map<String, dynamic> b) async {
    final r = await http.patch(Uri.parse('${Config.baseUrl}/api$p'),
        headers: _h, body: jsonEncode(b));
    return _handle(r);
  }

  Future<dynamic> _get(String p) async {
    final r = await http.get(Uri.parse('${Config.baseUrl}/api$p'), headers: _h);
    return _handle(r);
  }

  /// 测试某个服务器地址是否可用（GET /api/health，不需要登录）。
  /// 返回提示文案用的结果 map；不通则抛异常。
  static Future<Map<String, dynamic>> testServer(String url) async {
    final u = Config.normalize(url);
    if (u.isEmpty) throw Exception('请填写服务器地址');
    final uri = Uri.tryParse('$u/api/health');
    if (uri == null) throw Exception('地址格式不正确');
    final r = await http.get(uri).timeout(const Duration(seconds: 6));
    if (r.statusCode != 200) throw Exception('HTTP ${r.statusCode}');
    final b = jsonDecode(r.body);
    if (b is! Map) throw Exception('返回格式不正确');
    return {'ok': b['ok'] == true, 'ts': b['ts']};
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

  Future<void> friendRequest(int id) async =>
      await _post('/friends/request', {'friendId': id});

  Future<void> acceptFriend(int id) async =>
      await _post('/friends/accept', {'friendId': id});

  Future<Map<String, dynamic>> friends() async => await _get('/friends');

  // ---- 会话 / 消息 ----
  Future<Map<String, dynamic>> dm(int userId) async =>
      await _get('/conversations/dm/$userId');

  Future<List<dynamic>> conversations() async => await _get('/conversations');

  /// 会话历史 + 已读状态：
  /// { messages: [...], members: [...], peerLastReadId, minOtherReadId, recallWindowMs }
  Future<Map<String, dynamic>> messages(int cid) async =>
      await _get('/conversations/$cid/messages');

  Future<Map<String, dynamic>> sendMessage(int cid, String kind, String content,
      [int? fileId]) async {
    final b = <String, dynamic>{'kind': kind, 'content': content};
    if (fileId != null) b['fileId'] = fileId;
    return await _post('/conversations/$cid/messages', b);
  }

  /// 撤回消息（仅本人、2 分钟内）
  Future<Map<String, dynamic>> recallMessage(int cid, int msgId) async =>
      await _post('/conversations/$cid/messages/$msgId/recall', const {});

  /// 编辑文字消息（仅本人）
  Future<Map<String, dynamic>> editMessage(
          int cid, int msgId, String content) async =>
      await _patch('/conversations/$cid/messages/$msgId', {'content': content});

  /// 标记已读（不传 msgId = 读到该会话最新一条）
  Future<Map<String, dynamic>> markRead(int cid, [int? msgId]) async =>
      await _post('/conversations/$cid/read',
          msgId == null ? const {} : {'messageId': msgId});

  // ---- 群组 ----
  Future<Map<String, dynamic>> createGroup(String name) async =>
      await _post('/groups', {'name': name});

  Future<void> addMember(int gid, int uid) async =>
      await _post('/groups/$gid/members', {'userId': uid});

  // ---- 文件 ----
  Future<Map<String, dynamic>> upload(File f) async {
    final req = http.MultipartRequest(
        'POST', Uri.parse('${Config.baseUrl}/api/files/upload'));
    req.headers['Authorization'] = 'Bearer $_token';
    req.files.add(await http.MultipartFile.fromPath('file', f.path));
    final r = await req.send();
    final body = jsonDecode(await r.stream.bytesToString());
    if (r.statusCode >= 200 && r.statusCode < 300) return body;
    throw Exception(body['error'] ?? '上传失败');
  }
}
