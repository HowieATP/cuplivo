import '../../providers/settings_provider.dart';
import 'chat_api_service.dart';

/// Stream sender signature used by [PlainTextCollector].
typedef PlainTextStreamSender =
    Stream<ChatStreamChunk> Function({
      required ProviderConfig config,
      required String modelId,
      required List<Map<String, dynamic>> messages,
      List<String>? userMediaPaths,
      int? thinkingBudget,
      double? temperature,
      double? topP,
      int? maxTokens,
      List<Map<String, dynamic>>? tools,
      ToolCallHandler? onToolCall,
      Map<String, String>? extraHeaders,
      Map<String, dynamic>? extraBody,
      bool stream,
      String? requestId,
      bool allowImagesApiRouting,
      bool ocrActive,
    });

/// Layer-① no-tool text-stream collector (ADR-0028): a thin wrapper over
/// [ChatApiService.sendMessageStream] that accumulates `chunk.content` into
/// plain text, optionally reporting the accumulated buffer per chunk.
///
/// Consumers: OCR, translation, translate page, ProactiveCare care reply.
/// Non-streaming utility calls (chat suggestions, title generation) stay on
/// `generateText`, which is already shared.
class PlainTextCollector {
  PlainTextCollector({PlainTextStreamSender? sendMessageStream})
    : _sendMessageStream =
          sendMessageStream ?? ChatApiService.sendMessageStream;

  final PlainTextStreamSender _sendMessageStream;

  /// Runs the stream and returns the accumulated text.
  ///
  /// [onAccumulated] fires per non-empty chunk with the full accumulated
  /// buffer (live-update hook for streaming UI).
  Future<String> collect({
    required ProviderConfig config,
    required String modelId,
    required List<Map<String, dynamic>> messages,
    List<String>? userMediaPaths,
    int? thinkingBudget,
    double? topP,
    int? maxTokens,
    bool stream = true,
    bool allowImagesApiRouting = true,
    bool ocrActive = false,
    String? requestId,
    void Function(String accumulated)? onAccumulated,
  }) async {
    final buffer = StringBuffer();
    await for (final chunk in _sendMessageStream(
      config: config,
      modelId: modelId,
      messages: messages,
      userMediaPaths: userMediaPaths,
      thinkingBudget: thinkingBudget,
      temperature: null,
      topP: topP,
      maxTokens: maxTokens,
      tools: null,
      onToolCall: null,
      extraHeaders: null,
      extraBody: null,
      stream: stream,
      requestId: requestId,
      allowImagesApiRouting: allowImagesApiRouting,
      ocrActive: ocrActive,
    )) {
      if (chunk.content.isEmpty) continue;
      buffer.write(chunk.content);
      onAccumulated?.call(buffer.toString());
    }
    return buffer.toString();
  }
}
