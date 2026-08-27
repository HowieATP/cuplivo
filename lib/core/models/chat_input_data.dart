import 'message_quote.dart';

/// SharedPreferences key of the persisted chat input draft. Single global
/// draft — the input is shared across conversations. Local-only: excluded
/// from backups/LAN sync (see `SharedPreferencesAsync._localOnlyKeys`).
const String chatInputDraftPrefsKey = 'chat_draft_v1';

class DocumentAttachment {
  final String path; // absolute file path
  final String fileName;
  final String mime; // e.g. application/pdf, text/plain

  const DocumentAttachment({
    required this.path,
    required this.fileName,
    required this.mime,
  });
}

class ChatInputData {
  final String text;
  final List<String> imagePaths; // absolute file paths or data URLs
  final List<DocumentAttachment> documents; // selected files
  final bool allowImagesApiRouting;
  final Map<String, dynamic> extraBody; // per-send API body overrides

  /// Pending reply citation; carried into the persisted user message as
  /// `ChatMessage.quoteJson`. Null = plain send.
  final MessageQuote? quote;

  /// Display-ready quote snippet for the composer preview row. Draft-only
  /// presentation state (the bubble renders its own citation); never read by
  /// the send pipeline.
  final String? quoteSnippet;

  const ChatInputData({
    required this.text,
    this.imagePaths = const [],
    this.documents = const [],
    this.allowImagesApiRouting = true,
    this.extraBody = const {},
    this.quote,
    this.quoteSnippet,
  });
}

enum ChatInputSubmissionResult { sent, queued, rejected }

class QueuedChatInput {
  final String conversationId;
  final ChatInputData input;

  const QueuedChatInput({required this.conversationId, required this.input});
}
