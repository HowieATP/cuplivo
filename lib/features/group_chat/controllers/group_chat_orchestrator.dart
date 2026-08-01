import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/models/assistant.dart';
import '../../../core/models/chat_input_data.dart';
import '../../../core/models/chat_message.dart';
import '../../../core/models/conversation.dart';
import '../../../core/models/group_chat.dart';
import '../../../core/providers/assistant_provider.dart';
import '../../../core/providers/group_chat_provider.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../core/providers/user_provider.dart';
import '../../../core/services/chat/chat_service.dart';
import '../../home/controllers/generation_controller.dart';
import '../../home/controllers/stream_controller.dart' as stream_ctrl;
import '../../home/services/ask_user_interaction_service.dart';
import '../../home/services/message_generation_service.dart';
import '../../home/services/message_pipeline.dart';
import '../../home/services/tool_approval_service.dart';
import '../services/assistant_private_context_builder.dart';
import '../services/director_context_builder.dart';
import '../services/director_runner.dart';
import '../services/director_tool_protocol.dart';
import 'group_chat_stream_executor.dart';

typedef GroupChatUiFeedback = void Function(String messageKey);

/// Orchestrates user → director → assistant turns for one group chat session.
class GroupChatOrchestrator {
  GroupChatOrchestrator({
    required this.chatService,
    required this.groupChatProvider,
    required this.assistantProvider,
    required this.settingsProvider,
    required this.userProvider,
    required this.streamController,
    required this.generationController,
    required this.messageGenerationService,
    required this.streamExecutor,
    required this.approvalService,
    required this.askUserService,
    required this.onUiFeedback,
    required this.onMessagesChanged,
  }) {
    _contextBuilder = DirectorContextBuilder(chatService: chatService);
    _privateBuilder = AssistantPrivateContextBuilder(chatService: chatService);
    _directorRunner = DirectorRunner(
      chatService: chatService,
      contextBuilder: _contextBuilder,
    );
    _pipeline = MessagePipeline(
      chatService: chatService,
      messageGenerationService: messageGenerationService,
      streamController: streamController,
      generationController: generationController,
      executeStream: streamExecutor.executeStream,
    );
  }

  final ChatService chatService;
  final GroupChatProvider groupChatProvider;
  final AssistantProvider assistantProvider;
  final SettingsProvider settingsProvider;
  final UserProvider userProvider;
  final stream_ctrl.StreamController streamController;
  final GenerationController generationController;
  final MessageGenerationService messageGenerationService;
  final GroupChatStreamExecutor streamExecutor;
  final ToolApprovalService? approvalService;
  final AskUserInteractionService? askUserService;
  final GroupChatUiFeedback onUiFeedback;
  final VoidCallback onMessagesChanged;

  late final DirectorContextBuilder _contextBuilder;
  late final AssistantPrivateContextBuilder _privateBuilder;
  late final DirectorRunner _directorRunner;
  late final MessagePipeline _pipeline;

  bool _busy = false;
  bool _stopRequested = false;
  String? _activeStreamKey;

  bool get isBusy => _busy;

  void requestStop() {
    _stopRequested = true;
    final key = _activeStreamKey;
    if (key != null) {
      unawaited(streamExecutor.cancel(key));
    }
  }

  Future<void> handleUserMessage({
    required GroupChat group,
    required ChatMessage userMessage,
    ChatInputData? inputData,
  }) async {
    if (_busy) return;
    _busy = true;
    _stopRequested = false;
    try {
      final assistantIds = groupChatProvider.assistantIdsOf(group.id);
      if (assistantIds.isEmpty) {
        onUiFeedback('groupChatNoAssistants');
        return;
      }

      final userName = userProvider.name.trim().isEmpty
          ? 'User'
          : userProvider.name.trim();

      // Cap merge or normal E1
      String directorUserContent;
      var g = groupChatProvider.getById(group.id) ?? group;
      if (g.pendingCapAssistantMessageId != null) {
        final pendingId = g.pendingCapAssistantMessageId!;
        final msgs = chatService.getMessages(g.conversationId);
        ChatMessage? pending;
        for (final m in msgs) {
          if (m.id == pendingId) {
            pending = m;
            break;
          }
        }
        final aName =
            assistantProvider.assistants
                .where((a) => a.id == pending?.speakerAssistantId)
                .map((a) => a.name)
                .firstOrNull ??
            'Assistant';
        directorUserContent = _contextBuilder.buildCapMergeE3(
          assistantName: aName,
          pendingAssistantContent: pending == null
              ? ''
              : _contextBuilder.contentForDirector(pending),
          userName: userName,
          newUserMessageText: userMessage.content,
        );
        g = g.copyWith(
          pendingCapAssistantMessageId: null,
          assistantMessagesThisRound: 0,
        );
        await groupChatProvider.persistGroupState(g);
      } else {
        directorUserContent = _contextBuilder.buildUserTurnE1(
          userName: userName,
          userMessageText: userMessage.content,
        );
        g = g.copyWith(assistantMessagesThisRound: 0);
        await groupChatProvider.persistGroupState(g);
      }

      directorUserContent = await _maybeInjectRoster(
        g,
        directorUserContent,
        isHumanUserTurn: true,
      );

      await _directorLoop(
        group: g,
        directorUserContent: directorUserContent,
        inputData: inputData,
      );
    } finally {
      _busy = false;
      onMessagesChanged();
    }
  }

  Future<void> _directorLoop({
    required GroupChat group,
    required String directorUserContent,
    ChatInputData? inputData,
  }) async {
    var g = groupChatProvider.getById(group.id) ?? group;
    var nextContent = directorUserContent;
    final userName = userProvider.name.trim().isEmpty
        ? 'User'
        : userProvider.name.trim();

    while (!_stopRequested) {
      g = groupChatProvider.getById(g.id) ?? g;
      final assistantIds = groupChatProvider.assistantIdsOf(g.id);
      if (assistantIds.isEmpty) break;

      final roster = assistantProvider.assistants
          .where((a) => assistantIds.contains(a.id))
          .toList();
      final memberNames = [userName, ...roster.map((a) => a.name)];

      DirectorDecision decision;
      try {
        decision = await _directorRunner.run(
          group: g,
          newUserContent: nextContent,
          rosterAssistants: roster,
          userName: userName,
          memberNames: memberNames,
          settings: settingsProvider,
          modelSupportsTools: _modelSupportsTools,
        );
      } on DirectorSoftError catch (e) {
        if (e.kind == DirectorSoftErrorKind.noModel) {
          onUiFeedback('groupChatNoDirectorModel');
        } else {
          onUiFeedback('groupChatDirectorModelNoTools');
        }
        return;
      } on TimeoutException {
        onUiFeedback('groupChatDirectorTimeout');
        return;
      } catch (e) {
        debugPrint('[GroupChatOrchestrator] director error: $e');
        onUiFeedback('groupChatDirectorError');
        return;
      }

      if (_stopRequested) return;
      if (decision.kind == DirectorDecisionKind.endTurn ||
          decision.assistantId == null) {
        return;
      }

      final speakerId = decision.assistantId!;
      final speaker = roster.where((a) => a.id == speakerId).firstOrNull;
      if (speaker == null) {
        debugPrint('[GroupChatOrchestrator] unknown speaker $speakerId');
        return;
      }

      // Cap check before speaking
      g = groupChatProvider.getById(g.id) ?? g;
      if (g.assistantMessagesThisRound >= g.maxAssistantMessagesPerRound) {
        return;
      }

      final assistantMsg = await _runAssistantTurn(
        group: g,
        speaker: speaker,
        inputData: inputData,
      );
      if (assistantMsg == null || _stopRequested) return;

      g = groupChatProvider.getById(g.id) ?? g;
      final count = g.assistantMessagesThisRound + 1;
      if (count >= g.maxAssistantMessagesPerRound) {
        // Do not send last assistant to director; set pending cap.
        g = g.copyWith(
          assistantMessagesThisRound: count,
          pendingCapAssistantMessageId: assistantMsg.id,
        );
        await groupChatProvider.persistGroupState(g);
        return;
      }

      g = g.copyWith(assistantMessagesThisRound: count);
      await groupChatProvider.persistGroupState(g);

      nextContent = _contextBuilder.buildAssistantTurnE2(
        assistantName: speaker.name,
        assistantContent: _contextBuilder.contentForDirector(assistantMsg),
      );
      nextContent = await _maybeInjectRoster(
        g,
        nextContent,
        isHumanUserTurn: false,
      );
      inputData = null; // only first turn may carry media
    }
  }

  Future<String> _maybeInjectRoster(
    GroupChat group,
    String content, {
    required bool isHumanUserTurn,
  }) async {
    final history = await chatService.repo.getDirectorMessages(group.id);
    final userTurnCount =
        _contextBuilder.countHumanUserTurns(history) +
        (isHumanUserTurn ? 1 : 0);
    final directorUserMsgCount =
        _contextBuilder.countDirectorUserMessages(history) + 1;
    final isFirstHuman =
        isHumanUserTurn && _contextBuilder.countHumanUserTurns(history) == 0;

    final inject = _contextBuilder.maybeAppendRoster(
      mode: group.assistantDetailInjectionMode,
      n: group.assistantDetailInjectionN,
      isHumanUserTurn: isHumanUserTurn,
      isFirstHumanUser: isFirstHuman,
      userTurnCount: userTurnCount,
      directorUserMsgCount: directorUserMsgCount,
    );
    if (!inject) return content;

    final assistantIds = groupChatProvider.assistantIdsOf(group.id);
    final roster = assistantProvider.assistants
        .where((a) => assistantIds.contains(a.id))
        .toList();
    final block = _contextBuilder.buildRosterBlock(roster);
    return '$content\n\n$block';
  }

  Future<ChatMessage?> _runAssistantTurn({
    required GroupChat group,
    required Assistant speaker,
    ChatInputData? inputData,
  }) async {
    // Force-disable proactive care for group (do not mutate stored assistant).
    final effective = speaker.copyWith(enableProactiveCare: false);

    final providerKey =
        (effective.chatModelProvider ?? settingsProvider.currentModelProvider)
            ?.trim();
    final modelId = (effective.chatModelId ?? settingsProvider.currentModelId)
        ?.trim();
    if (providerKey == null ||
        providerKey.isEmpty ||
        modelId == null ||
        modelId.isEmpty) {
      onUiFeedback('groupChatAssistantNoModel');
      return null;
    }

    final conversation =
        chatService.getConversation(group.conversationId) ??
        Conversation(
          id: group.conversationId,
          title: group.name,
          conversationKind: Conversation.kindGroup,
        );

    final publicMessages = chatService.getMessages(group.conversationId);
    final assistantsById = {
      for (final a in assistantProvider.assistants) a.id: a,
    };
    final userName = userProvider.name.trim().isEmpty
        ? 'User'
        : userProvider.name.trim();

    final privateMessages = _privateBuilder.build(
      conversation: conversation,
      publicMessages: publicMessages,
      speaker: effective,
      userName: userName,
      assistantsById: assistantsById,
    );

    final placeholder = await messageGenerationService
        .createAssistantPlaceholder(
          conversationId: group.conversationId,
          modelId: modelId,
          providerKey: providerKey,
          speakerAssistantId: effective.id,
        );
    onMessagesChanged();

    final done = Completer<void>();
    _activeStreamKey = placeholder.id;

    streamController.toolParts.remove(placeholder.id);

    await _pipeline.executeAssistantResponse(
      assistantMessage: placeholder,
      providerKey: providerKey,
      modelId: modelId,
      context: ModelExecutionContext(
        conversation: conversation,
        settings: settingsProvider,
        assistant: effective,
        approvalService: approvalService,
        askUserService: askUserService,
        versionSelections: conversation.versionSelections,
      ),
      completeMessages: privateMessages,
      inputData: inputData,
      generateTitleOnFinish: false,
      onStreamComplete: () {
        if (!done.isCompleted) done.complete();
      },
    );

    await done.future;
    _activeStreamKey = null;
    await groupChatProvider.touchUpdatedAt(group.id);
    onMessagesChanged();

    final msgs = chatService.getMessages(group.conversationId);
    for (final m in msgs.reversed) {
      if (m.id == placeholder.id) return m;
    }
    return placeholder;
  }

  bool _modelSupportsTools(String providerKey, String modelId) {
    try {
      final cfg = settingsProvider.getProviderConfig(providerKey);
      final ov = cfg.modelOverrides[modelId];
      if (ov is Map) {
        final abs = ov['abilities'];
        if (abs is List) {
          return abs.map((e) => e.toString()).contains('tool');
        }
      }
    } catch (e) {
      debugPrint('[GroupChatOrchestrator] modelSupportsTools: $e');
    }
    // Default: assume tool-capable models unless overrides say otherwise.
    // Prefer false-negative? Design says soft-error if no tools — be lenient
    // when override missing so global defaults still work.
    return true;
  }
}
