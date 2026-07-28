class FileReference {
  const FileReference({
    required this.conversationId,
    required this.conversationTitle,
    required this.messageId,
    required this.preview,
  });

  final String conversationId;
  final String conversationTitle;
  final String messageId;
  final String preview;
}
