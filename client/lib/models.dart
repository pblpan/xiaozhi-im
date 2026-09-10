class User {
  final int id;
  final String username;
  final String? nickname;
  final String? avatar;
  final String role;

  const User({
    required this.id,
    required this.username,
    this.nickname,
    this.avatar,
    this.role = 'user',
  });

  factory User.fromJson(Map<String, dynamic> m) => User(
        id: m['id'],
        username: m['username'],
        nickname: m['nickname'],
        avatar: m['avatar'],
        role: m['role'] ?? 'user',
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

  const Conversation({
    required this.id,
    required this.type,
    this.title,
    this.avatar,
    this.lastContent,
    this.lastAt,
    this.unread = 0,
  });

  factory Conversation.fromJson(Map<String, dynamic> m) => Conversation(
        id: m['id'],
        type: m['type'],
        title: m['title'],
        avatar: m['avatar'],
        lastContent: m['last_content'],
        lastAt: m['last_at'],
        unread: (m['unread'] ?? 0) as int,
      );
}

class Message {
  final int id;
  final int conversationId;
  final int senderId;
  final String kind; // text | image | file | emoji
  final String? content;
  final int? fileId;
  final String? fileUrl; // 服务端 join 出的 /files/xxx 访问地址
  final String? fileName;
  final int? fileSize;
  final int createdAt;
  final bool edited; // 是否被编辑过
  final bool deleted; // 是否已撤回

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
      );

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
