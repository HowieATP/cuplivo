import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../../core/models/assistant.dart';
import '../../../core/models/director_message.dart';
import '../../../core/models/group_chat.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../core/services/api/chat_api_service.dart';
import '../../../core/services/chat/chat_service.dart';
import 'director_context_builder.dart';
import 'director_tool_protocol.dart';

/// Runs one director decision via tool-calling.
class DirectorRunner {
  DirectorRunner({required this.chatService, required this.contextBuilder});

  final ChatService chatService;
  final DirectorContextBuilder contextBuilder;

  static const temperature = 0.2;
  static const maxTokens = 256;
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
    final history = await chatService.repo.getDirectorMessages(group.id);

    final apiMessages = contextBuilder.buildApiMessages(
      group: group,
      history: history,
      newUserContent: newUserContent,
      rosterAssistants: rosterAssistants,
      userName: userName,
      memberNames: memberNames,
    );

    // Persist the new user turn first.
    final nextOrder = history.isEmpty
        ? 0
        : history.map((m) => m.messageOrder).reduce((a, b) => a > b ? a : b) +
              1;
    await chatService.repo.appendDirectorMessage(
      DirectorMessage(
        groupChatId: group.id,
        role: 'user',
        content: newUserContent,
        messageOrder: nextOrder,
      ),
    );

    DirectorDecision? decision;
    try {
      decision = await _callOnce(
        config: config,
        modelId: modelId,
        messages: apiMessages,
        tools: tools,
        assistantIds: assistantIds,
        requestId: 'director-${group.id}-$nextOrder',
      );
    } catch (e) {
      debugPrint('[Director] first call failed: $e');
    }

    if (decision == null) {
      // One retry with stronger instruction.
      final retryMessages = List<Map<String, dynamic>>.from(apiMessages)
        ..add({
          'role': 'user',
          'content':
              'You must call select_speaker or end_turn now. No free-text.',
        });
      try {
        decision = await _callOnce(
          config: config,
          modelId: modelId,
          messages: retryMessages,
          tools: tools,
          assistantIds: assistantIds,
          requestId: 'director-${group.id}-$nextOrder-retry',
        );
      } catch (e) {
        debugPrint('[Director] retry failed: $e');
      }
    }

    decision ??= DirectorDecision.end(
      reason: 'fallback_no_tool',
      fallback: true,
    );
    debugPrint(
      '[Director] decision=${decision.kind} '
      'assistant=${decision.assistantId} fallback=${decision.fallback}',
    );

    // Persist assistant decision row for logs.
    await chatService.repo.appendDirectorMessage(
      DirectorMessage(
        groupChatId: group.id,
        role: 'assistant',
        content: jsonEncode({
          'kind': decision.kind.name,
          'assistant_id': decision.assistantId,
          'reason': decision.reason,
          'fallback': decision.fallback,
        }),
        messageOrder: nextOrder + 1,
        metaJson: jsonEncode({'type': 'decision'}),
      ),
    );

    return decision;
  }

  Future<DirectorDecision?> _callOnce({
    required dynamic config,
    required String modelId,
    required List<Map<String, dynamic>> messages,
    required List<Map<String, dynamic>> tools,
    required List<String> assistantIds,
    required String requestId,
  }) async {
    DirectorDecision? decided;
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
      // Cancel further tool rounds.
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
        // Merged after provider defaults so this wins for OpenAI-compatible hosts.
        extraBody: const {'tool_choice': 'required'},
      );

      final sub = stream.listen(
        (chunk) {
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

      return await completer.future.timeout(
        timeout,
        onTimeout: () {
          unawaited(sub.cancel());
          ChatApiService.cancelRequest(requestId);
          debugPrint('[Director] timeout');
          throw TimeoutException('director timeout');
        },
      );
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
    if (name == DirectorTools.endTurn) {
      return DirectorDecision.end(reason: args['reason']?.toString());
    }
    if (name == DirectorTools.selectSpeaker) {
      final id = args['assistant_id']?.toString();
      if (id == null || !assistantIds.contains(id)) {
        debugPrint('[Director] invalid assistant_id=$id');
        return null;
      }
      return DirectorDecision.speak(id, reason: args['reason']?.toString());
    }
    return null;
  }
}

enum DirectorSoftErrorKind { noModel, noTools }

class DirectorSoftError implements Exception {
  DirectorSoftError(this.kind);
  final DirectorSoftErrorKind kind;

  @override
  String toString() => 'DirectorSoftError($kind)';
}
