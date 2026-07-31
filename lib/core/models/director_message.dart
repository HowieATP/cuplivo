import 'package:uuid/uuid.dart';

/// One row in the director's private session (invisible to member assistants).
class DirectorMessage {
  DirectorMessage({
    String? id,
    required this.groupChatId,
    required this.role,
    required this.content,
    required this.messageOrder,
    DateTime? createdAt,
    this.metaJson,
  }) : id = id ?? const Uuid().v4(),
       createdAt = createdAt ?? DateTime.now();

  final String id;
  final String groupChatId;

  /// system | user | assistant | tool
  final String role;
  final String content;
  final int messageOrder;
  final DateTime createdAt;

  /// Optional JSON (tool_calls metadata, tool name, etc.).
  final String? metaJson;

  Map<String, dynamic> toJson() => {
    'id': id,
    'groupChatId': groupChatId,
    'role': role,
    'content': content,
    'messageOrder': messageOrder,
    'createdAt': createdAt.toIso8601String(),
    'metaJson': metaJson,
  };

  factory DirectorMessage.fromJson(Map<String, dynamic> json) {
    return DirectorMessage(
      id: json['id'] as String?,
      groupChatId: json['groupChatId'] as String,
      role: json['role'] as String,
      content: json['content'] as String? ?? '',
      messageOrder: (json['messageOrder'] as num?)?.toInt() ?? 0,
      createdAt: json['createdAt'] != null
          ? DateTime.parse(json['createdAt'] as String)
          : null,
      metaJson: json['metaJson'] as String?,
    );
  }
}
