import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/models/assistant.dart';
import '../../../core/services/generation_engine.dart';
import '../../home/controllers/stream_controller.dart' as stream_ctrl;

/// Streams one group-chat member assistant turn into a GenerationEngine slot
/// (ADR-0034 layer ③). Replaces the source-parity chunk loop of the deleted
/// `group_chat_stream_executor.dart`; the engine owns the chunk pipeline,
/// persistence, reasoning segments, sanitization and the smooth live ramp.
///
/// Contract preserved from the old executor: [executeStream]'s future
/// completes only after the slot settled (final content persisted), so
/// callers reading the message row right after it see the finished row, not
/// the still-streaming placeholder.
class GroupChatSlotRunner {
  GroupChatSlotRunner({
    required this.engine,
    required this.streamController,
    this.onTruncationWarning,
  });

  final GenerationEngine engine;
  final stream_ctrl.StreamController streamController;

  /// Fired once per turn when the response was truncated, with the raw
  /// reason (`max_tokens` / `context_exceeded`). The page maps it to
  /// localized copy (the runner itself has no l10n access).
  final void Function(String reason)? onTruncationWarning;

  Completer<void>? _activeDone;
  String? _lastTruncationReason;

  /// Starts one engine slot for [ctx] and returns when the slot settled
  /// (done, error, or cancelled).
  Future<void> executeStream(
    stream_ctrl.GenerationContext ctx, {
    String? streamKeyOverride,
    String? requestIdOverride,
  }) async {
    final assistant = ctx.assistant;
    final mid = ctx.assistantMessage.id;
    final cid = ctx.assistantMessage.conversationId;

    // Mark this message as actively streaming + pre-create its notifier so
    // MessageListView's streaming gate detects it.
    streamController.markStreamingStarted(mid);

    final done = _activeDone = Completer<void>();
    try {
      final notifier = streamController.streamingContentNotifier;
      engine.startRound(
        conversationId: cid,
        slots: [
          GenerationSlotRequest(
            assistantMessageId: mid,
            apiMessages: ctx.apiMessages,
            config: ctx.config,
            modelId: ctx.modelId,
            toolDefs: ctx.toolDefs,
            onToolCall: ctx.onToolCall,
            assistant: assistant is Assistant ? assistant : null,
            thinkingBudget:
                assistant?.thinkingBudget ?? ctx.settings.thinkingBudget,
            temperature: assistant?.temperature,
            topP: assistant?.topP,
            maxTokens: assistant?.maxTokens,
            stream: ctx.streamOutput,
            userMediaPaths: ctx.userMediaPaths,
            allowImagesApiRouting: ctx.allowImagesApiRouting,
            ocrActive: ctx.ocrActive,
            extraHeaders: ctx.extraHeaders,
            extraBody: ctx.extraBody,
            supportsReasoning: ctx.supportsReasoning,
            autoCollapseThinking: ctx.settings.autoCollapseThinking,
            onSlotComplete: () => _finalize(mid, done),
            onSlotError: (error) {
              debugPrint('[GroupChatSlotRunner] slot error: msgId=$mid $error');
              _finalize(mid, done);
            },
            onUiState: (state) {
              streamController.syncEngineUiState(mid, state);
              _lastTruncationReason = state.truncationReason;
            },
          ),
        ],
      );
      // Register the page notifier for live rendering (the engine's ramp
      // publishes to it; safe to register after start — the ramp syncs on
      // attach and the accumulated state is seeded on demand).
      final slot = engine.slotForMessage(mid);
      if (slot != null) {
        slot.uiNotifier = notifier;
        final text = slot.streamedText.toString();
        if (text.isNotEmpty) {
          notifier.updateContent(mid, text, 0);
        }
      }
    } catch (e) {
      debugPrint('[GroupChatSlotRunner] start failed: $e');
      _finalize(mid, done);
    }
    await done.future;
  }

  void _finalize(String mid, Completer<void> done) {
    if (done.isCompleted) return;
    streamController.markStreamingEnded(mid);
    final tr = _lastTruncationReason;
    _lastTruncationReason = null;
    done.complete();
    if (tr != null && onTruncationWarning != null) {
      onTruncationWarning!(tr);
    }
  }

  /// Cancels the in-flight turn: the engine cascades the HTTP cancel and
  /// persists the partial content with `isStreaming: false`; the running
  /// [executeStream] future resolves (mirror cancel semantics of the old
  /// executor — callers awaiting the turn are released immediately).
  void cancel(String messageId) {
    engine.cancelSlot(messageId);
    final done = _activeDone;
    if (done != null && !done.isCompleted) {
      done.complete();
    }
  }
}
