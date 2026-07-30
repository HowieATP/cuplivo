import 'dart:async';
import 'package:flutter/widgets.dart';

import '../providers/settings_provider.dart';
import 'api/chat_api_service.dart';
import 'chat/chat_service.dart';

class HeadlessGenerationService extends ChangeNotifier {
  HeadlessGenerationService({required this._chatService});

  final ChatService _chatService;
  final _chunkControllers = <String, StreamController<ChatStreamChunk>>{};
  final _activeConversations = <String>{};

  bool isActive(String conversationId) =>
      _activeConversations.contains(conversationId);

  Stream<ChatStreamChunk>? chunkStream(String conversationId) =>
      _chunkControllers[conversationId]?.stream;

  void start({
    required String conversationId,
    required String assistantId,
    required List<Map<String, dynamic>> apiMessages,
    required ProviderConfig config,
    required String modelId,
    List<Map<String, dynamic>>? toolDefs,
    ToolCallHandler? onToolCall,
    int? thinkingBudget,
    double? temperature,
    double? topP,
    int? maxTokens,
    bool stream = true,
    VoidCallback? onComplete,
  }) {
    unawaited(
      _run(
        conversationId: conversationId,
        assistantId: assistantId,
        apiMessages: apiMessages,
        config: config,
        modelId: modelId,
        toolDefs: toolDefs,
        onToolCall: onToolCall,
        thinkingBudget: thinkingBudget,
        temperature: temperature,
        topP: topP,
        maxTokens: maxTokens,
        stream: stream,
        onComplete: onComplete,
      ),
    );
  }

  Future<void> _run({
    required String conversationId,
    required String assistantId,
    required List<Map<String, dynamic>> apiMessages,
    required ProviderConfig config,
    required String modelId,
    List<Map<String, dynamic>>? toolDefs,
    ToolCallHandler? onToolCall,
    int? thinkingBudget,
    double? temperature,
    double? topP,
    int? maxTokens,
    bool stream = true,
    VoidCallback? onComplete,
  }) async {
    final controller = StreamController<ChatStreamChunk>.broadcast();
    _chunkControllers[conversationId] = controller;
    _activeConversations.add(conversationId);
    notifyListeners();

    String? assistantMessageId;
    try {
      final assistantMsg = await _chatService.addMessage(
        conversationId: conversationId,
        role: 'assistant',
        content: '',
        isStreaming: true,
      );
      assistantMessageId = assistantMsg.id;

      final buf = StringBuffer();
      var chunkCount = 0;
      await for (final chunk in ChatApiService.sendMessageStream(
        config: config,
        modelId: modelId,
        messages: apiMessages,
        tools: toolDefs,
        onToolCall: onToolCall,
        thinkingBudget: thinkingBudget,
        temperature: temperature,
        topP: topP,
        maxTokens: maxTokens,
        stream: stream,
        requestId: conversationId,
      )) {
        chunkCount++;
        buf.write(chunk.content);
        controller.add(chunk);
      }

      debugPrint(
        '[HeadlessGen] stream done for $conversationId: '
        'chunks=$chunkCount buf.length=${buf.length}',
      );

      await _chatService.updateMessage(
        assistantMessageId,
        content: buf.toString(),
        isStreaming: false,
      );
      debugPrint(
        '[HeadlessGen] message updated: id=$assistantMessageId '
        'content.length=${buf.length} isStreaming=false',
      );
      onComplete?.call();
    } catch (e) {
      debugPrint('[HeadlessGen] error in $conversationId: $e');
      if (assistantMessageId != null) {
        await _chatService.updateMessage(
          assistantMessageId,
          content: 'Error: $e',
          isStreaming: false,
        );
      }
    } finally {
      _activeConversations.remove(conversationId);
      await controller.close();
      _chunkControllers.remove(conversationId);
      notifyListeners();
    }
  }

  void cancel(String conversationId) {
    ChatApiService.cancelRequest(conversationId);
  }
}
