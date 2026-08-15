import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/providers/download_progress_store.dart';
import '../../../core/providers/input_status_provider.dart';
import '../../../core/services/chat/chat_service.dart';
import '../../../core/services/generation_engine.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/ios_tactile.dart';
import '../../../shared/widgets/image_mode_info_popover.dart';
import '../services/ask_user_interaction_service.dart';
import '../services/tool_approval_service.dart';
import 'image_generation_options.dart';

/// LivePanel (实时面板): unified transient-status surface pinned above the
/// conversation input bar. Hosts heterogeneous live entries — subagent jobs,
/// workspace downloads, and the image-mode / image-warning pills — sharing one
/// pill↔card design language (issue #307, ADR-0030).
///
/// Entry order: info pill, warning pill, download entries, subagent entries.
/// Every entry is conversation-scoped (keyed off `currentConversationId`);
/// the panel disappears when no entry exists.
class LivePanel extends StatefulWidget {
  const LivePanel({super.key, this.onOpenChild, this.imageGenController});

  /// Called with the child conversation id when the user taps 查看子对话 /
  /// 去回答 on a subagent entry.
  final ValueChanged<String>? onOpenChild;

  /// Shared image-generation options controller (home page owned, same
  /// instance as the input bar's). Drives the inline expanded options card;
  /// when null the panel creates its own (tests).
  final ImageGenerationOptionsController? imageGenController;

  @override
  State<LivePanel> createState() => _LivePanelState();
}

class _LivePanelState extends State<LivePanel> {
  Timer? _ticker;
  final _expandedJobIds = <String>{};
  final _expandedDownloadIds = <String>{};
  bool _expandedImageMode = false;
  final _imageModeInfoKey = GlobalKey(debugLabel: 'image-mode-info');
  final _chatModeInfoKey = GlobalKey(debugLabel: 'chat-mode-info');
  late final ImageGenerationOptionsController _imageGenController =
      widget.imageGenController ?? ImageGenerationOptionsController();

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (_activeJobs().isEmpty && _activeDownloads().isEmpty) return;
      setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  /// All running wait-mode jobs spawned by the current conversation.
  /// Concurrent `kelivo_handoff_sync` calls produce multiple jobs — every one
  /// gets its own pill/expanded card.
  List<GenerationSlot> _activeJobs() {
    final chatService = context.read<ChatService>();
    final parentId = chatService.currentConversationId;
    if (parentId == null) return const <GenerationSlot>[];
    final engine = context.read<GenerationEngine>();
    return engine
        .waitSlotsFor(parentId)
        .where((job) => job.status == SlotStatus.running)
        .toList();
  }

  List<DownloadJob> _activeDownloads() {
    final chatService = context.read<ChatService>();
    final parentId = chatService.currentConversationId;
    if (parentId == null) return const <DownloadJob>[];
    return context.read<DownloadProgressStore>().runningFor(parentId);
  }

  ToolApprovalRequest? _pendingApproval(GenerationSlot job) {
    final service = context.watch<ToolApprovalService>();
    for (final req in service.pendingRequests.values) {
      if (req.conversationId == job.conversationId) return req;
    }
    return null;
  }

  AskUserRequest? _pendingAskUser(GenerationSlot job) {
    final service = context.watch<AskUserInteractionService>();
    for (final req in service.pendingRequests.values) {
      if (req.conversationId == job.conversationId) return req;
    }
    return null;
  }

  Future<void> _confirmCancel(GenerationSlot job) async {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        backgroundColor: cs.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(l10n.subagentPanelCancelConfirmTitle),
        content: Text(l10n.subagentPanelCancelConfirmBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dctx).pop(false),
            child: Text(l10n.subagentPanelCancelConfirmKeep),
          ),
          TextButton(
            onPressed: () => Navigator.of(dctx).pop(true),
            child: Text(l10n.subagentPanelCancelConfirmAction),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    // Release any pending approval/ask_user the child is suspended on FIRST:
    // the child's generator is awaiting that completer with no in-flight
    // HTTP request, so token cancellation alone cannot unwind it.
    context.read<ToolApprovalService>().cancelForConversation(
      job.conversationId,
    );
    context.read<AskUserInteractionService>().cancelForConversation(
      job.conversationId,
    );
    context.read<GenerationEngine>().cancelConversation(job.conversationId);
  }

  @override
  Widget build(BuildContext context) {
    final jobs = _activeJobs();
    final downloads = _activeDownloads();
    final inputStatus = context.watch<InputStatusProvider>();
    final hasPills =
        inputStatus.imageModeActive ||
        inputStatus.imageModeDismissed ||
        inputStatus.imageWarningActive;
    if (jobs.isEmpty && downloads.isEmpty && !hasPills) {
      return const SizedBox.shrink();
    }

    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final base = isDark ? cs.surfaceContainerHighest : cs.surface;

    // The expansion flag is only meaningful while the image-mode pill renders.
    // Sync it here so a model switch (pill disappears) collapses the options
    // card instead of silently re-expanding it on the next activation.
    final showImageOptionsExpanded =
        _expandedImageMode && inputStatus.imageModeActive;
    if (showImageOptionsExpanded != _expandedImageMode) {
      _expandedImageMode = showImageOptionsExpanded;
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (inputStatus.imageModeActive) ...[
            _buildImageModePill(inputStatus, base, cs, l10n),
            if (showImageOptionsExpanded) ...[
              const SizedBox(height: 6),
              _buildImageOptionsCard(base),
            ],
            const SizedBox(height: 6),
          ] else if (inputStatus.imageModeDismissed) ...[
            _buildChatModePill(inputStatus, base, cs, l10n),
            const SizedBox(height: 6),
          ],
          if (inputStatus.imageWarningActive) ...[
            _buildPill(
              icon: Lucide.ImageOff,
              label: l10n.chatInputBarImageWarning,
              closeTooltip: l10n.chatInputBarDisableImageWarningTooltip,
              onClose: () => inputStatus.dismissImageWarning(),
              base: base,
              cs: cs,
            ),
            const SizedBox(height: 6),
          ],
          for (final download in downloads) ...[
            _buildDownloadCard(download, base, cs),
            if (download != downloads.last) const SizedBox(height: 6),
          ],
          if (downloads.isNotEmpty && jobs.isNotEmpty)
            const SizedBox(height: 6),
          for (final job in jobs) ...[
            _buildJobCard(context, job, base, cs, l10n),
            if (job != jobs.last) const SizedBox(height: 6),
          ],
        ],
      ),
    );
  }

  Widget _buildImageModePill(
    InputStatusProvider inputStatus,
    Color base,
    ColorScheme cs,
    AppLocalizations l10n,
  ) {
    return _buildPill(
      icon: Lucide.Brush,
      label: l10n.chatInputBarImageMode,
      base: base,
      cs: cs,
      onTap: () => setState(() => _expandedImageMode = !_expandedImageMode),
      infoButton: IosIconButton(
        key: _imageModeInfoKey,
        icon: Icons.info_outline,
        size: 16,
        color: cs.onSurfaceVariant,
        semanticLabel: l10n.chatInputBarImageModeInfoTooltip,
        onTap: () => unawaited(
          showImageModeInfoPopover(context, anchorKey: _imageModeInfoKey),
        ),
      ),
      trailing: [
        if (_imageGenController.customized)
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              color: cs.primary,
              shape: BoxShape.circle,
            ),
          ),
        Icon(
          _expandedImageMode
              ? Icons.keyboard_arrow_down
              : Icons.keyboard_arrow_up,
          size: 18,
          color: cs.onSurfaceVariant,
        ),
        const SizedBox(width: 2),
        IosIconButton(
          icon: Icons.close,
          size: 16,
          color: cs.onSurfaceVariant,
          semanticLabel: l10n.chatInputBarDisableImageModeTooltip,
          onTap: () {
            setState(() => _expandedImageMode = false);
            inputStatus.dismissImageMode();
          },
        ),
      ],
    );
  }

  Widget _buildChatModePill(
    InputStatusProvider inputStatus,
    Color base,
    ColorScheme cs,
    AppLocalizations l10n,
  ) {
    return _buildPill(
      icon: Lucide.MessageSquare,
      label: l10n.chatInputBarChatMode,
      base: base,
      cs: cs,
      onTap: () {
        inputStatus.restoreImageMode();
        setState(() => _expandedImageMode = true);
      },
      infoButton: IosIconButton(
        key: _chatModeInfoKey,
        icon: Icons.info_outline,
        size: 16,
        color: cs.onSurfaceVariant,
        semanticLabel: l10n.chatInputBarImageModeInfoTooltip,
        onTap: () => unawaited(
          showImageModeInfoPopover(context, anchorKey: _chatModeInfoKey),
        ),
      ),
    );
  }

  Widget _buildImageOptionsCard(Color base) {
    final maxHeight = MediaQuery.of(context).size.height * 0.55;
    return Container(
      decoration: BoxDecoration(
        color: base,
        borderRadius: BorderRadius.circular(12),
      ),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: SingleChildScrollView(
          child: ImageGenerationOptionsBody(
            controller: _imageGenController,
            onChanged: () => setState(() {}),
          ),
        ),
      ),
    );
  }

  Widget _buildPill({
    required IconData icon,
    required String label,
    required Color base,
    required ColorScheme cs,
    VoidCallback? onTap,
    Widget? infoButton,
    List<Widget> trailing = const <Widget>[],
    String? closeTooltip,
    VoidCallback? onClose,
  }) {
    return IosCardPress(
      borderRadius: BorderRadius.circular(12),
      baseColor: base,
      pressedScale: 0.99,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            Icon(icon, size: 14, color: cs.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: cs.onSurface,
                ),
              ),
            ),
            if (infoButton != null) ...[infoButton, const SizedBox(width: 2)],
            ...trailing,
            if (onClose != null) ...[
              const SizedBox(width: 2),
              IosIconButton(
                icon: Icons.close,
                size: 16,
                color: cs.onSurfaceVariant,
                semanticLabel: closeTooltip ?? label,
                onTap: onClose,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildDownloadCard(DownloadJob job, Color base, ColorScheme cs) {
    final showExpanded = _expandedDownloadIds.contains(job.id);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        IosCardPress(
          borderRadius: BorderRadius.circular(12),
          baseColor: base,
          pressedScale: 0.99,
          onTap: () => setState(() {
            if (!_expandedDownloadIds.add(job.id)) {
              _expandedDownloadIds.remove(job.id);
            }
          }),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                Icon(Lucide.Download, size: 14, color: cs.onSurfaceVariant),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '${_basename(job.displayPath)} · '
                    '${_formatElapsed(job.startedAt)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: cs.onSurface,
                    ),
                  ),
                ),
                Icon(
                  showExpanded
                      ? Icons.keyboard_arrow_down
                      : Icons.keyboard_arrow_up,
                  size: 18,
                  color: cs.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
        if (showExpanded)
          Container(
            decoration: BoxDecoration(
              color: base,
              borderRadius: BorderRadius.circular(12),
            ),
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
            child: _buildDownloadProgress(job, cs),
          ),
      ],
    );
  }

  Widget _buildDownloadProgress(DownloadJob job, ColorScheme cs) {
    final percent = job.percent;
    final fraction = (job.progress ?? 0).clamp(0.0, 1.0).toDouble();
    final detail = percent != null
        ? '$percent%'
        : _formatBytes(job.receivedBytes);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(999),
          child: SizedBox(
            height: 4,
            child: Stack(
              fit: StackFit.expand,
              children: [
                ColoredBox(color: cs.onSurface.withValues(alpha: 0.08)),
                Align(
                  alignment: Alignment.centerLeft,
                  child: FractionallySizedBox(
                    widthFactor: fraction,
                    child: ColoredBox(color: cs.primary),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 5),
        Text(
          detail,
          style: TextStyle(
            fontSize: 11,
            color: cs.onSurface.withValues(alpha: 0.56),
          ),
        ),
      ],
    );
  }

  Widget _buildJobCard(
    BuildContext context,
    GenerationSlot job,
    Color base,
    ColorScheme cs,
    AppLocalizations l10n,
  ) {
    final approval = _pendingApproval(job);
    final askUser = _pendingAskUser(job);
    final waitingInteraction = approval != null || askUser != null;
    final forceExpanded = waitingInteraction;
    final showExpanded =
        forceExpanded || _expandedJobIds.contains(job.conversationId);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        IosCardPress(
          borderRadius: BorderRadius.circular(12),
          baseColor: base,
          pressedScale: 0.99,
          onTap: waitingInteraction
              ? null
              : () => setState(() {
                  if (!_expandedJobIds.add(job.conversationId)) {
                    _expandedJobIds.remove(job.conversationId);
                  }
                }),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CupertinoActivityIndicator(),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    // {assistant name} · {elapsed} — no phase, no arrow
                    '${job.targetName ?? job.conversationId} · '
                    '${_formatElapsed(job.startedAt)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: cs.onSurface,
                    ),
                  ),
                ),
                if (!waitingInteraction)
                  Icon(
                    showExpanded
                        ? Icons.keyboard_arrow_down
                        : Icons.keyboard_arrow_up,
                    size: 18,
                    color: cs.onSurfaceVariant,
                  ),
                const SizedBox(width: 4),
                IosIconButton(
                  icon: Icons.close,
                  size: 16,
                  color: cs.onSurfaceVariant,
                  semanticLabel: l10n.subagentPanelCancelTooltip,
                  onTap: () => _confirmCancel(job),
                ),
              ],
            ),
          ),
        ),
        if (showExpanded)
          Container(
            decoration: BoxDecoration(
              color: base,
              borderRadius: BorderRadius.circular(12),
            ),
            child: _buildExpandedBody(context, job, approval, askUser),
          ),
      ],
    );
  }

  Widget _buildExpandedBody(
    BuildContext context,
    GenerationSlot job,
    ToolApprovalRequest? approval,
    AskUserRequest? askUser,
  ) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;

    final children = <Widget>[];
    if (approval != null) {
      children.add(
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              approval.toolName,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: cs.onSurface,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              _argsSummary(approval.arguments),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: IosCardPress(
                    borderRadius: BorderRadius.circular(10),
                    baseColor: cs.primaryContainer,
                    onTap: () => context.read<ToolApprovalService>().approve(
                      approval.toolCallId,
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text(
                        l10n.subagentPanelApprove,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: cs.onPrimaryContainer,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: IosCardPress(
                    borderRadius: BorderRadius.circular(10),
                    baseColor: cs.surfaceContainerHighest,
                    onTap: () => context.read<ToolApprovalService>().deny(
                      approval.toolCallId,
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text(
                        l10n.subagentPanelDeny,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: cs.onSurface,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      );
    } else if (askUser != null) {
      children.add(
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l10n.subagentPanelAskUserPending,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: cs.onSurface,
              ),
            ),
            const SizedBox(height: 8),
            IosCardPress(
              borderRadius: BorderRadius.circular(10),
              baseColor: cs.primaryContainer,
              onTap: () => widget.onOpenChild?.call(job.conversationId),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  l10n.subagentPanelAnswerNow,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: cs.onPrimaryContainer,
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    } else {
      // One row: {N} tool calls · last step, tap anywhere to open the child.
      children.add(
        IosCardPress(
          borderRadius: BorderRadius.circular(10),
          baseColor: cs.surfaceContainerHighest,
          pressedScale: 0.98,
          onTap: () => widget.onOpenChild?.call(job.conversationId),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                Icon(Icons.hub_outlined, size: 15, color: cs.onSurfaceVariant),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    l10n.subagentPanelToolCalls(job.toolCallCount),
                    style: TextStyle(fontSize: 13, color: cs.onSurface),
                  ),
                ),
                if (job.lastStep != null)
                  Expanded(
                    child: Text(
                      job.lastStep!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ),
                const SizedBox(width: 4),
                Icon(
                  Icons.arrow_forward_ios,
                  size: 14,
                  color: cs.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: children,
    );
  }

  static String _argsSummary(Map<String, dynamic> args) {
    final entries = args.entries.map((e) => '${e.key}: ${e.value}').toList();
    return entries.isEmpty ? '{}' : entries.join('\n');
  }

  static String _basename(String path) {
    final idx = path.lastIndexOf('/');
    if (idx < 0) return path;
    final name = path.substring(idx + 1);
    return name.isEmpty ? path : name;
  }

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  static String _formatElapsed(DateTime startedAt) {
    final d = DateTime.now().difference(startedAt);
    final h = d.inHours;
    final m = d.inMinutes % 60;
    final s = d.inSeconds % 60;
    final mm = m.toString().padLeft(2, '0');
    final ss = s.toString().padLeft(2, '0');
    return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
  }
}
