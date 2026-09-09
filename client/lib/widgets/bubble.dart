import 'package:flutter/material.dart';
import 'package:xiaozhi_im_client/models.dart';

class MessageBubble extends StatelessWidget {
  final Message msg;
  final bool mine;
  final String? senderName;
  final String baseUrl;

  const MessageBubble({
    super.key,
    required this.msg,
    required this.mine,
    this.senderName,
    this.baseUrl = '',
  });

  @override
  Widget build(BuildContext context) {
    final align = mine ? CrossAxisAlignment.end : CrossAxisAlignment.start;
    Widget body;
    if (msg.kind == 'image' && msg.fileId != null) {
      body = Image.network('$baseUrl/files/${msg.content}', width: 200);
    } else if (msg.kind == 'file') {
      body = Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(color: Colors.blueGrey, borderRadius: BorderRadius.circular(8)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.insert_drive_file),
            const SizedBox(width: 8),
            Text(msg.content ?? '文件', style: const TextStyle(color: Colors.white)),
          ],
        ),
      );
    } else {
      body = Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: mine ? const Color(0xFF5865F2) : Colors.grey[800],
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(msg.content ?? '', style: const TextStyle(color: Colors.white)),
      );
    }

    return Column(
      crossAxisAlignment: align,
      children: [
        if (!mine && senderName != null)
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 2),
            child: Text(senderName!, style: const TextStyle(fontSize: 12, color: Colors.grey)),
          ),
        body,
        const SizedBox(height: 8),
      ],
    );
  }
}
