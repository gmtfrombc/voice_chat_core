import 'package:uuid/uuid.dart';

/// Represents a single message in the chat history.
class Message {
  final String id;
  String content;
  final bool isUser;
  final DateTime timestamp;
  bool isPartial; // Changed to non-final to allow updates for streaming

  Message({
    String? id,
    required this.content,
    required this.isUser,
    DateTime? timestamp,
    this.isPartial = false,
  })  : id = id ?? const Uuid().v4(),
        timestamp = timestamp ?? DateTime.now();

  /// Converts the message to a JSON format suitable for the OpenAI API.
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'role': isUser ? 'user' : 'assistant',
      'content': content,
    };
  }
}
