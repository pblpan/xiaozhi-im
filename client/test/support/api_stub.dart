import 'dart:convert';
import 'dart:io';

/// 一个**真的**本地 HTTP 服务端，给"必须连服务器才做得成"的页面做测试用。
///
/// ── 为什么不 mock 掉 http ──────────────────────────────────────
/// 抽盘授权页 / 审批中心这两页的全部价值，就是把服务端的判断**原样**摆出来：
/// 谁有权、我能不能批、驳回理由有没有带上。把 http 换成 mock 之后，
/// URL 拼错一个字符、字段名读错一个字母、Authorization 没带上 ——
/// 这些**全都能"通过"**。所以这里起一个真服务端：请求真的发出去、
/// 真的被解析、状态码真的按 HTTP 走。
///
/// ── 用法 ──────────────────────────────────────────────────────
/// ```dart
/// final stub = await ApiStub.start();
/// Config.currentUrl = stub.baseUrl;          // 让 ImApi 打到这个端口
/// ImApi().setToken('t');                     // 否则服务端会 401
/// stub.on('GET', '/api/stocktake/zone/Z01/grant', (r) => {...});
/// ...
/// addTearDown(stub.stop);
/// ```
/// 没注册的路径一律 404，并记进 `calls` —— 拼错 URL 时**必须响**，
/// 否则测试会以一个看不懂的报错收场（"找不到某某控件"），
/// 让人以为是界面坏了。
class ApiStub {
  ApiStub._(this._server);

  final HttpServer _server;
  final Map<String, Object? Function(StubCall)> _routes = {};

  /// 所有收到过的请求（按时间顺序）。用来断言"这一枪真的打出去了"。
  final List<StubCall> calls = [];

  String get baseUrl => 'http://127.0.0.1:${_server.port}';

  static Future<ApiStub> start() async {
    // 🔴 先把 binding 装的那层"假 http"换回真的。
    //    `TestWidgetsFlutterBinding` 一初始化就把 `HttpOverrides.global`
    //    换成一个**所有请求一律回 400**的假客户端（Flutter 故意的，
    //    防止单元测试偷偷联网）。这一套测的恰好是"请求真的发出去、
    //    服务端真的回"，所以必须盖回来 —— 盖的是**原样透传**，
    //    不是另一个 mock：
    //      不做这一步的现象是：页面一直停在转圈，超时后报
    //      "找不到某某控件"，让人以为是界面写坏了。
    HttpOverrides.global = _RealHttp();

    final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final stub = ApiStub._(s);
    // 每条请求单独处理，不排队 —— 页面里几个请求是并发的。
    s.listen((req) async {
      final body = await utf8.decoder.bind(req).join();
      Object? parsed;
      if (body.isNotEmpty) {
        try {
          parsed = jsonDecode(body);
        } catch (_) {
          parsed = body;
        }
      }
      final call = StubCall(
        method: req.method,
        path: req.uri.path,
        query: req.uri.queryParameters,
        body: parsed,
        authorization: req.headers.value('authorization'),
      );
      stub.calls.add(call);

      final h = stub._routes['${req.method} ${req.uri.path}'];
      if (h == null) {
        req.response.statusCode = 404;
        req.response.write(jsonEncode({'error': 'stub 未注册该路由 ${req.method} ${req.uri.path}'}));
        await req.response.close();
        return;
      }
      final out = h(call);
      if (out is StubResponse) {
        req.response.statusCode = out.status;
        req.response.write(jsonEncode(out.body));
      } else {
        req.response.statusCode = 200;
        req.response.write(jsonEncode(out));
      }
      await req.response.close();
    });
    return stub;
  }

  void on(String method, String path, Object? Function(StubCall) h) {
    _routes['$method $path'] = h;
  }

  /// 这条路径被打过几次？（断言"该发的请求发了、不该发的没发"）
  int hits(String method, String path) =>
      calls.where((c) => c.method == method && c.path == path).length;

  StubCall last(String method, String path) =>
      calls.lastWhere((c) => c.method == method && c.path == path);

  Future<void> stop() => _server.close(force: true);
}

class StubCall {  StubCall({
    required this.method,
    required this.path,
    required this.query,
    required this.body,
    required this.authorization,
  });

  final String method;
  final String path;
  final Map<String, String> query;
  final Object? body;
  final String? authorization;
}

/// 需要非 200 的时候用它（比如 403 —— 正好可以测"服务端拦住了会怎么样"）。
class StubResponse {
  const StubResponse(this.status, this.body);
  final int status;
  final Object? body;
}

/// 把 `HttpOverrides.global` 换回**真的** HttpClient。
///
/// 不做任何拦截、不做任何 mock —— 只是把 flutter_test 装的那层
/// "所有请求回 400"的壳摘掉，让请求真的走到 ApiStub 上。
/// 不重写任何方法：`HttpOverrides` 的默认实现就是返回真的 `HttpClient`，
/// 这里只是把 binding 装的那层壳顶掉。
class _RealHttp extends HttpOverrides {}
