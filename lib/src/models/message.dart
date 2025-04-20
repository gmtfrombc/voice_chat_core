/// Represents a single message in the chat history.
class Message {
  String content;
  final bool isUser;
  final DateTime timestamp;
  bool isPartial; // Changed to non-final to allow updates for streaming

  Message({
    required this.content,
    required this.isUser,
    DateTime? timestamp,
    this.isPartial = false,
  }) : timestamp = timestamp ?? DateTime.now();

  /// Converts the message to a JSON format suitable for the OpenAI API.
  Map<String, dynamic> toJson() {
    return {'role': isUser ? 'user' : 'assistant', 'content': content};
  }
}
