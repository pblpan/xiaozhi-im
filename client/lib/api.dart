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

  Future<dynamic> _get(String p) async {
    final r = await http.get(Uri.parse('${Config.baseUrl}/api$p'), headers: _h);
    return _handle(r);
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

  Future<List<dynamic>> messages(int cid) async =>
      await _get('/conversations/$cid/messages');

  Future<Map<String, dynamic>> sendMessage(int cid, String kind, String content,
      [int? fileId]) async {
    final b = <String, dynamic>{'kind': kind, 'content': content};
    if (fileId != null) b['fileId'] = fileId;
    return await _post('/conversations/$cid/messages', b);
  }

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
