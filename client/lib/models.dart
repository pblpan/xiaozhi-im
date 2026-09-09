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

  const Conversation({
    required this.id,
    required this.type,
    this.title,
    this.avatar,
    this.lastContent,
    this.lastAt,
  });

  factory Conversation.fromJson(Map<String, dynamic> m) => Conversation(
        id: m['id'],
        type: m['type'],
        title: m['title'],
        avatar: m['avatar'],
        lastContent: m['last_content'],
        lastAt: m['last_at'],
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
      );

  /// 图片可显示的地址（baseUrl 由调用方拼）
  String? get imagePath {
    if (kind != 'image') return null;
    if (fileUrl != null && fileUrl!.isNotEmpty) return fileUrl;
    // 兼容：老数据 content 存的是 /files/xxx
    if (content != null && content!.startsWith('/files/')) return content;
    return null;
  }
}
