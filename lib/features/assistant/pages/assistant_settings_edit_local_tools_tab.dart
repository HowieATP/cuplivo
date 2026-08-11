part of 'assistant_settings_edit_page.dart';

class _LocalToolsTab extends StatelessWidget {
  const _LocalToolsTab({required this.assistantId});
  final String assistantId;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final ap = context.watch<AssistantProvider>();
    final assistant = ap.getById(assistantId)!;
    final timeEnabled = assistant.localToolIds.contains(
      LocalToolNames.timeInfo,
    );
    final clipboardEnabled = assistant.localToolIds.contains(
      LocalToolNames.clipboard,
    );
    final textToSpeechEnabled = assistant.localToolIds.contains(
      LocalToolNames.textToSpeech,
    );
    final askUserEnabled = assistant.localToolIds.contains(
      LocalToolNames.askUser,
    );
    final calculateEnabled = assistant.localToolIds.contains(
      LocalToolNames.calculate,
    );
    final handoffEnabled = assistant.localToolIds.contains(
      LocalToolNames.handoff,
    );
    final handoffSyncEnabled = assistant.localToolIds.contains(
      LocalToolNames.handoffSync,
    );

    Future<void> updateTool(String toolId, bool value) {
      final ids = assistant.localToolIds.toSet();
      if (value) {
        ids.add(toolId);
      } else {
        ids.remove(toolId);
      }
      return context.read<AssistantProvider>().updateAssistant(
        assistant.copyWith(localToolIds: ids.toList(growable: false)),
      );
    }

    final workspaceOn = assistant.workspaceEnabled;
    String workspaceSubtitle = l10n.workspaceEntrySubtitleOff;
    if (workspaceOn) {
      try {
        final wp = context.watch<WorkspaceProvider>();
        final ws = assistant.workspaceId == null
            ? null
            : wp.getById(assistant.workspaceId!);
        workspaceSubtitle = ws?.displayName ?? l10n.workspaceBindTitle;
      } on ProviderNotFoundException catch (e) {
        debugPrint('workspace provider missing: $e');
      } catch (e) {
        debugPrint('workspace subtitle: $e');
      }
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
      children: [
        _iosSectionCard(
          children: [
            _LocalToolNavRow(
              icon: Lucide.FolderOpen,
              title: l10n.assistantEditLocalToolWorkspaceTitle,
              subtitle: workspaceSubtitle,
              onTap: () => _showWorkspaceBindSheet(context, assistant),
            ),
            _iosDivider(context),
            _LocalToolRow(
              icon: Lucide.clock,
              title: l10n.assistantEditLocalToolTimeInfoTitle,
              subtitle: l10n.assistantEditLocalToolTimeInfoSubtitle,
              enabled: timeEnabled,
              onChanged: (value) => updateTool(LocalToolNames.timeInfo, value),
            ),
            _iosDivider(context),
            _LocalToolRow(
              icon: Lucide.Clipboard,
              title: l10n.assistantEditLocalToolClipboardTitle,
              subtitle: l10n.assistantEditLocalToolClipboardSubtitle,
              enabled: clipboardEnabled,
              onChanged: (value) => updateTool(LocalToolNames.clipboard, value),
            ),
            _iosDivider(context),
            _LocalToolRow(
              icon: Lucide.Volume2,
              title: l10n.assistantEditLocalToolTextToSpeechTitle,
              subtitle: l10n.assistantEditLocalToolTextToSpeechSubtitle,
              enabled: textToSpeechEnabled,
              onChanged: (value) =>
                  updateTool(LocalToolNames.textToSpeech, value),
            ),
            _iosDivider(context),
            _LocalToolRow(
              icon: Lucide.MessageCircleQuestionMark,
              title: l10n.assistantEditLocalToolAskUserTitle,
              subtitle: l10n.assistantEditLocalToolAskUserSubtitle,
              enabled: askUserEnabled,
              onChanged: (value) => updateTool(LocalToolNames.askUser, value),
            ),
            _iosDivider(context),
            _LocalToolRow(
              icon: Lucide.Calculator,
              title: l10n.assistantEditLocalToolCalculateTitle,
              subtitle: l10n.assistantEditLocalToolCalculateSubtitle,
              enabled: calculateEnabled,
              onChanged: (value) => updateTool(LocalToolNames.calculate, value),
            ),
            _iosDivider(context),
            _LocalToolRow(
              icon: Lucide.Bot,
              title: l10n.assistantEditLocalToolHandoffTitle,
              subtitle: l10n.assistantEditLocalToolHandoffSubtitle,
              enabled: handoffEnabled,
              onChanged: (value) => updateTool(LocalToolNames.handoff, value),
            ),
            _iosDivider(context),
            _LocalToolRow(
              icon: Lucide.Timer,
              title: l10n.assistantEditLocalToolHandoffSyncTitle,
              subtitle: l10n.assistantEditLocalToolHandoffSyncSubtitle,
              enabled: handoffSyncEnabled,
              onChanged: (value) =>
                  updateTool(LocalToolNames.handoffSync, value),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _showWorkspaceBindSheet(
    BuildContext context,
    Assistant assistant,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    final ap = context.read<AssistantProvider>();
    final wp = context.read<WorkspaceProvider>();
    await wp.init();
    var enabled = assistant.workspaceEnabled;
    var selectedId = assistant.workspaceId ?? wp.defaultWorkspace?.id;

    if (!context.mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSt) {
            final list = wp.workspaces;
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Center(
                      child: Container(
                        width: 40,
                        height: 4,
                        decoration: BoxDecoration(
                          color: Theme.of(
                            ctx,
                          ).colorScheme.outlineVariant.withValues(alpha: 0.6),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            l10n.workspaceEnableTitle,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        IosSwitch(
                          value: enabled,
                          onChanged: (v) async {
                            setSt(() => enabled = v);
                            await ap.updateAssistant(
                              assistant.copyWith(
                                workspaceEnabled: v,
                                workspaceId: selectedId,
                              ),
                            );
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text(
                      l10n.workspaceBindTitle,
                      style: TextStyle(
                        fontSize: 13,
                        color: Theme.of(
                          ctx,
                        ).colorScheme.onSurface.withValues(alpha: 0.6),
                      ),
                    ),
                    const SizedBox(height: 8),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 320),
                      child: ListView.builder(
                        shrinkWrap: true,
                        itemCount: list.length,
                        itemBuilder: (_, i) {
                          final w = list[i];
                          final selected = w.id == selectedId;
                          return ListTile(
                            title: Text(w.displayName),
                            subtitle: Text('@${w.alias}'),
                            trailing: selected
                                ? Icon(
                                    Lucide.Check,
                                    color: Theme.of(ctx).colorScheme.primary,
                                  )
                                : null,
                            onTap: () async {
                              setSt(() => selectedId = w.id);
                              await ap.updateAssistant(
                                assistant.copyWith(
                                  workspaceEnabled: enabled,
                                  workspaceId: w.id,
                                ),
                              );
                            },
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _LocalToolNavRow extends StatelessWidget {
  const _LocalToolNavRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return _TactileRow(
      onTap: onTap,
      builder: (pressed) {
        final baseColor = cs.onSurface.withValues(alpha: 0.9);
        return _AnimatedPressColor(
          pressed: pressed,
          base: baseColor,
          builder: (color) {
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  SizedBox(
                    width: 36,
                    child: Icon(icon, size: 20, color: cs.primary),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 15,
                            color: color,
                            fontWeight: AppFontWeights.semibold,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          subtitle,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            height: 1.25,
                            color: cs.onSurface.withValues(alpha: 0.62),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Icon(
                    Lucide.ChevronRight,
                    size: 18,
                    color: cs.onSurface.withValues(alpha: 0.35),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

class _LocalToolRow extends StatelessWidget {
  const _LocalToolRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.enabled,
    required this.onChanged,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return _TactileRow(
      onTap: () => onChanged(!enabled),
      builder: (pressed) {
        final baseColor = cs.onSurface.withValues(alpha: 0.9);
        return _AnimatedPressColor(
          pressed: pressed,
          base: baseColor,
          builder: (color) {
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  SizedBox(
                    width: 36,
                    child: Icon(
                      icon,
                      size: 20,
                      color: enabled ? cs.primary : color,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 15,
                            color: color,
                            fontWeight: AppFontWeights.semibold,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          subtitle,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            height: 1.25,
                            color: cs.onSurface.withValues(alpha: 0.62),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  IosSwitch(value: enabled, onChanged: onChanged),
                ],
              ),
            );
          },
        );
      },
    );
  }
}
