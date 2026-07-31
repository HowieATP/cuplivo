import 'dart:async';
import 'dart:io' show File;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/models/assistant.dart';
import '../../../core/models/chat_input_data.dart';
import '../../../core/models/chat_message.dart';
import '../../../core/providers/assistant_provider.dart';
import '../../../core/providers/group_chat_provider.dart';
import '../../../core/providers/settings_provider.dart';
import '../../../core/providers/user_provider.dart';
import '../../../core/services/chat/chat_service.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/ios_tactile.dart';
import '../../../shared/widgets/snackbar.dart';
import '../../../theme/app_font_weights.dart';
import '../../../utils/sandbox_path_resolver.dart';
import '../../home/controllers/chat_controller.dart';
import '../../home/controllers/generation_controller.dart';
import '../../home/controllers/stream_controller.dart' as stream_ctrl;
import '../../home/services/ask_user_interaction_service.dart';
import '../../home/services/message_builder_service.dart';
import '../../home/services/message_generation_service.dart';
import '../../home/services/tool_approval_service.dart';
import '../../home/widgets/chat_input_bar.dart';
import '../controllers/group_chat_orchestrator.dart';
import '../controllers/group_chat_stream_executor.dart';
import '../models/chat_input_mode.dart';
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

  late ChatService _chatService;
  late stream_ctrl.StreamController _streamController;
  late ChatController _chatController;
  late MessageBuilderService _messageBuilderService;
  late GenerationController _generationController;
  late MessageGenerationService _messageGenerationService;
  late GroupChatStreamExecutor _streamExecutor;
  late GroupChatOrchestrator _orchestrator;

  List<ChatMessage> _messages = [];
  bool _loading = false;
  bool _initialized = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    _chatService = context.read<ChatService>();
    _streamController = stream_ctrl.StreamController(
      chatService: _chatService,
      onStateChanged: () {
        if (mounted) setState(() => _reloadMessages());
      },
      getSettingsProvider: () => context.read<SettingsProvider>(),
      getCurrentConversationId: () {
        final g = context.read<GroupChatProvider>().getById(widget.groupChatId);
        return g?.conversationId;
      },
    );
    _chatController = ChatController(chatService: _chatService);
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
      getTitleForLocale: (_) => 'Group',
    );
    _messageGenerationService = MessageGenerationService(
      chatService: _chatService,
      messageBuilderService: _messageBuilderService,
      generationController: _generationController,
      streamController: _streamController,
      contextProvider: context,
    );
    _streamExecutor = GroupChatStreamExecutor(
      chatService: _chatService,
      streamController: _streamController,
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
      streamExecutor: _streamExecutor,
      approvalService: context.read<ToolApprovalService>(),
      askUserService: context.read<AskUserInteractionService>(),
      onUiFeedback: _onUiFeedback,
      onMessagesChanged: () {
        if (mounted) setState(() => _reloadMessages());
      },
    );
    _reloadMessages();
  }

  void _reloadMessages() {
    final g = context.read<GroupChatProvider>().getById(widget.groupChatId);
    if (g == null) {
      _messages = [];
      return;
    }
    _messages = List.of(_chatService.getMessages(g.conversationId));
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
    _streamExecutor.dispose();
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
      _reloadMessages();
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
          _reloadMessages();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final gp = context.watch<GroupChatProvider>();
    final group = gp.getById(widget.groupChatId);
    final assistants = context.watch<AssistantProvider>().assistants;
    final byId = {for (final a in assistants) a.id: a};

    if (group == null) {
      return Scaffold(
        appBar: AppBar(title: Text(l10n.groupChatMyGroupChats)),
        body: Center(child: Text(l10n.groupChatNotFound)),
      );
    }

    // Refresh messages when provider notifies
    _reloadMessages();

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
            child: _messages.isEmpty
                ? Center(
                    child: Text(
                      l10n.groupChatEmptyConversation,
                      style: TextStyle(
                        color: cs.onSurface.withValues(alpha: 0.55),
                      ),
                    ),
                  )
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
                    itemCount: _messages.length,
                    itemBuilder: (context, index) {
                      final msg = _messages[index];
                      final speaker = msg.role == 'assistant'
                          ? byId[msg.speakerAssistantId]
                          : null;
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: _GroupMessageBubble(
                          message: msg,
                          speaker: speaker,
                        ),
                      );
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

class _GroupMessageBubble extends StatelessWidget {
  const _GroupMessageBubble({required this.message, this.speaker});
  final ChatMessage message;
  final Assistant? speaker;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isUser = message.role == 'user';
    final name = isUser
        ? context.watch<UserProvider>().name
        : (speaker?.name ?? message.speakerAssistantId ?? 'Assistant');
    final avatar = isUser ? null : speaker?.avatar;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _avatar(context, cs, name, avatar, isUser),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                name,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: AppFontWeights.emphasis,
                  color: cs.onSurface.withValues(alpha: 0.7),
                ),
              ),
              const SizedBox(height: 4),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: isUser
                      ? cs.primary.withValues(alpha: 0.10)
                      : cs.surfaceContainerHighest.withValues(alpha: 0.45),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: SelectableText(
                  message.content.isEmpty && message.isStreaming
                      ? '…'
                      : message.content,
                  style: const TextStyle(fontSize: 15, height: 1.4),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _avatar(
    BuildContext context,
    ColorScheme cs,
    String name,
    String? avatar,
    bool isUser,
  ) {
    final a = avatar?.trim() ?? '';
    if (!isUser && a.isNotEmpty && !kIsWeb) {
      final path = SandboxPathResolver.fix(a);
      final f = File(path);
      if (f.existsSync()) {
        return ClipOval(
          child: Image.file(f, width: 32, height: 32, fit: BoxFit.cover),
        );
      }
    }
    return CircleAvatar(
      radius: 16,
      backgroundColor: cs.primary.withValues(alpha: 0.12),
      child: Text(
        name.isNotEmpty ? name.characters.first : '?',
        style: TextStyle(fontSize: 13, color: cs.primary),
      ),
    );
  }
}
