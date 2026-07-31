// SOURCE PARITY: lib/features/home/controllers/chat_actions.dart
// Stream path for group-chat member assistants (tools + content).

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/models/token_usage.dart';
import '../../../core/services/api/chat_api_service.dart';
import '../../../core/services/chat/chat_service.dart';
import '../../home/controllers/stream_controller.dart' as stream_ctrl;

/// Stream executor for group chat member assistants.
class GroupChatStreamExecutor {
  GroupChatStreamExecutor({
    required this.chatService,
    required this.streamController,
  });

  final ChatService chatService;
  final stream_ctrl.StreamController streamController;

  final Map<String, StreamSubscription<ChatStreamChunk>> _streams = {};

  Future<void> executeStream(
    stream_ctrl.GenerationContext ctx, {
    String? streamKeyOverride,
    String? requestIdOverride,
  }) async {
    final state = stream_ctrl.StreamingState(ctx);
    final assistant = ctx.assistant;
    final streamKey = streamKeyOverride ?? state.conversationId;
    final requestId = requestIdOverride ?? state.conversationId;

    streamController.markStreamingStarted(state.messageId);

    try {
      final stream = ChatApiService.sendMessageStream(
        config: ctx.config,
        modelId: ctx.modelId,
        messages: ctx.apiMessages,
        userMediaPaths: ctx.userMediaPaths,
        thinkingBudget:
            assistant?.thinkingBudget ?? ctx.settings.thinkingBudget,
        temperature: assistant?.temperature,
        topP: assistant?.topP,
        maxTokens: assistant?.maxTokens,
        tools: ctx.toolDefs.isEmpty ? null : ctx.toolDefs,
        onToolCall: ctx.onToolCall,
        extraHeaders: ctx.extraHeaders,
        extraBody: ctx.extraBody,
        stream: ctx.streamOutput,
        requestId: requestId,
        allowImagesApiRouting: ctx.allowImagesApiRouting,
        ocrActive: ctx.ocrActive,
      );

      await _streams[streamKey]?.cancel();
      // Process chunks sequentially (await handler before next event).
      final pending = <Future<void>>[];
      final sub = stream.listen(
        (chunk) {
          final prev = pending.isEmpty ? Future<void>.value() : pending.last;
          final next = prev.then((_) => _handleChunk(chunk, state));
          pending.add(next);
        },
        onError: (Object e, StackTrace st) {
          final prev = pending.isEmpty ? Future<void>.value() : pending.last;
          pending.add(prev.then((_) => _handleError(e, state)));
        },
        onDone: () {
          final prev = pending.isEmpty ? Future<void>.value() : pending.last;
          pending.add(prev.then((_) => _handleDone(state)));
        },
        cancelOnError: false,
      );
      _streams[streamKey] = sub;
    } catch (e, st) {
      debugPrint('[GroupChatStreamExecutor] start error: $e\n$st');
      await _handleError(e, state);
    }
  }

  Future<void> cancel(String streamKey) async {
    await _streams[streamKey]?.cancel();
    _streams.remove(streamKey);
    ChatApiService.cancelRequest(streamKey);
  }

  Future<void> _handleChunk(
    ChatStreamChunk chunk,
    stream_ctrl.StreamingState state,
  ) async {
    final messageId = state.messageId;
    var chunkContent = chunk.content;
    if (chunkContent.isNotEmpty) {
      chunkContent = streamController.captureGeminiThoughtSignature(
        chunkContent,
        messageId,
      );
    }

    if (chunk.reasoningDetails != null) {
      streamController.setReasoningDetails(messageId, chunk.reasoningDetails);
    }

    if ((chunk.reasoning ?? '').isNotEmpty && state.ctx.supportsReasoning) {
      await streamController.handleReasoningChunk(
        chunk,
        state,
        updateReasoningInDb:
            (
              String mid, {
              String? reasoningText,
              DateTime? reasoningStartAt,
              String? reasoningSegmentsJson,
            }) async {
              await chatService.updateMessageSilent(
                mid,
                reasoningText: reasoningText,
                reasoningStartAt: reasoningStartAt,
                reasoningSegmentsJson: reasoningSegmentsJson,
              );
            },
      );
    }

    if ((chunk.toolCalls ?? const []).isNotEmpty) {
      await streamController.handleToolCallsChunk(
        chunk,
        state,
        updateReasoningSegmentsInDb: (String mid, String json) async {
          await chatService.updateMessageSilent(
            mid,
            reasoningSegmentsJson: json,
          );
        },
        setToolEventsInDb:
            (String mid, List<Map<String, dynamic>> events) async {
              await chatService.setToolEvents(mid, events);
            },
        getToolEventsFromDb: (String mid) => chatService.getToolEvents(mid),
      );
    }

    if ((chunk.toolResults ?? const []).isNotEmpty) {
      await streamController.handleToolResultsChunk(
        chunk,
        state,
        upsertToolEventInDb:
            (
              String mid, {
              required String id,
              required String name,
              required Map<String, dynamic> arguments,
              String? content,
              Map<String, dynamic>? metadata,
            }) async {
              await chatService.upsertToolEvent(
                mid,
                id: id,
                name: name,
                arguments: arguments,
                content: content,
                metadata: metadata,
              );
            },
      );
    }

    if (chunkContent.isNotEmpty && !state.finishHandled) {
      state.fullContentRaw += chunkContent;
      state.streamStartedAt ??= DateTime.now();
      if (chunk.totalTokens > 0) {
        state.totalTokens = chunk.totalTokens;
      }
      if (chunk.usage != null) {
        state.usage = (state.usage ?? const TokenUsage()).merge(chunk.usage!);
        state.totalTokens = state.usage!.totalTokens;
      }
      await chatService.updateMessageSilent(
        messageId,
        content: state.fullContentRaw,
        totalTokens: state.totalTokens,
      );
      // Lightweight UI tick for ValueListenableBuilder consumers.
      streamController.streamingContentNotifier.updateContent(
        messageId,
        state.fullContentRaw,
        state.totalTokens,
      );
    }

    if (chunk.isDone) {
      await _finish(chunk, state);
    }
  }

  Future<void> _finish(
    ChatStreamChunk chunk,
    stream_ctrl.StreamingState state,
  ) async {
    if (state.finishHandled) return;
    state.finishHandled = true;
    if (chunk.usage != null) {
      state.usage = (state.usage ?? const TokenUsage()).merge(chunk.usage!);
      state.totalTokens = state.usage!.totalTokens;
    }
    await chatService.updateMessage(
      state.messageId,
      content: state.fullContentRaw,
      isStreaming: false,
      totalTokens: state.totalTokens,
      promptTokens: state.usage?.promptTokens,
      completionTokens: state.usage?.completionTokens,
    );
    streamController.markStreamingEnded(state.messageId);
    streamController.cleanupTimers(state.messageId);
  }

  Future<void> _handleError(
    Object error,
    stream_ctrl.StreamingState state,
  ) async {
    debugPrint('[GroupChatStreamExecutor] stream error: $error');
    if (!state.finishHandled) {
      state.finishHandled = true;
      final existing = state.fullContentRaw;
      await chatService.updateMessage(
        state.messageId,
        isStreaming: false,
        content: existing.isNotEmpty ? existing : 'Error: $error',
      );
    }
    streamController.markStreamingEnded(state.messageId);
    streamController.cleanupTimers(state.messageId);
  }

  Future<void> _handleDone(stream_ctrl.StreamingState state) async {
    if (state.finishHandled) return;
    state.finishHandled = true;
    await chatService.updateMessage(
      state.messageId,
      content: state.fullContentRaw,
      isStreaming: false,
      totalTokens: state.totalTokens,
    );
    streamController.markStreamingEnded(state.messageId);
    streamController.cleanupTimers(state.messageId);
  }

  void dispose() {
    for (final s in _streams.values) {
      unawaited(s.cancel());
    }
    _streams.clear();
  }
}
