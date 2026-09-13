// 远程协助的数据模型（访问码 / 会话审计）
//
// 这两个模型只描述"谁在什么时候连了谁"，**不涉及任何画面或键鼠内容** ——
// 那些是 P2P 直连的，服务端看不见，自然也不落库。

/// 从 JSON 里宽容取值的三个小工具。
///
/// 为什么不用 `j['id'] as int`：只要服务端把一个字段的类型改了（或者中间被
/// 代理改过），这里会直接抛 CastError —— 而 fromJson 是在列表渲染的循环里跑的，
/// 一抛就是整页崩给用户看。宁可拿到默认值，也不让界面白屏。
int jsonInt(Object? v, [int fallback = 0]) => v is num ? v.toInt() : fallback;

int? jsonIntOrNull(Object? v) => v is num ? v.toInt() : null;

String jsonStr(Object? v) => v is String ? v : '';

bool jsonBool(Object? v) => v == true;

/// 无人值守访问码。
///
/// ⚠️ 这里**没有 code 字段**：明文只在「生成的那一刻」返回一次，之后
/// 服务端只剩哈希、App 也查不到。故意不建模，防止哪天被人顺手加上了。
class RemoteCode {
  const RemoteCode({
    required this.id,
    required this.label,
    required this.singleUse,
    this.expiresAt,
    required this.useCount,
    this.lastUsedAt,
    required this.createdAt,
  });

  final int id;
  final String label;
  final bool singleUse;
  final int? expiresAt; // 毫秒时间戳，null = 长期有效
  final int useCount;
  final int? lastUsedAt;
  final int createdAt;

  factory RemoteCode.fromJson(Map<String, dynamic> j) => RemoteCode(
        id: jsonInt(j['id']),
        label: jsonStr(j['label']),
        singleUse: jsonBool(j['singleUse']),
        expiresAt: jsonIntOrNull(j['expiresAt']),
        useCount: jsonInt(j['useCount']),
        lastUsedAt: jsonIntOrNull(j['lastUsedAt']),
        createdAt: jsonInt(j['createdAt']),
      );

  bool get expired =>
      expiresAt != null && DateTime.now().millisecondsSinceEpoch > expiresAt!;

  /// 一次性码用过后就作废了
  bool get usedUp => singleUse && useCount > 0;
}

/// 会话角色：我在这次会话里是控制方还是被控方。
enum RemoteRole { host, controller }

/// 一次远程协助的审计记录。
class RemoteSessionRecord {
  const RemoteSessionRecord({
    required this.sessionId,
    required this.hostId,
    this.controllerId,
    required this.hostName,
    required this.controllerName,
    required this.mode,
    required this.status,
    required this.endReason,
    required this.role,
    required this.createdAt,
    this.startedAt,
    this.endedAt,
    required this.durationSec,
    this.hostDevice = '',
    this.controllerDevice = '',
  });

  final String sessionId;
  final int hostId;
  final int? controllerId;
  final String hostName;
  final String controllerName;
  final String mode; // attended | unattended
  final String status;
  final String endReason;
  final RemoteRole role;
  final int createdAt;
  final int? startedAt;
  final int? endedAt;
  final int durationSec;
  final String hostDevice;
  final String controllerDevice;

  /// 会话里"对方"的名字 —— 列表里显示"老李协助了你"或"你协助了小张"
  String get peerName => role == RemoteRole.host ? controllerName : hostName;

  factory RemoteSessionRecord.fromJson(Map<String, dynamic> j) =>
      RemoteSessionRecord(
        sessionId: jsonStr(j['sessionId']),
        hostId: jsonInt(j['hostId']),
        controllerId: jsonIntOrNull(j['controllerId']),
        hostName: jsonStr(j['hostName']),
        controllerName: jsonStr(j['controllerName']),
        mode: jsonStr(j['mode']).isEmpty ? 'attended' : jsonStr(j['mode']),
        status: jsonStr(j['status']),
        endReason: jsonStr(j['endReason']),
        role: j['role'] == 'host' ? RemoteRole.host : RemoteRole.controller,
        createdAt: jsonInt(j['createdAt']),
        startedAt: jsonIntOrNull(j['startedAt']),
        endedAt: jsonIntOrNull(j['endedAt']),
        durationSec: jsonInt(j['durationSec']),
        hostDevice: jsonStr(j['hostDevice']),
        controllerDevice: jsonStr(j['controllerDevice']),
      );
}

/// 结束原因 → 用户能看懂的文案。
String remoteEndReasonText(String r) {
  switch (r) {
    case 'host_end':
      return '对方已断开';
    case 'controller_end':
      return '你已断开连接';
    case 'timeout':
      return '会话超时已自动结束';
    case 'rejected':
      return '对方拒绝了协助请求';
    case 'canceled':
      return '你取消了请求';
    case 'offline':
      return '对方已离线';
    case 'failed':
      return '连接失败';
    default:
      return r.isEmpty ? '已结束' : r;
  }
}
