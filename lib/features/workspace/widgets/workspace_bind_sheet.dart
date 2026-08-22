import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/models/assistant.dart';
import '../../../core/providers/assistant_provider.dart';
import '../../../core/providers/workspace_provider.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/ios_switch.dart';
import '../../../utils/platform_utils.dart';

bool _bindOpen = false;

/// Bottom sheet (mobile) / centered dialog (desktop) to enable and bind a
/// workspace for [assistant].
///
/// Writes `workspaceEnabled` + `workspaceId` atomically. Shared by the
/// assistant settings local-tools tab and the chat Tools Hub. Re-entrant
/// calls while a dialog/sheet is open are ignored.
Future<void> showWorkspaceBindSheet(
  BuildContext context,
  Assistant assistant,
) async {
  if (_bindOpen) return;
  _bindOpen = true;
  try {
    final wp = context.read<WorkspaceProvider>();
    await wp.init();
    if (!context.mounted) return;
    if (PlatformUtils.isDesktop) {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(AppLocalizations.of(ctx)!.workspaceBindTitle),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420, maxHeight: 480),
            child: WorkspaceBindBody(assistant: assistant),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text(AppLocalizations.of(ctx)!.mcpPageCancel),
            ),
          ],
        ),
      );
    } else {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Theme.of(context).colorScheme.surface,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        ),
        builder: (ctx) => SafeArea(
          top: false,
          child: SingleChildScrollView(
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
                  WorkspaceBindBody(assistant: assistant),
                ],
              ),
            ),
          ),
        ),
      );
    }
  } finally {
    _bindOpen = false;
  }
}

/// Shared bind/select body used by both the mobile sheet and the desktop
/// dialog.
class WorkspaceBindBody extends StatefulWidget {
  const WorkspaceBindBody({super.key, required this.assistant});

  final Assistant assistant;

  @override
  State<WorkspaceBindBody> createState() => _WorkspaceBindBodyState();
}

class _WorkspaceBindBodyState extends State<WorkspaceBindBody> {
  late bool _enabled = widget.assistant.workspaceEnabled;
  late String? _selectedId =
      widget.assistant.workspaceId ??
      context.read<WorkspaceProvider>().defaultWorkspace?.id;

  Future<void> _apply({bool? enabled, String? id}) async {
    try {
      await context.read<AssistantProvider>().updateAssistant(
        widget.assistant.copyWith(
          workspaceEnabled: enabled ?? _enabled,
          workspaceId: id ?? _selectedId,
        ),
      );
    } catch (e) {
      debugPrint('WorkspaceBindBody: failed to persist workspace binding: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final wp = context.watch<WorkspaceProvider>();
    final list = wp.workspaces;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
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
              value: _enabled,
              onChanged: (v) {
                setState(() => _enabled = v);
                _apply(enabled: v);
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
              context,
            ).colorScheme.onSurface.withValues(alpha: 0.6),
          ),
        ),
        const SizedBox(height: 8),
        if (_enabled)
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 320),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final w in list)
                    ListTile(
                      title: Text(w.displayName),
                      subtitle: Text('@${w.alias}'),
                      trailing: w.id == _selectedId
                          ? Icon(
                              Lucide.Check,
                              color: Theme.of(context).colorScheme.primary,
                            )
                          : null,
                      onTap: () {
                        setState(() => _selectedId = w.id);
                        _apply(id: w.id);
                      },
                    ),
                ],
              ),
            ),
          )
        else
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Text(
              l10n.workspaceBindDisabledHint,
              style: TextStyle(
                fontSize: 13,
                color: Theme.of(
                  context,
                ).colorScheme.onSurface.withValues(alpha: 0.55),
              ),
            ),
          ),
      ],
    );
  }
}
