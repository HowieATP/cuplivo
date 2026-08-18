import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/models/assistant.dart';
import '../../../core/models/workspace.dart';
import '../../../core/providers/assistant_provider.dart';
import '../../../core/providers/mcp_provider.dart';
import '../../../core/providers/workspace_provider.dart';
import '../../../core/services/haptics.dart';
import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/collapsible_group_header.dart';
import '../../../shared/widgets/ios_tactile.dart';
import '../../../shared/widgets/tool_toggle_row.dart';
import '../../../theme/app_font_weights.dart';
import '../../mcp/pages/mcp_page.dart';
import '../../workspace/pages/workspace_list_page.dart';
import '../../workspace/pages/workspace_terminal_page.dart';
import '../../workspace/widgets/workspace_bind_sheet.dart';
import '../services/local_tools_service.dart';

/// The shared Tools Hub content: local tools / MCP servers / workspace
/// management grouped with collapsible headers. Used by both the mobile
/// bottom sheet and the desktop anchored popover.
class ToolsHubContent extends StatefulWidget {
  const ToolsHubContent({super.key, required this.assistantId});

  final String assistantId;

  @override
  State<ToolsHubContent> createState() => _ToolsHubContentState();
}

class _ToolsHubContentState extends State<ToolsHubContent>
    with CollapsibleGroupsMixin<ToolsHubContent> {
  static const String _localToolsKey = 'local_tools';
  static const String _mcpKey = 'mcp';
  static const String _workspaceKey = 'workspace';

  @override
  Set<String> get initialCollapsedGroups => {_localToolsKey};

  void _updateAssistant(Assistant next) {
    try {
      context.read<AssistantProvider>().updateAssistant(next);
    } catch (e) {
      debugPrint('ToolsHubContent: failed to persist assistant update: $e');
    }
  }

  void _toggleLocalTool(Assistant a, String toolId, bool value) {
    Haptics.light();
    final ids = a.localToolIds.toSet();
    if (value) {
      ids.add(toolId);
    } else {
      ids.remove(toolId);
    }
    _updateAssistant(a.copyWith(localToolIds: ids.toList(growable: false)));
  }

  void _toggleMcpServer(Assistant a, String id, bool value) {
    Haptics.light();
    final set = a.mcpServerIds.toSet();
    if (value) {
      set.add(id);
    } else {
      set.remove(id);
    }
    _updateAssistant(a.copyWith(mcpServerIds: set.toList(growable: false)));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final ap = context.watch<AssistantProvider>();
    final assistant = ap.getById(widget.assistantId);
    if (assistant == null) return const SizedBox.shrink();

    final mcp = context.watch<McpProvider>();
    final wp = context.watch<WorkspaceProvider>();
    final servers = mcp.servers
        .where((s) => mcp.statusFor(s.id) == McpStatus.connected)
        .toList();
    final selected = assistant.mcpServerIds.toSet();
    final boundWs = assistant.workspaceId == null
        ? null
        : wp.getById(assistant.workspaceId!);
    final wsTerminalReady =
        Platform.isAndroid &&
        assistant.workspaceEnabled &&
        boundWs != null &&
        !boundWs.readOnly;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 6),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  l10n.chatInputBarToolsTooltip,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: AppFontWeights.emphasis,
                  ),
                ),
              ),
              Tooltip(
                message: l10n.mcpAssistantSheetTitle,
                child: IosIconButton(
                  icon: Lucide.Hammer,
                  size: 18,
                  minSize: 34,
                  padding: const EdgeInsets.all(8),
                  onTap: () {
                    Haptics.light();
                    Navigator.of(
                      context,
                    ).push(MaterialPageRoute(builder: (_) => const McpPage()));
                  },
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildLocalToolsGroup(l10n, cs, assistant),
              const SizedBox(height: 6),
              _buildMcpGroup(l10n, cs, assistant, servers, selected),
              const SizedBox(height: 6),
              _buildWorkspaceGroup(
                l10n,
                cs,
                assistant,
                boundWs,
                wsTerminalReady,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildLocalToolsGroup(
    AppLocalizations l10n,
    ColorScheme cs,
    Assistant a,
  ) {
    final rows = <Widget>[
      _localToolRow(
        a,
        icon: Lucide.clock,
        title: l10n.assistantEditLocalToolTimeInfoTitle,
        toolId: LocalToolNames.timeInfo,
      ),
      _localToolRow(
        a,
        icon: Lucide.Clipboard,
        title: l10n.assistantEditLocalToolClipboardTitle,
        toolId: LocalToolNames.clipboard,
      ),
      _localToolRow(
        a,
        icon: Lucide.Volume2,
        title: l10n.assistantEditLocalToolTextToSpeechTitle,
        toolId: LocalToolNames.textToSpeech,
      ),
      _localToolRow(
        a,
        icon: Lucide.MessageCircleQuestionMark,
        title: l10n.assistantEditLocalToolAskUserTitle,
        toolId: LocalToolNames.askUser,
      ),
      _localToolRow(
        a,
        icon: Lucide.Calculator,
        title: l10n.assistantEditLocalToolCalculateTitle,
        toolId: LocalToolNames.calculate,
      ),
      _localToolRow(
        a,
        icon: Lucide.Bot,
        title: l10n.assistantEditLocalToolHandoffTitle,
        toolId: LocalToolNames.handoff,
      ),
      _localToolRow(
        a,
        icon: Lucide.Timer,
        title: l10n.assistantEditLocalToolHandoffSyncTitle,
        toolId: LocalToolNames.handoffSync,
      ),
    ];
    return _buildGroup(
      keyName: _localToolsKey,
      groupName: l10n.toolsHubLocalToolsTitle,
      count: rows.length,
      children: rows,
    );
  }

  Widget _localToolRow(
    Assistant a, {
    required IconData icon,
    required String title,
    required String toolId,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: ToolToggleRow(
        icon: icon,
        title: title,
        enabled: a.localToolIds.contains(toolId),
        onChanged: (v) => _toggleLocalTool(a, toolId, v),
      ),
    );
  }

  Widget _buildMcpGroup(
    AppLocalizations l10n,
    ColorScheme cs,
    Assistant a,
    List<McpServerConfig> servers,
    Set<String> selected,
  ) {
    final children = <Widget>[];
    if (servers.isEmpty) {
      children.add(
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Center(
            child: Text(
              l10n.mcpConversationSheetNoRunning,
              style: TextStyle(
                fontSize: 12.5,
                color: cs.onSurface.withValues(alpha: 0.6),
              ),
            ),
          ),
        ),
      );
    } else {
      children.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 2, 4, 6),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton.icon(
                onPressed: () {
                  Haptics.light();
                  _updateAssistant(
                    a.copyWith(mcpServerIds: servers.map((e) => e.id).toList()),
                  );
                },
                icon: Icon(Lucide.Check, size: 14, color: cs.primary),
                label: Text(
                  l10n.mcpConversationSheetSelectAll,
                  style: const TextStyle(fontSize: 12),
                ),
              ),
              const SizedBox(width: 8),
              TextButton.icon(
                onPressed: () {
                  Haptics.light();
                  _updateAssistant(a.copyWith(mcpServerIds: const <String>[]));
                },
                icon: Icon(Lucide.X, size: 14, color: cs.primary),
                label: Text(
                  l10n.mcpConversationSheetClearAll,
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ],
          ),
        ),
      );
      for (final s in servers) {
        final isSelected = selected.contains(s.id);
        final tools = s.tools;
        final enabledTools = tools.where((t) => t.enabled).length;
        children.add(
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: ToolToggleRow(
              icon: Lucide.Hammer,
              title: s.name,
              subtitle: l10n.mcpConversationSheetToolsCount(
                enabledTools,
                tools.length,
              ),
              enabled: isSelected,
              onChanged: (v) => _toggleMcpServer(a, s.id, v),
            ),
          ),
        );
      }
    }
    return _buildGroup(
      keyName: _mcpKey,
      groupName: l10n.mcpConversationSheetTitle,
      count: servers.length,
      children: children,
    );
  }

  Widget _buildWorkspaceGroup(
    AppLocalizations l10n,
    ColorScheme cs,
    Assistant a,
    Workspace? boundWs,
    bool wsTerminalReady,
  ) {
    final children = <Widget>[
      Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: _NavRow(
          icon: Lucide.FolderOpen,
          title: l10n.workspaceBindTitle,
          subtitle: boundWs?.displayName ?? l10n.toolsHubWorkspaceUnbound,
          enabled: true,
          onTap: () {
            Haptics.light();
            showWorkspaceBindSheet(context, a);
          },
        ),
      ),
    ];
    if (Platform.isAndroid) {
      children.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: _NavRow(
            icon: Lucide.Terminal,
            title: l10n.toolsHubOpenTerminal,
            subtitle: wsTerminalReady
                ? boundWs!.displayName
                : l10n.toolsHubTerminalDisabledHint,
            enabled: wsTerminalReady,
            onTap: wsTerminalReady
                ? () {
                    Haptics.light();
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) =>
                            WorkspaceTerminalPage(workspaceId: boundWs!.id),
                      ),
                    );
                  }
                : null,
          ),
        ),
      );
    }
    return _buildGroup(
      keyName: _workspaceKey,
      groupName: l10n.settingsPageWorkspace,
      count: Platform.isAndroid ? 2 : 1,
      trailing: Tooltip(
        message: l10n.toolsHubWorkspaceManage,
        child: IosIconButton(
          icon: Lucide.Settings2,
          size: 16,
          minSize: 30,
          padding: const EdgeInsets.all(6),
          onTap: () {
            Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const WorkspaceListPage()),
            );
          },
        ),
      ),
      children: children,
    );
  }

  Widget _buildGroup({
    required String keyName,
    required String groupName,
    required int count,
    required List<Widget> children,
    Widget? trailing,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        CollapsibleGroupHeader(
          groupName: groupName,
          skillCount: count,
          expanded: isGroupExpanded(keyName),
          onTap: () => toggleGroup(keyName),
          fontSize: 12.5,
          fontWeight: AppFontWeights.emphasis,
          padding: const EdgeInsets.fromLTRB(4, 10, 4, 4),
          trailing: trailing,
        ),
        CollapsibleGroupBody(
          expanded: isGroupExpanded(keyName),
          child: Column(children: children),
        ),
      ],
    );
  }
}

class _NavRow extends StatelessWidget {
  const _NavRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.enabled,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool enabled;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final dimmed = !enabled;
    final iconColor = dimmed ? cs.onSurface.withValues(alpha: 0.4) : cs.primary;
    return IosCardPress(
      borderRadius: BorderRadius.circular(14),
      baseColor: cs.surface,
      duration: const Duration(milliseconds: 260),
      onTap: onTap,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Opacity(
        opacity: dimmed ? 0.55 : 1.0,
        child: Row(
          children: [
            Icon(icon, size: 18, color: iconColor),
            const SizedBox(width: 10),
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
                      fontWeight: AppFontWeights.medium,
                      color: cs.onSurface,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: cs.onSurface.withValues(alpha: 0.55),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Icon(
              Lucide.ChevronRight,
              size: 18,
              color: cs.onSurface.withValues(alpha: 0.55),
            ),
          ],
        ),
      ),
    );
  }
}
