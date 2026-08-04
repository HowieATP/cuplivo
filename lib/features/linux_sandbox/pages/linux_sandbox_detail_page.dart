import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/providers/assistant_provider.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/ios_switch.dart';
import '../../../shared/widgets/ios_tactile.dart';
import '../../../shared/widgets/snackbar.dart';
import '../../../theme/app_font_weights.dart';
import '../models/linux_sandbox.dart';
import '../providers/linux_sandbox_provider.dart';
import 'linux_sandbox_file_browser_page.dart';

class LinuxSandboxDetailPage extends StatelessWidget {
  const LinuxSandboxDetailPage({super.key, required this.sandboxId});

  final String sandboxId;

  Future<void> _confirmDelete(
    BuildContext context,
    LinuxSandbox sandbox,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.linuxSandboxDeleteConfirmTitle),
        content: Text(l10n.linuxSandboxDeleteConfirmMessage(sandbox.name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(MaterialLocalizations.of(ctx).cancelButtonLabel),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: cs.error),
            child: Text(l10n.linuxSandboxDeleteAction),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    try {
      await context.read<LinuxSandboxProvider>().delete(
        sandbox.id,
        context.read<AssistantProvider>(),
      );
      if (context.mounted) Navigator.of(context).maybePop();
    } catch (e, st) {
      debugPrint('LinuxSandboxDetailPage: delete failed: $e\n$st');
      if (!context.mounted) return;
      showAppSnackBar(
        context,
        message: l10n.linuxSandboxDeleteFailed,
        type: NotificationType.error,
      );
    }
  }

  List<_ToolUiMeta> _toolMetas(AppLocalizations l10n) {
    return [
      _ToolUiMeta(
        name: LinuxSandboxToolNames.read,
        title: l10n.linuxSandboxToolReadName,
        description: l10n.linuxSandboxToolReadDescription,
        params: const [_ParamMeta(name: 'path', required: true)],
      ),
      _ToolUiMeta(
        name: LinuxSandboxToolNames.write,
        title: l10n.linuxSandboxToolWriteName,
        description: l10n.linuxSandboxToolWriteDescription,
        params: const [
          _ParamMeta(name: 'path', required: true),
          _ParamMeta(name: 'content', required: true),
        ],
      ),
      _ToolUiMeta(
        name: LinuxSandboxToolNames.edit,
        title: l10n.linuxSandboxToolEditName,
        description: l10n.linuxSandboxToolEditDescription,
        params: const [
          _ParamMeta(name: 'path', required: true),
          _ParamMeta(name: 'old_string', required: true),
          _ParamMeta(name: 'new_string', required: true),
        ],
      ),
      _ToolUiMeta(
        name: LinuxSandboxToolNames.shell,
        title: l10n.linuxSandboxToolShellName,
        description: l10n.linuxSandboxToolShellDescription,
        params: const [
          _ParamMeta(name: 'command', required: true),
          _ParamMeta(name: 'timeout_seconds', required: false),
        ],
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final provider = context.watch<LinuxSandboxProvider>();
    final sandbox = provider.getById(sandboxId);

    if (sandbox == null) {
      return Scaffold(
        appBar: AppBar(
          leading: IosIconButton(
            icon: Lucide.ChevronLeft,
            size: 22,
            minSize: 44,
            onTap: () => Navigator.of(context).maybePop(),
          ),
          title: Text(l10n.linuxSandboxListTitle),
        ),
        body: Center(
          child: Text(
            l10n.linuxSandboxMissingMessage,
            style: TextStyle(color: cs.onSurface.withValues(alpha: 0.6)),
          ),
        ),
      );
    }

    final metas = _toolMetas(l10n);

    return Scaffold(
      appBar: AppBar(
        leading: Tooltip(
          message: l10n.settingsPageBackButton,
          child: IosIconButton(
            icon: Lucide.ChevronLeft,
            size: 22,
            minSize: 44,
            onTap: () => Navigator.of(context).maybePop(),
          ),
        ),
        title: Text(sandbox.name),
        actions: [
          Tooltip(
            message: l10n.linuxSandboxBrowseTitle,
            child: IosIconButton(
              icon: Lucide.FolderOpen,
              size: 20,
              minSize: 44,
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) =>
                        LinuxSandboxFileBrowserPage(sandboxId: sandbox.id),
                  ),
                );
              },
            ),
          ),
          Tooltip(
            message: l10n.linuxSandboxDeleteAction,
            child: IosIconButton(
              icon: Lucide.Trash2,
              size: 20,
              minSize: 44,
              color: cs.error,
              onTap: () => _confirmDelete(context, sandbox),
            ),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
        children: [
          Text(
            sandbox.name,
            style: TextStyle(
              fontSize: 20,
              fontWeight: AppFontWeights.emphasis,
              color: cs.onSurface,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            l10n.linuxSandboxBackupNote,
            style: TextStyle(
              fontSize: 12,
              height: 1.35,
              color: cs.onSurface.withValues(alpha: 0.55),
            ),
          ),
          const SizedBox(height: 18),
          Text(
            l10n.linuxSandboxDetailToolsSection,
            style: TextStyle(
              fontSize: 13,
              fontWeight: AppFontWeights.semibold,
              color: cs.onSurface.withValues(alpha: 0.55),
            ),
          ),
          const SizedBox(height: 8),
          for (final meta in metas) ...[
            _ToolCard(
              meta: meta,
              config:
                  sandbox.tools[meta.name] ?? const LinuxSandboxToolConfig(),
              isDark: isDark,
              onEnabledChanged: (v) {
                final provider = context.read<LinuxSandboxProvider>();
                final latest = provider.getById(sandbox.id);
                if (latest == null) return;
                final current =
                    latest.tools[meta.name] ?? const LinuxSandboxToolConfig();
                provider.setToolConfig(
                  sandbox.id,
                  meta.name,
                  current.copyWith(enabled: v),
                );
              },
              onNeedsApprovalChanged: (v) {
                final provider = context.read<LinuxSandboxProvider>();
                final latest = provider.getById(sandbox.id);
                if (latest == null) return;
                final current =
                    latest.tools[meta.name] ?? const LinuxSandboxToolConfig();
                provider.setToolConfig(
                  sandbox.id,
                  meta.name,
                  current.copyWith(needsApproval: v),
                );
              },
            ),
            const SizedBox(height: 10),
          ],
        ],
      ),
    );
  }
}

class _ToolUiMeta {
  const _ToolUiMeta({
    required this.name,
    required this.title,
    required this.description,
    required this.params,
  });

  final String name;
  final String title;
  final String description;
  final List<_ParamMeta> params;
}

class _ParamMeta {
  const _ParamMeta({required this.name, required this.required});
  final String name;
  final bool required;
}

class _ToolCard extends StatelessWidget {
  const _ToolCard({
    required this.meta,
    required this.config,
    required this.isDark,
    required this.onEnabledChanged,
    required this.onNeedsApprovalChanged,
  });

  final _ToolUiMeta meta;
  final LinuxSandboxToolConfig config;
  final bool isDark;
  final ValueChanged<bool> onEnabledChanged;
  final ValueChanged<bool> onNeedsApprovalChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isDark ? Colors.white10 : const Color(0xFFF7F7F9),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      meta.title,
                      style: TextStyle(fontWeight: AppFontWeights.emphasis),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      meta.description,
                      style: TextStyle(
                        fontSize: 12,
                        color: cs.onSurface.withValues(alpha: 0.7),
                      ),
                    ),
                    if (meta.params.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: meta.params.map((p) {
                          final color = p.required
                              ? cs.primary
                              : cs.onSurface.withValues(alpha: 0.5);
                          final bg = p.required
                              ? cs.primary.withValues(alpha: 0.12)
                              : cs.onSurface.withValues(alpha: 0.06);
                          return Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: bg,
                              borderRadius: BorderRadius.circular(999),
                              border: Border.all(
                                color: color.withValues(alpha: 0.5),
                              ),
                            ),
                            child: Text(
                              p.name,
                              style: TextStyle(
                                fontSize: 11,
                                color: color,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          );
                        }).toList(),
                      ),
                    ],
                  ],
                ),
              ),
              IosSwitch(value: config.enabled, onChanged: onEnabledChanged),
            ],
          ),
          if (config.enabled) ...[
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(
                children: [
                  Icon(
                    Lucide.Shield,
                    size: 13,
                    color: config.needsApproval
                        ? cs.primary
                        : cs.onSurface.withValues(alpha: 0.4),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      l10n.mcpToolNeedsApproval,
                      style: TextStyle(
                        fontSize: 12,
                        color: cs.onSurface.withValues(alpha: 0.6),
                      ),
                    ),
                  ),
                  IosSwitch(
                    value: config.needsApproval,
                    onChanged: onNeedsApprovalChanged,
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
