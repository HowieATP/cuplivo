import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/models/assistant.dart';
import '../../../core/providers/assistant_provider.dart';
import '../../../core/providers/workspace_provider.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/ios_switch.dart';

/// Bottom sheet to enable/disable and bind a workspace for [assistant].
///
/// Writes `workspaceEnabled` + `workspaceId` atomically. Shared by the
/// assistant settings local-tools tab and the chat Tools Hub.
Future<void> showWorkspaceBindSheet(
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
