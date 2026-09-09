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
  final int createdAt;

  const Message({
    required this.id,
    required this.conversationId,
    required this.senderId,
    required this.kind,
    this.content,
    this.fileId,
    required this.createdAt,
  });

  factory Message.fromJson(Map<String, dynamic> m) => Message(
        id: m['id'],
        conversationId: m['conversation_id'],
        senderId: m['sender_id'],
        kind: m['kind'],
        content: m['content'],
        fileId: m['file_id'],
        createdAt: m['created_at'],
      );
}
