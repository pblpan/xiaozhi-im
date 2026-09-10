import 'dart:convert';

class User {
  final int id;
  final String username;
  final String? nickname;
  final String? avatar;
  final String role;
  final bool isBot;

  const User({
    required this.id,
    required this.username,
    this.nickname,
    this.avatar,
    this.role = 'user',
    this.isBot = false,
  });

  factory User.fromJson(Map<String, dynamic> m) => User(
        id: m['id'],
        username: m['username'],
        nickname: m['nickname'],
        avatar: m['avatar'],
        role: m['role'] ?? 'user',
        isBot: m['is_bot'] == true || m['is_bot'] == 1,
      );

  String get display =>
      (nickname != null && nickname!.isNotEmpty) ? nickname! : username;
}

class Conversation {
  final int id;
  final String type; // dm | group
  final String? title;
  final String? avatar;
  final String? lastContent;
  final int? lastAt;
  final int unread; // 未读消息数
  final bool hasMention; // 未读里是否有人 @我
  final bool muted; // 免打扰
  final String? announcement; // 群公告
  final int? groupId; // 群聊对应的群 id（单聊为 null）
  final Map<String, dynamic>? peer;

  const Conversation({
    required this.id,
    required this.type,
    this.title,
    this.avatar,
    this.lastContent,
    this.lastAt,
    this.unread = 0,
    this.hasMention = false,
    this.muted = false,
    this.announcement,
    this.groupId,
    this.peer,
  });

  factory Conversation.fromJson(Map<String, dynamic> m) => Conversation(
        id: m['id'],
        type: m['type'],
        title: m['title'],
        avatar: m['avatar'],
        lastContent: m['last_content'],
        lastAt: m['last_at'],
        unread: (m['unread'] ?? 0) as int,
        hasMention: m['has_mention'] == true,
        muted: m['muted'] == true,
        announcement: m['announcement'],
        groupId: m['group_id'] as int?,
        peer: m['peer'] as Map<String, dynamic>?,
      );
}

class Message {
  final int id;
  final int conversationId;
  final int senderId;
  final String kind; // text | image | file | emoji | audio | card
  final String? content;
  final int? fileId;
  final String? fileUrl; // 服务端 join 出的 /files/xxx 访问地址
  final String? fileName;
  final int? fileSize;
  final int createdAt;
  final bool edited; // 是否被编辑过
  final bool deleted; // 是否已撤回
  final List<int> mentions; // @提及的用户 id；-1 表示 @所有人
  final bool senderIsBot; // 发送者是不是机器人（渲染 BOT 标签）

  const Message({
    required this.id,
    required this.conversationId,
    required this.senderId,
    required this.kind,
    this.content,
    this.fileId,
    this.fileUrl,
    this.fileName,
    this.fileSize,
    required this.createdAt,
    this.edited = false,
    this.deleted = false,
    this.mentions = const [],
    this.senderIsBot = false,
  });

  factory Message.fromJson(Map<String, dynamic> m) => Message(
        id: m['id'],
        conversationId: m['conversation_id'],
        senderId: m['sender_id'],
        kind: m['kind'],
        content: m['content'],
        fileId: m['file_id'],
        fileUrl: m['file_url'],
        fileName: m['file_name'],
        fileSize: m['file_size'],
        createdAt: m['created_at'],
        edited: (m['edited'] ?? 0) == 1 || m['edited'] == true,
        deleted: (m['deleted'] ?? 0) == 1 || m['deleted'] == true,
        mentions: ((m['mentions'] as List?) ?? const [])
            .map((e) => e is int ? e : int.tryParse('$e') ?? -99)
            .where((e) => e != -99)
            .toList(),
        senderIsBot: m['sender_is_bot'] == true || m['sender_is_bot'] == 1,
      );

  /// 本地即时更新（撤回 / 编辑后无需重新拉取整页历史）
  Message copyWith({String? content, bool? edited, bool? deleted}) => Message(
        id: id,
        conversationId: conversationId,
        senderId: senderId,
        kind: kind,
        content: content ?? this.content,
        fileId: fileId,
        fileUrl: fileUrl,
        fileName: fileName,
        fileSize: fileSize,
        createdAt: createdAt,
        edited: edited ?? this.edited,
        deleted: deleted ?? this.deleted,
        mentions: mentions,
        senderIsBot: senderIsBot,
      );

  /// 是否 @了我（含 @所有人）
  bool mentionsMe(int myId) => mentions.contains(myId) || mentions.contains(-1);

  /// 卡片内容（kind == 'card' 且 JSON 合法时非空）
  CardData? get card => kind == 'card' ? CardData.tryParse(content) : null;

  /// 通话记录内容（kind == 'call' 且 JSON 合法时非空）
  CallLog? get call => kind == 'call' ? CallLog.tryParse(content) : null;

  /// 图片可显示的地址（baseUrl 由调用方拼）
  String? get imagePath {
    if (kind != 'image') return null;
    if (fileUrl != null && fileUrl!.isNotEmpty) return fileUrl;
    // 兼容：老数据 content 存的是 /files/xxx
    if (content != null && content!.startsWith('/files/')) return content;
    return null;
  }

  /// 语音时长（秒）。非语音消息返回 null；非法值兜底 1 秒。
  int? get audioSeconds {
    if (kind != 'audio') return null;
    final n = int.tryParse((content ?? '').trim());
    if (n == null) return 1;
    return n < 1 ? 1 : (n > 600 ? 600 : n);
  }

  /// 语音播放地址（baseUrl 由调用方拼）
  String? get audioPath {
    if (kind != 'audio') return null;
    if (fileUrl != null && fileUrl!.isNotEmpty) return fileUrl;
    return null;
  }

  /// 文件消息的下载地址（baseUrl 由调用方拼）
  String? get filePath {
    if (kind != 'file' && kind != 'image' && kind != 'audio') return null;
    if (fileUrl != null && fileUrl!.isNotEmpty) return fileUrl;
    if (content != null && content!.startsWith('/files/')) return content;
    return null;
  }

  /// 展示 / 另存为时用的文件名（取路径最后一段，兜底「文件」）
  String get displayFileName {
    final raw = (fileName != null && fileName!.isNotEmpty)
        ? fileName!
        : (kind == 'file' ? (content ?? '') : '');
    if (raw.isEmpty) return '文件';
    final i = raw.lastIndexOf('/');
    final n = i < 0 ? raw : raw.substring(i + 1);
    return n.isEmpty ? '文件' : n;
  }
}

/// 通话记录消息（kind == 'call'）的内容。
///
/// 服务端在通话的每个终态都会落一条这样的消息，所以"漏接/被拒"不会静默丢失。
class CallLog {
  final String mode; // audio | video
  final String status; // ended | missed | rejected | canceled | busy | failed
  final int duration; // 通话秒数（未接通为 0）

  const CallLog({
    this.mode = 'audio',
    this.status = 'ended',
    this.duration = 0,
  });

  factory CallLog.fromJson(Map<String, dynamic> m) => CallLog(
        mode: '${m['mode'] ?? 'audio'}',
        status: '${m['status'] ?? 'ended'}',
        duration: (m['duration'] as num?)?.toInt() ?? 0,
      );

  static CallLog? tryParse(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      final v = jsonDecode(raw);
      if (v is! Map) return null;
      return CallLog.fromJson(v.cast<String, dynamic>());
    } catch (_) {
      return null; // 脏数据 → 调用方降级成纯文本
    }
  }

  bool get isVideo => mode == 'video';

  /// 时长文案：不足 1 小时用 mm:ss，超过用 h:mm:ss
  String get durationText {
    final s = duration < 0 ? 0 : duration;
    final h = s ~/ 3600;
    final m = (s % 3600) ~/ 60;
    final sec = s % 60;
    final mm = m.toString().padLeft(2, '0');
    final ss = sec.toString().padLeft(2, '0');
    return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
  }

  /// 气泡里显示的一行文案
  String get label {
    final kind = isVideo ? '视频通话' : '语音通话';
    switch (status) {
      case 'ended':
        return duration > 0 ? '$kind  $durationText' : kind;
      case 'missed':
        return '$kind · 未接听';
      case 'rejected':
        return '$kind · 已拒绝';
      case 'canceled':
        return '$kind · 已取消';
      case 'busy':
        return '$kind · 对方忙线中';
      case 'failed':
        return '$kind · 通话中断';
      default:
        return kind;
    }
  }

  /// 未正常通话结束（界面用弱化/警示色）
  bool get isMissed => status != 'ended';
}

/// 卡片里的一个字段（键值对，如「东北大米 → 剩 3 袋」）
class CardField {
  final String label;
  final String value;
  final bool short; // true = 可与相邻字段并排显示

  const CardField({this.label = '', this.value = '', this.short = false});

  factory CardField.fromJson(Map<String, dynamic> m) => CardField(
        label: '${m['label'] ?? ''}',
        value: '${m['value'] ?? ''}',
        short: m['short'] == true,
      );
}

/// 结构化卡片消息：外部系统（工厂 V2 / OA / 脚本）推送的日报、预警等
///
/// 内容由服务端归一化过（长度、字段数、颜色白名单），客户端只负责画，
/// 不需要再做防御性校验——但解析失败时仍返回 null 走降级渲染。
class CardData {
  final String title;
  final String text;
  final List<CardField> fields;
  final String color; // blue | green | orange | red | purple | gray
  final String footer;
  final String url; // 可点击跳转的链接（可为空）

  const CardData({
    this.title = '',
    this.text = '',
    this.fields = const [],
    this.color = 'blue',
    this.footer = '',
    this.url = '',
  });

  factory CardData.fromJson(Map<String, dynamic> m) => CardData(
        title: '${m['title'] ?? ''}',
        text: '${m['text'] ?? ''}',
        fields: ((m['fields'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => CardField.fromJson(e.cast<String, dynamic>()))
            .toList(),
        color: '${m['color'] ?? 'blue'}',
        footer: '${m['footer'] ?? ''}',
        url: '${m['url'] ?? ''}',
      );

  static CardData? tryParse(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      final v = jsonDecode(raw);
      if (v is! Map) return null;
      return CardData.fromJson(v.cast<String, dynamic>());
    } catch (_) {
      return null; // 老数据/脏数据 → 调用方降级成纯文本
    }
  }

  bool get isEmpty => title.isEmpty && text.isEmpty && fields.isEmpty;
}

/// 全局搜索结果条目（消息 + 所在会话 + 发送者）
class SearchHit {
  final Message msg;
  final String? convTitle;
  final String? convType; // dm | group
  final String? senderName;
  final bool mine;

  const SearchHit({
    required this.msg,
    this.convTitle,
    this.convType,
    this.senderName,
    this.mine = false,
  });

  factory SearchHit.fromJson(Map<String, dynamic> m) => SearchHit(
        msg: Message.fromJson(m),
        convTitle: m['conv_title'],
        convType: m['conv_type'],
        senderName: m['sender_name'],
        mine: m['mine'] == true,
      );
}

/// 收藏条目（消息 + 所在会话 + 发送者 + 收藏时间）
class FavoriteHit {
  final Message msg;
  final String? convTitle;
  final String? convType;
  final String? senderName;
  final bool mine;
  final int? favoritedAt;

  const FavoriteHit({
    required this.msg,
    this.convTitle,
    this.convType,
    this.senderName,
    this.mine = false,
    this.favoritedAt,
  });

  factory FavoriteHit.fromJson(Map<String, dynamic> m) => FavoriteHit(
        msg: Message.fromJson(m),
        convTitle: m['conv_title'],
        convType: m['conv_type'],
        senderName: m['sender_name'],
        mine: m['mine'] == true,
        favoritedAt: m['favorited_at'],
      );
}

/// 群成员（群管理页用）
class GroupMember {
  final int id;
  final String username;
  final String? nickname;
  final String? avatar;
  final String role; // owner | admin | member
  final int mutedUntil; // 禁言到期时间戳，0 = 未禁言
  final int? joinedAt;
  final bool isBot;

  const GroupMember({
    required this.id,
    required this.username,
    this.nickname,
    this.avatar,
    this.role = 'member',
    this.mutedUntil = 0,
    this.joinedAt,
    this.isBot = false,
  });

  factory GroupMember.fromJson(Map<String, dynamic> m) => GroupMember(
        id: m['id'],
        username: m['username'],
        nickname: m['nickname'],
        avatar: m['avatar'],
        role: m['role'] ?? 'member',
        mutedUntil: (m['muted_until'] ?? 0) as int,
        joinedAt: m['joined_at'],
        isBot: m['is_bot'] == true || m['is_bot'] == 1,
      );

  String get display =>
      (nickname != null && nickname!.isNotEmpty) ? nickname! : username;

  bool get isMuted => mutedUntil > DateTime.now().millisecondsSinceEpoch;

  String get roleLabel =>
      role == 'owner' ? '群主' : (role == 'admin' ? '管理员' : '成员');
}

/// 群详情（群信息 + 成员 + 我的权限）
class GroupDetail {
  final Map<String, dynamic> group;
  final List<GroupMember> members;
  final String myRole;
  final bool isOwner;
  final bool canManage;

  const GroupDetail({
    required this.group,
    required this.members,
    this.myRole = 'member',
    this.isOwner = false,
    this.canManage = false,
  });

  factory GroupDetail.fromJson(Map<String, dynamic> m) => GroupDetail(
        group: (m['group'] ?? const {}) as Map<String, dynamic>,
        members: ((m['members'] as List?) ?? const [])
            .map((e) => GroupMember.fromJson(e))
            .toList(),
        myRole: m['my_role'] ?? 'member',
        isOwner: m['is_owner'] == true,
        canManage: m['can_manage'] == true,
      );

  int get id => (group['id'] ?? 0) as int;
  String get name => (group['name'] ?? '') as String;
  String? get announcement => group['announcement'] as String?;
  int get conversationId => (group['conversation_id'] ?? 0) as int;
}
