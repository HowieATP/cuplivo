import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/models/assistant.dart';
import '../../../core/models/conversation.dart';
import '../../../core/providers/assistant_provider.dart';
import '../../../core/providers/workspace_provider.dart';
import '../../../core/services/chat/chat_service.dart';
import '../../../core/services/workspace/workspace_execution_context.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/ios_form_text_field.dart';
import '../../../shared/widgets/ios_tactile.dart';
import '../../../shared/widgets/ios_tile_button.dart';
import '../../../shared/widgets/snackbar.dart';
import '../../../theme/app_font_weights.dart';
import '../../../utils/platform_utils.dart';
import 'workspace_directory_picker.dart';

/// Opens a directory-only editor for either the assistant default or a
/// conversation override. Workspace enablement and binding stay in the
/// existing workspace bind sheet.
Future<void> showWorkspaceDirectorySettings(
  BuildContext context, {
  required String assistantId,
  String? conversationId,
}) async {
  final assistants = context.read<AssistantProvider>();
  final workspaces = context.read<WorkspaceProvider>();
  await workspaces.init();
  if (!context.mounted) return;

  final assistant = assistants.getById(assistantId);
  final workspaceId = assistant?.workspaceId;
  if (assistant == null ||
      !assistant.workspaceEnabled ||
      workspaceId == null ||
      workspaces.getById(workspaceId) == null) {
    debugPrint(
      'Workspace directory settings unavailable: assistant is not bound to '
      'an enabled workspace.',
    );
    return;
  }

  final content = _WorkspaceDirectorySettings(
    assistantId: assistantId,
    workspaceId: workspaceId,
    conversationId: conversationId,
  );
  if (PlatformUtils.isDesktopTarget) {
    await showDialog<void>(
      context: context,
      builder: (_) => Dialog(
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: content,
        ),
      ),
    );
    return;
  }

  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => content,
  );
}

class _WorkspaceDirectorySettings extends StatefulWidget {
  const _WorkspaceDirectorySettings({
    required this.assistantId,
    required this.workspaceId,
    this.conversationId,
  });

  final String assistantId;
  final String workspaceId;
  final String? conversationId;

  @override
  State<_WorkspaceDirectorySettings> createState() =>
      _WorkspaceDirectorySettingsState();
}

class _WorkspaceDirectorySettingsState
    extends State<_WorkspaceDirectorySettings> {
  final TextEditingController _directoryController = TextEditingController();
  bool _initialized = false;
  bool _saving = false;

  bool get _conversationMode => widget.conversationId != null;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _syncDirectoryText(_assistant());
    _initialized = true;
  }

  @override
  void dispose() {
    _directoryController.dispose();
    super.dispose();
  }

  Assistant? _assistant() =>
      context.read<AssistantProvider>().getById(widget.assistantId);

  Conversation? _conversation() {
    final id = widget.conversationId;
    if (id == null) return null;
    return context.read<ChatService>().getConversation(id);
  }

  String _assistantDefault(Assistant? assistant) =>
      assistant?.workspaceDefaultDirectories[widget.workspaceId] ??
      '/workspace';

  void _syncDirectoryText(Assistant? assistant) {
    _directoryController.text = _conversationMode
        ? _conversation()?.workspaceDirectoryOverrides[widget.workspaceId] ??
              _assistantDefault(assistant)
        : _assistantDefault(assistant);
  }

  Future<void> _saveDirectory(String raw) async {
    if (_saving) return;
    final l10n = AppLocalizations.of(context)!;
    final workspaces = context.read<WorkspaceProvider>();
    final chatService = _conversationMode ? context.read<ChatService>() : null;
    final assistantProvider = context.read<AssistantProvider>();
    final workspace = workspaces.getById(widget.workspaceId);
    if (workspace == null) return;

    setState(() => _saving = true);
    try {
      final normalized = normalizeWorkspaceDirectory(raw);
      await ensureWorkspaceWorkingDirectory(
        context: WorkspaceExecutionContext(
          workspace: workspace,
          workingDirectory: normalized,
        ),
        workspaces: workspaces,
      );
      if (_conversationMode) {
        await chatService!.setConversationWorkspaceDirectoryOverride(
          widget.conversationId!,
          widget.workspaceId,
          normalized,
        );
      } else {
        final assistant = assistantProvider.getById(widget.assistantId);
        if (assistant == null) return;
        final directories = Map<String, String>.of(
          assistant.workspaceDefaultDirectories,
        )..[widget.workspaceId] = normalized;
        await assistantProvider.updateAssistant(
          assistant.copyWith(workspaceDefaultDirectories: directories),
        );
      }
      if (!mounted) return;
      _directoryController.text = normalized;
      showAppSnackBar(
        context,
        message: l10n.workspaceDirectorySaved,
        type: NotificationType.success,
      );
      setState(() {});
    } catch (error, stackTrace) {
      debugPrint(
        'Failed to save workspace working directory: $error\n$stackTrace',
      );
      if (!mounted) return;
      showAppSnackBar(
        context,
        message: l10n.workspaceDirectorySaveFailed(error.toString()),
        type: NotificationType.error,
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _browse() async {
    if (_saving) return;
    final workspaces = context.read<WorkspaceProvider>();
    final workspace = workspaces.getById(widget.workspaceId);
    if (workspace == null) return;

    String initialDirectory;
    try {
      initialDirectory = normalizeWorkspaceDirectory(_directoryController.text);
    } on WorkspacePathException catch (error, stackTrace) {
      debugPrint(
        'Workspace directory picker reset an unsafe initial path: '
        '$error\n$stackTrace',
      );
      initialDirectory = '/workspace';
    }
    if (!mounted) return;
    final selected = await showWorkspaceDirectoryPicker(
      context,
      workspace: workspace,
      workspaces: workspaces,
      initialDirectory: initialDirectory,
    );
    if (selected == null || !mounted) return;
    setState(() => _directoryController.text = selected);
  }

  Future<void> _useAssistantDefault() async {
    if (!_conversationMode || _saving) return;
    setState(() => _saving = true);
    try {
      await context
          .read<ChatService>()
          .clearConversationWorkspaceDirectoryOverride(
            widget.conversationId!,
            widget.workspaceId,
          );
      if (!mounted) return;
      _syncDirectoryText(_assistant());
      showAppSnackBar(
        context,
        message: AppLocalizations.of(context)!.workspaceDirectorySaved,
        type: NotificationType.success,
      );
      setState(() {});
    } catch (error, stackTrace) {
      debugPrint(
        'Failed to restore assistant working directory: $error\n$stackTrace',
      );
      if (!mounted) return;
      showAppSnackBar(
        context,
        message: AppLocalizations.of(
          context,
        )!.workspaceDirectorySaveFailed(error.toString()),
        type: NotificationType.error,
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    context.watch<AssistantProvider>();
    if (_conversationMode) context.watch<ChatService>();
    final workspace = context.watch<WorkspaceProvider>().getById(
      widget.workspaceId,
    );
    final hasOverride =
        _conversation()?.workspaceDirectoryOverrides.containsKey(
          widget.workspaceId,
        ) ==
        true;
    final enabled = workspace != null && !_saving;

    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          16,
          PlatformUtils.isDesktopTarget ? 12 : 10,
          16,
          20 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!PlatformUtils.isDesktopTarget) ...[
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: cs.onSurface.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              ),
              const SizedBox(height: 10),
            ],
            Row(
              children: [
                Expanded(
                  child: Text(
                    l10n.workspaceDirectoryPickerTitle,
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: AppFontWeights.emphasis,
                    ),
                  ),
                ),
                IosIconButton(
                  icon: Lucide.X,
                  semanticLabel: l10n.homePageCancel,
                  onTap: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            const SizedBox(height: 12),
            IosFormTextField(
              label: _conversationMode
                  ? l10n.workspaceConversationDirectoryTitle
                  : l10n.workspaceDefaultDirectoryTitle,
              controller: _directoryController,
              hintText: l10n.workspaceDirectoryHint,
              enabled: enabled,
              inlineLabel: false,
              outerPadding: EdgeInsets.zero,
            ),
            if (_conversationMode) ...[
              const SizedBox(height: 6),
              Text(
                hasOverride
                    ? l10n.workspaceDirectoryOverride
                    : l10n.workspaceDirectoryInherited,
                style: TextStyle(
                  fontSize: 12,
                  color: cs.onSurface.withValues(alpha: 0.58),
                ),
              ),
            ],
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: IosTileButton(
                    label: l10n.workspaceDirectoryBrowse,
                    icon: Lucide.FolderOpen,
                    enabled: enabled,
                    onTap: _browse,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: IosTileButton(
                    label: l10n.workspaceDirectorySave,
                    icon: Lucide.Check,
                    enabled: enabled,
                    backgroundColor: cs.primary,
                    onTap: () => _saveDirectory(_directoryController.text),
                  ),
                ),
              ],
            ),
            if (_conversationMode && hasOverride) ...[
              const SizedBox(height: 10),
              IosTileButton(
                label: l10n.workspaceDirectoryUseAssistantDefault,
                icon: Lucide.RotateCcw,
                enabled: enabled,
                onTap: _useAssistantDefault,
              ),
            ],
            if (workspace != null) ...[
              const SizedBox(height: 10),
              Text(
                workspace.displayName,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12,
                  color: cs.onSurface.withValues(alpha: 0.55),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
