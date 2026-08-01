import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../../core/models/assistant.dart';
import '../../../core/models/chat_message.dart';
import '../../../core/models/group_chat.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../core/services/api/chat_api_service.dart';
import '../../../core/services/chat/chat_service.dart';
import 'director_context_builder.dart';
import 'director_tool_protocol.dart';

/// Runs one director decision via tool-calling.
///
/// Uses the same transport as normal chat ([ChatApiService.sendMessageStream])
/// with provider-default `tool_choice: auto` (not `required`), so DeepSeek and
/// other OpenAI-compatible hosts that reject forced tools still work.
///
/// Director history is not persisted; each call is assembled from the public
/// conversation transcript.
class DirectorRunner {
  DirectorRunner({required this.chatService, required this.contextBuilder});

  final ChatService chatService;
  final DirectorContextBuilder contextBuilder;

  static const temperature = 0.2;
  static const maxTokens = 512;
  static const timeout = Duration(seconds: 45);

  Future<DirectorDecision> run({
    required GroupChat group,
    required String newUserContent,
    required List<Assistant> rosterAssistants,
    required String userName,
    required List<String> memberNames,
    required SettingsProvider settings,
    required bool Function(String providerKey, String modelId)
    modelSupportsTools,
    required List<ChatMessage> publicMessages,
    required Map<String, int> versionSelections,
    required Map<String, Assistant> assistantsById,
    String? skipPendingCapMessageId,
    String? excludeTrailingUserMessageId,
  }) async {
    final providerKey =
        (group.directorModelProvider ?? settings.currentModelProvider)?.trim();
    final modelId = (group.directorModelId ?? settings.currentModelId)?.trim();

    if (providerKey == null ||
        providerKey.isEmpty ||
        modelId == null ||
        modelId.isEmpty) {
      debugPrint('[Director] no model configured');
      throw DirectorSoftError(DirectorSoftErrorKind.noModel);
    }

    if (!modelSupportsTools(providerKey, modelId)) {
      debugPrint('[Director] model lacks tools: $providerKey/$modelId');
      throw DirectorSoftError(DirectorSoftErrorKind.noTools);
    }

    final config = settings.getProviderConfig(providerKey);
    final assistantIds = rosterAssistants.map((a) => a.id).toList();
    final tools = DirectorTools.definitions(assistantIds);

    final apiMessages = contextBuilder.buildApiMessagesFromPublic(
      group: group,
      publicMessages: publicMessages,
      versionSelections: versionSelections,
      newUserContent: newUserContent,
      rosterAssistants: rosterAssistants,
      userName: userName,
      memberNames: memberNames,
      assistantsById: assistantsById,
      skipPendingCapMessageId: skipPendingCapMessageId,
      excludeTrailingUserMessageId: excludeTrailingUserMessageId,
    );

    final requestStamp = DateTime.now().microsecondsSinceEpoch;

    String? lastError;
    String? lastFreeText;
    DirectorDecision? decision;

    try {
      final result = await _callOnce(
        config: config,
        modelId: modelId,
        messages: apiMessages,
        tools: tools,
        assistantIds: assistantIds,
        requestId: 'director-${group.id}-$requestStamp',
      );
      decision = result.decision;
      lastFreeText = result.freeText;
    } catch (e) {
      lastError = e.toString();
      debugPrint('[Director] first call failed: $e');
    }

    if (decision == null) {
      final retryMessages = List<Map<String, dynamic>>.from(apiMessages)
        ..add({
          'role': 'user',
          'content':
              'You must respond ONLY by calling the tools select_speaker or '
              'end_turn. Do not write free-text answers. '
              'Valid assistant_id values: ${assistantIds.join(', ')}',
        });
      try {
        final result = await _callOnce(
          config: config,
          modelId: modelId,
          messages: retryMessages,
          tools: tools,
          assistantIds: assistantIds,
          requestId: 'director-${group.id}-$requestStamp-retry',
        );
        decision = result.decision;
        lastFreeText = result.freeText ?? lastFreeText;
      } catch (e) {
        lastError = e.toString();
        debugPrint('[Director] retry failed: $e');
      }
    }

    if (decision == null && lastFreeText != null && lastFreeText.isNotEmpty) {
      decision = _tryParseFreeTextDecision(lastFreeText, assistantIds);
      if (decision != null) {
        debugPrint(
          '[Director] free-text fallback decision=${decision.kind} '
          'assistant=${decision.assistantId}',
        );
      }
    }

    decision ??= DirectorDecision.end(
      reason: lastError != null
          ? 'fallback_no_tool: $lastError'
          : (lastFreeText != null && lastFreeText.isNotEmpty
                ? 'fallback_no_tool: free_text=${_clip(lastFreeText, 200)}'
                : 'fallback_no_tool'),
      fallback: true,
    );
    debugPrint(
      '[Director] decision=${decision.kind} '
      'assistant=${decision.assistantId} fallback=${decision.fallback}',
    );

    return decision;
  }

  Future<({DirectorDecision? decision, String? freeText})> _callOnce({
    required dynamic config,
    required String modelId,
    required List<Map<String, dynamic>> messages,
    required List<Map<String, dynamic>> tools,
    required List<String> assistantIds,
    required String requestId,
  }) async {
    DirectorDecision? decided;
    final freeTextBuf = StringBuffer();
    final completer = Completer<DirectorDecision?>();

    Future<String> onToolCall(
      String name,
      Map<String, dynamic> args, {
      String? toolCallId,
    }) async {
      if (decided != null) return jsonEncode({'ok': true, 'ignored': true});
      decided = _parseTool(name, args, assistantIds);
      if (decided != null && !completer.isCompleted) {
        completer.complete(decided);
      }
      unawaited(Future(() => ChatApiService.cancelRequest(requestId)));
      return jsonEncode({'ok': true});
    }

    try {
      final stream = ChatApiService.sendMessageStream(
        config: config,
        modelId: modelId,
        messages: messages,
        tools: tools,
        onToolCall: onToolCall,
        temperature: temperature,
        maxTokens: maxTokens,
        stream: false,
        requestId: requestId,
      );

      final sub = stream.listen(
        (chunk) {
          if (chunk.content.isNotEmpty) {
            freeTextBuf.write(chunk.content);
          }
          if (decided != null) return;
          final calls = chunk.toolCalls;
          if (calls == null || calls.isEmpty) return;
          for (final c in calls) {
            final args = Map<String, dynamic>.from(c.arguments);
            decided = _parseTool(c.name, args, assistantIds);
            if (decided != null) {
              if (!completer.isCompleted) completer.complete(decided);
              break;
            }
          }
        },
        onError: (e) {
          if (!completer.isCompleted) completer.completeError(e);
        },
        onDone: () {
          if (!completer.isCompleted) completer.complete(decided);
        },
        cancelOnError: true,
      );

      final decision = await completer.future.timeout(
        timeout,
        onTimeout: () {
          unawaited(sub.cancel());
          ChatApiService.cancelRequest(requestId);
          debugPrint('[Director] timeout');
          throw TimeoutException('director timeout');
        },
      );
      final freeText = freeTextBuf.toString().trim();
      return (decision: decision, freeText: freeText.isEmpty ? null : freeText);
    } catch (e) {
      debugPrint('[Director] _callOnce error: $e');
      rethrow;
    }
  }

  DirectorDecision? _parseTool(
    String name,
    Map<String, dynamic> args,
    List<String> assistantIds,
  ) {
    final normalized = name.trim().toLowerCase().replaceAll('-', '_');
    if (normalized == DirectorTools.endTurn ||
        normalized.endsWith(DirectorTools.endTurn)) {
      return DirectorDecision.end(reason: args['reason']?.toString());
    }
    if (normalized == DirectorTools.selectSpeaker ||
        normalized.endsWith(DirectorTools.selectSpeaker)) {
      final id =
          args['assistant_id']?.toString() ??
          args['assistantId']?.toString() ??
          args['id']?.toString();
      if (id == null || !assistantIds.contains(id)) {
        debugPrint('[Director] invalid assistant_id=$id args=$args');
        return null;
      }
      return DirectorDecision.speak(id, reason: args['reason']?.toString());
    }
    return null;
  }

  DirectorDecision? _tryParseFreeTextDecision(
    String text,
    List<String> assistantIds,
  ) {
    final lower = text.toLowerCase();
    if (lower.contains('end_turn') ||
        lower.contains('no assistant') ||
        lower.contains('nobody') ||
        lower.contains('silence')) {
      return DirectorDecision.end(reason: 'free_text_end_turn', fallback: true);
    }
    for (final id in assistantIds) {
      if (text.contains(id)) {
        return DirectorDecision.speak(id, reason: 'free_text_id_match');
      }
    }
    return null;
  }

  static String _clip(String s, int max) {
    final t = s.trim();
    if (t.length <= max) return t;
    return '${t.substring(0, max)}…';
  }
}

enum DirectorSoftErrorKind { noModel, noTools }

class DirectorSoftError implements Exception {
  DirectorSoftError(this.kind);
  final DirectorSoftErrorKind kind;

  @override
  String toString() => 'DirectorSoftError($kind)';
}
