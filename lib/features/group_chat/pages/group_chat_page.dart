import 'dart:async';

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:scrollview_observer/scrollview_observer.dart';

import '../../../core/models/assistant.dart';
import '../../../core/models/chat_input_data.dart';
import '../../../core/models/chat_message.dart';
import '../../../core/providers/assistant_provider.dart';
import '../../../core/providers/group_chat_provider.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../core/providers/user_provider.dart';
import '../../../core/services/chat/chat_service.dart';
import '../../../core/services/generation_engine.dart';
import '../../../desktop/message_edit_dialog.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/ios_tactile.dart';
import '../../../shared/widgets/snackbar.dart';
import '../../chat/models/message_edit_result.dart';
import '../../chat/widgets/message_edit_sheet.dart';
import '../../chat/widgets/message_more_sheet.dart';
import '../../home/controllers/chat_controller.dart';
import '../../home/controllers/generation_controller.dart';
import '../../home/controllers/stream_controller.dart' as stream_ctrl;
import '../../home/services/ask_user_interaction_service.dart';
import '../../home/services/message_builder_service.dart';
import '../../home/services/message_generation_service.dart';
import '../../home/services/tool_approval_service.dart';
import '../../home/widgets/chat_input_bar.dart';
import '../../home/widgets/message_list_view.dart';
import '../controllers/group_chat_orchestrator.dart';
import '../models/chat_input_mode.dart';
import '../services/group_chat_slot_runner.dart';
import 'group_chat_settings_page.dart';

class GroupChatPage extends StatefulWidget {
  const GroupChatPage({super.key, required this.groupChatId});
  final String groupChatId;

  @override
  State<GroupChatPage> createState() => _GroupChatPageState();
}

class _GroupChatPageState extends State<GroupChatPage> {
  final _inputController = TextEditingController();
  final _scrollController = ScrollController();
  final _inputFocus = FocusNode();
  final _isProcessingFiles = ValueNotifier<bool>(false);
  final _translations = <String, TranslationUiState>{};

  late ListObserverController _observerController;
  late ChatService _chatService;
  late stream_ctrl.StreamController _streamController;
  late ChatController _chatController;
  late MessageBuilderService _messageBuilderService;
  late GenerationController _generationController;
  late MessageGenerationService _messageGenerationService;
  late GroupChatSlotRunner _slotRunner;
  late GroupChatOrchestrator _orchestrator;

  bool _loading = false;
  bool _initialized = false;

  bool get _isDesktop =>
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.linux;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    _observerController = ListObserverController(controller: _scrollController);
    _chatService = context.read<ChatService>();
    _streamController = stream_ctrl.StreamController(
      chatService: _chatService,
      onStateChanged: () {
        if (mounted) {
          _refreshList();
          setState(() {});
        }
      },
      getSettingsProvider: () => context.read<SettingsProvider>(),
      getCurrentConversationId: () {
        final g = context.read<GroupChatProvider>().getById(widget.groupChatId);
        return g?.conversationId;
      },
    );
    _chatController = ChatController(chatService: _chatService);
    _chatController.addListener(_onChatControllerChanged);
    _messageBuilderService = MessageBuilderService(
      chatService: _chatService,
      contextProvider: context,
    );
    _generationController = GenerationController(
      chatService: _chatService,
      chatController: _chatController,
      streamController: _streamController,
      messageBuilderService: _messageBuilderService,
      contextProvider: context,
      onStateChanged: () {
        if (mounted) setState(() {});
      },
      getTitleForLocale: (ctx) =>
          AppLocalizations.of(ctx)!.groupChatDefaultName,
    );
    _messageGenerationService = MessageGenerationService(
      chatService: _chatService,
      messageBuilderService: _messageBuilderService,
      generationController: _generationController,
      streamController: _streamController,
      contextProvider: context,
    );
    _slotRunner = GroupChatSlotRunner(
      engine: context.read<GenerationEngine>(),
      streamController: _streamController,
      onTruncationWarning: (reason) {
        if (!mounted) return;
        final l10n = AppLocalizations.of(context)!;
        final reasonText = reason == 'max_tokens'
            ? l10n.truncationReasonMaxTokens
            : l10n.truncationReasonContextExceeded;
        showAppSnackBar(
          context,
          message: l10n.responseTruncated(reasonText),
          type: NotificationType.warning,
          duration: const Duration(seconds: 30),
        );
      },
    );
    _orchestrator = GroupChatOrchestrator(
      chatService: _chatService,
      groupChatProvider: context.read<GroupChatProvider>(),
      assistantProvider: context.read<AssistantProvider>(),
      settingsProvider: context.read<SettingsProvider>(),
      userProvider: context.read<UserProvider>(),
      streamController: _streamController,
      generationController: _generationController,
      messageGenerationService: _messageGenerationService,
      slotRunner: _slotRunner,
      approvalService: context.read<ToolApprovalService>(),
      askUserService: context.read<AskUserInteractionService>(),
      onUiFeedback: _onUiFeedback,
      onMessagesChanged: () {
        if (mounted) {
          _refreshList();
          setState(() {});
        }
      },
    );
    _bindConversation();
  }

  void _onChatControllerChanged() {
    if (mounted) setState(() {});
  }

  void _bindConversation() {
    final g = context.read<GroupChatProvider>().getById(widget.groupChatId);
    if (g == null) return;
    final convo = _chatService.getConversation(g.conversationId);
    if (convo != null) {
      _chatController.setCurrentConversation(convo);
    }
    // KNOWN GAP: normal chat restores per-message UI state (reasoning text /
    // timers, tool events, content splits, gemini thought signatures) on
    // conversation open via home_view_model._restoreMessageUiState ->
    // StreamController.restoreMessageUiState, which copies the persisted
    // message-row fields back into the in-memory maps the widgets read.
    // This page never calls it, so reopening a group chat loses the
    // reasoning panels of historical assistant messages. The equivalent
    // hook here is _bindConversation (NOT _refreshList, which would clobber
    // live streaming state). Not fixed yet — tracked as a comment per user
    // decision.
  }

  void _refreshList() {
    final g = context.read<GroupChatProvider>().getById(widget.groupChatId);
    if (g == null) return;
    final convo = _chatService.getConversation(g.conversationId);
    if (convo != null) {
      _chatController.updateCurrentConversation(convo);
    }
    _chatController.loadVersionSelections();
    _chatController.reloadMessages();
  }

  void _onUiFeedback(String key) {
    if (!mounted) return;
    final l10n = AppLocalizations.of(context)!;
    final map = <String, String>{
      'groupChatNoAssistants': l10n.groupChatNoAssistants,
      'groupChatNoDirectorModel': l10n.groupChatNoDirectorModel,
      'groupChatDirectorModelNoTools': l10n.groupChatDirectorModelNoTools,
      'groupChatDirectorTimeout': l10n.groupChatDirectorTimeout,
      'groupChatDirectorError': l10n.groupChatDirectorError,
      'groupChatAssistantNoModel': l10n.groupChatAssistantNoModel,
    };
    showAppSnackBar(context, message: map[key] ?? key);
  }

  @override
  void dispose() {
    _orchestrator.requestStop();
    _streamController.dispose();
    _chatController.removeListener(_onChatControllerChanged);
    _chatController.dispose();
    _isProcessingFiles.dispose();
    _inputController.dispose();
    _scrollController.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  Future<void> _send(ChatInputData data) async {
    final text = data.text.trim();
    if (text.isEmpty && data.imagePaths.isEmpty && data.documents.isEmpty) {
      return;
    }
    final gp = context.read<GroupChatProvider>();
    final group = gp.getById(widget.groupChatId);
    if (group == null) return;

    setState(() => _loading = true);
    try {
      final userMsg = await _chatService.addMessage(
        conversationId: group.conversationId,
        role: 'user',
        content: text,
      );
      await gp.touchUpdatedAt(group.id);
      _refreshList();
      setState(() {});
      await _orchestrator.handleUserMessage(
        group: group,
        userMessage: userMsg,
        inputData: data,
      );
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
        _refreshList();
      }
    }
  }

  Assistant? _resolveSpeaker(ChatMessage m) {
    if (m.role != 'assistant') return null;
    final id = m.speakerAssistantId;
    if (id == null || id.isEmpty) return null;
    return context.read<AssistantProvider>().getById(id);
  }

  Future<void> _onVersionChange(String groupId, int version) async {
    await _chatController.setSelectedVersion(groupId, version);
    _refreshList();
  }

  Future<void> _onRegenerate(ChatMessage message) async {
    final g = context.read<GroupChatProvider>().getById(widget.groupChatId);
    if (g == null) return;
    setState(() => _loading = true);
    try {
      await _orchestrator.regenerateAssistantMessage(
        group: g,
        message: message,
      );
    } finally {
      if (mounted) {
        setState(() => _loading = false);
        _refreshList();
      }
    }
  }

  Future<void> _onResend(ChatMessage message) async {
    final g = context.read<GroupChatProvider>().getById(widget.groupChatId);
    if (g == null) return;
    setState(() => _loading = true);
    try {
      await _orchestrator.resendUserMessage(group: g, userMessage: message);
    } finally {
      if (mounted) {
        setState(() => _loading = false);
        _refreshList();
      }
    }
  }

  Future<void> _onEdit(ChatMessage message) async {
    if (!mounted) return;
    final Future<MessageEditResult?> future = _isDesktop
        ? showMessageEditDesktopDialog(context, message: message)
        : showMessageEditSheet(context, message: message);
    final result = await future;
    if (result == null || !mounted) return;

    final g = context.read<GroupChatProvider>().getById(widget.groupChatId);
    if (g == null) return;

    final keepOriginalTimestamp =
        message.role == 'assistant' || !result.shouldSend;
    final newMsg = await _chatService.appendMessageVersion(
      messageId: message.id,
      content: result.content,
      timestamp: keepOriginalTimestamp ? message.timestamp : null,
    );
    if (newMsg == null) return;
    final gid = newMsg.groupId ?? newMsg.id;
    await _chatService.setSelectedVersion(
      g.conversationId,
      gid,
      newMsg.version,
    );
    _refreshList();

    if (!result.shouldSend) {
      setState(() {});
      return;
    }

    setState(() => _loading = true);
    try {
      if (newMsg.role == 'assistant') {
        await _orchestrator.regenerateAssistantMessage(
          group: g,
          message: newMsg,
        );
      } else if (newMsg.role == 'user') {
        await _orchestrator.resendUserMessage(group: g, userMessage: newMsg);
      }
    } finally {
      if (mounted) {
        setState(() => _loading = false);
        _refreshList();
      }
    }
  }

  Future<void> _onDelete(
    ChatMessage message,
    Map<String, List<ChatMessage>> byGroup, {
    required bool allVersions,
  }) async {
    final g = context.read<GroupChatProvider>().getById(widget.groupChatId);
    if (g == null) return;
    await _orchestrator.deleteMessageVersions(
      group: g,
      message: message,
      allVersions: allVersions,
      byGroup: byGroup,
    );
    _refreshList();
    setState(() {});
  }

  Future<void> _clearContext() async {
    final g = context.read<GroupChatProvider>().getById(widget.groupChatId);
    if (g == null) return;
    final updated = await _chatService.toggleTruncateAtTail(g.conversationId);
    if (updated != null && mounted) {
      _refreshList();
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final gp = context.watch<GroupChatProvider>();
    final group = gp.getById(widget.groupChatId);

    if (group == null) {
      return Scaffold(
        appBar: AppBar(title: Text(l10n.groupChatMyGroupChats)),
        body: Center(child: Text(l10n.groupChatNotFound)),
      );
    }

    final messages = _chatController.collapsedMessages;
    final byGroup = _chatController.groupedMessages;

    return Scaffold(
      appBar: AppBar(
        leading: IosIconButton(
          icon: Lucide.ArrowLeft,
          color: cs.onSurface,
          size: 22,
          onTap: () => Navigator.of(context).maybePop(),
        ),
        title: Text(group.name),
        actions: [
          IosIconButton(
            icon: Lucide.Menu,
            color: cs.onSurface,
            size: 22,
            semanticLabel: l10n.groupChatSettingsTitle,
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => GroupChatSettingsPage(groupChatId: group.id),
                ),
              );
            },
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: messages.isEmpty
                ? Center(
                    child: Text(
                      l10n.groupChatEmptyConversation,
                      style: TextStyle(
                        color: cs.onSurface.withValues(alpha: 0.55),
                      ),
                    ),
                  )
                : MessageListView(
                    scrollController: _scrollController,
                    observerController: _observerController,
                    messages: messages,
                    byGroup: byGroup,
                    versionSelections: _chatController.versionSelections,
                    reasoning: _streamController.reasoning,
                    reasoningSegments: _streamController.reasoningSegments,
                    contentSplits: _streamController.contentSplits,
                    toolParts: _streamController.toolParts,
                    translations: _translations,
                    selecting: false,
                    selectedItems: const <String>{},
                    dividerPadding: EdgeInsets.zero,
                    isProcessingFiles: _isProcessingFiles,
                    streamingContentNotifier:
                        _streamController.streamingContentNotifier,
                    resolveSpeaker: _resolveSpeaker,
                    hideMoreActions: () => {
                      MessageMoreAction.multiAI,
                      MessageMoreAction.fork,
                      MessageMoreAction.selectMessages,
                    },
                    onVersionChange: _onVersionChange,
                    onRegenerateMessage: (m) {
                      unawaited(_onRegenerate(m));
                    },
                    onResendMessage: (m) {
                      unawaited(_onResend(m));
                    },
                    onEditMessage: (m) {
                      unawaited(_onEdit(m));
                    },
                    onDeleteMessage: (m, bg) =>
                        _onDelete(m, bg, allVersions: false),
                    onDeleteAllVersions: (m, bg) =>
                        _onDelete(m, bg, allVersions: true),
                    onToggleReasoning: (id) {
                      final r = _streamController.reasoning[id];
                      if (r == null) return;
                      r.expanded = !r.expanded;
                      setState(() {});
                    },
                    onToggleReasoningSegment: (id, index) {
                      final segs = _streamController.reasoningSegments[id];
                      if (segs == null || index < 0 || index >= segs.length) {
                        return;
                      }
                      segs[index].expanded = !segs[index].expanded;
                      setState(() {});
                    },
                  ),
          ),
          SafeArea(
            top: false,
            child: ChatInputBar(
              controller: _inputController,
              focusNode: _inputFocus,
              loading: _loading || _orchestrator.isBusy,
              mode: ChatInputMode.groupChat,
              showMcpButton: false,
              supportsReasoning: false,
              showMoreButton: false,
              showQuickPhraseButton: false,
              onStop: () {
                _orchestrator.requestStop();
                setState(() => _loading = false);
              },
              onClearContext: () {
                unawaited(_clearContext());
              },
              onSend: (data) async {
                unawaited(_send(data));
                return ChatInputSubmissionResult.sent;
              },
            ),
          ),
        ],
      ),
    );
  }
}
